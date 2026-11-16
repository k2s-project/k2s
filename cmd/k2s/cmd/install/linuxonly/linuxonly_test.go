// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package linuxonly_test

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/install/config"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/install/linuxonly"
	"github.com/k2s-project/k2s/cmd/k2s/utils"
)

func Test(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "linuxonly Unit Tests", Label("unit", "ci", "linux-only"))
}

var _ = Describe("linuxonly", func() {
	Describe("BuildCmd", func() {
		When("WSL is enabled", func() {
			It("returns an error", func() {
				config := &config.InstallConfig{
					Behavior: config.BehaviorConfig{Wsl: true},
				}

				actual, err := linuxonly.BuildCmd(config)

				Expect(actual).To(BeEmpty())
				Expect(err).To(MatchError(linuxonly.ErrWslNotSupported))
			})
		})

		When("control-plane config not found", func() {
			It("returns an error", func() {
				config := &config.InstallConfig{}

				actual, err := linuxonly.BuildCmd(config)

				Expect(actual).To(BeEmpty())
				Expect(err).To(MatchError(ContainSubstring("node config not found")))
			})
		})

		When("minimal config set", func() {
			It("returns cmd with minimal params", func() {
				const rawExpected = `\lib\scripts\windows\linuxonly\install\install.ps1' -MasterVMProcessorCount 5 -MasterVMMemory 6GB -MasterDiskSize 7GB`
				expected := "&'" + utils.InstallDir() + rawExpected

				config := &config.InstallConfig{
					Nodes: []config.NodeConfig{
						{
							Role: config.ControlPlaneRoleName,
							Resources: config.ResourceConfig{
								Cpu:    "5",
								Memory: "6GB",
								Disk:   "7GB",
							},
						},
					},
				}

				actual, err := linuxonly.BuildCmd(config)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("maximal config set", func() {
			It("returns cmd with maximal params", func() {
				const rawExpected = `\lib\scripts\windows\linuxonly\install\install.ps1' -MasterVMProcessorCount 5 -MasterVMMemory 6GB -MasterDiskSize 7GB` +
					` -Proxy 'my_proxy' -AdditionalHooksDir 'c:\my\dir' -ShowLogs -SkipStart -DeleteFilesForOfflineInstallation -ForceOnlineInstallation -AppendLogFile`
				expected := "&'" + utils.InstallDir() + rawExpected

				config := &config.InstallConfig{
					Nodes: []config.NodeConfig{
						{
							Role: config.ControlPlaneRoleName,
							Resources: config.ResourceConfig{
								Cpu:    "5",
								Memory: "6GB",
								Disk:   "7GB",
							}},
					},
					Env: config.EnvConfig{
						Proxy:              "my_proxy",
						AdditionalHooksDir: "c:\\my\\dir",
					},
					Behavior: config.BehaviorConfig{
						ShowOutput:                        true,
						DeleteFilesForOfflineInstallation: true,
						ForceOnlineInstallation:           true,
						AppendLog:                         true,
						SkipStart:                         true,
					},
				}

				actual, err := linuxonly.BuildCmd(config)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("string values contain single quotes", func() {
			It("returns cmd with the values escaped as PowerShell string literals", func() {
				const rawExpected = `\lib\scripts\windows\linuxonly\install\install.ps1' -MasterVMProcessorCount 5 -MasterVMMemory 6GB -MasterDiskSize 7GB` +
					` -Proxy 'http://x''; calc; ''' -NoProxy 'localhost','x''; calc; ''' -AdditionalHooksDir 'c:\owner''s dir'`
				expected := "&'" + utils.InstallDir() + rawExpected

				config := &config.InstallConfig{
					Nodes: []config.NodeConfig{
						{
							Role: config.ControlPlaneRoleName,
							Resources: config.ResourceConfig{
								Cpu:    "5",
								Memory: "6GB",
								Disk:   "7GB",
							}},
					},
					Env: config.EnvConfig{
						Proxy:              "http://x'; calc; '",
						NoProxy:            []string{"localhost", "x'; calc; '"},
						AdditionalHooksDir: "c:\\owner's dir",
					},
				}

				actual, err := linuxonly.BuildCmd(config)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})
	})
})
