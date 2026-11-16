// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

//go:build linux

package provider

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestLinuxSystemRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Linux System Restore Unit Tests", Label("unit", "ci", "linux"))
}

var _ = Describe("Linux System Restore", func() {
	var tempDir string

	BeforeEach(func() {
		tempDir = GinkgoT().TempDir()
	})

	Describe("isDangerousVolumePath", func() {
		It("rejects root and empty paths", func() {
			Expect(isDangerousVolumePath("/")).To(BeTrue())
			Expect(isDangerousVolumePath("")).To(BeTrue())
			Expect(isDangerousVolumePath(".")).To(BeTrue())
		})

		It("rejects system root directory paths", func() {
			Expect(isDangerousVolumePath("/bin")).To(BeTrue())
			Expect(isDangerousVolumePath("/bin/subdir")).To(BeTrue())
			Expect(isDangerousVolumePath("/sbin")).To(BeTrue())
			Expect(isDangerousVolumePath("/usr")).To(BeTrue())
			Expect(isDangerousVolumePath("/usr/local/bin")).To(BeTrue())
			Expect(isDangerousVolumePath("/etc")).To(BeTrue())
			Expect(isDangerousVolumePath("/etc/kubernetes")).To(BeTrue())
			Expect(isDangerousVolumePath("/lib")).To(BeTrue())
			Expect(isDangerousVolumePath("/lib64")).To(BeTrue())
			Expect(isDangerousVolumePath("/boot")).To(BeTrue())
			Expect(isDangerousVolumePath("/dev")).To(BeTrue())
			Expect(isDangerousVolumePath("/proc")).To(BeTrue())
			Expect(isDangerousVolumePath("/sys")).To(BeTrue())
			Expect(isDangerousVolumePath("/root")).To(BeTrue())
			Expect(isDangerousVolumePath("/var/run")).To(BeTrue())
			Expect(isDangerousVolumePath("/var/run/docker.sock")).To(BeTrue())
			Expect(isDangerousVolumePath("/var/lib/kubelet")).To(BeTrue())
			Expect(isDangerousVolumePath("/var/lib/kubelet/pods")).To(BeTrue())
		})

		It("accepts safe data directories", func() {
			Expect(isDangerousVolumePath("/var/lib/k2s/pv-data")).To(BeFalse())
			Expect(isDangerousVolumePath("/mnt/data/storage")).To(BeFalse())
			Expect(isDangerousVolumePath("/opt/k2s/volumes/pv1")).To(BeFalse())
			Expect(isDangerousVolumePath("/srv/nfs/share")).To(BeFalse())
		})
	})

	Describe("isK2sInstalled", func() {
		It("returns true when setup.json exists in installDir", func() {
			setupPath := filepath.Join(tempDir, "setup.json")
			Expect(os.WriteFile(setupPath, []byte("{}"), 0644)).To(Succeed())

			Expect(isK2sInstalled(tempDir)).To(BeTrue())
		})

		It("returns true when cfg/config.json exists in installDir", func() {
			cfgDir := filepath.Join(tempDir, "cfg")
			Expect(os.MkdirAll(cfgDir, 0755)).To(Succeed())
			configPath := filepath.Join(cfgDir, "config.json")
			Expect(os.WriteFile(configPath, []byte("{}"), 0644)).To(Succeed())

			Expect(isK2sInstalled(tempDir)).To(BeTrue())
		})

		It("returns false when no K2s config files exist", func() {
			emptyDir := filepath.Join(tempDir, "empty")
			Expect(os.MkdirAll(emptyDir, 0755)).To(Succeed())

			// If /etc/kubernetes/admin.conf doesn't exist on host, this is false
			if _, err := os.Stat("/etc/kubernetes/admin.conf"); err != nil {
				Expect(isK2sInstalled(emptyDir)).To(BeFalse())
			}
		})
	})

	Describe("validateBackupManifest", func() {
		It("validates a proper backup.json manifest", func() {
			manifest := backupManifest{
				APIVersion: "k2s.backup/v1",
				Kind:       "SystemBackup",
				Cluster: backupManifestCluster{
					Name:       "test-cluster",
					K2sVersion: "v1.0.0",
				},
			}
			data, err := json.Marshal(manifest)
			Expect(err).ToNot(HaveOccurred())

			manifestPath := filepath.Join(tempDir, "backup.json")
			Expect(os.WriteFile(manifestPath, data, 0644)).To(Succeed())

			res, err := validateBackupManifest(tempDir)
			Expect(err).ToNot(HaveOccurred())
			Expect(res).ToNot(BeNil())
			Expect(res.APIVersion).To(Equal("k2s.backup/v1"))
			Expect(res.Kind).To(Equal("SystemBackup"))
			Expect(res.Cluster.Name).To(Equal("test-cluster"))
		})

		It("fails when backup.json does not exist", func() {
			_, err := validateBackupManifest(tempDir)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("backup manifest (backup.json) not found"))
		})

		It("fails when apiVersion is unsupported", func() {
			manifest := backupManifest{
				APIVersion: "k2s.backup/v2",
				Kind:       "SystemBackup",
			}
			data, err := json.Marshal(manifest)
			Expect(err).ToNot(HaveOccurred())

			manifestPath := filepath.Join(tempDir, "backup.json")
			Expect(os.WriteFile(manifestPath, data, 0644)).To(Succeed())

			_, err = validateBackupManifest(tempDir)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("unsupported backup apiVersion"))
		})

		It("fails when kind is invalid", func() {
			manifest := backupManifest{
				APIVersion: "k2s.backup/v1",
				Kind:       "InvalidKind",
			}
			data, err := json.Marshal(manifest)
			Expect(err).ToNot(HaveOccurred())

			manifestPath := filepath.Join(tempDir, "backup.json")
			Expect(os.WriteFile(manifestPath, data, 0644)).To(Succeed())

			_, err = validateBackupManifest(tempDir)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("invalid backup kind"))
		})
	})

	Describe("restorePersistentVolumes", func() {
		It("skips gracefully when pv directory does not exist", func() {
			errs := restorePersistentVolumes(tempDir)
			Expect(errs).To(BeEmpty())
		})

		It("rejects persistent volume with dangerous path", func() {
			pvDir := filepath.Join(tempDir, "pv")
			Expect(os.MkdirAll(pvDir, 0755)).To(Succeed())

			meta := pvRestoreMetadata{
				Version:    "1.0",
				PVName:     "danger-pv",
				VolumePath: "/etc/danger",
				BackupFile: "danger-pv-backup.tar.gz",
			}
			metaData, err := json.Marshal(meta)
			Expect(err).ToNot(HaveOccurred())
			Expect(os.WriteFile(filepath.Join(pvDir, "danger-pv-metadata.json"), metaData, 0644)).To(Succeed())

			errs := restorePersistentVolumes(tempDir)
			Expect(errs).To(HaveLen(1))
			Expect(errs[0]).To(ContainSubstring("dangerous volume path target"))
		})

		It("fails when backup tar.gz file is missing", func() {
			pvDir := filepath.Join(tempDir, "pv")
			Expect(os.MkdirAll(pvDir, 0755)).To(Succeed())

			targetVolumePath := filepath.Join(tempDir, "safe-pv-data")
			meta := pvRestoreMetadata{
				Version:    "1.0",
				PVName:     "missing-tar-pv",
				VolumePath: targetVolumePath,
				BackupFile: "nonexistent.tar.gz",
			}
			metaData, err := json.Marshal(meta)
			Expect(err).ToNot(HaveOccurred())
			Expect(os.WriteFile(filepath.Join(pvDir, "missing-tar-pv-metadata.json"), metaData, 0644)).To(Succeed())

			errs := restorePersistentVolumes(tempDir)
			Expect(errs).To(HaveLen(1))
			Expect(errs[0]).To(ContainSubstring("backup tar.gz archive not found"))
		})

		It("extracts valid persistent volume archive successfully", func() {
			pvDir := filepath.Join(tempDir, "pv")
			Expect(os.MkdirAll(pvDir, 0755)).To(Succeed())

			targetVolumePath := filepath.Join(tempDir, "safe-pv-data")

			// Create a valid tar.gz file
			tarPath := filepath.Join(pvDir, "valid-pv-backup.tar.gz")
			tf, err := os.Create(tarPath)
			Expect(err).ToNot(HaveOccurred())
			gw := gzip.NewWriter(tf)
			tw := tar.NewWriter(gw)

			content := []byte("pv storage content")
			Expect(tw.WriteHeader(&tar.Header{
				Name:     "data.txt",
				Typeflag: tar.TypeReg,
				Size:     int64(len(content)),
				Mode:     0644,
			})).To(Succeed())
			_, err = tw.Write(content)
			Expect(err).ToNot(HaveOccurred())

			Expect(tw.Close()).To(Succeed())
			Expect(gw.Close()).To(Succeed())
			Expect(tf.Close()).To(Succeed())

			meta := pvRestoreMetadata{
				Version:    "1.0",
				PVName:     "valid-pv",
				VolumePath: targetVolumePath,
				BackupFile: "valid-pv-backup.tar.gz",
			}
			metaData, err := json.Marshal(meta)
			Expect(err).ToNot(HaveOccurred())
			Expect(os.WriteFile(filepath.Join(pvDir, "valid-pv-backup-metadata.json"), metaData, 0644)).To(Succeed())

			errs := restorePersistentVolumes(tempDir)
			Expect(errs).To(BeEmpty())

			restoredFile := filepath.Join(targetVolumePath, "data.txt")
			data, err := os.ReadFile(restoredFile)
			Expect(err).ToNot(HaveOccurred())
			Expect(string(data)).To(Equal("pv storage content"))
		})
	})

	Describe("restoreContainerImages", func() {
		It("skips gracefully when images directory does not exist", func() {
			errs := restoreContainerImages(tempDir)
			Expect(errs).To(BeEmpty())
		})

		It("skips gracefully when images directory is empty", func() {
			imagesDir := filepath.Join(tempDir, "images")
			Expect(os.MkdirAll(imagesDir, 0755)).To(Succeed())

			errs := restoreContainerImages(tempDir)
			Expect(errs).To(BeEmpty())
		})
	})

	Describe("runLinuxSystemRestore", func() {
		It("fails when backup file path is empty", func() {
			err := runLinuxSystemRestore(tempDir, SystemRestoreConfig{BackupFile: ""})
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("backup file path must not be empty"))
		})

		It("fails when backup file does not exist", func() {
			err := runLinuxSystemRestore(tempDir, SystemRestoreConfig{
				BackupFile: filepath.Join(tempDir, "nonexistent.zip"),
			})
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("not found"))
		})

		It("fails when K2s is not installed", func() {
			emptyInstallDir := filepath.Join(tempDir, "notinstalled")
			Expect(os.MkdirAll(emptyInstallDir, 0755)).To(Succeed())

			backupFile := filepath.Join(tempDir, "backup.zip")
			zf, err := os.Create(backupFile)
			Expect(err).ToNot(HaveOccurred())
			zw := zip.NewWriter(zf)
			Expect(zw.Close()).To(Succeed())
			Expect(zf.Close()).To(Succeed())

			// If admin.conf doesn't exist
			if _, err := os.Stat("/etc/kubernetes/admin.conf"); err != nil {
				err = runLinuxSystemRestore(emptyInstallDir, SystemRestoreConfig{BackupFile: backupFile})
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("K2s is not installed"))
			}
		})
	})
})
