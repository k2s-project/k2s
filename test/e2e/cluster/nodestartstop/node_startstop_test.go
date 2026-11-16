// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package nodestartstop

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/core/clusterconfig"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

var suite *framework.K2sTestSuite
var k2s *dsl.K2s

func TestNodeStartStop(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Node Start/Stop Acceptance Tests",
		Label("core", "acceptance", "internet-required", "setup-required", "system-running", "node-start-stop"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(500*time.Millisecond),
		framework.ClusterTestStepTimeout(20*time.Minute))
	k2s = dsl.NewK2s(suite)

	// Wait for all nodes to be Ready before running start/stop tests
	GinkgoWriter.Println("Waiting for all nodes to be in Ready state...")
	nodes := getAllNodeNames(ctx)
	for _, node := range nodes {
		GinkgoWriter.Printf("Waiting for node %s to be Ready...\n", node)
		suite.Cluster().WaitForNodeToBeReady(node, ctx)
	}
	GinkgoWriter.Println("All nodes are Ready")

	DeferCleanup(suite.TearDown)
})

// getAllNodeNames returns all node names in the cluster
func getAllNodeNames(ctx context.Context) []string {
	client := suite.Cluster().Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	if err != nil {
		GinkgoWriter.Printf("Error creating clientset: %v\n", err)
		return nil
	}

	nodes, err := clientSet.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		GinkgoWriter.Printf("Error listing nodes: %v\n", err)
		return nil
	}

	var nodeNames []string
	for _, node := range nodes.Items {
		nodeNames = append(nodeNames, node.Name)
	}
	return nodeNames
}

const (
	// KubeSwitch network CIDR (internal Hyper-V switch for K2s VMs)
	kubeSwitchCIDR = "172.19.1.0/24"
)

// WorkerNodeInfo holds the details of a worker node from cluster.json
// Supports both VM-EXISTING (Hyper-V) and Host (bare-metal) node types
type WorkerNodeInfo struct {
	Name      string
	IpAddress string
	Username  string
	NodeType  clusterconfig.NodeType
}

// nodeJSON is used to parse node entries from cluster.json
type nodeJSON struct {
	Name      string `json:"Name"`
	IpAddress string `json:"IpAddress"`
	Username  string `json:"Username"`
	NodeType  string `json:"NodeType"`
}

// findWorkerNode searches cluster.json for a worker node with NodeType=VM-EXISTING or NodeType=Host
// and returns its details. Handles both array and single-object formats for nodes.
// Supports both Hyper-V VMs (VM-EXISTING) and bare-metal (Host) node types.
func findWorkerNode() (*WorkerNodeInfo, bool) {
	configDir := suite.SetupInfo().Config.Host().K2sSetupConfigDir()
	clusterJsonPath := filepath.Join(configDir, "cluster.json")

	data, err := os.ReadFile(clusterJsonPath)
	if err != nil {
		GinkgoWriter.Printf("Could not read cluster.json: %v\n", err)
		return nil, false
	}

	// isWorkerNodeType checks if the node type is a supported worker node type
	isWorkerNodeType := func(nodeType string) bool {
		return nodeType == string(clusterconfig.NodeTypeVMExisting) ||
			nodeType == string(clusterconfig.NodeTypeHost)
	}

	// Try to parse nodes as an array first
	var clusterWithArray struct {
		Nodes []nodeJSON `json:"nodes"`
	}
	if err := json.Unmarshal(data, &clusterWithArray); err == nil && len(clusterWithArray.Nodes) > 0 {
		for _, node := range clusterWithArray.Nodes {
			if isWorkerNodeType(node.NodeType) {
				return &WorkerNodeInfo{
					Name:      node.Name,
					IpAddress: node.IpAddress,
					Username:  node.Username,
					NodeType:  clusterconfig.NodeType(node.NodeType),
				}, true
			}
		}
		return nil, false
	}

	// Try to parse nodes as a single object (non-standard but may occur)
	var clusterWithObject struct {
		Nodes nodeJSON `json:"nodes"`
	}
	if err := json.Unmarshal(data, &clusterWithObject); err == nil && clusterWithObject.Nodes.Name != "" {
		node := clusterWithObject.Nodes
		if isWorkerNodeType(node.NodeType) {
			return &WorkerNodeInfo{
				Name:      node.Name,
				IpAddress: node.IpAddress,
				Username:  node.Username,
				NodeType:  clusterconfig.NodeType(node.NodeType),
			}, true
		}
	}

	GinkgoWriter.Println("No worker node (VM-EXISTING or Host) found in cluster.json")
	return nil, false
}

