// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"archive/tar"
	"compress/gzip"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestLinuxAddonBackupRestoreRejectsUnsupportedAddon(t *testing.T) {
	p := newLinuxAddonProvider(ProviderConfig{})
	for _, command := range []string{"backup", "restore"} {
		t.Run(command, func(t *testing.T) {
			err := p.RunCommand(AddonRunCommandConfig{AddonName: "metrics", CommandName: command})
			if !errors.Is(err, ErrNotSupported) {
				t.Fatalf("expected unsupported-operation error, got %v", err)
			}
		})
	}
}

func TestRegistryDataArchiveRoundTripReplacesExistingData(t *testing.T) {
	registryDir := t.TempDir()
	repositoryDir := filepath.Join(registryDir, "repository")
	if err := os.MkdirAll(repositoryDir, 0o755); err != nil {
		t.Fatal(err)
	}
	markerPath := filepath.Join(repositoryDir, "marker")
	if err := os.WriteFile(markerPath, []byte("saved registry data"), 0o600); err != nil {
		t.Fatal(err)
	}
	archivePath := filepath.Join(t.TempDir(), registryBackupArchive)

	if err := createRegistryDataArchive(registryDir, archivePath); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repositoryDir, "stale"), []byte("not in archive"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := extractRegistryDataArchive(archivePath, registryDir); err != nil {
		t.Fatal(err)
	}

	got, err := os.ReadFile(markerPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "saved registry data" {
		t.Fatalf("restored marker = %q", got)
	}
	if _, err := os.Stat(filepath.Join(repositoryDir, "stale")); !os.IsNotExist(err) {
		t.Fatalf("stale repository file should be removed, stat error = %v", err)
	}
}

func TestExtractRegistryDataArchiveRejectsTraversalWithoutReplacingData(t *testing.T) {
	registryDir := t.TempDir()
	repositoryDir := filepath.Join(registryDir, "repository")
	if err := os.MkdirAll(repositoryDir, 0o755); err != nil {
		t.Fatal(err)
	}
	markerPath := filepath.Join(repositoryDir, "marker")
	if err := os.WriteFile(markerPath, []byte("existing data"), 0o600); err != nil {
		t.Fatal(err)
	}
	archivePath := filepath.Join(t.TempDir(), "malicious.tar.gz")
	writeRegistryTestArchive(t, archivePath, "repository/../../escape", "bad")

	if err := extractRegistryDataArchive(archivePath, registryDir); err == nil {
		t.Fatal("expected archive traversal to be rejected")
	}
	if _, err := os.Stat(filepath.Join(registryDir, "escape")); !os.IsNotExist(err) {
		t.Fatalf("archive wrote outside the repository, stat error = %v", err)
	}
	got, err := os.ReadFile(markerPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "existing data" {
		t.Fatalf("existing repository marker changed to %q", got)
	}
}

func TestRegistryDataArchiveAcceptsTrailingSlashDirectoryEntries(t *testing.T) {
	registryDir := t.TempDir()
	archivePath := filepath.Join(t.TempDir(), registryBackupArchive)

	file, err := os.Create(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	gz := gzip.NewWriter(file)
	tw := tar.NewWriter(gz)
	for _, dir := range []string{"repository/", "repository/sub/"} {
		if err := tw.WriteHeader(&tar.Header{Name: dir, Mode: 0o755, Typeflag: tar.TypeDir}); err != nil {
			t.Fatal(err)
		}
	}
	content := "gnu tar marker"
	if err := tw.WriteHeader(&tar.Header{Name: "repository/sub/marker", Mode: 0o600, Size: int64(len(content)), Typeflag: tar.TypeReg}); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write([]byte(content)); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	if err := validateRegistryDataArchive(archivePath); err != nil {
		t.Fatalf("validateRegistryDataArchive() error = %v", err)
	}
	if err := extractRegistryDataArchive(archivePath, registryDir); err != nil {
		t.Fatalf("extractRegistryDataArchive() error = %v", err)
	}

	got, err := os.ReadFile(filepath.Join(registryDir, "repository", "sub", "marker"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != content {
		t.Fatalf("restored marker = %q, want %q", got, content)
	}
}

func writeRegistryTestArchive(t *testing.T, path, name, content string) {
	t.Helper()
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	gz := gzip.NewWriter(file)
	tw := tar.NewWriter(gz)
	if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o600, Size: int64(len(content)), Typeflag: tar.TypeReg}); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write([]byte(content)); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
}
