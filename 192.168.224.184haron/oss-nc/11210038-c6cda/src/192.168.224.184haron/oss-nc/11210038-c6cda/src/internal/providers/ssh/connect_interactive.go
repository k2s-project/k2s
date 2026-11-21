// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package ssh

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
)

func connectInteractively(options ConnectionOptions, sshCmd string) error {
	timeoutOption := fmt.Sprintf("ConnectTimeout=%d", int(options.Timeout.Seconds()))
	port := fmt.Sprintf("%d", options.Port)
	remote := fmt.Sprintf("%s@%s", options.RemoteUser, options.IpAddress)

	cmd := exec.Command(sshCmd, "-tt", "-o", "StrictHostKeyChecking=no", "-o", timeoutOption, "-i", options.SshPrivateKeyPath, "-p", port, remote)

	slog.Debug(fmt.Sprintf("Executing %s", sshCmd), "command", cmd.String())

	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to start %s: %w", sshCmd, err)
	}

	if err := cmd.Wait(); err != nil {
		if exitErr, ok := errors.AsType[*exec.ExitError](err); ok {
			exitCode := exitErr.ExitCode()
			if exitCode == 255 {
				return fmt.Errorf("failed to execute %s: %w", sshCmd, err)
			}
			slog.Debug(fmt.Sprintf("failed to execute %s", sshCmd), "exit-code", exitCode)
			return nil
		}
		return fmt.Errorf("failed to wait for %s execution: %w", sshCmd, err)
	}
	return nil
}
