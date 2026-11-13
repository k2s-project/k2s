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

var _ = Describe("add", Ordered, func() {
	var mockImg *mockImageProvider
	var tempDir string

	BeforeAll(func() {
		addCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})

	BeforeEach(func() {
		mockImg = &mockImageProvider{}
		resetAddFlags()
		DeferCleanup(resetAddFlags)
	})

	AfterEach(func() {
		if tempDir != "" {
			_ = os.RemoveAll(tempDir)
		}
	})

	When("no registry passed in args", func() {
		It("returns error", func() {
			err := addRegistry(addCmd, []string{})

			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("no registry passed in CLI"))
		})
	})

	When("running on Linux-only with multi-node selector", func() {
		It("rejects multi-node selector with actionable message", func() {
			tempDir = setupTestCmdContext(addCmd, mockImg, true, "control-plane")
			addCmd.Flags().Set(nodesFlag, "worker-1,worker-2")

			err := addRegistry(addCmd, []string{"ghcr.io"})

			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("multi-node selection 'worker-1,worker-2' is not supported on a Linux-only installation"))
		})
	})

	When("running on Linux-only with valid flags", func() {
		It("routes to provider Image.RegistryAdd", func() {
			tempDir = setupTestCmdContext(addCmd, mockImg, true, "control-plane")
			addCmd.Flags().Set(usernameFlag, "testuser")
			addCmd.Flags().Set(passwordFlag, "testpass")
			addCmd.Flags().Set(skipVerifyFlag, "true")
			addCmd.Flags().Set(plainHttpFlag, "true")

			mockImg.On("RegistryAdd", mock.MatchedBy(func(cfg provider.ImageRegistryAddConfig) bool {
				return cfg.RegistryName == "ghcr.io" &&
					cfg.Username == "testuser" &&
					cfg.Password == "testpass" &&
					cfg.SkipVerify &&
					cfg.PlainHttp
			})).Return(nil)

			err := addRegistry(addCmd, []string{"ghcr.io"})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertExpectations(GinkgoT())
		})
	})
})

func resetAddFlags() {
	addCmd.Flags().Set(usernameFlag, "")
	addCmd.Flags().Set(passwordFlag, "")
	addCmd.Flags().Set(skipVerifyFlag, "false")
	addCmd.Flags().Set(plainHttpFlag, "false")
	addCmd.Flags().Set(nodeFlag, "")
	addCmd.Flags().Set(nodesFlag, "")
}
