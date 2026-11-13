// SPDX-FileCopyrightText: (C) 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package framework

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	contracts "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/logging"
	"github.com/k2s-project/k2s/test/framework/k2s"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestFramework(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Framework Unit Tests", Label("unit", "ci"))
}

var _ = Describe("LogsDir", Label("unit", "ci"), func() {
	BeforeEach(func() {
		GinkgoT().Setenv(logging.LogRootEnvVar, "")
	})

	It("prefers the environment override over installation values", func() {
		configDir := GinkgoT().TempDir()
		override := filepath.Join(configDir, "override-logs")

		GinkgoT().Setenv(logging.LogRootEnvVar, override)

		Expect(logging.RootLogDirForInstallation(configDir, filepath.Join(configDir, "configured-logs"))).
			To(Equal(filepath.Clean(override)))
	})

	It("prefers the installed persisted log root over its configured fallback", func() {
		configDir := GinkgoT().TempDir()
		persistedLogs := filepath.Join(configDir, "persisted-logs")
		configuredLogs := filepath.Join(configDir, "configured-logs")
		setup, err := json.Marshal(map[string]string{"LogRoot": persistedLogs})
		Expect(err).NotTo(HaveOccurred())
		Expect(os.WriteFile(filepath.Join(configDir, "setup.json"), setup, 0o600)).To(Succeed())

		Expect(logging.RootLogDirForInstallation(configDir, configuredLogs)).To(Equal(filepath.Clean(persistedLogs)))
	})

	It("expands home-directory paths in the configured fallback", func() {
		home, err := os.UserHomeDir()
		Expect(err).NotTo(HaveOccurred())

		got := logging.RootLogDirForInstallation(GinkgoT().TempDir(), "~/k2s-logs")

		Expect(got).To(Equal(filepath.Clean(filepath.Join(home, "k2s-logs"))))
	})

	It("uses the installed persisted log root in the Windows test suite", func() {
		if runtime.GOOS != "windows" {
			Skip("Windows installation log discovery")
		}

		configDir := GinkgoT().TempDir()
		persistedLogs := filepath.Join(configDir, "persisted-logs")
		configuredLogs := filepath.Join(configDir, "configured-logs")
		host := contracts.NewHostConfig(nil, nil, configDir, "", configuredLogs)
		suite := &K2sTestSuite{setupInfo: &k2s.SetupInfo{
			Config: *contracts.NewK2sConfig(host, nil),
		}}

		Expect(suite.LogsDir()).To(Equal(filepath.Clean(configuredLogs)))

		setup, err := json.Marshal(map[string]string{"LogRoot": persistedLogs})
		Expect(err).NotTo(HaveOccurred())
		Expect(os.WriteFile(filepath.Join(configDir, "setup.json"), setup, 0o600)).To(Succeed())

		Expect(suite.LogsDir()).To(Equal(filepath.Clean(persistedLogs)))
	})
})
