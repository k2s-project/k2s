// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package compact

import (
	"context"
	"os"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestCompactSystemStopped(t *testing.T) {
	os.Setenv("SYSTEM_TEST_TIMEOUT", "20m")
	RegisterFailHandler(Fail)
	RunSpecs(t, "system compact Acceptance Tests (system stopped)",
		Label("system", "compact", "system-stopped"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeStopped,
		framework.ClusterTestStepPollInterval(500*time.Millisecond),
		framework.ClusterTestStepTimeout(20*time.Minute),
	)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

func skipIfUnsupportedSetup() {
	ic := suite.SetupInfo().RuntimeConfig.InstallConfig()
	if ic.WslEnabled() {
		Skip("skipped: compact is not available for WSL-based setup")
	}
	if ic.SetupName() == definitions.SetupNameBuildOnlyEnv {
		Skip("skipped: compact is not available for build-only setup")
	}
}

var _ = Describe("system compact", Ordered, func() {

	Describe("when system is already stopped", Ordered, func() {

		BeforeEach(func() {
			skipIfUnsupportedSetup()
		})

		It("skips fstrim, skips cluster stop, compacts VHDX and does not restart", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "system", "compact", "--yes")

			Expect(output).To(SatisfyAll(
				ContainSubstring("VM is not running. Skipping fstrim"),
				ContainSubstring("Cluster is already stopped"),
				ContainSubstring("Optimizing VHDX"),
				ContainSubstring("Optimization completed"),
				ContainSubstring("VHDX compaction completed successfully"),
			))
		})

		It("does not attempt to stop or restart the cluster when already stopped", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "system", "compact", "--yes")

			Expect(output).NotTo(ContainSubstring("Stopping cluster"))
			Expect(output).NotTo(ContainSubstring("Restarting cluster"))
			Expect(output).To(ContainSubstring("Cluster was not running. Not restarting"))
		})

		It("reports before/after size and space saved", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "system", "compact", "--yes")

			Expect(output).To(SatisfyAll(
				ContainSubstring("Before:"),
				ContainSubstring("After:"),
				ContainSubstring("Saved:"),
				ContainSubstring("Compaction Results"),
			))
		})

		It("leaves the cluster in a stopped state after compaction", func(ctx context.Context) {
			Expect(suite.StatusChecker().IsK2sRunning(ctx)).To(BeFalse())
		})
	})

	Describe("when system is stopped and --no-restart is specified", Ordered, func() {

		BeforeEach(func() {
			skipIfUnsupportedSetup()
		})

		It("completes successfully", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "system", "compact", "--yes", "--no-restart")

			Expect(output).To(SatisfyAll(
				ContainSubstring("VM is not running. Skipping fstrim"),
				ContainSubstring("Cluster is already stopped"),
				ContainSubstring("Optimizing VHDX"),
				ContainSubstring("VHDX compaction completed successfully"),
			))
		})
	})
})

