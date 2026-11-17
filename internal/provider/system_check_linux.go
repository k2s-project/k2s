// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"errors"
	"log/slog"
	"os"

	"github.com/k2s-project/k2s/internal/healthcheck"
)

// linuxAdminKubeconfigPath is used when the current user has no kubeconfig yet.
const linuxAdminKubeconfigPath = "/etc/kubernetes/admin.conf"

// linuxContainerStateDir holds the container runtime and kubelet state on Linux hosts.
const linuxContainerStateDir = "/var/lib"

// Check runs the Linux host health checks. Nothing on the system is modified.
func (p *linuxSystemProvider) Check(cfg SystemCheckConfig) (healthcheck.Report, error) {
	return healthcheck.Run(linuxHealthChecks(cfg, p.installDir, p.configDir, healthcheck.GetDiskInfo)), nil
}

func linuxHealthChecks(cfg SystemCheckConfig, installDir, configDir string, diskInfoFunc healthcheck.DiskInfoFunc) []healthcheck.Check {
	return []healthcheck.Check{
		healthcheck.NewDiskSpaceCheck([]string{installDir, configDir, linuxContainerStateDir}, diskInfoFunc),
		healthcheck.NewCertificatesCheck(healthcheck.CertificatesCheckConfig{
			KubeconfigPath: resolveLinuxKubeconfigPath(cfg.KubeconfigPath),
			ClusterName:    cfg.ClusterName,
		}),
	}
}

// resolveLinuxKubeconfigPath falls back to the kubeadm admin kubeconfig when the user's kubeconfig
// does not exist, matching the context resolution of the other commands on Linux hosts.
func resolveLinuxKubeconfigPath(kubeconfigPath string) string {
	if _, err := os.Stat(kubeconfigPath); errors.Is(err, os.ErrNotExist) {
		if _, adminErr := os.Stat(linuxAdminKubeconfigPath); adminErr == nil {
			slog.Debug("Falling back to admin kubeconfig", "path", linuxAdminKubeconfigPath)
			return linuxAdminKubeconfigPath
		}
	}
	return kubeconfigPath
}
