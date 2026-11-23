//go:build linux

// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package provider

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestLinuxNodeAddRejectsMissingArguments(t *testing.T) {
	p := &linuxNodeProvider{installDir: t.TempDir()}

	if err := p.Add(NodeAddConfig{UserName: "debian", NodePackagePath: "/tmp/node.zip"}); err == nil || !strings.Contains(err.Error(), "--ip-addr") {
		t.Fatalf("Add() without IP: got %v, want an --ip-addr error", err)
	}
	if err := p.Add(NodeAddConfig{IpAddress: "10.10.0.20", NodePackagePath: "/tmp/node.zip"}); err == nil || !strings.Contains(err.Error(), "--username") {
		t.Fatalf("Add() without user: got %v, want a --username error", err)
	}
}

func TestLinuxNodeAddRequiresNodePackage(t *testing.T) {
	p := &linuxNodeProvider{installDir: t.TempDir()}

	err := p.Add(NodeAddConfig{IpAddress: "10.10.0.20", UserName: "debian"})
	if err == nil || !strings.Contains(err.Error(), "--node-package") {
		t.Fatalf("Add() without package: got %v, want a --node-package error", err)
	}
}

func TestLinuxNodeAddFailsWhenScriptIsMissing(t *testing.T) {
	p := &linuxNodeProvider{installDir: t.TempDir()}

	err := p.Add(NodeAddConfig{IpAddress: "10.10.0.20", UserName: "debian", NodePackagePath: "/tmp/node.zip"})
	if err == nil || !strings.Contains(err.Error(), "Add.sh") {
		t.Fatalf("Add() with empty install dir: got %v, want a missing Add.sh error", err)
	}
}

func TestLinuxNodeAddReportsUnsupportedNodeAsWarning(t *testing.T) {
	p := &linuxNodeProvider{installDir: installFakeNodeAddScript(t, 3)}

	err := p.Add(NodeAddConfig{IpAddress: "10.10.0.20", UserName: "debian", NodePackagePath: "/tmp/node.zip"})

	var failure *ProviderFailure
	if !errors.As(err, &failure) {
		t.Fatalf("Add() for an unsupported node: got %v, want a ProviderFailure", err)
	}
	if failure.Severity != SeverityWarning || failure.Code != "node-os-not-supported" || failure.Message != "node rejected" {
		t.Fatalf("Add() for an unsupported node: got %+v, want a node-os-not-supported warning with the script's last error line", failure)
	}
}

func TestLinuxNodeAddReportsScriptFailureWithReason(t *testing.T) {
	p := &linuxNodeProvider{installDir: installFakeNodeAddScript(t, 1)}

	err := p.Add(NodeAddConfig{IpAddress: "10.10.0.20", UserName: "debian", NodePackagePath: "/tmp/node.zip"})

	var failure *ProviderFailure
	if err == nil || errors.As(err, &failure) {
		t.Fatalf("Add() with a failing script: got %v, want a plain error", err)
	}
	for _, expected := range []string{"10.10.0.20", "node rejected", "see log file"} {
		if !strings.Contains(err.Error(), expected) {
			t.Fatalf("Add() with a failing script: got %q, want it to contain %q", err, expected)
		}
	}
}

func installFakeNodeAddScript(t *testing.T, exitCode int) string {
	t.Helper()
	installDir := t.TempDir()
	scriptDir := filepath.Join(installDir, "lib", "scripts", "linux", "debian", "worker", "bare-metal")
	if err := os.MkdirAll(scriptDir, 0o700); err != nil {
		t.Fatal(err)
	}
	script := "printf '%s\\n' 'first error' 'node rejected' >&2\nexit " + strconv.Itoa(exitCode) + "\n"
	if err := os.WriteFile(filepath.Join(scriptDir, "Add.sh"), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	return installDir
}
