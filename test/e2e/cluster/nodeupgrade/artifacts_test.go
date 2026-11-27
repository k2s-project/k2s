// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package nodeupgrade

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strings"
)

const (
	expectedDeltaManifestVersion = "2.0"
	expectedNodeDeltaType        = "node-package"
	expectedDeltaHashAlgorithm   = "SHA256"

	upgradeModeFull  = "FULL"
	upgradeModeDelta = "DELTA"
)

var requiredNodeDeltaHelperScripts = []string{
	"apply-node-delta.sh",
	"verify-node-delta.sh",
	"Apply-Delta.ps1",
}

// stringList decodes a JSON array of strings as well as a single JSON string
// (which Windows PowerShell 5.1 ConvertTo-Json can emit for 1-element lists).
type stringList []string

func (s *stringList) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		*s = nil
		return nil
	}
	if trimmed[0] == '[' {
		var items []string
		if err := json.Unmarshal(trimmed, &items); err != nil {
			return err
		}
		*s = items
		return nil
	}
	var single string
	if err := json.Unmarshal(trimmed, &single); err != nil {
		return err
	}
	if single == "" {
		*s = nil
		return nil
	}
	*s = []string{single}
	return nil
}

type nodeDeltaManifest struct {
	ManifestVersion         string             `json:"ManifestVersion"`
	DeltaType               string             `json:"DeltaType"`
	GeneratedUtc            string             `json:"GeneratedUtc"`
	BasePackage             string             `json:"BasePackage"`
	TargetPackage           string             `json:"TargetPackage"`
	Added                   stringList         `json:"Added"`
	Changed                 stringList         `json:"Changed"`
	Removed                 stringList         `json:"Removed"`
	AddedCount              int                `json:"AddedCount"`
	ChangedCount            int                `json:"ChangedCount"`
	RemovedCount            int                `json:"RemovedCount"`
	HashAlgorithm           string             `json:"HashAlgorithm"`
	DebianPackageDiff       debianPackageDiff  `json:"DebianPackageDiff"`
	DebianDeltaRelativePath string             `json:"DebianDeltaRelativePath"`
	ContainerImageDiff      containerImageDiff `json:"ContainerImageDiff"`
}

type debianPackageDiff struct {
	Processed    bool       `json:"Processed"`
	Error        *string    `json:"Error"`
	Added        stringList `json:"Added"`
	Changed      stringList `json:"Changed"`
	Removed      stringList `json:"Removed"`
	AddedCount   int        `json:"AddedCount"`
	ChangedCount int        `json:"ChangedCount"`
	RemovedCount int        `json:"RemovedCount"`
}

type imageMetadataEntry struct {
	FullName string `json:"FullName"`
	ImageId  string `json:"ImageId"`
	Size     any    `json:"Size"`
}

type containerImageDiff struct {
	AddedImages   map[string]imageMetadataEntry `json:"AddedImages"`
	ChangedImages map[string]imageMetadataEntry `json:"ChangedImages"`
	RemovedImages map[string]imageMetadataEntry `json:"RemovedImages"`
	AddedCount    int                           `json:"AddedCount"`
	ChangedCount  int                           `json:"ChangedCount"`
	RemovedCount  int                           `json:"RemovedCount"`
}

type nodePackageArchive struct {
	Path               string
	SizeBytes          int64
	Entries            map[string]int64
	OSDirs             []string
	DebsByOS           map[string][]string
	Images             []string
	HasDeltaManifest   bool
	DeltaManifest      *nodeDeltaManifest
	HasPackagesRemoved bool
	PackagesRemoved    []string
	HasImagesRemoved   bool
	ImagesRemoved      []string
}

type derivedDeltaPlan struct {
	DistKey      string
	AddedDeb     string
	ChangedDeb   string
	AddedImage   string
	ChangedImage string
}

func normalizeZipPath(name string) string {
	normalized := strings.ReplaceAll(name, "\\", "/")
	normalized = strings.TrimPrefix(normalized, "./")
	normalized = strings.TrimPrefix(normalized, "/")
	return normalized
}

