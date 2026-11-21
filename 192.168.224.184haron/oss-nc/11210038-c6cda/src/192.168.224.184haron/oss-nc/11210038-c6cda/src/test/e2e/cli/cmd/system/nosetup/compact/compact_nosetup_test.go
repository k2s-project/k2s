// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package compact

import (
	"context"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestCompactNoSetup(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system compact Acceptance Tests (no setup)",
		Label("system", "compact", "no-setup"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.NoSetupInstalled,
		framework.ClusterTestStepPollInterval(100*time.Millisecond),
		framework.ClusterTestStepTimeout(30*time.Second),
	)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system compact", func() {

	Describe("when K2s is not installed", func() {

		It("exits with failure and reports system-not-installed error", func(ctx context.Context) {
			output, _ := suite.K2sCli().
				ExpectedExitCode(cli.ExitCodeFailure).
				Exec(ctx, "system", "compact")

			Expect(output).To(SatisfyAny(
				ContainSubstring("not installed"),
				ContainSubstring("system is not installed"),
			))
		})

		It("exits with failure and reports system-not-installed error when --yes is passed", func(ctx context.Context) {
			output, _ := suite.K2sCli().
				ExpectedExitCode(cli.ExitCodeFailure).
				Exec(ctx, "system", "compact", "--yes")

			Expect(output).To(SatisfyAny(
				ContainSubstring("not installed"),
				ContainSubstring("system is not installed"),
			))
		})

		It("exits with failure and reports system-not-installed error when --no-restart is passed", func(ctx context.Context) {
			output, _ := suite.K2sCli().
				ExpectedExitCode(cli.ExitCodeFailure).
				Exec(ctx, "system", "compact", "--no-restart", "--yes")

			Expect(output).To(SatisfyAny(
				ContainSubstring("not installed"),
				ContainSubstring("system is not installed"),
			))
		})
	})
})

