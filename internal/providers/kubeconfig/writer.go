// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package kubeconfig

import (
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
)

type kubectl interface {
	Exec(args ...string) error
}

type KubeconfigWriter struct {
	kubectl kubectl
}

func NewKubeconfigWriter(kubectl kubectl) *KubeconfigWriter {
	return &KubeconfigWriter{
		kubectl: kubectl,
	}
}

// SetClusterConfig implicitly creates the kubeconfig file if it does not exist and sets the cluster configuration in the specified kubeconfig file.
func (k *KubeconfigWriter) SetClusterConfig(kubeconfigPath string, cluster *Cluster) error {
	slog.Debug("Writing cluster config to kubeconfig", "path", kubeconfigPath, "cluster-name", cluster.Name)

	targetDir := filepath.Dir(kubeconfigPath)

	if err := os.MkdirAll(targetDir, fs.ModePerm); err != nil {
		return fmt.Errorf("failed to create target directory '%s': %w", kubeconfigPath, err)
	}

	// implicitly creates kubeconfig when not existing
	if err := k.kubectl.Exec("config", "set-cluster", cluster.Name, "--server", cluster.Details.Server, "--kubeconfig", kubeconfigPath); err != nil {
		return fmt.Errorf("failed to set cluster '%s' in kubeconfig '%s': %w", cluster.Name, kubeconfigPath, err)
	}

	certJsonPath := fmt.Sprintf("clusters.%s.certificate-authority-data", cluster.Name)

	// "kubectl config set-cluster" does not support in-memory cert data, therefore the cert data is set separately
	if err := k.kubectl.Exec("config", "set", certJsonPath, cluster.Details.Cert, "--kubeconfig", kubeconfigPath); err != nil {
		return fmt.Errorf("failed to set cluster certificate in kubeconfig '%s': %w", kubeconfigPath, err)
	}

	slog.Debug("Cluster config written to kubeconfig", "path", kubeconfigPath, "cluster-name", cluster.Name)
	return nil
}

func (k *KubeconfigWriter) SetUserCredentials(k8sUserName, certPath, keyPath, kubeconfigPath string) error {
	slog.Debug("Setting user credentials", "k8s-user-name", k8sUserName, "cert-path", certPath, "key-path", keyPath, "kubeconfig-path", kubeconfigPath)

	if err := k.kubectl.Exec("config", "set-credentials", k8sUserName, "--client-certificate", certPath, "--client-key", keyPath, "--embed-certs=true", "--kubeconfig", kubeconfigPath); err != nil {
		return fmt.Errorf("failed to set user credentials in kubeconfig '%s': %w", kubeconfigPath, err)
	}

	slog.Debug("User credentials set for user", "k8s-user-name", k8sUserName, "cert-path", certPath, "key-path", keyPath, "kubeconfig-path", kubeconfigPath)
	return nil
}

func (k *KubeconfigWriter) SetContext(context, k8sUserName, clusterName, kubeconfigPath string) error {
	slog.Debug("Setting context for user", "k8s-user-name", k8sUserName, "cluster-name", clusterName, "context", context, "kubeconfig-path", kubeconfigPath)

	if err := k.kubectl.Exec("config", "set-context", context, "--cluster="+clusterName, "--user="+k8sUserName, "--kubeconfig", kubeconfigPath); err != nil {
		return fmt.Errorf("failed to set context in kubeconfig '%s': %w", kubeconfigPath, err)
	}

	slog.Debug("K2s context set", "k8s-user-name", k8sUserName, "cluster-name", clusterName, "context", context, "kubeconfig-path", kubeconfigPath)
	return nil
}

func (k *KubeconfigWriter) SetCurrentContext(context, kubeconfigPath string) error {
	slog.Debug("Setting current context", "context", context, "kubeconfig-path", kubeconfigPath)

	if err := k.kubectl.Exec("config", "use-context", context, "--kubeconfig", kubeconfigPath); err != nil {
		return fmt.Errorf("failed to set current context in kubeconfig '%s': %w", kubeconfigPath, err)
	}

	slog.Debug("Current context set", "context", context, "kubeconfig-path", kubeconfigPath)
	return nil
}
