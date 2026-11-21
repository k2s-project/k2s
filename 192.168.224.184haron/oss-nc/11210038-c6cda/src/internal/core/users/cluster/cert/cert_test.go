// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package cert_test

import (
	"log/slog"
	"path/filepath"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/core/users/cluster/cert"
)

func TestPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "cert pkg Unit Tests", Label("unit", "ci", "cert"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("cert", func() {
	Describe("CreateRemoteCertCmd", func() {
		It("derives the key and cert file names from the user name", func() {
			actual := cert.CreateRemoteCertCmd("my-user")

			Expect(actual.KeyFileName).To(Equal("my-user.key"))
			Expect(actual.CertFileName).To(Equal("my-user.crt"))
		})

		It("places the temp dir under /tmp", func() {
			actual := cert.CreateRemoteCertCmd("my-user")

			Expect(actual.TempDir).To(HavePrefix("/tmp/"))
		})

		It("generates a different temp dir on each call", func() {
			first := cert.CreateRemoteCertCmd("my-user")
			second := cert.CreateRemoteCertCmd("my-user")

			Expect(first.TempDir).NotTo(Equal(second.TempDir))
		})

		It("builds a command that produces the key and cert files and cleans up the signing request", func() {
			actual := cert.CreateRemoteCertCmd("my-user")

			Expect(actual.Cmd).To(ContainSubstring(actual.TempDir + "/my-user.key"))
			Expect(actual.Cmd).To(ContainSubstring(actual.TempDir + "/my-user.crt"))
			Expect(actual.Cmd).To(ContainSubstring("rm -f " + actual.TempDir + "/my-user.csr"))
		})
	})

	Describe("DetermineLocalCertPaths", func() {
		It("joins the local dir, temp dir name and file names", func() {
			remoteCmd := cert.RemoteCertCmd{
				TempDir:      "/tmp/remote-123",
				KeyFileName:  "my-user.key",
				CertFileName: "my-user.crt",
			}

			certPath, keyPath := cert.DetermineLocalCertPaths("/local/dir", remoteCmd)

			Expect(certPath).To(Equal(filepath.Join("/local/dir", "remote-123", "my-user.crt")))
			Expect(keyPath).To(Equal(filepath.Join("/local/dir", "remote-123", "my-user.key")))
		})

		It("uses only the last segment of the remote temp dir", func() {
			remoteCmd := cert.RemoteCertCmd{
				TempDir:      "/tmp/nested/remote-123",
				KeyFileName:  "my-user.key",
				CertFileName: "my-user.crt",
			}

			certPath, keyPath := cert.DetermineLocalCertPaths("/local/dir", remoteCmd)

			Expect(certPath).To(Equal(filepath.Join("/local/dir", "remote-123", "my-user.crt")))
			Expect(keyPath).To(Equal(filepath.Join("/local/dir", "remote-123", "my-user.key")))
		})
	})
})
