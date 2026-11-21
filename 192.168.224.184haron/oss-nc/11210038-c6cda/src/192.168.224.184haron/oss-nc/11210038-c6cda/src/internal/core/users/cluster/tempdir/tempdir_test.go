// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package tempdir_test

import (
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/core/users/cluster/tempdir"
	k_os "github.com/k2s-project/k2s/internal/os"
)

func TestPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "tempdir pkg Unit Tests", Label("integration", "ci", "tempdir"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("tempdir", func() {
	Describe("CreateTempDir", func() {
		It("creates a temporary directory", func() {
			var actual string
			var err error

			DeferCleanup(func() {
				err := os.RemoveAll(actual)
				Expect(err).ToNot(HaveOccurred())
				GinkgoWriter.Println("deleted", actual)
			})

			actual, err = tempdir.CreateTempDir()

			Expect(err).ToNot(HaveOccurred())
			Expect(actual).To(BeADirectory())
			Expect(filepath.Base(actual)).To(HavePrefix("k2s-"))

			GinkgoWriter.Println("created", actual)
		})
	})

	Describe("RemoveTempDir", func() {
		var dir string
		var err error

		BeforeEach(func() {
			dir, err = os.MkdirTemp("", "k2s-test-*")
			Expect(err).ToNot(HaveOccurred())
			Expect(k_os.PathExists(dir)).To(BeTrue())
			GinkgoWriter.Println("created", dir)

			DeferCleanup(func() {
				err := os.RemoveAll(dir)
				Expect(err).ToNot(HaveOccurred())
			})
		})

		It("removes a directory", func() {
			err := tempdir.RemoveTempDir(dir)

			Expect(err).ToNot(HaveOccurred())
			Expect(k_os.PathExists(dir)).To(BeFalse())

			GinkgoWriter.Println("removed", dir)
		})
	})
})
