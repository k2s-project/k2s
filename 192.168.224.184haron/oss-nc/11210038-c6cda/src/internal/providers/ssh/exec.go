// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package ssh

import (
	"fmt"
	"log/slog"
	"os"
)

func (s *SSH) Exec(command string) error {
	sshClient, err := Connect(s.connectionOptions)
	if err != nil {
		return fmt.Errorf("failed to dial SSH: %w", err)
	}
	defer func() {
		slog.Debug("Closing SSH client")
		if err := sshClient.Close(); err != nil {
			slog.Error("failed to close SSH client", "error", err)
		}
	}()

	session, err := sshClient.NewSession()
	if err != nil {
		return fmt.Errorf("failed to create SSH session: %w", err)
	}

	if s.connectionOptions.StdOutWriter != nil {
		session.Stdout = s.connectionOptions.StdOutWriter
	} else {
		session.Stdout = os.Stdout
	}
	session.Stderr = os.Stdout

	// Session.Run() implicitly closes the session afterwards
	if err := session.Run(command); err != nil {
		return fmt.Errorf("failed to run command: %w", err)
	}
	return nil
}
