// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package os

import (
	"os/exec"
	"time"
)

// ConfigureProcessGroup configures bounded pipe draining for cmd on Windows.
func ConfigureProcessGroup(cmd *exec.Cmd, waitDelay time.Duration) {
	if cmd == nil {
		return
	}
	if waitDelay > 0 {
		cmd.WaitDelay = waitDelay
	}
}
