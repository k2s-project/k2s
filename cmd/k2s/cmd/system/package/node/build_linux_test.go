// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build linux

package nodepackage

import (
	"os"
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

func TestValidateBuildHostOS(t *testing.T) {
	tests := []struct {
		name      string
		targetOS  string
		osRelease string
		wantErr   bool
	}{
		{
			name:      "matching Debian release",
			targetOS:  "debian13",
			osRelease: "ID=debian\nVERSION_ID=\"13\"\n",
		},
		{
			name:      "different Debian release",
			targetOS:  "debian12",
			osRelease: "ID=debian\nVERSION_ID=\"13\"\n",
			wantErr:   true,
		},
		{
			name:      "different distribution",
			targetOS:  "debian13",
			osRelease: "ID=ubuntu\nVERSION_ID=\"24.04\"\n",
			wantErr:   true,
		},
		{
			name:      "missing distribution metadata",
			targetOS:  "debian13",
			osRelease: "NAME=Debian\n",
			wantErr:   true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			osReleasePath := filepath.Join(t.TempDir(), "os-release")
			if err := os.WriteFile(osReleasePath, []byte(tt.osRelease), 0o600); err != nil {
				t.Fatal(err)
			}

			err := validateBuildHostOS(tt.targetOS, osReleasePath)
			if (err != nil) != tt.wantErr {
				t.Fatalf("validateBuildHostOS() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}
