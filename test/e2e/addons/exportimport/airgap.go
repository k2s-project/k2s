// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package exportimport

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"

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
	Original string `json:"original"`
	Backup   string `json:"backup"`
}

const (
	backupDirPrefix    = "airgap-backup-"
	backupManifestName = "manifest.json"
)

var stagedAddonFileInventories sync.Map

func addonInventoryKey(addonName, implName string) string {
	return addonName + "/" + implName
}

func captureAddonFileInventory(addonDir string) ([]string, error) {
	var files []string
	err := filepath.WalkDir(addonDir, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(addonDir, path)
		if err != nil {
			return err
		}
		files = append(files, filepath.ToSlash(rel))
		return nil
	})
	sort.Strings(files)
	return files, err
}

func verifyStagedAddonFileInventory(rootDir string, addonArgs []string) {
	stagedAddonFileInventories.Range(func(key, value any) bool {
		addonName, implName, ok := strings.Cut(key.(string), "/")
		if !ok {
			return true
		}
		selected := false
		for i, arg := range addonArgs {
			if arg != addonName {
				continue
			}
			if implName == addonName || i+1 < len(addonArgs) && addonArgs[i+1] == implName {
				selected = true
				break
			}
		}
		if !selected {
			return true
		}

		expected := value.([]string)
		addonDir := filepath.Join(rootDir, "addons", addonName)
		actual, err := captureAddonFileInventory(addonDir)
		Expect(err).ToNot(HaveOccurred(), "[AirGap] failed to capture imported addon files for %s", addonName)
		missing := slices.DeleteFunc(slices.Clone(expected), func(path string) bool {
			return slices.Contains(actual, path) || runtimeGeneratedFile(addonName, path)
		})
		unexpected := slices.DeleteFunc(slices.Clone(actual), func(path string) bool {
			return slices.Contains(expected, path) || intentionalExportFile(addonName, implName, path)
		})
		Expect(missing).To(BeEmpty(), "[AirGap] imported addon is missing original files for %s/%s", addonName, implName)
		Expect(unexpected).To(BeEmpty(), "[AirGap] imported addon contains unexpected files for %s/%s", addonName, implName)
		stagedAddonFileInventories.Delete(key)
		return true
	})
}

// runtimeGeneratedFile reports files that enabling an addon creates inside its folder; they are no part of the addon
// package, so export neither ships nor import restores them. path is relative to addons/<addonName>.
func runtimeGeneratedFile(addonName, path string) bool {
	return addonName == "security" && strings.HasPrefix(path, "data/")
}

// intentionalExportFile reports files that the export adds on purpose and that therefore do not exist in the original
// addon folder. path is relative to addons/<addonName>; for addons with several implementations (e.g. storage) it
// starts with the implementation folder (smb/manifests/gitops-sync/...), which is stripped before matching.
func intentionalExportFile(addonName, implName, path string) bool {
	if implName != addonName {
		path = strings.TrimPrefix(path, implName+"/")
	}
	return strings.HasPrefix(path, "manifests/gitops-sync/") ||
		(addonName == "storage" && implName == "ceph" && strings.HasPrefix(path, "manifests/smb-shared/"))
}

// VerifyStagedAddonFileInventory checks that importing restored every original addon file.
func VerifyStagedAddonFileInventory(rootDir, addonName, implName string) {
	addonArgs := []string{addonName}
	if implName != addonName {
		addonArgs = append(addonArgs, implName)
	}
	verifyStagedAddonFileInventory(rootDir, addonArgs)
}

func newHostBackup(rootDir string) (*hostBackup, error) {
	tmpParent := filepath.Join(rootDir, "tmp")
	if err := os.MkdirAll(tmpParent, 0o755); err != nil {
		return nil, fmt.Errorf("[AirGap] failed to create tmp directory %s: %w", tmpParent, err)
	}
	dir, err := os.MkdirTemp(tmpParent, backupDirPrefix)
	if err != nil {
		return nil, fmt.Errorf("[AirGap] failed to create backup directory under %s: %w", tmpParent, err)
	}
	b := &hostBackup{dir: dir}
	return b, b.writeManifest()
}

// writeManifest persists what was moved, so that a later run can restore the originals even if this process
// terminated abruptly (e.g. a log.Fatal in a helper) and could not run its cleanup.
func (b *hostBackup) writeManifest() error {
	content, err := json.MarshalIndent(b.items, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(b.dir, backupManifestName), content, 0o644)
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
	item := backupItem{Original: path, Backup: backupPath}
	b.items = append(b.items, item)
	if err := b.writeManifest(); err != nil {
		b.items = b.items[:len(b.items)-1]
		return fmt.Errorf("[AirGap] failed to record move of %s: %w", path, err)
	}
	if err := renameWithRetry(path, backupPath); err != nil {
		b.items = b.items[:len(b.items)-1]
		_ = b.writeManifest()
		return fmt.Errorf("[AirGap] failed to move %s to backup: %w", path, err)
	}
	return nil
}

