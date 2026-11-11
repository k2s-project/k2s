// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package lifecycle

import (
	"path/filepath"
	"testing"
)

func TestScriptPath(t *testing.T) {
	t.Parallel()

	path, err := ScriptPath("/opt/k2s", LinuxOnly, "Install")
	if err != nil {
		t.Fatalf("ScriptPath() returned error: %v", err)
	}
	want := filepath.Join("/opt/k2s", "lib", "scripts", "linux", "debian", "linuxonly", "Install.sh")
	if path != want {
		t.Errorf("ScriptPath() = %q, want %q", path, want)
	}
}

func TestScriptPathResolvesCompact(t *testing.T) {
	t.Parallel()

	path, err := ScriptPath("/opt/k2s", LinuxOnly, "Compact")
	if err != nil {
		t.Fatalf("ScriptPath() returned error: %v", err)
	}
	want := filepath.Join("/opt/k2s", "lib", "scripts", "linux", "debian", "linuxonly", "Compact.sh")
	if path != want {
		t.Errorf("ScriptPath() = %q, want %q", path, want)
	}
}

func TestScriptPathRejectsUnknownScopeAndOperation(t *testing.T) {
	t.Parallel()

	if _, err := ScriptPath("/opt/k2s", "worker", "Install"); err == nil {
		t.Fatal("ScriptPath() accepted unsupported scope")
	}
	if _, err := ScriptPath("/opt/k2s", LinuxOnly, "Upgrade"); err == nil {
		t.Fatal("ScriptPath() accepted unsupported operation")
	}
}

func TestProvisioningScriptPath(t *testing.T) {
	t.Parallel()

	got := ProvisioningScriptPath("/opt/k2s")
	want := filepath.Join("/opt/k2s", "lib", "scripts", "linux", "debian", "linuxonly", "ProvisionPackages.sh")
	if got != want {
		t.Errorf("ProvisioningScriptPath() = %q, want %q", got, want)
	}
}
