// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package ceph_share

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	bos "os"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	addonName          = "storage"
	implementationName = "ceph"
	namespace          = "ceph-share-test"
	kubemasterIP       = "172.19.1.100"

	namespaceManifestPath = "workloads/ceph-share-test-namespace.yaml"
	rwxManifestDir        = "workloads/rwx"
	windowsManifestDir    = "workloads/windows"

	pvcName      = "ceph-share-test-pvc"
	writerPod    = "ceph-share-writer"
	readerPod    = "ceph-share-reader"
	testFile     = "/mnt/data/hello.txt"
	testMarker   = "hello from k2s ceph e2e"
	cephDataPool = "cephfs.cephfs.data"

	winWriterPod        = "ceph-share-win-writer"
	winReaderPod        = "ceph-share-win-reader"
	winTestFile         = `C:\data\win-hello.txt`
	winTestMarker       = "hello from k2s ceph windows e2e"
	cephSmbNamespace    = "storage-smb-ceph"
	cephSmbStorageClass = "ceph-smb"
	winPVCName          = "ceph-share-win-pvc"

	testClusterTimeout     = time.Minute * 20
	addonEnableMaxAttempts = 2
	addonEnableRetryDelay  = 10 * time.Second
	windowsPodReadyTimeout = 10 * time.Minute
	windowsPVCBoundTimeout = 10 * time.Minute
)

var (
	suite              *framework.K2sTestSuite
	k2s                *dsl.K2s
	testFailed         = false
	originalConfigPath string
)

