// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package registry

import (
	"errors"
	"os"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/stretchr/testify/mock"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("list", Ordered, func() {
	var mockImg *mockImageProvider
	var tempDir string

	BeforeAll(func() {
		listCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})

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

	When("running on Linux-only with multi-node selector", func() {
		It("rejects multi-node selector with actionable message", func() {
			tempDir = setupTestCmdContext(listCmd, mockImg, true, "control-plane")
			listCmd.Flags().Set(nodesFlag, "worker-1,worker-2")

			err := listRegistries(listCmd, []string{})

			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("multi-node selection 'worker-1,worker-2' is not supported on a Linux-only installation"))
			mockImg.AssertNotCalled(GinkgoT(), "RegistryList", mock.Anything, mock.Anything)
		})
	})

	When("no node selector is specified", func() {
		It("reads registries from config without calling ImageProvider.RegistryList", func() {
			tempDir = setupTestCmdContext(listCmd, mockImg, true, "control-plane")

			err := listRegistries(listCmd, []string{})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertNotCalled(GinkgoT(), "RegistryList", mock.Anything, mock.Anything)
		})
	})

	When("a valid node selector is specified", func() {
		It("routes through ImageProvider.RegistryList", func() {
			tempDir = setupTestCmdContext(listCmd, mockImg, false, "control-plane")
			listCmd.Flags().Set(nodesFlag, "worker-1,worker-2")

			mockImg.On("RegistryList", mock.Anything, provider.ImageRegistryListConfig{
				Nodes: []string{"worker-1", "worker-2"},
			}).Return([]string{"ghcr.io"}, nil)

			err := listRegistries(listCmd, []string{})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertExpectations(GinkgoT())
		})

		It("propagates provider errors", func() {
			tempDir = setupTestCmdContext(listCmd, mockImg, true, "control-plane")
			listCmd.Flags().Set(nodeFlag, "linux")

			mockImg.On("RegistryList", mock.Anything, provider.ImageRegistryListConfig{
				Nodes: []string{"linux"},
			}).Return(nil, errors.New("provider error"))

			err := listRegistries(listCmd, []string{})

			Expect(err).To(MatchError("provider error"))
			mockImg.AssertExpectations(GinkgoT())
		})
	})
})

func resetListFlags() {
	listCmd.Flags().Set(nodeFlag, "")
	listCmd.Flags().Set(nodesFlag, "")
}
