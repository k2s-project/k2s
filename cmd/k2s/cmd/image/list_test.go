// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"os"

	"github.com/k2s-project/k2s/internal/provider"
	"github.com/stretchr/testify/mock"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("list", func() {
	var mockImg *mockImageProvider
	var tempDir string

	BeforeEach(func() {
		mockImg = &mockImageProvider{}
		resetListFlags()
		DeferCleanup(resetListFlags)
	})

	AfterEach(func() {
		if tempDir != "" {
			_ = os.RemoveAll(tempDir)
		}
	})

	When("running on Linux-only with invalid node selector", func() {
		It("rejects Windows worker node selector before calling ImageProvider.List", func() {
			tempDir = setupTestCmdContext(listCmd, mockImg, true, "control-plane")
			listCmd.Flags().Set(nodeFlagName, "windows")

			err := listImages(listCmd, []string{})

			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("is a Windows worker node"))
			mockImg.AssertNotCalled(GinkgoT(), "List", mock.Anything)
		})
	})

	When("running with valid node selector", func() {
		It("passes node selector to ImageProvider.List", func() {
			tempDir = setupTestCmdContext(listCmd, mockImg, false, "control-plane")
			listCmd.Flags().Set(nodesFlagName, "control-plane,k2s-win-worker")

			mockImg.On("List", mock.MatchedBy(func(cfg provider.ImageListConfig) bool {
				return cfg.Nodes == "control-plane,k2s-win-worker"
			})).Return(&provider.ImageListResult{}, nil)

			err := listImages(listCmd, []string{})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertExpectations(GinkgoT())
		})
	})
})

func resetListFlags() {
	listCmd.Flags().Set(nodeFlagName, "")
	listCmd.Flags().Set(nodesFlagName, "")
	listCmd.Flags().Set(includeK8sImages, "false")
	listCmd.Flags().Set(outputFlagName, "")
}
