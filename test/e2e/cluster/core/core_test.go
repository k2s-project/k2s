// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package core

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"testing"
	"time"

	core_config "github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/providers/ssh"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"
	"github.com/k2s-project/k2s/test/framework/watcher"
	core_v1 "k8s.io/api/core/v1"
	discovery_v1 "k8s.io/api/discovery/v1"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	meta_v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

const (
	namespace               = "k2s"
	rolloutRetryGracePeriod = 6 * time.Minute
)

var linuxDeploymentNames = []string{"albums-linux1", "albums-linux2"}
var winDeploymentNames = []string{"albums-win1", "albums-win2"}

var suite *framework.K2sTestSuite
var k2s *dsl.K2s

var manifestDir string
var proxy string

var testFailed = false
var podWatcher *watcher.PodWatcher

func TestClusterCore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Cluster Core Acceptance Tests", Label("core", "acceptance", "internet-required", "setup-required", "system-running", "sanity"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	manifestDir = "workload/windows"

	suite = framework.Setup(ctx, framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(time.Millisecond*200),
		framework.ClusterTestStepTimeout(12*time.Minute))
	k2s = dsl.NewK2s(suite)
	kubeSwitchConfig, err := core_config.ReadKubeSwitchConfig(suite.RootDir())
	Expect(err).NotTo(HaveOccurred())
	proxy = "http://" + kubeSwitchConfig.Address + ":8181"

	if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		GinkgoWriter.Println("Found Linux-only setup, skipping Windows-based workloads")

		manifestDir = "workload/base"
	}

	GinkgoWriter.Println("Using proxy <", proxy, "> for internet access")
	GinkgoWriter.Println("Deploying workloads to cluster..")

	// Start pod watcher in background
	podWatcher = watcher.NewPodWatcher(GinkgoWriter, namespace)
	if err := podWatcher.Start(ctx, suite.Kubectl().Path()); err != nil {
		GinkgoWriter.Printf("Warning: failed to start pod watcher: %v\n", err)
	}

	suite.Kubectl().MustExec(ctx, "apply", "-k", manifestDir)

	GinkgoWriter.Println("Waiting for Deployments to be ready in namespace <", namespace, ">..")

	// Early detection: check for systemic image pull failures before committing
	// to the full rollout timeout (~8 min). If all pods are stuck in ErrImagePull
	// after 60s, the registry is likely unreachable — fail fast with diagnostics.
	GinkgoWriter.Println("Checking for image pull errors (60s grace period)...")
	time.Sleep(60 * time.Second)
	detectSystemicImagePullFailures(ctx)

	waitForCoreWorkloadRollout(ctx)

	for _, deploymentName := range linuxDeploymentNames {
		suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, namespace)
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, namespace)
	}

	if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		for _, deploymentName := range winDeploymentNames {
			suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, namespace)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, namespace)
		}
	}

	GinkgoWriter.Println("Waiting for DNS entries to be resolvable from host..")

	for _, deploymentName := range linuxDeploymentNames {
		suite.Cluster().ExpectDNSToBeResolvableFromHost(ctx, deploymentName, namespace)
	}

	if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		for _, deploymentName := range winDeploymentNames {
			suite.Cluster().ExpectDNSToBeResolvableFromHost(ctx, deploymentName, namespace)
		}

		waitForWindowsWorkloadNetworkReadiness(ctx)
	}

	GinkgoWriter.Println("Deployments ready for testing")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		GinkgoWriter.Println("Skipping core test cleanup because BeforeSuite did not complete")
		return
	}

	if podWatcher != nil {
		podWatcher.Stop()
	}

	if runtime.GOOS == "linux" && suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		if _, err := os.Stat("/etc/kubernetes/admin.conf"); err == nil {
			suite.StatusChecker().IsK2sRunning(ctx)
		} else {
			GinkgoWriter.Println("Skipping native Linux status check because system reset removed runtime state")
		}
	} else {
		suite.StatusChecker().IsK2sRunning(ctx)
	}

	GinkgoWriter.Println("Deleting workloads..")

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	// for finding out the sporadically failed test runs
	if suite.ShouldCleanup(testFailed) {
		suite.Kubectl().MustExec(ctx, "delete", "-k", manifestDir, "--ignore-not-found=true")
		GinkgoWriter.Println("Workloads deleted")
		suite.TearDown(ctx, framework.RestartKubeProxy)
	}
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