// isIPInCIDR checks if the given IP address falls within the specified CIDR range.
func isIPInCIDR(ipStr, cidrStr string) bool {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}
	_, cidrNet, err := net.ParseCIDR(cidrStr)
	if err != nil {
		return false
	}
	return cidrNet.Contains(ip)
}

// getNodeStatus returns the Ready condition status of a node.
func getNodeStatus(ctx context.Context, nodeName string) (bool, error) {
	client := suite.Cluster().Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	if err != nil {
		return false, err
	}

	node, err := clientSet.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{})
	if err != nil {
		return false, err
	}

	for _, cond := range node.Status.Conditions {
		if cond.Type == corev1.NodeReady {
			return cond.Status == corev1.ConditionTrue, nil
		}
	}
	return false, nil
}

// getPodsOnNode returns all pods scheduled on the given node in the specified namespace.
func getPodsOnNode(ctx context.Context, nodeName, namespace string) ([]corev1.Pod, error) {
	client := suite.Cluster().Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	if err != nil {
		return nil, err
	}

	pods, err := clientSet.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{
		FieldSelector: fmt.Sprintf("spec.nodeName=%s", nodeName),
	})
	if err != nil {
		return nil, err
	}
	return pods.Items, nil
}

// getControlPlaneNodeName returns the name of the control-plane node.
func getControlPlaneNodeName(ctx context.Context) string {
	output := suite.Kubectl().NoStdOut().MustExec(ctx, "get", "nodes",
		"-l", "node-role.kubernetes.io/control-plane",
		"-o", "jsonpath={.items[0].metadata.name}")
	return strings.TrimSpace(output)
}

// kubeSwitchExists checks if the KubeSwitch Hyper-V virtual switch exists.
// The switch is named "KubeSwitch" and is used for K2s VM networking.
func kubeSwitchExists(ctx context.Context) bool {
	// Use PowerShell to check if the switch exists
	output, exitCode := suite.Cli("powershell").Exec(ctx, "-Command",
		"Get-VMSwitch -Name 'KubeSwitch' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name")
	if exitCode != 0 {
		GinkgoWriter.Printf("KubeSwitch check returned exit code %d\n", exitCode)
		return false
	}
	exists := strings.TrimSpace(output) == "KubeSwitch"
	GinkgoWriter.Printf("KubeSwitch exists: %v\n", exists)
	return exists
}

