// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package cluster

import (
	"fmt"
	"log/slog"

	"github.com/k2s-project/k2s/internal/core/users/cluster/cert"
)

type sshProvider interface {
	Exec(command string) error
	MoveFromNode(source, target string) error
}

type CertGenerator struct {
	sshProvider sshProvider
}

func NewCertGenerator(sshProvider sshProvider) *CertGenerator {
	return &CertGenerator{
		sshProvider: sshProvider,
	}
}

func (c *CertGenerator) GenerateUserCert(userName string, targetDir string) (certPath, keyPath string, err error) {
	slog.Debug("Generating user cert", "user-name", userName, "target-dir", targetDir)

	remoteCmd := cert.CreateRemoteCertCmd(userName)

	if err := c.sshProvider.Exec(remoteCmd.Cmd); err != nil {
		return "", "", fmt.Errorf("failed to create user certificate on remote machine for user '%s': %w", userName, err)
	}

	err = c.sshProvider.MoveFromNode(remoteCmd.TempDir, targetDir)
	if err != nil {
		return "", "", fmt.Errorf("failed to move user certificate files from remote machine for user '%s': %w", userName, err)
	}

	certPath, keyPath = cert.DetermineLocalCertPaths(targetDir, remoteCmd)

	slog.Debug("User cert generated", "user-name", userName, "target-dir", targetDir, "cert-path", certPath, "key-path", keyPath)
	return
}