func stripUTF8BOM(data []byte) []byte {
	return bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF})
}

func parseNodeDeltaManifest(raw []byte) (*nodeDeltaManifest, error) {
	cleaned := stripUTF8BOM(raw)
	var manifest nodeDeltaManifest
	if err := json.Unmarshal(cleaned, &manifest); err != nil {
		return nil, fmt.Errorf("decode delta-manifest.json: %w", err)
	}
	return &manifest, nil
}

func inspectNodePackageZip(zipPath string) (*nodePackageArchive, error) {
	stat, err := os.Stat(zipPath)
	if err != nil {
		return nil, fmt.Errorf("stat node package %s: %w", zipPath, err)
	}
	reader, err := zip.OpenReader(zipPath)
	if err != nil {
		return nil, fmt.Errorf("open node package zip %s: %w", zipPath, err)
	}
	defer reader.Close()

	info := &nodePackageArchive{
		Path:      zipPath,
		SizeBytes: stat.Size(),
		Entries:   make(map[string]int64),
		DebsByOS:  make(map[string][]string),
	}
	osSet := make(map[string]struct{})

	for _, f := range reader.File {
		norm := normalizeZipPath(f.Name)
		if norm == "" {
			continue
		}

		trimmedDir := strings.TrimSuffix(norm, "/")
		if strings.HasPrefix(trimmedDir, "packages/") {
			rest := strings.TrimPrefix(trimmedDir, "packages/")
			if rest != "" {
				osKey := strings.SplitN(rest, "/", 2)[0]
				if osKey != "" {
					osSet[osKey] = struct{}{}
				}
			}
		}

		if strings.HasSuffix(norm, "/") || f.FileInfo().IsDir() {
			continue
		}

		info.Entries[norm] = int64(f.UncompressedSize64)

		switch {
		case norm == "delta-manifest.json":
			raw, err := readZipEntryBytes(f)
			if err != nil {
				return nil, fmt.Errorf("read delta-manifest.json: %w", err)
			}
			manifest, err := parseNodeDeltaManifest(raw)
			if err != nil {
				return nil, err
			}
			info.HasDeltaManifest = true
			info.DeltaManifest = manifest

		case norm == "packages.removed":
			raw, err := readZipEntryBytes(f)
			if err != nil {
				return nil, fmt.Errorf("read packages.removed: %w", err)
			}
			info.HasPackagesRemoved = true
			info.PackagesRemoved = parseNonEmptyLines(raw)

		case norm == "images.removed":
			raw, err := readZipEntryBytes(f)
			if err != nil {
				return nil, fmt.Errorf("read images.removed: %w", err)
			}
			info.HasImagesRemoved = true
			info.ImagesRemoved = parseNonEmptyLines(raw)

		case strings.HasPrefix(norm, "packages/") && strings.HasSuffix(strings.ToLower(norm), ".deb"):
			rest := strings.TrimPrefix(norm, "packages/")
			parts := strings.SplitN(rest, "/", 2)
			if len(parts) == 2 && parts[0] != "" && parts[1] != "" {
				info.DebsByOS[parts[0]] = append(info.DebsByOS[parts[0]], parts[1])
			}

		case strings.HasPrefix(norm, "images/") && strings.HasSuffix(strings.ToLower(norm), ".tar"):
			rel := strings.TrimPrefix(norm, "images/")
			if rel != "" && !strings.Contains(rel, "/") {
				info.Images = append(info.Images, rel)
			}
		}
	}

	for osKey := range osSet {
		info.OSDirs = append(info.OSDirs, osKey)
		sort.Strings(info.DebsByOS[osKey])
	}
	sort.Strings(info.OSDirs)
	sort.Strings(info.Images)
	return info, nil
}

func readZipEntryBytes(f *zip.File) ([]byte, error) {
	rc, err := f.Open()
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(rc)
}

