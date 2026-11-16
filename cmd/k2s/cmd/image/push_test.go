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

var _ = Describe("push", Ordered, func() {
	var mockImg *mockImageProvider
	var tempDir string

	BeforeAll(func() {
		pushCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})

	BeforeEach(func() {
		mockImg = &mockImageProvider{}
		resetPushFlags()
		DeferCleanup(resetPushFlags)
	})

	AfterEach(func() {
		if tempDir != "" {
			_ = os.RemoveAll(tempDir)
		}
	})

	When("neither id nor name is provided", func() {
		It("returns error", func() {
			err := pushImage(pushCmd, []string{})

			Expect(err).To(MatchError("no image id or image name provided"))
		})
	})

	When("running on Linux-only with multi-node selector", func() {
		It("rejects multi-node selector with actionable message", func() {
			tempDir = setupTestCmdContext(pushCmd, mockImg, true, "control-plane")
			pushCmd.Flags().Set(imageNameFlagName, "myimage:v1")
			pushCmd.Flags().Set(nodesFlagName, "worker-1,worker-2")

			err := pushImage(pushCmd, []string{})

			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("multi-node selection 'worker-1,worker-2' is not supported on a Linux-only installation"))
		})
	})

	When("running on Linux-only with valid options", func() {
		It("routes to provider Image.Push", func() {
			tempDir = setupTestCmdContext(pushCmd, mockImg, true, "control-plane")
			pushCmd.Flags().Set(imageNameFlagName, "myimage:v1")

			mockImg.On("Push", mock.MatchedBy(func(cfg provider.ImagePushConfig) bool {
				return cfg.ImageName == "myimage:v1"
			})).Return(nil)

			err := pushImage(pushCmd, []string{})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertExpectations(GinkgoT())
		})
	})
})

func resetPushFlags() {
	pushCmd.Flags().Set(imageIdFlagName, "")
	pushCmd.Flags().Set(imageNameFlagName, "")
	pushCmd.Flags().Set(nodeFlagName, "")
	pushCmd.Flags().Set(nodesFlagName, "")
}
