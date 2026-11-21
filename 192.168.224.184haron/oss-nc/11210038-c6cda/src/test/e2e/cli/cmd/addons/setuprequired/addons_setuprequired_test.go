// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package setuprequired

import (
	"context"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	ka "github.com/k2s-project/k2s/internal/core/addons"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"
	"github.com/k2s-project/k2s/test/framework/k2s/addons"
)

var (
	suite     *framework.K2sTestSuite
	allAddons ka.Addons
	k2s       *dsl.K2s
)

func TestAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons CLI Command Acceptance Tests when setup is installed", Label("acceptance", "cli", "cmd", "addons", "setup-required"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemStateIrrelevant, framework.ClusterTestStepPollInterval(200*time.Millisecond))
	allAddons = suite.AddonsAdditionalInfo().AllAddons()
	k2s = dsl.NewK2s(suite)

	DeferCleanup(suite.TearDown)
})

var _ = Describe("addons", Ordered, func() {
	Describe("ls", Label("ls"), func() {
		var output string

		BeforeAll(func(ctx context.Context) {
			output = suite.K2sCli().MustExec(ctx, "addons", "ls")
		})

		It("prints the header", func() {
			Expect(output).To(ContainSubstring("Available Addons"))
		})

		It("prints the addons with enabled/disabled status", func() {
			Expect(output).To(SatisfyAll(
				ContainSubstring("Addons"),
				ContainSubstring("Enabled"),
				ContainSubstring("Disabled"),
			))

			lines := strings.Split(output, "\n")

			for _, addon := range allAddons {
				Expect(lines).To(ContainElement(SatisfyAll(
					ContainSubstring(addon.Metadata.Name),
					ContainSubstring(addon.Metadata.Description),
				)))
			}
		})
	})

	Describe("status", Label("status", "invasive"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k2s.SetWrongK8sContext(ctx)

				DeferCleanup(k2s.ResetK8sContext)
			})

			It("fails", func(ctx context.Context) {
				addons.Foreach(allAddons, func(addonName, implementationName, _ string) {
					result := k2s.ShowAddonStatus(ctx, addonName, implementationName)

					result.VerifyWrongK8sContextFailure()
				})
			})
		})
	})

	Describe("enable", Label("enable", "invasive"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k2s.SetWrongK8sContext(ctx)

				DeferCleanup(k2s.ResetK8sContext)
			})

			It("fails", func(ctx context.Context) {
				addons.Foreach(allAddons, func(addonName, implementationName, _ string) {
					result := k2s.EnableAddon(ctx, addonName, implementationName)

					result.VerifyWrongK8sContextFailure()
				})
			})
		})
	})

	Describe("disable", Label("disable", "invasive"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k2s.SetWrongK8sContext(ctx)

				DeferCleanup(k2s.ResetK8sContext)
			})

			It("fails", func(ctx context.Context) {
				addons.Foreach(allAddons, func(addonName, implementationName, _ string) {
					result := k2s.DisableAddon(ctx, addonName, implementationName)

					result.VerifyWrongK8sContextFailure()
				})
			})
		})
	})
})
