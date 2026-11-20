// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package setuprequired

import (
	"context"
	"time"

	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"
)

var suite *framework.K2sTestSuite
var k2s *dsl.K2s

func TestStart(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "start CLI Command Acceptance Tests", Label("cli", "start", "acceptance", "setup-required", "invasive"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemStateIrrelevant, framework.ClusterTestStepPollInterval(200*time.Millisecond))
	k2s = dsl.NewK2s(suite)

	DeferCleanup(suite.TearDown)
})

var _ = Describe("start", Ordered, func() {
	When("wrong K8s context is in use", func() {
		BeforeEach(func(ctx context.Context) {
			k2s.SetWrongK8sContext(ctx)

			DeferCleanup(k2s.ResetK8sContext)
		})

		It("fails", func(ctx context.Context) {
			result := k2s.Start(ctx)

			result.VerifyWrongK8sContextFailure()
		})
	})
})
