// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package cluster

import (
	"fmt"
	"log/slog"

	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/providers/kubeconfig"
	"github.com/k2s-project/k2s/internal/providers/kubectl"
)

type KubeconfigEditor struct {
	currentClusterName    string
	currentKubeconfigPath string
	kubeconfigWriter      *kubeconfig.KubeconfigWriter
}

func NewKubeconfigEditor(hostConfig *config.HostConfig, currentClusterName string) *KubeconfigEditor {
	return &KubeconfigEditor{
		currentClusterName:    currentClusterName,
		currentKubeconfigPath: hostConfig.KubeConfig().CurrentPath(),
		kubeconfigWriter:      kubeconfig.NewKubeconfigWriter(kubectl.NewKubectl(hostConfig.K2sInstallDir())),
	}
}

func (k *KubeconfigEditor) CopyCurrentClusterConfig(targetKubeconfig string) error {
	slog.Debug("Copying current cluster config to target kubeconfig", "target-path", targetKubeconfig)

	sourceConfig, err := kubeconfig.FromFile(k.currentKubeconfigPath)
	if err != nil {
		return fmt.Errorf("failed to read current kubeconfig: %w", err)
	}

	clusterConfig, err := sourceConfig.FindCluster(k.currentClusterName)
	if err != nil {
		return fmt.Errorf("failed to find cluster config: %w", err)
	}

	if err := k.kubeconfigWriter.SetClusterConfig(targetKubeconfig, clusterConfig); err != nil {
		return fmt.Errorf("failed to set cluster config in target '%s': %w", targetKubeconfig, err)
	}

	slog.Debug("Current cluster config copied to target kubeconfig", "target-path", targetKubeconfig)
	return nil
}

func (k *KubeconfigEditor) SetUserContext(k8sUserName, k8sContext, certPath, keyPath, targetKubeconfig string) error {
	if err := k.kubeconfigWriter.SetUserCredentials(k8sUserName, certPath, keyPath, targetKubeconfig); err != nil {
		return fmt.Errorf("failed to set user credentials in '%s': %w", targetKubeconfig, err)
	}

	if err := k.kubeconfigWriter.SetContext(k8sContext, k8sUserName, k.currentClusterName, targetKubeconfig); err != nil {
		return fmt.Errorf("failed to set context in '%s': %w", targetKubeconfig, err)
	}

	kubeConfig, err := kubeconfig.FromFile(targetKubeconfig)
	if err != nil {
		return fmt.Errorf("failed to read kubeconfig '%s': %w", targetKubeconfig, err)
	}

	if kubeConfig.CurrentContext == "" {
		if err := k.kubeconfigWriter.SetCurrentContext(k8sContext, targetKubeconfig); err != nil {
			return fmt.Errorf("failed to set current context '%s' in '%s': %w", k8sContext, targetKubeconfig, err)
		}
	}
	return nil
}