func parseNonEmptyLines(raw []byte) []string {
	lines := strings.Split(string(stripUTF8BOM(raw)), "\n")
	var out []string
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" {
			out = append(out, trimmed)
		}
	}
	sort.Strings(out)
	return out
}

func validateFullNodePackage(info *nodePackageArchive, expectedDistKey string) error {
	if info == nil {
		return fmt.Errorf("node package archive info is nil")
	}
	if info.SizeBytes <= 0 {
		return fmt.Errorf("node package %s is empty", info.Path)
	}
	if info.HasDeltaManifest {
		return fmt.Errorf("full node package %s unexpectedly contains delta-manifest.json", info.Path)
	}
	if !slices.Contains(info.OSDirs, expectedDistKey) {
		return fmt.Errorf("full node package %s does not contain packages/%s (available: %v)", info.Path, expectedDistKey, info.OSDirs)
	}
	debs := info.DebsByOS[expectedDistKey]
	if len(debs) == 0 {
		return fmt.Errorf("full node package %s contains no .deb files under packages/%s", info.Path, expectedDistKey)
	}
	hasK8sDeb, hasBuildahDeb := false, false
	pkgNames := make(map[string]struct{}, len(debs))
	for _, rel := range debs {
		if strings.HasPrefix(rel, "kubernetes/") {
			hasK8sDeb = true
		}
		if strings.HasPrefix(rel, "buildah/") {
			hasBuildahDeb = true
		}
		pkgNames[debFilenameToPackageName(rel)] = struct{}{}
	}
	if !hasK8sDeb {
		return fmt.Errorf("full node package %s has no .deb files under packages/%s/kubernetes", info.Path, expectedDistKey)
	}
	if !hasBuildahDeb {
		return fmt.Errorf("full node package %s has no .deb files under packages/%s/buildah", info.Path, expectedDistKey)
	}
	for _, corePkg := range []string{"kubelet", "kubeadm", "kubectl"} {
		if _, ok := pkgNames[corePkg]; !ok {
			return fmt.Errorf("full node package %s is missing required %q .deb package under packages/%s", info.Path, corePkg, expectedDistKey)
		}
	}
	if len(info.Images) == 0 {
		return fmt.Errorf("full node package %s contains no container image .tar archives under images/", info.Path)
	}
	return nil
}

