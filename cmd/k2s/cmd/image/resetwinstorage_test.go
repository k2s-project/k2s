// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"context"
	"errors"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/provider"
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

var _ = Describe("reset-win-storage", Ordered, func() {
	var mockImg *mockImageProvider

	BeforeAll(func() {
		resetWinStorageCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})

	BeforeEach(func() {
		mockImg = &mockImageProvider{}
		resetFlags(mockImg)

		DeferCleanup(func() {
			resetFlags(nil)
			getSetupConfigProvider = newSetupConfigProvider
		})
	})

	Describe("buildResetWinStorageConfig", func() {
		Context("with containerd directory and docker directory", func() {
			It("returns correct config", func() {
				resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")
				resetWinStorageCmd.Flags().Set(dockerDirFlag, "dockerDir")

				cfg, err := buildResetWinStorageConfig(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cfg).To(Equal(provider.ImageResetWinStorageConfig{
					Containerd: "containerdDir",
					Docker:     "dockerDir",
					MaxRetry:   defaultMaxRetry,
				}))
			})
		})

		Context("with containerd directory only", func() {
			It("uses default docker directory", func() {
				resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

				cfg, err := buildResetWinStorageConfig(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cfg.Containerd).To(Equal("containerdDir"))
				Expect(cfg.Docker).To(Equal(defaultDockerDir))
				Expect(cfg.MaxRetry).To(Equal(defaultMaxRetry))
			})
		})

		Context("with docker directory only", func() {
			It("keeps empty containerd directory", func() {
				resetWinStorageCmd.Flags().Set(dockerDirFlag, "dockerDir")

				cfg, err := buildResetWinStorageConfig(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cfg.Containerd).To(Equal(defaultContainerdDir))
				Expect(cfg.Docker).To(Equal("dockerDir"))
			})
		})

		Context("with user provided retries and force zap", func() {
			It("populates MaxRetry and ForceZap", func() {
				resetWinStorageCmd.Flags().Set(maxRetryFlag, "5")
				resetWinStorageCmd.Flags().Set(forceZapFlag, "true")

				cfg, err := buildResetWinStorageConfig(resetWinStorageCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cfg.MaxRetry).To(Equal(5))
				Expect(cfg.ForceZap).To(BeTrue())
			})
		})

		Context("with invalid max retries", func() {
			It("returns an error", func() {
				resetWinStorageCmd.Flags().Set(maxRetryFlag, "0")

				_, err := buildResetWinStorageConfig(resetWinStorageCmd)

				Expect(err).To(HaveOccurred())
			})
		})
	})

	Describe("resetWinStorage", func() {
		Context("when k2s is not installed", func() {
			It("routes through ImageProvider.ResetWinStorage", func() {
				mockSetupConfigProvider := &mockRuntimeConfigProvider{}
				var nilConfig *config.K2sRuntimeConfig
				mockSetupConfigProvider.On(reflection.GetFunctionName(mockSetupConfigProvider.ReadConfig), mock.AnythingOfType("string")).Return(nilConfig, config.ErrSystemNotInstalled)
				mockImg.On("ResetWinStorage", mock.Anything, mock.MatchedBy(func(cfg provider.ImageResetWinStorageConfig) bool {
					return cfg.Containerd == "containerdDir"
				})).Return(nil)
				getSetupConfigProvider = func() setupConfigProvider { return mockSetupConfigProvider }
				resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

				err := resetWinStorage(resetWinStorageCmd, nil)

				Expect(err).ToNot(HaveOccurred())
				mockImg.AssertExpectations(GinkgoT())
			})
		})

		Context("when k2s installation is corrupted", func() {
			Context("when default k2s variant", func() {
				It("routes through ImageProvider.ResetWinStorage", func() {
					mockSetupConfigProvider := &mockRuntimeConfigProvider{}
					k2sConfig := config.NewK2sRuntimeConfig(nil, config.NewK2sInstallConfig("", false, "", true, false), nil)
					mockSetupConfigProvider.On(reflection.GetFunctionName(mockSetupConfigProvider.ReadConfig), mock.AnythingOfType("string")).Return(k2sConfig, config.ErrSystemInCorruptedState)
					mockImg.On("ResetWinStorage", mock.Anything, mock.Anything).Return(nil)
					getSetupConfigProvider = func() setupConfigProvider { return mockSetupConfigProvider }
					resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

					err := resetWinStorage(resetWinStorageCmd, nil)

					Expect(err).ToNot(HaveOccurred())
					mockImg.AssertExpectations(GinkgoT())
				})
			})
			Context("when Linux-only variant", func() {
				It("routes through ImageProvider.ResetWinStorage", func() {
					mockSetupConfigProvider := &mockRuntimeConfigProvider{}
					k2sConfig := config.NewK2sRuntimeConfig(nil, config.NewK2sInstallConfig("", true, "", true, false), nil)
					mockSetupConfigProvider.On(reflection.GetFunctionName(mockSetupConfigProvider.ReadConfig), mock.AnythingOfType("string")).Return(k2sConfig, config.ErrSystemInCorruptedState)
					mockImg.On("ResetWinStorage", mock.Anything, mock.Anything).Return(nil)
					getSetupConfigProvider = func() setupConfigProvider { return mockSetupConfigProvider }
					resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

					err := resetWinStorage(resetWinStorageCmd, nil)

					Expect(err).ToNot(HaveOccurred())
					mockImg.AssertExpectations(GinkgoT())
				})
			})
		})

		Context("when k2s is installed", func() {
			Context("when Linux-only setup", func() {
				It("returns unsupported error without calling provider", func() {
					mockSetupConfigProvider := &mockRuntimeConfigProvider{}
					k2sConfig := config.NewK2sRuntimeConfig(nil, config.NewK2sInstallConfig("", true, "", false, false), nil)
					mockSetupConfigProvider.On(reflection.GetFunctionName(mockSetupConfigProvider.ReadConfig), mock.AnythingOfType("string")).Return(k2sConfig, nil)
					getSetupConfigProvider = func() setupConfigProvider { return mockSetupConfigProvider }

					err := resetWinStorage(resetWinStorageCmd, nil)

					Expect(err).To(MatchError("Resetting WinContainerStorage for Linux-only setup is not supported."))
					mockImg.AssertNotCalled(GinkgoT(), "ResetWinStorage", mock.Anything, mock.Anything)
				})
			})

			Context("error encountered while reading setup details", func() {
				It("returns error", func() {
					mockSetupConfigProvider := &mockRuntimeConfigProvider{}
					err := errors.New("error")
					var nilConfig *config.K2sRuntimeConfig
					mockSetupConfigProvider.On(reflection.GetFunctionName(mockSetupConfigProvider.ReadConfig), mock.AnythingOfType("string")).Return(nilConfig, err)
					getSetupConfigProvider = func() setupConfigProvider { return mockSetupConfigProvider }
					resetWinStorageCmd.Flags().Set(containerdDirFlag, "containerdDir")

					errFromCmdExecution := resetWinStorage(resetWinStorageCmd, nil)

					Expect(errFromCmdExecution).To(HaveOccurred())
				})
			})
		})
	})
})

func resetFlags(mockImg *mockImageProvider) {
	resetWinStorageCmd.Flags().Set(containerdDirFlag, "")
	resetWinStorageCmd.Flags().Set(dockerDirFlag, "")
	resetWinStorageCmd.Flags().Set(maxRetryFlag, "1")
	resetWinStorageCmd.Flags().Set(forceZapFlag, "false")
	resetWinStorageCmd.Flags().Set(forceFlag, "false")

	k2sConfig := config.NewK2sConfig(config.NewHostConfig(nil, nil, "some-dir", "", ""), nil)
	var reg *provider.Registry
	if mockImg != nil {
		reg = &provider.Registry{Image: mockImg}
	}
	cmdContext := common.NewCmdContext(k2sConfig, nil, reg)
	resetWinStorageCmd.SetContext(context.WithValue(context.TODO(), common.ContextKeyCmdContext, cmdContext))
}
