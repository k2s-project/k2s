// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package knownhosts_test

import (
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/contracts/users"
	"github.com/k2s-project/k2s/internal/core/users/controlplane/knownhosts"
)

func TestPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "knownhosts pkg Integration Tests", Label("integration", "ci", "knownhosts"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("KnownHostsCopier", func() {
	Describe("CopyHostEntries", Ordered, func() {
		When("error while reading known hosts file", func() {
			var tempDir string

			BeforeAll(func() {
				tempDir = GinkgoT().TempDir()
			})

			It("returns error", func() {
				const host = "my-host"
				config := config.NewSshConfig(tempDir, "", "")
				user := users.NewOSUser("", "", "")

				sut := knownhosts.NewKnownHostsCopier(config)

				err := sut.CopyHostEntries(host, user)

				Expect(err).To(MatchError(SatisfyAll(
					ContainSubstring("failed to find host entries"),
					ContainSubstring("failed to read known_hosts file"),
				)))
			})
		})

		When("no host entries found", func() {
			var tempDir string

			BeforeAll(func() {
				tempDir = GinkgoT().TempDir()
				tempFile := filepath.Join(tempDir, "known_hosts")

				Expect(os.WriteFile(tempFile, []byte(""), fs.ModePerm)).To(Succeed())
			})

			It("returns error", func() {
				const host = "my-host"
				config := config.NewSshConfig(tempDir, "", "")
				user := users.NewOSUser("", "", "")

				sut := knownhosts.NewKnownHostsCopier(config)

				err := sut.CopyHostEntries(host, user)

				Expect(err).To(MatchError(ContainSubstring("no host entries found")))
			})
		})

		When("target knownhosts file exists", func() {
			var sourceSshDir string
			var targetHomeDir string
			var targetFile string

			BeforeAll(func() {
				sourceEntries := []string{
					"any-host ssh-ras <fingerprint>",
					"my-host ssh-rsa <newer-fingerprint-1>",
					"another-any-host ssh-rsa <fingerprint>",
					"my-host ssh-ecdsa <newer-fingerprint-2>\n",
				}
				targetEntries := []string{
					"some-host ssh-ras <fingerprint>",
					"my-host ssh-rsa <older-fingerprint-1>",
					"my-host ssh-ecdsa <older-fingerprint-2>",
					"another-host ssh-rsa <fingerprint>\n",
				}
				tempDir := GinkgoT().TempDir()

				sourceSshDir = filepath.Join(tempDir, "ssh-dir")
				targetHomeDir = filepath.Join(tempDir, "user-home-dir")
				targetSshDir := filepath.Join(targetHomeDir, "ssh-dir")

				Expect(os.MkdirAll(sourceSshDir, fs.ModePerm)).To(Succeed())
				Expect(os.MkdirAll(targetSshDir, fs.ModePerm)).To(Succeed())

				sourceFile := filepath.Join(sourceSshDir, "known_hosts")
				targetFile = filepath.Join(targetSshDir, "known_hosts")

				Expect(os.WriteFile(sourceFile, []byte(strings.Join(sourceEntries, "\n")), fs.ModePerm)).To(Succeed())
				Expect(os.WriteFile(targetFile, []byte(strings.Join(targetEntries, "\n")), fs.ModePerm)).To(Succeed())
			})

			It("updates host entries in existing file", func() {
				const host = "my-host"
				config := config.NewSshConfig(sourceSshDir, "~/ssh-dir", "")
				user := users.NewOSUser("", "", targetHomeDir)

				sut := knownhosts.NewKnownHostsCopier(config)

				err := sut.CopyHostEntries(host, user)

				Expect(err).NotTo(HaveOccurred())

				actual, err := os.ReadFile(targetFile)

				Expect(err).NotTo(HaveOccurred())

				entries := strings.Split(string(actual), "\n")

				Expect(entries).To(ConsistOf(
					"some-host ssh-ras <fingerprint>",
					"another-host ssh-rsa <fingerprint>",
					"my-host ssh-rsa <newer-fingerprint-1>",
					"my-host ssh-ecdsa <newer-fingerprint-2>",
					"",
				))
			})
		})

		When("target knownhosts file not existing", func() {
			var sourceSshDir string
			var targetHomeDir string
			var targetFile string

			BeforeAll(func() {
				sourceEntries := []string{
					"some-host ssh-ras <fingerprint>",
					"my-host ssh-rsa <newer-fingerprint-1>",
					"another-host ssh-rsa <fingerprint>",
					"my-host ssh-ecdsa <newer-fingerprint-2>\n",
				}
				tempDir := GinkgoT().TempDir()

				sourceSshDir = filepath.Join(tempDir, "ssh-dir")
				targetHomeDir = filepath.Join(tempDir, "user-home-dir")

				Expect(os.MkdirAll(sourceSshDir, fs.ModePerm)).To(Succeed())
				Expect(os.MkdirAll(targetHomeDir, fs.ModePerm)).To(Succeed())

				sourceFile := filepath.Join(sourceSshDir, "known_hosts")
				targetFile = filepath.Join(targetHomeDir, "ssh-dir", "known_hosts")

				Expect(os.WriteFile(sourceFile, []byte(strings.Join(sourceEntries, "\n")), fs.ModePerm)).To(Succeed())
			})

			It("creates target knownhosts file", func() {
				const host = "my-host"
				config := config.NewSshConfig(sourceSshDir, "~/ssh-dir", "")
				user := users.NewOSUser("", "", targetHomeDir)

				sut := knownhosts.NewKnownHostsCopier(config)

				err := sut.CopyHostEntries(host, user)

				Expect(err).NotTo(HaveOccurred())

				actual, err := os.ReadFile(targetFile)

				Expect(err).NotTo(HaveOccurred())

				entries := strings.Split(string(actual), "\n")

				Expect(entries).To(ConsistOf(
					"my-host ssh-rsa <newer-fingerprint-1>",
					"my-host ssh-ecdsa <newer-fingerprint-2>",
					"",
				))
			})
		})
	})
})
