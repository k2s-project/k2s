// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package registry

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
		rmCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})

	BeforeEach(func() {
		mockImg = &mockImageProvider{}
		resetRmFlags()
		DeferCleanup(resetRmFlags)
	})

	AfterEach(func() {
		if tempDir != "" {
			_ = os.RemoveAll(tempDir)
		}
	})

	When("no registry passed in args", func() {
		It("returns error", func() {
			err := removeRegistry(rmCmd, []string{})

			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("no registry passed in CLI"))
		})
	})

	When("running on Linux-only with multi-node selector", func() {
		It("rejects multi-node selector with actionable message", func() {
			tempDir = setupTestCmdContext(rmCmd, mockImg, true, "control-plane")
			rmCmd.Flags().Set(nodesFlag, "worker-1,worker-2")

			err := removeRegistry(rmCmd, []string{"ghcr.io"})

			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("multi-node selection 'worker-1,worker-2' is not supported on a Linux-only installation"))
		})
	})

	When("running on Linux-only with valid flags", func() {
		It("routes to provider Image.RegistryRemove", func() {
			tempDir = setupTestCmdContext(rmCmd, mockImg, true, "control-plane")

			mockImg.On("RegistryRemove", mock.MatchedBy(func(cfg provider.ImageRegistryRemoveConfig) bool {
				return cfg.RegistryName == "ghcr.io"
			})).Return(nil)

			err := removeRegistry(rmCmd, []string{"ghcr.io"})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertExpectations(GinkgoT())
		})
	})
})

func resetRmFlags() {
	rmCmd.Flags().Set(nodeFlag, "")
	rmCmd.Flags().Set(nodesFlag, "")
}