// restore puts the original files back and removes the backup directory.
// With replaceExisting, whatever exists at the original location (e.g. created by the import) is replaced;
// otherwise an existing original is kept and its backup is preserved.
// The backup directory is preserved when restoring is incomplete so nothing gets lost.
func (b *hostBackup) restore(replaceExisting bool) error {
	GinkgoWriter.Printf("[AirGap] Restoring %d original item(s) from %s\n", len(b.items), b.dir)

	var errs []error
	remaining := b.items[:0:0]
	for i := len(b.items) - 1; i >= 0; i-- {
		item := b.items[i]
		if _, err := os.Stat(item.Backup); errors.Is(err, os.ErrNotExist) {
			if _, originalErr := os.Stat(item.Original); originalErr == nil {
				GinkgoWriter.Printf("[AirGap]   move was not completed for %s; keeping original\n", item.Original)
				continue
			}
			errs = append(errs, fmt.Errorf("backup %s is missing", item.Backup))
			remaining = append(remaining, item)
			continue
		}
		if _, err := os.Stat(item.Original); err == nil {
			if !replaceExisting {
				errs = append(errs, fmt.Errorf("%s exists again, its backup %s is kept", item.Original, item.Backup))
				remaining = append(remaining, item)
				continue
			}
			GinkgoWriter.Printf("[AirGap]   removing imported %s before restoring the original\n", item.Original)
			if rmErr := removeDirWithRetry(item.Original); rmErr != nil {
				errs = append(errs, fmt.Errorf("failed to remove %s: %w", item.Original, rmErr))
				remaining = append(remaining, item)
				continue
			}
		}
		if err := os.MkdirAll(filepath.Dir(item.Original), 0o755); err != nil {
			errs = append(errs, err)
			remaining = append(remaining, item)
			continue
		}
		if err := renameWithRetry(item.Backup, item.Original); err != nil {
			errs = append(errs, fmt.Errorf("failed to restore %s: %w", item.Original, err))
			remaining = append(remaining, item)
			continue
		}
		GinkgoWriter.Printf("[AirGap]   restored %s\n", item.Original)
	}
	b.items = remaining
	_ = b.writeManifest()

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
	toRemove := []string{addonFolder}
	if addonFolder != filepath.Join(addonsRoot, addon.Metadata.Name) {
		addonRoot := filepath.Join(addonsRoot, addon.Metadata.Name)
		rootEntries, err := os.ReadDir(addonRoot)
		Expect(err).ToNot(HaveOccurred(), "[AirGap] failed to list addon root %s", addonRoot)
		for _, entry := range rootEntries {
			if !entry.IsDir() {
				toRemove = append(toRemove, filepath.Join(addonRoot, entry.Name()))
			}
		}
	}
	toRemove = append(toRemove, windowsCurlPackagePaths(rootDir, impl)...)

	framework.RecoverStaleAddonBackups(rootDir)

	inventory, err := captureAddonFileInventory(filepath.Join(addonsRoot, addon.Metadata.Name))
	Expect(err).ToNot(HaveOccurred(), "[AirGap] failed to capture original addon file inventory")

	backup, err := newHostBackup(rootDir)
	Expect(err).ToNot(HaveOccurred())
	inventoryKey := addonInventoryKey(addon.Metadata.Name, impl.Name)
	stagedAddonFileInventories.Store(inventoryKey, inventory)
	DeferCleanup(func() {
		defer stagedAddonFileInventories.Delete(inventoryKey)
		Expect(backup.restore(true)).To(Succeed(), "original addon files must be restored to avoid a modified K2s directory")
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

// Packages the K2s control plane setup itself installs or relies on; they are never purged even if an addon declares them.
var baseSystemDebPackages = []string{"curl", "gpg", "gnupg", "ca-certificates", "dnsutils", "dnsmasq", "util-linux", "util-linux-extra", "lsb-release"}

var (
	debPackageNameRegex = regexp.MustCompile(`^[a-z0-9][a-z0-9+.-]*$`)
	purgeResultRegex    = regexp.MustCompile(`K2S_PURGE (\w[\w-]*) (\S+)(.*)`)
)

// PurgeAddonDebianPackages purges the debian packages the addon declares (offline_usage.linux.deb) from the control
// plane, so an import starts without anything a previous enable of the addon installed, and verifies the result.
//
// Two guards keep the node intact; a package that is skipped is logged and added to the report as a remaining item:
//   - packages of the K2s base system (baseSystemDebPackages) are never purged
//   - a package is only purged if apt's simulation shows that nothing else would be removed with it
//
// Dependencies that were pulled in by the packages are not removed (no autoremove), and nothing is reinstalled afterwards.
func PurgeAddonDebianPackages(ctx context.Context, suite *framework.K2sTestSuite, impl *addons.Implementation, controlPlaneIP string) {
	GinkgoWriter.Println("=== PURGE ADDON DEBIAN PACKAGES START ===")

	var candidates []string
	for _, pkg := range impl.OfflineUsage.LinuxResources.DebPackages {
		Expect(pkg).To(MatchRegexp(debPackageNameRegex.String()), "[AirGap] unsupported debian package name '%s'", pkg)
		if slices.Contains(baseSystemDebPackages, pkg) {
			GinkgoWriter.Printf("[AirGap] Debian package '%s' belongs to the K2s base system, not purging\n", pkg)
			continue
		}
		candidates = append(candidates, pkg)
	}
	if len(candidates) == 0 {
		GinkgoWriter.Printf("[AirGap] Implementation '%s' declares no debian packages that can be purged\n", impl.Name)
		GinkgoWriter.Println("=== PURGE ADDON DEBIAN PACKAGES END ===")
		return
	}

	cmd := fmt.Sprintf(`for p in %s; do `+
		`if ! dpkg -s "$p" >/dev/null 2>&1; then echo "K2S_PURGE absent $p"; continue; fi; `+
		`extra=$(sudo apt-get purge --simulate -y "$p" 2>/dev/null | grep '^Remv' | awk '{print $2}' | grep -vx "$p" | tr '\n' ' '); `+
		`if [ -n "$extra" ]; then echo "K2S_PURGE skipped $p would also remove: $extra"; continue; fi; `+
		`if sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y "$p" >/dev/null 2>&1; then echo "K2S_PURGE purged $p"; else echo "K2S_PURGE failed $p"; fi; `+
		`done`, strings.Join(candidates, " "))
	output, _ := suite.K2sCli().Exec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", cmd, "-r")

	results := purgeResultRegex.FindAllStringSubmatch(output, -1)
	Expect(results).To(HaveLen(len(candidates)), "[AirGap] every debian package must report a purge result, output: %s", output)

	var failed, skipped []string
	for _, r := range results {
		state, pkg, detail := r[1], r[2], strings.TrimSpace(r[3])
		GinkgoWriter.Printf("[AirGap] debian package %-20s -> %s %s\n", pkg, state, detail)
		switch state {
		case "failed":
			failed = append(failed, pkg)
		case "skipped":
			skipped = append(skipped, pkg+" ("+detail+")")
		}
	}
	Expect(failed).To(BeEmpty(), "[AirGap] debian packages could not be purged")

	for _, r := range results {
		if r[1] == "skipped" {
			continue
		}
		suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", fmt.Sprintf("! dpkg -s %s >/dev/null 2>&1", r[2]), "-o")
		GinkgoWriter.Printf("[AirGap] VERIFIED not installed before import: debian package %s\n", r[2])
	}

	if len(skipped) > 0 {
		warning := fmt.Sprintf("These debian packages of '%s' remain installed because purging them would remove other packages: %v", impl.Name, skipped)
		GinkgoWriter.Printf("[AirGap] WARNING: %s\n", warning)
		AddReportEntry("AIR-GAP WARNING: debian packages remain installed", warning)
	}
	GinkgoWriter.Println("=== PURGE ADDON DEBIAN PACKAGES END ===")
}

const controlPlaneBackupDir = "/tmp/k2s-airgap-backup"

func execOnControlPlane(ctx context.Context, suite *framework.K2sTestSuite, controlPlaneIP string, cmd string) {
	suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", cmd, "-o")
}

// RemoveAddonPackagesFromControlPlane removes everything an import stages on the control plane and verifies it is gone:
//   - the staged debian packages and relative linux files (~/.<ExportDirectoryName>)
//   - linux binaries with an absolute destination (e.g. /usr/local/bin/virtctl); they are moved to a backup on the
//     control plane and restored automatically at the end of the enclosing container (DeferCleanup)
//   - the apt package cache, so that no previously downloaded .deb file can hide a missing package
func RemoveAddonPackagesFromControlPlane(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, impl *addons.Implementation, controlPlaneIP string) {
	GinkgoWriter.Printf("[AirGap] Removing staged packages '.%s' on control plane %s\n", impl.ExportDirectoryName, controlPlaneIP)
	execOnControlPlane(ctx, suite, controlPlaneIP, fmt.Sprintf("sudo rm -rf .%s .%s", impl.ExportDirectoryName, debianPackageDirectoryName(impl)))
	VerifyResourcesCleanedUp(ctx, suite, k2sDsl, impl, controlPlaneIP)
	GinkgoWriter.Printf("[AirGap] VERIFIED absent before import: control plane folder .%s\n", impl.ExportDirectoryName)

	GinkgoWriter.Println("[AirGap] Cleaning the apt package cache on the control plane")
	execOnControlPlane(ctx, suite, controlPlaneIP, "sudo apt-get clean")

	for _, pkg := range impl.OfflineUsage.LinuxResources.CurlPackages {
		destination := pkg.Destination
		if !strings.HasPrefix(destination, "/") {
			continue // relative destinations live in the staged folder removed above
		}
		Expect(destination).To(MatchRegexp(`^/[A-Za-z0-9._/-]+$`), "[AirGap] unsupported linux curl destination '%s'", destination)
		Expect(destination).ToNot(Or(Equal("/"), HaveSuffix("/")), "[AirGap] linux curl destination '%s' must be a file", destination)

		backupPath := controlPlaneBackupDir + "/" + strings.ReplaceAll(strings.TrimPrefix(destination, "/"), "/", "_")
		GinkgoWriter.Printf("[AirGap] Moving linux package %s to %s on the control plane\n", destination, backupPath)
		execOnControlPlane(ctx, suite, controlPlaneIP,
			fmt.Sprintf("sudo mkdir -p %s && if [ -e %s ]; then sudo mv -f %s %s; fi", controlPlaneBackupDir, destination, destination, backupPath))

		// Also restores a backup left behind by an aborted earlier run.
		DeferCleanup(func() {
			GinkgoWriter.Printf("[AirGap] Restoring linux package %s on the control plane\n", destination)
			execOnControlPlane(context.Background(), suite, controlPlaneIP,
				fmt.Sprintf("if [ -e %s ]; then sudo rm -rf %s && sudo mv -f %s %s; fi", backupPath, destination, backupPath, destination))
		})

		suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", fmt.Sprintf("[ ! -e %s ]", destination), "-o")
		GinkgoWriter.Printf("[AirGap] VERIFIED absent before import: control plane file %s\n", destination)
	}
}

var addonImageCache = map[string][]string{}

// addonNonCoreImages returns the non-core images declared by the addon implementation. Determining them reads files
// of the addon folder and terminates the whole test process (log.Fatal) when that folder is absent, so the result is
// cached while the folder still exists (PrepareAirGappedAddonImport runs this before the folder is removed).
// known is false when the images cannot be determined because the folder is absent and nothing was cached.
func addonNonCoreImages(suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, addon *addons.Addon, impl *addons.Implementation) (images []string, known bool) {
	key := addon.Metadata.Name + "/" + impl.Name
	if cached, ok := addonImageCache[key]; ok {
		return cached, true
	}
	if _, err := os.Stat(AddonFolderPath(suite.RootDir(), addon, impl)); err != nil {
		return nil, false
	}

	allImages, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(*impl)
	Expect(err).ToNot(HaveOccurred(), "[AirGap] failed to determine images of implementation %s", impl.Name)
	addonImageCache[key] = k2sDsl.FilterOutK8sImages(allImages)
	return addonImageCache[key], true
}

// VerifyNoNonCoreImagesInContainerRuntimes asserts that the container runtimes of all nodes only contain core Kubernetes images,
// and that none of the addon's own images is present.
func VerifyNoNonCoreImagesInContainerRuntimes(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, addon *addons.Addon, impl *addons.Implementation) {
	GinkgoWriter.Println("=== VERIFY NO ADDON IMAGES IN CONTAINER RUNTIMES START ===")

	nonCoreImages := k2sDsl.GetNonK8sImagesFromNodes(ctx)
	GinkgoWriter.Printf("[AirGap] Non-core images in container runtimes: %d\n", len(nonCoreImages))
	for i, image := range nonCoreImages {
		GinkgoWriter.Printf("[AirGap]   [%d] UNEXPECTED: %s\n", i, image)
	}
	Expect(nonCoreImages).To(BeEmpty(), "only core Kubernetes images may be present in the container runtimes before an air-gapped import")

	addonImages, known := addonNonCoreImages(suite, k2sDsl, addon, impl)
	switch {
	case !known:
		GinkgoWriter.Printf("[AirGap] Images of '%s' cannot be determined because its addon folder is absent, relying on the non-core image check above\n", impl.Name)
	case len(addonImages) == 0:
		GinkgoWriter.Printf("[AirGap] Implementation '%s' declares no non-core images\n", impl.Name)
	default:
		VerifyImagesAbsentFromNodes(ctx, k2sDsl, addonImages, "air-gapped precondition before import")
	}

	GinkgoWriter.Println("[AirGap] VERIFIED: only core Kubernetes images are in the container runtimes")
	GinkgoWriter.Println("=== VERIFY NO ADDON IMAGES IN CONTAINER RUNTIMES END ===")
}
