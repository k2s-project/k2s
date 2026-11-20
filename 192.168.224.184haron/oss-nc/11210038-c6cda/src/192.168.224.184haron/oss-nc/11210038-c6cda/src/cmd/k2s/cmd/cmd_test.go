// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package cmd

import (
	"errors"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
)

func TestCmd(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "cmd Unit Tests", Label("unit", "ci"))
}

var _ = Describe("resolveInstallDirFromPath", func() {
	const exeDir = `C:\ws\K2s\delta`

	var originalErr error

	// stubResolveInstalledK2s replaces the PATH-based discovery for the current spec.
	stubResolveInstalledK2s := func(installed *config.InstalledK2s, err error) {
		original := resolveInstalledK2s
		DeferCleanup(func() { resolveInstalledK2s = original })

		resolveInstalledK2s = func() (*config.InstalledK2s, error) {
			return installed, err
		}
	}

	BeforeEach(func() {
		originalErr = errors.New("setup.json not found")
	})

	// A corrupted installation is still an existing installation: its install dir must
	// be used instead of falling back to the executable's directory.
	When("an installation is discovered together with the corrupted-state error", func() {
		It("returns the discovered install dir", func() {
			stubResolveInstalledK2s(&config.InstalledK2s{InstallDir: `D:\ws\K2s\1.6.0`}, cconfig.ErrSystemInCorruptedState)

			actual, err := resolveInstallDirFromPath(exeDir, originalErr)

			Expect(err).ToNot(HaveOccurred())
			Expect(actual).To(Equal(`D:\ws\K2s\1.6.0`))
		})
	})

	When("an installation is discovered without any error", func() {
		It("returns the discovered install dir", func() {
			stubResolveInstalledK2s(&config.InstalledK2s{InstallDir: `D:\ws\K2s\1.6.0`}, nil)

			actual, err := resolveInstallDirFromPath(exeDir, originalErr)

			Expect(err).ToNot(HaveOccurred())
			Expect(actual).To(Equal(`D:\ws\K2s\1.6.0`))
		})
	})

	When("no installation was found", func() {
		It("returns the exe dir and the original error", func() {
			stubResolveInstalledK2s(nil, cconfig.ErrSystemNotInstalled)

			actual, err := resolveInstallDirFromPath(exeDir, originalErr)

			Expect(err).To(MatchError(originalErr))
			Expect(actual).To(Equal(exeDir))
		})
	})

	When("discovery fails with the corrupted-state error but without an installation", func() {
		It("returns the exe dir and the original error", func() {
			stubResolveInstalledK2s(nil, cconfig.ErrSystemInCorruptedState)

			actual, err := resolveInstallDirFromPath(exeDir, originalErr)

			Expect(err).To(MatchError(originalErr))
			Expect(actual).To(Equal(exeDir))
		})
	})
})

var _ = Describe("formatLinuxCLIInvocation", func() {
	It("uses POSIX-safe quoting for Linux command arguments", func() {
		args := []string{"/opt/k2s/k2s", "install", "--windows-qcow2-path", "/tmp/Windows 11's.qcow2", "--proxy", "http://proxy:81"}

		actual := formatLinuxCLIInvocation(args)

		Expect(actual).To(Equal("/opt/k2s/k2s install --windows-qcow2-path '/tmp/Windows 11'\"'\"'s.qcow2' --proxy http://proxy:81"))
	})
})

