// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package nodehyperv

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

func TestHyperVLinuxNode(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Hyper-V Linux VM Node Acceptance Tests",
		Label("core", "acceptance", "internet-required", "setup-required", "system-running", "node-hyper-v"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(500*time.Millisecond),
		framework.ClusterTestStepTimeout(20*time.Minute))
	k2s = dsl.NewK2s(suite)

	DeferCleanup(suite.TearDown)
})

const (
	// KubeSwitch network CIDR (internal Hyper-V switch for K2s VMs)
	kubeSwitchCIDR = "172.19.1.0/24"
	// KubeSwitch is the name of the Hyper-V switch used by K2s VMs
	kubeSwitchName = "KubeSwitch"
)

// HyperVLinuxNodeInfo holds the details of a local VM node from cluster.json
type HyperVLinuxNodeInfo struct {
	Name      string // Kubernetes node name
	VmName    string // Hyper-V VM name (may differ from Name)
	IpAddress string
	Username  string
	NodeType  clusterconfig.NodeType
}

// nodeJSON is used to parse node entries from cluster.json
type nodeJSON struct {
	Name      string `json:"Name"`
	VmName    string `json:"VmName"` // Hyper-V VM name (may differ from Name)
	IpAddress string `json:"IpAddress"`
	Username  string `json:"Username"`
	NodeType  string `json:"NodeType"`
}

