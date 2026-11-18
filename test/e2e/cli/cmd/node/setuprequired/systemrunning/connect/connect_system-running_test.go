// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package connect

import (
	"context"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gbytes"
	"github.com/onsi/gomega/gexec"

	"github.com/shirou/gopsutil/v3/process"
	"github.com/k2s-project/k2s/test/framework"
)

const (
	connectionTimeout = 10 * time.Second
	manualTag         = "manual"
)

var (
	suite                         *framework.K2sTestSuite
	skipWinNodeTests              bool
	isManualExecution             = false
	automatedExecutionSkipMessage = fmt.Sprintf("can only be run using the filter value '%s'", manualTag)
)

func TestConnect(t *testing.T) {
	labels := []string{"cli", "node", "connect", "acceptance", "setup-required", "system-running"}
	userSuppliedLabels := GinkgoLabelFilter()
	if strings.Compare(userSuppliedLabels, "") != 0 {
		if Label(manualTag).MatchesLabelFilter(userSuppliedLabels) {
			isManualExecution = true
			labels = append(labels, manualTag)
		}
	}

	RegisterFailHandler(Fail)
	RunSpecs(t, "node connect Acceptance Tests", Label(labels...))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(100*time.Millisecond))

	// TODO: remove when adding Win nodes is supported
	skipWinNodeTests = true //suite.SetupInfo().SetupConfig.LinuxOnly
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("node connect", Ordered, func() {
	When("node is Linux node", Label("linux-node"), func() {
		const remoteUser = "remote"

		var nodeIpAddress string

		BeforeEach(func(ctx context.Context) {
			if !isManualExecution {
				Skip(automatedExecutionSkipMessage)
			}

			nodeIpAddress = suite.SetupInfo().Config.ControlPlane().IpAddress()

			GinkgoWriter.Println("Using control-plane node IP address <", nodeIpAddress, ">")
		})

		It("connects via SSH successfully", func(ctx context.Context) {
			inputReader, inputWriter := io.Pipe()

			cmd := exec.CommandContext(ctx, suite.K2sCli().Path(), "node", "connect", "-i", nodeIpAddress, "-u", remoteUser, "-o")
			cmd.Stdin = inputReader

			session, err := gexec.Start(cmd, GinkgoWriter, GinkgoWriter)
			Expect(err).NotTo(HaveOccurred())

			GinkgoWriter.Println("Waiting for pseuto terminal to be ready")

			Eventually(ctx, session).WithTimeout(connectionTimeout).Should(gbytes.Say(remoteUser + "@.+"))

			GinkgoWriter.Println("Closing pseudo terminal")

			_, err = inputWriter.Write([]byte("logout\n"))
			Expect(err).NotTo(HaveOccurred())

			Expect(inputWriter.Close()).To(Succeed())

			GinkgoWriter.Println("Waiting for pseudo terminal to be closed")

			Eventually(ctx, session).WithTimeout(time.Second * 5).Should(gbytes.Say(`logout`))
			Eventually(ctx, session).WithTimeout(time.Second * 5).Should(gbytes.Say(`'k2s node connect' completed`))
			Eventually(ctx, session).WithTimeout(time.Second * 5).Should(gexec.Exit(0))
		})
	})

	When("node is Windows node", Label("windows-node"), func() {
		const remoteUser = "administrator"

		var nodeIpAddress string

		BeforeEach(func(ctx context.Context) {
			if !isManualExecution {
				Skip(automatedExecutionSkipMessage)
			}
			if skipWinNodeTests {
				Skip("Windows node tests are disabled")
			}

			// TODO: remove when adding Win nodes is supported
			nodeIpAddress = "" //k2s.GetWindowsNode(suite.SetupInfo().Config.Nodes()).IpAddress()

			GinkgoWriter.Println("Using windows node IP address <", nodeIpAddress, ">")
		})

		It("connects via SSH successfully", func(ctx context.Context) {
			inputReader, inputWriter := io.Pipe()

			cmd := exec.CommandContext(ctx, suite.K2sCli().Path(), "node", "connect", "-i", nodeIpAddress, "-u", remoteUser, "-o")
			cmd.Stdin = inputReader

			session, err := gexec.Start(cmd, GinkgoWriter, GinkgoWriter)
			Expect(err).NotTo(HaveOccurred())

			GinkgoWriter.Println("Waiting for pseuto terminal to be ready")

			Eventually(ctx, session).WithTimeout(connectionTimeout).Should(gbytes.Say(remoteUser + "@.+"))

			GinkgoWriter.Println("\nClosing pseudo terminal")

			_, err = inputWriter.Write([]byte("exit\n"))
			Expect(err).NotTo(HaveOccurred())

			Expect(inputWriter.Close()).To(Succeed())

			GinkgoWriter.Println("Killing ssh.exe child process") // otherwise, process remains active in automated tests on Windows terminal

			k2sProcess, err := process.NewProcess(int32(cmd.Process.Pid))
			Expect(err).NotTo(HaveOccurred())

			GinkgoWriter.Println("K2s process ID =", k2sProcess.Pid)

			k2sChildProcesses, err := k2sProcess.Children()
			Expect(err).NotTo(HaveOccurred())

			for _, childProcess := range k2sChildProcesses {
				name, err := childProcess.Name()
				Expect(err).NotTo(HaveOccurred())

				if name != "ssh.exe" {
					continue
				}

				GinkgoWriter.Println("Killing process ID =", childProcess.Pid)

				Expect(childProcess.KillWithContext(ctx)).To(Succeed())
			}

			Eventually(ctx, session).WithTimeout(time.Second * 5).Should(gbytes.Say(`'k2s node connect' completed`))
			Eventually(ctx, session).WithTimeout(time.Second * 5).Should(gexec.Exit(0))
		})
	})
})
