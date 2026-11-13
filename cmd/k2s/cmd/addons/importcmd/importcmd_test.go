// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package importcmd

import (
	"log/slog"
	"path/filepath"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/utils"

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
	Describe("buildPsCmd", func() {
		var cmd *cobra.Command

		BeforeEach(func() {
			cmd = NewCommand()
			cmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
		})

		expectedScript := func() string {
			return utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "addons", "Import.ps1"))
		}

		expectedArtifact := func() string {
			abs, err := filepath.Abs("myAddons.tar")
			Expect(err).ToNot(HaveOccurred())
			return " -ArtifactFile " + utils.EscapeWithSingleQuotes(abs)
		}

		When("no file flag is provided", func() {
			It("returns an error", func() {
				psCmd, params, err := buildPsCmd(cmd)

				Expect(err).To(MatchError("no path to OCI artifact provided"))
				Expect(psCmd).To(BeEmpty())
				Expect(params).To(BeNil())
			})
		})

		When("file flag is provided without node flag", func() {
			It("builds params without -Nodes (default behavior preserved)", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())

				psCmd, params, err := buildPsCmd(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(psCmd).To(Equal(expectedScript()))
				Expect(params).To(ConsistOf(expectedArtifact()))
			})
		})

		When("node flag is provided", func() {
			It("forwards -Nodes with the node name", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodeFlagName, "worker-1")).To(Succeed())

				psCmd, params, err := buildPsCmd(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(psCmd).To(Equal(expectedScript()))
				Expect(params).To(ConsistOf(expectedArtifact(), " -Nodes 'worker-1'"))
			})
		})

		When("node flag is provided with surrounding whitespace", func() {
			It("trims the whitespace before forwarding -Nodes", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodeFlagName, "  worker-1  ")).To(Succeed())

				psCmd, params, err := buildPsCmd(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(psCmd).To(Equal(expectedScript()))
				Expect(params).To(ConsistOf(expectedArtifact(), " -Nodes 'worker-1'"))
			})
		})

		When("node flag is provided but blank or whitespace-only", func() {
			It("trims to empty and does not append -Nodes (blank is rejected earlier in runImport)", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodeFlagName, "   ")).To(Succeed())

				psCmd, params, err := buildPsCmd(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(psCmd).To(Equal(expectedScript()))
				Expect(params).ToNot(ContainElement(ContainSubstring("-Nodes")))
			})
		})

		When("nodes flag is provided", func() {
			It("forwards -Nodes with multiple comma-separated nodes", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodesFlagName, "worker-1,worker-2")).To(Succeed())

				psCmd, params, err := buildPsCmd(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(psCmd).To(Equal(expectedScript()))
				Expect(params).To(ConsistOf(expectedArtifact(), " -Nodes 'worker-1,worker-2'"))
			})
		})

		When("nodes flag is provided with surrounding whitespace", func() {
			It("trims the whitespace before forwarding -Nodes", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodesFlagName, "  worker-1,worker-2  ")).To(Succeed())

				psCmd, params, err := buildPsCmd(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(psCmd).To(Equal(expectedScript()))
				Expect(params).To(ConsistOf(expectedArtifact(), " -Nodes 'worker-1,worker-2'"))
			})
		})

		When("nodes flag is provided but blank or whitespace-only", func() {
			It("trims to empty and does not append -Nodes (blank is rejected earlier in runImport)", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodesFlagName, "   ")).To(Succeed())

				psCmd, params, err := buildPsCmd(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(psCmd).To(Equal(expectedScript()))
				Expect(params).ToNot(ContainElement(ContainSubstring("-Nodes")))
			})
		})

		When("nodes flag is provided but comma-only", func() {
			It("trims to empty and does not append -Nodes (blank is rejected earlier in runImport)", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodesFlagName, ",,")).To(Succeed())

				psCmd, params, err := buildPsCmd(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(psCmd).To(Equal(expectedScript()))
				Expect(params).ToNot(ContainElement(ContainSubstring("-Nodes")))
			})
		})

		When("both node and nodes flags are provided", func() {
			It("gives precedence to nodes flag", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodeFlagName, "worker-1")).To(Succeed())
				Expect(cmd.Flags().Set(nodesFlagName, "worker-2,worker-3")).To(Succeed())

				psCmd, params, err := buildPsCmd(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(psCmd).To(Equal(expectedScript()))
				Expect(params).To(ConsistOf(expectedArtifact(), " -Nodes 'worker-2,worker-3'"))
			})
		})

		When("addon names and nodes flag are provided", func() {
			It("builds -Names, -ArtifactFile and -Nodes", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodesFlagName, "worker-1,worker-2")).To(Succeed())

				psCmd, params, err := buildPsCmd(cmd, "registry", "ingress")

				Expect(err).ToNot(HaveOccurred())
				Expect(psCmd).To(Equal(expectedScript()))
				Expect(params).To(ConsistOf(
					" -Names 'registry','ingress'",
					expectedArtifact(),
					" -Nodes 'worker-1,worker-2'",
				))
			})
		})

		When("addon names and node flag are provided", func() {
			It("builds -Names, -ArtifactFile and -Nodes", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(nodeFlagName, "worker-1")).To(Succeed())

				psCmd, params, err := buildPsCmd(cmd, "registry", "ingress")

				Expect(err).ToNot(HaveOccurred())
				Expect(psCmd).To(Equal(expectedScript()))
				Expect(params).To(ConsistOf(
					" -Names 'registry','ingress'",
					expectedArtifact(),
					" -Nodes 'worker-1'",
				))
			})
		})

		When("no omit flag is provided", func() {
			It("does not append -Omit (default behavior preserved)", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())

				_, params, err := buildPsCmd(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(params).ToNot(ContainElement(ContainSubstring("-Omit")))
			})
		})

		When("a single omit flag is provided", func() {
			It("forwards -Omit with the quoted option", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(omitFlagName, "omitKeycloak")).To(Succeed())

				_, params, err := buildPsCmd(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(params).To(ContainElement(" -Omit 'omitKeycloak'"))
			})
		})

		When("multiple omit flags are provided", func() {
			It("forwards them as a comma-separated list", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(omitFlagName, "omitKeycloak")).To(Succeed())
				Expect(cmd.Flags().Set(omitFlagName, "ingress/nginx:omitCertMgr")).To(Succeed())

				_, params, err := buildPsCmd(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(params).To(ContainElement(" -Omit 'omitKeycloak','ingress/nginx:omitCertMgr'"))
			})
		})

		When("omit flags contain surrounding whitespace or are blank", func() {
			It("trims them and drops empty ones", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(omitFlagName, "  omitGrafana  ")).To(Succeed())
				Expect(cmd.Flags().Set(omitFlagName, "   ")).To(Succeed())

				_, params, err := buildPsCmd(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(params).To(ContainElement(" -Omit 'omitGrafana'"))
			})
		})

		When("only blank omit flags are provided", func() {
			It("does not append -Omit", func() {
				Expect(cmd.Flags().Set(fileLabel, "myAddons.tar")).To(Succeed())
				Expect(cmd.Flags().Set(omitFlagName, "   ")).To(Succeed())

				_, params, err := buildPsCmd(cmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(params).ToNot(ContainElement(ContainSubstring("-Omit")))
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
