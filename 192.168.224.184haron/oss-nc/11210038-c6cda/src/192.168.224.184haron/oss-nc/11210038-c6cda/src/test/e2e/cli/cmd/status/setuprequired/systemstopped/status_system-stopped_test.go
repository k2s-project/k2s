// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0
package systemstopped

import (
	"context"
	"encoding/json"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/status"

	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/regex"
)

var suite *framework.K2sTestSuite

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "status CLI Command Acceptance Tests", Label("cli", "status", "acceptance", "setup-required", "invasive", "setup=k2s", "system-stopped"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeStopped)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("status", Ordered, func() {
	Context("default output", func() {
		var output string

		BeforeAll(func(ctx context.Context) {
			output = suite.K2sCli().MustExec(ctx, "status")
		})

		It("prints a header", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("K2s SYSTEM STATUS"))
		})

		It("prints setup", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("Setup: .+%s.+,", suite.SetupInfo().RuntimeConfig.InstallConfig().SetupName()))
		})

		It("prints version", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("Version: .+%s.+", regex.VersionRegex))
		})

		It("states that system is not running with details about what is not running", func(ctx context.Context) {
			// TODO: cater to multiple nodes
			Expect(output).To(SatisfyAll(ContainSubstring("The system is stopped."),
				ContainSubstring("control-plane 'kubemaster' not running, state is 'Off' (VM)"),
				ContainSubstring("'flanneld' not running (service)"),
				ContainSubstring("'kubelet' not running (service)"),
				ContainSubstring("'kubeproxy' not running (service)")))
		})
	})

	Context("extended output", func() {
		var output string

		BeforeAll(func(ctx context.Context) {
			output = suite.K2sCli().MustExec(ctx, "status", "-o", "wide")
		})

		It("prints a header", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("K2s SYSTEM STATUS"))
		})

		It("prints setup", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("Setup: .+%s.+,", suite.SetupInfo().RuntimeConfig.InstallConfig().SetupName()))
		})

		It("prints version", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("Version: .+%s.+", regex.VersionRegex))
		})

		It("states that system is not running with details about what is not running", func(ctx context.Context) {
			// TODO: cater to multiple nodes
			Expect(output).To(SatisfyAll(ContainSubstring("The system is stopped."),
				ContainSubstring("control-plane 'kubemaster' not running, state is 'Off' (VM)"),
				ContainSubstring("'flanneld' not running (service)"),
				ContainSubstring("'kubelet' not running (service)"),
				ContainSubstring("'kubeproxy' not running (service)")))
		})
	})

	Context("json output", func() {
		var status status.PrintStatus

		BeforeAll(func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "status", "-o", "json")

			Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())
		})

		It("contains setup info", func() {
			Expect(status.SetupInfo.Name).To(Equal(suite.SetupInfo().RuntimeConfig.InstallConfig().SetupName()))
			Expect(status.SetupInfo.Version).To(MatchRegexp(regex.VersionRegex))
			Expect(status.SetupInfo.LinuxOnly).To(Equal(suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly()))
		})

		It("contains running state", func() {
			Expect(status.RunningState.IsRunning).To(BeFalse())
			Expect(status.RunningState.Issues).To(ContainElements(
				ContainSubstring("not running, state is 'Off' (VM)"),
				ContainSubstring("'flanneld' not running (service)"),
				ContainSubstring("'kubelet' not running (service)"),
				ContainSubstring("'kubeproxy' not running (service)"),
			))
		})

		It("does not contain any other info", func() {
			Expect(status.Nodes).To(BeNil())
			Expect(status.Pods).To(BeNil())
			Expect(status.K8sVersionInfo).To(BeNil())
			Expect(status.Error).To(BeNil())
		})
	})
})
