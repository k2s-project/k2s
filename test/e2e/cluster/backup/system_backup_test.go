// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package systembackup

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

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/test/framework"
)

type backupManifest struct {
	APIVersion string `json:"apiVersion"`
	Kind       string `json:"kind"`
	Metadata   struct {
		BackupTimestamp     string `json:"backupTimestamp"`
		BackupTool          string `json:"backupTool"`
		BackupToolVersion   string `json:"backupToolVersion"`
		BackupFormatVersion string `json:"backupFormatVersion"`
	} `json:"metadata"`
	Cluster struct {
		Name       string `json:"name"`
		K2sVersion string `json:"k2sVersion"`
	} `json:"cluster"`
	Content struct {
		Included struct {
			ClusterResources bool     `json:"clusterResources"`
			Namespaces       []string `json:"namespaces"`
		} `json:"included"`
		Excluded struct {
			Namespaces          []string `json:"namespaces"`
			NamespacedResources []string `json:"namespacedResources"`
			ClusterResources    []string `json:"clusterResources"`
		} `json:"excluded"`
	} `json:"content"`
	ConfigSnapshot struct {
		Source string `json:"source"`
	} `json:"configSnapshot"`
}

var (
	suite         *framework.K2sTestSuite
	testBackupDir string
)

func TestSystemBackup(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Cluster System Backup Acceptance Tests", Label("core", "acceptance", "internet-required", "setup-required", "system-running", "system-backup"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(200*time.Millisecond),
		framework.ClusterTestStepTimeout(15*time.Minute),
	)

	var err error
	testBackupDir, err = os.MkdirTemp("", "k2s-system-backup-test-*")
	Expect(err).NotTo(HaveOccurred(), "failed to create temporary backup directory")
})

var _ = AfterSuite(func(ctx context.Context) {
	if testBackupDir != "" {
		_ = os.RemoveAll(testBackupDir)
	}
	suite.TearDown(ctx)
})

var _ = Describe("system backup", func() {
	const entryMissingPattern = "%s not found in backup zip archive"

	hasZipEntry := func(files []*zip.File, target string) bool {
		normalizedTarget := strings.ReplaceAll(target, "\\", "/")
		for _, f := range files {
			normalizedName := strings.ReplaceAll(f.Name, "\\", "/")
			if normalizedName == normalizedTarget || strings.HasSuffix(normalizedName, normalizedTarget) {
				return true
			}
		}
		return false
	}

	readManifest := func(r *zip.ReadCloser) *backupManifest {
		for _, f := range r.File {
			normalizedName := strings.ReplaceAll(f.Name, "\\", "/")
			if normalizedName == "backup.json" {
				rc, err := f.Open()
				Expect(err).NotTo(HaveOccurred(), "failed to open backup.json from zip")
				defer rc.Close()

				data, err := io.ReadAll(rc)
				Expect(err).NotTo(HaveOccurred(), "failed to read backup.json content")

				var manifest backupManifest
				err = json.Unmarshal(data, &manifest)
				Expect(err).NotTo(HaveOccurred(), "failed to unmarshal backup.json")
				return &manifest
			}
		}
		Fail("backup.json not found in zip archive")
		return nil
	}

	It("creates a system backup with specified file path and validates archive structure and manifest", func(ctx context.Context) {
		backupFilePath := filepath.Join(testBackupDir, fmt.Sprintf("system-backup-%d.zip", time.Now().UnixNano()))
		DeferCleanup(func() {
			_ = os.Remove(backupFilePath)
		})

		output := suite.K2sCli().MustExec(ctx, "system", "backup", "-f", backupFilePath, "--output")
		Expect(output).NotTo(BeEmpty(), "system backup output should not be empty")

		fileInfo, err := os.Stat(backupFilePath)
		Expect(err).NotTo(HaveOccurred(), "backup zip file should exist on disk")
		Expect(fileInfo.Size()).To(BeNumerically(">", 0), "backup zip file size should be greater than 0")

		r, err := zip.OpenReader(backupFilePath)
		Expect(err).NotTo(HaveOccurred(), "failed to open backup zip file as a valid zip archive")
		defer r.Close()

		Expect(hasZipEntry(r.File, "backup.json")).To(BeTrue(), entryMissingPattern, "backup.json")
		Expect(hasZipEntry(r.File, "config/config.json")).To(BeTrue(), entryMissingPattern, "config/config.json")

		manifest := readManifest(r)
		Expect(manifest).NotTo(BeNil())
		Expect(manifest.APIVersion).To(Equal("k2s.backup/v1"), "manifest apiVersion mismatch")
		Expect(manifest.Kind).To(Equal("SystemBackup"), "manifest kind mismatch")
		Expect(manifest.Metadata.BackupTimestamp).NotTo(BeEmpty(), "metadata.backupTimestamp should not be empty")
		Expect(manifest.Metadata.BackupTool).To(ContainSubstring("backup"), "metadata.backupTool should contain 'backup'")
		Expect(manifest.Metadata.BackupToolVersion).NotTo(BeEmpty(), "metadata.backupToolVersion should not be empty")
		Expect(manifest.Metadata.BackupFormatVersion).NotTo(BeEmpty(), "metadata.backupFormatVersion should not be empty")
		Expect(manifest.Cluster.Name).NotTo(BeEmpty(), "cluster.name should not be empty")
		Expect(manifest.ConfigSnapshot.Source).To(Equal("config/config.json"), "configSnapshot.source mismatch")
	})

	It("creates a system backup with --skip-images and --skip-pvs flags", func(ctx context.Context) {
		backupFilePath := filepath.Join(testBackupDir, fmt.Sprintf("system-backup-skip-%d.zip", time.Now().UnixNano()))
		DeferCleanup(func() {
			_ = os.Remove(backupFilePath)
		})

		output := suite.K2sCli().MustExec(ctx, "system", "backup", "-f", backupFilePath, "--skip-images", "--skip-pvs", "--output")
		Expect(output).NotTo(BeEmpty(), "system backup output should not be empty")

		fileInfo, err := os.Stat(backupFilePath)
		Expect(err).NotTo(HaveOccurred(), "backup zip file should exist on disk")
		Expect(fileInfo.Size()).To(BeNumerically(">", 0), "backup zip file size should be greater than 0")

		r, err := zip.OpenReader(backupFilePath)
		Expect(err).NotTo(HaveOccurred(), "failed to open backup zip file as a valid zip archive")
		defer r.Close()

		Expect(hasZipEntry(r.File, "backup.json")).To(BeTrue(), entryMissingPattern, "backup.json")
		Expect(hasZipEntry(r.File, "config/config.json")).To(BeTrue(), entryMissingPattern, "config/config.json")

		manifest := readManifest(r)
		Expect(manifest).NotTo(BeNil())
		Expect(manifest.APIVersion).To(Equal("k2s.backup/v1"), "manifest apiVersion mismatch")
		Expect(manifest.Kind).To(Equal("SystemBackup"), "manifest kind mismatch")
		Expect(manifest.Metadata.BackupTimestamp).NotTo(BeEmpty(), "metadata.backupTimestamp should not be empty")
		Expect(manifest.Metadata.BackupTool).To(ContainSubstring("backup"), "metadata.backupTool should contain 'backup'")
		Expect(manifest.Metadata.BackupToolVersion).NotTo(BeEmpty(), "metadata.backupToolVersion should not be empty")
		Expect(manifest.Metadata.BackupFormatVersion).NotTo(BeEmpty(), "metadata.backupFormatVersion should not be empty")
	})
})
