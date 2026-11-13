//go:build linux

// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package nodepackage

import (
	"os"
	"path/filepath"
	"strings"
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

func TestEnvironmentWithOverridesReplacesExistingValues(t *testing.T) {
	const key = "K2S_TEST_APT_CONFIG"
	t.Setenv(key, "original")

	values := environmentWithOverrides(map[string]string{key: "isolated"})
	count := 0
	for _, entry := range values {
		if strings.HasPrefix(entry, key+"=") {
			count++
			if entry != key+"=isolated" {
				t.Fatalf("environment value = %q, want %q", entry, key+"=isolated")
			}
		}
	}
	if count != 1 {
		t.Fatalf("found %d entries for %s, want exactly one", count, key)
	}
}

func TestRestoreFilesRestoresExistingFilesAndRemovesNewFiles(t *testing.T) {
	dir := t.TempDir()
	existingPath := filepath.Join(dir, "existing.list")
	newPath := filepath.Join(dir, "new.list")
	if err := os.WriteFile(existingPath, []byte("original"), 0o640); err != nil {
		t.Fatal(err)
	}

	snapshots, err := snapshotFiles([]string{existingPath, newPath})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(existingPath, []byte("modified"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(newPath, []byte("new"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := restoreFiles(snapshots); err != nil {
		t.Fatal(err)
	}

	content, err := os.ReadFile(existingPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "original" {
		t.Fatalf("restored content = %q, want %q", content, "original")
	}
	info, err := os.Stat(existingPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o640 {
		t.Fatalf("restored mode = %o, want %o", info.Mode().Perm(), 0o640)
	}
	if _, err := os.Stat(newPath); !os.IsNotExist(err) {
		t.Fatalf("new file still exists or could not be checked: %v", err)
	}
}

func TestRestoreFilesRestoresSymlinks(t *testing.T) {
	dir := t.TempDir()
	targetPath := filepath.Join(dir, "target")
	linkPath := filepath.Join(dir, "source.list")
	if err := os.WriteFile(targetPath, []byte("original target"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(targetPath, linkPath); err != nil {
		t.Fatal(err)
	}

	snapshots, err := snapshotFiles([]string{linkPath})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(targetPath, []byte("modified target"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(linkPath); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(linkPath, []byte("replacement"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := restoreFiles(snapshots); err != nil {
		t.Fatal(err)
	}
	linkTarget, err := os.Readlink(linkPath)
	if err != nil {
		t.Fatal(err)
	}
	if linkTarget != targetPath {
		t.Fatalf("restored symlink target = %q, want %q", linkTarget, targetPath)
	}
	content, err := os.ReadFile(targetPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "original target" {
		t.Fatalf("restored symlink target content = %q, want %q", content, "original target")
	}
	info, err := os.Stat(targetPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o640 {
		t.Fatalf("restored symlink target mode = %o, want %o", info.Mode().Perm(), 0o640)
	}
}
