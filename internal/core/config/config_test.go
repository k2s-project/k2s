// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier:   MIT

package config_test

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	contracts "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/definitions"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestConfig(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "config Integration Tests", Label("integration", "ci", "config"))
}

var _ = Describe("config pkg", func() {
	Describe("ReadK2sConfig", Ordered, func() {
		When("config file does not exist", func() {
			It("returns not-exist error", func() {
				config, err := config.ReadK2sConfig(GinkgoT().TempDir())

				Expect(config).To(BeNil())
				Expect(err).To(MatchError(os.ErrNotExist))
			})
		})

		When("config file is corrupted", func() {
			var dir string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				subDir := filepath.Join(dir, "cfg")

				Expect(os.MkdirAll(subDir, os.ModePerm)).To(Succeed())

				configPath := filepath.Join(subDir, "config.json")

				GinkgoWriter.Println("Writing corrupted test file to <", configPath, ">")

				Expect(os.WriteFile(configPath, []byte(" "), os.ModePerm)).To(Succeed())
			})

			It("returns JSON syntax error", func() {
				config, err := config.ReadK2sConfig(dir)

				Expect(config).To(BeNil())

				var syntaxError *json.SyntaxError
				Expect(errors.As(err, &syntaxError)).To(BeTrue())
			})
		})

		When("config file exists", func() {
			var actual *contracts.K2sConfig

			BeforeAll(func() {
				dir := GinkgoT().TempDir()
				subDir := filepath.Join(dir, "cfg")

				Expect(os.MkdirAll(subDir, os.ModePerm)).To(Succeed())

				configPath := filepath.Join(subDir, "config.json")
				inputConfig := map[string]any{
					"configDir": map[string]any{
						"ssh":  "~/.ssh",
						"kube": "~/.kube",
						"k2s":  "C:\\ProgramData\\K2s",
					},
				}

				blob, err := json.Marshal(inputConfig)
				Expect(err).ToNot(HaveOccurred())

				GinkgoWriter.Println("Writing test config file to <", configPath, ">")

				Expect(os.WriteFile(configPath, blob, os.ModePerm)).To(Succeed())

				actual, err = config.ReadK2sConfig(dir)

				Expect(err).ToNot(HaveOccurred())
			})

			It("kube config path is cleaned and absolute", func() {
				GinkgoWriter.Println("kube config dir: <", actual.Host().KubeConfig().CurrentDir(), ">")

				Expect(filepath.IsAbs(actual.Host().KubeConfig().CurrentDir())).To(BeTrue())
				Expect(actual.Host().KubeConfig().CurrentDir()).ToNot(ContainSubstring("~"))
			})

			It("K2s config path is absolute", func() {
				GinkgoWriter.Println("K2s config dir: <", actual.Host().K2sSetupConfigDir(), ">")

				Expect(filepath.IsAbs(actual.Host().K2sSetupConfigDir())).To(BeTrue())
			})

			It("SSH path is cleaned and absolute", func() {
				GinkgoWriter.Println("ssh dir: <", actual.Host().SshConfig().CurrentDir(), ">")

				Expect(filepath.IsAbs(actual.Host().SshConfig().CurrentDir())).To(BeTrue())
				Expect(actual.Host().SshConfig().CurrentDir()).ToNot(ContainSubstring("~"))
			})
		})
	})

	Describe("ReadRuntimeConfig", func() {
		When("config file does not exist", func() {
			It("returns system-not-installed error", func() {
				config, err := config.ReadRuntimeConfig(GinkgoT().TempDir())

				Expect(config).To(BeNil())
				Expect(err).To(MatchError(contracts.ErrSystemNotInstalled))
			})
		})

		When("config file is corrupted", func() {
			var dir string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				configPath := filepath.Join(dir, definitions.K2sRuntimeConfigFileName)

				GinkgoWriter.Println("Writing corrupted test file to <", configPath, ">")

				Expect(os.WriteFile(configPath, []byte(" "), os.ModePerm)).To(Succeed())
			})

			It("returns JSON syntax error", func() {
				config, err := config.ReadRuntimeConfig(dir)

				Expect(config).To(BeNil())

				var syntaxError *json.SyntaxError
				Expect(errors.As(err, &syntaxError)).To(BeTrue())
			})
		})

		When("config file exists", func() {
			var dir string
			var inputConfig map[string]any

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				inputConfig = map[string]any{
					"SetupType":                "test-name",
					"Registries":               []string{"r1", "r2"},
					"LinuxOnly":                true,
					"Version":                  "test-version",
					"ClusterName":              "my-cluster",
					"ControlPlaneNodeHostname": "my-host",
				}

				blob, err := json.Marshal(inputConfig)
				Expect(err).ToNot(HaveOccurred())
				Expect(os.WriteFile(filepath.Join(dir, definitions.K2sRuntimeConfigFileName), blob, os.ModePerm)).To(Succeed())
			})

			It("returns config data", func() {
				config, err := config.ReadRuntimeConfig(dir)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.InstallConfig().LinuxOnly()).To(Equal(inputConfig["LinuxOnly"]))

				registries := config.ClusterConfig().Registries()
				Expect(len(registries)).To(Equal(len(inputConfig["Registries"].([]string))))
				Expect(string(registries[0])).To(Equal(inputConfig["Registries"].([]string)[0]))
				Expect(string(registries[1])).To(Equal(inputConfig["Registries"].([]string)[1]))

				Expect(config.InstallConfig().SetupName()).To(Equal(inputConfig["SetupType"]))
				Expect(config.InstallConfig().Version()).To(Equal(inputConfig["Version"]))
				Expect(config.ClusterConfig().Name()).To(Equal(inputConfig["ClusterName"]))
				Expect(config.ControlPlaneConfig().Hostname()).To(Equal(inputConfig["ControlPlaneNodeHostname"]))
			})
		})

		When("config file has entry 'Corrupted' (errors during installation)", func() {
			var dir string
			var inputConfig map[string]any

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				inputConfig = map[string]any{
					"SetupType":   "test-name",
					"Registries":  []string{"r1", "r2"},
					"LinuxOnly":   true,
					"Version":     "test-version",
					"ClusterName": "my-cluster",
					"Corrupted":   true,
				}

				blob, err := json.Marshal(inputConfig)
				Expect(err).ToNot(HaveOccurred())
				Expect(os.WriteFile(filepath.Join(dir, definitions.K2sRuntimeConfigFileName), blob, os.ModePerm)).To(Succeed())
			})

			It("returns config data and system-in-corrupted-state error", func() {

				config, err := config.ReadRuntimeConfig(dir)

				Expect(err).To(Equal(contracts.ErrSystemInCorruptedState))
				Expect(config.InstallConfig().LinuxOnly()).To(Equal(inputConfig["LinuxOnly"]))

				registries := config.ClusterConfig().Registries()
				Expect(len(registries)).To(Equal(len(inputConfig["Registries"].([]string))))
				Expect(string(registries[0])).To(Equal(inputConfig["Registries"].([]string)[0]))
				Expect(string(registries[1])).To(Equal(inputConfig["Registries"].([]string)[1]))

				Expect(config.InstallConfig().SetupName()).To(Equal(inputConfig["SetupType"]))
				Expect(config.InstallConfig().Version()).To(Equal(inputConfig["Version"]))
				Expect(config.ClusterConfig().Name()).To(Equal(inputConfig["ClusterName"]))
				Expect(config.InstallConfig().Corrupted()).To(Equal(inputConfig["Corrupted"]))
			})
		})

		When("config file misses cluster name entry", func() {
			var dir string
			var inputConfig map[string]any

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				inputConfig = map[string]any{
					"SetupType":                "test-name",
					"Registries":               []string{"r1", "r2"},
					"LinuxOnly":                true,
					"Version":                  "test-version",
					"ControlPlaneNodeHostname": "my-host",
				}

				blob, err := json.Marshal(inputConfig)
				Expect(err).ToNot(HaveOccurred())
				Expect(os.WriteFile(filepath.Join(dir, definitions.K2sRuntimeConfigFileName), blob, os.ModePerm)).To(Succeed())
			})

			It("returns config with legacy cluster name", func() {
				config, err := config.ReadRuntimeConfig(dir)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.ClusterConfig().Name()).To(Equal(definitions.LegacyClusterName))
			})
		})
	})

	Describe("MarkSetupAsCorrupted", func() {
		When("config file does not exist", func() {
			var dir string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
			})

			It("creates new config file with corrupted state marker", func() {
				Expect(config.MarkSetupAsCorrupted(dir)).ToNot(HaveOccurred())

				configBlob, err := os.ReadFile(filepath.Join(dir, definitions.K2sRuntimeConfigFileName))
				Expect(err).ToNot(HaveOccurred())

				var config map[string]any
				Expect(json.Unmarshal(configBlob, &config)).ToNot(HaveOccurred())

				Expect(config).To(HaveLen(1))
				Expect(config["Corrupted"]).To(BeTrue())
			})
		})

		When("config file exists", func() {
			var dir string
			var configPath string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				config := map[string]any{"prop1": "val1", "prop2": "val2", "prop3": 123.45}

				configBlob, err := json.Marshal(config)
				Expect(err).ToNot(HaveOccurred())

				configPath = filepath.Join(dir, definitions.K2sRuntimeConfigFileName)

				Expect(os.WriteFile(configPath, configBlob, os.ModePerm)).To(Succeed())
			})

			It("marks existing config as corrupted without modifying the other values", func() {
				Expect(config.MarkSetupAsCorrupted(dir)).ToNot(HaveOccurred())

				configBlob, err := os.ReadFile(configPath)
				Expect(err).ToNot(HaveOccurred())

				var config map[string]any
				Expect(json.Unmarshal(configBlob, &config)).ToNot(HaveOccurred())

				Expect(config).To(HaveLen(4))
				Expect(config["Corrupted"]).To(BeTrue())
				Expect(config["prop1"]).To(Equal("val1"))
				Expect(config["prop2"]).To(Equal("val2"))
				Expect(config["prop3"]).To(Equal(123.45))
			})
		})
	})
})
