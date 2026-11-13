// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package backup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
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

func TestBackup(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "backup Unit Tests", Label("unit", "ci"))
}

var _ = BeforeSuite(func() {
	SystemBackupCmd.Flags().BoolP(
		common.OutputFlagName,
		common.OutputFlagShorthand,
		false,
		common.OutputFlagUsage,
	)
})

func resetBackupFlags() {
	flags := SystemBackupCmd.Flags()
	flags.Set(common.OutputFlagName, "false")
	flags.Set(backupFileFlag, "")
	flags.Set(common.AdditionalHooksDirFlagName, "")
	flags.Set(skipImagesFlag, "false")
	flags.Set(skipPVsFlag, "false")
}

var _ = Describe("backup", func() {
	BeforeEach(func() {
		resetBackupFlags()
	})

	Describe("resolveBackupFileName", func() {
		When("backup file flag is set", func() {
			It("returns the specified backup file path", func() {
				testFile := filepath.Join("test", "dir", "backup.zip")
				SystemBackupCmd.Flags().Set(backupFileFlag, testFile)

				actual := resolveBackupFileName(SystemBackupCmd)

				Expect(actual).To(Equal(testFile))
			})
		})

		When("backup file flag is omitted", func() {
			It("returns a timestamped default backup file in temp directory", func() {
				expectedDir := filepath.Join(os.TempDir(), "k2s", "backups")

				actual := resolveBackupFileName(SystemBackupCmd)

				Expect(filepath.Dir(actual)).To(Equal(expectedDir))
				Expect(filepath.Base(actual)).To(HavePrefix("k2s-backup-file-"))
				Expect(filepath.Base(actual)).To(HaveSuffix(".zip"))
			})
		})
	})

	Describe("runSystemBackup", func() {
		var mockSys *mockSystemProvider

		BeforeEach(func() {
			mockSys = &mockSystemProvider{}
			cmdContext := common.NewCmdContext(nil, nil, &provider.Registry{System: mockSys})
			ctx := context.WithValue(context.TODO(), common.ContextKeyCmdContext, cmdContext)
			SystemBackupCmd.SetContext(ctx)
		})

		When("default flags are used", func() {
			It("calls provider Backup with default config", func() {
				mockSys.On("Backup", mock.MatchedBy(func(cfg provider.SystemBackupConfig) bool {
					expectedDir := filepath.Join(os.TempDir(), "k2s", "backups")
					return filepath.Dir(cfg.BackupFile) == expectedDir &&
						strings.HasPrefix(filepath.Base(cfg.BackupFile), "k2s-backup-file-") &&
						strings.HasSuffix(cfg.BackupFile, ".zip") &&
						cfg.AdditionalHooksDir == "" &&
						!cfg.SkipImages &&
						!cfg.SkipPVs &&
						!cfg.ShowOutput
				})).Return(nil).Once()

				err := runSystemBackup(SystemBackupCmd, nil)

				Expect(err).ToNot(HaveOccurred())
				mockSys.AssertExpectations(GinkgoT())
			})
		})

		When("custom flags are provided", func() {
			It("passes all flag values to provider Backup", func() {
				customFile := filepath.Join("custom", "path", "my-backup.zip")
				SystemBackupCmd.Flags().Set(backupFileFlag, customFile)
				SystemBackupCmd.Flags().Set(common.AdditionalHooksDirFlagName, "/custom/hooks")
				SystemBackupCmd.Flags().Set(skipImagesFlag, "true")
				SystemBackupCmd.Flags().Set(skipPVsFlag, "true")
				SystemBackupCmd.Flags().Set(common.OutputFlagName, "true")

				expectedConfig := provider.SystemBackupConfig{
					BackupFile:         customFile,
					AdditionalHooksDir: "/custom/hooks",
					SkipImages:         true,
					SkipPVs:            true,
					ShowOutput:         true,
				}

				mockSys.On("Backup", expectedConfig).Return(nil).Once()

				err := runSystemBackup(SystemBackupCmd, nil)

				Expect(err).ToNot(HaveOccurred())
				mockSys.AssertExpectations(GinkgoT())
			})
		})

		When("provider Backup returns an error", func() {
			It("returns the error", func() {
				expectedErr := errors.New("backup failed")
				mockSys.On("Backup", mock.Anything).Return(expectedErr).Once()

				err := runSystemBackup(SystemBackupCmd, nil)

				Expect(err).To(MatchError(expectedErr))
				mockSys.AssertExpectations(GinkgoT())
			})
		})
	})
})
