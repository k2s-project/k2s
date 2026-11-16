// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/test/framework"

	"github.com/k2s-project/k2s/internal/cli"
)

var suite *framework.K2sTestSuite

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "CLI Acceptance Tests", Label("cli", "acceptance", "no-setup", "ci"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("CLI", func() {
	Describe("exit behavior", Ordered, func() {
		When("error happened while CLI executions", func() {
			It("prints the error and exits with non-zero", func(ctx context.Context) {
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "invalid", "command")

				Expect(output).To(SatisfyAll(
					ContainSubstring("ERROR"),
					ContainSubstring(`unknown command "invalid"`),
				))
			})
		})

		When("CLI execution successful", func() {
			It("prints no error", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "ls")

				Expect(output).ToNot(ContainSubstring("ERROR"))
				Expect(output).To(ContainSubstring("Available Addons"))
			})
		})

		When("non-leaf command is issued", func() {
			It("prints help without errors", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons")

				Expect(output).ToNot(ContainSubstring("ERROR"))
				Expect(output).To(ContainSubstring("Addons add optional functionality"))
			})
		})

		When("help flag is used", func() {
			It("prints help without errors", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "ls", "-h")

				Expect(output).ToNot(ContainSubstring("ERROR"))
				Expect(output).To(ContainSubstring("List addons available"))
			})
		})
	})
})
