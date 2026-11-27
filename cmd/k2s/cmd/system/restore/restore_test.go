// SPDX-FileCopyrightText: © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package restore

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/healthcheck"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/stretchr/testify/mock"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type mockSystemProvider struct {
	mock.Mock
}

func (m *mockSystemProvider) Dump(config provider.SystemDumpConfig) error {
	args := m.Called(config)
	return args.Error(0)
}

func (m *mockSystemProvider) Upgrade(config provider.SystemUpgradeConfig) error {
	args := m.Called(config)
	return args.Error(0)
}

func (m *mockSystemProvider) Package(config provider.SystemPackageConfig) error {
	args := m.Called(config)
	return args.Error(0)
}

func (m *mockSystemProvider) Reset(config provider.SystemResetConfig) error {
	args := m.Called(config)
	return args.Error(0)
}

func (m *mockSystemProvider) ResetNetwork(config provider.SystemResetNetworkConfig) error {
	args := m.Called(config)
	return args.Error(0)
}

func (m *mockSystemProvider) Compact(config provider.SystemCompactConfig) error {
	args := m.Called(config)
	return args.Error(0)
}

func (m *mockSystemProvider) Backup(config provider.SystemBackupConfig) error {
	args := m.Called(config)
	return args.Error(0)
}

func (m *mockSystemProvider) Restore(config provider.SystemRestoreConfig) error {
	args := m.Called(config)
	return args.Error(0)
}

func (m *mockSystemProvider) CertificateRenew(config provider.SystemCertRenewConfig) error {
	args := m.Called(config)
	return args.Error(0)
}

func (m *mockSystemProvider) CertificateAutoRotation(config provider.SystemCertAutoRotationConfig) error {
	args := m.Called(config)
	return args.Error(0)
}

func (m *mockSystemProvider) Check(config provider.SystemCheckConfig) (healthcheck.Report, error) {
	args := m.Called(config)
	return args.Get(0).(healthcheck.Report), args.Error(1)
}

func TestRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "restore Unit Tests", Label("unit", "ci"))
}

var _ = BeforeSuite(func() {
	SystemRestoreCmd.Flags().BoolP(
		common.OutputFlagName,
		common.OutputFlagShorthand,
		false,
		common.OutputFlagUsage,
	)
})

// Helper to reset flags between tests
func resetRestoreFlags() {
	flags := SystemRestoreCmd.Flags()
	flags.Set(common.OutputFlagName, "false")
	flags.Set(restoreFileFlag, "")
	flags.Set(errorOnFailureFlag, "false")
	flags.Set(common.AdditionalHooksDirFlagName, "")
}

var _ = Describe("restore", func() {
	var mockSys *mockSystemProvider

	BeforeEach(func() {
		resetRestoreFlags()
		mockSys = &mockSystemProvider{}
		cmdContext := common.NewCmdContext(nil, nil, &provider.Registry{System: mockSys})
		ctx := context.WithValue(context.TODO(), common.ContextKeyCmdContext, cmdContext)
		SystemRestoreCmd.SetContext(ctx)
	})

	Describe("runSystemRestore", func() {
		When("mandatory flags are provided", func() {
			It("delegates to provider Restore with expected config", func() {
				testFile := filepath.Join("test", "dir", "backup.zip")
				SystemRestoreCmd.Flags().Set(restoreFileFlag, testFile)

				expectedConfig := provider.SystemRestoreConfig{
					BackupFile:         testFile,
					AdditionalHooksDir: "",
					ErrorOnFailure:     false,
					ShowOutput:         false,
				}

				mockSys.On("Restore", expectedConfig).Return(nil).Once()

				err := runSystemRestore(SystemRestoreCmd, nil)

				Expect(err).ToNot(HaveOccurred())
				mockSys.AssertExpectations(GinkgoT())
			})
		})

		When("all flags are provided", func() {
			It("passes all flags to provider Restore", func() {
				testFile := filepath.Join("test", "dir", "backup.zip")
				SystemRestoreCmd.Flags().Set(restoreFileFlag, testFile)
				SystemRestoreCmd.Flags().Set(common.OutputFlagName, "true")
				SystemRestoreCmd.Flags().Set(errorOnFailureFlag, "true")
				SystemRestoreCmd.Flags().Set(common.AdditionalHooksDirFlagName, "/custom/hooks")

				expectedConfig := provider.SystemRestoreConfig{
					BackupFile:         testFile,
					AdditionalHooksDir: "/custom/hooks",
					ErrorOnFailure:     true,
					ShowOutput:         true,
				}

				mockSys.On("Restore", expectedConfig).Return(nil).Once()

				err := runSystemRestore(SystemRestoreCmd, nil)

				Expect(err).ToNot(HaveOccurred())
				mockSys.AssertExpectations(GinkgoT())
			})
		})

		When("provider Restore returns an error", func() {
			It("returns the error", func() {
				testFile := filepath.Join("test", "dir", "backup.zip")
				SystemRestoreCmd.Flags().Set(restoreFileFlag, testFile)

				expectedErr := errors.New("restore failed")
				mockSys.On("Restore", mock.Anything).Return(expectedErr).Once()

				err := runSystemRestore(SystemRestoreCmd, nil)

				Expect(err).To(HaveOccurred())
				Expect(err).To(MatchError(expectedErr))
				mockSys.AssertExpectations(GinkgoT())
			})
		})
	})
})
