// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package controlplane

import (
	"fmt"
	"log/slog"

	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/contracts/users"
	"github.com/k2s-project/k2s/internal/core/users/controlplane/keyauth"
	"github.com/k2s-project/k2s/internal/core/users/controlplane/knownhosts"
	"github.com/k2s-project/k2s/internal/primitives/concurrency"
	"github.com/k2s-project/k2s/internal/providers/acl"
	"github.com/k2s-project/k2s/internal/providers/ssh"
)

type ControlPlaneAdmission struct {
	controlplaneIP   string
	keyAuthorizer    *keyauth.KeyAuthorizer
	knownHostsCopier *knownhosts.KnownHostsCopier
	keyPathResolver  *ssh.KeyPathResolver
}

func NewControlPlaneAdmission(config *config.K2sConfig, connectionOptions ssh.ConnectionOptions) *ControlPlaneAdmission {
	return &ControlPlaneAdmission{
		controlplaneIP:   config.ControlPlane().IpAddress(),
		keyAuthorizer:    keyauth.NewKeyAuthorizer(ssh.NewSSH(connectionOptions)),
		knownHostsCopier: knownhosts.NewKnownHostsCopier(config.Host().SshConfig()),
		keyPathResolver:  ssh.NewKeyPathResolver(config.Host().SshConfig()),
	}
}

func (u *ControlPlaneAdmission) GrantAccess(user *users.OSUser, publicKeyComment string) error {
	slog.Debug("Granting user access to control-plane", "name", user.Name(), "id", user.Id())

	privateKeyPath := u.keyPathResolver.ResolvePrivateKeyPath(user)

	slog.Debug("SSH private key path determined", "path", privateKeyPath)

	publicKeyPath, err := ssh.CreateKeyPair(privateKeyPath, publicKeyComment)
	if err != nil {
		return fmt.Errorf("failed to create SSH key pair: %w", err)
	}

	return concurrency.RunAll(
		func() error {
			return acl.TransferFileOwnership(privateKeyPath, user)
		},
		func() error {
			return u.keyAuthorizer.AuthorizePubKeyOnRemote(publicKeyPath, publicKeyComment)
		},
		func() error {
			return u.knownHostsCopier.CopyHostEntries(u.controlplaneIP, user)
		},
	)
}