// detectSystemicImagePullFailures checks if all pods in the test namespace are
// stuck in ErrImagePull/ImagePullBackOff, indicating a cluster-wide registry
// connectivity problem (e.g., broken proxy or auth after an upgrade).
// Fails immediately with diagnostics instead of waiting the full rollout timeout.
func detectSystemicImagePullFailures(ctx context.Context) {
	output, _ := suite.Kubectl().Exec(ctx, "get", "pods", "-n", namespace, "--no-headers",
		"-o", "custom-columns=NAME:.metadata.name,REASON:.status.containerStatuses[*].state.waiting.reason")

	output = strings.TrimSpace(output)
	if output == "" {
		return
	}

	lines := strings.Split(output, "\n")
	failCount := 0
	for _, line := range lines {
		if strings.Contains(line, "ErrImagePull") || strings.Contains(line, "ImagePullBackOff") {
			failCount++
		}
	}

	if failCount > 0 && failCount == len(lines) {
		podStatus, _ := suite.Kubectl().Exec(ctx, "get", "pods", "-n", namespace, "-o", "wide")
		events, _ := suite.Kubectl().Exec(ctx, "get", "events", "-n", namespace,
			"--sort-by=.lastTimestamp", "--field-selector=reason=Failed")
		Fail(fmt.Sprintf("All %d pods stuck in image pull failures — container registry may be unreachable after upgrade.\nPod status:\n%s\nRecent failure events:\n%s",
			failCount, podStatus, events))
	}
}

func waitForCoreWorkloadRollout(ctx context.Context) {
	clientSet, err := kubernetes.NewForConfig(suite.Cluster().Client().Resources().GetConfig())
	Expect(err).ToNot(HaveOccurred())

	deploymentNames := append([]string{}, linuxDeploymentNames...)
	deploymentNames = append(deploymentNames, "curl")
	if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		deploymentNames = append(deploymentNames, winDeploymentNames...)
	}

	timeout := suite.TestStepTimeout() + rolloutRetryGracePeriod
	deadline := time.Now().Add(timeout)
	pollInterval := suite.TestStepPollInterval()
	if pollInterval < 5*time.Second {
		pollInterval = 5 * time.Second
	}

	var pending []string
	for {
		select {
		case <-ctx.Done():
			collectCoreWorkloadRolloutDiagnostics()
			Fail(fmt.Sprintf("context cancelled while waiting for rollout in namespace <%s>: %v", namespace, ctx.Err()))
		default:
		}

		pending = pending[:0]

		for _, deploymentName := range deploymentNames {
			deployment, getErr := clientSet.AppsV1().Deployments(namespace).Get(ctx, deploymentName, meta_v1.GetOptions{})
			if getErr != nil {
				pending = append(pending, fmt.Sprintf("%s: get failed: %v", deploymentName, getErr))
				continue
			}

			desiredReplicas := int32(1)
			if deployment.Spec.Replicas != nil {
				desiredReplicas = *deployment.Spec.Replicas
			}

			if deployment.Status.ObservedGeneration < deployment.Generation ||
				deployment.Status.UpdatedReplicas < desiredReplicas ||
				deployment.Status.ReadyReplicas < desiredReplicas ||
				deployment.Status.AvailableReplicas < desiredReplicas {
				pending = append(pending,
					fmt.Sprintf("%s: observed=%d/%d updated=%d/%d ready=%d/%d available=%d/%d",
						deploymentName,
						deployment.Status.ObservedGeneration, deployment.Generation,
						deployment.Status.UpdatedReplicas, desiredReplicas,
						deployment.Status.ReadyReplicas, desiredReplicas,
						deployment.Status.AvailableReplicas, desiredReplicas))
			}
		}

		if len(pending) == 0 {
			GinkgoWriter.Println("Core workload rollout completed for all deployments")
			return
		}

		if time.Now().After(deadline) {
			collectCoreWorkloadRolloutDiagnostics()
			Fail(fmt.Sprintf("Deployments in namespace <%s> did not complete rollout within %s. Pending:\n%s",
				namespace, timeout, strings.Join(pending, "\n")))
		}

		GinkgoWriter.Printf("Core workload rollout pending: %s\n", strings.Join(pending, "; "))
		time.Sleep(pollInterval)
	}
}