// findHyperVLinuxNode searches cluster.json for a node with NodeType=VM-EXISTING
// and returns its details. Handles both array and single-object formats for nodes.
func findHyperVLinuxNode() (*HyperVLinuxNodeInfo, bool) {
	configDir := suite.SetupInfo().Config.Host().K2sSetupConfigDir()
	clusterJsonPath := filepath.Join(configDir, "cluster.json")

	data, err := os.ReadFile(clusterJsonPath)
	if err != nil {
		GinkgoWriter.Printf("Could not read cluster.json: %v\n", err)
		return nil, false
	}

	// Try to parse nodes as an array first
	var clusterWithArray struct {
		Nodes []nodeJSON `json:"nodes"`
	}
	if err := json.Unmarshal(data, &clusterWithArray); err == nil && len(clusterWithArray.Nodes) > 0 {
		for _, node := range clusterWithArray.Nodes {
			if node.NodeType == string(clusterconfig.NodeTypeVMExisting) {
				// VmName may be empty for older cluster.json files, fallback to Name
				vmName := node.VmName
				if vmName == "" {
					vmName = node.Name
				}
				return &HyperVLinuxNodeInfo{
					Name:      node.Name,
					VmName:    vmName,
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
		if node.NodeType == string(clusterconfig.NodeTypeVMExisting) {
			// VmName may be empty for older cluster.json files, fallback to Name
			vmName := node.VmName
			if vmName == "" {
				vmName = node.Name
			}
			return &HyperVLinuxNodeInfo{
				Name:      node.Name,
				VmName:    vmName,
				IpAddress: node.IpAddress,
				Username:  node.Username,
				NodeType:  clusterconfig.NodeType(node.NodeType),
			}, true
		}
	}

	GinkgoWriter.Println("No VM-EXISTING node found in cluster.json")
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

// isVMReachableViaKubeSwitch verifies that the VM is reachable via the KubeSwitch network
// by testing TCP connectivity to the SSH port. This functionally proves the VM is attached
// to KubeSwitch since the IP is in the KubeSwitch CIDR range.
func isVMReachableViaKubeSwitch(vmIP string) bool {
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:22", vmIP), 5*time.Second)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

// kubeSwitchExists checks if the KubeSwitch virtual switch exists in Hyper-V.
func kubeSwitchExists(ctx context.Context) bool {
	cmd := fmt.Sprintf("(Get-VMSwitch -Name '%s' -ErrorAction SilentlyContinue) -ne $null", kubeSwitchName)
	output := suite.Cli("powershell").NoStdOut().MustExec(ctx, "-Command", cmd)
	return strings.TrimSpace(output) == "True"
}

// isVMConnectedToKubeSwitch checks if a specific VM's network adapter is connected to KubeSwitch.
func isVMConnectedToKubeSwitch(ctx context.Context, vmName string) bool {
	cmd := fmt.Sprintf("(Get-VMNetworkAdapter -VMName '%s' -ErrorAction SilentlyContinue | Where-Object { $_.SwitchName -eq '%s' }) -ne $null", vmName, kubeSwitchName)
	output := suite.Cli("powershell").NoStdOut().MustExec(ctx, "-Command", cmd)
	return strings.TrimSpace(output) == "True"
}

// isVMRunning checks if a Hyper-V VM is in running state.
func isVMRunning(ctx context.Context, vmName string) bool {
	cmd := fmt.Sprintf("(Get-VM -Name '%s' -ErrorAction SilentlyContinue).State -eq 'Running'", vmName)
	output := suite.Cli("powershell").NoStdOut().MustExec(ctx, "-Command", cmd)
	return strings.TrimSpace(output) == "True"
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

// getControlPlaneNodeInternalIP returns the InternalIP of the control-plane node.
func getControlPlaneNodeInternalIP(ctx context.Context) (string, error) {
	client := suite.Cluster().Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	if err != nil {
		return "", err
	}

	controlPlaneNode := getControlPlaneNodeName(ctx)
	node, err := clientSet.CoreV1().Nodes().Get(ctx, controlPlaneNode, metav1.GetOptions{})
	if err != nil {
		return "", err
	}

	for _, addr := range node.Status.Addresses {
		if addr.Type == corev1.NodeInternalIP && strings.TrimSpace(addr.Address) != "" {
			return strings.TrimSpace(addr.Address), nil
		}
	}

	return "", fmt.Errorf("control-plane node %s has no InternalIP", controlPlaneNode)
}

var _ = Describe("Hyper-V Linux VM Node", Ordered, func() {
	var vmIP string
	var nodeName string // Kubernetes node name
	var vmName string   // Hyper-V VM name (may differ from nodeName)
	var vmUsername string
	var vmNodeType clusterconfig.NodeType

	BeforeAll(func() {
		nodeInfo, found := findHyperVLinuxNode()
		if !found {
			Skip("Skipping Hyper-V Linux VM node tests: no VM-EXISTING node found in cluster.json")
		}
		vmIP = nodeInfo.IpAddress
		nodeName = nodeInfo.Name
		vmName = nodeInfo.VmName
		vmUsername = nodeInfo.Username
		vmNodeType = nodeInfo.NodeType

		GinkgoWriter.Printf("Using Hyper-V Linux VM node from cluster.json: nodeName=%s, vmName=%s, ip=%s, username=%s, nodeType=%s\n",
			nodeName, vmName, vmIP, vmUsername, vmNodeType)
	})

	Describe("validate", Label("validate"), func() {
		Context("when reading node configuration from cluster.json", func() {
			It("node type is VM-EXISTING", func() {
				Expect(vmNodeType).To(Equal(clusterconfig.NodeTypeVMExisting),
					"Expected node type to be VM-EXISTING")
			})

			It("IP address is in KubeSwitch range", func() {
				Expect(isIPInCIDR(vmIP, kubeSwitchCIDR)).To(BeTrue(),
					"Expected IP %s to be within KubeSwitch CIDR %s", vmIP, kubeSwitchCIDR)
			})

			It("IP address is a valid IPv4 address", func() {
				ip := net.ParseIP(vmIP)
				Expect(ip).NotTo(BeNil(), "Expected a valid IP address, got: %s", vmIP)
				Expect(ip.To4()).NotTo(BeNil(), "Expected an IPv4 address, got: %s", vmIP)
			})

			It("node name is not empty", func() {
				Expect(vmName).NotTo(BeEmpty(), "Expected node name to be non-empty")
			})

			It("username is set for SSH access", func() {
				Expect(vmUsername).NotTo(BeEmpty(), "Expected username to be non-empty for SSH access")
			})
		})

		Context("when verifying Hyper-V VM configuration", func() {
			It("KubeSwitch virtual switch exists", func(ctx context.Context) {
				Expect(kubeSwitchExists(ctx)).To(BeTrue(),
					"Expected KubeSwitch virtual switch to exist in Hyper-V")
			})

			It("VM is reachable via KubeSwitch network", func() {
				Expect(isVMReachableViaKubeSwitch(vmIP)).To(BeTrue(),
					"Expected VM at %s to be reachable via KubeSwitch (SSH port 22)", vmIP)
			})
		})

		Context("when node is already part of the cluster", func() {
			It("node appears as Ready in the cluster", func(ctx context.Context) {
				suite.Cluster().ExpectNodeToBeReady(nodeName, ctx)
			})
		})
	})

	Describe("node lifecycle", Label("lifecycle"), func() {
		const (
			testNamespace  = "node-lifecycle-test"
			deploymentName = "nginx-lifecycle-test"
			replicas       = 2
		)

		var controlPlaneNode string
		var deploymentTempFile string

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
			k2s.StartNode(ctx, nodeName)

			// Wait for node to be ready again
			Eventually(func() bool {
				ready, _ := getNodeStatus(ctx, nodeName)
				return ready
			}, 5*time.Minute, 5*time.Second).Should(BeTrue(), "Node should be Ready after cleanup start")

			GinkgoWriter.Println("Cleanup: deleting test namespace")
			suite.Kubectl().Exec(ctx, "delete", "namespace", testNamespace, "--ignore-not-found")

			if strings.TrimSpace(deploymentTempFile) != "" {
				err := os.Remove(deploymentTempFile)
				if err != nil && !os.IsNotExist(err) {
					GinkgoWriter.Printf("Cleanup warning: failed to delete temp deployment file %s: %v\n", deploymentTempFile, err)
				}
			}
		})

		Context("when deploying workload across nodes", Ordered, func() {
			It("creates a deployment with replicas spread across nodes", func(ctx context.Context) {
				// Create a deployment that will schedule pods on both control-plane and worker node
				// Using shsk2s.azurecr.io image which is pre-pulled and doesn't require internet
				// tolerationSeconds=30 ensures pods are evicted quickly when node becomes NotReady
				deploymentYaml := fmt.Sprintf(`apiVersion: apps/v1
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

				// Apply the deployment using a temp file written with Go's os.WriteFile
				deploymentTempFile = filepath.Join(suite.SetupInfo().Config.Host().K2sSetupConfigDir(), "deployment.yaml")
				err := os.WriteFile(deploymentTempFile, []byte(deploymentYaml), 0644)
				Expect(err).NotTo(HaveOccurred(), "Failed to write deployment YAML to %s", deploymentTempFile)

				suite.Kubectl().MustExec(ctx, "apply", "-f", deploymentTempFile)

				GinkgoWriter.Printf("Created deployment %s with %d replicas\n", deploymentName, replicas)
			})

			It("waits for deployment to be available", func(ctx context.Context) {
				suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, testNamespace)
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, testNamespace)
				GinkgoWriter.Println("Deployment is available and pods are ready")
			})

			It("verifies pods are scheduled on the worker node", func(ctx context.Context) {
				pods, err := getPodsOnNode(ctx, nodeName, testNamespace)
				Expect(err).NotTo(HaveOccurred())
				Expect(len(pods)).To(BeNumerically(">", 0),
					"Expected at least one pod to be scheduled on worker node %s", nodeName)

				for _, pod := range pods {
					GinkgoWriter.Printf("Pod %s is running on node %s\n", pod.Name, pod.Spec.NodeName)
				}
			})

			It("stops the worker node using k2s stop --node", func(ctx context.Context) {
				GinkgoWriter.Printf("Stopping node %s\n", nodeName)

				result := k2s.StopNode(ctx, nodeName)
				result.ExpectSuccess()

				GinkgoWriter.Printf("Node %s stop command completed\n", nodeName)
			})

			It("verifies worker node becomes NotReady", func(ctx context.Context) {
				Eventually(func() bool {
					ready, err := getNodeStatus(ctx, nodeName)
					if err != nil {
						GinkgoWriter.Printf("Error getting node status: %v\n", err)
						return false // Keep polling on error
					}
					GinkgoWriter.Printf("Node %s Ready status: %v\n", nodeName, ready)
					return !ready // We want NotReady (ready=false)
				}, 5*time.Minute, 5*time.Second).Should(BeTrue(),
					"Node %s should become NotReady after stop", nodeName)
			})

			It("verifies pods on stopped node are terminating or evicted", func(ctx context.Context) {
				// Wait for pods to be marked for deletion (Terminating) or evicted
				// Note: "Terminating" is not a pod phase - it's indicated by DeletionTimestamp being set
				// The pod phase may still show "Running" while terminating
				Eventually(func() bool {
					pods, err := getPodsOnNode(ctx, nodeName, testNamespace)
					if err != nil {
						GinkgoWriter.Printf("Error getting pods: %v\n", err)
						return false
					}

					// If no pods on this node, they've been evicted
					if len(pods) == 0 {
						GinkgoWriter.Printf("No pods remaining on node %s - all evicted\n", nodeName)
						return true
					}

					for _, pod := range pods {
						isTerminating := pod.DeletionTimestamp != nil
						GinkgoWriter.Printf("Pod %s on node %s: phase=%s, terminating=%v\n",
							pod.Name, nodeName, pod.Status.Phase, isTerminating)

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
				GinkgoWriter.Printf("Starting node %s\n", nodeName)

				result := k2s.StartNode(ctx, nodeName)
				result.ExpectSuccess()

				GinkgoWriter.Printf("Node %s start command completed\n", nodeName)
			})

			It("verifies worker node becomes Ready again", func(ctx context.Context) {
				Eventually(func() bool {
					ready, err := getNodeStatus(ctx, nodeName)
					if err != nil {
						GinkgoWriter.Printf("Error getting node status: %v\n", err)
						return false
					}
					GinkgoWriter.Printf("Node %s Ready status: %v\n", nodeName, ready)
					return ready
				}, 5*time.Minute, 5*time.Second).Should(BeTrue(),
					"Node %s should become Ready after start", nodeName)
			})

			It("verifies deployment is healthy with all replicas", func(ctx context.Context) {
				suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, testNamespace)
				GinkgoWriter.Printf("Deployment %s is healthy after node restart\n", deploymentName)
			})
		})
	})

	Describe("cluster lifecycle", Label("cluster-lifecycle"), func() {
		Context("when stopping and starting the entire cluster", Ordered, func() {
			It("stops the cluster using k2s stop", func(ctx context.Context) {
				GinkgoWriter.Println("Stopping the entire K2s cluster")

				result := k2s.Stop(ctx)
				result.ExpectSuccess()

				GinkgoWriter.Println("Cluster stop command completed")
			})

			It("starts the cluster using k2s start", func(ctx context.Context) {
				GinkgoWriter.Println("Starting the K2s cluster")

				result := k2s.Start(ctx)
				result.ExpectSuccess()

				GinkgoWriter.Println("Cluster start command completed")
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
				ready, err := getNodeStatus(ctx, nodeName)
				Expect(err).NotTo(HaveOccurred(), "Should be able to get node status for %s", nodeName)
				Expect(ready).To(BeTrue(), "Worker node %s should be Ready after cluster restart", nodeName)

				GinkgoWriter.Printf("Worker node %s is Ready after cluster restart\n", nodeName)
			})
		})
	})

	Describe("KubeSwitch lifecycle", Label("kubeswitch-lifecycle"), func() {
		const kubemasterVM = "KubeMaster"

		Context("when cluster is running", func() {
			It("KubeSwitch exists", func(ctx context.Context) {
				Expect(kubeSwitchExists(ctx)).To(BeTrue(),
					"KubeSwitch should exist when cluster is running")
				GinkgoWriter.Println("KubeSwitch exists while cluster is running")
			})

			It("KubeMaster VM is connected to KubeSwitch", func(ctx context.Context) {
				Expect(isVMConnectedToKubeSwitch(ctx, kubemasterVM)).To(BeTrue(),
					"KubeMaster VM should be connected to KubeSwitch when cluster is running")
				GinkgoWriter.Println("KubeMaster VM is connected to KubeSwitch")
			})

			It("additional worker VM is connected to KubeSwitch", func(ctx context.Context) {
				Expect(isVMConnectedToKubeSwitch(ctx, vmName)).To(BeTrue(),
					"Worker VM %s should be connected to KubeSwitch when cluster is running", vmName)
				GinkgoWriter.Printf("Worker VM %s is connected to KubeSwitch\n", vmName)
			})
		})

		Context("when stopping cluster without caching vSwitches", Ordered, func() {
			It("stops the cluster using k2s stop", func(ctx context.Context) {
				GinkgoWriter.Println("Stopping cluster (KubeSwitch will be removed)")

				result := k2s.Stop(ctx)
				result.ExpectSuccess()

				GinkgoWriter.Println("Cluster stopped")
			})

			It("KubeSwitch is removed after stop", func(ctx context.Context) {
				// Give some time for cleanup to complete
				time.Sleep(5 * time.Second)

				Expect(kubeSwitchExists(ctx)).To(BeFalse(),
					"KubeSwitch should be removed after k2s stop")
				GinkgoWriter.Println("KubeSwitch was removed after cluster stop")
			})

			It("KubeMaster VM is stopped", func(ctx context.Context) {
				Expect(isVMRunning(ctx, kubemasterVM)).To(BeFalse(),
					"KubeMaster VM should be stopped after k2s stop")
				GinkgoWriter.Println("KubeMaster VM is stopped")
			})

			It("starts the cluster using k2s start", func(ctx context.Context) {
				GinkgoWriter.Println("Starting cluster (KubeSwitch will be recreated)")

				result := k2s.Start(ctx)
				result.ExpectSuccess()

				GinkgoWriter.Println("Cluster started")
			})

			It("KubeSwitch is recreated after start", func(ctx context.Context) {
				Expect(kubeSwitchExists(ctx)).To(BeTrue(),
					"KubeSwitch should be recreated after k2s start")
				GinkgoWriter.Println("KubeSwitch was recreated after cluster start")
			})

			It("KubeMaster VM is running and connected to KubeSwitch", func(ctx context.Context) {
				Expect(isVMRunning(ctx, kubemasterVM)).To(BeTrue(),
					"KubeMaster VM should be running after k2s start")
				Expect(isVMConnectedToKubeSwitch(ctx, kubemasterVM)).To(BeTrue(),
					"KubeMaster VM should be connected to KubeSwitch after k2s start")
				GinkgoWriter.Println("KubeMaster VM is running and connected to KubeSwitch")
			})

			It("additional worker VM is running and connected to KubeSwitch", func(ctx context.Context) {
				Expect(isVMRunning(ctx, vmName)).To(BeTrue(),
					"Worker VM %s should be running after k2s start", vmName)
				Expect(isVMConnectedToKubeSwitch(ctx, vmName)).To(BeTrue(),
					"Worker VM %s should be connected to KubeSwitch after k2s start", vmName)
				GinkgoWriter.Printf("Worker VM %s is running and connected to KubeSwitch\n", vmName)
			})

			It("all nodes become Ready after start", func(ctx context.Context) {
				Eventually(func() bool {
					client := suite.Cluster().Client()
					clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
					if err != nil {
						return false
					}

					nodes, err := clientSet.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
					if err != nil {
						return false
					}

					for _, node := range nodes.Items {
						nodeReady := false
						for _, cond := range node.Status.Conditions {
							if cond.Type == corev1.NodeReady {
								nodeReady = cond.Status == corev1.ConditionTrue
								break
							}
						}
						if !nodeReady {
							GinkgoWriter.Printf("Node %s is not yet Ready\n", node.Name)
							return false
						}
					}
					return true
				}, 10*time.Minute, 10*time.Second).Should(BeTrue(),
					"All nodes should become Ready after cluster start")

				GinkgoWriter.Println("All nodes are Ready after KubeSwitch lifecycle test")
			})
		})

		Context("when VM is reachable via KubeSwitch after restart", func() {
			It("KubeMaster is reachable via SSH", func(ctx context.Context) {
				kubemasterIP, err := getControlPlaneNodeInternalIP(ctx)
				Expect(err).NotTo(HaveOccurred(), "Expected to resolve control-plane InternalIP")
				GinkgoWriter.Printf("Resolved KubeMaster/control-plane IP: %s\n", kubemasterIP)
				Eventually(func() bool {
					conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:22", kubemasterIP), 5*time.Second)
					if err != nil {
						GinkgoWriter.Printf("KubeMaster SSH not reachable yet: %v\n", err)
						return false
					}
					conn.Close()
					return true
				}, 2*time.Minute, 5*time.Second).Should(BeTrue(),
					"KubeMaster should be reachable via SSH through KubeSwitch")
				GinkgoWriter.Println("KubeMaster is reachable via SSH through KubeSwitch")
			})

			It("additional worker node is reachable via SSH", func(ctx context.Context) {
				Eventually(func() bool {
					conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:22", vmIP), 5*time.Second)
					if err != nil {
						GinkgoWriter.Printf("Worker VM SSH not reachable yet: %v\n", err)
						return false
					}
					conn.Close()
					return true
				}, 2*time.Minute, 5*time.Second).Should(BeTrue(),
					"Worker VM %s should be reachable via SSH through KubeSwitch", vmName)
				GinkgoWriter.Printf("Worker VM %s is reachable via SSH through KubeSwitch\n", vmName)
			})
		})
	})

	Describe("Worker node lifecycle", Label("worker-node-lifecycle"), func() {
		Context("when stopping and starting individual worker node", Ordered, func() {
			It("worker node is initially Ready", func(ctx context.Context) {
				ready, err := getNodeStatus(ctx, nodeName)
				Expect(err).NotTo(HaveOccurred(), "Should be able to get node status for %s", nodeName)
				Expect(ready).To(BeTrue(), "Worker node %s should be Ready initially", nodeName)
				GinkgoWriter.Printf("Worker node %s is Ready initially\n", nodeName)
			})

			It("stops the worker node using k2s stop --node", func(ctx context.Context) {
				GinkgoWriter.Printf("Stopping worker node %s\n", nodeName)

				result := k2s.StopNode(ctx, nodeName)
				result.ExpectSuccess()

				GinkgoWriter.Printf("Worker node %s stop command completed\n", nodeName)
			})

			It("worker node becomes NotReady after stop", func(ctx context.Context) {
				// For VM-EXISTING nodes, k2s stop --node may not stop the actual VM,
				// but the Kubernetes node should become NotReady
				Eventually(func() bool {
					ready, err := getNodeStatus(ctx, nodeName)
					if err != nil {
						GinkgoWriter.Printf("Error getting node status: %v\n", err)
						return false
					}
					GinkgoWriter.Printf("Node %s Ready status: %v\n", nodeName, ready)
					return !ready
				}, 5*time.Minute, 5*time.Second).Should(BeTrue(),
					"Node %s should become NotReady after stop", nodeName)
				GinkgoWriter.Printf("Worker node %s is NotReady after stop\n", nodeName)
			})

			It("starts the worker node using k2s start --node", func(ctx context.Context) {
				GinkgoWriter.Printf("Starting worker node %s\n", nodeName)

				result := k2s.StartNode(ctx, nodeName)
				result.ExpectSuccess()

				GinkgoWriter.Printf("Worker node %s start command completed\n", nodeName)
			})

			It("worker node becomes Ready after start", func(ctx context.Context) {
				Eventually(func() bool {
					ready, err := getNodeStatus(ctx, nodeName)
					if err != nil {
						GinkgoWriter.Printf("Error getting node status: %v\n", err)
						return false
					}
					GinkgoWriter.Printf("Node %s Ready status: %v\n", nodeName, ready)
					return ready
				}, 5*time.Minute, 5*time.Second).Should(BeTrue(),
					"Node %s should become Ready after start", nodeName)
				GinkgoWriter.Printf("Worker node %s is Ready after start\n", nodeName)
			})

			It("worker node is reachable via SSH after start", func(ctx context.Context) {
				Eventually(func() bool {
					conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:22", vmIP), 5*time.Second)
					if err != nil {
						GinkgoWriter.Printf("Worker VM SSH not reachable yet: %v\n", err)
						return false
					}
					conn.Close()
					return true
				}, 2*time.Minute, 5*time.Second).Should(BeTrue(),
					"Worker VM %s should be reachable via SSH after start", vmName)
				GinkgoWriter.Printf("Worker VM %s is reachable via SSH after start\n", vmName)
			})
		})
	})
})
