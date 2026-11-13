// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0
package nosetup

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/image"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestImage(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "image CLI Commands Acceptance Tests", Label("cli", "image", "acceptance", "no-setup", "ci"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("image", func() {
	DescribeTable("print system-not-installed message and exits with non-zero",
		func(ctx context.Context, args ...string) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, args...)

			Expect(output).To(ContainSubstring("not installed"))
		},
		Entry("build", "image", "build"),
		Entry("clean", "image", "clean"),
		Entry("export", "image", "export", "-n", "non-existent", "-t", "non-existent"),
		Entry("import", "image", "import", "-t", "non-existent"),
		Entry("ls default output", "image", "ls"),
		Entry("pull", "image", "pull", "non-existent"),
		Entry("push", "image", "push", "-n", "non-existent"),
		Entry("tag", "image", "tag", "-n", "non-existent", "-t", "non-existent"),
		Entry("registry add", "image", "registry", "add", "non-existent"),
		Entry("registry ls", "image", "registry", "ls"),
		Entry("rm", "image", "rm", "--id", "non-existent"),
	)

	DescribeTable("with node selection flags: print system-not-installed message and exits with non-zero",
		func(ctx context.Context, args ...string) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, args...)

			Expect(output).To(ContainSubstring("not installed"))
		},
		Entry("export --node", "image", "export", "--node", "worker-1", "-n", "non-existent", "-t", "non-existent"),
		Entry("export --nodes", "image", "export", "--nodes", "worker-1,worker-2", "-n", "non-existent", "-t", "non-existent"),
		Entry("import --node", "image", "import", "--node", "worker-1", "-t", "non-existent"),
		Entry("import --nodes", "image", "import", "--nodes", "worker-1,worker-2", "-t", "non-existent"),
		Entry("ls --node", "image", "ls", "--node", "worker-1"),
		Entry("ls --nodes", "image", "ls", "--nodes", "worker-1,worker-2"),
		Entry("pull --node", "image", "pull", "non-existent", "--node", "worker-1"),
		Entry("pull --nodes", "image", "pull", "non-existent", "--nodes", "worker-1,worker-2"),
		Entry("push --node", "image", "push", "-n", "non-existent", "--node", "worker-1"),
		Entry("push --nodes", "image", "push", "-n", "non-existent", "--nodes", "worker-1,worker-2"),
		Entry("rm --node", "image", "rm", "--id", "non-existent", "--node", "worker-1"),
		Entry("rm --nodes", "image", "rm", "--id", "non-existent", "--nodes", "worker-1,worker-2"),
		Entry("tag --node", "image", "tag", "-n", "non-existent", "-t", "non-existent", "--node", "worker-1"),
		Entry("tag --nodes", "image", "tag", "-n", "non-existent", "-t", "non-existent", "--nodes", "worker-1,worker-2"),
	)

	Describe("ls JSON output", Ordered, func() {
		var images image.PrintImages

		BeforeAll(func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "image", "ls", "-o", "json")

			Expect(json.Unmarshal([]byte(output), &images)).To(Succeed())
		})

		It("contains only system-not-installed info and exits with non-zero", func() {
			Expect(images.ContainerImages).To(BeNil())
			Expect(images.ContainerRegistry).To(BeNil())
			Expect(images.PushedImages).To(BeNil())
			Expect(*images.Error).To(Equal(config.ErrSystemNotInstalled.Error()))
		})
	})
})
