// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package setuprequired

import (
	"context"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"
)

var suite *framework.K2sTestSuite
var k2s *dsl.K2s

func TestImage(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "image CLI Commands Acceptance Tests", Label("cli", "image", "acceptance", "setup-required"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemStateIrrelevant, framework.ClusterTestStepPollInterval(200*time.Millisecond))
	k2s = dsl.NewK2s(suite)

	DeferCleanup(suite.TearDown)
})

var _ = Describe("image", func() {
	Describe("registry", Label("registry"), func() {
		Describe("ls", Label("ls"), func() {
			It("runs without error", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "image", "registry", "ls")

				Expect(output).To(SatisfyAny(
					ContainSubstring("No registries configured"),
					ContainSubstring("Configured registries"),
				))
			})
		})
	})

	Describe("rm", Label("rm", "invasive"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k2s.SetWrongK8sContext(ctx)

				DeferCleanup(k2s.ResetK8sContext)
			})

			It("fails with wrong K8s context warning", func(ctx context.Context) {
				result := k2s.RemoveImage(ctx)

				result.VerifyWrongK8sContextFailure()
			})
		})

		When("validating command availability across setups", func() {
			It("is supported and does not fail with functionality not available", func(ctx context.Context) {
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "image", "rm")

				Expect(output).ToNot(ContainSubstring("functionality is not available"))
			})
		})
	})
})
