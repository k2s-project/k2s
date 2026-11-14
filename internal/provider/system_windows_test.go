// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package provider

import (
	"strings"
	"testing"
)

func TestClusterUpgradeCommandEscapesConfigPath(t *testing.T) {
	provider := &windowsSystemProvider{installDir: `C:\K2s Package`}

	command := provider.clusterUpgradeCommand(SystemUpgradeConfig{
		ConfigFile: `C:\Upgrade Config\owner's.yaml`,
	})

	if !strings.Contains(command, ` -Config 'C:\Upgrade Config\owner''s.yaml'`) {
		t.Fatalf("cluster upgrade command does not safely quote config path: %s", command)
	}
}

func TestClusterUpgradeCommandEscapesUserSuppliedValues(t *testing.T) {
	provider := &windowsSystemProvider{installDir: `C:\K2s`}

	command := provider.clusterUpgradeCommand(SystemUpgradeConfig{
		Proxy:              `http://x'; calc; '`,
		BackupDir:          `C:\owner's backup`,
		AdditionalHooksDir: `C:\$(calc)`,
	})

	expectedParams := []string{
		` -Proxy 'http://x''; calc; '''`,
		` -BackupDir 'C:\owner''s backup'`,
		` -AdditionalHooksDir 'C:\$(calc)'`,
	}
	for _, expected := range expectedParams {
		if !strings.Contains(command, expected) {
			t.Fatalf("cluster upgrade command does not contain %q: %s", expected, command)
		}
	}
}

func TestNodePackageCommandUsesTypedOptions(t *testing.T) {
	provider := &windowsSystemProvider{installDir: `C:\K2s Package`}
	command, params := provider.nodePackageCommand(SystemPackageConfig{
		OutputDir:    `C:\output folder`,
		PackageName:  "node.zip",
		OS:           "debian13",
		Architecture: "amd64",
		Proxy:        `http://proxy'; invalid`,
		IncludeGPU:   true,
		ShowOutput:   true,
	})

	if !strings.Contains(command, "New-K2sNodePackage.ps1") {
		t.Fatalf("unexpected node package script path: %s", command)
	}
	expectedParams := []string{
		" -TargetDirectory 'C:\\output folder'",
		" -ZipPackageFileName 'node.zip'",
		" -OS 'debian13'",
		" -Proxy 'http://proxy''; invalid'",
		" -IncludeGpu",
		" -ShowLogs",
	}
	for _, expected := range expectedParams {
		if !strings.Contains(strings.Join(params, ""), expected) {
			t.Fatalf("node package parameters do not contain %q: %v", expected, params)
		}
	}
}
