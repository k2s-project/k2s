// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package config_test

import (
	"os"
	"path/filepath"
	"runtime"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/core/config"
)

// realistic excerpt of 'cfg/config.json' containing entries that are unknown to the typed
// Go representation.
const configFileFixture = `{
  "smallsetup": {
    "masterIP": "172.19.1.100",
    "masterNetworkCIDR": "172.19.1.0/24"
  },
  "backup": {
    "path": "C:\\backup"
  },
  "clusterName": "k2s-cluster",
  "supportedWorkerOS": [
    {
      "os": "debian12",
      "cloudImage": {
        "urlRoot": "https://example.invalid",
        "urlFile": "debian-12-genericcloud-amd64.qcow2"
      }
    }
  ],
  "configDir": {
    "kube": "~\\.kube",
    "k2s": "C:\\ProgramData\\K2s",
    "ssh": "~\\.ssh",
    "docker": "~\\.docker",
    "logs": "C:\\var\\log"
  },
  "vfprules-k2s": {
    "rules": ["rule-1", "rule-2"]
  }
}`

// The K2s config file of a package is the source of truth of the installation it belongs
// to. #2886: the upgrade must never modify it - the custom setup config dir of an old
// installation is only propagated transiently via the K2S_SETUP_CONFIG_DIR env var.
var _ = Describe("K2s config file", func() {
	var installDir string
	var configFilePath string

	BeforeEach(func() {
		installDir = GinkgoT().TempDir()
		Expect(os.MkdirAll(filepath.Join(installDir, "cfg"), os.ModePerm)).To(Succeed())
		configFilePath = filepath.Join(installDir, "cfg", "config.json")
		Expect(os.WriteFile(configFilePath, []byte(configFileFixture), os.ModePerm)).To(Succeed())
	})

	Describe("ReadK2sConfig", func() {
		It("does not modify the config file", func() {
			before, err := os.ReadFile(configFilePath)
			Expect(err).ToNot(HaveOccurred())

			_, err = config.ReadK2sConfig(installDir)
			Expect(err).ToNot(HaveOccurred())

			after, err := os.ReadFile(configFilePath)
			Expect(err).ToNot(HaveOccurred())
			Expect(after).To(Equal(before))
		})

		It("returns the setup config dir configured in the package", func() {
			if runtime.GOOS != "windows" {
				Skip("ReadK2sConfig hard-codes the setup config dir on Linux")
			}

			k2sConfig, err := config.ReadK2sConfig(installDir)

			Expect(err).ToNot(HaveOccurred())
			Expect(k2sConfig.Host().K2sSetupConfigDir()).To(Equal(`C:\ProgramData\K2s`))
			Expect(k2sConfig.Host().K2sInstallDir()).To(Equal(installDir))
		})
	})

	Describe("ReadSupportedWorkerOS", func() {
		It("does not modify the config file", func() {
			before, err := os.ReadFile(configFilePath)
			Expect(err).ToNot(HaveOccurred())

			_, err = config.ReadSupportedWorkerOS(installDir)
			Expect(err).ToNot(HaveOccurred())

			after, err := os.ReadFile(configFilePath)
			Expect(err).ToNot(HaveOccurred())
			Expect(after).To(Equal(before))
		})
	})
})

