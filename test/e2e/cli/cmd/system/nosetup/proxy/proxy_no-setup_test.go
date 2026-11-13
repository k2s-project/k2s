// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package proxy

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

func TestProxy(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system proxy CLI Commands Acceptance Tests", Label("cli", "system", "proxy", "acceptance", "no-setup", "ci"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system proxy", func() {
	DescribeTable("print system-not-installed message and exits with non-zero", Label("cli", "ci", "system", "proxy", "acceptance", "no-setup"),
		func(ctx context.Context, args ...string) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, args...)

			Expect(output).To(ContainSubstring("not installed"))
		},
		Entry("set", "system", "proxy", "set", "http://dummy:8080"),
		Entry("get", "system", "proxy", "get"),
		Entry("show", "system", "proxy", "show"),
		Entry("reset", "system", "proxy", "reset"),
		Entry("override add", "system", "proxy", "override", "add", "example.com"),
		Entry("override delete", "system", "proxy", "override", "delete", "example.com"),
		Entry("override ls", "system", "proxy", "override", "ls"),
	)
})
