// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package upgrade

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/utils"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/definitions"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestUpgrade(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "upgrade Unit Tests", Label("unit", "ci"))
}

var _ = BeforeSuite(func() {
	UpgradeCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
})

// Helper function to reset all flags to their default values
func resetAllFlags() {
	flags := UpgradeCmd.Flags()
	flags.Set(common.OutputFlagName, "false")
	flags.Set(skipK8sResources, "false")
	flags.Set(deleteFiles, "false")
	flags.Set(configFileFlagName, "")
	flags.Set(proxy, "")
	flags.Set(skipImagesFlag, "false")
	flags.Set(common.AdditionalHooksDirFlagName, "")
	flags.Set(backupDir, "")
	flags.Set(force, "false")
}

var _ = Describe("upgrade", func() {
	Describe("createUpgradeCommand", func() {
		When("no flags set", func() {
			It("creates the command", func() {
				const staticPartOfExpectedCmd = `\lib\scripts\windows\host\system\upgrade\Start-ClusterUpgrade.ps1`
				expected := utils.FormatScriptFilePath(utils.InstallDir() + staticPartOfExpectedCmd)

				actual := createUpgradeCommand(UpgradeCmd)

				Expect(actual).To(Equal(expected))
			})
		})

		When("flags set", func() {
			It("creates the command", func() {
				const staticPartOfExpectedCmd = `\lib\scripts\windows\host\system\upgrade\Start-ClusterUpgrade.ps1`
				const args = ` -ShowLogs -SkipResources  -DeleteFiles  -Config 'config.yaml' -Proxy 'http://myproxy:81' -SkipImages -AdditionalHooksDir 'hookDir' -BackupDir 'backupDir'`
				expected := utils.FormatScriptFilePath(utils.InstallDir()+staticPartOfExpectedCmd) + args

				flags := UpgradeCmd.Flags()
				flags.Set(common.OutputFlagName, "true")
				flags.Set(skipK8sResources, "true")
				flags.Set(deleteFiles, "true")
				flags.Set(configFileFlagName, "config.yaml")
				flags.Set(proxy, "http://myproxy:81")
				flags.Set(skipImagesFlag, "true")
				flags.Set(common.AdditionalHooksDirFlagName, "hookDir")
				flags.Set(backupDir, "backupDir")

				actual := createUpgradeCommand(UpgradeCmd)

				Expect(actual).To(Equal(expected))
			})
		})

		When("force flag is set", func() {
			It("creates the command with force flag", func() {
				const staticPartOfExpectedCmd = `\lib\scripts\windows\host\system\upgrade\Start-ClusterUpgrade.ps1`
				const args = ` -Force`
				expected := utils.FormatScriptFilePath(utils.InstallDir()+staticPartOfExpectedCmd) + args

				// Reset all flags to default values
				resetAllFlags()
				// Set only the flag under test
				UpgradeCmd.Flags().Set(force, "true")

				actual := createUpgradeCommand(UpgradeCmd)

				Expect(actual).To(Equal(expected))
			})
		})
	})

	Describe("prepareUpgradeInstallConfig", func() {
		It("validates, normalizes, and stages the replacement independently of its source", func() {
			sourceDir := GinkgoT().TempDir()
			sourcePath := filepath.Join(sourceDir, "replacement config.yaml")
			content := []byte(`kind: k2s
apiVersion: v1
nodes:
  - role: control-plane
    resources:
      cpu: 6
      memory: 6GB
      disk: 50GB
kubeletOverrides:
  linuxControlPlane:
    enabled: true
    config:
      maxPods: 42
`)
			Expect(os.WriteFile(sourcePath, content, 0o600)).To(Succeed())

			stagedPath, cleanup, err := prepareUpgradeInstallConfig(sourcePath, "")

			Expect(err).ToNot(HaveOccurred())
			Expect(stagedPath).ToNot(Equal(sourcePath))
			Expect(filepath.Dir(stagedPath)).ToNot(Equal(sourceDir))
			Expect(os.Remove(sourcePath)).To(Succeed())
			stagedContent, err := os.ReadFile(stagedPath)
			Expect(err).ToNot(HaveOccurred())
			var normalized map[string]any
			Expect(json.Unmarshal(stagedContent, &normalized)).To(Succeed())
			Expect(normalized).To(HaveKey("kubeletOverrides"))
			Expect(cleanup()).To(Succeed())
			_, err = os.Stat(stagedPath)
			Expect(os.IsNotExist(err)).To(BeTrue())
		})

		It("rejects an invalid replacement before staging", func() {
			sourcePath := filepath.Join(GinkgoT().TempDir(), "invalid.yaml")
			content := []byte(`kind: k2s
apiVersion: v1
nodes:
  - role: control-plane
kubeletOverrides:
  linuxControlPlane:
    enabled: true
    config:
      unsupported: true
`)
			Expect(os.WriteFile(sourcePath, content, 0o600)).To(Succeed())

			stagedPath, cleanup, err := prepareUpgradeInstallConfig(sourcePath, "")

			Expect(err).To(MatchError(ContainSubstring("unsupported")))
			Expect(stagedPath).To(BeEmpty())
			Expect(cleanup).To(BeNil())
		})

		It("rejects a missing explicit replacement", func() {
			sourcePath := filepath.Join(GinkgoT().TempDir(), "missing.yaml")

			stagedPath, cleanup, err := prepareUpgradeInstallConfig(sourcePath, "")

			Expect(errors.Is(err, os.ErrNotExist)).To(BeTrue())
			Expect(stagedPath).To(BeEmpty())
			Expect(cleanup).To(BeNil())
		})

		It("validates and stages the linked stored configuration", func() {
			setupDir := GinkgoT().TempDir()
			storedPath := filepath.Join(setupDir, definitions.EffectiveInstallConfigFileName)
			storedConfig := []byte(`{"kind":"k2s","apiVersion":"v1","nodes":[{"role":"control-plane","resources":{"cpu":6,"memory":"6GB","disk":"50GB"}}]}`)
			Expect(os.WriteFile(storedPath, storedConfig, 0o600)).To(Succeed())
			setup, err := json.Marshal(map[string]any{definitions.EffectiveInstallConfigPathKey: storedPath})
			Expect(err).ToNot(HaveOccurred())
			Expect(os.WriteFile(filepath.Join(setupDir, definitions.K2sRuntimeConfigFileName), setup, 0o600)).To(Succeed())

			stagedPath, cleanup, err := prepareUpgradeInstallConfig("", setupDir)

			Expect(err).ToNot(HaveOccurred())
			Expect(stagedPath).ToNot(Equal(storedPath))
			Expect(cleanup()).To(Succeed())
		})

		It("continues without a config when the linked stored configuration is missing", func() {
			setupDir := GinkgoT().TempDir()
			storedPath := filepath.Join(setupDir, definitions.EffectiveInstallConfigFileName)
			setup, err := json.Marshal(map[string]any{definitions.EffectiveInstallConfigPathKey: storedPath})
			Expect(err).ToNot(HaveOccurred())
			Expect(os.WriteFile(filepath.Join(setupDir, definitions.K2sRuntimeConfigFileName), setup, 0o600)).To(Succeed())

			stagedPath, cleanup, err := prepareUpgradeInstallConfig("", setupDir)

			Expect(err).ToNot(HaveOccurred())
			Expect(stagedPath).To(BeEmpty())
			Expect(cleanup()).To(Succeed())
		})

		It("rejects an invalid linked stored configuration", func() {
			setupDir := GinkgoT().TempDir()
			storedPath := filepath.Join(setupDir, definitions.EffectiveInstallConfigFileName)
			storedConfig := []byte(`{"kind":"k2s","apiVersion":"v1","nodes":[{"role":"control-plane"}],"kubeletOverrides":{"linuxControlPlane":{"enabled":true,"config":{"unsupported":true}}}}`)
			Expect(os.WriteFile(storedPath, storedConfig, 0o600)).To(Succeed())
			setup, err := json.Marshal(map[string]any{definitions.EffectiveInstallConfigPathKey: storedPath})
			Expect(err).ToNot(HaveOccurred())
			Expect(os.WriteFile(filepath.Join(setupDir, definitions.K2sRuntimeConfigFileName), setup, 0o600)).To(Succeed())

			stagedPath, cleanup, err := prepareUpgradeInstallConfig("", setupDir)

			Expect(err).To(HaveOccurred())
			Expect(stagedPath).To(BeEmpty())
			Expect(cleanup).To(BeNil())
		})

		It("continues without a config for a legacy setup without a snapshot link", func() {
			setupDir := GinkgoT().TempDir()
			Expect(os.WriteFile(filepath.Join(setupDir, definitions.K2sRuntimeConfigFileName), []byte(`{"SetupType":"k2s"}`), 0o600)).To(Succeed())

			stagedPath, cleanup, err := prepareUpgradeInstallConfig("", setupDir)

			Expect(err).ToNot(HaveOccurred())
			Expect(stagedPath).To(BeEmpty())
			Expect(cleanup()).To(Succeed())
		})
	})

	Describe("applySetupConfigDirOverride", func() {
		var packageInstallDir string
		var packageConfigFile string
		var originalConfigContent []byte

		// realistic package config file; it must never be touched by the upgrade.
		const packageConfigJson = `{
  "smallsetup": { "masterIP": "172.19.1.100" },
  "clusterName": "k2s-cluster",
  "configDir": {
    "kube": "~/.kube",
    "k2s": "C:\\ProgramData\\K2s",
    "ssh": "~/.ssh",
    "docker": "~/.docker",
    "logs": "C:\\var\\log"
  }
}`

		BeforeEach(func() {
			// isolate the env var per spec
			GinkgoT().Setenv(definitions.SetupConfigDirEnvVar, "")
			Expect(os.Unsetenv(definitions.SetupConfigDirEnvVar)).To(Succeed())

			packageInstallDir = GinkgoT().TempDir()
			Expect(os.MkdirAll(filepath.Join(packageInstallDir, "cfg"), os.ModePerm)).To(Succeed())
			packageConfigFile = filepath.Join(packageInstallDir, "cfg", "config.json")
			Expect(os.WriteFile(packageConfigFile, []byte(packageConfigJson), os.ModePerm)).To(Succeed())

			var err error
			originalConfigContent, err = os.ReadFile(packageConfigFile)
			Expect(err).ToNot(HaveOccurred())
		})

		// The package's config file is the source of truth of the NEW installation and
		// must never be modified by the upgrade.
		AfterEach(func() {
			currentContent, err := os.ReadFile(packageConfigFile)
			Expect(err).ToNot(HaveOccurred())
			Expect(currentContent).To(Equal(originalConfigContent), "the package's cfg/config.json must never be modified")

			var parsed map[string]any
			Expect(json.Unmarshal(currentContent, &parsed)).To(Succeed())
			Expect(parsed["configDir"].(map[string]any)["k2s"]).To(Equal(`C:\ProgramData\K2s`))
		})

		When("the old installation uses a custom config dir and the package uses the default one", func() {
			It("sets the override to the old config dir", func() {
				err := applySetupConfigDirOverride(`C:\DummySetup\K2s`, `C:\ProgramData\K2s`)

				Expect(err).ToNot(HaveOccurred())
				Expect(os.Getenv(definitions.SetupConfigDirEnvVar)).To(Equal(`C:\DummySetup\K2s`))
			})
		})

		When("the old installation and the package both use the default config dir", func() {
			It("does not set the override", func() {
				err := applySetupConfigDirOverride(`C:\ProgramData\K2s`, `C:\ProgramData\K2s`)

				Expect(err).ToNot(HaveOccurred())

				_, isSet := os.LookupEnv(definitions.SetupConfigDirEnvVar)
				Expect(isSet).To(BeFalse())
			})
		})

		When("the old installation uses a custom config dir and the package uses a different custom one", func() {
			It("sets the override to the old config dir", func() {
				err := applySetupConfigDirOverride(`C:\DummySetup\K2s`, `D:\CustomPkg\K2s`)

				Expect(err).ToNot(HaveOccurred())
				Expect(os.Getenv(definitions.SetupConfigDirEnvVar)).To(Equal(`C:\DummySetup\K2s`))
			})
		})

		When("no config dir could be resolved", func() {
			It("does not set the override", func() {
				err := applySetupConfigDirOverride("", `C:\ProgramData\K2s`)

				Expect(err).ToNot(HaveOccurred())

				_, isSet := os.LookupEnv(definitions.SetupConfigDirEnvVar)
				Expect(isSet).To(BeFalse())
			})
		})

		// Windows paths are case-insensitive: the same dir written in different casing must
		// not trigger a redundant override.
		When("both config dirs denote the same dir but differ in casing", func() {
			It("does not set the override on Windows", func() {
				if runtime.GOOS != "windows" {
					Skip("path comparison is only case-insensitive on Windows")
				}

				err := applySetupConfigDirOverride(`C:\ProgramData\K2s`, `c:\programdata\k2s`)

				Expect(err).ToNot(HaveOccurred())

				_, isSet := os.LookupEnv(definitions.SetupConfigDirEnvVar)
				Expect(isSet).To(BeFalse())
			})
		})

		When("both config dirs denote the same dir but differ in trailing separators", func() {
			It("does not set the override", func() {
				err := applySetupConfigDirOverride(`C:\ProgramData\K2s\`, `C:\ProgramData\K2s`)

				Expect(err).ToNot(HaveOccurred())

				_, isSet := os.LookupEnv(definitions.SetupConfigDirEnvVar)
				Expect(isSet).To(BeFalse())
			})
		})
	})

	Describe("readInstalledConfigFromPath", func() {
		// stubResolveInstalledK2s replaces the PATH-based discovery for the current spec.
		stubResolveInstalledK2s := func(installed *config.InstalledK2s, err error) {
			original := resolveInstalledK2s
			DeferCleanup(func() { resolveInstalledK2s = original })

			resolveInstalledK2s = func() (*config.InstalledK2s, error) {
				return installed, err
			}
		}

		newInstalled := func(configDir string, version string) *config.InstalledK2s {
			hostConfig := cconfig.NewHostConfig(nil, nil, configDir, `D:\ws\K2s\1.6.0`, "")
			installConfig := cconfig.NewK2sInstallConfig("k2s", false, version, false, false)

			return &config.InstalledK2s{
				InstallDir:    `D:\ws\K2s\1.6.0`,
				Config:        cconfig.NewK2sConfig(hostConfig, nil),
				RuntimeConfig: cconfig.NewK2sRuntimeConfig(nil, installConfig, nil),
			}
		}

		When("an installation with a custom config dir is discovered", func() {
			It("returns its runtime config and setup config dir", func() {
				stubResolveInstalledK2s(newInstalled(`C:\DummySetup\K2s`, "1.8.1"), nil)

				runtimeConfig, configDir, err := readInstalledConfigFromPath()

				Expect(err).ToNot(HaveOccurred())
				Expect(configDir).To(Equal(`C:\DummySetup\K2s`))
				Expect(runtimeConfig).ToNot(BeNil())
				Expect(runtimeConfig.InstallConfig().Version()).To(Equal("1.8.1"))
			})
		})

		// A corrupted installation is still an existing installation.
		When("the discovered installation is in corrupted state", func() {
			It("returns its config dir and preserves the corrupted-state error", func() {
				stubResolveInstalledK2s(newInstalled(`C:\DummySetup\K2s`, "1.8.1"), cconfig.ErrSystemInCorruptedState)

				runtimeConfig, configDir, err := readInstalledConfigFromPath()

				Expect(errors.Is(err, cconfig.ErrSystemInCorruptedState)).To(BeTrue())
				Expect(configDir).To(Equal(`C:\DummySetup\K2s`))
				Expect(runtimeConfig).ToNot(BeNil())
			})
		})

		When("no installation is found", func() {
			It("returns the system-not-installed error", func() {
				stubResolveInstalledK2s(nil, cconfig.ErrSystemNotInstalled)

				runtimeConfig, configDir, err := readInstalledConfigFromPath()

				Expect(err).To(MatchError(cconfig.ErrSystemNotInstalled))
				Expect(configDir).To(BeEmpty())
				Expect(runtimeConfig).To(BeNil())
			})
		})

		When("discovery fails with another error", func() {
			It("propagates that error", func() {
				discoveryErr := errors.New("found multiple installed K2s")
				stubResolveInstalledK2s(nil, discoveryErr)

				runtimeConfig, configDir, err := readInstalledConfigFromPath()

				Expect(err).To(MatchError(discoveryErr))
				Expect(configDir).To(BeEmpty())
				Expect(runtimeConfig).To(BeNil())
			})
		})

		// Defensive: an error must never be masked by ErrSystemNotInstalled.
		When("no installation is returned together with the corrupted-state error", func() {
			It("preserves the corrupted-state error", func() {
				stubResolveInstalledK2s(nil, cconfig.ErrSystemInCorruptedState)

				runtimeConfig, configDir, err := readInstalledConfigFromPath()

				Expect(errors.Is(err, cconfig.ErrSystemInCorruptedState)).To(BeTrue())
				Expect(configDir).To(BeEmpty())
				Expect(runtimeConfig).To(BeNil())
			})
		})

		When("no installation and no error are returned", func() {
			It("returns the system-not-installed error", func() {
				stubResolveInstalledK2s(nil, nil)

				_, _, err := readInstalledConfigFromPath()

				Expect(err).To(MatchError(cconfig.ErrSystemNotInstalled))
			})
		})
	})
})
