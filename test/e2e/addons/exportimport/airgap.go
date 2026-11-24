// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package exportimport

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/k2s-project/k2s/internal/core/addons"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const airGapProbeMarker = "K2S_AIRGAP_PROBE"

// Hosts that the failing offline imports tried to reach (apt/deb.debian.org and GitHub release downloads).
var airGapProbeUrls = []string{"https://github.com", "https://deb.debian.org"}

var (
	hostProbeRegex = regexp.MustCompile(airGapProbeMarker + `\|([^|\r\n]+)\|([^|\r\n]+)\|(REACHABLE|BLOCKED)\|([^\r\n]*)`)
	vmProbeRegex   = regexp.MustCompile(airGapProbeMarker + ` label=(\S+) exit=(\d+)`)
)

// hostBackup moves files/folders out of the K2s installation into a backup directory and moves them back on restore.
type hostBackup struct {
	dir   string
	items []backupItem
}

type backupItem struct {
	original string
	backup   string
}

func newHostBackup(rootDir string) (*hostBackup, error) {
	tmpParent := filepath.Join(rootDir, "tmp")
	if err := os.MkdirAll(tmpParent, 0o755); err != nil {
		return nil, fmt.Errorf("[AirGap] failed to create tmp directory %s: %w", tmpParent, err)
	}
	dir, err := os.MkdirTemp(tmpParent, "airgap-backup-")
	if err != nil {
		return nil, fmt.Errorf("[AirGap] failed to create backup directory under %s: %w", tmpParent, err)
	}
	return &hostBackup{dir: dir}, nil
}

// move moves path (file or folder) into the backup directory. A non-existing path is only logged.
func (b *hostBackup) move(path string) error {
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		GinkgoWriter.Printf("[AirGap]   already absent: %s\n", path)
		return nil
	} else if err != nil {
		return fmt.Errorf("[AirGap] cannot stat %s: %w", path, err)
	}

	backupPath := filepath.Join(b.dir, fmt.Sprintf("%d-%s", len(b.items), filepath.Base(path)))
	GinkgoWriter.Printf("[AirGap]   moving %s -> %s\n", path, backupPath)
	if err := renameWithRetry(path, backupPath); err != nil {
		return fmt.Errorf("[AirGap] failed to move %s to backup: %w", path, err)
	}
	b.items = append(b.items, backupItem{original: path, backup: backupPath})
	return nil
}

// restore puts the original files back (replacing whatever the import created) and removes the backup directory.
// The backup directory is preserved when restoring is incomplete so nothing gets lost.
func (b *hostBackup) restore() error {
	GinkgoWriter.Printf("[AirGap] Restoring %d original item(s) from %s\n", len(b.items), b.dir)

	var errs []error
	remaining := b.items[:0:0]
	for i := len(b.items) - 1; i >= 0; i-- {
		item := b.items[i]
		if _, err := os.Stat(item.original); err == nil {
			GinkgoWriter.Printf("[AirGap]   removing imported %s before restoring the original\n", item.original)
			if rmErr := removeDirWithRetry(item.original); rmErr != nil {
				errs = append(errs, fmt.Errorf("failed to remove %s: %w", item.original, rmErr))
				remaining = append(remaining, item)
				continue
			}
		}
		if err := os.MkdirAll(filepath.Dir(item.original), 0o755); err != nil {
			errs = append(errs, err)
			remaining = append(remaining, item)
			continue
		}
		if err := renameWithRetry(item.backup, item.original); err != nil {
			errs = append(errs, fmt.Errorf("failed to restore %s: %w", item.original, err))
			remaining = append(remaining, item)
			continue
		}
		GinkgoWriter.Printf("[AirGap]   restored %s\n", item.original)
	}
	b.items = remaining

	if len(errs) > 0 {
		GinkgoWriter.Printf("[AirGap] Restore incomplete, backup preserved in %s\n", b.dir)
		return errors.Join(errs...)
	}
	if err := os.RemoveAll(b.dir); err != nil {
		GinkgoWriter.Printf("[AirGap] WARNING: failed to remove backup dir %s: %v\n", b.dir, err)
	}
	return nil
}

// AddonFolderPath returns the folder of the addon implementation inside the K2s installation,
// matching the destination used by Import.ps1: addons/<addon>[/<implementation>].
func AddonFolderPath(rootDir string, addon *addons.Addon, impl *addons.Implementation) string {
	if impl.Name == addon.Metadata.Name {
		return filepath.Join(rootDir, "addons", addon.Metadata.Name)
	}
	return filepath.Join(rootDir, "addons", addon.Metadata.Name, impl.Name)
}

