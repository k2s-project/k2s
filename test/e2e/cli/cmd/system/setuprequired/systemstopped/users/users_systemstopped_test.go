// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package users

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

func TestUsers(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system users Acceptance Tests", Label("cli", "system", "users", "acceptance", "setup-required", "system-stopped"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeStopped, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system users", func() {
	When("system stopped", func() {
		It("prints system-stopped message and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "system", "users", "add", "-u", "non-existent")

			Expect(output).To(SatisfyAll(
				ContainSubstring("WARNING"),
				ContainSubstring("system is stopped"),
			))
		})
	})
})
