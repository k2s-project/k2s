// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package smb_share

import (
	"context"
	"fmt"
	"io/fs"
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/os"

	bos "os"

	"github.com/k2s-project/k2s/internal/cli"
	kos "github.com/k2s-project/k2s/internal/os"

	"encoding/json"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

type config []configEntry

type configEntry struct {
	WinMountPath     string `json:"winMountPath"`
	LinuxMountPath   string `json:"linuxMountPath"`
	WinShareName     string `json:"winShareName"`
	LinuxShareName   string `json:"linuxShareName"`
	StorageClassName string `json:"storageClassName"`
}

const (
	addonName          = "storage"
	implementationName = "smb"
	namespace          = "smb-share-test"

	linuxManifestDir      = "workloads/linux"
	windowsManifestDir    = "workloads/windows"
	accessModeManifestDir = "workloads/accessmode"
	retainManifestDir     = "workloads/retain"
	linuxPosixManifestDir = "workloads/linux-posix"

	linuxWorkloadName1     = "smb-share-test-linux1"
	linuxWorkloadName2     = "smb-share-test-linux2"
	linuxPosixWorkloadName = "smb-share-test-linux-posix"
	windowsWorkloadName1   = "smb-share-test-windows1"
	windowsWorkloadName2   = "smb-share-test-windows2"

	testConfigFileName = "test-config.json"

	linuxTestfileName   = "smb-share-test-linux.file"
	windowsTestfileName = "smb-share-test-windows.txt"

	testFileCheckTimeout  = time.Minute * 2
	testFileCheckInterval = time.Second * 5
	testClusterTimeout    = time.Minute * 10
	testStepPollInterval  = time.Millisecond * 200

	testFileCreationTimeout = time.Minute * 5
	testFileOverallTimeout  = time.Minute * 10
)

var (
	namespaceManifestPath = fmt.Sprintf("workloads/%s-namespace.yaml", namespace)
	suite                 *framework.K2sTestSuite
	skipWindowsWorkloads  = false
	originalConfigPath    string
	storageConfig         config
	testFailed            = false
)

func TestSmbshare(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "storage Addon Acceptance Tests", Label("addon", "acceptance", "internet-required", "setup-required", "invasive", "storage", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout),
		framework.ClusterTestStepPollInterval(testStepPollInterval))

	skipWindowsWorkloads = suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly()

	GinkgoWriter.Println("Creating namespace <", namespace, "> on cluster..")

	suite.Kubectl().MustExec(ctx, "apply", "-f", namespaceManifestPath)

	GinkgoWriter.Println("Namespace <", namespace, "> created on cluster")

	originalConfigPath = filepath.Join(suite.RootDir(), "addons", "storage", "smb", "config", "SmbStorage.json")

	Expect(bos.Rename(originalConfigPath, originalConfigPath+"_")).To(Succeed())
	Expect(kos.CopyFile(testConfigFileName, originalConfigPath)).To(Succeed())

	configBytes, err := bos.ReadFile(testConfigFileName)
	Expect(err).ToNot(HaveOccurred())

	var rawConfig []map[string]json.RawMessage
	Expect(json.Unmarshal(configBytes, &rawConfig)).To(Succeed())
	nonPosixConfig := make([]map[string]json.RawMessage, 0, len(rawConfig))
	for _, configEntry := range rawConfig {
		var enablePosixExtensions bool
		if posixValue, exists := configEntry["enablePosixExtensions"]; exists {
			Expect(json.Unmarshal(posixValue, &enablePosixExtensions)).To(Succeed())
		}
		if enablePosixExtensions {
			continue
		}
		nonPosixConfig = append(nonPosixConfig, configEntry)
	}
	nonPosixConfigBytes, err := json.MarshalIndent(nonPosixConfig, "", "    ")
	Expect(err).ToNot(HaveOccurred())
	Expect(bos.WriteFile(originalConfigPath, nonPosixConfigBytes, fs.ModePerm)).To(Succeed())

	Expect(json.Unmarshal(configBytes, &storageConfig)).To(Succeed())
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	if suite.ShouldCleanup(testFailed) {
		GinkgoWriter.Println("Deleting namespace <", namespace, "> on cluster..")

		suite.Kubectl().MustExec(ctx, "delete", "-f", namespaceManifestPath)

		GinkgoWriter.Println("Namespace <", namespace, "> deleted on cluster")
		GinkgoWriter.Println("Disabling addon..")

		output := suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, implementationName, "-f", "-o")

		GinkgoWriter.Println(output)
	}

	Expect(bos.Remove(originalConfigPath)).To(Succeed())
	Expect(bos.Rename(originalConfigPath+"_", originalConfigPath)).To(Succeed())

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe(fmt.Sprintf("%s Addon, %s Implementation", addonName, implementationName), Ordered, func() {
	Describe("status command", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, implementationName)

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Implementation .+%s.+ of Addon .+%s.+ is .+disabled.+`, implementationName, addonName),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, implementationName, "-o", "json")

				var status status.AddonPrintStatus

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

				Expect(status.Name).To(Equal(addonName))
				Expect(status.Implementation).To(Equal(implementationName))
				Expect(status.Enabled).NotTo(BeNil())
				Expect(*status.Enabled).To(BeFalse())
				Expect(status.Props).To(BeNil())
				Expect(status.Error).To(BeNil())
			})
		})
	})

	Describe("disable command", func() {
		When("addon is disabled", func() {
			It("disables the addon for both host types for cleanup", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, implementationName, "-f", "-o")

				Expect(output).To(SatisfyAll(
					ContainSubstring("disable"),
					ContainSubstring(addonName),
					ContainSubstring(implementationName),
					ContainSubstring("trying to remove both Windows and Linux hosted SMB shares"),
				))
			})
		})

		When("both mutually exclusive flags are being used", func() {
			It("displays error and exits with non-zero", func(ctx context.Context) {
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", addonName, implementationName, "-f", "-k", "-o")

				Expect(output).To(SatisfyAll(
					ContainSubstring("ERROR"),
					MatchRegexp(`.+\[force keep\] were all set`),
				))
			})
		})
	})

	Describe("negative flows", func() {
		It("fails enable when ceph is requested while smb is already enabled", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, implementationName, "-o")
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", addonName, "ceph")
			Expect(output).To(ContainSubstring("Cannot enable"))
			suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, implementationName, "-f", "-o")
		})
	})

	Describe("enable command", func() {
		When("SMB host type is Windows", func() {
			It("enables the addon", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, implementationName, "-o")

				expectEnableMessage(output, "windows")
			})

			It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", addonName, implementationName)

				Expect(output).To(ContainSubstring("already enabled"))
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted("windows", ctx)
			})

			It("deploys Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "apply", "-k", linuxManifestDir)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().MustExec(ctx, "apply", "-k", windowsManifestDir)
			})

			It("runs Linux-based workloads", func(ctx context.Context) {
				// TODO: could be more generic
				expectWorkloadToRun(ctx, linuxWorkloadName1, storageConfig[0].WinMountPath, linuxTestfileName)
				expectWorkloadToRun(ctx, linuxWorkloadName2, storageConfig[1].WinMountPath, linuxTestfileName)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				expectWorkloadToRun(ctx, windowsWorkloadName1, storageConfig[0].WinMountPath, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, storageConfig[1].WinMountPath, windowsTestfileName)
			})

			It("restarts the cluster", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "start", "-o")
			})

			It("still runs Linux-based workloads after cluster restart", func(ctx context.Context) {
				expectWorkloadToRun(ctx, linuxWorkloadName1, storageConfig[0].WinMountPath, linuxTestfileName)
				expectWorkloadToRun(ctx, linuxWorkloadName2, storageConfig[1].WinMountPath, linuxTestfileName)
			})

			It("still runs Windows-based workloads after cluster restart", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				expectWorkloadToRun(ctx, windowsWorkloadName1, storageConfig[0].WinMountPath, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, storageConfig[1].WinMountPath, windowsTestfileName)
			})

			It("deletes Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "delete", "-k", linuxManifestDir)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().MustExec(ctx, "delete", "-k", windowsManifestDir)
			})

			It("disposes Linux-based workloads", func(ctx context.Context) {
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName2, namespace, ctx)
			})

			It("disposes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName2, namespace, ctx)
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx, "-f")
			})
		})

		When("SMB host type is linux", func() {
			var smbHostPrefix string

			BeforeAll(func() {
				smbHostPrefix = `\\` + suite.SetupInfo().Config.ControlPlane().IpAddress() + `\`
			})

			It("enables the addon", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, implementationName, "-o", "-t", "linux")

				expectEnableMessage(output, "linux")
			})

			It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", addonName, implementationName)

				Expect(output).To(ContainSubstring("already enabled"))
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted("linux", ctx)
			})

			It("deploys Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "apply", "-k", linuxManifestDir)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().MustExec(ctx, "apply", "-k", windowsManifestDir)
			})

			It("runs Linux-based workloads", func(ctx context.Context) {
				expectWorkloadToRun(ctx, linuxWorkloadName1, smbHostPrefix+storageConfig[0].LinuxShareName, linuxTestfileName)
				expectWorkloadToRun(ctx, linuxWorkloadName2, smbHostPrefix+storageConfig[1].LinuxShareName, linuxTestfileName)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				expectWorkloadToRun(ctx, windowsWorkloadName1, smbHostPrefix+storageConfig[0].LinuxShareName, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, smbHostPrefix+storageConfig[1].LinuxShareName, windowsTestfileName)
			})

			It("restarts the cluster", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "start", "-o")
			})

			It("still runs Linux-based workloads after cluster restart", func(ctx context.Context) {
				expectWorkloadToRun(ctx, linuxWorkloadName1, smbHostPrefix+storageConfig[0].LinuxShareName, linuxTestfileName)
				expectWorkloadToRun(ctx, linuxWorkloadName2, smbHostPrefix+storageConfig[1].LinuxShareName, linuxTestfileName)
			})

			It("still runs Windows-based workloads after cluster restart", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				expectWorkloadToRun(ctx, windowsWorkloadName1, smbHostPrefix+storageConfig[0].LinuxShareName, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, smbHostPrefix+storageConfig[1].LinuxShareName, windowsTestfileName)
			})

			It("deletes Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "delete", "-k", linuxManifestDir)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().MustExec(ctx, "delete", "-k", windowsManifestDir)
			})

			It("disposes Linux-based workloads", func(ctx context.Context) {
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName2, namespace, ctx)
			})

			It("disposes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName2, namespace, ctx)
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx, "-f")
			})
		})
	})

	Describe("enable and disable with keep in Windows", func() {
		When("SMB host type is Windows", func() {
			It("enables the addon", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, implementationName, "-o")

				expectEnableMessage(output, "windows")
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted("windows", ctx)
			})

			It("deploys Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "apply", "-k", linuxManifestDir)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().MustExec(ctx, "apply", "-k", windowsManifestDir)
			})

			It("runs Linux-based workloads", func(ctx context.Context) {
				// TODO: could be more generic
				expectWorkloadToRun(ctx, linuxWorkloadName1, storageConfig[0].WinMountPath, linuxTestfileName)
				expectWorkloadToRun(ctx, linuxWorkloadName2, storageConfig[1].WinMountPath, linuxTestfileName)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				expectWorkloadToRun(ctx, windowsWorkloadName1, storageConfig[0].WinMountPath, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, storageConfig[1].WinMountPath, windowsTestfileName)
			})

			It("deletes Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "delete", "-k", linuxManifestDir)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().MustExec(ctx, "delete", "-k", windowsManifestDir)
			})

			It("disposes Linux-based workloads", func(ctx context.Context) {
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName2, namespace, ctx)
			})

			It("disposes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName2, namespace, ctx)
			})

			It("create the test files", func() {
				createTestFiles(storageConfig[0].WinMountPath)
				createTestFiles(storageConfig[1].WinMountPath)
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx, "-k")
			})

			It("checks that the test files are still available", func(ctx context.Context) {
				expectTestFilesAreAvailable(ctx, storageConfig[0].WinMountPath)
				expectTestFilesAreAvailable(ctx, storageConfig[1].WinMountPath)
			})

			It("deletes the test files", func() {
				deleteTestFiles(storageConfig[0].WinMountPath)
				deleteTestFiles(storageConfig[1].WinMountPath)
			})

			It("deletes the mount paths", func() {
				deleteMountPath(storageConfig[0].WinMountPath)
				deleteMountPath(storageConfig[1].WinMountPath)
			})
		})
	})

	Describe("enable and disable with keep in Linux", func() {
		When("SMB host type is Linux", func() {
			var smbHostPrefix string

			BeforeAll(func() {
				smbHostPrefix = `\\` + suite.SetupInfo().Config.ControlPlane().IpAddress() + `\`
			})

			It("enables the addon", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, implementationName, "-o", "-t", "linux")

				expectEnableMessage(output, "linux")
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted("linux", ctx)
			})

			It("deploys Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "apply", "-k", linuxManifestDir)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().MustExec(ctx, "apply", "-k", windowsManifestDir)
			})

			It("runs Linux-based workloads", func(ctx context.Context) {
				// TODO: could be more generic
				expectWorkloadToRun(ctx, linuxWorkloadName1, smbHostPrefix+storageConfig[0].LinuxShareName, linuxTestfileName)
				expectWorkloadToRun(ctx, linuxWorkloadName2, smbHostPrefix+storageConfig[1].LinuxShareName, linuxTestfileName)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				expectWorkloadToRun(ctx, windowsWorkloadName1, smbHostPrefix+storageConfig[0].LinuxShareName, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, smbHostPrefix+storageConfig[1].LinuxShareName, windowsTestfileName)
			})

			It("deletes Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "delete", "-k", linuxManifestDir)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().MustExec(ctx, "delete", "-k", windowsManifestDir)
			})

			It("disposes Linux-based workloads", func(ctx context.Context) {
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName2, namespace, ctx)
			})

			It("disposes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName2, namespace, ctx)
			})

			It("create the test files", func() {
				createTestFiles(smbHostPrefix + storageConfig[0].LinuxShareName)
				createTestFiles(smbHostPrefix + storageConfig[1].LinuxShareName)
			})

			It("checks that the test files are available", func(ctx context.Context) {
				expectFileAreAvailableInLinux(ctx, storageConfig[0].LinuxMountPath)
				expectFileAreAvailableInLinux(ctx, storageConfig[1].LinuxMountPath)
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx, "-k")
			})

			It("checks that the test files are still available", func(ctx context.Context) {
				expectFileAreAvailableInLinux(ctx, "/srv/samba/linux-smb-share1")
				expectFileAreAvailableInLinux(ctx, "/srv/samba/linux-smb-share2")
			})

			It("deletes the test files", func(ctx context.Context) {
				deleteFilesOnLinuxMount(ctx)
			})
		})
	})

	Describe("enable with preexisting folder in Windows", func() {
		When("SMB host type is Windows", func() {
			It("creates the mount paths", func() {
				createMountPath(storageConfig[0].WinMountPath)
				createMountPath(storageConfig[1].WinMountPath)

				createTestFiles(storageConfig[0].WinMountPath)
				createTestFiles(storageConfig[1].WinMountPath)
			})

			It("enables the addon", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, implementationName, "-o")

				expectEnableMessage(output, "windows")
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted("windows", ctx)
			})

			It("checks that the test files are still available", func(ctx context.Context) {
				expectTestFilesAreAvailable(ctx, storageConfig[0].WinMountPath)
				expectTestFilesAreAvailable(ctx, storageConfig[1].WinMountPath)
			})

			It("deploys Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "apply", "-k", linuxManifestDir)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().MustExec(ctx, "apply", "-k", windowsManifestDir)
			})

			It("runs Linux-based workloads", func(ctx context.Context) {
				// TODO: could be more generic
				expectWorkloadToRun(ctx, linuxWorkloadName1, storageConfig[0].WinMountPath, linuxTestfileName)
				expectWorkloadToRun(ctx, linuxWorkloadName2, storageConfig[1].WinMountPath, linuxTestfileName)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				expectWorkloadToRun(ctx, windowsWorkloadName1, storageConfig[0].WinMountPath, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, storageConfig[1].WinMountPath, windowsTestfileName)
			})

			It("deletes Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "delete", "-k", linuxManifestDir)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().MustExec(ctx, "delete", "-k", windowsManifestDir)
			})

			It("disposes Linux-based workloads", func(ctx context.Context) {
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName2, namespace, ctx)
			})

			It("disposes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName2, namespace, ctx)
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx, "-f")
			})

			It("deletes the mount paths", func() {
				deleteMountPath(storageConfig[0].WinMountPath)
				deleteMountPath(storageConfig[1].WinMountPath)
			})
		})
	})

	Describe("enable with pvc access mode readwritemany deployment in Windows", func() {
		BeforeAll(func() {
			if skipWindowsWorkloads {
				Skip("Linux-only setup")
			}
		})

		When("SMB host type is Windows", func() {
			It("enables the addon", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, implementationName, "-o")
				expectEnableMessage(output, "windows")
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted("windows", ctx)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "apply", "-k", accessModeManifestDir)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				expectSmbDeploymentToRun(ctx, storageConfig[0].WinMountPath, windowsTestfileName)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "delete", "-k", accessModeManifestDir)
			})

			It("disposes Windows-based workloads", func(ctx context.Context) {
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", windowsWorkloadName1, namespace)
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", windowsWorkloadName2, namespace)
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx, "-f")
			})
		})
	})

	Describe("Reclaim Policy Delete", func() {
		When("StorageClass with Delete reclaim policy", func() {
			pvNames := []string{}
			workloadPVCNames := []string{
				fmt.Sprintf("persistent-storage-%s-0", linuxWorkloadName1),
				fmt.Sprintf("persistent-storage-%s-0", linuxWorkloadName2),
			}

			BeforeAll(func() {
				if !skipWindowsWorkloads {
					workloadPVCNames = append(workloadPVCNames,
						fmt.Sprintf("persistent-storage-%s-0", windowsWorkloadName1),
						fmt.Sprintf("persistent-storage-%s-0", windowsWorkloadName2),
					)
				}
			})

			It("enables the addon", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, implementationName, "-o")
				expectEnableMessage(output, "windows")
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted("windows", ctx)
			})

			It("verifies the reclaim policy of storage class is Delete", func(ctx context.Context) {
				reclaimPolicy1 := suite.Kubectl().MustExec(ctx, "get", "storageclass", storageConfig[0].StorageClassName, "-o", "jsonpath={.reclaimPolicy}")
				GinkgoWriter.Printf("Reclaim policy for %s: %s\n", storageConfig[0].StorageClassName, reclaimPolicy1)
				Expect(reclaimPolicy1).To(Equal("Delete"))

				reclaimPolicy2 := suite.Kubectl().MustExec(ctx, "get", "storageclass", storageConfig[1].StorageClassName, "-o", "jsonpath={.reclaimPolicy}")
				GinkgoWriter.Printf("Reclaim policy for %s: %s\n", storageConfig[1].StorageClassName, reclaimPolicy2)
				Expect(reclaimPolicy2).To(Equal("Delete"))
			})

			It("deploys Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "apply", "-k", linuxManifestDir)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().MustExec(ctx, "apply", "-k", windowsManifestDir)
			})

			It("runs Linux-based workloads", func(ctx context.Context) {
				// TODO: could be more generic
				expectWorkloadToRun(ctx, linuxWorkloadName1, storageConfig[0].WinMountPath, linuxTestfileName)
				expectWorkloadToRun(ctx, linuxWorkloadName2, storageConfig[1].WinMountPath, linuxTestfileName)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				expectWorkloadToRun(ctx, windowsWorkloadName1, storageConfig[0].WinMountPath, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, storageConfig[1].WinMountPath, windowsTestfileName)
			})

			It("verifies PVCs are bound", func(ctx context.Context) {
				for _, pvcName := range workloadPVCNames {
					output := suite.Kubectl().MustExec(ctx, "get", "pvc", pvcName, "-n", namespace, "-o", "jsonpath={.status.phase}")
					Expect(output).To(Equal("Bound"), fmt.Sprintf("PVC %s should be Bound", pvcName))
				}
			})

			It("deletes Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "delete", "-k", linuxManifestDir)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().MustExec(ctx, "delete", "-k", windowsManifestDir)
			})

			It("disposes Linux-based workloads", func(ctx context.Context) {
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName2, namespace, ctx)
			})

			It("disposes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName2, namespace, ctx)
			})

			It("verifies PVC still exists after StatefulSet deletion", func(ctx context.Context) {
				for _, pvcName := range workloadPVCNames {
					output := suite.Kubectl().MustExec(ctx, "get", "pvc", pvcName, "-n", namespace, "-o", "jsonpath={.status.phase}")
					GinkgoWriter.Printf("\nPVC %s status: %s\n", pvcName, output)
					Expect(output).To(Equal("Bound"), fmt.Sprintf("PVC %s should be Bound", pvcName))

					// get pv name from pvc
					pvName := suite.Kubectl().MustExec(ctx, "get", "pvc", pvcName, "-n", namespace, "-o", "jsonpath={.spec.volumeName}")
					pvNames = append(pvNames, pvName)
					GinkgoWriter.Printf("\nPVC %s is bound to PV %s\n", pvcName, pvName)
				}
			})

			It("verifies content still exists after StatefulSet deletion", func(ctx context.Context) {
				expectFileExists(ctx, storageConfig[0].WinMountPath, linuxTestfileName, linuxWorkloadName1)
				expectFileExists(ctx, storageConfig[1].WinMountPath, linuxTestfileName, linuxWorkloadName2)

				if skipWindowsWorkloads {
					return
				}

				expectFileExists(ctx, storageConfig[0].WinMountPath, windowsTestfileName, windowsWorkloadName1)
				expectFileExists(ctx, storageConfig[1].WinMountPath, windowsTestfileName, windowsWorkloadName2)
			})

			It("deletes the PVC", func(ctx context.Context) {
				for _, pvcName := range workloadPVCNames {
					suite.Kubectl().MustExec(ctx, "delete", "pvc", pvcName, "-n", namespace)
				}
			})

			It("verifies PV is deleted with Delete reclaim policy", func(ctx context.Context) {
				for _, pvName := range pvNames {
					GinkgoWriter.Printf("Checking if PV %s is deleted\n", pvName)
					Eventually(func(ctx context.Context) string {
						return suite.Kubectl().MustExec(ctx, "get", "pv", pvName, "--ignore-not-found", "-o", "jsonpath={.metadata.name}")
					}).
						WithTimeout(time.Minute).
						WithPolling(time.Second*2).
						WithContext(ctx).
						Should(BeEmpty(), "PV should be deleted with Delete reclaim policy")
				}
			})

			It("verifies content is deleted with PV (Delete reclaim policy)", func(ctx context.Context) {
				expectFileDoesNotExist(ctx, storageConfig[0].WinMountPath, linuxTestfileName, linuxWorkloadName1)
				expectFileDoesNotExist(ctx, storageConfig[1].WinMountPath, linuxTestfileName, linuxWorkloadName2)

				if skipWindowsWorkloads {
					return
				}

				expectFileDoesNotExist(ctx, storageConfig[0].WinMountPath, windowsTestfileName, windowsWorkloadName1)
				expectFileDoesNotExist(ctx, storageConfig[1].WinMountPath, windowsTestfileName, windowsWorkloadName2)
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx, "-f")
			})
		})
	})

	Describe("Reclaim Policy Retain", func() {
		BeforeAll(func() {
			if skipWindowsWorkloads {
				Skip("Linux-only setup")
			}
		})

		When("StorageClass with Retain reclaim policy", func() {
			pvNames := []string{}
			workloadPVCNames := []string{
				fmt.Sprintf("persistent-storage-%s-0", windowsWorkloadName1),
				fmt.Sprintf("persistent-storage-%s-0", windowsWorkloadName2),
			}

			It("enables the addon", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, implementationName, "-o")
				expectEnableMessage(output, "windows")
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted("windows", ctx)
			})

			It("verifies the reclaim policy of storage class is Retain", func(ctx context.Context) {
				reclaimPolicy := suite.Kubectl().MustExec(ctx, "get", "storageclass", storageConfig[2].StorageClassName, "-o", "jsonpath={.reclaimPolicy}")
				GinkgoWriter.Printf("Reclaim policy for %s: %s\n", storageConfig[2].StorageClassName, reclaimPolicy)
				Expect(reclaimPolicy).To(Equal("Retain"))
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "apply", "-k", retainManifestDir)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				expectWorkloadToRun(ctx, windowsWorkloadName1, storageConfig[2].WinMountPath, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, storageConfig[2].WinMountPath, windowsTestfileName)
			})

			It("verifies PVCs are bound", func(ctx context.Context) {
				for _, pvcName := range workloadPVCNames {
					output := suite.Kubectl().MustExec(ctx, "get", "pvc", pvcName, "-n", namespace, "-o", "jsonpath={.status.phase}")
					GinkgoWriter.Printf("\nPVC %s status: %s\n", pvcName, output)
					Expect(output).To(Equal("Bound"), fmt.Sprintf("PVC %s should be Bound", pvcName))
				}
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "delete", "-k", retainManifestDir)
			})

			It("disposes Windows-based workloads", func(ctx context.Context) {
				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName2, namespace, ctx)
			})

			It("verifies PVC still exists after StatefulSet deletion", func(ctx context.Context) {
				for _, pvcName := range workloadPVCNames {
					output := suite.Kubectl().MustExec(ctx, "get", "pvc", pvcName, "-n", namespace, "-o", "jsonpath={.status.phase}")
					GinkgoWriter.Printf("\nPVC %s status: %s\n", pvcName, output)
					Expect(output).To(Equal("Bound"), fmt.Sprintf("PVC %s should be Bound", pvcName))

					// get pv name from pvc
					pvName := suite.Kubectl().MustExec(ctx, "get", "pvc", pvcName, "-n", namespace, "-o", "jsonpath={.spec.volumeName}")
					pvNames = append(pvNames, pvName)
					GinkgoWriter.Printf("\nPVC %s is bound to PV %s\n", pvcName, pvName)
				}
			})

			It("verifies content still exists after StatefulSet deletion", func(ctx context.Context) {
				expectFileExists(ctx, storageConfig[2].WinMountPath, windowsTestfileName, windowsWorkloadName1)
				expectFileExists(ctx, storageConfig[2].WinMountPath, windowsTestfileName, windowsWorkloadName2)
			})

			It("deletes the PVC", func(ctx context.Context) {
				for _, pvcName := range workloadPVCNames {
					suite.Kubectl().MustExec(ctx, "delete", "pvc", pvcName, "-n", namespace)
				}
			})

			It("verifies PV is retained with Retain reclaim policy", func(ctx context.Context) {
				for _, pvName := range pvNames {
					GinkgoWriter.Printf("\nChecking if PV %s is retained and in released state\n", pvName)
					Eventually(func(ctx context.Context) string {
						return suite.Kubectl().MustExec(ctx, "get", "pv", pvName, "-o", "jsonpath={.status.phase}")
					}).
						WithTimeout(time.Second*30).
						WithPolling(time.Second*2).
						WithContext(ctx).
						Should(Equal("Released"), "PV should be in Released state with Retain reclaim policy")
				}
			})

			It("verifies content still exists with PV (Retain reclaim policy)", func(ctx context.Context) {
				expectFileExists(ctx, storageConfig[2].WinMountPath, windowsTestfileName, windowsWorkloadName1)
				expectFileExists(ctx, storageConfig[2].WinMountPath, windowsTestfileName, windowsWorkloadName2)
			})

			It("cleans up the retained PV", func(ctx context.Context) {
				for _, pvName := range pvNames {
					suite.Kubectl().MustExec(ctx, "delete", "pv", pvName)
				}
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx, "-f")
			})
		})
	})

	Describe("Static Provisioning", func() {
		When("using static PV and PVC", func() {
			const (
				staticWorkloadName = "smb-static-test"
				staticPVName       = "smb-static-pv"
				staticPVCName      = "smb-static-pvc"
				staticTestFileName = "smb-share-test-linux.file"
				staticManifestDir  = "workloads/staticpv"
			)

			It("enables the addon with Windows host", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, implementationName, "-o")
				expectEnableMessage(output, "windows")
			})

			It("creates static PV and PVC", func(ctx context.Context) {
				GinkgoWriter.Printf("Creating static PV with source: %s\n", storageConfig[2].WinMountPath)

				suite.Kubectl().MustExec(ctx, "apply", "-k", staticManifestDir)
			})

			It("waits for PVC to be bound", func(ctx context.Context) {
				Eventually(func(ctx context.Context) string {
					return suite.Kubectl().MustExec(ctx, "get", "pvc", staticPVCName, "-n", namespace, "-o", "jsonpath={.status.phase}")
				}).
					WithTimeout(testFileCheckTimeout).
					WithPolling(time.Second*2).
					WithContext(ctx).
					Should(Equal("Bound"), "Static PVC should be bound to static PV")
			})

			It("waits for StatefulSet to be ready", func(ctx context.Context) {
				suite.Cluster().ExpectStatefulSetToBeReady(staticWorkloadName, namespace, 1, ctx)
			})

			It("verifies file exists on SMB share (static provisioning)", func(ctx context.Context) {
				Eventually(os.IsFileExists).
					WithArguments(storageConfig[2].WinMountPath, staticTestFileName).
					WithTimeout(testFileCheckTimeout).
					WithPolling(testFileCheckInterval).
					WithContext(ctx).
					Should(BeTrue(), fmt.Sprintf("File %s should exist in static PV mount path", staticTestFileName))
			})

			It("deletes the StatefulSet", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "delete", "statefulset", staticWorkloadName, "-n", namespace)
				suite.Cluster().ExpectStatefulSetToBeDeleted(staticWorkloadName, namespace, ctx)
			})

			It("verifies file still exists after workload deletion", func(ctx context.Context) {
				testFilePath := filepath.Join(storageConfig[2].WinMountPath, staticTestFileName)
				_, err := bos.Stat(testFilePath)
				Expect(err).ToNot(HaveOccurred(), "File should still exist after workload deletion")
			})

			It("deletes the PVC and PV", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "delete", "pvc", staticPVCName, "-n", namespace)
				suite.Kubectl().MustExec(ctx, "delete", "pv", staticPVName)
			})

			It("verifies file still exists after PVC deletion (Retain policy)", func(ctx context.Context) {
				testFilePath := filepath.Join(storageConfig[2].WinMountPath, staticTestFileName)
				_, err := bos.Stat(testFilePath)
				Expect(err).ToNot(HaveOccurred(), "File should still exist with Retain reclaim policy")
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx, "-f")
			})
		})
	})

	Describe("SMB 3.1.1 POSIX Extensions", func() {
		When("a POSIX-enabled StorageClass is hosted on the Linux Samba host", func() {
			posixPVCName := fmt.Sprintf("persistent-storage-%s-0", linuxPosixWorkloadName)

			BeforeAll(func() {
				Expect(kos.CopyFile(testConfigFileName, originalConfigPath)).To(Succeed())
			})

			It("enables the addon with the Linux SMB host", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, implementationName, "-o", "-t", "linux")

				expectEnableMessage(output, "linux")
			})

			It("generates POSIX mount options on the StorageClass", func(ctx context.Context) {
				mountOptions := suite.Kubectl().MustExec(ctx, "get", "storageclass", storageConfig[3].StorageClassName, "-o", "jsonpath={.mountOptions}")
				GinkgoWriter.Printf("Mount options for %s: %s\n", storageConfig[3].StorageClassName, mountOptions)

				Expect(mountOptions).To(ContainSubstring("vers=3.1.1"), "POSIX StorageClass should request the configured SMB dialect")
				Expect(mountOptions).NotTo(ContainSubstring("handletimeout"), "handletimeout is rejected by mount.cifs and conflicts with nobrl; it must not be in StorageClass mount options")
				Expect(mountOptions).NotTo(ContainSubstring("noperm"), "POSIX mode should not emulate permissions via noperm")
			})

			It("deploys the POSIX Linux workload", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "apply", "-k", linuxPosixManifestDir)
			})

			It("runs the POSIX Linux workload", func(ctx context.Context) {
				suite.Cluster().ExpectStatefulSetToBeReady(linuxPosixWorkloadName, namespace, 1, ctx)
			})

			It("verifies the PVC is bound", func(ctx context.Context) {
				output := suite.Kubectl().MustExec(ctx, "get", "pvc", posixPVCName, "-n", namespace, "-o", "jsonpath={.status.phase}")
				Expect(output).To(Equal("Bound"), fmt.Sprintf("PVC %s should be Bound", posixPVCName))
			})

			It("verifies POSIX symlink semantics are negotiated", func(ctx context.Context) {
				// The workload creates a symlink inside the SMB mount. A symlink can only be
				// created over SMB when the POSIX mfsymlinks behavior is negotiated, so a
				// resolvable symlink proves POSIX extensions are working end-to-end.
				output := suite.Kubectl().MustExec(ctx, "exec", fmt.Sprintf("%s-0", linuxPosixWorkloadName), "-n", namespace, "--", "sh", "-c", "test -L /mnt/smb/marker.link && cat /mnt/smb/marker.link")
				Expect(output).To(ContainSubstring("posix-marker"), "Symlink in the POSIX mount should resolve to the marker file")
			})

			It("deletes the POSIX Linux workload", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "delete", "-k", linuxPosixManifestDir)
			})

			It("disposes the POSIX Linux workload", func(ctx context.Context) {
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxPosixWorkloadName, namespace, ctx)
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx, "-f")
			})
		})
	})
})

func expectWorkloadToRun(ctx context.Context, workloadName, mountPath, testFileName string) {
	suite.Cluster().ExpectStatefulSetToBeReady(workloadName, namespace, 1, ctx)

	Eventually(os.IsFileYoungerThan).
		WithArguments(testFileCheckInterval, mountPath, testFileName).
		WithTimeout(testFileCheckTimeout).
		WithPolling(suite.TestStepPollInterval()).
		WithContext(ctx).
		Should(BeTrue(), fmt.Sprintf("Expected file check to pass for %s", workloadName))
}

func expectSmbDeploymentToRun(ctx context.Context, mountPath, testFileName string) {
	pvcName := "smb-pvc"
	suite.Cluster().ExpectPersistentVolumeToBeBound(pvcName, namespace, 1, ctx)

	deploymentName1 := "smb-share-test-windows1"
	deploymentName2 := "smb-share-test-windows2"

	suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName1, namespace)
	suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName1, namespace)

	suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName2, namespace)
	suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName2, namespace)

	Eventually(os.IsFileYoungerThan).
		WithArguments(testFileCheckInterval, mountPath, testFileName).
		WithTimeout(testFileCheckTimeout).
		WithPolling(suite.TestStepPollInterval()).
		WithContext(ctx).
		Should(BeTrue(), fmt.Sprintf("Expected file check to pass for %s", deploymentName1))
}

func disableAddon(ctx context.Context, option string) {
	if len(option) == 0 {
		option = "-f"
	}
	output := suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, implementationName, "-o", option)

	Expect(output).To(SatisfyAll(
		ContainSubstring("disable"),
		ContainSubstring(addonName),
		MatchRegexp("'k2s addons disable %s %s' completed", addonName, implementationName),
	))
}

func expectStatusToBePrinted(smbHostType string, ctx context.Context) {
	output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, implementationName)

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Implementation .+%s.+ of Addon .+%s.+ is .+enabled.+`, implementationName, addonName),
		MatchRegexp("SmbHostType: .+%s.+", smbHostType),
		MatchRegexp("SMB share is working, path: \\(%s <-> %s\\)", regexp.QuoteMeta(storageConfig[0].WinMountPath), regexp.QuoteMeta(storageConfig[0].LinuxMountPath)),
		MatchRegexp("SMB share is working, path: \\(%s <-> %s\\)", regexp.QuoteMeta(storageConfig[1].WinMountPath), regexp.QuoteMeta(storageConfig[1].LinuxMountPath)),
		MatchRegexp("CSI Pods are running"),
	))

	output = suite.K2sCli().MustExec(ctx, "addons", "status", addonName, implementationName, "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal(addonName))
	Expect(status.Implementation).To(Equal(implementationName))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
	Expect(status.Props).NotTo(BeNil())
	Expect(status.Props).To(ContainElements(
		SatisfyAll(
			HaveField("Name", "SmbHostType"),
			HaveField("Value", smbHostType)),
		SatisfyAll(
			HaveField("Name", "ShareForStorageClass_"+storageConfig[0].StorageClassName),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("SMB share is working")))),
		SatisfyAll(
			HaveField("Name", "ShareForStorageClass_"+storageConfig[1].StorageClassName),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("SMB share is working")))),
		SatisfyAll(
			HaveField("Name", "AreCsiPodsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("CSI Pods are running")))),
	))
}