func validateNodeDeltaPackage(info *nodePackageArchive, expectedDistKey string) error {
	if info == nil {
		return fmt.Errorf("node delta archive info is nil")
	}
	if !info.HasDeltaManifest || info.DeltaManifest == nil {
		return fmt.Errorf("node delta package %s is missing delta-manifest.json", info.Path)
	}
	m := info.DeltaManifest
	if m.ManifestVersion != expectedDeltaManifestVersion {
		return fmt.Errorf("ManifestVersion=%q, want %q", m.ManifestVersion, expectedDeltaManifestVersion)
	}
	if m.DeltaType != expectedNodeDeltaType {
		return fmt.Errorf("DeltaType=%q, want %q", m.DeltaType, expectedNodeDeltaType)
	}
	if m.HashAlgorithm != expectedDeltaHashAlgorithm {
		return fmt.Errorf("HashAlgorithm=%q, want %q", m.HashAlgorithm, expectedDeltaHashAlgorithm)
	}
	expectedRel := "packages/" + expectedDistKey
	if m.DebianDeltaRelativePath != expectedRel {
		return fmt.Errorf("DebianDeltaRelativePath=%q, want %q", m.DebianDeltaRelativePath, expectedRel)
	}
	if !m.DebianPackageDiff.Processed {
		return fmt.Errorf("DebianPackageDiff.Processed is false")
	}
	if m.DebianPackageDiff.Error != nil && *m.DebianPackageDiff.Error != "" {
		return fmt.Errorf("DebianPackageDiff.Error is set: %q", *m.DebianPackageDiff.Error)
	}
	if len(m.DebianPackageDiff.Added) != m.DebianPackageDiff.AddedCount ||
		len(m.DebianPackageDiff.Changed) != m.DebianPackageDiff.ChangedCount ||
		len(m.DebianPackageDiff.Removed) != m.DebianPackageDiff.RemovedCount {
		return fmt.Errorf("DebianPackageDiff counts do not match list lengths: added=%d/%d changed=%d/%d removed=%d/%d",
			len(m.DebianPackageDiff.Added), m.DebianPackageDiff.AddedCount,
			len(m.DebianPackageDiff.Changed), m.DebianPackageDiff.ChangedCount,
			len(m.DebianPackageDiff.Removed), m.DebianPackageDiff.RemovedCount)
	}
	if len(m.ContainerImageDiff.AddedImages) != m.ContainerImageDiff.AddedCount ||
		len(m.ContainerImageDiff.ChangedImages) != m.ContainerImageDiff.ChangedCount ||
		len(m.ContainerImageDiff.RemovedImages) != m.ContainerImageDiff.RemovedCount {
		return fmt.Errorf("ContainerImageDiff counts do not match map lengths: added=%d/%d changed=%d/%d removed=%d/%d",
			len(m.ContainerImageDiff.AddedImages), m.ContainerImageDiff.AddedCount,
			len(m.ContainerImageDiff.ChangedImages), m.ContainerImageDiff.ChangedCount,
			len(m.ContainerImageDiff.RemovedImages), m.ContainerImageDiff.RemovedCount)
	}
	if m.AddedCount != m.DebianPackageDiff.AddedCount+m.ContainerImageDiff.AddedCount ||
		m.ChangedCount != m.DebianPackageDiff.ChangedCount+m.ContainerImageDiff.ChangedCount ||
		m.RemovedCount != m.DebianPackageDiff.RemovedCount+m.ContainerImageDiff.RemovedCount {
		return fmt.Errorf("top-level delta counts (%d/%d/%d) do not equal deb+image counts (%d/%d/%d)",
			m.AddedCount, m.ChangedCount, m.RemovedCount,
			m.DebianPackageDiff.AddedCount+m.ContainerImageDiff.AddedCount,
			m.DebianPackageDiff.ChangedCount+m.ContainerImageDiff.ChangedCount,
			m.DebianPackageDiff.RemovedCount+m.ContainerImageDiff.RemovedCount)
	}

	for _, script := range requiredNodeDeltaHelperScripts {
		size, ok := info.Entries[script]
		if !ok || size == 0 {
			return fmt.Errorf("node delta package %s is missing non-empty helper script %q", info.Path, script)
		}
	}

	if !slices.Contains(info.OSDirs, expectedDistKey) {
		return fmt.Errorf("node delta package %s does not contain packages/%s directory", info.Path, expectedDistKey)
	}

	expectedDebs := sortedCopy(append(slices.Clone(m.DebianPackageDiff.Added), m.DebianPackageDiff.Changed...))
	actualDebs := sortedCopy(info.DebsByOS[expectedDistKey])
	if !slices.Equal(actualDebs, expectedDebs) {
		return fmt.Errorf("delta ZIP .deb entries under packages/%s = %v, want %v", expectedDistKey, actualDebs, expectedDebs)
	}

	expectedImages := sortedCopy(append(mapKeys(m.ContainerImageDiff.AddedImages), mapKeys(m.ContainerImageDiff.ChangedImages)...))
	actualImages := sortedCopy(info.Images)
	if !slices.Equal(actualImages, expectedImages) {
		return fmt.Errorf("delta ZIP .tar entries under images/ = %v, want %v", actualImages, expectedImages)
	}

	expectedTopAdded := expectedPrefixedPaths(expectedDistKey, m.DebianPackageDiff.Added, mapKeys(m.ContainerImageDiff.AddedImages))
	expectedTopChanged := expectedPrefixedPaths(expectedDistKey, m.DebianPackageDiff.Changed, mapKeys(m.ContainerImageDiff.ChangedImages))
	expectedTopRemoved := expectedPrefixedPaths(expectedDistKey, m.DebianPackageDiff.Removed, mapKeys(m.ContainerImageDiff.RemovedImages))
	if !slices.Equal(sortedCopy(m.Added), expectedTopAdded) {
		return fmt.Errorf("manifest top-level Added = %v, want %v", m.Added, expectedTopAdded)
	}
	if !slices.Equal(sortedCopy(m.Changed), expectedTopChanged) {
		return fmt.Errorf("manifest top-level Changed = %v, want %v", m.Changed, expectedTopChanged)
	}
	if !slices.Equal(sortedCopy(m.Removed), expectedTopRemoved) {
		return fmt.Errorf("manifest top-level Removed = %v, want %v", m.Removed, expectedTopRemoved)
	}

	if m.DebianPackageDiff.RemovedCount > 0 {
		if !info.HasPackagesRemoved {
			return fmt.Errorf("manifest reports %d removed .deb(s) but packages.removed is missing", m.DebianPackageDiff.RemovedCount)
		}
		if !slices.Equal(info.PackagesRemoved, sortedCopy(m.DebianPackageDiff.Removed)) {
			return fmt.Errorf("packages.removed = %v, want %v", info.PackagesRemoved, sortedCopy(m.DebianPackageDiff.Removed))
		}
	} else if info.HasPackagesRemoved {
		return fmt.Errorf("packages.removed should not exist when DebianPackageDiff.RemovedCount == 0")
	}

	if m.ContainerImageDiff.RemovedCount > 0 {
		if !info.HasImagesRemoved {
			return fmt.Errorf("manifest reports %d removed image(s) but images.removed is missing", m.ContainerImageDiff.RemovedCount)
		}
		if !slices.Equal(info.ImagesRemoved, sortedCopy(mapKeys(m.ContainerImageDiff.RemovedImages))) {
			return fmt.Errorf("images.removed = %v, want %v", info.ImagesRemoved, sortedCopy(mapKeys(m.ContainerImageDiff.RemovedImages)))
		}
	} else if info.HasImagesRemoved {
		return fmt.Errorf("images.removed should not exist when ContainerImageDiff.RemovedCount == 0")
	}

	return nil
}