func collectCoreWorkloadRolloutDiagnostics() {
	GinkgoWriter.Println("Collecting core workload rollout diagnostics..")
	diagCtx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	runDiagnosticCommand(diagCtx, "get", "deployment", "-n", namespace, "-o", "wide")
	runDiagnosticCommand(diagCtx, "get", "pods", "-n", namespace, "-o", "wide")
	runDiagnosticCommand(diagCtx, "get", "events", "-n", namespace, "--sort-by=.lastTimestamp")

	deploymentNames := append([]string{}, linuxDeploymentNames...)
	deploymentNames = append(deploymentNames, "curl")
	if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		deploymentNames = append(deploymentNames, winDeploymentNames...)
	}

	for _, deploymentName := range deploymentNames {
		runDiagnosticCommand(diagCtx, "describe", "deployment", deploymentName, "-n", namespace)
		runDiagnosticCommand(diagCtx, "describe", "pods", "-l", "app="+deploymentName, "-n", namespace)
	}
}

func waitForWindowsWorkloadNetworkReadiness(ctx context.Context) {
	GinkgoWriter.Println("Waiting for Windows workload network readiness from host and Linux curl pod..")

	const maxRetries = 3
	const retryDelay = 30 * time.Second

	for attempt := 1; attempt <= maxRetries; attempt++ {
		if attempt > 1 {
			GinkgoWriter.Printf("Windows network readiness attempt %d/%d after %v delay\n", attempt, maxRetries, retryDelay)
			time.Sleep(retryDelay)
		}

		if tryWindowsWorkloadNetworkReadiness(ctx) {
			GinkgoWriter.Println("Windows workload network readiness verified")
			return
		}
	}

	testFailed = true
	collectWindowsWorkloadNetworkDiagnostics()
	Fail(fmt.Sprintf("Windows workload network readiness failed after %d attempts and %s timeout", maxRetries, suite.TestStepTimeout()))
}

// tryWindowsWorkloadNetworkReadiness attempts to verify Windows workload network readiness
// within the configured test step timeout. Returns true if successful, false if timeout exceeded.
func tryWindowsWorkloadNetworkReadiness(ctx context.Context) bool {
	deadline := time.Now().Add(suite.TestStepTimeout())
	pollInterval := suite.TestStepPollInterval()
	if pollInterval < 5*time.Second {
		pollInterval = 5 * time.Second
	}
	lastFailures := make([]string, 0)

	for {
		lastFailures = lastFailures[:0]

		for _, deploymentName := range winDeploymentNames {
			if err := probeDeploymentFromHost(ctx, deploymentName); err != nil {
				lastFailures = append(lastFailures, fmt.Sprintf("host -> %s: %v", deploymentName, err))
			}

			if err := probeDeploymentFromCurlPod(ctx, deploymentName); err != nil {
				lastFailures = append(lastFailures, fmt.Sprintf("curl pod -> %s: %v", deploymentName, err))
			}
		}

		if len(lastFailures) == 0 {
			return true
		}

		if time.Now().After(deadline) {
			GinkgoWriter.Printf("Windows network readiness failed within this attempt: %s\n", strings.Join(lastFailures, "; "))
			return false
		}

		GinkgoWriter.Printf("Windows workload network readiness pending: %s\n", strings.Join(lastFailures, "; "))
		time.Sleep(pollInterval)
	}
}

func probeDeploymentFromHost(ctx context.Context, deploymentName string) error {
	url := fmt.Sprintf("http://%s.%s.svc.cluster.local/%s", deploymentName, namespace, deploymentName)
	_, exitCode := suite.Cli("curl").Exec(ctx, "-sS", "-f", "-m", "10", url)
	if exitCode != 0 {
		return fmt.Errorf("curl returned exit code %d for %s", exitCode, url)
	}

	return nil
}

func probeDeploymentFromCurlPod(ctx context.Context, deploymentName string) error {
	url := fmt.Sprintf("http://%s.%s.svc.cluster.local/%s", deploymentName, namespace, deploymentName)
	_, exitCode := suite.Kubectl().Exec(ctx, "exec", "deployment/curl", "-n", namespace, "-c", "curl", "--", "curl", "-sS", "-f", "-m", "10", url)
	if exitCode != 0 {
		return fmt.Errorf("kubectl exec curl returned exit code %d for %s", exitCode, url)
	}

	return nil
}