var _ = Describe("Node Start/Stop", Ordered, func() {
	var workerIP string
	var workerName string
	var workerUsername string
	var workerNodeType clusterconfig.NodeType
	var isHyperVNode bool

	BeforeAll(func() {
		nodeInfo, found := findWorkerNode()
		if !found {
			Skip("Skipping node start/stop tests: no worker node (VM-EXISTING or Host) found in cluster.json")
		}
		workerIP = nodeInfo.IpAddress
		workerName = nodeInfo.Name
		workerUsername = nodeInfo.Username
		workerNodeType = nodeInfo.NodeType
		isHyperVNode = workerNodeType == clusterconfig.NodeTypeVMExisting

		GinkgoWriter.Printf("Using worker node from cluster.json: name=%s, ip=%s, username=%s, nodeType=%s\n",
			workerName, workerIP, workerUsername, workerNodeType)

		// Validate node is in KubeSwitch CIDR range (only for Hyper-V VMs)
		if isHyperVNode {
			Expect(isIPInCIDR(workerIP, kubeSwitchCIDR)).To(BeTrue(),
				"Expected IP %s to be within KubeSwitch CIDR %s", workerIP, kubeSwitchCIDR)
		}
	})

	Describe("node lifecycle", Label("lifecycle"), func() {
		const (
			testNamespace  = "node-lifecycle-test"
			deploymentName = "nginx-lifecycle-test"
			replicas       = 2
		)

		var controlPlaneNode string

		BeforeAll(func(ctx context.Context) {
			controlPlaneNode = getControlPlaneNodeName(ctx)
			GinkgoWriter.Printf("Control-plane node: %s\n", controlPlaneNode)

			// Create test namespace using pipe through cmd.exe
			cmd := fmt.Sprintf("%s create namespace %s --dry-run=client -o yaml | %s apply -f -",
				suite.Kubectl().Path(), testNamespace, suite.Kubectl().Path())
			suite.Cli("cmd.exe").MustExec(ctx, "/c", cmd)
		})

		AfterAll(func(ctx context.Context) {
			// Cleanup: ensure node is started and namespace is deleted
			GinkgoWriter.Println("Cleanup: ensuring node is started")
			k2s.StartNode(ctx, workerName)

			// Wait for node to be ready again
			Eventually(func() bool {
				ready, _ := getNodeStatus(ctx, workerName)
				return ready
			}, 5*time.Minute, 5*time.Second).Should(BeTrue(), "Node should be Ready after cleanup start")

			GinkgoWriter.Println("Cleanup: deleting test namespace")
			suite.Kubectl().Exec(ctx, "delete", "namespace", testNamespace, "--ignore-not-found")
		})

		Context("when deploying workload across nodes", Ordered, func() {
			It("creates a deployment with replicas spread across nodes", func(ctx context.Context) {
				// Create a deployment that will schedule pods on both control-plane and worker node
				// Using shsk2s.azurecr.io image which is pre-pulled and doesn't require internet
				// tolerationSeconds=30 ensures pods are evicted quickly when node becomes NotReady
				deploymentYaml := fmt.Sprintf(`
apiVersion: apps/v1
kind: Deployment
metadata:
  name: %s
  namespace: %s
spec:
  replicas: %d
  selector:
    matchLabels:
      app: %s
  template:
    metadata:
      labels:
        app: %s
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: %s
              topologyKey: kubernetes.io/hostname
      containers:
      - name: albums-app
        image: shsk2s.azurecr.io/example.albums-golang-linux:v1.0.0
        ports:
        - containerPort: 80
        env:
        - name: PORT
          value: "80"
        - name: RESOURCE
          value: "%s"
      tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "node.kubernetes.io/not-ready"
        operator: "Exists"
        effect: "NoExecute"
        tolerationSeconds: 30
      - key: "node.kubernetes.io/unreachable"
        operator: "Exists"
        effect: "NoExecute"
        tolerationSeconds: 30
`, deploymentName, testNamespace, replicas, deploymentName, deploymentName, deploymentName, deploymentName)

				// Apply the deployment using a temp file
				tempFile := fmt.Sprintf("%s\\deployment.yaml", suite.SetupInfo().Config.Host().K2sSetupConfigDir())
				writeCmd := fmt.Sprintf(`Set-Content -Path '%s' -Value @'
%s
'@`, tempFile, deploymentYaml)
				suite.Cli("powershell").MustExec(ctx, "-Command", writeCmd)
				suite.Kubectl().MustExec(ctx, "apply", "-f", tempFile)

				GinkgoWriter.Printf("Created deployment %s with %d replicas\n", deploymentName, replicas)
			})

			It("waits for deployment to be available", func(ctx context.Context) {
				suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, testNamespace)
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, testNamespace)
				GinkgoWriter.Println("Deployment is available and pods are ready")
			})

			It("verifies pods are scheduled on the worker node", func(ctx context.Context) {
				pods, err := getPodsOnNode(ctx, workerName, testNamespace)
				Expect(err).NotTo(HaveOccurred())
				Expect(len(pods)).To(BeNumerically(">", 0),
					"Expected at least one pod to be scheduled on worker node %s", workerName)

				for _, pod := range pods {
					GinkgoWriter.Printf("Pod %s is running on node %s\n", pod.Name, pod.Spec.NodeName)
				}
			})

			It("stops the worker node using k2s stop --node", func(ctx context.Context) {
				GinkgoWriter.Printf("Stopping node %s\n", workerName)

				result := k2s.StopNode(ctx, workerName)
				result.ExpectSuccess()

				GinkgoWriter.Printf("Node %s stop command completed\n", workerName)
			})

			It("verifies worker node becomes NotReady", func(ctx context.Context) {
				Eventually(func() bool {
					ready, err := getNodeStatus(ctx, workerName)
					if err != nil {
						GinkgoWriter.Printf("Error getting node status: %v\n", err)
						return true // Keep polling on error
					}
					GinkgoWriter.Printf("Node %s Ready status: %v\n", workerName, ready)
					return !ready // We want NotReady (ready=false)
				}, 5*time.Minute, 5*time.Second).Should(BeTrue(),
					"Node %s should become NotReady after stop", workerName)
			})

			It("verifies pods on stopped node are terminating or evicted", func(ctx context.Context) {
				// Wait for pods to be marked for deletion (Terminating) or evicted
				// Note: "Terminating" is not a pod phase - it's indicated by DeletionTimestamp being set
				// The pod phase may still show "Running" while terminating
				Eventually(func() bool {
					pods, err := getPodsOnNode(ctx, workerName, testNamespace)
					if err != nil {
						GinkgoWriter.Printf("Error getting pods: %v\n", err)
						return false
					}

					// If no pods on this node, they've been evicted
					if len(pods) == 0 {
						GinkgoWriter.Printf("No pods remaining on node %s - all evicted\n", workerName)
						return true
					}

					for _, pod := range pods {
						isTerminating := pod.DeletionTimestamp != nil
						GinkgoWriter.Printf("Pod %s on node %s: phase=%s, terminating=%v\n",
							pod.Name, workerName, pod.Status.Phase, isTerminating)

						// Pod should be terminating (has deletion timestamp) or already gone
						if !isTerminating {
							return false // Pod not yet marked for deletion
						}
					}
					// All remaining pods are terminating
					return true
				}, 2*time.Minute, 5*time.Second).Should(BeTrue(),
					"Pods on stopped node should be terminating or evicted")
			})

			It("verifies new pods are scheduled on another node", func(ctx context.Context) {
				// The deployment controller should create new pods on available nodes
				Eventually(func() int {
					pods, err := getPodsOnNode(ctx, controlPlaneNode, testNamespace)
					if err != nil {
						GinkgoWriter.Printf("Error getting pods on control-plane: %v\n", err)
						return 0
					}

					runningCount := 0
					for _, pod := range pods {
						if pod.Status.Phase == corev1.PodRunning {
							runningCount++
							GinkgoWriter.Printf("Running pod %s on control-plane node %s\n",
								pod.Name, controlPlaneNode)
						}
					}
					return runningCount
				}, 5*time.Minute, 5*time.Second).Should(BeNumerically(">=", 1),
					"At least one pod should be running on control-plane node after worker node stops")
			})

			It("starts the worker node using k2s start --node", func(ctx context.Context) {
				GinkgoWriter.Printf("Starting node %s\n", workerName)

				result := k2s.StartNode(ctx, workerName)
				result.ExpectSuccess()

				GinkgoWriter.Printf("Node %s start command completed\n", workerName)
			})

			It("verifies worker node becomes Ready again", func(ctx context.Context) {
				Eventually(func() bool {
					ready, err := getNodeStatus(ctx, workerName)
					if err != nil {
						GinkgoWriter.Printf("Error getting node status: %v\n", err)
						return false
					}
					GinkgoWriter.Printf("Node %s Ready status: %v\n", workerName, ready)
					return ready
				}, 5*time.Minute, 5*time.Second).Should(BeTrue(),
					"Node %s should become Ready after start", workerName)
			})

			It("verifies deployment is healthy with all replicas", func(ctx context.Context) {
				suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, testNamespace)
				GinkgoWriter.Printf("Deployment %s is healthy after node restart\n", deploymentName)
			})
		})
	})

	Describe("cluster lifecycle", Label("cluster-lifecycle"), func() {
		Context("when stopping and starting the entire cluster", Ordered, func() {
			It("verifies KubeSwitch exists before stopping", func(ctx context.Context) {
				// Only check for Hyper-V nodes where KubeSwitch is used
				if !isHyperVNode {
					Skip("Skipping KubeSwitch check: not a Hyper-V node")
				}
				Expect(kubeSwitchExists(ctx)).To(BeTrue(),
					"KubeSwitch should exist before stopping the cluster")
				GinkgoWriter.Println("KubeSwitch exists before cluster stop")
			})

			It("stops the cluster using k2s stop", func(ctx context.Context) {
				GinkgoWriter.Println("Stopping the entire K2s cluster")

				result := k2s.Stop(ctx)
				result.ExpectSuccess()

				GinkgoWriter.Println("Cluster stop command completed")
			})

			It("verifies KubeSwitch is removed after stopping", func(ctx context.Context) {
				// Only check for Hyper-V nodes where KubeSwitch is used
				if !isHyperVNode {
					Skip("Skipping KubeSwitch check: not a Hyper-V node")
				}
				Expect(kubeSwitchExists(ctx)).To(BeFalse(),
					"KubeSwitch should be removed after stopping the cluster")
				GinkgoWriter.Println("KubeSwitch is removed after cluster stop")
			})

			It("starts the cluster using k2s start", func(ctx context.Context) {
				GinkgoWriter.Println("Starting the K2s cluster")

				result := k2s.Start(ctx)
				result.ExpectSuccess()

				GinkgoWriter.Println("Cluster start command completed")
			})

			It("verifies KubeSwitch is restored after starting", func(ctx context.Context) {
				// Only check for Hyper-V nodes where KubeSwitch is used
				if !isHyperVNode {
					Skip("Skipping KubeSwitch check: not a Hyper-V node")
				}
				Expect(kubeSwitchExists(ctx)).To(BeTrue(),
					"KubeSwitch should be restored after starting the cluster")
				GinkgoWriter.Println("KubeSwitch is restored after cluster start")
			})

			It("verifies all nodes are Ready after cluster restart", func(ctx context.Context) {
				// Get all nodes and verify they are Ready
				Eventually(func() bool {
					client := suite.Cluster().Client()
					clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
					if err != nil {
						GinkgoWriter.Printf("Error creating clientset: %v\n", err)
						return false
					}

					nodes, err := clientSet.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
					if err != nil {
						GinkgoWriter.Printf("Error listing nodes: %v\n", err)
						return false
					}

					if len(nodes.Items) == 0 {
						GinkgoWriter.Println("No nodes found in cluster")
						return false
					}

					allReady := true
					for _, node := range nodes.Items {
						nodeReady := false
						for _, cond := range node.Status.Conditions {
							if cond.Type == corev1.NodeReady {
								nodeReady = cond.Status == corev1.ConditionTrue
								break
							}
						}
						GinkgoWriter.Printf("Node %s Ready: %v\n", node.Name, nodeReady)
						if !nodeReady {
							allReady = false
						}
					}
					return allReady
				}, 10*time.Minute, 10*time.Second).Should(BeTrue(),
					"All nodes should be Ready after cluster restart")

				GinkgoWriter.Println("All nodes are Ready after cluster restart")
			})

			It("verifies the added worker node is Ready", func(ctx context.Context) {
				ready, err := getNodeStatus(ctx, workerName)
				Expect(err).NotTo(HaveOccurred(), "Should be able to get node status for %s", workerName)
				Expect(ready).To(BeTrue(), "Worker node %s should be Ready after cluster restart", workerName)

				GinkgoWriter.Printf("Worker node %s is Ready after cluster restart\n", workerName)
			})
		})
	})
})
