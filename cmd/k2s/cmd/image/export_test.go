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

var _ = Describe("export", Ordered, func() {
	var mockImg *mockImageProvider
	var tempDir string

	BeforeAll(func() {
		exportCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})

	BeforeEach(func() {
		mockImg = &mockImageProvider{}
		resetExportFlags()
		DeferCleanup(resetExportFlags)
	})

	AfterEach(func() {
		if tempDir != "" {
			_ = os.RemoveAll(tempDir)
		}
	})

	When("neither name nor id provided", func() {
		It("returns error", func() {
			exportCmd.Flags().Set(tarFlag, "myExportPath")

			err := exportImage(exportCmd, []string{})

			Expect(err).To(MatchError("no image id or image name provided"))
		})
	})

	When("no export path provided", func() {
		It("returns error", func() {
			exportCmd.Flags().Set(removeImgNameFlagName, "myImageName")

			err := exportImage(exportCmd, []string{})

			Expect(err).To(MatchError("no export path provided"))
		})
	})

	When("running on Linux-only with invalid node selector", func() {
		It("rejects multi-node selector", func() {
			tempDir = setupTestCmdContext(exportCmd, mockImg, true, "control-plane")
			exportCmd.Flags().Set(removeImgNameFlagName, "myImageName")
			exportCmd.Flags().Set(tarFlag, "/tmp/export.tar")
			exportCmd.Flags().Set(nodesFlagName, "node-1,node-2")

			err := exportImage(exportCmd, []string{})

			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("multi-node selection 'node-1,node-2' is not supported on a Linux-only installation"))
		})
	})

	When("running on Linux-only with valid flags and DockerArchive", func() {
		It("routes to provider Image.Export with DockerArchive set", func() {
			tempDir = setupTestCmdContext(exportCmd, mockImg, true, "control-plane")
			exportCmd.Flags().Set(removeImgNameFlagName, "myImageName")
			exportCmd.Flags().Set(tarFlag, "/tmp/export.tar")
			exportCmd.Flags().Set(dockerArchiveFlag, "true")

			mockImg.On("Export", mock.MatchedBy(func(cfg provider.ImageExportConfig) bool {
				return cfg.ImageName == "myImageName" &&
					cfg.OutputPath == "/tmp/export.tar" &&
					cfg.DockerArchive
			})).Return(nil)

			err := exportImage(exportCmd, []string{})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertExpectations(GinkgoT())
		})
	})

	When("running with image id flag", func() {
		It("routes to provider Image.Export with ImageId set", func() {
			tempDir = setupTestCmdContext(exportCmd, mockImg, true, "control-plane")
			exportCmd.Flags().Set(imageIdFlagName, "123456789abc")
			exportCmd.Flags().Set(tarFlag, "/tmp/export-id.tar")

			mockImg.On("Export", mock.MatchedBy(func(cfg provider.ImageExportConfig) bool {
				return cfg.ImageId == "123456789abc" &&
					cfg.OutputPath == "/tmp/export-id.tar"
			})).Return(nil)

			err := exportImage(exportCmd, []string{})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertExpectations(GinkgoT())
		})
	})

	When("running with positional arguments", func() {
		It("resolves image name and export path from args", func() {
			tempDir = setupTestCmdContext(exportCmd, mockImg, true, "control-plane")

			mockImg.On("Export", mock.MatchedBy(func(cfg provider.ImageExportConfig) bool {
				return cfg.ImageName == "posImage:v1" &&
					cfg.OutputPath == "/tmp/pos.tar"
			})).Return(nil)

			err := exportImage(exportCmd, []string{"posImage:v1", "/tmp/pos.tar"})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertExpectations(GinkgoT())
		})
	})
})

func resetExportFlags() {
	exportCmd.Flags().Set(removeImgNameFlagName, "")
	exportCmd.Flags().Set(imageIdFlagName, "")
	exportCmd.Flags().Set(tarFlag, "")
	exportCmd.Flags().Set(dockerArchiveFlag, "false")
	exportCmd.Flags().Set(nodeFlagName, "")
	exportCmd.Flags().Set(nodesFlagName, "")
}
