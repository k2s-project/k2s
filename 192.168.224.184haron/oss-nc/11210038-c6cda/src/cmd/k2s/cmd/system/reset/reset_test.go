// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package reset

import (
	"context"
	"errors"
	"log/slog"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	contracts "github.com/k2s-project/k2s/internal/contracts/config"
	coreconfig "github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/cobra"
)

func TestReset(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "reset Unit Tests", Label("unit", "ci"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

type testSystemProvider struct {
	provider.SystemProvider

	resetCalled        bool
	resetErr           error
	resetNetworkCalled bool
	resetNetworkCfg    provider.SystemResetNetworkConfig
	resetNetworkErr    error
}

func (p *testSystemProvider) Reset(provider.SystemResetConfig) error {
	p.resetCalled = true
	return p.resetErr
}

func (p *testSystemProvider) ResetNetwork(cfg provider.SystemResetNetworkConfig) error {
	p.resetNetworkCalled = true
	p.resetNetworkCfg = cfg
	return p.resetNetworkErr
}

var _ = Describe("reset", func() {
	Describe("resetSystem", func() {
		newCmd := func(configDir string, systemProvider provider.SystemProvider) *cobra.Command {
			cmd := &cobra.Command{Use: "reset"}
			k2sConfig := contracts.NewK2sConfig(contracts.NewHostConfig(nil, nil, configDir, "", ""), nil)
			registry := &provider.Registry{System: systemProvider}
			cmd.SetContext(context.WithValue(context.TODO(), common.ContextKeyCmdContext, common.NewCmdContext(k2sConfig, nil, registry)))
			return cmd
		}

		When("the runtime config belongs to a Linux-only install", func() {
			It("routes the command to the system provider", func() {
				configDir := GinkgoT().TempDir()
				err := coreconfig.WriteRuntimeConfig(configDir, "k2s", true, "2.0.0", "k2s-cluster", "control-plane", false)
				Expect(err).NotTo(HaveOccurred())

				systemProvider := &testSystemProvider{}
				err = resetSystem(newCmd(configDir, systemProvider), nil)

				Expect(err).NotTo(HaveOccurred())
				Expect(systemProvider.resetCalled).To(BeTrue())
			})
		})

		When("the runtime config belongs to a Windows-capable install", func() {
			It("preserves the existing provider routing", func() {
				configDir := GinkgoT().TempDir()
				err := coreconfig.WriteRuntimeConfig(configDir, "k2s", false, "2.0.0", "k2s-cluster", "control-plane", false)
				Expect(err).NotTo(HaveOccurred())

				systemProvider := &testSystemProvider{}
				err = resetSystem(newCmd(configDir, systemProvider), nil)

				Expect(err).NotTo(HaveOccurred())
				Expect(systemProvider.resetCalled).To(BeTrue())
			})
		})

		When("the provider fails", func() {
			It("returns the provider error", func() {
				configDir := GinkgoT().TempDir()
				err := coreconfig.WriteRuntimeConfig(configDir, "k2s", true, "2.0.0", "k2s-cluster", "control-plane", false)
				Expect(err).NotTo(HaveOccurred())

				expectedErr := errors.New("reset failed")
				systemProvider := &testSystemProvider{resetErr: expectedErr}
				err = resetSystem(newCmd(configDir, systemProvider), nil)

				Expect(err).To(MatchError(expectedErr))
				Expect(systemProvider.resetCalled).To(BeTrue())
			})
		})
	})

	Describe("resetNetwork", func() {
		newCmd := func(configDir string, systemProvider provider.SystemProvider) *cobra.Command {
			cmd := &cobra.Command{Use: "reset network"}
			k2sConfig := contracts.NewK2sConfig(contracts.NewHostConfig(nil, nil, configDir, "", ""), nil)
			registry := &provider.Registry{System: systemProvider}
			cmd.SetContext(context.WithValue(context.TODO(), common.ContextKeyCmdContext, common.NewCmdContext(k2sConfig, nil, registry)))
			cmd.Flags().BoolP(forceFlagName, "f", false, "")
			cmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, "")
			return cmd
		}

		When("no setup is installed", func() {
			It("routes the command to the system provider and forwards flags", func() {
				configDir := GinkgoT().TempDir()
				systemProvider := &testSystemProvider{}
				cmd := newCmd(configDir, systemProvider)
				Expect(cmd.Flags().Set(forceFlagName, "true")).To(Succeed())
				Expect(cmd.Flags().Set(common.OutputFlagName, "true")).To(Succeed())

				err := resetNetwork(cmd, nil)

				Expect(err).NotTo(HaveOccurred())
				Expect(systemProvider.resetNetworkCalled).To(BeTrue())
				Expect(systemProvider.resetNetworkCfg).To(Equal(provider.SystemResetNetworkConfig{
					Force:      true,
					ShowOutput: true,
				}))
			})
		})

		When("the runtime config belongs to a Linux-only install", func() {
			It("preserves the installed-setup guard and does not call the provider", func() {
				configDir := GinkgoT().TempDir()
				err := coreconfig.WriteRuntimeConfig(configDir, "k2s", true, "2.0.0", "k2s-cluster", "control-plane", false)
				Expect(err).NotTo(HaveOccurred())

				systemProvider := &testSystemProvider{}
				err = resetNetwork(newCmd(configDir, systemProvider), nil)

				Expect(err).NotTo(HaveOccurred())
				Expect(systemProvider.resetNetworkCalled).To(BeFalse())
			})
		})

		When("the runtime config belongs to a Windows-capable install", func() {
			It("preserves the existing guard behavior", func() {
				configDir := GinkgoT().TempDir()
				err := coreconfig.WriteRuntimeConfig(configDir, "k2s", false, "2.0.0", "k2s-cluster", "control-plane", false)
				Expect(err).NotTo(HaveOccurred())

				systemProvider := &testSystemProvider{}
				err = resetNetwork(newCmd(configDir, systemProvider), nil)

				Expect(err).NotTo(HaveOccurred())
				Expect(systemProvider.resetNetworkCalled).To(BeFalse())
			})
		})

		When("the runtime config is corrupted", func() {
			It("returns the existing corrupted-state command failure", func() {
				configDir := GinkgoT().TempDir()
				err := coreconfig.WriteRuntimeConfig(configDir, "k2s", true, "2.0.0", "k2s-cluster", "control-plane", false)
				Expect(err).NotTo(HaveOccurred())
				Expect(coreconfig.MarkSetupAsCorrupted(configDir)).To(Succeed())

				systemProvider := &testSystemProvider{}
				err = resetNetwork(newCmd(configDir, systemProvider), nil)

				expectedErr := common.CreateSystemInCorruptedStateCmdFailure()
				Expect(err).To(MatchError(expectedErr.Error()))
				Expect(systemProvider.resetNetworkCalled).To(BeFalse())
			})
		})
	})
})
