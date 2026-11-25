// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package exportimport

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// PrebuiltAddonOciFileEnv names the environment variable that points to an addon OCI artifact that was already built
// (e.g. the addon package of a release that is shipped next to the product package).
//
// When set, ExportAddon and ExportAddonRelativePath do not export anything (an export needs internet access and a
// configured proxy); they copy that file into the requested output directory instead. The export-import suites then
// test the import of exactly the shipped artifact, which allows to run them on an air-gapped system.
//
// The file is only used for the addon it belongs to (K2s-<version>-addons-<addon>[-<implementation>].oci.tar).
// A suite that also needs another addon (e.g. ingress nginx, which security enables) uses that addon's own, separate
// package if it lies next to the configured file (the offline-package workflows place it there); otherwise the suite
// exports it itself, before it sets up the air-gapped environment.
const PrebuiltAddonOciFileEnv = "SYSTEM_TEST_ADDON_OCI_FILE"

// prebuiltAddonOciStem returns the addon part of the package file name, as produced by 'k2s addons export'.
func prebuiltAddonOciStem(addonName, implName string) string {
	if implName == "" || implName == addonName {
		return strings.ReplaceAll(addonName, " ", "-")
	}
	return strings.ReplaceAll(addonName+"-"+implName, " ", "-")
}

// usePrebuiltAddonOci copies the pre-built package of the requested addon into outputDir and returns the path of the
// copy: the configured file if it belongs to the addon, otherwise the addon's package next to it. Without such a
// package it returns false, so the caller exports the addon.
// The copy keeps the original file name, so cleanup helpers can delete it without touching the original.
func usePrebuiltAddonOci(addonName, implName, outputDir string) (string, bool) {
	source := os.Getenv(PrebuiltAddonOciFileEnv)
	if source == "" {
		return "", false
	}
	stem := prebuiltAddonOciStem(addonName, implName)
	if !strings.HasSuffix(filepath.Base(source), "-addons-"+stem+".oci.tar") {
		pattern := filepath.Join(filepath.Dir(source), "K2s-*-addons-"+stem+".oci.tar")
		matches, err := filepath.Glob(pattern)
		Expect(err).ToNot(HaveOccurred(), "invalid pre-built addon OCI pattern '%s'", pattern)
		Expect(len(matches)).To(BeNumerically("<=", 1), "ambiguous pre-built packages for '%s': %v", stem, matches)
		if len(matches) == 0 {
			GinkgoWriter.Printf("[Prebuilt] No pre-built package for '%s' next to %s, exporting it instead\n", stem, source)
			return "", false
		}
		source = matches[0]
	}

	GinkgoWriter.Println("=== USE PRE-BUILT ADDON OCI (no export) START ===")
	GinkgoWriter.Printf("[Prebuilt] %s=%s\n", PrebuiltAddonOciFileEnv, source)

	sourceInfo, err := os.Stat(source)
	Expect(err).ToNot(HaveOccurred(), "pre-built addon OCI file '%s' must exist", source)
	Expect(sourceInfo.Mode().IsRegular()).To(BeTrue(), "pre-built addon OCI '%s' must be a file", source)
	Expect(sourceInfo.Size()).To(BeNumerically(">", 0), "pre-built addon OCI '%s' must not be empty", source)

	Expect(os.MkdirAll(outputDir, 0o755)).To(Succeed(), "should create output directory '%s'", outputDir)
	target := filepath.Join(outputDir, filepath.Base(source))
	sourceAbs, err := filepath.Abs(source)
	Expect(err).ToNot(HaveOccurred())
	targetAbs, err := filepath.Abs(target)
	Expect(err).ToNot(HaveOccurred())
	if filepath.Clean(sourceAbs) == filepath.Clean(targetAbs) {
		Fail(fmt.Sprintf("pre-built addon OCI source and destination must differ: %s", source))
	}
	if targetInfo, statErr := os.Stat(target); statErr == nil {
		Expect(os.SameFile(sourceInfo, targetInfo)).To(BeFalse(), "pre-built addon OCI source and destination must not be the same file")
	}

	in, err := os.Open(source)
	Expect(err).ToNot(HaveOccurred())
	defer in.Close()

	out, err := os.Create(target)
	Expect(err).ToNot(HaveOccurred(), "should create '%s'", target)
	_, copyErr := io.Copy(out, in)
	closeErr := out.Close()
	Expect(copyErr).ToNot(HaveOccurred(), fmt.Sprintf("should copy '%s' to '%s'", source, target))
	Expect(closeErr).ToNot(HaveOccurred())

	GinkgoWriter.Printf("[Prebuilt] Copied %d bytes to %s\n", sourceInfo.Size(), target)
	GinkgoWriter.Println("=== USE PRE-BUILT ADDON OCI (no export) END ===")
	return target, true
}
