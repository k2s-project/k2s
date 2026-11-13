// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package registry

import (
	"os"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

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
		})
	})

	When("running on Linux-only with no registries configured", func() {
		It("succeeds without calling PowerShell", func() {
			tempDir = setupTestCmdContext(listCmd, mockImg, true, "control-plane")

			err := listRegistries(listCmd, []string{})

			Expect(err).ToNot(HaveOccurred())
		})
	})

	When("running on Linux-only with valid node selector", func() {
		It("succeeds without calling PowerShell", func() {
			tempDir = setupTestCmdContext(listCmd, mockImg, true, "control-plane")
			listCmd.Flags().Set(nodeFlag, "linux")

			err := listRegistries(listCmd, []string{})

			Expect(err).ToNot(HaveOccurred())
		})
	})
})

func resetListFlags() {
	listCmd.Flags().Set(nodeFlag, "")
	listCmd.Flags().Set(nodesFlag, "")
}