func TestCephStorage(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "storage ceph Addon Acceptance Tests", Label("addon", "acceptance", "internet-required", "setup-required", "invasive", "storage-ceph", "ceph", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(
		ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout),
	)
	k2s = dsl.NewK2s(suite)

	suite.Kubectl().MustExec(ctx, "apply", "-f", namespaceManifestPath)

	originalConfigPath = filepath.Join(suite.RootDir(), "addons", "storage", "ceph", "config", "ceph-config.json")
	_, err := bos.Stat(originalConfigPath)
	Expect(err).ToNot(HaveOccurred(), "expected addon Ceph config to exist at '%s'", originalConfigPath)
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	// Best-effort cleanup in failure paths.
	suite.Kubectl().Exec(ctx, "delete", "-k", windowsManifestDir)
	suite.Kubectl().Exec(ctx, "delete", "-k", rwxManifestDir)
	suite.Kubectl().Exec(ctx, "delete", "-f", namespaceManifestPath)
	suite.K2sCli().Exec(ctx, "addons", "disable", addonName, implementationName, "-f", "-o")

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("storage ceph addon", Ordered, func() {
	Describe("status command", func() {
		It("shows disabled in default output", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, implementationName)
			Expect(output).To(SatisfyAll(
				ContainSubstring("ADDON STATUS"),
				ContainSubstring("disabled"),
			))
		})

		It("shows disabled in JSON output", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, implementationName, "-o", "json")

			var st status.AddonPrintStatus
			Expect(json.Unmarshal([]byte(output), &st)).To(Succeed())
			Expect(st.Name).To(Equal(addonName))
			Expect(st.Implementation).To(Equal(implementationName))
			Expect(st.Enabled).NotTo(BeNil())
			Expect(*st.Enabled).To(BeFalse())
		})
	})

	Describe("enable without -w, run Linux workload, disable", func() {
		It("enables the addon without Windows SMB setup", func(ctx context.Context) {
			output := enableCephAddonWithRetry(ctx, false)
			Expect(output).To(SatisfyAll(
				ContainSubstring("enable"),
				ContainSubstring(addonName),
				ContainSubstring(implementationName),
			))

			k2s.VerifyAddonIsEnabled(addonName, implementationName)
		})

		It("shows enabled status", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, implementationName)
			Expect(output).To(SatisfyAll(
				ContainSubstring("ADDON STATUS"),
				ContainSubstring("enabled"),
			))
		})

		It("does not provision Ceph SMB resources without -w", func(ctx context.Context) {
			expectCephSmbResourcesAbsent(ctx)
		})

		It("makes Ceph dashboard URL reachable", func(ctx context.Context) {
			dashboardURL, err := getExpectedCephDashboardURL(originalConfigPath, suite.SetupInfo().Config.Host().K2sSetupConfigDir())
			Expect(err).ToNot(HaveOccurred())

			Eventually(func() error {
				_, getErr := suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, dashboardURL)
				return getErr
			}).WithTimeout(3*time.Minute).WithPolling(10*time.Second).Should(Succeed(), "Ceph dashboard URL should be reachable: %s", dashboardURL)
		})

		It("deploys Ceph RWX workload", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx, "apply", "-k", rwxManifestDir)
		})

		It("binds the Ceph PVC", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx,
				"wait",
				"--for=jsonpath={.status.phase}=Bound",
				"pvc/"+pvcName,
				"-n", namespace,
				"--timeout=180s",
			)
		})

		It("runs writer and reader pods", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx, "wait", "--for=condition=Ready", "pod/"+writerPod, "-n", namespace, "--timeout=180s")
			suite.Kubectl().MustExec(ctx, "wait", "--for=condition=Ready", "pod/"+readerPod, "-n", namespace, "--timeout=180s")
		})

		It("shares data across pods through CephFS", func(ctx context.Context) {
			Eventually(func() string {
				out, exitCode := suite.Kubectl().Exec(ctx, "exec", "-n", namespace, readerPod, "--", "cat", testFile)
				if exitCode != 0 {
					return ""
				}
				return strings.TrimSpace(out)
			}).WithTimeout(3 * time.Minute).WithPolling(5 * time.Second).Should(Equal(testMarker))
		})

		It("deletes Ceph workload resources", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx, "delete", "-k", rwxManifestDir)
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, implementationName, "-f", "-o")
			k2s.VerifyAddonIsDisabled(addonName, implementationName)

			Eventually(func(g Gomega) {
				st := getAddonStatusJSON(ctx, g)
				g.Expect(st.Name).To(Equal(addonName))
				g.Expect(st.Implementation).To(Equal(implementationName))
				g.Expect(st.Enabled).NotTo(BeNil())
				g.Expect(*st.Enabled).To(BeFalse())
			}).WithTimeout(2 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())
		})
	})

	Describe("enable with -w, run Windows SMB workload, disable", func() {
		It("enables the addon with Windows SMB setup", func(ctx context.Context) {
			skipIfLinuxOnly()
			output := enableCephAddonWithRetry(ctx, true)
			Expect(output).To(SatisfyAll(
				ContainSubstring("enable"),
				ContainSubstring(addonName),
				ContainSubstring(implementationName),
			))

			k2s.VerifyAddonIsEnabled(addonName, implementationName)
		})

		It("provisions Ceph SMB resources with -w", func(ctx context.Context) {
			skipIfLinuxOnly()
			expectCephSmbResourcesPresent(ctx)
		})

		It("deploys the Windows Ceph SMB workload", func(ctx context.Context) {
			skipIfLinuxOnly()
			suite.Kubectl().MustExec(ctx, "apply", "-k", windowsManifestDir)
		})

		It("binds the Windows Ceph SMB PVC", func(ctx context.Context) {
			skipIfLinuxOnly()
			suite.Kubectl().MustExec(ctx,
				"wait",
				"--for=jsonpath={.status.phase}=Bound",
				"pvc/"+winPVCName,
				"-n", namespace,
				"--timeout="+windowsPVCBoundTimeout.String(),
			)
		})

		It("runs the Windows writer and reader pods", func(ctx context.Context) {
			skipIfLinuxOnly()
			suite.Kubectl().MustExec(ctx, "wait", "--for=condition=Ready", "pod/"+winWriterPod, "-n", namespace, "--timeout="+windowsPodReadyTimeout.String())
			suite.Kubectl().MustExec(ctx, "wait", "--for=condition=Ready", "pod/"+winReaderPod, "-n", namespace, "--timeout="+windowsPodReadyTimeout.String())
		})

		It("shares data across Windows pods through the CephFS SMB share", func(ctx context.Context) {
			skipIfLinuxOnly()
			Eventually(func() string {
				out, exitCode := suite.Kubectl().Exec(ctx, "exec", "-n", namespace, winReaderPod, "--", "cmd", "/c", "type", winTestFile)
				if exitCode != 0 {
					return ""
				}
				return strings.TrimSpace(out)
			}).WithTimeout(3 * time.Minute).WithPolling(5 * time.Second).Should(Equal(winTestMarker))
		})

		It("deletes the Windows Ceph workload resources", func(ctx context.Context) {
			skipIfLinuxOnly()
			suite.Kubectl().MustExec(ctx, "delete", "-k", windowsManifestDir)
		})

		It("disables the addon", func(ctx context.Context) {
			skipIfLinuxOnly()
			suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, implementationName, "-f", "-o")
			k2s.VerifyAddonIsDisabled(addonName, implementationName)
		})
	})
})

