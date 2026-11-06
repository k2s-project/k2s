// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package node

import (
	"bytes"
	"context"
	"fmt"
	"html/template"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	kos "github.com/k2s-project/k2s/internal/os"

	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"
	v1 "k8s.io/api/core/v1"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	namespace     = "k2s"
	linux         = "linux"
	windows       = "windows"
	baseDeployDir = "overlays"
	curlMaxTime   = "180"
	curlConnTime  = "30"
)

var suite *framework.K2sTestSuite
var k2s *dsl.K2s

var linuxNodes []string
var windowsNodes []string
var deployments []DeploymentData
var testFailed = false

type DeploymentData struct {
	DeploymentName string
	AppName        string
	ContainerName  string
	Image          string
	NodeName       string
	OS             string
}

func TestClusterCore(t *testing.T) {
	os.Setenv("SYSTEM_TEST_TIMEOUT", "20m")
	RegisterFailHandler(Fail)
	RunSpecs(t, "Cluster Nodes Core Acceptance Tests", Label("core", "acceptance", "internet-required", "setup-required", "system-running", "node-sanity"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(
		ctx,
		framework.ClusterTestStepTimeout(time.Minute*10),
		framework.ClusterTestStepPollInterval(time.Millisecond*200),
	)
	k2s = dsl.NewK2s(suite)

	suite.SetupInfo().LoadClusterConfig()
	GinkgoWriter.Println("Getting available nodes on cluster..")

	linuxNodes = getNodes(ctx, linux)
	windowsNodes = getNodes(ctx, windows)

	GinkgoWriter.Println("Found Linux nodes:", linuxNodes, len(linuxNodes))
	GinkgoWriter.Println("Found Windows nodes:", windowsNodes, len(windowsNodes))

	// Wait for all nodes to be Ready before deploying workloads
	GinkgoWriter.Println("Waiting for all nodes to be in Ready state...")
	for _, node := range linuxNodes {
		suite.Cluster().WaitForNodeToBeReady(node, ctx)
	}
	for _, node := range windowsNodes {
		suite.Cluster().WaitForNodeToBeReady(node, ctx)
	}
	GinkgoWriter.Println("All nodes are Ready")

	linuxImage := "shsk2s.azurecr.io/example.albums-golang-linux:v1.0.0"
	windowsImage := "shsk2s.azurecr.io/example.albums-golang-win:v1.0.0"

	// Generate and apply deployments for Linux and Windows
	generateDeployments("overlays/linux", linuxNodes, linuxImage, linux)
	generateDeployments("overlays/windows", windowsNodes, windowsImage, windows)

	applyDeployments(ctx)

	GinkgoWriter.Println("Deployments ready for testing")
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	if suite.ShouldCleanup(testFailed) {
		GinkgoWriter.Println("Deleting workloads..")

		deleteDeployments(ctx)

		GinkgoWriter.Println("Workloads deleted")

		if err := os.RemoveAll(baseDeployDir); err != nil {
			panic(err)
		}

		suite.TearDown(ctx, framework.RestartKubeProxy)
	}
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("Node Communication Core", func() {
	systemNamespace := "kube-system"

	Describe("Basic Components", func() {
		Describe("System Nodes", func() {
			It("All available nodes are in Ready state", func(ctx SpecContext) {

				for _, node := range linuxNodes {
					suite.Cluster().ExpectNodeToBeReady(node, ctx)
				}

				for _, node := range windowsNodes {
					suite.Cluster().ExpectNodeToBeReady(node, ctx)
				}
			})

			It("control-plane node reports Debian 13 osImage", func(ctx SpecContext) {
				controlPlaneNode := getControlPlaneNode(ctx)
				if controlPlaneNode == "" {
					Skip("No control-plane node found")
				}

				osImage := strings.TrimSpace(suite.Kubectl().MustExec(
					ctx,
					"get", "node", controlPlaneNode,
					"-o", "jsonpath={.status.nodeInfo.osImage}",
				))

				Expect(osImage).To(ContainSubstring("Debian GNU/Linux 13"),
					"control-plane node %s should run Debian 13, actual osImage=%q", controlPlaneNode, osImage)
			})
		})

		Describe("System Deployments", func() {
			It("coredns is available", func() {
				suite.Cluster().ExpectDeploymentToBeAvailable("coredns", systemNamespace)
			})
		})

		DescribeTable("System Pods", func(podName string) {
			suite.Cluster().ExpectPodToBeReady(podName, systemNamespace, suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname())
		},
			Entry("etcd-HOSTNAME_PLACEHOLDER is available", "etcd-HOSTNAME_PLACEHOLDER"),
			Entry("kube-scheduler-HOSTNAME_PLACEHOLDER is available", "kube-scheduler-HOSTNAME_PLACEHOLDER"),
			Entry("kube-apiserver-HOSTNAME_PLACEHOLDER is available", "kube-apiserver-HOSTNAME_PLACEHOLDER"),
			Entry("kube-controller-manager-HOSTNAME_PLACEHOLDER is available", "kube-controller-manager-HOSTNAME_PLACEHOLDER"))
	})

	Describe("Communication", func() {
		It("Deployments Availability", func() {
			deploymentNames := getDeploymentNames()
			for _, v := range deploymentNames {
				suite.Cluster().ExpectDeploymentToBeAvailable(v, namespace)
			}
		})

		It("Deployment Reachable from Host", func(ctx context.Context) {
			deploymentNames := getDeploymentNames()
			for _, name := range deploymentNames {
				k2s.VerifyDeploymentToBeReachableFromHost(ctx, name, namespace)
			}
		})

		Describe("Linux/Windows Pods Communication within Nodes", func() {

			It("Pod Communication within Nodes", func(ctx SpecContext) {

				linuxPods := suite.Cluster().GetPodsGroupedByNode(ctx, namespace, linuxNodes)
				windowsPods := suite.Cluster().GetPodsGroupedByNode(ctx, namespace, windowsNodes)

				By("Testing pod-to-pod communication within Linux nodes")
				testPodCommunicationWithinNodes(ctx, linuxPods, "curl-sidecar")

				By("Testing pod-to-pod communication within Windows nodes")
				testPodCommunicationWithinNodes(ctx, windowsPods, "")
			})
		})

		Describe("Linux/Windows Pods Communication Across Nodes", func() {

			It("Pod Communication Across Nodes", func(ctx SpecContext) {

				linuxPods := suite.Cluster().GetPodsGroupedByNode(ctx, namespace, linuxNodes)
				windowsPods := suite.Cluster().GetPodsGroupedByNode(ctx, namespace, windowsNodes)

				By("Testing pod-to-pod communication across Linux and Windows nodes")
				testPodCommunicationAcrossNodes(ctx, linuxPods, windowsPods, "curl-sidecar")
			})
		})

		Describe("Linux ControlPlane/Worker Communication Matrix", func() {

			It("Master and Linux workers can communicate with each other in both directions", func(ctx SpecContext) {
				if len(linuxNodes) < 2 {
					Skip("Not enough Linux nodes")
				}

				linuxPodsByNode := suite.Cluster().GetPodsGroupedByNode(ctx, namespace, linuxNodes)

				controlPlaneNode := getControlPlaneNode(ctx)
				if controlPlaneNode == "" {
					controlPlaneNode = suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname()
				}

				masterLinuxPod, ok := getFirstPodOnNode(linuxPodsByNode, controlPlaneNode)
				if !ok {
					Skip(fmt.Sprintf("No Linux pod found on control-plane node %q", controlPlaneNode))
				}

				linuxWorkerPods := getFirstPodsExcludingNode(linuxPodsByNode, controlPlaneNode)
				if len(linuxWorkerPods) == 0 {
					Skip("No Linux worker pods found")
				}

				By("Master Linux pod -> each Linux worker service")
				for _, workerPod := range linuxWorkerPods {
					checkCommunication(ctx, masterLinuxPod, workerPod, "curl-sidecar")
				}

				By("Each Linux worker pod -> master Linux service")
				for _, workerPod := range linuxWorkerPods {
					checkCommunication(ctx, workerPod, masterLinuxPod, "curl-sidecar")
				}

				By("Each Linux worker pod -> every other Linux worker service")
				for i := 0; i < len(linuxWorkerPods); i++ {
					for j := i + 1; j < len(linuxWorkerPods); j++ {
						checkCommunication(ctx, linuxWorkerPods[i], linuxWorkerPods[j], "curl-sidecar")
						checkCommunication(ctx, linuxWorkerPods[j], linuxWorkerPods[i], "curl-sidecar")
					}
				}
			})
		})

		Describe("Internet Access from Linux/Windows Pods from all Nodes", func() {

			It("Internet Communication from Nodes", func(ctx SpecContext) {

				if suite.IsOfflineMode() {
					Skip("Offline-Mode")
				}

				linuxPods := suite.Cluster().GetPodsGroupedByNode(ctx, namespace, linuxNodes)
				windowsPods := suite.Cluster().GetPodsGroupedByNode(ctx, namespace, windowsNodes)

				By("Testing Internet Communication from Linux nodes")
				testInternetCommunication(ctx, linuxPods, "curl-sidecar")

				By("Testing Internet Communication from Windows nodes")
				testInternetCommunication(ctx, windowsPods, "")
			})
		})

	})
})

func applyDeployments(ctx context.Context) {
	command := fmt.Sprintf("%s create ns %s --dry-run=client -o yaml | kubectl apply -f -", suite.Kubectl().Path(), namespace)
	suite.Cli("cmd.exe").MustExec(ctx, "/c", command)

	overlayLinuxDir, overlayWinDir, linuxDirs, winDirs := getDeploymentDirs()

	executeDeployment(ctx, linuxDirs, overlayLinuxDir, "apply")
	executeDeployment(ctx, winDirs, overlayWinDir, "apply")

	GinkgoWriter.Println("Waiting for Deployments to be ready in namespace <", namespace, ">..")

	for _, data := range deployments {
		GinkgoWriter.Println("Waiting for deployment availability and pod readiness for <", data.DeploymentName, ">")
		suite.Cluster().ExpectDeploymentToBeAvailable(data.DeploymentName, namespace)
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", data.DeploymentName, namespace)
	}
}

func deleteDeployments(ctx context.Context) {
	overlayLinuxDir, overlayWinDir, linuxDirs, winDirs := getDeploymentDirs()

	executeDeployment(ctx, linuxDirs, overlayLinuxDir, "delete")
	executeDeployment(ctx, winDirs, overlayWinDir, "delete")

	suite.Kubectl().MustExec(ctx, "delete", "ns", namespace)
}

func getNodes(ctx context.Context, osType string) []string {
	output := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", fmt.Sprintf("kubernetes.io/os=%s", osType), "-o", "jsonpath={range .items[*]}{.metadata.name}{'\\n'}{end}")
	output = strings.TrimSpace(output)

	if output == "" {
		return []string{}
	}
	return strings.Split(output, "\n")
}

func generateDeployments(outputDir string, nodes []string, image string, osType string) {
	if len(nodes) == 0 {
		GinkgoWriter.Println("No nodes found for OsType:", osType)
		return
	}

	tmpl := `
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .DeploymentName }}
  namespace: k2s
spec:
  selector:
    matchLabels:
      app: {{ .AppName }}
  replicas: 1
  template:
    metadata:
      labels:
        app: {{ .AppName }}
    spec:
      containers:
        - name: {{ .ContainerName }}
          image: {{ .Image }}
          ports:
            - containerPort: 80
          env:
            - name: PORT
              value: "80"
            - name: RESOURCE
              value: "{{ .AppName }}"
        {{ if eq .OS "linux" -}}
        - name: curl-sidecar
          image: docker.io/curlimages/curl:8.5.0
          command: ["sleep", "infinity"]
        {{- end }}
      nodeSelector:
        kubernetes.io/os: {{ .OS }}
        kubernetes.io/hostname: {{ .NodeName }}
      {{ if eq .OS "windows" -}}
      tolerations:
        - key: "OS"
          operator: "Equal"
          value: "Windows"
          effect: "NoSchedule"
      {{- end }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ .AppName }}
  namespace: k2s
spec:
  selector:
    app: {{ .AppName }}
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
`

	t, err := template.New("deployment").Parse(tmpl)
	if err != nil {
		panic(err)
	}

	if err := os.MkdirAll(outputDir, 0755); err != nil {
		panic(err)
	}

	for _, node := range nodes {
		overlayDir := filepath.Join(outputDir, node)
		if err := os.MkdirAll(overlayDir, 0755); err != nil {
			panic(err)
		}

		var resourcePaths []string
		for i := 1; i <= 1; i++ {
			data := DeploymentData{
				DeploymentName: fmt.Sprintf("%s%d", node, i),
				AppName:        fmt.Sprintf("%s%d", node, i),
				ContainerName:  fmt.Sprintf("%s-ctr-%d", node, i),
				Image:          image,
				NodeName:       node,
				OS:             osType,
			}
			deployments = append(deployments, data)

			var buf bytes.Buffer
			if err := t.Execute(&buf, data); err != nil {
				panic(err)
			}

			filePath := filepath.Join(overlayDir, fmt.Sprintf("%s.yaml", data.DeploymentName))
			if err := os.WriteFile(filePath, buf.Bytes(), 0644); err != nil {
				panic(err)
			}
			GinkgoWriter.Println("Generated deployment for node <", node, "> File <", filePath, ">")
			resourcePaths = append(resourcePaths, filepath.Base(filePath))
		}

		kustomizeContent := "resources:\n"
		for _, resource := range resourcePaths {
			kustomizeContent += fmt.Sprintf("- %s\n", resource)
		}
		kustomizePath := filepath.Join(overlayDir, "kustomization.yaml")
		if err := os.WriteFile(kustomizePath, []byte(kustomizeContent), 0644); err != nil {
			Expect(err).To(nil)
		}
		GinkgoWriter.Println("Generated kustomization.yaml for node <", node, "> File <", kustomizePath, ">")
	}
}

func getDeploymentDirs() (string, string, []fs.DirEntry, []fs.DirEntry) {
	overlayLinuxDir := filepath.Join(baseDeployDir, "linux")
	overlayWinDir := filepath.Join(baseDeployDir, "windows")

	var err error
	linuxDirs := []fs.DirEntry{}
	winDirs := []fs.DirEntry{}

	if kos.PathExists(overlayLinuxDir) {
		linuxDirs, err = os.ReadDir(overlayLinuxDir)
		if err != nil {
			Fail(fmt.Sprintf("Unable to read linux base deployment directory: %s", err))
		}
	}

	if kos.PathExists(overlayWinDir) {
		winDirs, err = os.ReadDir(overlayWinDir)
		if err != nil {
			Fail(fmt.Sprintf("Unable to read windows base deployment directory: %s", err))
		}
	}

	return overlayLinuxDir, overlayWinDir, linuxDirs, winDirs
}

func executeDeployment(ctx context.Context, dirs []fs.DirEntry, overlayDir string, operation string) {
	GinkgoWriter.Println("Directories", dirs)
	for _, dir := range dirs {
		if dir.IsDir() {
			suite.Kubectl().MustExec(ctx, operation, "-k", fmt.Sprintf("%s/%s", overlayDir, dir.Name()))
			GinkgoWriter.Println("Performed operation", operation, "in ", dir.Name())
		}
	}
}

func testInternetCommunication(ctx context.Context, podsByNode map[string][]v1.Pod, sidecarName string) {
	for node, pods := range podsByNode {
		if len(pods) < 1 {
			By(fmt.Sprintf("Skipping node %s due to insufficient pods", node))
			continue
		}

		By(fmt.Sprintf("Testing internet communication from node %s", node))
		for i := 0; i < len(pods)-1; i++ {
			checkInternetCommunication(ctx, pods[i], sidecarName)
		}
	}
}

func testPodCommunicationWithinNodes(ctx context.Context, podsByNode map[string][]v1.Pod, sidecarName string) {
	for node, pods := range podsByNode {
		if len(pods) < 2 {
			By(fmt.Sprintf("Skipping node %s due to insufficient pods", node))
			continue
		}

		By(fmt.Sprintf("Testing communication within node %s", node))
		for i := 0; i < len(pods)-1; i++ {
			checkCommunication(ctx, pods[i], pods[i+1], sidecarName)
			checkCommunication(ctx, pods[i+1], pods[i], sidecarName)
		}
	}
}

func testPodCommunicationAcrossNodes(ctx context.Context, linuxPods, windowsPods map[string][]v1.Pod, sidecarName string) {
	By("Testing communication between Linux and Windows nodes")
	for _, lPods := range linuxPods {
		for _, wPods := range windowsPods {
			if len(lPods) > 0 && len(wPods) > 0 {
				checkCommunication(ctx, lPods[0], wPods[0], sidecarName)
				checkCommunication(ctx, wPods[0], lPods[0], "")
			}
		}
	}

	By("Testing communication across Linux nodes")
	testInterNodeCommunication(ctx, linuxPods, sidecarName)

	By("Testing communication across Windows nodes")
	testInterNodeCommunication(ctx, windowsPods, "")
}

func testInterNodeCommunication(ctx context.Context, podsByNode map[string][]v1.Pod, sidecarName string) {
	nodes := make([]string, 0, len(podsByNode))
	for node := range podsByNode {
		nodes = append(nodes, node)
	}

	for i := 0; i < len(nodes)-1; i++ {
		node1, node2 := nodes[i], nodes[i+1]
		if len(podsByNode[node1]) > 0 && len(podsByNode[node2]) > 0 {
			checkCommunication(ctx, podsByNode[node1][0], podsByNode[node2][0], sidecarName)
			checkCommunication(ctx, podsByNode[node2][0], podsByNode[node1][0], sidecarName)
		}
	}
}

func checkCommunication(ctx context.Context, sourcePod, targetPod v1.Pod, sidecarName string) {
	By(fmt.Sprintf("Checking communication from pod %s (node: %s) to pod %s (node: %s)", sourcePod.Name, sourcePod.Spec.NodeName, targetPod.Name, targetPod.Spec.NodeName))

	probePassed := false
	DeferCleanup(func() {
		if !probePassed {
			collectNodeCommunicationDiagnostics(sourcePod, targetPod, sidecarName)
		}
	})
	app := targetPod.Labels["app"]
	args := podCommandArgs(sourcePod.Name, sidecarName, "curl", "-sS", "-i",
		"--connect-timeout", curlConnTime, "--max-time", curlMaxTime,
		fmt.Sprintf("http://%s.%s.svc.cluster.local/%s", app, namespace, app))
	output := suite.Kubectl().MustExec(ctx, args...)
	Expect(strings.TrimSpace(output)).To(ContainSubstring("200"), "Unexpected response")
	probePassed = true
}

func checkInternetCommunication(ctx context.Context, pod v1.Pod, sidecarName string) {
	proxy := suite.SetupInfo().GetProxyForNode(pod.Spec.NodeName)

	By(fmt.Sprintf("Checking Internet communication from pod %s (node: %s) (proxy: %s)", pod.Name, pod.Spec.NodeName, proxy))

	command := ""
	if sidecarName != "" {
		// For Linux, use curl-sidecar
		command = fmt.Sprintf("%s exec %s -n %s -c %s -- curl -si --insecure --connect-timeout %s --max-time %s -x %s www.msftconnecttest.com/connecttest.txt", suite.Kubectl().Path(), pod.Name, namespace, sidecarName, curlConnTime, curlMaxTime, proxy)
	} else {
		// For Windows, use the main container
		command = fmt.Sprintf("%s exec %s -n %s -- curl -si --insecure --connect-timeout %s --max-time %s -x %s www.msftconnecttest.com/connecttest.txt", suite.Kubectl().Path(), pod.Name, namespace, curlConnTime, curlMaxTime, proxy)
	}

	output := suite.Cli("cmd.exe").MustExec(ctx, "/c", command)
	Expect(strings.TrimSpace(output)).To(ContainSubstring("200"), "Unexpected response")
}

func getDeploymentNames() []string {
	var names []string
	for _, deployment := range deployments {
		names = append(names, deployment.DeploymentName)
	}
	return names
}

func getControlPlaneNode(ctx context.Context) string {
	output := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "node-role.kubernetes.io/control-plane", "-o", "jsonpath={range .items[*]}{.metadata.name}{'\\n'}{end}")
	output = strings.TrimSpace(output)
	if output != "" {
		return strings.Split(output, "\n")[0]
	}

	output = suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "node-role.kubernetes.io/master", "-o", "jsonpath={range .items[*]}{.metadata.name}{'\\n'}{end}")
	output = strings.TrimSpace(output)
	if output != "" {
		return strings.Split(output, "\n")[0]
	}

	return ""
}

func getFirstPodOnNode(podsByNode map[string][]v1.Pod, nodeName string) (v1.Pod, bool) {
	pods, ok := podsByNode[nodeName]
	if ok && len(pods) > 0 {
		return pods[0], true
	}

	for node, nodePods := range podsByNode {
		if strings.EqualFold(node, nodeName) && len(nodePods) > 0 {
			return nodePods[0], true
		}
	}

	return v1.Pod{}, false
}

func getFirstPodsExcludingNode(podsByNode map[string][]v1.Pod, excludedNode string) []v1.Pod {
	result := []v1.Pod{}
	for node, pods := range podsByNode {
		if strings.EqualFold(node, excludedNode) {
			continue
		}
		if len(pods) > 0 {
			result = append(result, pods[0])
		}
	}

	return result
}
