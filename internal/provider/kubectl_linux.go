// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"os"
	"path/filepath"
)

const linuxAdminKubeconfig = "/etc/kubernetes/admin.conf"

func init() {
	EnsureKubeconfigEnv()
}

// EnsureKubeconfigEnv sets KUBECONFIG to /etc/kubernetes/admin.conf if KUBECONFIG is not already set
// and ~/.kube/config does not exist.
func EnsureKubeconfigEnv() {
	if val := resolveKubeconfigEnv(os.Getenv, os.UserHomeDir, os.Stat); val != "" {
		_ = os.Setenv("KUBECONFIG", val)
	}
}

// resolveKubeconfigEnv determines if KUBECONFIG needs to be explicitly set.
// - If KUBECONFIG is already non-empty, it returns "" (no override).
// - Else if ~/.kube/config exists, it returns "" (kubectl default behavior).
// - Else if /etc/kubernetes/admin.conf exists, it returns "/etc/kubernetes/admin.conf".
// - Otherwise, it returns "".
func resolveKubeconfigEnv(
	getEnv func(string) string,
	userHomeDir func() (string, error),
	stat func(string) (os.FileInfo, error),
) string {
	if v := getEnv("KUBECONFIG"); v != "" {
		return ""
	}
	if home, err := userHomeDir(); err == nil {
		userKubeconfig := filepath.Join(home, ".kube", "config")
		if _, err := stat(userKubeconfig); err == nil {
			return ""
		}
	}
	if _, err := stat(linuxAdminKubeconfig); err == nil {
		return linuxAdminKubeconfig
	}
	return ""
}