// deriveBaseNodePackage creates a realistic base node package ZIP derived from
// fullZipPath by keeping most entries byte-identical while omitting one .deb and
// one .tar (so they become Added in base -> full) and mutating one other .deb
// and one other .tar in the base copy (so they become Changed in base -> full,
// causing the delta generator to pack the genuine target files from fullZipPath).
func deriveBaseNodePackage(fullZipPath, distKey, baseZipPath string) (*derivedDeltaPlan, error) {
	reader, err := zip.OpenReader(fullZipPath)
	if err != nil {
		return nil, fmt.Errorf("open full node package %s: %w", fullZipPath, err)
	}
	defer reader.Close()

	type sizedEntry struct {
		rel  string
		size uint64
	}
	var debs []sizedEntry
	var images []sizedEntry
	debPrefix := "packages/" + distKey + "/"
	for _, f := range reader.File {
		norm := normalizeZipPath(f.Name)
		if norm == "" || strings.HasSuffix(norm, "/") || f.FileInfo().IsDir() {
			continue
		}
		switch {
		case strings.HasPrefix(norm, debPrefix) && strings.HasSuffix(strings.ToLower(norm), ".deb"):
			debs = append(debs, sizedEntry{rel: strings.TrimPrefix(norm, debPrefix), size: f.UncompressedSize64})
		case strings.HasPrefix(norm, "images/") && strings.HasSuffix(strings.ToLower(norm), ".tar"):
			rel := strings.TrimPrefix(norm, "images/")
			if rel != "" && !strings.Contains(rel, "/") {
				images = append(images, sizedEntry{rel: rel, size: f.UncompressedSize64})
			}
		}
	}
	if len(debs) == 0 {
		return nil, fmt.Errorf("no .deb packages found under %s in %s", debPrefix, fullZipPath)
	}

	// Prefer core Kubernetes .deb packages (kubectl, kubeadm) when available so
	// delta upgrades reinstall well-known standalone packages, falling back to
	// smallest .deb files so transfers and dpkg runs stay fast.
	sort.Slice(debs, func(i, j int) bool {
		pi := derivedDebPriority(debs[i].rel)
		pj := derivedDebPriority(debs[j].rel)
		if pi != pj {
			return pi < pj
		}
		if debs[i].size != debs[j].size {
			return debs[i].size < debs[j].size
		}
		return debs[i].rel < debs[j].rel
	})
	sort.Slice(images, func(i, j int) bool {
		if images[i].size != images[j].size {
			return images[i].size < images[j].size
		}
		return images[i].rel < images[j].rel
	})

	plan := &derivedDeltaPlan{
		DistKey:  distKey,
		AddedDeb: debs[0].rel,
	}
	if len(debs) >= 2 {
		plan.ChangedDeb = debs[1].rel
	}
	if len(images) >= 1 {
		plan.AddedImage = images[0].rel
	}
	if len(images) >= 2 {
		plan.ChangedImage = images[1].rel
	}

	if err := os.MkdirAll(filepath.Dir(baseZipPath), 0o755); err != nil {
		return nil, fmt.Errorf("create base zip parent directory: %w", err)
	}
	outFile, err := os.Create(baseZipPath)
	if err != nil {
		return nil, fmt.Errorf("create derived base zip %s: %w", baseZipPath, err)
	}
	zw := zip.NewWriter(outFile)

	addedDebPath := debPrefix + plan.AddedDeb
	changedDebPath := ""
	if plan.ChangedDeb != "" {
		changedDebPath = debPrefix + plan.ChangedDeb
	}
	addedImagePath := ""
	if plan.AddedImage != "" {
		addedImagePath = "images/" + plan.AddedImage
	}
	changedImagePath := ""
	if plan.ChangedImage != "" {
		changedImagePath = "images/" + plan.ChangedImage
	}

	writeErr := func() error {
		for _, f := range reader.File {
			norm := normalizeZipPath(f.Name)
			if norm == "" || strings.HasSuffix(norm, "/") || f.FileInfo().IsDir() {
				continue
			}
			if norm == addedDebPath || (addedImagePath != "" && norm == addedImagePath) {
				continue
			}

			w, err := zw.Create(norm)
			if err != nil {
				return fmt.Errorf("create zip entry %s: %w", norm, err)
			}
			if (changedDebPath != "" && norm == changedDebPath) || (changedImagePath != "" && norm == changedImagePath) {
				if _, err := fmt.Fprintf(w, "k2s-node-upgrade-e2e-synthetic-base-content:%s\n", norm); err != nil {
					return fmt.Errorf("write mutated base entry %s: %w", norm, err)
				}
				continue
			}

			rc, err := f.Open()
			if err != nil {
				return fmt.Errorf("open source zip entry %s: %w", norm, err)
			}
			_, copyErr := io.Copy(w, rc)
			closeErr := rc.Close()
			if copyErr != nil {
				return fmt.Errorf("copy zip entry %s: %w", norm, copyErr)
			}
			if closeErr != nil {
				return fmt.Errorf("close source zip entry %s: %w", norm, closeErr)
			}
		}
		return nil
	}()
	closeZipErr := zw.Close()
	closeFileErr := outFile.Close()
	if writeErr != nil {
		_ = os.Remove(baseZipPath)
		return nil, writeErr
	}
	if closeZipErr != nil {
		_ = os.Remove(baseZipPath)
		return nil, fmt.Errorf("finalize derived base zip %s: %w", baseZipPath, closeZipErr)
	}
	if closeFileErr != nil {
		_ = os.Remove(baseZipPath)
		return nil, fmt.Errorf("close derived base zip %s: %w", baseZipPath, closeFileErr)
	}
	return plan, nil
}

