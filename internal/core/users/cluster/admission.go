// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package cluster

import (
	"fmt"
	"log/slog"

	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/contracts/users"
	"github.com/k2s-project/k2s/internal/core/users/cluster/naming"
	"github.com/k2s-project/k2s/internal/core/users/cluster/tempdir"
	"github.com/k2s-project/k2s/internal/primitives/concurrency"
	"github.com/k2s-project/k2s/internal/providers/kubeconfig"
	"github.com/k2s-project/k2s/internal/providers/ssh"
)

type ClusterAdmission struct {
	clusterName        string
	kubeconfigResolver *kubeconfig.KubeconfigResolver
	kubeconfigEditor   *KubeconfigEditor
	certGenerator      *CertGenerator
	accessVerifier     *ClusterAccessVerifier
}

func NewClusterAdmission(clusterName string, hostConfig *config.HostConfig, connectionOptions ssh.ConnectionOptions) *ClusterAdmission {
	return &ClusterAdmission{
		clusterName:        clusterName,
		kubeconfigResolver: kubeconfig.NewKubeconfigResolver(hostConfig.KubeConfig()),
		kubeconfigEditor:   NewKubeconfigEditor(hostConfig, clusterName),
		certGenerator:      NewCertGenerator(ssh.NewSSH(connectionOptions)),
		accessVerifier:     NewClusterAccessVerifier(),
	}
}

func (c *ClusterAdmission) GrantAccess(user *users.OSUser, k8sUserName string) error {
	slog.Debug("Granting user access to Kubernetes cluster", "name", user.Name(), "id", user.Id(), "k8s-user-name", k8sUserName)

	targetKubeconfigPath := c.kubeconfigResolver.ResolveKubeconfigPath(user)

	tempDir, err := tempdir.CreateTempDir()
	if err != nil {
		return err
	}
	defer func() {
		err := tempdir.RemoveTempDir(tempDir)
		if err != nil {
			slog.Error("failed to remove temporary directory for user certificate generation", "path", tempDir, "error", err)
		}
	}()

	var certPath, keyPath string

	allErrors := concurrency.RunAll(
		func() error {
			return c.kubeconfigEditor.CopyCurrentClusterConfig(targetKubeconfigPath)
		},
		func() error {
			var err error

			certPath, keyPath, err = c.certGenerator.GenerateUserCert(k8sUserName, tempDir)
			return err
		},
	)

	if allErrors != nil {
		return fmt.Errorf("failed to grant user access to Kubernetes cluster: %w", allErrors)
	}

	k8sContext := naming.DetermineK8sContext(k8sUserName, c.clusterName)

	if err := c.kubeconfigEditor.SetUserContext(k8sUserName, k8sContext, certPath, keyPath, targetKubeconfigPath); err != nil {
		return err
	}

	if err := c.accessVerifier.VerifyAccess(k8sContext, targetKubeconfigPath); err != nil {
		return fmt.Errorf("failed to verify cluster access for user '%s' in kubeconfig '%s': %w", k8sUserName, targetKubeconfigPath, err)
	}
	return nil
}
