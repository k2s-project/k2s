// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package restore

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadAndValidateManifestSupportsOptionalInfrastructureSelector(t *testing.T) {
	tests := []struct {
		name     string
		content  string
		selector string
	}{
		{
			name:    "legacy manifest",
			content: `{"k2sVersion":"1.0","addon":"metrics","files":[]}`,
		},
		{
			name:     "manifest with selector",
			content:  `{"k2sVersion":"1.0","addon":"metrics","files":[],"infraNodeSelector":"kubernetes.io/hostname=infra-1"}`,
			selector: "kubernetes.io/hostname=infra-1",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			manifestPath := filepath.Join(t.TempDir(), "backup.json")
			if err := os.WriteFile(manifestPath, []byte(test.content), 0o600); err != nil {
				t.Fatal(err)
			}

			manifest, err := readAndValidateManifest(manifestPath)
			if err != nil {
				t.Fatalf("readAndValidateManifest() error = %v", err)
			}
			if manifest.InfraNodeSelector != test.selector {
				t.Fatalf("selector = %q, want %q", manifest.InfraNodeSelector, test.selector)
			}
		})
	}
}

func TestSelectorEnableParamsOnlyTargetsSupportedAddons(t *testing.T) {
	manifest := backupManifest{InfraNodeSelector: "kubernetes.io/hostname=infra-1"}
	for _, addon := range []string{"metrics", "dashboard", "monitoring", "logging", "registry", "ingress"} {
		if got := selectorEnableParams(addon, manifest); len(got) != 1 {
			t.Fatalf("%s selector args = %v, want one argument", addon, got)
		}
	}
	for _, addon := range []string{"kubevirt", "autoscaling", "viewer", "dicom", "rollout", "security", "storage", "gpu-node"} {
		if got := selectorEnableParams(addon, manifest); len(got) != 0 {
			t.Fatalf("unsupported addon %s selector args = %v, want none", addon, got)
		}
	}
}

func TestValidateManifestTargetsRejectsDroppingUnintegratedPlacement(t *testing.T) {
	manifest := backupManifest{Addon: "gpu-node", InfraNodeSelector: "kubernetes.io/hostname=kubemaster"}
	if err := validateManifestTargets(manifest, "gpu-node", "gpu-node"); err == nil {
		t.Fatal("restore silently dropped a saved selector for an unintegrated owner")
	}
	manifest.Addon = "metrics"
	if err := validateManifestTargets(manifest, "metrics", "metrics"); err != nil {
		t.Fatalf("integrated owner cannot replay placement: %v", err)
	}
}

func TestValidateManifestTargetsRejectsConflictingIdentityAndInvalidPlacement(t *testing.T) {
	if err := validateManifestTargets(backupManifest{Addon: "storage", Implementation: "ceph", InfraNodeSelector: "pool=infra"}, "storage", "ceph"); err == nil {
		t.Fatal("unsupported storage restore accepted")
	}
	for _, manifest := range []backupManifest{
		{Addon: "ingress", Implementation: "traefik", InfraNodeSelector: "pool=infra"},
		{Addon: "ingress", Implementation: "nginx", InfraNodeSelector: "pool=infra,pool=other"},
	} {
		if err := validateManifestTargets(manifest, "ingress", "nginx"); err == nil {
			t.Fatalf("invalid restore accepted: %+v", manifest)
		}
	}
}
