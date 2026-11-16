// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package systemrunning

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

func TestAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons CLI Command Acceptance Tests when system is running", Label("acceptance", "cli", "cmd", "addons", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(200*time.Millisecond))

	DeferCleanup(suite.TearDown)
})

var _ = Describe("addons", Ordered, func() {
	Describe("export", Label("export"), func() {
		When("addon name is invalid", func() {
			It("prints addon-invalid message and exits with non-zero", func(ctx context.Context) {
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "export", "invalid-addon-name", "-d", "test-dir")

				Expect(output).To(Or(
					ContainSubstring("no addon with name"),
					ContainSubstring("is not available in Linux-only"),
				))
			})
		})
	})

	Describe("import", Label("import"), func() {
		When("addon name is invalid", func() {
			It("prints addon-invalid message and exits with non-zero", func(ctx context.Context) {
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "import", "invalid-addon-name", "-f", "test-dir")

				Expect(output).To(Or(
					ContainSubstring("is not available in Linux-only"),
					ContainSubstring("Unknown artifact format. Supported formats: .oci.tar"),
				))
			})
		})
	})
})
