// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

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
