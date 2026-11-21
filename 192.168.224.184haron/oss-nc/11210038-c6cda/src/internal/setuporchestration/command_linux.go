// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package setuporchestration

import (
	"bytes"
	"fmt"
	"log/slog"
	"os/exec"
	"strings"
)

// runCommand is retained for Linux libvirt support. Native K2s cluster
// lifecycle commands are implemented by the platform-first shell modules.
func runCommand(name string, args ...string) error {
	slog.Debug("Executing command", "cmd", name, "args", args)
	cmd := exec.Command(name, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		slog.Error("Command failed", "cmd", name, "output", string(output), "error", err)
		return fmt.Errorf("%s failed: %w\nOutput: %s", name, err, string(output))
	}
	slog.Debug("Command succeeded", "cmd", name, "output", string(output))
	return nil
}

// runCommandOutput returns stdout without mixing successful stderr diagnostics
// into data consumed by libvirt command parsers.
func runCommandOutput(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("%s failed: %w; stderr: %s", name, err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), nil
}
