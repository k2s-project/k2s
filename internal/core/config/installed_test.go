// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package config

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	contracts "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/definitions"
	kos "github.com/k2s-project/k2s/internal/os"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("ResolveInstalledK2s", func() {
	// T1 + T2: the installed K2s uses a custom 'configDir.k2s' while the running
	// package would use a different one -> primary #2886 regression scenario.
	When("a single valid installation with custom config dir is in PATH", func() {
		It("resolves it", func() {
			installDir, k2sConfigDir := newInstallation(false)
			setPath(installDir)

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(err).ToNot(HaveOccurred())
			Expect(actual.InstallDir).To(Equal(installDir))
			Expect(actual.Config.Host().K2sSetupConfigDir()).To(Equal(k2sConfigDir))
			Expect(actual.RuntimeConfig).ToNot(BeNil())
			Expect(actual.RuntimeConfig.InstallConfig().SetupName()).To(Equal(definitions.SetupNameK2s))
		})
	})

	// T3
	When("the only PATH candidate is the currently running executable", func() {
		It("excludes it and reports the system as not installed", func() {
			installDir, _ := newInstallation(false)
			setPath(installDir)

			currentExe := filepath.Join(installDir, kos.ExecutableFileName("k2s"))

			actual, err := resolveInstalledK2s(currentExe)

			Expect(actual).To(BeNil())
			Expect(err).To(MatchError(contracts.ErrSystemNotInstalled))
		})
	})

	// T4
	When("no K2s executable is in PATH", func() {
		It("reports the system as not installed", func() {
			setPath(GinkgoT().TempDir())

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(actual).To(BeNil())
			Expect(err).To(MatchError(contracts.ErrSystemNotInstalled))
		})
	})

	// T5
	When("candidate has a K2s executable but no config file", func() {
		It("skips the candidate", func() {
			installDir := GinkgoT().TempDir()
			createK2sExe(installDir)
			setPath(installDir)

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(actual).To(BeNil())
			Expect(err).To(MatchError(contracts.ErrSystemNotInstalled))
		})
	})

	// T6
	When("candidate config file contains an empty 'configDir.k2s'", func() {
		It("skips the candidate", func() {
			installDir := GinkgoT().TempDir()
			createK2sExe(installDir)
			createK2sConfig(installDir, "")
			setPath(installDir)

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(actual).To(BeNil())
			Expect(err).To(MatchError(contracts.ErrSystemNotInstalled))
		})
	})

	// T7
	When("candidate setup config file is missing", func() {
		It("skips the candidate", func() {
			installDir := GinkgoT().TempDir()
			createK2sExe(installDir)
			createK2sConfig(installDir, GinkgoT().TempDir())
			setPath(installDir)

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(actual).To(BeNil())
			Expect(err).To(MatchError(contracts.ErrSystemNotInstalled))
		})
	})

	// T8
	When("multiple valid installations are in PATH", func() {
		It("returns an explicit error", func() {
			firstInstallDir, _ := newInstallation(false)
			secondInstallDir, _ := newInstallation(false)
			setPath(firstInstallDir, secondInstallDir)

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(actual).To(BeNil())
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("multiple installed K2s"))
			Expect(err.Error()).To(ContainSubstring("PATH"))
		})
	})

	// T9
	When("'InstallFolder' does not match the discovered install dir", func() {
		It("still resolves the candidate", func() {
			skipIfSetupConfigDirIsFixed()

			installDir := GinkgoT().TempDir()
			k2sConfigDir := GinkgoT().TempDir()

			createK2sExe(installDir)
			createK2sConfig(installDir, k2sConfigDir)
			createSetupConfig(k2sConfigDir, filepath.Join("some", "stale", "location"), false)

			setPath(installDir)

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(err).ToNot(HaveOccurred())
			Expect(actual.InstallDir).To(Equal(installDir))
		})
	})

	When("'InstallFolder' is empty", func() {
		It("still resolves the candidate", func() {
			skipIfSetupConfigDirIsFixed()

			installDir := GinkgoT().TempDir()
			k2sConfigDir := GinkgoT().TempDir()

			createK2sExe(installDir)
			createK2sConfig(installDir, k2sConfigDir)
			createSetupConfig(k2sConfigDir, "", false)

			setPath(installDir)

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(err).ToNot(HaveOccurred())
			Expect(actual.InstallDir).To(Equal(installDir))
		})
	})

	// T10
	When("the installed system is marked as corrupted", func() {
		It("preserves the corrupted-state error and returns the installation", func() {
			installDir, k2sConfigDir := newInstallation(true)
			setPath(installDir)

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(errors.Is(err, contracts.ErrSystemInCorruptedState)).To(BeTrue())
			Expect(actual).ToNot(BeNil())
			Expect(actual.InstallDir).To(Equal(installDir))
			Expect(actual.Config.Host().K2sSetupConfigDir()).To(Equal(k2sConfigDir))
		})
	})

	When("the same install dir occurs multiple times in PATH", func() {
		It("is treated as a single candidate", func() {
			installDir, _ := newInstallation(false)
			setPath(installDir, installDir)

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(err).ToNot(HaveOccurred())
			Expect(actual.InstallDir).To(Equal(installDir))
		})
	})

	When("the same install dir occurs in PATH with differing casing", func() {
		It("is treated as a single candidate on Windows", func() {
			if runtime.GOOS != "windows" {
				Skip("path comparison is only case-insensitive on Windows")
			}

			installDir, _ := newInstallation(false)
			setPath(installDir, strings.ToUpper(installDir))

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(err).ToNot(HaveOccurred())
			Expect(actual.InstallDir).ToNot(BeEmpty())
		})
	})

	When("a stale PATH entry precedes a valid installation", func() {
		It("skips the stale entry and resolves the valid one", func() {
			staleDir := GinkgoT().TempDir()
			createK2sExe(staleDir) // no cfg/config.json -> stale

			installDir, _ := newInstallation(false)
			setPath(staleDir, installDir)

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(err).ToNot(HaveOccurred())
			Expect(actual.InstallDir).To(Equal(installDir))
		})
	})

	When("a PATH entry does not exist at all", func() {
		It("is ignored", func() {
			installDir, _ := newInstallation(false)
			setPath(filepath.Join(GinkgoT().TempDir(), "does-not-exist"), installDir)

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(err).ToNot(HaveOccurred())
			Expect(actual.InstallDir).To(Equal(installDir))
		})
	})

	// An ambiguous PATH must never be resolved silently to one of the candidates; the
	// user has to clean up the PATH first.
	When("two independent valid installations are in PATH", func() {
		It("returns no installation and reports both install dirs asking to clean up PATH", func() {
			firstInstallDir, _ := newInstallation(false)
			secondInstallDir, _ := newInstallation(false)
			setPath(firstInstallDir, secondInstallDir)

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(actual).To(BeNil())
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("multiple installed K2s"))
			Expect(err.Error()).To(ContainSubstring(firstInstallDir))
			Expect(err.Error()).To(ContainSubstring(secondInstallDir))
			Expect(err.Error()).To(ContainSubstring("clean up your PATH"))
		})
	})

	// Leftovers of previous installations must not prevent the discovery of the
	// installed K2s (#2886: custom 'configDir.k2s' is resolved from its own package).
	When("stale and non-existing PATH entries precede a valid installation", func() {
		It("ignores them and fully resolves the valid installation", func() {
			installDir, k2sConfigDir := newInstallation(false)

			setPath(
				filepath.Join(GinkgoT().TempDir(), "does-not-exist"),
				filepath.Join(GinkgoT().TempDir(), "also-removed"),
				installDir)

			actual, err := resolveInstalledK2s(filepath.Join(GinkgoT().TempDir(), "k2s.exe"))

			Expect(err).ToNot(HaveOccurred())
			Expect(actual).ToNot(BeNil())
			Expect(actual.InstallDir).To(Equal(installDir))
			Expect(actual.Config.Host().K2sSetupConfigDir()).To(Equal(k2sConfigDir))
			Expect(actual.RuntimeConfig).ToNot(BeNil())
			Expect(actual.RuntimeConfig.InstallConfig().SetupName()).To(Equal(definitions.SetupNameK2s))
			Expect(actual.RuntimeConfig.InstallConfig().Version()).To(Equal("1.8.0"))
			Expect(actual.RuntimeConfig.ClusterConfig().Name()).To(Equal("k2s-cluster"))
		})
	})
})

