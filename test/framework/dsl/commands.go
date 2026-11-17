// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package dsl

import (
	"context"

	"github.com/k2s-project/k2s/internal/cli"
)

func (k2s *K2s) ShowStatus(ctx context.Context) *K2sCmdResult {
	return k2s.runCmd(ctx, "status")
}

func (k2s *K2s) Start(ctx context.Context) *K2sCmdResult {
	return k2s.runCmd(ctx, "start")
}

func (k2s *K2s) Stop(ctx context.Context) *K2sCmdResult {
	return k2s.runCmd(ctx, "stop")
}

func (k2s *K2s) AddNode(ctx context.Context) *K2sCmdResult {
	return k2s.runCmd(ctx, "node", "add", "-i", "ip", "-u", "user")
}

func (k2s *K2s) RemoveNode(ctx context.Context, nodeName string) *K2sCmdResult {
	return k2s.runCmd(ctx, "node", "remove", "-m", nodeName)
}

func (k2s *K2s) RemoveImage(ctx context.Context) *K2sCmdResult {
	return k2s.runCmd(ctx, "image", "rm")
}

func (k2s *K2s) ShowAddonStatus(ctx context.Context, addon, implementation string) *K2sCmdResult {
	return k2s.runCmd(ctx, "addons", "status", addon, implementation)
}

func (k2s *K2s) EnableAddon(ctx context.Context, addon, implementation string) *K2sCmdResult {
	return k2s.runCmd(ctx, "addons", "enable", addon, implementation)
}

func (k2s *K2s) DisableAddon(ctx context.Context, addon, implementation string) *K2sCmdResult {
	cliArgs := []string{"addons", "disable", addon, implementation}

	if addon == "storage" {
		cliArgs = append(cliArgs, "-f")
	}

	return k2s.runCmd(ctx, cliArgs...)
}

func (k2s *K2s) runCmd(ctx context.Context, cliArgs ...string) *K2sCmdResult {
	output, exitCode := k2s.suite.K2sCli().Exec(ctx, cliArgs...)

	return &K2sCmdResult{
		output:   output,
		exitCode: cli.ExitCode(exitCode),
	}
}

func (k2s *K2s) StartNode(ctx context.Context, nodeName string) *K2sCmdResult {
	return k2s.runCmd(ctx, "start", "--node", nodeName)
}

func (k2s *K2s) StopNode(ctx context.Context, nodeName string) *K2sCmdResult {
	return k2s.runCmd(ctx, "stop", "--node", nodeName)
}
