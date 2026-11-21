// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package start_test

import (
	"errors"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/pterm/pterm"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/start"
	"github.com/spf13/cobra"
)

func TestStartCmd(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Start Command Tests", Label("unit", "ci", "start"))
}

var _ = BeforeSuite(func() {
	pterm.DisableOutput()
})

var _ = Describe("HandleIgnoreIfRunning", func() {
	var (
		cmd                  *cobra.Command
		mockClusterIsRunning func() (bool, error)
	)

	BeforeEach(func() {
		cmd = &cobra.Command{}
		cmd.Flags().BoolP(common.IgnoreIfRunningFlagName, common.IgnoreIfRunningFlagShort, false, "")
	})

	When("IgnoreIfRunning is false", Label("unit"), func() {
		BeforeEach(func() {
			cmd.Flags().Set(common.IgnoreIfRunningFlagName, "false")
			mockClusterIsRunning = func() (bool, error) {
				return false, nil
			}
		})

		It("does not skip and returns no error", func() {
			skip, err := start.HandleIgnoreIfRunning(cmd, mockClusterIsRunning)
			Expect(skip).To(BeFalse())
			Expect(err).ToNot(HaveOccurred())
		})
	})

	When("Cluster is running and IgnoreIfRunning is true", Label("unit"), func() {
		BeforeEach(func() {
			cmd.Flags().Set(common.IgnoreIfRunningFlagName, "true")
			mockClusterIsRunning = func() (bool, error) {
				return true, nil
			}
		})

		It("skips and returns no error", func() {
			skip, err := start.HandleIgnoreIfRunning(cmd, mockClusterIsRunning)
			Expect(skip).To(BeTrue())
			Expect(err).ToNot(HaveOccurred())
		})
	})

	When("Cluster is not running and IgnoreIfRunning is true", Label("unit"), func() {
		BeforeEach(func() {
			cmd.Flags().Set(common.IgnoreIfRunningFlagName, "true")
			mockClusterIsRunning = func() (bool, error) {
				return false, nil
			}
		})

		It("does not skip and returns no error", func() {
			skip, err := start.HandleIgnoreIfRunning(cmd, mockClusterIsRunning)
			Expect(skip).To(BeFalse())
			Expect(err).ToNot(HaveOccurred())
		})
	})

	When("Error occurs while checking cluster status", Label("unit"), func() {
		BeforeEach(func() {
			cmd.Flags().Set(common.IgnoreIfRunningFlagName, "true")
			mockClusterIsRunning = func() (bool, error) {
				return false, errors.New("failed to check cluster status")
			}
		})

		It("does not skip and returns the error", func() {
			skip, err := start.HandleIgnoreIfRunning(cmd, mockClusterIsRunning)
			Expect(skip).To(BeFalse())
			Expect(err).To(MatchError("failed to check cluster status"))
		})
	})
})
