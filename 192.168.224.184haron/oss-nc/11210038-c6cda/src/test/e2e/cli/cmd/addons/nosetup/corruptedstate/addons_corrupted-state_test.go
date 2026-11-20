// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0
package corruptedstate

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	contracts "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/addons"
	"github.com/k2s-project/k2s/internal/core/config"
	kos "github.com/k2s-project/k2s/internal/os"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"
)

var suite *framework.K2sTestSuite
var allAddons addons.Addons

func TestAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons CLI Commands Acceptance Tests", Label("cli", "acceptance", "no-setup", "corrupted-state", "addons"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
	allAddons = suite.AddonsAdditionalInfo().AllAddons()
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("addons commands", Ordered, func() {
	var configPath string

	BeforeEach(func() {
		inputConfig := map[string]any{
			"SetupName":  "k2s",
			"Registries": []string{"r1", "r2"},
			"LinuxOnly":  true,
			"Version":    "test-version",
			"Corrupted":  true,
		}
		inputData, err := json.Marshal(inputConfig)
		Expect(err).ToNot(HaveOccurred())

		currentDir, err := kos.ExecutableDir()
		Expect(err).ToNot(HaveOccurred())
		installDir := filepath.Join(currentDir, "..\\..\\..\\..\\..\\..\\..\\..")

		GinkgoWriter.Println("Current test dir: <", currentDir, ">, install dir: <", installDir, ">")

		config, err := config.ReadK2sConfig(installDir)
		Expect(err).ToNot(HaveOccurred())

		GinkgoWriter.Println("Creating <", config.Host().K2sSetupConfigDir(), ">..")

		Expect(os.MkdirAll(config.Host().K2sSetupConfigDir(), os.ModePerm)).To(Succeed())

		configPath = filepath.Join(config.Host().K2sSetupConfigDir(), "setup.json")

		GinkgoWriter.Println("Writing test data to <", configPath, ">..")

		Expect(os.WriteFile(configPath, inputData, os.ModePerm)).To(Succeed())

		DeferCleanup(func() {
			GinkgoWriter.Println("Deleting <", config.Host().K2sSetupConfigDir(), ">..")

			Expect(os.RemoveAll(config.Host().K2sSetupConfigDir())).To(Succeed())
		})
	})

	Describe("ls", Ordered, func() {
		var output string

		BeforeAll(func(ctx context.Context) {
			output, _ = suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "ls")
		})

		It("prints system-in-corrupted-state message", func() {
			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})

	Describe("status", func() {
		Context("standard output", func() {
			It("prints system-in-corrupted-state message for all addons and exits with non-zero", func(ctx context.Context) {
				for _, addon := range allAddons {
					for _, impl := range addon.Spec.Implementations {
						GinkgoWriter.Println("Calling addons status for", impl.AddonsCmdName)

						var output string
						if addon.Metadata.Name == impl.Name {
							output, _ = suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "status", addon.Metadata.Name)
						} else {
							output, _ = suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "status", addon.Metadata.Name, impl.Name)
						}

						Expect(output).To(ContainSubstring("corrupted state"))
					}
				}
			})
		})

		Context("JSON output", func() {
			It("contains only system-in-corrupted-state info and name and exits with non-zero", func(ctx context.Context) {
				for _, addon := range allAddons {
					for _, impl := range addon.Spec.Implementations {
						GinkgoWriter.Println("Calling addons status for", impl.AddonsCmdName)

						var output string
						if addon.Metadata.Name == impl.Name {
							output, _ = suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "status", addon.Metadata.Name, "-o", "json")
						} else {
							output, _ = suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "status", addon.Metadata.Name, impl.Name, "-o", "json")
						}

						var status status.AddonPrintStatus

						Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

						Expect(status.Enabled).To(BeNil())
						Expect(status.Name).To(Equal(addon.Metadata.Name))
						Expect(*status.Error).To(Equal(contracts.ErrSystemInCorruptedState.Error()))
						Expect(status.Props).To(BeEmpty())
					}
				}
			})
		})
	})

	Describe("disable", func() {
		It("prints system-in-corrupted-state message for all addons and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				for _, impl := range addon.Spec.Implementations {
					GinkgoWriter.Println("Calling addons disable for", impl.AddonsCmdName)

					var output string
					if addon.Metadata.Name == impl.Name {
						output, _ = suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", addon.Metadata.Name)
					} else {
						output, _ = suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", addon.Metadata.Name, impl.Name)
					}

					Expect(output).To(ContainSubstring("corrupted state"))
				}
			}
		})
	})

	Describe("enable", func() {
		It("prints system-in-corrupted-state message for all addons and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				for _, impl := range addon.Spec.Implementations {
					GinkgoWriter.Println("Calling addons disable for", impl.AddonsCmdName)

					var output string
					if addon.Metadata.Name == impl.Name {
						output, _ = suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", addon.Metadata.Name)
					} else {
						output, _ = suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", addon.Metadata.Name, impl.Name)
					}

					Expect(output).To(ContainSubstring("corrupted state"))
				}
			}
		})
	})

	Describe("export", func() {
		It("prints system-in-corrupted-state message for each addon and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				for _, impl := range addon.Spec.Implementations {
					GinkgoWriter.Println("Calling addons export for", impl.AddonsCmdName)

					output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "export", impl.AddonsCmdName, "-d", "test-dir")

					Expect(output).To(ContainSubstring("corrupted state"))
				}
			}
		})

		It("prints system-in-corrupted-state message for all addons and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "export", "-d", "test-dir")

			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})

	Describe("import", func() {
		It("prints system-in-corrupted-state message for each addon and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				for _, impl := range addon.Spec.Implementations {
					GinkgoWriter.Println("Calling addons import for", impl.AddonsCmdName)

					output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "import", impl.AddonsCmdName, "-f", "test-dir")

					Expect(output).To(ContainSubstring("corrupted state"))
				}
			}
		})

		It("prints system-in-corrupted-state message for all addons and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "import", "-f", "test-dir")

			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})
})