var _ = Describe("ReadInstallFolder", func() {
	When("setup config file exists", func() {
		It("returns the install folder", func() {
			k2sConfigDir := GinkgoT().TempDir()
			createSetupConfig(k2sConfigDir, `C:\ws\K2s`, false)

			actual, err := ReadInstallFolder(k2sConfigDir)

			Expect(err).ToNot(HaveOccurred())
			Expect(actual).To(Equal(`C:\ws\K2s`))
		})
	})

	When("setup config file does not exist", func() {
		It("returns an error", func() {
			actual, err := ReadInstallFolder(GinkgoT().TempDir())

			Expect(actual).To(BeEmpty())
			Expect(err).To(MatchError(os.ErrNotExist))
		})
	})
})

// setPath sets the PATH env var for the duration of the current spec.
func setPath(dirs ...string) {
	originalPath := os.Getenv("PATH")
	DeferCleanup(func() {
		Expect(os.Setenv("PATH", originalPath)).To(Succeed())
	})
	Expect(os.Setenv("PATH", strings.Join(dirs, string(os.PathListSeparator)))).To(Succeed())
}

// createK2sExe creates a fake k2s executable in the given dir.
func createK2sExe(dir string) string {
	exePath := filepath.Join(dir, kos.ExecutableFileName("k2s"))

	Expect(os.WriteFile(exePath, []byte("fake"), os.ModePerm)).To(Succeed())

	return exePath
}

