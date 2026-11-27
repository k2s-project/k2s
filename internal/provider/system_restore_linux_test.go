// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("Linux System Restore", func() {
	var tempDir string

	BeforeEach(func() {
		tempDir = GinkgoT().TempDir()

		originalRoots := trustedVolumeRoots
		trustedVolumeRoots = append(append([]string{}, originalRoots...), tempDir)
		DeferCleanup(func() { trustedVolumeRoots = originalRoots })
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

		It("accepts data directories inside trusted storage roots", func() {
			Expect(isDangerousVolumePath("/var/lib/k2s/volumes/pv-data")).To(BeFalse())
			Expect(isDangerousVolumePath("/mnt/data/storage")).To(BeFalse())
			Expect(isDangerousVolumePath("/srv/nfs/share")).To(BeFalse())
		})

		It("rejects sensitive locations outside the trusted storage roots", func() {
			Expect(isDangerousVolumePath("/var/spool/cron")).To(BeTrue())
			Expect(isDangerousVolumePath("/opt/k2s/volumes/pv1")).To(BeTrue())
			Expect(isDangerousVolumePath("/var/lib/k2s/setup.json")).To(BeTrue())
		})

		It("rejects ancestors of protected locations", func() {
			Expect(isDangerousVolumePath("/var/lib")).To(BeTrue())
			Expect(isDangerousVolumePath("/var")).To(BeTrue())
		})

		It("resolves a missing destination below a symlink before validating it", func() {
			root := GinkgoT().TempDir()
			trustedVolumeRoots = []string{root}
			Expect(os.Symlink("/etc", filepath.Join(root, "alias"))).To(Succeed())

			Expect(isDangerousVolumePath(filepath.Join(root, "alias", "missing"))).To(BeTrue())
			resolved, err := resolveVolumePath(filepath.Join(root, "data", "missing"))
			Expect(err).ToNot(HaveOccurred())
			Expect(resolved).To(HaveSuffix(filepath.Join("data", "missing")))
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
				Version:            "1.0",
				PVName:             "valid-pv",
				VolumePath:         targetVolumePath,
				VolumeKind:         "directory",
				BackupFile:         "valid-pv-backup.tar.gz",
				VolumeRootMetadata: true,
				VolumeRootMode:     0750,
			}
			metaData, err := json.Marshal(meta)
			Expect(err).ToNot(HaveOccurred())
			Expect(os.WriteFile(filepath.Join(pvDir, "valid-pv-backup-metadata.json"), metaData, 0644)).To(Succeed())

			originalRunner := restoreKubectlRunner
			restoreKubectlRunner = func(_ time.Duration, args ...string) (string, error) {
				if len(args) >= 3 && args[0] == "get" && args[1] == "pv" {
					return "", errors.New("NotFound")
				}
				return "", errors.New("unexpected kubectl call in PV restore test")
			}
			DeferCleanup(func() { restoreKubectlRunner = originalRunner })

			errs := restorePersistentVolumes(tempDir)
			Expect(errs).To(BeEmpty())

			restoredFile := filepath.Join(targetVolumePath, "data.txt")
			data, err := os.ReadFile(restoredFile)
			Expect(err).ToNot(HaveOccurred())
			Expect(string(data)).To(Equal("pv storage content"))
			info, err := os.Stat(targetVolumePath)
			Expect(err).ToNot(HaveOccurred())
			Expect(info.Mode().Perm()).To(Equal(os.FileMode(0750)))
		})
	})

	Describe("restore volume metadata", func() {
		It("infers legacy file-backed hostPath volumes from the saved PV definition", func() {
			pvDir := filepath.Join(tempDir, "NotNamespaced")
			Expect(os.MkdirAll(pvDir, 0755)).To(Succeed())
			Expect(os.WriteFile(filepath.Join(pvDir, "persistentvolumes.yaml"), []byte(`items:
- metadata:
    name: legacy-file
  spec:
    hostPath:
      path: /mnt/file
      type: File
`), 0644)).To(Succeed())

			kind, err := resolveVolumeKind(pvRestoreMetadata{PVName: "legacy-file"}, tempDir, filepath.Join(tempDir, "missing"))
			Expect(err).ToNot(HaveOccurred())
			Expect(kind).To(Equal("file"))
		})
	})

	Describe("Linux backup PV metadata", func() {
		It("archives the PV root metadata and rejects escaping symlinks", func() {
			source := filepath.Join(tempDir, "source")
			Expect(os.MkdirAll(source, 0700)).To(Succeed())
			archive := filepath.Join(tempDir, "pv.tar.gz")
			Expect(tarGzDirectory(source, archive)).To(Succeed())

			file, err := os.Open(archive)
			Expect(err).ToNot(HaveOccurred())
			gz, err := gzip.NewReader(file)
			Expect(err).ToNot(HaveOccurred())
			header, err := tar.NewReader(gz).Next()
			Expect(err).ToNot(HaveOccurred())
			Expect(header.Name).To(Equal("./"))
			Expect(header.Mode & 0777).To(Equal(int64(0700)))
			Expect(gz.Close()).To(Succeed())
			Expect(file.Close()).To(Succeed())

			outside := GinkgoT().TempDir()
			Expect(os.Symlink(outside, filepath.Join(source, "escape"))).To(Succeed())
			Expect(tarGzDirectory(source, filepath.Join(tempDir, "bad.tar.gz"))).ToNot(Succeed())
		})

		It("includes addon namespaces, storage classes, and addon PVs by default", func() {
			cfg := loadBackupConfig(tempDir)
			Expect(containsString(cfg.ExcludedNamespaces, "ingress-nginx")).To(BeFalse())
			Expect(containsString(cfg.ExcludedNamespaces, "registry")).To(BeFalse())
			Expect(containsString(cfg.ExcludedClusterResources, "storageclasses")).To(BeFalse())
			Expect(containsString(cfg.ExcludedAddonPersistentVolumes, "registry-pv")).To(BeFalse())
		})
	})

	Describe("isMountPoint", func() {
		It("identifies filesystem roots and ordinary directories", func() {
			mounted, err := isMountPoint("/")
			Expect(err).ToNot(HaveOccurred())
			Expect(mounted).To(BeTrue())
			mounted, err = isMountPoint(tempDir)
			Expect(err).ToNot(HaveOccurred())
			Expect(mounted).To(BeFalse())
		})
	})

	Describe("validateBackupManifest with UTF-8 BOM", func() {
		It("parses a manifest written with a byte-order mark", func() {
			content := append([]byte{0xEF, 0xBB, 0xBF}, []byte(`{"apiVersion":"k2s.backup/v1","kind":"SystemBackup"}`)...)
			Expect(os.WriteFile(filepath.Join(tempDir, "backup.json"), content, 0644)).To(Succeed())

			manifest, err := validateBackupManifest(tempDir)
			Expect(err).ToNot(HaveOccurred())
			Expect(manifest.Kind).To(Equal("SystemBackup"))
		})
	})

	Describe("restorePersistentVolumes path confinement", func() {
		It("does not read archives outside the pv directory", func() {
			pvDir := filepath.Join(tempDir, "pv")
			Expect(os.MkdirAll(pvDir, 0755)).To(Succeed())
			Expect(os.WriteFile(filepath.Join(tempDir, "outside.tar.gz"), []byte("x"), 0644)).To(Succeed())

			meta := pvRestoreMetadata{PVName: "../outside", VolumePath: filepath.Join(tempDir, "vol"), BackupFile: "../outside.tar.gz"}
			metaData, err := json.Marshal(meta)
			Expect(err).ToNot(HaveOccurred())
			Expect(os.WriteFile(filepath.Join(pvDir, "x-metadata.json"), metaData, 0644)).To(Succeed())

			errs := restorePersistentVolumes(tempDir)
			Expect(errs).To(HaveLen(1))
			Expect(errs[0]).To(ContainSubstring("backup tar.gz archive not found"))
		})
	})

	Describe("restoreContainerImages manifest handling", func() {
		It("resolves Windows style root-relative archive paths and reports missing archives", func() {
			nested := filepath.Join(tempDir, "images", "images")
			Expect(os.MkdirAll(nested, 0755)).To(Succeed())
			Expect(os.WriteFile(filepath.Join(nested, "a.tar"), []byte("x"), 0644)).To(Succeed())
			manifest := `{"Images":[{"TarFile":"images\\images\\a.tar","Node":"windows-worker"},{"TarFile":"images\\images\\missing.tar","Node":"kubemaster"}]}`
			Expect(os.WriteFile(filepath.Join(tempDir, "images", "manifest.json"), []byte(manifest), 0644)).To(Succeed())

			var imported []string
			errs := restoreContainerImages(tempDir, func(p string, windows bool) error {
				imported = append(imported, p)
				Expect(windows).To(BeTrue())
				return nil
			})
			Expect(imported).To(ConsistOf(filepath.Join(nested, "a.tar")))
			Expect(errs).To(HaveLen(1))
			Expect(errs[0]).To(ContainSubstring("missing.tar"))
		})
	})

	Describe("cleanAndConvertResourceJSON", func() {
		It("drops controller-owned objects and keeps standalone ones", func() {
			raw := `{"kind":"PodList","items":[{"metadata":{"name":"owned","ownerReferences":[{"kind":"Job","controller":true}]}},{"metadata":{"name":"standalone"}}]}`
			out, has, err := cleanAndConvertResourceJSON([]byte(raw))
			Expect(err).ToNot(HaveOccurred())
			Expect(has).To(BeTrue())
			Expect(string(out)).To(ContainSubstring("standalone"))
			Expect(string(out)).ToNot(ContainSubstring("owned"))
		})

		It("preserves active Jobs and StatefulSet-owned PVCs", func() {
			for _, kind := range []string{"JobList", "PersistentVolumeClaimList"} {
				raw := `{"kind":"` + kind + `","items":[{"metadata":{"name":"owned","ownerReferences":[{"kind":"CronJob","controller":true}]}}]}`
				out, has, err := cleanAndConvertResourceJSON([]byte(raw))
				Expect(err).ToNot(HaveOccurred())
				Expect(has).To(BeTrue())
				Expect(string(out)).To(ContainSubstring("owned"))
			}
		})
	})

	Describe("restoreContainerImages", func() {
		It("skips gracefully when images directory does not exist", func() {
			errs := restoreContainerImages(tempDir, func(string, bool) error { return nil })
			Expect(errs).To(BeEmpty())
		})

		It("skips gracefully when images directory is empty", func() {
			imagesDir := filepath.Join(tempDir, "images")
			Expect(os.MkdirAll(imagesDir, 0755)).To(Succeed())

			errs := restoreContainerImages(tempDir, func(string, bool) error { return nil })
			Expect(errs).To(BeEmpty())
		})

		It("classifies manifest entries by their source node", func() {
			Expect(isWindowsImageNode("kubemaster")).To(BeFalse())
			Expect(isWindowsImageNode("linux")).To(BeFalse())
			Expect(isWindowsImageNode("Linux")).To(BeFalse())
			Expect(isWindowsImageNode("windows-worker")).To(BeTrue())
			Expect(isWindowsImageNode("")).To(BeFalse())
		})
	})

	Describe("loadBackupConfig with shipped cfg/config.json", func() {
		It("uses Linux backup defaults without excluding addon namespaces, storageclasses, or addon PVs", func() {
			repoRoot := filepath.Join("..", "..")
			cfg := loadBackupConfig(repoRoot)

			Expect(cfg.ExcludedNamespaces).To(ContainElements("kube-system", "kube-public", "kube-node-lease"))
			Expect(cfg.ExcludedNamespaces).NotTo(ContainElements("ingress-nginx", "monitoring", "logging", "storage"))
			Expect(cfg.ExcludedClusterResources).NotTo(ContainElement("storageclasses"))
			Expect(cfg.ExcludedAddonPersistentVolumes).To(BeEmpty())
		})
	})

	Describe("cleanResourceMap", func() {
		It("filters controller-owned Pods and ReplicaSets inside generic kind List", func() {
			list := map[string]any{
				"apiVersion": "v1",
				"kind":       "List",
				"items": []any{
					map[string]any{
						"apiVersion": "v1",
						"kind":       "Pod",
						"metadata": map[string]any{
							"name": "owned-pod",
							"ownerReferences": []any{
								map[string]any{"kind": "ReplicaSet", "name": "rs-1", "controller": true},
							},
						},
					},
					map[string]any{
						"apiVersion": "v1",
						"kind":       "Pod",
						"metadata":   map[string]any{"name": "standalone-pod"},
					},
					map[string]any{
						"apiVersion": "apps/v1",
						"kind":       "ReplicaSet",
						"metadata": map[string]any{
							"name": "owned-rs",
							"ownerReferences": []any{
								map[string]any{"kind": "Deployment", "name": "dep-1", "controller": true},
							},
						},
					},
				},
			}

			cleanResourceMap(list)
			items, ok := list["items"].([]any)
			Expect(ok).To(BeTrue())
			Expect(items).To(HaveLen(1))
			meta := items[0].(map[string]any)["metadata"].(map[string]any)
			Expect(meta["name"]).To(Equal("standalone-pod"))
		})
	})

	Describe("resolveVolumePath policy", func() {
		It("accepts /registry paths by default", func() {
			p, err := resolveVolumePath("/registry/data")
			Expect(err).ToNot(HaveOccurred())
			Expect(p).To(Equal("/registry/data"))
		})

		It("reports allowed roots and K2S_RESTORE_PV_ROOTS when rejecting untrusted paths", func() {
			_, err := resolveVolumePath("/tmp/untrusted-pv")
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("K2S_RESTORE_PV_ROOTS"))
			Expect(err.Error()).To(ContainSubstring("/registry"))
		})
	})

	Describe("sanitizeMissingJob", func() {
		It("strips generated selector and controller-UID/job-name labels", func() {
			job := map[string]any{
				"apiVersion": "batch/v1",
				"kind":       "Job",
				"metadata": map[string]any{
					"name": "my-job",
					"labels": map[string]any{
						"app":                              "demo",
						"controller-uid":                   "old-uid",
						"batch.kubernetes.io/controller-uid": "old-uid",
					},
				},
				"spec": map[string]any{
					"selector": map[string]any{
						"matchLabels": map[string]any{"controller-uid": "old-uid"},
					},
					"template": map[string]any{
						"metadata": map[string]any{
							"labels": map[string]any{
								"app":                              "demo",
								"controller-uid":                   "old-uid",
								"batch.kubernetes.io/controller-uid": "old-uid",
								"job-name":                         "my-job",
								"batch.kubernetes.io/job-name":     "my-job",
							},
						},
					},
				},
			}

			Expect(sanitizeMissingJob(job)).To(BeTrue())
			spec := job["spec"].(map[string]any)
			Expect(spec).NotTo(HaveKey("selector"))
			tplLabels := spec["template"].(map[string]any)["metadata"].(map[string]any)["labels"].(map[string]any)
			Expect(tplLabels).To(Equal(map[string]any{"app": "demo"}))
			metaLabels := job["metadata"].(map[string]any)["labels"].(map[string]any)
			Expect(metaLabels).To(Equal(map[string]any{"app": "demo"}))
		})

		It("preserves selector and labels when manualSelector is true", func() {
			job := map[string]any{
				"metadata": map[string]any{"name": "manual-job"},
				"spec": map[string]any{
					"manualSelector": true,
					"selector": map[string]any{
						"matchLabels": map[string]any{"custom": "val"},
					},
					"template": map[string]any{
						"metadata": map[string]any{
							"labels": map[string]any{"custom": "val"},
						},
					},
				},
			}

			Expect(sanitizeMissingJob(job)).To(BeFalse())
			Expect(job["spec"].(map[string]any)).To(HaveKey("selector"))
		})
	})

	Describe("extractWebhookBackingServices", func() {
		It("extracts unique backing services from webhook list manifests", func() {
			whFile := filepath.Join(tempDir, "validatingwebhookconfigurations.yaml")
			content := `apiVersion: v1
kind: List
items:
- apiVersion: admissionregistration.k8s.io/v1
  kind: ValidatingWebhookConfiguration
  metadata:
    name: my-wh
  webhooks:
  - name: a.example.com
    clientConfig:
      service:
        namespace: cert-manager
        name: cert-manager-webhook
  - name: b.example.com
    clientConfig:
      service:
        namespace: cert-manager
        name: cert-manager-webhook
`
			Expect(os.WriteFile(whFile, []byte(content), 0644)).To(Succeed())

			refs, err := extractWebhookBackingServices(whFile)
			Expect(err).ToNot(HaveOccurred())
			Expect(refs).To(Equal([]webhookServiceRef{{namespace: "cert-manager", name: "cert-manager-webhook"}}))
		})
	})

	Describe("transactional multi-PV restore", func() {
		It("aborts before mutating PV #1 when PV #2 fails preflight", func() {
			origRoots := trustedVolumeRoots
			trustedVolumeRoots = []string{tempDir}
			defer func() { trustedVolumeRoots = origRoots }()

			pv1Target := filepath.Join(tempDir, "pv1")
			Expect(os.MkdirAll(pv1Target, 0755)).To(Succeed())
			Expect(os.WriteFile(filepath.Join(pv1Target, "state.txt"), []byte("original-pv1"), 0644)).To(Succeed())

			srcDir := filepath.Join(tempDir, "src-pv1")
			Expect(os.MkdirAll(srcDir, 0755)).To(Succeed())
			Expect(os.WriteFile(filepath.Join(srcDir, "state.txt"), []byte("restored-pv1"), 0644)).To(Succeed())

			pvDir := filepath.Join(tempDir, "staging", "pv")
			Expect(os.MkdirAll(pvDir, 0755)).To(Succeed())
			Expect(tarGzDirectory(srcDir, filepath.Join(pvDir, "pv1-backup.tar.gz"))).To(Succeed())

			meta1 := pvRestoreMetadata{
				PVName:     "pv1",
				VolumePath: pv1Target,
				VolumeKind: "directory",
				BackupFile: "pv1-backup.tar.gz",
			}
			b1, err := json.Marshal(meta1)
			Expect(err).ToNot(HaveOccurred())
			Expect(os.WriteFile(filepath.Join(pvDir, "pv1-metadata.json"), b1, 0644)).To(Succeed())

			// PV #2 references a missing archive, so preflight must abort before pv1 is modified.
			meta2 := pvRestoreMetadata{
				PVName:     "pv2",
				VolumePath: filepath.Join(tempDir, "pv2"),
				VolumeKind: "directory",
				BackupFile: "missing.tar.gz",
			}
			b2, err := json.Marshal(meta2)
			Expect(err).ToNot(HaveOccurred())
			Expect(os.WriteFile(filepath.Join(pvDir, "pv2-metadata.json"), b2, 0644)).To(Succeed())

			_, errs := restorePersistentVolumesDeferredResume(filepath.Join(tempDir, "staging"))
			Expect(errs).NotTo(BeEmpty())

			data, err := os.ReadFile(filepath.Join(pv1Target, "state.txt"))
			Expect(err).ToNot(HaveOccurred())
			Expect(string(data)).To(Equal("original-pv1"))
		})
	})

	Describe("windowsWorkerSSHOptions", func() {
		It("pins known_hosts, enforces strict host key checking, and sets noninteractive timeouts", func() {
			cfgDir := filepath.Join(tempDir, "k2s-cfg")
			sshDir := filepath.Join(cfgDir, "ssh")
			keyDir := filepath.Join(sshDir, "k2s")
			Expect(os.MkdirAll(keyDir, 0700)).To(Succeed())
			keyPath := filepath.Join(keyDir, "id_ed25519")
			knownHostsPath := filepath.Join(sshDir, "windows-worker.known_hosts")
			Expect(os.WriteFile(keyPath, []byte("dummy-key"), 0600)).To(Succeed())
			Expect(os.WriteFile(knownHostsPath, []byte("172.19.1.101 ssh-ed25519 AAAA\n"), 0600)).To(Succeed())

			installDir := filepath.Join(tempDir, "install")
			Expect(os.MkdirAll(filepath.Join(installDir, "cfg"), 0755)).To(Succeed())
			cfgJSON, err := json.Marshal(map[string]any{
				"smallsetup": map[string]any{"kubeSwitch": "172.19.1.1"},
				"configDir":  map[string]any{"ssh": sshDir},
				"sshKey": map[string]any{
					"subDir":   "k2s",
					"fileName": map[string]any{"linux": "id_ed25519"},
				},
			})
			Expect(err).ToNot(HaveOccurred())
			Expect(os.WriteFile(filepath.Join(installDir, "cfg", "config.json"), cfgJSON, 0644)).To(Succeed())

			p := &linuxImageProvider{installDir: installDir, configDir: cfgDir}
			kPath, khPath, workerIP, err := p.windowsWorkerSSHConfig()
			Expect(err).ToNot(HaveOccurred())
			Expect(kPath).To(Equal(keyPath))
			Expect(khPath).To(Equal(knownHostsPath))
			Expect(workerIP).To(Equal("172.19.1.101"))

			opts := windowsWorkerSSHOptions(kPath, khPath)
			Expect(opts).To(ContainElements(
				"BatchMode=yes",
				"StrictHostKeyChecking=yes",
				"UserKnownHostsFile="+knownHostsPath,
				"ServerAliveInterval=15",
				"ServerAliveCountMax=4",
			))
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