func skipIfLinuxOnly() {
	if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		Skip("Linux-only setup: no Windows worker node to validate CephFS access over SMB")
	}
}

func enableCephAddonWithRetry(ctx context.Context, setupWindowsNode bool) string {
	lastOutput := ""
	lastExitCode := -1
	args := []string{"addons", "enable", addonName, implementationName, "-o"}
	if setupWindowsNode {
		args = append(args, "-w")
	}

	for attempt := 1; attempt <= addonEnableMaxAttempts; attempt++ {
		output, exitCode := suite.K2sCli().Exec(ctx, args...)
		if exitCode == 0 {
			return output
		}

		lastOutput = output
		lastExitCode = exitCode

		if attempt < addonEnableMaxAttempts {
			GinkgoWriter.Printf("Retrying addon enable after failed attempt %d/%d (exit code: %d).\n", attempt, addonEnableMaxAttempts, exitCode)
			suite.K2sCli().Exec(ctx, "addons", "disable", addonName, implementationName, "-f", "-o")
			time.Sleep(addonEnableRetryDelay)
		}
	}

	Expect(lastExitCode).To(Equal(0), "'k2s addons enable %s %s -o' failed after %d attempts. Last output:\n%s", addonName, implementationName, addonEnableMaxAttempts, lastOutput)
	return lastOutput
}

func expectCephSmbResourcesAbsent(ctx context.Context) {
	sc, scExitCode := suite.Kubectl().Exec(ctx, "get", "storageclass", cephSmbStorageClass, "-o", "name", "--ignore-not-found")
	Expect(scExitCode).To(Equal(0))
	Expect(strings.TrimSpace(sc)).To(BeEmpty(), "Ceph SMB StorageClass should not exist without -w")

	ns, nsExitCode := suite.Kubectl().Exec(ctx, "get", "namespace", cephSmbNamespace, "-o", "name", "--ignore-not-found")
	Expect(nsExitCode).To(Equal(0))
	Expect(strings.TrimSpace(ns)).To(BeEmpty(), "Ceph SMB namespace should not exist without -w")
}

func expectCephSmbResourcesPresent(ctx context.Context) {
	Eventually(func() string {
		out, exitCode := suite.Kubectl().Exec(ctx, "get", "storageclass", cephSmbStorageClass, "-o", "name", "--ignore-not-found")
		if exitCode != 0 {
			return ""
		}
		return strings.TrimSpace(out)
	}).WithTimeout(2 * time.Minute).WithPolling(5 * time.Second).Should(ContainSubstring(cephSmbStorageClass))

	Eventually(func() string {
		out, exitCode := suite.Kubectl().Exec(ctx, "get", "namespace", cephSmbNamespace, "-o", "name", "--ignore-not-found")
		if exitCode != 0 {
			return ""
		}
		return strings.TrimSpace(out)
	}).WithTimeout(2 * time.Minute).WithPolling(5 * time.Second).Should(Equal("namespace/" + cephSmbNamespace))
}

func getAddonStatusJSON(ctx context.Context, g Gomega) status.AddonPrintStatus {
	output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, implementationName, "-o", "json")

	var st status.AddonPrintStatus
	g.Expect(json.Unmarshal([]byte(output), &st)).To(Succeed())
	return st
}

func getExpectedCephDashboardURL(cephConfigPath, setupConfigDir string) (string, error) {
	clusterHostNode, err := getClusterHostNodeFromCephConfig(cephConfigPath)
	if err != nil {
		return "", err
	}
	targetHost, err := getDashboardTargetHost(clusterHostNode, setupConfigDir)
	if err != nil {
		return "", err
	}

	return fmt.Sprintf("https://%s:8443/", targetHost), nil
}

