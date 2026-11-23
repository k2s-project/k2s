// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package importcmd

import (
	"log/slog"
	"path/filepath"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/cobra"
)

func TestImportcmdPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons import cmd Unit Tests", Label("unit", "ci", "addons", "import"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("importcmd pkg", func() {
	Describe("buildImportConfig", func() {
		var cmd *cobra.Command

		BeforeEach(func() {
			cmd = NewCommand()
			cmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
		})

		expectedArtifact := func() string {
			abs, err := filepath.Abs("myAddons.tar")
			Expect(err).ToNot(HaveOccurred())
			return abs
		}

		When("no file flag is provided", func() {
			It("returns an error", func() {
				config, err := buildImportConfig(cmd)

				Expect(err).To(MatchError("no path to OCI artifact provided"))
				Expect(config).To(BeZero())
			})
		})

		When("file flag is provided without node flag", func() {
			It("builds a config without nodes, names and output (default behavior preserved)", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.ArtifactFile).To(Equal(expectedArtifact()))
				Expect(config.Names).To(BeEmpty())
				Expect(config.Nodes).To(BeEmpty())
				Expect(config.ShowOutput).To(BeFalse())
			})
		})

		When("output flag is set", func() {
			It("requests output", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(common.OutputFlagName, "true")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.ShowOutput).To(BeTrue())
			})
		})

		When("node flag is provided", func() {
			It("forwards the node name", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodeFlagName, "worker-1")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.ArtifactFile).To(Equal(expectedArtifact()))
				Expect(config.Nodes).To(Equal("worker-1"))
			})
		})

		When("node flag is provided with surrounding whitespace", func() {
			It("trims the whitespace before forwarding the node name", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodeFlagName, "  worker-1  ")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Nodes).To(Equal("worker-1"))
			})
		})

		When("node flag is provided but blank or whitespace-only", func() {
			It("trims to empty and does not forward nodes (blank is rejected earlier in runImport)", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodeFlagName, "   ")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Nodes).To(BeEmpty())
			})
		})

		When("nodes flag is provided", func() {
			It("forwards multiple comma-separated nodes", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodesFlagName, "worker-1,worker-2")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Nodes).To(Equal("worker-1,worker-2"))
			})
		})

		When("nodes flag is provided with surrounding whitespace", func() {
			It("trims the whitespace before forwarding the nodes", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodesFlagName, "  worker-1,worker-2  ")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Nodes).To(Equal("worker-1,worker-2"))
			})
		})

		When("nodes flag is provided but blank or whitespace-only", func() {
			It("trims to empty and does not forward nodes (blank is rejected earlier in runImport)", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodesFlagName, "   ")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Nodes).To(BeEmpty())
			})
		})

		When("nodes flag is provided but comma-only", func() {
			It("does not forward nodes (blank is rejected earlier in runImport)", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodesFlagName, ",,")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Nodes).To(BeEmpty())
			})
		})

		When("both node and nodes flags are provided", func() {
			It("gives precedence to nodes flag", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodeFlagName, "worker-1")).To(Succeed())
				Expect(cmd.Flags().Set(nodesFlagName, "worker-2,worker-3")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Nodes).To(Equal("worker-2,worker-3"))
			})
		})

		When("addon names and nodes flag are provided", func() {
			It("forwards names, artifact and nodes", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodesFlagName, "worker-1,worker-2")).To(Succeed())

				config, err := buildImportConfig(cmd, "registry", "ingress")

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Names).To(Equal([]string{"registry", "ingress"}))
				Expect(config.ArtifactFile).To(Equal(expectedArtifact()))
				Expect(config.Nodes).To(Equal("worker-1,worker-2"))
			})
		})

		When("addon names and node flag are provided", func() {
			It("forwards names, artifact and node", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodeFlagName, "worker-1")).To(Succeed())

				config, err := buildImportConfig(cmd, "registry", "ingress")

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Names).To(Equal([]string{"registry", "ingress"}))
				Expect(config.ArtifactFile).To(Equal(expectedArtifact()))
				Expect(config.Nodes).To(Equal("worker-1"))
			})
		})

		When("no omit flag is provided", func() {
			It("does not forward omit options (default behavior preserved)", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Omit).To(BeEmpty())
			})
		})

		When("a single omit flag is provided", func() {
			It("forwards the option", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(omitFlagName, "omitKeycloak")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Omit).To(Equal([]string{"omitKeycloak"}))
			})
		})

		When("multiple omit flags are provided", func() {
			It("forwards them in order", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(omitFlagName, "omitKeycloak")).To(Succeed())
				Expect(cmd.Flags().Set(omitFlagName, "ingress/nginx:omitCertMgr")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Omit).To(Equal([]string{"omitKeycloak", "ingress/nginx:omitCertMgr"}))
			})
		})

		When("omit flags contain surrounding whitespace or are blank", func() {
			It("trims them and drops empty ones", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(omitFlagName, "  omitGrafana  ")).To(Succeed())
				Expect(cmd.Flags().Set(omitFlagName, "   ")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Omit).To(Equal([]string{"omitGrafana"}))
			})
		})

		When("only blank omit flags are provided", func() {
			It("does not forward omit options", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(omitFlagName, "   ")).To(Succeed())

				config, err := buildImportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Omit).To(BeEmpty())
			})
		})
	})

	Describe("runImport", func() {
		var cmd *cobra.Command

		BeforeEach(func() {
			cmd = NewCommand()
			cmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
		})

		When("node flag is changed and empty", func() {
			It("returns a descriptive error", func() {
				Expect(cmd.Flags().Set(nodeFlagName, "")).To(Succeed())

				err := runImport(cmd, nil)

				Expect(err).To(MatchError("the --node flag was provided but is empty - specify a valid node name (run 'kubectl get nodes' to list available nodes)"))
			})
		})

		When("node flag is changed and whitespace-only", func() {
			It("returns a descriptive error", func() {
				Expect(cmd.Flags().Set(nodeFlagName, "   ")).To(Succeed())

				err := runImport(cmd, nil)

				Expect(err).To(MatchError("the --node flag was provided but is empty - specify a valid node name (run 'kubectl get nodes' to list available nodes)"))
			})
		})

		When("nodes flag is changed and empty", func() {
			It("returns a descriptive error", func() {
				Expect(cmd.Flags().Set(nodesFlagName, "")).To(Succeed())

				err := runImport(cmd, nil)

				Expect(err).To(MatchError("the --nodes flag was provided but is empty - specify a valid node name (run 'kubectl get nodes' to list available nodes)"))
			})
		})

		When("nodes flag is changed and whitespace-only", func() {
			It("returns a descriptive error", func() {
				Expect(cmd.Flags().Set(nodesFlagName, " \t  \n ")).To(Succeed())

				err := runImport(cmd, nil)

				Expect(err).To(MatchError("the --nodes flag was provided but is empty - specify a valid node name (run 'kubectl get nodes' to list available nodes)"))
			})
		})

		When("nodes flag is changed and contains only commas and whitespace", func() {
			It("returns a descriptive error", func() {
				Expect(cmd.Flags().Set(nodesFlagName, ",,")).To(Succeed())

				err := runImport(cmd, nil)

				Expect(err).To(MatchError("the --nodes flag was provided but is empty - specify a valid node name (run 'kubectl get nodes' to list available nodes)"))
			})
		})

		When("both node and nodes flags are provided and nodes is comma-only", func() {
			It("validates effective selector nodes and returns a descriptive error", func() {
				Expect(cmd.Flags().Set(nodeFlagName, "worker-1")).To(Succeed())
				Expect(cmd.Flags().Set(nodesFlagName, " , , ")).To(Succeed())

				err := runImport(cmd, nil)

				Expect(err).To(MatchError("the --nodes flag was provided but is empty - specify a valid node name (run 'kubectl get nodes' to list available nodes)"))
			})
		})
	})
})
