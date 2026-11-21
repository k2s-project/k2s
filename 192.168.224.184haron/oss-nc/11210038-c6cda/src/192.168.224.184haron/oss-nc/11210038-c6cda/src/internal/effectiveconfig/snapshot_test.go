// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package effectiveconfig

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/k2s-project/k2s/internal/definitions"
)

func TestStageRejectsEmptyContent(t *testing.T) {
	if _, err := Stage(t.TempDir(), nil); err == nil {
		t.Fatal("Stage() expected an error for empty content")
	}
}

func TestAbortRemovesStagedSnapshot(t *testing.T) {
	snapshot, err := Stage(t.TempDir(), []byte(`{"kind":"k2s"}`))
	if err != nil {
		t.Fatalf("Stage() error = %v", err)
	}
	path := snapshot.Path()

	if err := snapshot.Abort(); err != nil {
		t.Fatalf("Abort() error = %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("staged snapshot still exists, stat error = %v", err)
	}
}

func TestCommitReplacesSnapshotAndLinksSetup(t *testing.T) {
	dir := t.TempDir()
	setupPath := filepath.Join(dir, definitions.K2sRuntimeConfigFileName)
	if err := os.WriteFile(setupPath, []byte(`{"SetupType":"k2s"}`), restrictedFileMode); err != nil {
		t.Fatalf("failed to create setup file: %v", err)
	}

	content := []byte(`{"kind":"k2s","apiVersion":"v1"}`)
	snapshot, err := Stage(dir, content)
	if err != nil {
		t.Fatalf("Stage() error = %v", err)
	}
	if err := snapshot.Commit(); err != nil {
		t.Fatalf("Commit() error = %v", err)
	}

	targetPath := filepath.Join(dir, definitions.EffectiveInstallConfigFileName)
	actual, err := os.ReadFile(targetPath)
	if err != nil {
		t.Fatalf("failed to read committed snapshot: %v", err)
	}
	if string(actual) != string(content) {
		t.Fatalf("committed snapshot = %q, want %q", actual, content)
	}

	setupContent, err := os.ReadFile(setupPath)
	if err != nil {
		t.Fatalf("failed to read setup file: %v", err)
	}
	var setup map[string]any
	if err := json.Unmarshal(setupContent, &setup); err != nil {
		t.Fatalf("failed to parse setup file: %v", err)
	}
	if setup[definitions.EffectiveInstallConfigPathKey] != targetPath {
		t.Fatalf("snapshot link = %v, want %q", setup[definitions.EffectiveInstallConfigPathKey], targetPath)
	}
}

func TestCommitCleansStagedSnapshotWhenPreservingPreviousFails(t *testing.T) {
	dir := t.TempDir()
	targetPath := filepath.Join(dir, definitions.EffectiveInstallConfigFileName)
	if err := os.Mkdir(targetPath, 0o700); err != nil {
		t.Fatalf("failed to create target directory: %v", err)
	}

	snapshot, err := Stage(dir, []byte(`{"kind":"candidate"}`))
	if err != nil {
		t.Fatalf("Stage() error = %v", err)
	}
	stagedPath := snapshot.Path()

	if err := snapshot.Commit(); err == nil {
		t.Fatal("Commit() expected a snapshot preservation error")
	}
	if _, err := os.Stat(stagedPath); !os.IsNotExist(err) {
		t.Fatalf("staged snapshot still exists, stat error = %v", err)
	}
}

func TestCommitRestoresPreviousSnapshotWhenLinkFails(t *testing.T) {
	dir := t.TempDir()
	targetPath := filepath.Join(dir, definitions.EffectiveInstallConfigFileName)
	previous := []byte(`{"kind":"previous"}`)
	if err := os.WriteFile(targetPath, previous, restrictedFileMode); err != nil {
		t.Fatalf("failed to create previous snapshot: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, definitions.K2sRuntimeConfigFileName), []byte("invalid"), restrictedFileMode); err != nil {
		t.Fatalf("failed to create invalid setup file: %v", err)
	}

	snapshot, err := Stage(dir, []byte(`{"kind":"candidate"}`))
	if err != nil {
		t.Fatalf("Stage() error = %v", err)
	}
	if err := snapshot.Commit(); err == nil {
		t.Fatal("Commit() expected a setup link error")
	}

	actual, err := os.ReadFile(targetPath)
	if err != nil {
		t.Fatalf("failed to read restored snapshot: %v", err)
	}
	if string(actual) != string(previous) {
		t.Fatalf("restored snapshot = %q, want %q", actual, previous)
	}
}
