// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package ssh

import (
	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/contracts/users"
	"github.com/k2s-project/k2s/internal/host"
)

type KeyPathResolver struct {
	sshConfig *config.SSHConfig
}

func NewKeyPathResolver(sshConfig *config.SSHConfig) *KeyPathResolver {
	return &KeyPathResolver{
		sshConfig: sshConfig,
	}
}

func (k *KeyPathResolver) ResolvePrivateKeyPath(user *users.OSUser) string {
	return host.ResolveTildePrefix(k.sshConfig.RelativePrivateKeyPath(), user.HomeDir())
}
