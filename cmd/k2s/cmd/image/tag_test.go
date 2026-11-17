// SPDX-FileCopyrightText:  © 2026 The K2s Authors
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

var _ = Describe("tag", Ordered, func() {
	var mockImg *mockImageProvider
	var tempDir string

	BeforeAll(func() {
		tagCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})

	BeforeEach(func() {
		mockImg = &mockImageProvider{}
		resetTagFlags()
		DeferCleanup(resetTagFlags)
	})

	AfterEach(func() {
		if tempDir != "" {
			_ = os.RemoveAll(tempDir)
		}
	})

	When("neither id nor name is provided", func() {
		It("returns error", func() {
			tagCmd.Flags().Set(targetImageNameFlagName, "mytarget:v2")

			err := tagImage(tagCmd, []string{})

			Expect(err).To(MatchError("no image id or image name provided"))
		})
	})

	When("running on Linux-only with multi-node selector", func() {
		It("rejects multi-node selector with actionable message", func() {
			tempDir = setupTestCmdContext(tagCmd, mockImg, true, "control-plane")
			tagCmd.Flags().Set(imageNameFlagName, "myimage:v1")
			tagCmd.Flags().Set(targetImageNameFlagName, "myimage:v2")
			tagCmd.Flags().Set(nodesFlagName, "worker-1,worker-2")

			err := tagImage(tagCmd, []string{})

			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("multi-node selection 'worker-1,worker-2' is not supported on a Linux-only installation"))
		})
	})

	When("running on Linux-only with valid options", func() {
		It("routes to provider Image.Tag", func() {
			tempDir = setupTestCmdContext(tagCmd, mockImg, true, "control-plane")
			tagCmd.Flags().Set(imageNameFlagName, "myimage:v1")
			tagCmd.Flags().Set(targetImageNameFlagName, "myimage:v2")

			mockImg.On("Tag", mock.MatchedBy(func(cfg provider.ImageTagConfig) bool {
				return cfg.ImageName == "myimage:v1" && cfg.TargetImageName == "myimage:v2"
			})).Return(nil)

			err := tagImage(tagCmd, []string{})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertExpectations(GinkgoT())
		})
	})
})

func resetTagFlags() {
	tagCmd.Flags().Set(imageIdFlagName, "")
	tagCmd.Flags().Set(imageNameFlagName, "")
	tagCmd.Flags().Set(targetImageNameFlagName, "")
	tagCmd.Flags().Set(nodeFlagName, "")
	tagCmd.Flags().Set(nodesFlagName, "")
}
