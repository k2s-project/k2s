// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package addonplacement

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestBundledOwningKustomizePlacement(t *testing.T) {
	if _, err := exec.LookPath("kubectl"); err != nil {
		t.Skip("offline kubectl renderer not installed")
	}
	for _, owner := range []string{
		"monitoring/manifests/monitoring", "monitoring/manifests/monitoring-no-grafana",
		"logging/manifests/logging", "registry/manifests/registry",
		"ingress/traefik/manifests", "ingress/nginx-gw/manifests", "common/manifests/external-dns",
	} {
		t.Run(owner, func(t *testing.T) {
			path := filepath.Join("..", "..", "..", "addons", filepath.FromSlash(owner))
			built, err := exec.Command("kubectl", "kustomize", path).CombinedOutput()
			if err != nil {
				t.Fatalf("build owner: %v\n%s", err, built)
			}
			output, changed, err := RenderManifestStream(built, "kubernetes.io/hostname=kubemaster")
			if err != nil || changed == 0 {
				t.Fatalf("render owner: changed=%d, err=%v", changed, err)
			}
			if _, err := WorkloadSelectors(output); err != nil {
				t.Fatal(err)
			}
			if owner == "monitoring/manifests/monitoring-no-grafana" && strings.Contains(strings.ToLower(string(output)), "grafana/grafana:") {
				t.Fatal("no-Grafana overlay includes the excluded Grafana image")
			}
		})
	}
}

func TestLocalPVPlacementRejectsStorageConflict(t *testing.T) {
	for _, owner := range []string{"registry/manifests/registry", "logging/manifests/logging"} {
		t.Run(owner, func(t *testing.T) {
			if _, err := exec.LookPath("kubectl"); err != nil {
				t.Skip("offline kubectl not installed")
			}
			input, err := exec.Command("kubectl", "kustomize", filepath.Join("..", "..", "..", "addons", filepath.FromSlash(owner))).Output()
			if err != nil {
				t.Fatal(err)
			}
			output, _, err := RenderStorageManifestStream(input, "kubernetes.io/hostname=kubemaster", "kubemaster")
			if err != nil || strings.Contains(string(output), "__STORAGE_NODE__") {
				t.Fatalf("compatible storage: %v", err)
			}
			if _, _, err := RenderStorageManifestStream(input, "kubernetes.io/hostname=worker", "kubemaster"); err == nil || !strings.Contains(err.Error(), "storage topology") {
				t.Fatalf("storage mismatch accepted: %v", err)
			}
		})
	}
}

func TestRenderManifestDirectory(t *testing.T) {
	manifestsDir := t.TempDir()
	manifest := `apiVersion: apps/v1
kind: Deployment
metadata:
  name: controller
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      containers: []
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-agent
spec:
  template:
    spec:
      containers: []
`
	if err := os.WriteFile(filepath.Join(manifestsDir, "workloads.yaml"), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}

	rendered, changed, err := RenderManifestDirectory(manifestsDir, "kubernetes.io/hostname=infra-1")
	if err != nil {
		t.Fatalf("RenderManifestDirectory() error = %v", err)
	}
	if changed != 1 {
		t.Fatalf("RenderManifestDirectory() changed = %d, want 1", changed)
	}
	if !strings.Contains(string(rendered), "kubernetes.io/os: linux") || !strings.Contains(string(rendered), "kubernetes.io/hostname: infra-1") {
		t.Fatalf("rendered manifest did not preserve and merge node selectors:\n%s", rendered)
	}
	if !strings.Contains(string(rendered), "kind: DaemonSet") {
		t.Fatalf("rendered manifest omitted node-local workload:\n%s", rendered)
	}
}

func TestRenderManifestDirectoryRejectsKustomizeInput(t *testing.T) {
	manifestsDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(manifestsDir, "kustomization.yaml"), []byte("resources: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	_, _, err := RenderManifestDirectory(manifestsDir, "key=value")
	if err == nil || !strings.Contains(err.Error(), "Kustomize input") {
		t.Fatalf("RenderManifestDirectory() error = %v, want unsupported Kustomize input", err)
	}
}

func TestRenderManifestDirectorySkipsRootGitopsSync(t *testing.T) {
	manifestsDir := t.TempDir()
	deployment := "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: controller\nspec:\n  template:\n    spec:\n      containers: []\n"
	syncDir := filepath.Join(manifestsDir, "gitops-sync")
	if err := os.Mkdir(syncDir, 0o700); err != nil {
		t.Fatal(err)
	}
	for name, content := range map[string]string{
		filepath.Join(manifestsDir, "workloads.yaml"): deployment,
		filepath.Join(syncDir, "kustomization.yaml"):  "resources:\n- sync-job.yaml\n",
		filepath.Join(syncDir, "sync-job.yaml"):       "apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: addon-sync-marker\n",
	} {
		if err := os.WriteFile(name, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	rendered, changed, err := RenderManifestDirectory(manifestsDir, "kubernetes.io/hostname=infra-1")
	if err != nil || changed != 1 {
		t.Fatalf("RenderManifestDirectory() changed = %d, err = %v", changed, err)
	}
	if strings.Contains(string(rendered), "addon-sync-marker") {
		t.Fatalf("gitops-sync content leaked into rendered output:\n%s", rendered)
	}

	nested := filepath.Join(manifestsDir, "other", "gitops-sync")
	if err := os.MkdirAll(nested, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(nested, "kustomization.yaml"), []byte("resources: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := RenderManifestDirectory(manifestsDir, "kubernetes.io/hostname=infra-1"); err == nil || !strings.Contains(err.Error(), "Kustomize input") {
		t.Fatalf("nested gitops-sync kustomization accepted: %v", err)
	}
}

func TestRenderManifestDirectoryRejectsKustomizeOutsideGitopsSync(t *testing.T) {
	manifestsDir := t.TempDir()
	if err := os.Mkdir(filepath.Join(manifestsDir, "gitops-sync"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(manifestsDir, "gitops-sync", "kustomization.yaml"), []byte("resources: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(manifestsDir, "kustomization.yaml"), []byte("resources: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := RenderManifestDirectory(manifestsDir, "key=value"); err == nil || !strings.Contains(err.Error(), "Kustomize input") {
		t.Fatalf("root kustomization accepted: %v", err)
	}
}

func TestSupportsAddonOnlyAllowsIntegratedAddons(t *testing.T) {
	for _, addonName := range []string{"metrics", "monitoring", "logging", "dashboard", "registry", "ingress"} {
		if !SupportsAddon(addonName) {
			t.Errorf("SupportsAddon(%q) = false, want true", addonName)
		}
	}
	for _, addonName := range []string{"kubevirt", "autoscaling", "viewer", "dicom", "rollout", "security", "storage", "gpu-node"} {
		if SupportsAddon(addonName) {
			t.Errorf("SupportsAddon(%q) = true, want false", addonName)
		}
	}
}
