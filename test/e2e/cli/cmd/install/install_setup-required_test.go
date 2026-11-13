// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0
package install

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

func TestInstall(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "install CLI Command Acceptance Tests", Label("cli", "install", "acceptance", "setup-required"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("install commands", func() {
	DescribeTable("print already-installed message and exits with non-zero",
		func(ctx context.Context, args ...string) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, args...)

			Expect(output).To(ContainSubstring("setup already installed"))
		},
		Entry(nil, "install"),
		Entry(nil, "install", "--linux-only"),
		Entry(nil, "install", "buildonly"),
	)
})
