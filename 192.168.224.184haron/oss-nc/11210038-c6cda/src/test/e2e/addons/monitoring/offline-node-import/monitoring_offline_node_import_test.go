// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package monitoringofflinenodeimport

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"

	"github.com/k2s-project/k2s/internal/core/addons"
	"github.com/k2s-project/k2s/internal/core/clusterconfig"
	"github.com/k2s-project/k2s/test/e2e/addons/exportimport"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const offlineNodeImportTimeout = 30 * time.Minute

var (
	suite                  *framework.K2sTestSuite
	k2s                    *dsl.K2s
	monitoringImpl         *addons.Implementation
	exportPath             string
	exportedOciFile        string
	controlPlaneIpAddress  string
	controlPlaneNodeName   string
	linuxWorkers           []corev1.Node
	windowsExporterTargets []string
	importTargetNodeNames  []string
	restoreProxy           func()
	monitoringEnableTried  bool
	testFailed             bool
)

func TestMonitoringOfflineNodeImport(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Monitoring Offline Linux Node Import E2E", Label("addon", "acceptance", "air-gapped", "export-import", "setup-required", "system-running", "node-images-import"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(offlineNodeImportTimeout))
	k2s = dsl.NewK2s(suite)
	controlPlaneIpAddress = suite.SetupInfo().Config.ControlPlane().IpAddress()
	exportPath = filepath.Join(suite.RootDir(), "tmp", "monitoring-offline-node-import")

	monitoringAddon := exportimport.GetAddonByName(suite.AddonsAdditionalInfo().AllAddons(), "monitoring")
	Expect(monitoringAddon).NotTo(BeNil(), "monitoring addon should exist")
	monitoringImpl = exportimport.GetImplementation(monitoringAddon, "monitoring")
	Expect(monitoringImpl).NotTo(BeNil(), "monitoring implementation should exist")

	var nodeList corev1.NodeList
	nodesJSON := suite.Kubectl().MustExec(ctx, "get", "nodes", "-o", "json")
	Expect(json.Unmarshal([]byte(nodesJSON), &nodeList)).To(Succeed(), "cluster nodes should be valid Kubernetes JSON")

	for _, node := range nodeList.Items {
		if node.Labels[corev1.LabelOSStable] == "linux" {
			if hasControlPlaneRole(node) || nodeHasInternalIP(node, controlPlaneIpAddress) {
				controlPlaneNodeName = node.Name
				continue
			}
			linuxWorkers = append(linuxWorkers, node)
		}
	}
	Expect(controlPlaneNodeName).NotTo(BeEmpty(), "the configured control plane should be discoverable in the Kubernetes node list")
	Expect(linuxWorkers).NotTo(BeEmpty(), "at least one added Linux worker should be discovered dynamically")

	importTargetNodeNames = append(importTargetNodeNames, controlPlaneNodeName)
	for _, worker := range linuxWorkers {
		Expect(internalIP(worker)).NotTo(BeEmpty(), "Linux worker %s should have an InternalIP", worker.Name)
		importTargetNodeNames = append(importTargetNodeNames, worker.Name)
	}

	if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() && hasWindowsExporterImage(monitoringImpl) {
		for _, node := range nodeList.Items {
			if node.Labels[corev1.LabelOSStable] == "windows" && strings.EqualFold(node.Name, suite.SetupInfo().WinNodeName) && isNodeReady(node) {
				windowsExporterTargets = append(windowsExporterTargets, node.Name)
				importTargetNodeNames = append(importTargetNodeNames, node.Name)
			}
		}
	}

	GinkgoWriter.Printf("Discovered control-plane target %q and Linux worker targets %v\n", controlPlaneNodeName, nodeNames(linuxWorkers))
	GinkgoWriter.Printf("Windows exporter targets (when supported and Ready): %v\n", windowsExporterTargets)
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	if suite.ShouldCleanup(testFailed) {
		if monitoringEnableTried {
			suite.K2sCli().Exec(ctx, "addons", "disable", "monitoring", "-o")
		}
		if restoreProxy != nil {
			restoreProxy()
		}
		exportimport.CleanupExportedFiles(exportPath, exportedOciFile)
		suite.TearDown(ctx)
	} else if restoreProxy != nil {
		restoreProxy()
	}
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = It("imports monitoring images onto added Linux workers and enables their exporters while air-gapped", func(ctx context.Context) {
	exportimport.CleanupExportedFiles(exportPath, "")
	exportedOciFile = exportimport.ExportAddon(ctx, suite, "monitoring", "", exportPath)

	exportimport.CleanAddonResources(ctx, suite, k2s, monitoringImpl, controlPlaneIpAddress)
	exportimport.VerifyResourcesCleanedUp(ctx, suite, k2s, monitoringImpl, controlPlaneIpAddress)
	restoreProxy = exportimport.PrepareAirGappedAddonImport(ctx, suite, controlPlaneIpAddress)

	suite.K2sCli().MustExec(ctx, "addons", "import", "-f", exportedOciFile, "--nodes", strings.Join(importTargetNodeNames, ","))
	expectMonitoringImageOnLinuxWorkers(ctx)

	monitoringEnableTried = true
	suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "-o")
	suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-kube-state-metrics", "monitoring")
	suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
	suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
	suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")

	workerNames := nodeNames(linuxWorkers)
	Eventually(func() []string {
		return workersWithoutReadyNodeExporter(ctx, workerNames)
	}).WithContext(ctx).WithTimeout(offlineNodeImportTimeout).WithPolling(5*time.Second).Should(BeEmpty(), "node-exporter should be Ready on every added Linux worker")

	if len(windowsExporterTargets) > 0 {
		Eventually(func() []string {
			return windowsTargetsWithoutReadyExporter(ctx, windowsExporterTargets)
		}).WithContext(ctx).WithTimeout(offlineNodeImportTimeout).WithPolling(5*time.Second).Should(BeEmpty(), "windows-exporter should be Ready on the targeted local Windows node")
	}
})

