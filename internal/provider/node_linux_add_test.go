//go:build linux

// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package provider

import (
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