func collectWindowsWorkloadNetworkDiagnostics() {
	GinkgoWriter.Println("Collecting Windows workload network diagnostics after readiness failure..")

	diagCtx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()

	runDiagnosticCommand(diagCtx, "get", "nodes", "-o", "wide")
	runDiagnosticCommand(diagCtx, "get", "pods", "-n", namespace, "-o", "wide")
	runDiagnosticCommand(diagCtx, "get", "services", "-n", namespace, "-o", "wide")
	runDiagnosticCommand(diagCtx, "get", "endpoints", "-n", namespace, "-o", "wide")
	runDiagnosticCommand(diagCtx, "get", "endpointslices", "-n", namespace, "-o", "wide")
	runDiagnosticCommand(diagCtx, "get", "events", "-n", namespace, "--sort-by=.lastTimestamp")
	if runtime.GOOS == "windows" {
		for _, script := range []string{
			"Get-Service kubeproxy,kubelet,flanneld | Format-List Name,Status",
			"Get-NetAdapter | Format-Table -AutoSize",
			"Get-NetRoute -AddressFamily IPv4 | Format-Table -AutoSize",
			"Import-Module HostNetworkingService; Get-HNSNetwork | ConvertTo-Json -Depth 15",
			"Import-Module HostNetworkingService; Get-HNSEndpoint | ConvertTo-Json -Depth 15",
			"Import-Module HostNetworkingService; Get-HNSPolicyList | ConvertTo-Json -Depth 15",
		} {
			_, _ = runBoundedDiagnostic(diagCtx, "powershell.exe", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop'; "+script)
		}
	}
	collectWindowsForwardingDiagnostics(diagCtx, winDeploymentNames,
		func(ctx context.Context, args ...string) (string, error) {
			return runBoundedDiagnostic(ctx, suite.Kubectl().Path(), args...)
		},
		func(ctx context.Context, args ...string) (string, error) {
			return runBoundedDiagnostic(ctx, suite.Cli("curl").Path(), args...)
		})
	runDiagnosticCommand(diagCtx, "logs", "-n", "kube-flannel", "-l", "app=flannel", "--all-containers=true", "--tail=100")
	runDiagnosticCommand(diagCtx, "logs", "-n", "kube-system", "-l", "k8s-app=kube-proxy", "--all-containers=true", "--tail=100")

	for _, deploymentName := range winDeploymentNames {
		runDiagnosticCommand(diagCtx, "describe", "deployment", deploymentName, "-n", namespace)
		runDiagnosticCommand(diagCtx, "describe", "service", deploymentName, "-n", namespace)
		runDiagnosticCommand(diagCtx, "describe", "pods", "-l", "app="+deploymentName, "-n", namespace)
	}
}

func runDiagnosticCommand(ctx context.Context, args ...string) {
	_, _ = runBoundedDiagnostic(ctx, suite.Kubectl().Path(), args...)
}

func runBoundedDiagnostic(ctx context.Context, executable string, args ...string) (string, error) {
	if err := ctx.Err(); err != nil {
		GinkgoWriter.Printf(">>> DIAG: skipping %s after collection deadline: %v\n", executable, err)
		return "", err
	}
	commandCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	GinkgoWriter.Printf(">>> DIAG: %s %s\n", executable, strings.Join(args, " "))
	command := exec.CommandContext(commandCtx, executable, args...)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	command.WaitDelay = time.Second
	err := command.Run()
	GinkgoWriter.Print(stdout.String())
	GinkgoWriter.Print(stderr.String())
	if err != nil {
		GinkgoWriter.Printf(">>> DIAG: command failed: %v (context: %v)\n", err, commandCtx.Err())
	}
	return stdout.String(), err
}

type forwardingDiagnosticTarget struct {
	kind    string
	address string
	port    int32
}

func collectWindowsForwardingDiagnostics(ctx context.Context, deployments []string,
	kubectl, curl func(context.Context, ...string) (string, error)) {
	for _, deployment := range deployments {
		if ctx.Err() != nil {
			GinkgoWriter.Printf(">>> DIAG: forwarding probes stopped: %v\n", ctx.Err())
			return
		}
		targets := []forwardingDiagnosticTarget{{kind: "Service DNS", address: deployment + "." + namespace + ".svc.cluster.local", port: 80}}
		serviceJSON, err := kubectl(ctx, "get", "service", deployment, "-n", namespace, "-o", "json")
		if err == nil {
			serviceTargets, parseErr := serviceForwardingTargets(serviceJSON)
			if parseErr != nil {
				GinkgoWriter.Printf(">>> DIAG: cannot parse service %s: %v\n", deployment, parseErr)
			} else {
				targets = append(targets, serviceTargets...)
				if len(serviceTargets) == 0 {
					GinkgoWriter.Printf(">>> DIAG: no Service ClusterIP/TCP port available for %s\n", deployment)
				}
			}
		} else {
			GinkgoWriter.Printf(">>> DIAG: cannot query service %s: %v\n", deployment, err)
		}
		endpointJSON, err := kubectl(ctx, "get", "endpointslices", "-n", namespace, "-l", "kubernetes.io/service-name="+deployment, "-o", "json")
		if err == nil {
			endpointTargets, parseErr := endpointForwardingTargets(endpointJSON)
			if parseErr != nil {
				GinkgoWriter.Printf(">>> DIAG: cannot parse endpoints for %s: %v\n", deployment, parseErr)
			} else {
				targets = append(targets, endpointTargets...)
				if len(endpointTargets) == 0 {
					GinkgoWriter.Printf(">>> DIAG: no endpoint IP/port available for %s\n", deployment)
				}
			}
		} else {
			GinkgoWriter.Printf(">>> DIAG: cannot query endpoints for %s: %v\n", deployment, err)
		}
		for _, target := range targets {
			if ctx.Err() != nil {
				return
			}
			url := "http://" + net.JoinHostPort(target.address, fmt.Sprint(target.port)) + "/" + deployment
			GinkgoWriter.Printf(">>> DIAG: host -> %s %s at %s\n", deployment, target.kind, url)
			_, _ = curl(ctx, "-sS", "-f", "-m", "5", url)
			GinkgoWriter.Printf(">>> DIAG: Linux curl pod -> %s %s at %s\n", deployment, target.kind, url)
			_, _ = kubectl(ctx, "exec", "deployment/curl", "-n", namespace, "-c", "curl", "--", "curl", "-sS", "-f", "-m", "5", url)
		}
	}
}

func serviceForwardingTargets(content string) ([]forwardingDiagnosticTarget, error) {
	var service core_v1.Service
	if err := json.Unmarshal([]byte(content), &service); err != nil {
		return nil, err
	}
	var targets []forwardingDiagnosticTarget
	if net.ParseIP(service.Spec.ClusterIP) == nil {
		return targets, nil
	}
	for _, port := range service.Spec.Ports {
		if port.Port > 0 && port.Port <= 65535 && (port.Protocol == "" || port.Protocol == core_v1.ProtocolTCP) {
			targets = append(targets, forwardingDiagnosticTarget{kind: "Service ClusterIP", address: service.Spec.ClusterIP, port: port.Port})
		}
	}
	return targets, nil
}

func endpointForwardingTargets(content string) ([]forwardingDiagnosticTarget, error) {
	var slices discovery_v1.EndpointSliceList
	if err := json.Unmarshal([]byte(content), &slices); err != nil {
		return nil, err
	}
	var targets []forwardingDiagnosticTarget
	seen := make(map[forwardingDiagnosticTarget]bool)
	for _, slice := range slices.Items {
		for _, endpoint := range slice.Endpoints {
			for _, address := range endpoint.Addresses {
				if net.ParseIP(address) == nil {
					continue
				}
				for _, port := range slice.Ports {
					if port.Port == nil || *port.Port <= 0 || *port.Port > 65535 || (port.Protocol != nil && *port.Protocol != core_v1.ProtocolTCP) {
						continue
					}
					target := forwardingDiagnosticTarget{kind: "Pod IP", address: address, port: *port.Port}
					if !seen[target] {
						targets = append(targets, target)
						seen[target] = true
					}
				}
			}
		}
	}
	return targets, nil
}

func controlPlaneNodeName() string {
	if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() || runtime.GOOS != "linux" {
		return suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname()
	}

	hostname, err := os.Hostname()
	Expect(err).NotTo(HaveOccurred())
	return strings.ToLower(hostname)
}

func restoreLinuxOnlyCoreSuiteState(ctx context.Context) {
	GinkgoWriter.Println("Reinstalling native Linux-only cluster after reset..")
	installArgs := []string{"install", "--linux-only"}
	if suite.Proxy() != "" {
		installArgs = append(installArgs, "--proxy", suite.Proxy())
	}
	suite.K2sCli().UseProxy().MustExec(ctx, installArgs...)
	suite.SetupInfo().ReloadRuntimeConfig()
	Expect(suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly()).To(BeTrue())
	suite.Kubectl().MustExec(ctx, "get", "nodes")
	expectLinuxOnlyInstallArtifacts()
	GinkgoWriter.Println("Native Linux-only cluster restored after reset")
}

// expectLinuxOnlyResetCleanup verifies that 'k2s system reset' removed the
// Kubernetes admin kubeconfig and the flannel/CNI network devices on the native
// Linux host.
func expectLinuxOnlyResetCleanup(devices ...string) {
	GinkgoWriter.Println("Verifying native Linux-only reset removed Kubernetes components..")

	_, err := os.Stat("/etc/kubernetes/admin.conf")
	Expect(os.IsNotExist(err)).To(BeTrue(), "expected /etc/kubernetes/admin.conf to be removed by system reset")

	if len(devices) == 0 {
		devices = []string{"cni0"}
	}

	for _, device := range devices {
		output, err := exec.Command("ip", "link", "show", device).CombinedOutput()
		Expect(err).To(HaveOccurred(), "expected network device %s to be removed by system reset, got:\n%s", device, string(output))
		Expect(string(output)).To(Or(
			ContainSubstring("does not exist"),
			ContainSubstring("Cannot find device"),
		),
			"expected network device %s to be removed by system reset", device)
	}

	GinkgoWriter.Println("Native Linux-only reset cleanup verified")
}

// expectLinuxOnlyNetworkResetCleanup verifies that 'k2s system reset network'
// removed the host CNI interfaces without requiring the admin kubeconfig to be
// absent. This is the host-network-only cleanup path on native Linux hosts.
func expectLinuxOnlyNetworkResetCleanup(devices ...string) {
	GinkgoWriter.Println("Verifying native Linux-only network reset removed host CNI devices..")

	if len(devices) == 0 {
		devices = []string{"cni0", "flannel.1"}
	}

	for _, device := range devices {
		output, err := exec.Command("ip", "link", "show", device).CombinedOutput()
		Expect(err).To(HaveOccurred(), "expected network device %s to be removed by system reset network, got:\n%s", device, string(output))
		Expect(string(output)).To(Or(
			ContainSubstring("does not exist"),
			ContainSubstring("Cannot find device"),
		),
			"expected network device %s to be removed by system reset network", device)
	}

	GinkgoWriter.Println("Native Linux-only network reset cleanup verified")
}

// expectLinuxOnlyInstallArtifacts verifies that 'k2s install --linux-only'
// recreated the Kubernetes admin kubeconfig and the flannel/CNI network devices
// on the native Linux host. The CNI devices appear once pods are scheduled, so
// the check is retried within the configured test step timeout.
func expectLinuxOnlyInstallArtifacts() {
	GinkgoWriter.Println("Verifying native Linux-only install created Kubernetes components..")

	Eventually(func() error {
		if _, err := os.Stat("/etc/kubernetes/admin.conf"); err != nil {
			return fmt.Errorf("/etc/kubernetes/admin.conf not present: %w", err)
		}

		for _, device := range []string{"cni0", "flannel.1"} {
			output, err := exec.Command("ip", "link", "show", device).CombinedOutput()
			if err != nil {
				return fmt.Errorf("network device %s not present: %w; output: %s", device, err, strings.TrimSpace(string(output)))
			}
		}

		return nil
	}).WithTimeout(suite.TestStepTimeout()).WithPolling(suite.TestStepPollInterval()).Should(Succeed(),
		"expected native Linux-only install to recreate admin.conf and flannel/CNI devices")

	GinkgoWriter.Println("Native Linux-only install artifacts verified")
}

var _ = Describe("Cluster Core", func() {
	systemNamespace := "kube-system"

	Describe("Basic Components", func() {
		Describe("System Nodes", func() {
			It("control-plane is ready", func(ctx SpecContext) {
				suite.Cluster().ExpectNodeToBeReady(controlPlaneNodeName(), ctx)
			})

			It("Windows worker is ready", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectNodeToBeReady(suite.SetupInfo().WinNodeName, ctx)
			})
		})

		Describe("System Deployments", func() {
			It("coredns is available", func() {
				suite.Cluster().ExpectDeploymentToBeAvailable("coredns", systemNamespace)
			})
		})

		Describe("Control Plane Tools", func() {
			controlPlaneExec := func(command string) error {
				if runtime.GOOS == "linux" {
					// The native Linux host is the control plane. SSH keys and a
					// kubemaster VM are intentionally absent in this topology.
					output, err := exec.Command("sh", "-c", command).CombinedOutput()
					if err != nil {
						return fmt.Errorf("run control-plane command %q locally: %w; output: %s", command, err, strings.TrimSpace(string(output)))
					}
					return nil
				}

				var buf bytes.Buffer
				opts := ssh.ConnectionOptions{
					IpAddress:         suite.SetupInfo().Config.ControlPlane().IpAddress(),
					Port:              definitions.SSHDefaultPort,
					RemoteUser:        definitions.SSHRemoteUser,
					SshPrivateKeyPath: suite.SetupInfo().Config.Host().SshConfig().CurrentPrivateKeyPath(),
					Timeout:           time.Minute,
					StdOutWriter:      &buf,
				}
				return ssh.NewSSH(opts).Exec(command)
			}

			It("helm is installed on control-plane", func() {
				Expect(controlPlaneExec("helm version")).To(Succeed())
			})

			It("yq is installed on control-plane", func() {
				Expect(controlPlaneExec("yq --version")).To(Succeed())
			})
		})

		DescribeTable("System Pods", func(podName string) {
			suite.Cluster().ExpectPodToBeReady(podName, systemNamespace, controlPlaneNodeName())
		},
			Entry("etcd-HOSTNAME_PLACEHOLDER is available", "etcd-HOSTNAME_PLACEHOLDER"),
			Entry("kube-scheduler-HOSTNAME_PLACEHOLDER is available", "kube-scheduler-HOSTNAME_PLACEHOLDER"),
			Entry("kube-apiserver-HOSTNAME_PLACEHOLDER is available", "kube-apiserver-HOSTNAME_PLACEHOLDER"),
			Entry("kube-controller-manager-HOSTNAME_PLACEHOLDER is available", "kube-controller-manager-HOSTNAME_PLACEHOLDER"))
	})

	Describe("Communication", func() {
		DescribeTable("Deployments Availability", func(name string, skipOnLinuxOnly bool) {
			if skipOnLinuxOnly && suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
				Skip("Linux-only")
			}

			suite.Cluster().ExpectDeploymentToBeAvailable(name, namespace)
		},
			Entry("albums-linux1 is available", "albums-linux1", false),
			Entry("albums-win1 is available", "albums-win1", true),
			Entry("albums-linux2 is available", "albums-linux2", false),
			Entry("albums-win2 is available", "albums-win2", true),
			Entry("curl is available", "curl", false))

		DescribeTable("Deployment Reachable from Host", func(ctx context.Context, name string, skipOnLinuxOnly bool) {
			if skipOnLinuxOnly && suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
				Skip("Linux-only")
			}

			k2s.VerifyDeploymentToBeReachableFromHost(ctx, name, namespace)
		},
			Entry("albums-linux1 is reachable from host", "albums-linux1", false),
			Entry("albums-win1 is reachable from host", "albums-win1", true),
			Entry("albums-linux2 is reachable from host", "albums-linux2", false),
			Entry("albums-win2 is reachable from host", "albums-win2", true))

		Describe("Linux/Windows Deployments Are Reachable from Linux Pods", func() {
			It("Deployment albums-linux1 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "curl", namespace, ctx)
			})

			It("Deployment albums-win1 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win1", namespace, "curl", namespace, ctx)
			})

			It("Deployment albums-linux2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "curl", namespace, ctx)
			})

			It("Deployment albums-win2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "curl", namespace, ctx)
			})
		})

		Describe("Linux Deployments Are Reachable from Windows Pods", func() {
			It("Deployment albums-linux1 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "albums-win1", namespace, ctx)
			})

			It("Deployment albums-linux1 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "albums-win2", namespace, ctx)
			})

			It("Deployment albums-linux2 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "albums-win1", namespace, ctx)
			})

			It("Deployment albums-linux2 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "albums-win2", namespace, ctx)
			})
		})

		Describe("Windows Deployments Are Reachable from Windows Pods", func() {
			It("Deployment albums-win2 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "albums-win1", namespace, ctx)
			})

			It("Deployment albums-win1 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win1", namespace, "albums-win2", namespace, ctx)
			})
		})

		Describe("Linux/Windows Pods Are Reachable from Linux Pods", func() {
			It("Pod of Deployment albums-linux1 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "curl", namespace, ctx)
			})

			It("Pod of Deployment albums-win1 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-win1", namespace, "curl", namespace, ctx)
			})

			It("Pod of Deployment albums-linux2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "curl", namespace, ctx)
			})

			It("Pod of Deployment albums-win2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "curl", namespace, ctx)
			})
		})

		Describe("Linux Pods Are Reachable from Windows Pods", func() {
			It("Pod of Deployment albums-linux1 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "albums-win1", namespace, ctx)
			})

			It("Pod of Deployment albums-linux1 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "albums-win2", namespace, ctx)
			})

			It("Pod of Deployment albums-linux2 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "albums-win1", namespace, ctx)
			})

			It("Pod of Deployment albums-linux2 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "albums-win2", namespace, ctx)
			})
		})

		Describe("Windows Pods Are Reachable from Windows Pods", func() {
			It("Pod of Deployment albums-win2 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "albums-win1", namespace, ctx)
			})

			It("Pod of Deployment albums-win1 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-win1", namespace, "albums-win2", namespace, ctx)
			})
		})

		Describe("Internet is Reachable from Pods", func() {
			It("Internet is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				if suite.IsOfflineMode() {
					Skip("Offline-Mode")
				}

				suite.Cluster().ExpectInternetToBeReachableFromPodOfDeployment("curl", namespace, proxy, ctx)
			})

			It("Internet is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.IsOfflineMode() {
					Skip("Offline-Mode")
				}

				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectInternetToBeReachableFromPodOfDeployment("albums-win1", namespace, proxy, ctx)
			})

			It("Internet is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.IsOfflineMode() {
					Skip("Offline-Mode")
				}

				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectInternetToBeReachableFromPodOfDeployment("albums-win2", namespace, proxy, ctx)
			})
		})
	})

	Describe("ClusterIP Subnet Assignment", func() {
		It("Windows service albums-win1 has a ClusterIP in the Windows subnet", func(ctx SpecContext) {
			if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
				Skip("Linux-only")
			}

			clientSet, err := kubernetes.NewForConfig(suite.Cluster().Client().Resources().GetConfig())
			Expect(err).NotTo(HaveOccurred())

			svc, err := clientSet.CoreV1().Services(namespace).Get(ctx, "albums-win1", meta_v1.GetOptions{})
			Expect(err).NotTo(HaveOccurred(), "failed to get service albums-win1")

			Expect(svc.Spec.ClusterIP).NotTo(BeEmpty(), "albums-win1 has no ClusterIP")
			Expect(strings.HasPrefix(svc.Spec.ClusterIP, "172.21.1.")).To(BeTrue(),
				"albums-win1 ClusterIP %s is not in the Windows subnet 172.21.1.0/24", svc.Spec.ClusterIP)
		})

		It("Windows service albums-win2 has a ClusterIP in the Windows subnet", func(ctx SpecContext) {
			if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
				Skip("Linux-only")
			}

			clientSet, err := kubernetes.NewForConfig(suite.Cluster().Client().Resources().GetConfig())
			Expect(err).NotTo(HaveOccurred())

			svc, err := clientSet.CoreV1().Services(namespace).Get(ctx, "albums-win2", meta_v1.GetOptions{})
			Expect(err).NotTo(HaveOccurred(), "failed to get service albums-win2")

			Expect(svc.Spec.ClusterIP).NotTo(BeEmpty(), "albums-win2 has no ClusterIP")
			Expect(strings.HasPrefix(svc.Spec.ClusterIP, "172.21.1.")).To(BeTrue(),
				"albums-win2 ClusterIP %s is not in the Windows subnet 172.21.1.0/24", svc.Spec.ClusterIP)
		})

		It("Linux service albums-linux1 has a ClusterIP in the Linux subnet", func(ctx SpecContext) {
			clientSet, err := kubernetes.NewForConfig(suite.Cluster().Client().Resources().GetConfig())
			Expect(err).NotTo(HaveOccurred())

			svc, err := clientSet.CoreV1().Services(namespace).Get(ctx, "albums-linux1", meta_v1.GetOptions{})
			Expect(err).NotTo(HaveOccurred(), "failed to get service albums-linux1")

			Expect(svc.Spec.ClusterIP).NotTo(BeEmpty(), "albums-linux1 has no ClusterIP")
			Expect(strings.HasPrefix(svc.Spec.ClusterIP, "172.21.0.")).To(BeTrue(),
				"albums-linux1 ClusterIP %s is not in the Linux subnet 172.21.0.0/24", svc.Spec.ClusterIP)
		})
	})

	Describe("Linux-only reset commands", Ordered, func() {
		BeforeAll(func() {
			if runtime.GOOS != "linux" || !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
				Skip("native Linux-only setup required")
			}
		})

		It("resets the native Linux-only cluster and removes Kubernetes components", func(ctx SpecContext) {
			suite.K2sCli().MustExec(ctx, "system", "reset")
			expectLinuxOnlyResetCleanup("cni0")
		})

		It("resets the native Linux-only host network and removes CNI devices", func(ctx SpecContext) {
			suite.K2sCli().MustExec(ctx, "system", "reset", "network", "--force")
			expectLinuxOnlyNetworkResetCleanup("cni0", "flannel.1")
		})

		It("can reinstall the native Linux-only cluster after reset", func(ctx SpecContext) {
			restoreLinuxOnlyCoreSuiteState(ctx)
		})
	})
})
