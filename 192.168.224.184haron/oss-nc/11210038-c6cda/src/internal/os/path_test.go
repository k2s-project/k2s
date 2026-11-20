// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package os_test

import (
	bos "os"
	"path/filepath"
	"runtime"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/os"
)

var _ = Describe("FindOtherExecutablesInPath", func() {
	var exeName string

	// setPath sets the PATH env var for the duration of the current spec.
	setPath := func(dirs ...string) {
		originalPath := bos.Getenv("PATH")
		DeferCleanup(func() {
			Expect(bos.Setenv("PATH", originalPath)).To(Succeed())
		})
		Expect(bos.Setenv("PATH", strings.Join(dirs, string(bos.PathListSeparator)))).To(Succeed())
	}

	createExe := func(dir string) string {
		exePath := filepath.Join(dir, exeName)
		Expect(bos.WriteFile(exePath, []byte("fake"), bos.ModePerm)).To(Succeed())
		return exePath
	}

	BeforeEach(func() {
		exeName = os.ExecutableFileName("k2s")
	})

	When("the only executable in PATH is the current one", func() {
		It("returns nothing", func() {
			dir := GinkgoT().TempDir()
			currentExe := createExe(dir)
			setPath(dir)

			actual, err := os.FindOtherExecutablesInPath(currentExe, exeName)

			Expect(err).ToNot(HaveOccurred())
			Expect(actual).To(BeEmpty())
		})
	})

	When("another executable is in PATH", func() {
		It("returns it", func() {
			otherDir := GinkgoT().TempDir()
			otherExe := createExe(otherDir)
			setPath(otherDir)

			currentExe := filepath.Join(GinkgoT().TempDir(), exeName)

			actual, err := os.FindOtherExecutablesInPath(currentExe, exeName)

			Expect(err).ToNot(HaveOccurred())
			Expect(actual).To(ConsistOf(otherExe))
		})
	})

	// Windows paths are case-insensitive, paths on other platforms are not.
	When("the current executable differs only in casing", func() {
		It("honors the platform's path case-sensitivity", func() {
			dir := GinkgoT().TempDir()
			exePath := createExe(dir)
			setPath(dir)

			currentExe := strings.ToUpper(exePath)

			actual, err := os.FindOtherExecutablesInPath(currentExe, exeName)

			Expect(err).ToNot(HaveOccurred())
			if runtime.GOOS == "windows" {
				Expect(actual).To(BeEmpty(), "on Windows the differently-cased path is the same file")
			} else {
				Expect(actual).To(ConsistOf(exePath), "on Linux the differently-cased path is a different file")
			}
		})
	})
})

