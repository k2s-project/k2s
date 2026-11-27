// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build !windows

package os

import (
	"errors"
	"os/exec"
	"syscall"
	"time"
)

// ConfigureProcessGroup places cmd in its own process group so context cancellation
// terminates the entire process tree and bounds pipe draining via WaitDelay.
func ConfigureProcessGroup(cmd *exec.Cmd, waitDelay time.Duration) {
	if cmd == nil {
		return
	}
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setpgid = true
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if errors.Is(err, syscall.ESRCH) {
			return nil
		}
		if err != nil {
			return cmd.Process.Kill()
		}
		return nil
	}
	if waitDelay > 0 {
		cmd.WaitDelay = waitDelay
	}
}
