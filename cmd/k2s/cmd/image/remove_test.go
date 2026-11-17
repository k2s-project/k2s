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

var _ = Describe("remove", Ordered, func() {
	var mockImg *mockImageProvider
	var tempDir string

	BeforeAll(func() {
		removeCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})

	BeforeEach(func() {
		mockImg = &mockImageProvider{}
		resetRemoveFlags()
		DeferCleanup(resetRemoveFlags)
	})

	AfterEach(func() {
		if tempDir != "" {
			_ = os.RemoveAll(tempDir)
		}
	})

	When("running on Linux-only with multi-node selector", func() {
		It("rejects multi-node selector with actionable message", func() {
			tempDir = setupTestCmdContext(removeCmd, mockImg, true, "control-plane")
			removeCmd.Flags().Set(removeImgNameFlagName, "myimage:v1")
			removeCmd.Flags().Set(nodesFlagName, "worker-1,worker-2")

			err := removeImage(removeCmd, []string{})

			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("multi-node selection 'worker-1,worker-2' is not supported on a Linux-only installation"))
		})
	})

	When("running on Linux-only with --from-registry", func() {
		It("routes to provider Image.Remove with FromRegistry true", func() {
			tempDir = setupTestCmdContext(removeCmd, mockImg, true, "control-plane")
			removeCmd.Flags().Set(removeImgNameFlagName, "myimage:v1")
			removeCmd.Flags().Set(fromRegistryFlagName, "true")

			mockImg.On("Remove", mock.MatchedBy(func(cfg provider.ImageRemoveConfig) bool {
				return cfg.ImageName == "myimage:v1" && cfg.FromRegistry
			})).Return(nil)

			err := removeImage(removeCmd, []string{})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertExpectations(GinkgoT())
		})
	})

	When("running on Linux-only with valid options", func() {
		It("routes to provider Image.Remove", func() {
			tempDir = setupTestCmdContext(removeCmd, mockImg, true, "control-plane")
			removeCmd.Flags().Set(removeImgNameFlagName, "myimage:v1")
			removeCmd.Flags().Set(forceFlagName, "true")

			mockImg.On("Remove", mock.MatchedBy(func(cfg provider.ImageRemoveConfig) bool {
				return cfg.ImageName == "myimage:v1" && cfg.Force
			})).Return(nil)

			err := removeImage(removeCmd, []string{})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertExpectations(GinkgoT())
		})
	})
})

func resetRemoveFlags() {
	removeCmd.Flags().Set(imageIdFlagName, "")
	removeCmd.Flags().Set(removeImgNameFlagName, "")
	removeCmd.Flags().Set(nodeFlagName, "")
	removeCmd.Flags().Set(nodesFlagName, "")
	removeCmd.Flags().Set(fromRegistryFlagName, "false")
	removeCmd.Flags().Set(forceFlagName, "false")
}