func writeZipFixture(zipPath string, files map[string][]byte) error {
	if err := os.MkdirAll(filepath.Dir(zipPath), 0o755); err != nil {
		return err
	}
	outFile, err := os.Create(zipPath)
	if err != nil {
		return err
	}
	zw := zip.NewWriter(outFile)

	keys := make([]string, 0, len(files))
	for k := range files {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	for _, name := range keys {
		norm := normalizeZipPath(name)
		w, err := zw.Create(norm)
		if err != nil {
			_ = zw.Close()
			_ = outFile.Close()
			return err
		}
		if _, err := w.Write(files[name]); err != nil {
			_ = zw.Close()
			_ = outFile.Close()
			return err
		}
	}
	if err := zw.Close(); err != nil {
		_ = outFile.Close()
		return err
	}
	return outFile.Close()
}

// debFilenameToPackageName extracts the Debian package name from a .deb path,
// matching Upgrade-K2sNode.ps1 and verify-node-delta.sh (<name>_<version>_<arch>.deb -> <name>).
func debFilenameToPackageName(debPath string) string {
	leaf := path.Base(normalizeZipPath(debPath))
	stem := strings.TrimSuffix(leaf, path.Ext(leaf))
	if idx := strings.IndexByte(stem, '_'); idx > 0 {
		return stem[:idx]
	}
	return stem
}

// parseDistroKey normalizes lsb_release -i and -r output to the K2s distribution
// folder key (for example "Debian" + "13" -> "debian13"), matching Get-InstalledDistribution.
func parseDistroKey(lsbID, lsbRelease string) (string, error) {
	id := strings.ToLower(strings.TrimSpace(lsbID))
	release := strings.ToLower(strings.TrimSpace(lsbRelease))
	if id == "" {
		return "", fmt.Errorf("empty distribution ID from lsb_release")
	}
	if release == "" {
		return "", fmt.Errorf("empty distribution release from lsb_release")
	}
	return id + release, nil
}

func validateUpgradeLogOrdering(output, expectedMode string) error {
	var modeMarker string
	switch expectedMode {
	case upgradeModeFull:
		modeMarker = "Upgrade mode: FULL (no delta-manifest.json found)"
	case upgradeModeDelta:
		modeMarker = "Upgrade mode: DELTA (node package delta detected)"
	default:
		return fmt.Errorf("unsupported expected upgrade mode %q", expectedMode)
	}

	markers := []string{
		"=== Phase 1: Validating inputs ===",
		"=== Phase 2: Locating node and determining OS ===",
		"=== Phase 3: Extracting node package ===",
		modeMarker,
		"=== Phase 4: Detecting OS distribution",
		"=== Phase 5: Cordoning and draining node",
		"=== Phase 6: Applying upgrade for OS family 'debian' ===",
		"=== Phase 7: Uncordoning node",
		"=== Phase 8: Waiting for node",
		"upgraded successfully.",
	}

	offset := 0
	for _, marker := range markers {
		idx := strings.Index(output[offset:], marker)
		if idx < 0 {
			return fmt.Errorf("expected upgrade log marker %q after offset %d; output:\n%s", marker, offset, output)
		}
		offset += idx + len(marker)
	}
	return nil
}

func expectedPrefixedPaths(distKey string, debs []string, images []string) []string {
	var out []string
	for _, d := range debs {
		out = append(out, "packages/"+distKey+"/"+d)
	}
	for _, img := range images {
		out = append(out, "images/"+img)
	}
	sort.Strings(out)
	return out
}

func sortedCopy(items []string) []string {
	if len(items) == 0 {
		return nil
	}
	cloned := slices.Clone(items)
	sort.Strings(cloned)
	return cloned
}

func mapKeys[V any](m map[string]V) []string {
	if len(m) == 0 {
		return nil
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func derivedDebPriority(relPath string) int {
	switch debFilenameToPackageName(relPath) {
	case "kubectl":
		return 0
	case "kubeadm":
		return 1
	case "kubelet":
		return 2
	default:
		return 3
	}
}
