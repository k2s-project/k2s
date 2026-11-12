// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"os"
	"path/filepath"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/k2s-project/k2s/internal/providers/kubeconfig"
	"github.com/stretchr/testify/mock"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("repair", Ordered, func() {
	var mockImg *mockImageProvider
	var tempDir string

	BeforeAll(func() {
		repairCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})

	BeforeEach(func() {
		mockImg = &mockImageProvider{}
		resetRepairFlags()
		DeferCleanup(resetRepairFlags)
	})

	AfterEach(func() {
		if tempDir != "" {
			_ = os.RemoveAll(tempDir)
		}
	})

	When("K2s is installed", func() {
		It("routes to provider Image.Repair without output", func() {
			tempDir = setupTestCmdContext(repairCmd, mockImg, false, "control-plane")

			mockImg.On("Repair", mock.MatchedBy(func(cfg provider.ImageRepairConfig) bool {
				return !cfg.ShowOutput
			})).Return(nil)

			err := repairImages(repairCmd, []string{})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertExpectations(GinkgoT())
		})

		It("passes the output flag to the provider", func() {
			tempDir = setupTestCmdContext(repairCmd, mockImg, false, "control-plane")
			repairCmd.Flags().Set(common.OutputFlagName, "true")

			mockImg.On("Repair", mock.MatchedBy(func(cfg provider.ImageRepairConfig) bool {
				return cfg.ShowOutput
			})).Return(nil)

			err := repairImages(repairCmd, []string{})

			Expect(err).ToNot(HaveOccurred())
			mockImg.AssertExpectations(GinkgoT())
		})

		It("returns the provider error", func() {
			tempDir = setupTestCmdContext(repairCmd, mockImg, false, "control-plane")
			expectedErr := errors.New("repair failed")

			mockImg.On("Repair", mock.Anything).Return(expectedErr)

			err := repairImages(repairCmd, []string{})

			Expect(err).To(MatchError(expectedErr))
		})

		It("refuses to repair when another kubectl context is current", func() {
			tempDir = setupTestCmdContext(repairCmd, mockImg, false, "control-plane")
			otherContext := `apiVersion: v1
kind: Config
current-context: other-context
contexts:
- context:
    cluster: k2s
    user: test-user
  name: k2s-context
- context:
    cluster: other
    user: other-user
  name: other-context
`
			Expect(os.WriteFile(filepath.Join(tempDir, kubeconfig.DefaultFileName), []byte(otherContext), 0644)).To(Succeed())

			err := repairImages(repairCmd, []string{})

			var cmdFailure *common.CmdFailure
			Expect(errors.As(err, &cmdFailure)).To(BeTrue())
			Expect(cmdFailure.Code).To(Equal("not-k2s-context"))
			mockImg.AssertNotCalled(GinkgoT(), "Repair", mock.Anything)
		})
	})
})

func resetRepairFlags() {
	repairCmd.Flags().Set(common.OutputFlagName, "false")
}
