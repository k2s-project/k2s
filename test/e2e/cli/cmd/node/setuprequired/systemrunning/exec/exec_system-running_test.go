// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package exec

import (
	"context"
	"math"
	"strconv"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"
)

var suite *framework.K2sTestSuite
var skipWinNodeTests bool

func TestExec(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "node exec Acceptance Tests", Label("cli", "node", "exec", "acceptance", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(100*time.Millisecond))

	// TODO: remove when adding Win nodes is supported
	skipWinNodeTests = true //suite.SetupInfo().SetupConfig.LinuxOnly
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("node exec", Ordered, func() {
	When("node is Linux node", Label("linux-node"), func() {
		const remoteUser = "remote"

		var nodeIpAddress string

		BeforeEach(func(ctx context.Context) {
			nodeIpAddress = suite.SetupInfo().Config.ControlPlane().IpAddress()

			GinkgoWriter.Println("Using control-plane node IP address <", nodeIpAddress, ">")
		})

		When("command execution succeeds", func() {
			When("output is standard", func() {
				It("prints standard output and exits with exit code zero", func(ctx context.Context) {
					output := suite.K2sCli().MustExec(ctx, "node", "exec", "-i", nodeIpAddress, "-u", remoteUser, "-c", "echo 'Hello, world!'", "-o")

					Expect(output).To(SatisfyAll(
						MatchRegexp("Hello, world!"),
						MatchRegexp("SUCCESS"),
					))
				})
			})

			When("output is raw", func() {
				It("prints raw output only and exits with exit code zero", func(ctx context.Context) {
					output := suite.K2sCli().MustExec(ctx, "node", "exec", "-i", nodeIpAddress, "-u", remoteUser, "-c", "echo 'Hello, world!'", "-r", "-o")

					Expect(output).To(Equal("Hello, world!\n"))
				})
			})
		})

		When("command execution fails", func() {
			It("prints the output and exits with non-zero exit code", func(ctx context.Context) {
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "exec", "-i", nodeIpAddress, "-u", remoteUser, "-c", "mkdir /this/should/not/exist", "-o")

				Expect(output).To(MatchRegexp("cannot create directory"))
			})
		})
	})

	When("node is Windows node", Label("windows-node"), func() {
		const remoteUser = "administrator"

		var nodeIpAddress string

		BeforeEach(func(ctx context.Context) {
			if skipWinNodeTests {
				Skip("Windows node tests are skipped")
			}

			// TODO: set when adding Win nodes is supported
			nodeIpAddress = ""

			GinkgoWriter.Println("Using windows node IP address <", nodeIpAddress, ">")
		})

		When("command execution succeeds", func() {
			When("output is standard", func() {
				It("prints standard output and exits with exit code zero", func(ctx context.Context) {
					output := suite.K2sCli().MustExec(ctx, "node", "exec", "-i", nodeIpAddress, "-u", remoteUser, "-c", "echo 'Hello, world!'", "-o")

					Expect(output).To(SatisfyAll(
						MatchRegexp("Hello, world!"),
						MatchRegexp("SUCCESS"),
					))
				})
			})

			When("output is raw", func() {
				It("prints raw output only and exits with exit code zero", func(ctx context.Context) {
					output := suite.K2sCli().MustExec(ctx, "node", "exec", "-i", nodeIpAddress, "-u", remoteUser, "-c", "echo 'Hello, world!'", "-r", "-o")

					Expect(output).To(Equal("Hello, world!\n"))
				})
			})
		})

		When("command execution fails", func() {
			It("prints the output and exits with non-zero exit code", func(ctx context.Context) {
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "exec", "-i", nodeIpAddress, "-u", remoteUser, "-c", "non-existing-cmd", "-o")

				Expect(output).To(MatchRegexp("not recognized"))
			})
		})
	})

	When("checking time synchronization", Label("time-sync"), func() {
		It("control plane VM clock is within 30 seconds of the Windows host clock", func(ctx context.Context) {
			nodeIpAddress := suite.SetupInfo().Config.ControlPlane().IpAddress()

			// Get the VM's current UTC epoch seconds
			output := suite.K2sCli().MustExec(ctx, "node", "exec", "-i", nodeIpAddress, "-u", "remote", "-c", "date -u +%s", "-r", "-o")
			vmEpochStr := strings.TrimSpace(output)

			vmEpoch, err := strconv.ParseInt(vmEpochStr, 10, 64)
			Expect(err).ToNot(HaveOccurred(), "failed to parse VM epoch time: %s", vmEpochStr)

			// Get the host's current UTC epoch seconds
			hostEpoch := time.Now().UTC().Unix()

			drift := math.Abs(float64(hostEpoch - vmEpoch))

			GinkgoWriter.Printf("Host UTC epoch: %d, VM UTC epoch: %d, drift: %.0f seconds\n", hostEpoch, vmEpoch, drift)

			Expect(drift).To(BeNumerically("<=", 30), "VM clock drift from host should be at most 30 seconds, but was %.0f seconds", drift)
		})
	})
})
