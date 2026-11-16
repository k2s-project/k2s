// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/k2s-project/k2s/internal/healthcheck"
)

func TestLinuxHealthChecks(t *testing.T) {
	var checkedPaths []string
	diskInfo := func(path string) (healthcheck.DiskInfo, error) {
		checkedPaths = append(checkedPaths, path)
		return healthcheck.DiskInfo{VolumeID: "root", FreeBytes: healthcheck.LowFreeDiskBytes}, nil
	}

	checks := linuxHealthChecks(SystemCheckConfig{
		ClusterName:    "k2s-cluster",
		KubeconfigPath: filepath.Join(t.TempDir(), "config"),
	}, "/opt/k2s", "/var/lib/k2s", diskInfo)

	report := healthcheck.Run(checks)

	names := make([]string, 0, len(report.Results))
	for _, result := range report.Results {
		names = append(names, result.Name)
	}
	if !slices.Equal(names, []string{"host-disk-space", "cluster-certificates"}) {
		t.Fatalf("unexpected checks: %v", names)
	}
	if !slices.Equal(checkedPaths, []string{"/opt/k2s", "/var/lib/k2s", "/var/lib"}) {
		t.Fatalf("unexpected disk paths: %v", checkedPaths)
	}
	if report.Results[0].Status != healthcheck.StatusPass {
		t.Fatalf("expected disk check to pass, got %q (%s)", report.Results[0].Status, report.Results[0].Message)
	}
}

func TestResolveLinuxKubeconfigPathKeepsExistingUserKubeconfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config")
	if err := os.WriteFile(path, []byte{}, 0o600); err != nil {
		t.Fatal(err)
	}

	if resolved := resolveLinuxKubeconfigPath(path); resolved != path {
		t.Fatalf("expected %q, got %q", path, resolved)
	}
}