func getClusterHostNodeFromCephConfig(cephConfigPath string) (string, error) {
	config, err := readJSONAsMap(cephConfigPath)
	if err != nil {
		return "", err
	}

	clusterHostValue, found := config["clusterHost"]
	if !found {
		return "", fmt.Errorf("clusterHost.node is missing in '%s'", cephConfigPath)
	}

	clusterHost, ok := clusterHostValue.(map[string]any)
	if !ok {
		return "", fmt.Errorf("clusterHost in '%s' is not an object", cephConfigPath)
	}

	clusterHostNode, ok := getTrimmedString(clusterHost["node"])
	if !ok {
		return "", fmt.Errorf("clusterHost.node in '%s' is empty or not a string", cephConfigPath)
	}

	return clusterHostNode, nil
}

func getTrimmedString(value any) (string, bool) {
	stringValue, ok := value.(string)
	if !ok {
		return "", false
	}

	trimmedValue := strings.TrimSpace(stringValue)
	if trimmedValue == "" {
		return "", false
	}

	return trimmedValue, true
}

// For the control plane node, use its well-known hostname directly.

func getDashboardTargetHost(clusterHostNode, setupConfigDir string) (string, error) {
	if strings.EqualFold(clusterHostNode, "kubemaster") {
		return kubemasterIP, nil
	}

	clusterConfigPath := filepath.Join(setupConfigDir, "cluster.json")
	clusterConfig, err := readJSONAsMap(clusterConfigPath)
	if err != nil {
		return "", fmt.Errorf("failed to read cluster config '%s': %w", clusterConfigPath, err)
	}
	ip, err := findNodeIPInClusterConfig(clusterConfig, clusterHostNode)
	if err != nil {
		return "", fmt.Errorf("%w in '%s'", err, clusterConfigPath)
	}
	return ip, nil
}

func findNodeIPInClusterConfig(clusterConfig map[string]any, targetNodeName string) (string, error) {
	nodesValue, hasNodes := clusterConfig["nodes"]
	if !hasNodes {
		return "", fmt.Errorf("nodes are missing")
	}

	if nodesArray, ok := nodesValue.([]any); ok {
		return findNodeIPInArray(nodesArray, targetNodeName)
	}

	return findNodeIPInObject(nodesValue, targetNodeName)
}

func findNodeIPInArray(nodesArray []any, targetNodeName string) (string, error) {
	for _, node := range nodesArray {
		name, ip := extractNodeNameAndIP(node)
		if strings.EqualFold(name, targetNodeName) {
			if ip == "" {
				return "", fmt.Errorf("node '%s' does not have an IpAddress", targetNodeName)
			}
			return ip, nil
		}
	}
	return "", fmt.Errorf("clusterHostNode '%s' was not found", targetNodeName)
}

func findNodeIPInObject(nodeValue any, targetNodeName string) (string, error) {
	name, ip := extractNodeNameAndIP(nodeValue)
	if strings.EqualFold(name, targetNodeName) {
		if ip == "" {
			return "", fmt.Errorf("node '%s' does not have an IpAddress", targetNodeName)
		}
		return ip, nil
	}
	return "", fmt.Errorf("clusterHostNode '%s' was not found", targetNodeName)
}

func extractNodeNameAndIP(node any) (string, string) {
	nodeMap, ok := node.(map[string]any)
	if !ok {
		return "", ""
	}

	name, _ := nodeMap["Name"].(string)
	if strings.TrimSpace(name) == "" {
		name, _ = nodeMap["name"].(string)
	}

	ip, _ := nodeMap["IpAddress"].(string)
	if strings.TrimSpace(ip) == "" {
		ip, _ = nodeMap["ipAddress"].(string)
	}

	return strings.TrimSpace(name), strings.TrimSpace(ip)
}

func readJSONAsMap(path string) (map[string]any, error) {
	content, err := bos.ReadFile(path)
	if err != nil {
		return nil, err
	}

	decoded := map[string]any{}
	if err := json.Unmarshal(content, &decoded); err != nil {
		return nil, err
	}

	return decoded, nil
}