func expectEnableMessage(output string, smbHostType string) {
	Expect(output).To(SatisfyAll(
		MatchRegexp("Enabling addon \\'%s\\' with SMB host type \\'%s\\'", addonName, smbHostType),
		MatchRegexp("'k2s addons enable %s %s' completed", addonName, implementationName),
	))
}

func createTestFiles(mountPath string) {
	fileNames := []string{"file1.txt", "file2.txt", "file3.txt"}
	for _, fileName := range fileNames {
		filePath := filepath.Join(mountPath, fileName)
		err := bos.WriteFile(filePath, []byte("test content"), fs.ModePerm)
		Expect(err).NotTo(HaveOccurred())
	}
}

func expectTestFilesAreAvailable(ctx context.Context, mountPath string) {
	fileNames := []string{"file1.txt", "file2.txt", "file3.txt"}
	for _, fileName := range fileNames {
		// check only if the file exists and is not empty
		Eventually(os.IsFileYoungerThan).
			WithArguments(testFileCreationTimeout, mountPath, fileName).
			WithTimeout(testFileOverallTimeout).
			WithPolling(suite.TestStepPollInterval()).
			WithContext(ctx).
			Should(BeTrue(), fmt.Sprintf("Expected file %s to be available in %s", fileName, mountPath))
	}
}