// windowsCurlPackagePaths returns the host files that an import writes for the implementation's windows curl packages (e.g. bin\linkerd.exe).
func windowsCurlPackagePaths(rootDir string, impl *addons.Implementation) []string {
	var paths []string
	for _, pkg := range impl.OfflineUsage.WindowsResources.CurlPackages {
		path := filepath.Join(rootDir, filepath.FromSlash(strings.ReplaceAll(pkg.Destination, `\`, "/")))
		if rel, err := filepath.Rel(rootDir, path); err != nil || rel == "." || strings.HasPrefix(rel, "..") {
			Fail(fmt.Sprintf("[AirGap] windows curl destination '%s' resolves outside of the K2s directory", pkg.Destination))
		}
		paths = append(paths, path)
	}
	return paths
}

// StageAddonRemovedFromHost moves the addon implementation folder and the Windows curl packages the import would
// install (e.g. bin\linkerd.exe) out of the K2s directory, so the import has to recreate them from the OCI artifact.
// The originals are restored automatically at the end of the enclosing container (DeferCleanup).
func StageAddonRemovedFromHost(rootDir string, addon *addons.Addon, impl *addons.Implementation) {
	GinkgoWriter.Println("=== REMOVE ADDON FOLDER AND WINDOWS PACKAGES FROM K2S DIRECTORY START ===")

	addonFolder := AddonFolderPath(rootDir, addon, impl)
	addonsRoot := filepath.Join(rootDir, "addons")
	if rel, err := filepath.Rel(addonsRoot, addonFolder); err != nil || rel == "." || strings.HasPrefix(rel, "..") || rel == "common" {
		Fail(fmt.Sprintf("[AirGap] refusing to delete unexpected addon folder '%s'", addonFolder))
	}
	toRemove := append([]string{addonFolder}, windowsCurlPackagePaths(rootDir, impl)...)

	backup, err := newHostBackup(rootDir)
	Expect(err).ToNot(HaveOccurred())
	DeferCleanup(func() {
		Expect(backup.restore()).To(Succeed(), "original addon files must be restored to avoid a modified K2s directory")
	})

	_, statErr := os.Stat(addonFolder)
	folderExisted := statErr == nil

	for _, path := range toRemove {
		Expect(backup.move(path)).To(Succeed())
	}

	if folderExisted {
		GinkgoWriter.Printf("[AirGap] Addon folder '%s' was removed (original backed up)\n", addonFolder)
	} else {
		GinkgoWriter.Printf("[AirGap] Addon folder '%s' does not exist in the K2s directory, nothing to remove: precondition already met\n", addonFolder)
	}

	for _, path := range toRemove {
		_, err := os.Stat(path)
		if errors.Is(err, os.ErrNotExist) {
			GinkgoWriter.Printf("[AirGap] VERIFIED absent before import: %s\n", path)
		} else {
			GinkgoWriter.Printf("[AirGap] NOT ABSENT: %s\n", path)
		}
		Expect(errors.Is(err, os.ErrNotExist)).To(BeTrue(), "'%s' must not exist before the import", path)
	}
	GinkgoWriter.Println("=== REMOVE ADDON FOLDER AND WINDOWS PACKAGES FROM K2S DIRECTORY END ===")
}

// RemoveAddonPackagesFromControlPlane deletes the staged debian/linux packages (~/.<ExportDirectoryName>) and verifies they are gone.
func RemoveAddonPackagesFromControlPlane(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, impl *addons.Implementation, controlPlaneIP string) {
	GinkgoWriter.Printf("[AirGap] Removing staged packages '.%s' on control plane %s\n", impl.ExportDirectoryName, controlPlaneIP)
	suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", fmt.Sprintf("sudo rm -rf .%s", impl.ExportDirectoryName), "-o")
	VerifyResourcesCleanedUp(ctx, suite, k2sDsl, impl, controlPlaneIP)
	GinkgoWriter.Printf("[AirGap] VERIFIED absent before import: control plane folder .%s\n", impl.ExportDirectoryName)
}

// VerifyNoNonCoreImagesInContainerRuntimes asserts that the container runtimes of all nodes only contain core Kubernetes images,
// and that none of the addon's own images is present.
func VerifyNoNonCoreImagesInContainerRuntimes(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, impl *addons.Implementation) {
	GinkgoWriter.Println("=== VERIFY NO ADDON IMAGES IN CONTAINER RUNTIMES START ===")

	nonCoreImages := k2sDsl.GetNonK8sImagesFromNodes(ctx)
	GinkgoWriter.Printf("[AirGap] Non-core images in container runtimes: %d\n", len(nonCoreImages))
	for i, image := range nonCoreImages {
		GinkgoWriter.Printf("[AirGap]   [%d] UNEXPECTED: %s\n", i, image)
	}
	Expect(nonCoreImages).To(BeEmpty(), "only core Kubernetes images may be present in the container runtimes before an air-gapped import")

	allAddonImages, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(*impl)
	Expect(err).ToNot(HaveOccurred(), "[AirGap] failed to determine images of implementation %s", impl.Name)
	addonImages := k2sDsl.FilterOutK8sImages(allAddonImages)
	if len(addonImages) == 0 {
		GinkgoWriter.Printf("[AirGap] Implementation '%s' declares no non-core images\n", impl.Name)
	} else {
		VerifyImagesAbsentFromNodes(ctx, k2sDsl, addonImages, "air-gapped precondition before import")
	}

	GinkgoWriter.Println("[AirGap] VERIFIED: only core Kubernetes images are in the container runtimes")
	GinkgoWriter.Println("=== VERIFY NO ADDON IMAGES IN CONTAINER RUNTIMES END ===")
}