func expectMonitoringImageOnLinuxWorkers(ctx context.Context) {
	images, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(*monitoringImpl)
	Expect(err).NotTo(HaveOccurred(), "monitoring images should be collected from its implementation")

	var nodeExporterImage string
	for _, image := range images {
		if strings.Contains(image, "prometheus/node-exporter") {
			nodeExporterImage = image
			break
		}
	}
	Expect(nodeExporterImage).NotTo(BeEmpty(), "monitoring implementation should declare the Linux node-exporter image")

	for _, worker := range linuxWorkers {
		command := fmt.Sprintf("sudo crictl images --output json | grep -Fq -- '%s'", strings.ReplaceAll(nodeExporterImage, "'", "'\\''"))
		GinkgoWriter.Printf("Checking CRI-O image %q on Linux worker %q (%s)\n", nodeExporterImage, worker.Name, internalIP(worker))
		suite.K2sCli().MustExec(ctx, "node", "exec", "-i", internalIP(worker), "-u", linuxWorkerUsername(worker), "-c", command, "-o")
	}
}

func linuxWorkerUsername(worker corev1.Node) string {
	clusterCfg, err := clusterconfig.Read(suite.SetupInfo().Config.Host().K2sSetupConfigDir())
	Expect(err).NotTo(HaveOccurred(), "cluster configuration should be readable")
	Expect(clusterCfg).NotTo(BeNil(), "cluster configuration should exist")

	workerIP := internalIP(worker)
	for _, configuredNode := range clusterCfg.Nodes {
		if configuredNode.Role == clusterconfig.RoleWorker && configuredNode.IpAddress == workerIP {
			Expect(configuredNode.Username).NotTo(BeEmpty(), "worker %s should have a configured SSH username", worker.Name)
			return configuredNode.Username
		}
	}

	Fail(fmt.Sprintf("Linux worker %s (%s) is missing from cluster configuration", worker.Name, workerIP))
	return ""
}

func workersWithoutReadyNodeExporter(ctx context.Context, workers []string) []string {
	podsByNode := suite.Cluster().GetPodsGroupedByNode(ctx, "monitoring", workers)
	var unready []string
	for _, worker := range workers {
		ready := false
		for _, pod := range podsByNode[worker] {
			if pod.Labels["app.kubernetes.io/name"] == "prometheus-node-exporter" && isPodReady(pod) {
				ready = true
				break
			}
		}
		if !ready {
			unready = append(unready, worker)
		}
	}
	return unready
}

func windowsTargetsWithoutReadyExporter(ctx context.Context, targets []string) []string {
	podsByNode := suite.Cluster().GetPodsGroupedByNode(ctx, "kube-system", targets)
	var unready []string
	for _, target := range targets {
		ready := false
		for _, pod := range podsByNode[target] {
			if pod.Labels["app"] == "windows-exporter" && isPodReady(pod) {
				ready = true
				break
			}
		}
		if !ready {
			unready = append(unready, target)
		}
	}
	return unready
}

func hasWindowsExporterImage(implementation *addons.Implementation) bool {
	for _, image := range implementation.OfflineUsage.WindowsResources.AdditionalImages {
		if strings.Contains(image, "windows-exporter") {
			return true
		}
	}
	return false
}

func hasControlPlaneRole(node corev1.Node) bool {
	_, controlPlane := node.Labels["node-role.kubernetes.io/control-plane"]
	_, master := node.Labels["node-role.kubernetes.io/master"]
	return controlPlane || master
}

func nodeHasInternalIP(node corev1.Node, ip string) bool {
	for _, address := range node.Status.Addresses {
		if address.Type == corev1.NodeInternalIP && address.Address == ip {
			return true
		}
	}
	return false
}

func internalIP(node corev1.Node) string {
	for _, address := range node.Status.Addresses {
		if address.Type == corev1.NodeInternalIP {
			return address.Address
		}
	}
	return ""
}

func isNodeReady(node corev1.Node) bool {
	for _, condition := range node.Status.Conditions {
		if condition.Type == corev1.NodeReady {
			return condition.Status == corev1.ConditionTrue
		}
	}
	return false
}

func isPodReady(pod corev1.Pod) bool {
	for _, condition := range pod.Status.Conditions {
		if condition.Type == corev1.PodReady {
			return condition.Status == corev1.ConditionTrue
		}
	}
	return false
}

func nodeNames(nodes []corev1.Node) []string {
	names := make([]string, 0, len(nodes))
	for _, node := range nodes {
		names = append(names, node.Name)
	}
	return names
}
