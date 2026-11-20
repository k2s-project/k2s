// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package backuprestore

import (
	"archive/zip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/e2e/addons/exportimport"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 30

const (
	cephSmbStorageClass = "ceph-smb"
	cephSmbNamespace    = "storage-smb-ceph"
)

type cephBackupManifest struct {
	EnableParams struct {
		SetupWindowsNode bool `json:"setupWindowsNode"`
	} `json:"enableParams"`
}

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
	backupDir  string
)

func TestStorageCephBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "storage ceph Addon Backup/Restore Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "storage-ceph", "ceph", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-storage-ceph")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "storage", "ceph", "--force", "-o")
	os.RemoveAll(backupDir)
	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

func backupZipPath(suffix string) string {
	return filepath.Join(backupDir, fmt.Sprintf("storage_ceph_backup_%s.zip", suffix))
}

func skipIfLinuxOnly() {
	if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		Skip("Linux-only setup: no Windows worker node to validate Ceph SMB (-w) behavior")
	}
}

func readCephBackupManifest(zipPath string) cephBackupManifest {
	reader, err := zip.OpenReader(zipPath)
	Expect(err).ToNot(HaveOccurred(), "expected backup zip to be readable")
	defer reader.Close()

	for _, file := range reader.File {
		if strings.EqualFold(file.Name, "backup.json") {
			handle, openErr := file.Open()
			Expect(openErr).ToNot(HaveOccurred(), "expected backup.json to be readable")
			defer handle.Close()

			content, readErr := io.ReadAll(handle)
			Expect(readErr).ToNot(HaveOccurred(), "expected backup.json content to be readable")

			var manifest cephBackupManifest
			Expect(json.Unmarshal(content, &manifest)).To(Succeed(), "expected valid backup.json content")
			return manifest
		}
	}

	Fail("backup.json not found in backup archive")
	return cephBackupManifest{}
}

func expectCephSmbResourcesPresent(ctx context.Context) {
	Eventually(func() string {
		out, exitCode := suite.Kubectl().Exec(ctx, "get", "storageclass", cephSmbStorageClass, "-o", "name", "--ignore-not-found")
		if exitCode != 0 {
			return ""
		}
		return strings.TrimSpace(out)
	}).WithTimeout(2 * time.Minute).WithPolling(5 * time.Second).Should(ContainSubstring(cephSmbStorageClass))

	Eventually(func() string {
		out, exitCode := suite.Kubectl().Exec(ctx, "get", "namespace", cephSmbNamespace, "-o", "name", "--ignore-not-found")
		if exitCode != 0 {
			return ""
		}
		return strings.TrimSpace(out)
	}).WithTimeout(2 * time.Minute).WithPolling(5 * time.Second).Should(Equal("namespace/" + cephSmbNamespace))
}

var _ = Describe("'storage ceph' addon backup/restore", Ordered, func() {
	var (
		zipPathWithWindows string
	)

	BeforeAll(func() {
		zipPathWithWindows = backupZipPath("with-w")
		_ = os.RemoveAll(backupDir)
		_ = os.MkdirAll(backupDir, os.ModePerm)
	})

	AfterAll(func(ctx context.Context) {
		suite.K2sCli().Exec(ctx, "addons", "disable", "storage", "ceph", "--force", "-o")
		k2s.VerifyAddonIsDisabled("storage", "ceph")
	})

	It("fails backup when addon is disabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "storage", "ceph")
		Expect(output).To(ContainSubstring("not enabled"))
	})

	It("fails restore with non-existent backup file", func(ctx context.Context) {
		fakePath := filepath.Join(backupDir, "does-not-exist.zip")
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "storage", "ceph", "-f", fakePath)
		Expect(output).To(ContainSubstring("not found"))
	})

	It("enables the addon with -w", func(ctx context.Context) {
		skipIfLinuxOnly()
		suite.K2sCli().MustExec(ctx, "addons", "enable", "storage", "ceph", "-o", "-w")
		k2s.VerifyAddonIsEnabled("storage", "ceph")
		expectCephSmbResourcesPresent(ctx)
	})

	It("creates a backup for -w mode", func(ctx context.Context) {
		skipIfLinuxOnly()
		suite.K2sCli().MustExec(ctx, "addons", "backup", "storage", "ceph", "-f", zipPathWithWindows, "-o")
		Expect(zipPathWithWindows).To(BeAnExistingFile())

		manifest := readCephBackupManifest(zipPathWithWindows)
		Expect(manifest.EnableParams.SetupWindowsNode).To(BeTrue(), "backup manifest should record -w mode")
	})

	It("disables the addon before restoring -w backup", func(ctx context.Context) {
		skipIfLinuxOnly()
		suite.K2sCli().MustExec(ctx, "addons", "disable", "storage", "ceph", "--force", "-o")
		k2s.VerifyAddonIsDisabled("storage", "ceph")
	})

	It("restores from -w backup and re-enables Ceph SMB", func(ctx context.Context) {
		skipIfLinuxOnly()
		suite.K2sCli().MustExec(ctx, "addons", "restore", "storage", "ceph", "-f", zipPathWithWindows, "-o")
		k2s.VerifyAddonIsEnabled("storage", "ceph")
		expectCephSmbResourcesPresent(ctx)
	})

	It("can be enabled when only addons/common and addons/storage are present", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "storage", "ceph", "--force", "-o")

		restore, err := exportimport.StageAddonIsolation(suite.RootDir(), "storage")
		Expect(err).ToNot(HaveOccurred(), "staging addon isolation should succeed")
		DeferCleanup(func() {
			Expect(restore()).To(Succeed(), "addon isolation restore must succeed")
		})
		DeferCleanup(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "storage", "ceph", "--force", "-o")
		})

		output := suite.K2sCli().MustExec(ctx, "addons", "enable", "storage", "ceph", "-o")
		k2s.VerifyAddonIsEnabled("storage", "ceph")
		Expect(output).ToNot(ContainSubstring("no valid module file was found"))
		Expect(output).ToNot(ContainSubstring("was not loaded"))
	})
})