func deleteTestFiles(mountPath string) {
	fileNames := []string{"file1.txt", "file2.txt", "file3.txt"}
	for _, fileName := range fileNames {
		filePath := filepath.Join(mountPath, fileName)
		err := bos.Remove(filePath)
		Expect(err).NotTo(HaveOccurred())
	}
}

func createMountPath(mountPath string) {
	err := bos.MkdirAll(mountPath, fs.ModePerm)
	Expect(err).NotTo(HaveOccurred())
}

func deleteMountPath(mountPath string) {
	err := bos.RemoveAll(mountPath)
	Expect(err).NotTo(HaveOccurred())
}

func expectFileAreAvailableInLinux(ctx context.Context, sharefolder string) {
	// execute command and check output if it contains the filename file1.txt and file2.txt
	output := suite.K2sCli().MustExec(ctx, "node", "exec", "-i", "172.19.1.100", "-u", "remote", "-c", fmt.Sprintf("ls %s", sharefolder))
	Expect(output).To(ContainSubstring("file1.txt"))
	Expect(output).To(ContainSubstring("file2.txt"))
	Expect(output).To(ContainSubstring("file3.txt"))
}

func deleteFilesOnLinuxMount(ctx context.Context) {
	// if boolLinuxOnly is true, then only delete files on linux mount
	share1 := "/srv/samba/linux-smb-share1"
	share2 := "/srv/samba/linux-smb-share2"

	// execute command and check output if it contains the filename file1.txt and file2.txt
	output1 := suite.K2sCli().MustExec(ctx, "node", "exec", "-i", "172.19.1.100", "-u", "remote", "-c", fmt.Sprintf("sudo rm -r %s", share1))
	Expect(output1).To(SatisfyAll(
		ContainSubstring("completed in"),
	))
	output2 := suite.K2sCli().MustExec(ctx, "node", "exec", "-i", "172.19.1.100", "-u", "remote", "-c", fmt.Sprintf("sudo rm -r %s", share2))
	Expect(output2).To(SatisfyAll(
		ContainSubstring("completed in"),
	))
}

func expectFileExists(ctx context.Context, mountPath string, testFileName string, deploymentName string) {
	Eventually(os.IsFileExists).
		WithArguments(mountPath, testFileName).
		WithTimeout(testFileCheckTimeout).
		WithPolling(suite.TestStepPollInterval()).
		WithContext(ctx).
		Should(BeTrue(), fmt.Sprintf("Expected file check to pass for %s", deploymentName))
}

func expectFileDoesNotExist(ctx context.Context, mountPath string, testFileName string, deploymentName string) {
	Eventually(os.IsFileExists).
		WithArguments(mountPath, testFileName).
		WithTimeout(testFileCheckTimeout).
		WithPolling(suite.TestStepPollInterval()).
		WithContext(ctx).
		Should(BeFalse(), fmt.Sprintf("Expected file does not exist for %s", deploymentName))
}
