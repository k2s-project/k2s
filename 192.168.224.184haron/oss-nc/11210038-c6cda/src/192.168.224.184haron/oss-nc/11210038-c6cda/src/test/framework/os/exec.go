// SPDX-FileCopyrightText: © 2025 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package os

import (
	"context"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	"github.com/k2s-project/k2s/internal/cli"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
	"github.com/onsi/gomega/types"
)

type CliExecutor struct {
	cliPath          string
	proxy            string
	timeout          time.Duration
	pollInterval     time.Duration
	expectedExitCode *int
	dir              string
	noStdOut         bool
	useProxy         bool
}

func NewCli(cliPath string, proxy string, timeout time.Duration, pollInterval time.Duration) *CliExecutor {
	return &CliExecutor{
		cliPath:      cliPath,
		proxy:        proxy,
		timeout:      timeout,
		pollInterval: pollInterval,
	}
}

func (c *CliExecutor) ExpectedExitCode(exitCode cli.ExitCode) *CliExecutor {
	c.expectedExitCode = new(int(exitCode))
	return c
}

func (c *CliExecutor) WorkingDir(workingDir string) *CliExecutor {
	c.dir = workingDir
	return c
}

func (c *CliExecutor) NoStdOut() *CliExecutor {
	c.noStdOut = true
	return c
}

func (c *CliExecutor) UseProxy() *CliExecutor {
	c.useProxy = true
	return c
}

func (c *CliExecutor) MustExec(ctx context.Context, cliArgs ...string) string {
	output, _ := c.ExpectedExitCode(cli.ExitCodeSuccess).Exec(ctx, cliArgs...)
	return output
}

func (c *CliExecutor) Exec(ctx context.Context, cliArgs ...string) (string, int) {
	cmd := exec.Command(c.cliPath, cliArgs...)
	cmd.Dir = c.dir

	if c.useProxy && c.proxy != "" {
		GinkgoWriter.Println("Using proxy <", c.proxy, "> for command execution..")
		cmd.Env = os.Environ()
		cmd.Env = append(cmd.Env, "https_proxy="+c.proxy)
		cmd.Env = append(cmd.Env, "http_proxy="+c.proxy)
	}

	var stdOut io.Writer = GinkgoWriter
	if c.noStdOut {
		stdOut = io.Discard
	}

	session, err := gexec.Start(cmd, stdOut, GinkgoWriter)
	Expect(err).ToNot(HaveOccurred())

	var exitCodeMatcher types.GomegaMatcher = gexec.Exit()
	if c.expectedExitCode != nil {
		exitCodeMatcher = gexec.Exit(*c.expectedExitCode)
	}

	GinkgoWriter.Printf(">>> EXEC: %s %s\n", c.cliPath, strings.Join(cliArgs, " "))
	GinkgoWriter.Printf(">>> EXEC: timeout=%v, pollInterval=%v, ctx=%v\n", c.timeout, c.pollInterval, ctx)
	if deadline, ok := ctx.Deadline(); ok {
		GinkgoWriter.Printf(">>> EXEC: context has deadline: %v (remaining: %v)\n", deadline, time.Until(deadline))
	} else {
		GinkgoWriter.Println(">>> EXEC: context has NO deadline")
	}

	Eventually(session,
		c.timeout,
		c.pollInterval,
		ctx).Should(exitCodeMatcher, "Command '%v' exited with code '%d'", session.Command, session.ExitCode())

	return string(session.Out.Contents()), session.ExitCode()
}

func (k *CliExecutor) Path() string {
	return k.cliPath
}
