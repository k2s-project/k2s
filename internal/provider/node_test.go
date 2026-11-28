// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package provider

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestNodeRenameConfigValidation(t *testing.T) {
	tests := []struct {
		name    string
		old     string
		new     string
		timeout time.Duration
		valid   bool
	}{
		{"normalizes names", "OLD-NODE", "NEW-NODE", 15 * time.Minute, true},
		{"empty old", "", "new", time.Minute, false},
		{"empty new", "old", "", time.Minute, false},
		{"same name", "OLD", "old", time.Minute, false},
		{"shell input", "old", "new;hostname", time.Minute, false},
		{"invalid hostname", "old", "new_node", time.Minute, false},
		{"invalid timeout", "old", "new", time.Second, false},
		{"excessive timeout", "old", "new", 25 * time.Hour, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg, err := (NodeRenameConfig{OldName: tt.old, NewName: tt.new, Timeout: tt.timeout}).Validated()
			if (err == nil) != tt.valid {
				t.Fatalf("Validated() error = %v, valid = %t", err, tt.valid)
			}
			if tt.valid && (cfg.OldName != "old-node" || cfg.NewName != "new-node") {
				t.Fatalf("names not normalized: %+v", cfg)
			}
		})
	}
}

func TestNodeUpgradeConfigValidation(t *testing.T) {
	dir := t.TempDir()
	writeFile := func(name string) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte("zip"), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	nodePackage := writeFile("debian13-node.zip")
	upperCaseNodePackage := writeFile("debian12-node.ZIP")
	textFile := writeFile("debian13-node.txt")
	zipDir := filepath.Join(dir, "folder.zip")
	if err := os.Mkdir(zipDir, 0o700); err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name        string
		nodeName    string
		packagePath string
		wantErr     string
	}{
		{"valid", "k2s-nodepkg-debian13", nodePackage, ""},
		{"zip extension in upper case", "k2s-nodepkg-debian13", upperCaseNodePackage, ""},
		{"empty node name", "", nodePackage, "invalid node name"},
		{"blank node name", "  ", nodePackage, "invalid node name"},
		{"shell input in node name", "worker;hostname", nodePackage, "invalid node name"},
		{"empty path", "worker", "", "must not be empty"},
		{"blank path", "worker", "  ", "must not be empty"},
		{"missing path", "worker", filepath.Join(dir, "missing.zip"), "does not exist"},
		{"not a zip file", "worker", textFile, "must be a .zip file"},
		{"directory", "worker", zipDir, "must be a .zip file"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := (NodeUpgradeConfig{NodeName: tt.nodeName, NodePackagePath: tt.packagePath}).Validated()
			if tt.wantErr == "" && err != nil {
				t.Fatalf("Validated() error = %v, want none", err)
			}
			if tt.wantErr != "" && (err == nil || !strings.Contains(err.Error(), tt.wantErr)) {
				t.Fatalf("Validated() error = %v, want error containing %q", err, tt.wantErr)
			}
		})
	}
}

func TestNodeUpgradeConfigValidationNormalizesInput(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "debian13-node.zip"), []byte("zip"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)

	cfg, err := (NodeUpgradeConfig{NodeName: " K2S-NodePkg-Debian13 ", NodePackagePath: "debian13-node.zip", ShowOutput: true}).Validated()
	if err != nil {
		t.Fatalf("Validated() error = %v", err)
	}

	// The upgrade script changes its working directory, so a relative path must be resolved against the caller's directory.
	wantPath, err := filepath.Abs("debian13-node.zip")
	if err != nil {
		t.Fatal(err)
	}
	want := NodeUpgradeConfig{NodeName: "k2s-nodepkg-debian13", NodePackagePath: wantPath, ShowOutput: true}
	if cfg != want {
		t.Fatalf("Validated() = %+v, want %+v", cfg, want)
	}
}
