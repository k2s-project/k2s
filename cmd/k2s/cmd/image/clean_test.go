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

var _ = Describe("clean", Ordered, func() {
	var mockImg *mockImageProvider
	var tempDir string

	BeforeAll(func() {
		cleanCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})

	BeforeEach(func() {
		mockImg = &mockImageProvider{}
		resetCleanFlags()
		DeferCleanup(resetCleanFlags)
	})

	AfterEach(func() {
		if tempDir != "" {
			_ = os.RemoveAll(tempDir)
		}
	})

	When("running on Linux-only with multi-node selector", func() {
		It("rejects multi-node selector with actionable message", func() {
			tempDir = setupTestCmdContext(cleanCmd, mockImg, true, "control-plane")
			cleanCmd.Flags().Set(nodesFlagName, "worker-1,worker-2")

			err := cleanImages(cleanCmd, []string{})

			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("multi-node selection 'worker-1,worker-2' is not supported on a Linux-only installation"))
		})
	})

	When("running on Linux-only with windows worker node", func() {
		It("rejects windows worker node selector with actionable message", func() {
			tempDir = setupTestCmdContext(cleanCmd, mockImg, true, "control-plane")
			cleanCmd.Flags().Set(nodeFlagName, "winworker-1")

			err := cleanImages(cleanCmd, []string{})

			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("node 'winworker-1' is a Windows worker node; Linux-only installations do not contain Windows worker nodes"))
		})
	})

	When("running on Linux-only with valid node selector", func() {
		It("routes to provider Image.Clean", func() {
			tempDir = setupTestCmdContext(cleanCmd, mockImg, true, "control-plane")

			mockImg.On("Clean", mock.MatchedBy(func(cfg provider.ImageCleanConfig) bool {
				return cfg.Nodes == ""
			})).Return(nil)

			err := cleanImages(cleanCmd, []string{})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertExpectations(GinkgoT())
		})
	})
})

func resetCleanFlags() {
	cleanCmd.Flags().Set(nodeFlagName, "")
	cleanCmd.Flags().Set(nodesFlagName, "")
}
