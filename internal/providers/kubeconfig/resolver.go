// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package kubeconfig

import (
	"path/filepath"

	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/contracts/users"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/host"
)

type KubeconfigResolver struct {
	kubeConfig *config.KubeConfig
}

func NewKubeconfigResolver(kubeConfig *config.KubeConfig) *KubeconfigResolver {
	return &KubeconfigResolver{
		kubeConfig: kubeConfig,
	}
}

func (k *KubeconfigResolver) ResolveKubeconfigPath(user *users.OSUser) string {
	targetDir := host.ResolveTildePrefix(k.kubeConfig.RelativeDir(), user.HomeDir())

	return filepath.Join(targetDir, definitions.KubeconfigName)
}
