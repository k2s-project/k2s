// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"os"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/stretchr/testify/mock"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("import", Ordered, func() {
	BeforeAll(func() {
		importCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})

	Describe("importImage", func() {
		var mockImg *mockImageProvider
		var tempDir string

		BeforeEach(func() {
			mockImg = &mockImageProvider{}
			resetImportFlags()
			DeferCleanup(resetImportFlags)
		})

		AfterEach(func() {
			if tempDir != "" {
				_ = os.RemoveAll(tempDir)
			}
		})

		When("neither tar nor dir is provided", func() {
			It("returns error", func() {
				err := importImage(importCmd, []string{})

				Expect(err).To(MatchError("no path to oci archive provided"))
			})
		})

		When("running on Linux-only with Windows flag", func() {
			It("rejects Windows flag with actionable error", func() {
				tempDir = setupTestCmdContext(importCmd, mockImg, true, "control-plane")
				importCmd.Flags().Set(tarFlag, "/tmp/win-img.tar")
				importCmd.Flags().Set(windowsFlag, "true")

				err := importImage(importCmd, []string{})

				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(Equal("importing Windows container images is not supported on a Linux-only installation"))
			})
		})

		When("running on Linux-only with valid tar", func() {
			It("routes to provider Image.Import", func() {
				tempDir = setupTestCmdContext(importCmd, mockImg, true, "control-plane")
				importCmd.Flags().Set(tarFlag, "/tmp/linux-img.tar")

				mockImg.On("Import", mock.MatchedBy(func(cfg provider.ImageImportConfig) bool {
					return cfg.TarPath == "/tmp/linux-img.tar" && !cfg.Windows
				})).Return(nil)

				err := importImage(importCmd, []string{})

				Expect(err).ToNot(HaveOccurred())
				mockImg.AssertExpectations(GinkgoT())
			})
		})
	})
})

func resetImportFlags() {
	importCmd.Flags().Set(tarFlag, "")
	importCmd.Flags().Set(dirFlag, "")
	importCmd.Flags().Set(windowsFlag, "false")
	importCmd.Flags().Set(dockerArchiveFlag, "false")
	importCmd.Flags().Set(nodeFlagName, "")
	importCmd.Flags().Set(nodesFlagName, "")
}
