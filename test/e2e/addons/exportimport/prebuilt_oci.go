// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package exportimport

import (
	"fmt"
	"io"
	"os"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// PrebuiltAddonOciFileEnv names the environment variable that points to an addon OCI artifact that was already built
// (e.g. the addon package of a release that is shipped next to the product package).
//
// When set, ExportAddon and ExportAddonRelativePath do not export anything (an export needs internet access and a
// configured proxy); they copy that file into the requested output directory instead. The export-import suites then
// test the import of exactly the shipped artifact, which allows to run them on an air-gapped system.
const PrebuiltAddonOciFileEnv = "SYSTEM_TEST_ADDON_OCI_FILE"

// usePrebuiltAddonOci copies the pre-built addon OCI artifact into outputDir. It returns the path of the copy.
// The copy keeps the original file name, so cleanup helpers can delete it without touching the original.
func usePrebuiltAddonOci(outputDir string) (string, bool) {
	source := os.Getenv(PrebuiltAddonOciFileEnv)
	if source == "" {
		return "", false
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
