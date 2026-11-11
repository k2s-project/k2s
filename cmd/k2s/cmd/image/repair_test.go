// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"os"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/provider"
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
	})
})

func resetRepairFlags() {
	repairCmd.Flags().Set(common.OutputFlagName, "false")
}
