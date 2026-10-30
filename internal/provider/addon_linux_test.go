// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"errors"
	"strings"
	"testing"
)

func TestRunCommand_RejectsInfraNodeSelectorWithoutSideEffects(t *testing.T) {
	p := &linuxAddonProvider{installDir: t.TempDir()}
	for name, cfg := range map[string]AddonRunCommandConfig{
		"script param":    {AddonName: "metrics", CommandName: "enable", Params: []string{" -InfraNodeSelector 'kubernetes.io/hostname=infra-1'"}},
		"parameter value": {AddonName: "metrics", CommandName: "enable", ParameterValues: map[string]string{"InfraNodeSelector": "kubernetes.io/hostname=infra-1"}},
	} {
		t.Run(name, func(t *testing.T) {
			err := p.RunCommand(cfg)
			if !errors.Is(err, ErrNotSupported) || !strings.Contains(err.Error(), "Windows-hosted") {
				t.Fatalf("expected NotSupportedError mentioning Windows-hosted clusters, got: %v", err)
			}
		})
	}
}

func TestRunCommand_WithoutSelectorIsUnaffected(t *testing.T) {
	p := &linuxAddonProvider{installDir: t.TempDir()}
	err := p.RunCommand(AddonRunCommandConfig{AddonName: "metrics", CommandName: "update", Params: []string{"-OmitGrafana"}})
	if !errors.Is(err, ErrNotSupported) || strings.Contains(err.Error(), "infra-node-selector") {
		t.Fatalf("expected the regular unsupported-command error, got: %v", err)
	}
}

func TestUpdateHostsContent_PreservesCoLocatedHostnames(t *testing.T) {
	initial := "127.0.0.1 localhost k2s.registry.local\n::1 localhost\n"
	updated := updateHostsContent(initial, "k2s.registry.local", "172.19.1.100")

	if !strings.Contains(updated, "127.0.0.1 localhost") {
		t.Fatalf("expected '127.0.0.1 localhost' to be preserved, got:\n%s", updated)
	}
	if !strings.Contains(updated, "172.19.1.100 k2s.registry.local") {
		t.Fatalf("expected '172.19.1.100 k2s.registry.local', got:\n%s", updated)
	}
	if strings.Contains(updated, "127.0.0.1 localhost k2s.registry.local") {
		t.Fatalf("did not expect old co-located entry to remain, got:\n%s", updated)
	}
}

func TestUpdateHostsContent_IdempotentWhenAlreadyPresent(t *testing.T) {
	initial := "127.0.0.1 localhost\n172.19.1.100 k2s.registry.local\n"
	updated := updateHostsContent(initial, "k2s.registry.local", "172.19.1.100")

	if updated != initial {
		t.Fatalf("expected content to be unchanged, got:\n%s", updated)
	}
}

func TestRemoveHostsContent_PreservesCoLocatedHostnames(t *testing.T) {
	initial := "127.0.0.1 localhost k2s.registry.local\n::1 localhost\n"
	updated := removeHostsContent(initial, "k2s.registry.local")

	if !strings.Contains(updated, "127.0.0.1 localhost") {
		t.Fatalf("expected '127.0.0.1 localhost' to be preserved, got:\n%s", updated)
	}
	if strings.Contains(updated, "k2s.registry.local") {
		t.Fatalf("expected 'k2s.registry.local' to be removed, got:\n%s", updated)
	}
}

func TestRemoveHostsContent_DropsLineWhenOnlyTargetHostname(t *testing.T) {
	initial := "127.0.0.1 localhost\n172.19.1.100 k2s.registry.local\n"
	updated := removeHostsContent(initial, "k2s.registry.local")

	if strings.Contains(updated, "172.19.1.100") || strings.Contains(updated, "k2s.registry.local") {
		t.Fatalf("expected standalone line to be dropped, got:\n%s", updated)
	}
	if !strings.Contains(updated, "127.0.0.1 localhost") {
		t.Fatalf("expected '127.0.0.1 localhost' to remain, got:\n%s", updated)
	}
}
