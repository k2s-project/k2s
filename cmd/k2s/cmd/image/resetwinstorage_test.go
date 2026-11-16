// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strconv"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/utils"
	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/test/reflection"
	"github.com/stretchr/testify/mock"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type mockRuntimeConfigProvider struct {
	mock.Mock
}

func (m *mockRuntimeConfigProvider) ReadConfig(configDir string) (*config.K2sRuntimeConfig, error) {
	args := m.Called(configDir)
	return args.Get(0).(*config.K2sRuntimeConfig), args.Error(1)
}

type mockPowershellExecutor struct {
	mock.Mock
}

func (m *mockPowershellExecutor) ExecutePsWithStructuredResult(psCmd string, params ...string) (*common.CmdResult, error) {
	args := m.Called(psCmd, params)
	return args.Get(0).(*common.CmdResult), args.Error(1)
}

var _ = Describe("reset-win-storage", Ordered, func() {
	BeforeAll(func() {
		resetWinStorageCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})
	BeforeEach(func() {
		resetFlags()

		DeferCleanup(resetFlags)
	})
	Describe("buildResetPsCmd", func() {
		Context("with containerd directory and docker directory", func() {
			It("returns correct reset-win-storage command", func() {
				resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")
				resetWinStorageCmd.Flags().Set(dockerDirFlag, "dockerDir")

				cmd, params, err := buildResetPsCmd(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "image", "ResetWinContainerStorage.ps1") + "'"))
				Expect(params).To(ConsistOf(" -Containerd 'containerdDir'", " -Docker 'dockerDir'", fmt.Sprintf(" -MaxRetries %v", strconv.Itoa(defaultMaxRetry))))
			})
		})

		Context("with containerd directory only", func() {
			It("returns correct reset-win-storage command", func() {
				resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

				cmd, params, err := buildResetPsCmd(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "image", "ResetWinContainerStorage.ps1") + "'"))
				Expect(params).To(ConsistOf(" -Containerd 'containerdDir'", fmt.Sprintf(" -Docker '%v'", defaultDockerDir), fmt.Sprintf(" -MaxRetries %v", strconv.Itoa(defaultMaxRetry))))
			})
		})

		Context("with docker directory only", func() {
			It("returns correct reset-win-storage command", func() {
				resetWinStorageCmd.Flags().Set(dockerDirFlag, "dockerDir")

				cmd, params, err := buildResetPsCmd(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "image", "ResetWinContainerStorage.ps1") + "'"))
				Expect(params).To(ConsistOf(fmt.Sprintf(" -Containerd '%v'", defaultContainerdDir), " -Docker 'dockerDir'", fmt.Sprintf(" -MaxRetries %v", strconv.Itoa(defaultMaxRetry))))
			})
		})

		Context("with no directory and user provided retries", func() {
			It("returns correct reset-win-storage command with default directories and user provided retries", func() {
				resetWinStorageCmd.Flags().Set(maxRetryFlag, "5")

				cmd, params, err := buildResetPsCmd(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "image", "ResetWinContainerStorage.ps1") + "'"))
				Expect(params).To(ConsistOf(fmt.Sprintf(" -Containerd '%v'", defaultContainerdDir), fmt.Sprintf(" -Docker '%v'", defaultDockerDir), fmt.Sprintf(" -MaxRetries %v", strconv.Itoa(5))))
			})
		})

		Context("with force zap flag", func() {
			It("returns correct reset-win-storage command with force zap flag", func() {
				resetWinStorageCmd.Flags().Set(forceZapFlag, "true")

				cmd, params, err := buildResetPsCmd(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "image", "ResetWinContainerStorage.ps1") + "'"))
				Expect(params).To(ConsistOf(fmt.Sprintf(" -Containerd '%v'", defaultContainerdDir), fmt.Sprintf(" -Docker '%v'", defaultDockerDir), fmt.Sprintf(" -MaxRetries %v", strconv.Itoa(defaultMaxRetry)), " -ForceZap"))
			})
		})

		Context("with no containerd directory provided", func() {
			It("passes an empty -Containerd so PowerShell resolves the configured storage path", func() {
				// containerd flag left empty by resetFlags()

				_, params, err := buildResetPsCmd(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(params).To(ContainElement(" -Containerd ''"))
				// docker default must remain unchanged
				Expect(params).To(ContainElement(fmt.Sprintf(" -Docker '%v'", defaultDockerDir)))
			})
		})

		Context("with explicit containerd directory", func() {
			It("forwards the explicit path and never falls back to a default", func() {
				resetWinStorageCmd.Flags().Set(containerdDirFlag, `E:\Temp\Containerd`)

				_, params, err := buildResetPsCmd(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(params).To(ContainElement(` -Containerd 'E:\Temp\Containerd'`))
				Expect(params).ToNot(ContainElement(" -Containerd ''"))
			})
		})
	})

	Describe("resetWinStorage", func() {
		Context("when k2s is not installed", func() {
			It("command is executed", func() {
				mockSetupConfigProvider := &mockRuntimeConfigProvider{}
				mockPowershellExecutor := &mockPowershellExecutor{}
				var nilConfig *config.K2sRuntimeConfig
				mockSetupConfigProvider.On(reflection.GetFunctionName(mockSetupConfigProvider.ReadConfig), mock.AnythingOfType("string")).Return(nilConfig, config.ErrSystemNotInstalled)
				mockPowershellExecutor.On(reflection.GetFunctionName(mockPowershellExecutor.ExecutePsWithStructuredResult), mock.Anything, mock.Anything, mock.Anything).Return(&common.CmdResult{}, nil)
				getSetupConfigProvider = func() setupConfigProvider { return mockSetupConfigProvider }
				getPowershellExecutor = func() powershellExecutor { return mockPowershellExecutor }
				resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

				resetWinStorage(resetWinStorageCmd, nil)

				mockPowershellExecutor.AssertCalled(GinkgoT(), reflection.GetFunctionName(mockPowershellExecutor.ExecutePsWithStructuredResult), mock.Anything, mock.Anything, mock.Anything)
			})
		})

		Context("when k2s installation is corrupted", func() {
			Context("when default k2s variant", func() {
				It("command is executed", func() {
					mockSetupConfigProvider := &mockRuntimeConfigProvider{}
					mockPowershellExecutor := &mockPowershellExecutor{}
					k2sConfig := config.NewK2sRuntimeConfig(nil, config.NewK2sInstallConfig("", false, "", true, false), nil)
					mockSetupConfigProvider.On(reflection.GetFunctionName(mockSetupConfigProvider.ReadConfig), mock.AnythingOfType("string")).Return(k2sConfig, config.ErrSystemInCorruptedState)
					mockPowershellExecutor.On(reflection.GetFunctionName(mockPowershellExecutor.ExecutePsWithStructuredResult), mock.Anything, mock.Anything, mock.Anything).Return(&common.CmdResult{}, nil)
					getSetupConfigProvider = func() setupConfigProvider { return mockSetupConfigProvider }
					getPowershellExecutor = func() powershellExecutor { return mockPowershellExecutor }
					resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

					resetWinStorage(resetWinStorageCmd, nil)

					mockPowershellExecutor.AssertCalled(GinkgoT(), reflection.GetFunctionName(mockPowershellExecutor.ExecutePsWithStructuredResult), mock.Anything, mock.Anything, mock.Anything)
				})
			})
			Context("when Linux-only variant", func() {
				It("command is executed", func() {
					mockSetupConfigProvider := &mockRuntimeConfigProvider{}
					mockPowershellExecutor := &mockPowershellExecutor{}
					k2sConfig := config.NewK2sRuntimeConfig(nil, config.NewK2sInstallConfig("", true, "", true, false), nil)
					mockSetupConfigProvider.On(reflection.GetFunctionName(mockSetupConfigProvider.ReadConfig), mock.AnythingOfType("string")).Return(k2sConfig, config.ErrSystemInCorruptedState)
					mockPowershellExecutor.On(reflection.GetFunctionName(mockPowershellExecutor.ExecutePsWithStructuredResult), mock.Anything, mock.Anything, mock.Anything).Return(&common.CmdResult{}, nil)
					getSetupConfigProvider = func() setupConfigProvider { return mockSetupConfigProvider }
					getPowershellExecutor = func() powershellExecutor { return mockPowershellExecutor }
					resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

					resetWinStorage(resetWinStorageCmd, nil)

					mockPowershellExecutor.AssertCalled(GinkgoT(), reflection.GetFunctionName(mockPowershellExecutor.ExecutePsWithStructuredResult), mock.Anything, mock.Anything, mock.Anything)
				})
			})
		})

		Context("when k2s is installed", func() {
			Context("error encountered while reading setup details", func() {
				It("returns error", func() {
					mockSetupConfigProvider := &mockRuntimeConfigProvider{}
					mockPowershellExecutor := &mockPowershellExecutor{}
					err := errors.New("error")
					var nilConfig *config.K2sRuntimeConfig
					mockSetupConfigProvider.On(reflection.GetFunctionName(mockSetupConfigProvider.ReadConfig), mock.AnythingOfType("string")).Return(nilConfig, err)
					mockPowershellExecutor.On(reflection.GetFunctionName(mockPowershellExecutor.ExecutePsWithStructuredResult), mock.Anything, mock.Anything, mock.Anything).Return(&common.CmdResult{}, nil)
					getSetupConfigProvider = func() setupConfigProvider { return mockSetupConfigProvider }
					getPowershellExecutor = func() powershellExecutor { return mockPowershellExecutor }
					resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

					errFromCmdExecution := resetWinStorage(resetWinStorageCmd, nil)

					Expect(errFromCmdExecution).To(HaveOccurred())
				})
			})
		})
	})
})

func resetFlags() {
	resetWinStorageCmd.Flags().Set(containerdDirFlag, "")
	resetWinStorageCmd.Flags().Set(dockerDirFlag, "")
	resetWinStorageCmd.Flags().Set(maxRetryFlag, "1")
	resetWinStorageCmd.Flags().Set(forceZapFlag, "false")

	k2sConfig := config.NewK2sConfig(config.NewHostConfig(nil, nil, "some-dir", "", ""), nil)
	cmdContext := common.NewCmdContext(k2sConfig, nil, nil)
	resetWinStorageCmd.SetContext(context.WithValue(context.TODO(), common.ContextKeyCmdContext, cmdContext))
}