// createK2sConfig creates '<installDir>/cfg/config.json' pointing to the given k2s config dir.
func createK2sConfig(installDir string, k2sConfigDir string) {
	cfgDir := filepath.Join(installDir, configFileRelDir)

	Expect(os.MkdirAll(cfgDir, os.ModePerm)).To(Succeed())

	content := map[string]any{
		"smallsetup": map[string]any{"masterIP": "172.19.1.100"},
		"configDir": map[string]any{
			"kube": filepath.Join(installDir, "kube"),
			"k2s":  k2sConfigDir,
			"ssh":  filepath.Join(installDir, "ssh"),
			"logs": filepath.Join(installDir, "logs"),
		},
	}

	data, err := json.Marshal(content)
	Expect(err).ToNot(HaveOccurred())
	Expect(os.WriteFile(filepath.Join(cfgDir, configFileName), data, os.ModePerm)).To(Succeed())
}

// createSetupConfig creates '<k2sConfigDir>/setup.json'.
func createSetupConfig(k2sConfigDir string, installFolder string, corrupted bool) {
	Expect(os.MkdirAll(k2sConfigDir, os.ModePerm)).To(Succeed())

	content := map[string]any{
		"SetupType":     definitions.SetupNameK2s,
		"ClusterName":   "k2s-cluster",
		"Version":       "1.8.0",
		"InstallFolder": installFolder,
		"Corrupted":     corrupted,
	}

	data, err := json.Marshal(content)
	Expect(err).ToNot(HaveOccurred())
	Expect(os.WriteFile(filepath.Join(k2sConfigDir, definitions.K2sRuntimeConfigFileName), data, os.ModePerm)).To(Succeed())
}

func skipIfSetupConfigDirIsFixed() {
	if runtime.GOOS == "linux" {
		Skip("ReadK2sConfig hard-codes the setup config dir on Linux")
	}
}

// newInstallation creates a complete fake K2s installation and returns install dir and k2s config dir.
// It skips the current spec if the setup config dir cannot be configured.
func newInstallation(corrupted bool) (installDir string, k2sConfigDir string) {
	skipIfSetupConfigDirIsFixed()

	installDir = GinkgoT().TempDir()
	k2sConfigDir = GinkgoT().TempDir()

	createK2sExe(installDir)
	createK2sConfig(installDir, k2sConfigDir)
	createSetupConfig(k2sConfigDir, installDir, corrupted)

	return installDir, k2sConfigDir
}
