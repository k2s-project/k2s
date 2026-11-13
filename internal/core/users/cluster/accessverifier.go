// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package cluster

import (
	"fmt"
	"log/slog"

	"github.com/k2s-project/k2s/internal/core/users/cluster/decoding"
	"github.com/k2s-project/k2s/internal/core/users/cluster/verification"
	"github.com/k2s-project/k2s/internal/providers/http"
	"github.com/k2s-project/k2s/internal/providers/k8s"
	"github.com/k2s-project/k2s/internal/providers/kubeconfig"
)

type ClusterAccessVerifier struct {
	userInfoAPI *k8s.UserInfoAPI
}

func NewClusterAccessVerifier() *ClusterAccessVerifier {
	return &ClusterAccessVerifier{
		userInfoAPI: k8s.NewUserInfoAPI(http.NewRestClient()),
	}
}

func (c *ClusterAccessVerifier) VerifyAccess(context, kubeconfigPath string) error {
	slog.Debug("Verifying cluster access", "context", context, "kubeconfig-path", kubeconfigPath)

	kubeConfig, err := kubeconfig.FromFile(kubeconfigPath)
	if err != nil {
		return fmt.Errorf("failed to read kubeconfig from '%s': %w", kubeconfigPath, err)
	}

	cluster, user, err := kubeConfig.FindK8sApiCredentials(context)
	if err != nil {
		return fmt.Errorf("failed to read Kubernetes API credentials from kubeconfig '%s': %w", kubeconfigPath, err)
	}

	caCert, userCert, userKey, err := decoding.DecodeK8sApiCredentials(cluster, user)
	if err != nil {
		return fmt.Errorf("failed to decode Kubernetes API credentials: %w", err)
	}

	userInfo, err := c.userInfoAPI.FetchUserInfo(cluster.Details.Server, caCert, userCert, userKey)
	if err != nil {
		return fmt.Errorf("failed to fetch user info from Kubernetes API: %w", err)
	}

	if err := verification.VerifyUser(user.Name, userInfo); err != nil {
		return fmt.Errorf("failed to verify user '%s' against Kubernetes API: %w", user.Name, err)
	}

	slog.Debug("Kubernetes cluster verified", "context", context, "kubeconfig-path", kubeconfigPath)
	return nil
}
