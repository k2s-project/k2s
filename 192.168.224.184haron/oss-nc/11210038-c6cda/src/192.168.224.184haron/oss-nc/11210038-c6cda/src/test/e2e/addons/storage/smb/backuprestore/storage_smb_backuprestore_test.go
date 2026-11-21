// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package backuprestore

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/e2e/addons/exportimport"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 20

type smbConfigEntry struct {
	WinMountPath     string `json:"winMountPath"`
	LinuxMountPath   string `json:"linuxMountPath"`
	WinShareName     string `json:"winShareName"`
	LinuxShareName   string `json:"linuxShareName"`
	StorageClassName string `json:"storageClassName"`
}

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
	backupDir  string
)

func TestStorageSmbBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "storage smb Addon Backup/Restore Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "storage", "smb", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-storage-smb")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "storage", "smb", "--force", "-o")

	cleanupBackupDir()

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

func cleanupBackupDir() {
	os.RemoveAll(backupDir)
}

func backupZipPath(suffix string) string {
	return filepath.Join(backupDir, fmt.Sprintf("storage_smb_backup_%s.zip", suffix))
}

// readSmbConfig reads the SmbStorage.json config to find the WinMountPath(s).
func readSmbConfig() ([]smbConfigEntry, error) {
	// The config file lives relative to the addons directory.
	configPath := filepath.Join(suite.RootDir(), "addons", "storage", "smb", "config", "SmbStorage.json")

	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read SmbStorage.json: %w", err)
	}

	var entries []smbConfigEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		return nil, fmt.Errorf("failed to parse SmbStorage.json: %w", err)
	}

	return entries, nil
}

var _ = Describe("'storage smb' addon backup/restore", Ordered, func() {

	const (
		testFileName    = "k2s-backup-restore-test.txt"
		testFileContent = "backup-restore-sentinel"
	)

	var (
		zipPath      string
		winMountPath string
	)

	BeforeAll(func() {
		zipPath = backupZipPath("basic")
		cleanupBackupDir()
		os.MkdirAll(backupDir, os.ModePerm)
	})

	AfterAll(func(ctx context.Context) {
		suite.K2sCli().Exec(ctx, "addons", "disable", "storage", "smb", "--force", "-o")
		k2s.VerifyAddonIsDisabled("storage", "smb")
	})

	// --- error tests while addon is disabled ---

	It("fails restore with a non-existent backup file", func(ctx context.Context) {
		fakePath := filepath.Join(backupDir, "does-not-exist.zip")

		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "storage", "smb", "-f", fakePath)

		Expect(output).To(ContainSubstring("not found"))
	})

	// --- single enable → write test file → backup → disable → restore cycle ---

	It("enables the addon", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "enable", "storage", "smb", "-o")

		k2s.VerifyAddonIsEnabled("storage", "smb")
	})

	It("reads the SMB config and writes a test file to the Windows mount path", func(ctx context.Context) {
		entries, err := readSmbConfig()
		Expect(err).NotTo(HaveOccurred())
		Expect(entries).NotTo(BeEmpty())

		winMountPath = entries[0].WinMountPath
		Expect(winMountPath).NotTo(BeEmpty())

		testFilePath := filepath.Join(winMountPath, testFileName)
		err = os.WriteFile(testFilePath, []byte(testFileContent), 0644)
		Expect(err).NotTo(HaveOccurred())

		Expect(testFilePath).To(BeAnExistingFile())
	})

	It("creates a backup", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "backup", "storage", "smb", "-f", zipPath, "-o")

		Expect(zipPath).To(BeAnExistingFile())
	})

	It("fails restore while addon is still enabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "storage", "smb", "-f", zipPath)

		Expect(output).To(ContainSubstring("disable"))
	})

	It("disables the addon", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "storage", "smb", "--force", "-o")

		k2s.VerifyAddonIsDisabled("storage", "smb")
	})

	It("restores from backup and the test file is present", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "restore", "storage", "smb", "-f", zipPath, "-o")

		k2s.VerifyAddonIsEnabled("storage", "smb")

		Expect(winMountPath).NotTo(BeEmpty(), "winMountPath should have been set in an earlier spec")

		testFilePath := filepath.Join(winMountPath, testFileName)
		Expect(testFilePath).To(BeAnExistingFile())

		content, err := os.ReadFile(testFilePath)
		Expect(err).NotTo(HaveOccurred())
		Expect(string(content)).To(Equal(testFileContent))
	})

	It("can be enabled when only addons/common and addons/storage are present", func(ctx context.Context) {
		GinkgoWriter.Println(">>> TEST: can be enabled when only addons/common and addons/storage are present")

		GinkgoWriter.Println("[Test] Disabling storage smb to ensure clean re-enable path")
		suite.K2sCli().MustExec(ctx, "addons", "disable", "storage", "smb", "--force", "-o")

		GinkgoWriter.Println("[Test] Staging addon isolation: keeping only common and storage")
		restore, err := exportimport.StageAddonIsolation(suite.RootDir(), "storage")
		Expect(err).ToNot(HaveOccurred(), "staging addon isolation should succeed")
		DeferCleanup(func() {
			Expect(restore()).To(Succeed(), "addon isolation restore must succeed to avoid a partial workspace state")
		})
		DeferCleanup(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "storage", "smb", "--force", "-o")
		})

		GinkgoWriter.Println("[Test] Enabling storage smb with isolated addons directory")
		output := suite.K2sCli().MustExec(ctx, "addons", "enable", "storage", "smb", "-o")

		GinkgoWriter.Println("[Test] Verifying storage smb addon is enabled")
		k2s.VerifyAddonIsEnabled("storage", "smb")

		GinkgoWriter.Println("[Test] Verifying no PowerShell module-not-found signatures in output")
		Expect(output).NotTo(ContainSubstring("no valid module file was found"), "enable output must not contain PowerShell module-not-found error")
		Expect(output).NotTo(ContainSubstring("was not loaded"), "enable output must not contain PowerShell module-not-loaded error")
	})
})
