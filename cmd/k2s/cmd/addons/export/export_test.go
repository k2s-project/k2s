// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package export

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

func TestExportPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons export cmd Unit Tests", Label("unit", "ci", "addons", "export"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("export pkg", func() {
	Describe("buildExportConfig", func() {
		var cmd *cobra.Command

		BeforeEach(func() {
			cmd = NewCommand()
			cmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
		})

		When("no directory flag is provided", func() {
			It("returns an error", func() {
				config, err := buildExportConfig(cmd)

				Expect(err).To(MatchError("no export path provided"))
				Expect(config).To(BeZero())
			})
		})

		When("only the directory is provided", func() {
			It("exports all addons with images and packages", func() {
				Expect(cmd.Flags().Set(directoryLabel, "exports")).To(Succeed())

				config, err := buildExportConfig(cmd)

				Expect(err).ToNot(HaveOccurred())
				expected, err := filepath.Abs("exports")
				Expect(err).ToNot(HaveOccurred())
				Expect(config.OutputDir).To(Equal(expected))
				Expect(config.Names).To(BeEmpty())
				Expect(config.OmitImages).To(BeFalse())
				Expect(config.OmitPackages).To(BeFalse())
				Expect(config.ShowOutput).To(BeFalse())
			})
		})

		When("addons and all flags are provided", func() {
			It("forwards names and options", func() {
				Expect(cmd.Flags().Set(directoryLabel, "exports")).To(Succeed())
				Expect(cmd.Flags().Set(omitImagesLabel, "true")).To(Succeed())
				Expect(cmd.Flags().Set(omitPackagesLabel, "true")).To(Succeed())
				Expect(cmd.Flags().Set(common.OutputFlagName, "true")).To(Succeed())

				config, err := buildExportConfig(cmd, "registry", "ingress", "nginx")

				Expect(err).ToNot(HaveOccurred())
				Expect(config.Names).To(Equal([]string{"registry", "ingress", "nginx"}))
				Expect(config.OmitImages).To(BeTrue())
				Expect(config.OmitPackages).To(BeTrue())
				Expect(config.ShowOutput).To(BeTrue())
			})
		})
	})
})
