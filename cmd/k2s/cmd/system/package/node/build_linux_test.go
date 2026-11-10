// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build linux

package nodepackage

import (
	"path/filepath"
	"testing"
)

// Guards the regex-based extraction against refactors of Get-DefaultK8sVersion.
func TestResolveDefaultK8sVersion_ReadsRepositoryConfigModule(t *testing.T) {
	installDir, err := filepath.Abs(filepath.Join("..", "..", "..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	version, err := resolveDefaultK8sVersion(installDir)
	if err != nil {
		t.Fatalf("could not resolve default K8s version: %v", err)
	}
	if len(version) < 2 || version[0] != 'v' {
		t.Fatalf("unexpected version '%s'", version)
	}
}
