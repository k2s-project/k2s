// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"maps"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/k2s-project/k2s/internal/core/addons"
	"github.com/k2s-project/k2s/internal/core/clusterconfig"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/host"
	"github.com/k2s-project/k2s/internal/json"
	"github.com/k2s-project/k2s/internal/providers/bash"
	"gopkg.in/yaml.v3"
)

type linuxAddonProvider struct {
	installDir string
	configDir  string
}

func newLinuxAddonProvider(cfg ProviderConfig) *linuxAddonProvider {
	return &linuxAddonProvider{
		installDir: cfg.InstallDir,
		configDir:  cfg.ConfigDir,
	}
}

// addonManifest is the minimal structure parsed from addon.manifest.yaml.
type addonManifest struct {
	Metadata struct {
		Name        string `yaml:"name"`
		Description string `yaml:"description"`
	} `yaml:"metadata"`
}

const (
	addRegistryScript    = "Add-Registry.sh"
	removeRegistryScript = "Remove-Registry.sh"
)

func init() {
	if os.Getenv("KUBECONFIG") == "" {
		if _, err := os.Stat("/etc/kubernetes/admin.conf"); err == nil {
			_ = os.Setenv("KUBECONFIG", "/etc/kubernetes/admin.conf")
		}
	}
}

func (p *linuxAddonProvider) loadManifest(addonName string) (*addonManifest, error) {
	manifestPath := filepath.Join(p.installDir, "addons", addonName, "addon.manifest.yaml")
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return nil, fmt.Errorf("cannot read addon manifest for '%s': %w", addonName, err)
	}
	var m addonManifest
	if err := yaml.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("cannot parse addon manifest for '%s': %w", addonName, err)
	}
	return &m, nil
}

func (p *linuxAddonProvider) Enable(cfg AddonEnableConfig) error {
	slog.Info("[Addon] Enabling addon", "name", cfg.Name, "implementation", cfg.Implementation)

	if err := rejectInfraNodeSelector(cfg.Params, nil); err != nil {
		return err
	}

	if cfg.Name == "registry" {
		return p.enableRegistry(cfg)
	}
	if cfg.Name == "ingress" {
		return p.enableIngress(cfg)
	}

	manifestsDir := filepath.Join(p.installDir, "addons", cfg.Name, "manifests")
	if _, err := os.Stat(manifestsDir); err != nil {
		return fmt.Errorf("addon manifests directory not found for '%s': %w", cfg.Name, err)
	}

	// Apply all YAML manifests in the addon's manifests/ directory
	if err := exec.Command("kubectl", "apply", "-f", manifestsDir, "--recursive").Run(); err != nil {
		return fmt.Errorf("kubectl apply failed for addon '%s': %w", cfg.Name, err)
	}

	// Wait for addon pods to be ready (best-effort, 120s timeout)
	slog.Info("[Addon] Waiting for addon pods to be ready", "name", cfg.Name)
	deadline := time.Now().Add(120 * time.Second)
	for time.Now().Before(deadline) {
		output, err := exec.Command("kubectl", "get", "pods", "-A",
			"-l", fmt.Sprintf("app.kubernetes.io/name=%s", cfg.Name),
			"-o", "jsonpath={.items[*].status.conditions[?(@.type=='Ready')].status}").Output()
		if err == nil {
			statuses := strings.Fields(string(output))
			if len(statuses) > 0 {
				allReady := true
				for _, s := range statuses {
					if s != "True" {
						allReady = false
						break
					}
				}
				if allReady {
					slog.Info("[Addon] Addon pods are ready", "name", cfg.Name)
					break
				}
			}
		}
		time.Sleep(3 * time.Second)
	}

	slog.Info("[Addon] Addon enabled", "name", cfg.Name)
	return nil
}

func (p *linuxAddonProvider) enableRegistry(cfg AddonEnableConfig) error {
	if p.isAddonEnabledInConfig("registry") {
		return fmt.Errorf("addon 'registry' is already enabled, nothing to do")
	}

	ingressType := cfg.Params["ingress"]
	if ingressType != "" && ingressType != "none" {
		if ingressType != "nginx" && ingressType != "traefik" && ingressType != "nginx-gw" {
			return fmt.Errorf("ingress implementation '%s' is not supported", ingressType)
		}
		if !p.isAddonEnabledInConfig("ingress", ingressType) {
			if err := p.enableIngress(AddonEnableConfig{Name: "ingress", Implementation: ingressType, ShowOutput: cfg.ShowOutput}); err != nil {
				return fmt.Errorf("auto-enabling ingress %s for registry failed: %w", ingressType, err)
			}
		}
	}

	// 1. Create storage directory on host
	_ = exec.Command("sudo", "mkdir", "-p", "/registry", "/registry/auth", "/registry/repository").Run()

	// 2. Create registry namespace
	_ = exec.Command("kubectl", "create", "namespace", "registry").Run()

	// 3. Render registry manifests to a temporary directory without modifying installDir
	registryManifestsDir := filepath.Join(p.installDir, "addons", "registry", "manifests", "registry")
	tmpManifestsDir, err := os.MkdirTemp("", "k2s-registry-manifests-*")
	if err != nil {
		return fmt.Errorf("creating temp directory for registry manifests: %w", err)
	}
	defer os.RemoveAll(tmpManifestsDir)

	entries, err := os.ReadDir(registryManifestsDir)
	if err != nil {
		return fmt.Errorf("reading registry manifests dir: %w", err)
	}
	storageNode := getNodeName()
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		srcPath := filepath.Join(registryManifestsDir, entry.Name())
		dstPath := filepath.Join(tmpManifestsDir, entry.Name())
		data, err := os.ReadFile(srcPath)
		if err != nil {
			return fmt.Errorf("reading %s: %w", entry.Name(), err)
		}
		if entry.Name() == "persistent-volume.yaml" {
			data = []byte(strings.Replace(string(data), "__STORAGE_NODE__", storageNode, 1))
		}
		if err := os.WriteFile(dstPath, data, 0o644); err != nil {
			return fmt.Errorf("writing rendered %s: %w", entry.Name(), err)
		}
	}

	// 4. Apply registry kustomize manifests from temp directory
	cmd := exec.Command("kubectl", "apply", "-k", tmpManifestsDir)
	if cfg.ShowOutput {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("kubectl apply -k registry failed: %w", err)
	}

	// 5. Wait for registry statefulset rollout
	rolloutCmd := exec.Command("kubectl", "rollout", "status", "statefulset/registry", "-n", "registry", "--timeout=180s")
	if cfg.ShowOutput {
		rolloutCmd.Stdout = os.Stdout
		rolloutCmd.Stderr = os.Stderr
	}
	if err := rolloutCmd.Run(); err != nil {
		return fmt.Errorf("registry rollout failed: %w", err)
	}

	// 6. Ensure /etc/hosts has k2s.registry.local pointing to node IP
	nodeIP := getNodeIP()
	if nodeIP != "" && nodeIP != "127.0.0.1" {
		setHostEntry("k2s.registry.local", nodeIP)
	} else {
		setHostEntry("k2s.registry.local", "127.0.0.1")
	}

	// 7. Update setup.json and configure ingress / nodeport
	_ = p.addAddonToConfig("registry", "")
	_ = p.updateRegistryIngress()

	return nil
}

func (p *linuxAddonProvider) enableIngress(cfg AddonEnableConfig) error {
	impl := cfg.Implementation
	if impl == "" {
		impl = "nginx"
	}

	// 1. Conflict checks
	if p.isAddonEnabledInConfig("ingress", impl) {
		return fmt.Errorf("addon 'ingress %s' is already enabled, nothing to do", impl)
	}
	for _, other := range []string{"nginx", "traefik", "nginx-gw"} {
		if other != impl && p.isAddonEnabledInConfig("ingress", other) {
			return fmt.Errorf("addon 'ingress %s' is enabled. Disable it first to avoid port conflicts", other)
		}
	}
	if p.isAddonEnabledInConfig("gateway-api") {
		return fmt.Errorf("addon 'gateway-api' is enabled. Disable it first to avoid port conflicts")
	}

	omitCertMgr := cfg.Params != nil && (cfg.Params["omitcertmgr"] == "true" || cfg.Params["omit-cert-mgr"] == "true")
	if !omitCertMgr {
		_ = p.enableCertManager(cfg.ShowOutput)
	} else {
		if impl == "nginx-gw" {
			fmt.Println("[ingress nginx-gw] WARNING: cert-manager omitted. TLS certificates must be provided manually for HTTPS to function.")
		} else {
			fmt.Printf("[ingress %s] Skipping cert-manager installation (--omitCertMgr)\n", impl)
		}
	}

	nodeIP := getNodeIP()
	if nodeIP == "" {
		nodeIP = "127.0.0.1"
	}

	switch impl {
	case "nginx":
		_ = exec.Command("kubectl", "create", "namespace", "ingress-nginx").Run()
		manifestFile := filepath.Join(p.installDir, "addons", "ingress", "nginx", "manifests", "ingress-nginx.yaml")
		cmd := exec.Command("kubectl", "apply", "-f", manifestFile)
		if cfg.ShowOutput {
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
		}
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("kubectl apply ingress-nginx failed: %w", err)
		}

		if nodeIP != "127.0.0.1" {
			patchJson := fmt.Sprintf(`{"spec":{"externalIPs":["%s"]}}`, nodeIP)
			_ = exec.Command("kubectl", "patch", "svc", "ingress-nginx-controller", "-n", "ingress-nginx", "-p", patchJson).Run()
		}

		rolloutCmd := exec.Command("kubectl", "rollout", "status", "deployment/ingress-nginx-controller", "-n", "ingress-nginx", "--timeout=180s")
		if cfg.ShowOutput {
			rolloutCmd.Stdout = os.Stdout
			rolloutCmd.Stderr = os.Stderr
		}
		if err := rolloutCmd.Run(); err != nil {
			return fmt.Errorf("ingress controller rollout failed: %w", err)
		}

		clusterLocal := filepath.Join(p.installDir, "addons", "ingress", "nginx", "manifests", "cluster-local-ingress.yaml")
		if _, err := os.Stat(clusterLocal); err == nil {
			_ = exec.Command("kubectl", "apply", "-f", clusterLocal).Run()
		}

	case "traefik":
		if err := p.ensureGatewayApiCrds(); err != nil {
			slog.Warn("[Addon] ensuring gateway-api crds returned error", "error", err)
		}

		_ = exec.Command("kubectl", "create", "namespace", "ingress-traefik").Run()

		traefikManifestsDir := filepath.Join(p.installDir, "addons", "ingress", "traefik", "manifests")
		cmd := exec.Command("kubectl", "apply", "-k", traefikManifestsDir)
		if cfg.ShowOutput {
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
		}
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("kubectl apply traefik manifests failed: %w", err)
		}

		if nodeIP != "127.0.0.1" {
			patchSvcJson := fmt.Sprintf(`{"spec":{"externalIPs":["%s"]}}`, nodeIP)
			_ = exec.Command("kubectl", "patch", "svc", "traefik", "-n", "ingress-traefik", "-p", patchSvcJson).Run()

			patchDepJson := fmt.Sprintf(`[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--providers.kubernetesIngress.ingressEndpoint"},{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--providers.kubernetesIngress.ingressEndpoint.ip=%s"}]`, nodeIP)
			_ = exec.Command("kubectl", "patch", "deployment", "traefik", "-n", "ingress-traefik", "--type=json", "-p", patchDepJson).Run()
		}

		rolloutCmd := exec.Command("kubectl", "rollout", "status", "deployment/traefik", "-n", "ingress-traefik", "--timeout=180s")
		if cfg.ShowOutput {
			rolloutCmd.Stdout = os.Stdout
			rolloutCmd.Stderr = os.Stderr
		}
		if err := rolloutCmd.Run(); err != nil {
			return fmt.Errorf("traefik rollout failed: %w", err)
		}

		clusterLocal := filepath.Join(p.installDir, "addons", "ingress", "traefik", "manifests", "cluster-local-ingress.yaml")
		if _, err := os.Stat(clusterLocal); err == nil {
			_ = exec.Command("kubectl", "apply", "-f", clusterLocal).Run()
		}

	case "nginx-gw":
		if err := p.ensureGatewayApiCrds(); err != nil {
			slog.Warn("[Addon] ensuring gateway-api crds returned error", "error", err)
		}

		ngfCrdsDir := filepath.Join(p.installDir, "addons", "ingress", "nginx-gw", "manifests", "crds")
		var crdErr error
		for attempt := 0; attempt < 3; attempt++ {
			cmdCrds := exec.Command("kubectl", "apply", "--server-side", "--force-conflicts", "--request-timeout=30s", "-f", ngfCrdsDir)
			if cfg.ShowOutput {
				cmdCrds.Stdout = os.Stdout
				cmdCrds.Stderr = os.Stderr
			}
			if err := cmdCrds.Run(); err == nil {
				crdErr = nil
				break
			} else {
				crdErr = err
				time.Sleep(2 * time.Second)
			}
		}
		if crdErr != nil {
			return fmt.Errorf("applying nginx-gw crds failed: %w", crdErr)
		}
		_ = exec.Command("kubectl", "wait", "--for=condition=Established", "crd/nginxproxies.gateway.nginx.org", "--timeout=60s").Run()

		_ = exec.Command("kubectl", "create", "namespace", "nginx-gw").Run()

		ngfManifestsDir := filepath.Join(p.installDir, "addons", "ingress", "nginx-gw", "manifests")
		cmd := exec.Command("kubectl", "apply", "-k", ngfManifestsDir)
		if cfg.ShowOutput {
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
		}
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("kubectl apply nginx-gw manifests failed: %w", err)
		}

		proxyTmpl := filepath.Join(p.installDir, "addons", "ingress", "nginx-gw", "manifests", "nginxproxy.yaml")
		proxyBytes, err := os.ReadFile(proxyTmpl)
		if err == nil {
			renderedProxy := strings.ReplaceAll(string(proxyBytes), "__CONTROL_PLANE_IP__", nodeIP)
			applyProxyCmd := exec.Command("kubectl", "apply", "--server-side", "--force-conflicts", "-f", "-")
			applyProxyCmd.Stdin = strings.NewReader(renderedProxy)
			if err := applyProxyCmd.Run(); err != nil {
				slog.Warn("[Addon] applying nginxproxy.yaml returned error", "error", err)
			}
		}

		rolloutCmd := exec.Command("kubectl", "rollout", "status", "deployment/nginx-gw-controller", "-n", "nginx-gw", "--timeout=180s")
		if cfg.ShowOutput {
			rolloutCmd.Stdout = os.Stdout
			rolloutCmd.Stderr = os.Stderr
		}
		if err := rolloutCmd.Run(); err != nil {
			return fmt.Errorf("nginx-gw rollout failed: %w", err)
		}

		_ = ensureTlsSecret("nginx-gw", "k2s-cluster-local-tls", "k2s.cluster.local")
		_ = ensureTlsSecret("nginx-gw", "k2s-registry-local-tls", "k2s.registry.local")

		if !omitCertMgr {
			certFile := filepath.Join(p.installDir, "addons", "ingress", "nginx-gw", "manifests", "k2s-cluster-local-tls-certificate.yaml")
			_ = exec.Command("kubectl", "apply", "-f", certFile).Run()
		}

		clusterLocal := filepath.Join(p.installDir, "addons", "ingress", "nginx-gw", "manifests", "cluster-local-nginx-gw.yaml")
		if _, err := os.Stat(clusterLocal); err == nil {
			_ = exec.Command("kubectl", "apply", "--server-side", "--force-conflicts", "-f", clusterLocal).Run()
		}

	default:
		return fmt.Errorf("ingress implementation '%s' is not supported", impl)
	}

	setHostEntry("k2s.cluster.local", nodeIP)
	configureClusterLocalDns()
	_ = p.addAddonToConfig("ingress", impl)
	_ = p.updateRegistryIngress()

	return nil
}

func (p *linuxAddonProvider) Disable(cfg AddonDisableConfig) error {
	slog.Info("[Addon] Disabling addon", "name", cfg.Name, "implementation", cfg.Implementation)

	if cfg.Name == "registry" {
		return p.disableRegistry(cfg)
	}
	if cfg.Name == "ingress" {
		return p.disableIngress(cfg)
	}

	manifestsDir := filepath.Join(p.installDir, "addons", cfg.Name, "manifests")
	if _, err := os.Stat(manifestsDir); err != nil {
		return fmt.Errorf("addon manifests directory not found for '%s': %w", cfg.Name, err)
	}

	if err := exec.Command("kubectl", "delete", "-f", manifestsDir, "--recursive", "--ignore-not-found").Run(); err != nil {
		return fmt.Errorf("kubectl delete failed for addon '%s': %w", cfg.Name, err)
	}

	slog.Info("[Addon] Addon disabled", "name", cfg.Name)
	return nil
}

func (p *linuxAddonProvider) disableRegistry(cfg AddonDisableConfig) error {
	if !p.isAddonEnabledInConfig("registry") && !isAddonDeployed("registry") {
		return fmt.Errorf("addon 'registry' is already disabled, nothing to do")
	}

	// Delete ingress manifests for all 3 controllers + nodeport
	_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx"), "--ignore-not-found").Run()
	_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-traefik"), "--ignore-not-found").Run()
	_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx-gw"), "--ignore-not-found").Run()
	_ = exec.Command("kubectl", "delete", "-f", filepath.Join(p.installDir, "addons", "registry", "manifests", "registry", "service-nodeport.yaml"), "--ignore-not-found").Run()

	registryManifestsDir := filepath.Join(p.installDir, "addons", "registry", "manifests", "registry")
	_ = exec.Command("kubectl", "delete", "-k", registryManifestsDir, "--ignore-not-found").Run()
	_ = exec.Command("kubectl", "delete", "namespace", "registry", "--ignore-not-found").Run()

	if cfg.Params != nil && (cfg.Params["deleteimages"] == "true" || cfg.Params["delete-images"] == "true" || cfg.Params["d"] == "true") {
		_ = exec.Command("sudo", "rm", "-rf", "/registry").Run()
	}

	// Remove host entry from /etc/hosts
	removeHostEntry("k2s.registry.local")

	// Remove registries via Remove-Registry.sh
	if _, err := os.Stat(p.registryScript(removeRegistryScript)); err == nil {
		p.runRegistryScript(removeRegistryScript, "--registry", "k2s.registry.local:30500")
		p.runRegistryScript(removeRegistryScript, "--registry", "k2s.registry.local")
	}

	// Update setup.json
	_ = p.removeAddonFromConfig("registry", "")
	_ = p.removeRegistryFromConfig("k2s.registry.local:30500")
	_ = p.removeRegistryFromConfig("k2s.registry.local")

	return nil
}

func (p *linuxAddonProvider) disableIngress(cfg AddonDisableConfig) error {
	impl := cfg.Implementation
	if impl == "" {
		impl = "nginx"
	}

	nsName := "ingress-nginx"
	switch impl {
	case "traefik":
		nsName = "ingress-traefik"
	case "nginx-gw":
		nsName = "nginx-gw"
	}

	if !p.isAddonEnabledInConfig("ingress", impl) && !isAddonDeployed(nsName) {
		return fmt.Errorf("addon 'ingress %s' is already disabled, nothing to do", impl)
	}

	removeHostEntry("k2s.cluster.local")

	switch impl {
	case "nginx":
		clusterLocal := filepath.Join(p.installDir, "addons", "ingress", "nginx", "manifests", "cluster-local-ingress.yaml")
		_ = exec.Command("kubectl", "delete", "-f", clusterLocal, "--ignore-not-found").Run()
		manifestFile := filepath.Join(p.installDir, "addons", "ingress", "nginx", "manifests", "ingress-nginx.yaml")
		_ = exec.Command("kubectl", "delete", "-f", manifestFile, "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "namespace", "ingress-nginx", "--ignore-not-found").Run()

	case "traefik":
		clusterLocal := filepath.Join(p.installDir, "addons", "ingress", "traefik", "manifests", "cluster-local-ingress.yaml")
		_ = exec.Command("kubectl", "delete", "-f", clusterLocal, "--ignore-not-found").Run()
		traefikManifestsDir := filepath.Join(p.installDir, "addons", "ingress", "traefik", "manifests")
		_ = exec.Command("kubectl", "delete", "-k", traefikManifestsDir, "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "namespace", "ingress-traefik", "--ignore-not-found").Run()
		_ = p.deleteGatewayApiCrds()

	case "nginx-gw":
		clusterLocal := filepath.Join(p.installDir, "addons", "ingress", "nginx-gw", "manifests", "cluster-local-nginx-gw.yaml")
		_ = exec.Command("kubectl", "delete", "-f", clusterLocal, "--ignore-not-found").Run()
		certFile := filepath.Join(p.installDir, "addons", "ingress", "nginx-gw", "manifests", "k2s-cluster-local-tls-certificate.yaml")
		_ = exec.Command("kubectl", "delete", "-f", certFile, "--ignore-not-found").Run()
		ngfManifestsDir := filepath.Join(p.installDir, "addons", "ingress", "nginx-gw", "manifests")
		_ = exec.Command("kubectl", "delete", "-k", ngfManifestsDir, "--ignore-not-found").Run()
		ngfCrdsDir := filepath.Join(p.installDir, "addons", "ingress", "nginx-gw", "manifests", "crds")
		_ = exec.Command("kubectl", "delete", "-f", ngfCrdsDir, "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "namespace", "nginx-gw", "--ignore-not-found").Run()
		_ = p.deleteGatewayApiCrds()
	}

	_ = p.removeAddonFromConfig("ingress", impl)
	_ = p.disableCertManager()
	_ = p.updateRegistryIngress()

	return nil
}

func (p *linuxAddonProvider) registryScript(name string) string {
	return filepath.Join(p.installDir, "lib", "scripts", "linux", "debian", "host", "image", "registry", name)
}

// runRegistryScript is best-effort: the script logs to the K2s log file itself, so only the failure is noted here.
func (p *linuxAddonProvider) runRegistryScript(name string, args ...string) {
	if err := bash.NewScript(p.registryScript(name)).WithArgs(args...).Exec(); err != nil {
		slog.Warn("[Addon] Registry script failed", "script", name, "error", err)
	}
}

func (p *linuxAddonProvider) updateRegistryIngress() error {
	if !p.isAddonEnabledInConfig("registry") && !isAddonDeployed("registry") {
		return nil
	}

	if p.isAddonEnabledInConfig("ingress", "nginx") {
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-traefik"), "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx-gw"), "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "-f", filepath.Join(p.installDir, "addons", "registry", "manifests", "registry", "service-nodeport.yaml"), "--ignore-not-found").Run()

		_ = exec.Command("kubectl", "apply", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx")).Run()

		p.runRegistryScript(removeRegistryScript, "--registry", "k2s.registry.local:30500")
		p.runRegistryScript(addRegistryScript, "--registry", "k2s.registry.local", "--plain-http")

		_ = p.removeRegistryFromConfig("k2s.registry.local:30500")
		_ = p.addRegistryToConfig("k2s.registry.local")
	} else if p.isAddonEnabledInConfig("ingress", "traefik") {
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx"), "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx-gw"), "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "-f", filepath.Join(p.installDir, "addons", "registry", "manifests", "registry", "service-nodeport.yaml"), "--ignore-not-found").Run()

		_ = exec.Command("kubectl", "apply", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-traefik")).Run()

		p.runRegistryScript(removeRegistryScript, "--registry", "k2s.registry.local:30500")
		p.runRegistryScript(addRegistryScript, "--registry", "k2s.registry.local", "--plain-http")

		_ = p.removeRegistryFromConfig("k2s.registry.local:30500")
		_ = p.addRegistryToConfig("k2s.registry.local")
	} else if p.isAddonEnabledInConfig("ingress", "nginx-gw") {
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx"), "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-traefik"), "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "-f", filepath.Join(p.installDir, "addons", "registry", "manifests", "registry", "service-nodeport.yaml"), "--ignore-not-found").Run()

		_ = ensureTlsSecret("nginx-gw", "k2s-registry-local-tls", "k2s.registry.local")
		certFile := filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx-gw", "k2s-registry-local-tls-certificate.yaml")
		if isCertManagerReady() {
			_ = exec.Command("kubectl", "apply", "-f", certFile).Run()
		}

		_ = exec.Command("kubectl", "apply", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx-gw")).Run()

		p.runRegistryScript(removeRegistryScript, "--registry", "k2s.registry.local:30500")
		p.runRegistryScript(addRegistryScript, "--registry", "k2s.registry.local", "--plain-http")

		_ = p.removeRegistryFromConfig("k2s.registry.local:30500")
		_ = p.addRegistryToConfig("k2s.registry.local")
	} else {
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx"), "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-traefik"), "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx-gw"), "--ignore-not-found").Run()

		_ = exec.Command("kubectl", "apply", "-f", filepath.Join(p.installDir, "addons", "registry", "manifests", "registry", "service-nodeport.yaml")).Run()

		p.runRegistryScript(removeRegistryScript, "--registry", "k2s.registry.local")
		p.runRegistryScript(addRegistryScript, "--registry", "k2s.registry.local:30500", "--plain-http")

		_ = p.removeRegistryFromConfig("k2s.registry.local")
		_ = p.addRegistryToConfig("k2s.registry.local:30500")
	}

	return nil
}

func ensureTlsSecret(namespace, secretName, commonName string) error {
	out, err := exec.Command("kubectl", "get", "secret", secretName, "-n", namespace, "--ignore-not-found").Output()
	if err == nil && len(strings.TrimSpace(string(out))) > 0 {
		return nil
	}

	keyFile, err := os.CreateTemp("", "tls-*.key")
	if err != nil {
		return err
	}
	keyPath := keyFile.Name()
	keyFile.Close()
	defer os.Remove(keyPath)

	certFile, err := os.CreateTemp("", "tls-*.crt")
	if err != nil {
		return err
	}
	certPath := certFile.Name()
	certFile.Close()
	defer os.Remove(certPath)

	genCmd := exec.Command("openssl", "req", "-x509", "-nodes", "-days", "365",
		"-newkey", "rsa:2048",
		"-keyout", keyPath,
		"-out", certPath,
		"-subj", fmt.Sprintf("/CN=%s", commonName),
	)
	if err := genCmd.Run(); err != nil {
		slog.Warn("[Addon] openssl req failed", "error", err)
		return err
	}

	createCmd := exec.Command("kubectl", "create", "secret", "tls", secretName,
		"-n", namespace,
		fmt.Sprintf("--cert=%s", certPath),
		fmt.Sprintf("--key=%s", keyPath),
	)
	return createCmd.Run()
}

func (p *linuxAddonProvider) ensureGatewayApiCrds() error {
	crdFile := filepath.Join(p.installDir, "addons", "common", "manifests", "crds", "gateway-crds", "gateway-api-v1.4.1.yaml")
	var applyErr error
	for attempt := 0; attempt < 3; attempt++ {
		cmd := exec.Command("kubectl", "apply", "--server-side", "--force-conflicts", "--request-timeout=30s", "-f", crdFile)
		if err := cmd.Run(); err == nil {
			applyErr = nil
			break
		} else {
			applyErr = err
			time.Sleep(2 * time.Second)
		}
	}
	if applyErr != nil {
		return fmt.Errorf("applying gateway-api crds: %w", applyErr)
	}
	waitCmd := exec.Command("kubectl", "wait", "--for=condition=Established", "crd/gateways.gateway.networking.k8s.io", "--timeout=60s")
	_ = waitCmd.Run()
	return nil
}

func (p *linuxAddonProvider) deleteGatewayApiCrds() error {
	if p.isAddonEnabledInConfig("ingress", "traefik") ||
		p.isAddonEnabledInConfig("ingress", "nginx-gw") ||
		p.isAddonEnabledInConfig("gateway-api") {
		return nil
	}
	crdFile := filepath.Join(p.installDir, "addons", "common", "manifests", "crds", "gateway-crds", "gateway-api-v1.4.1.yaml")
	_ = exec.Command("kubectl", "delete", "-f", crdFile, "--ignore-not-found").Run()
	return nil
}

func (p *linuxAddonProvider) enableCertManager(showOutput bool) error {
	if isCertManagerReady() && isCaRootSecretAvailable() {
		return nil
	}

	certManagerFile := filepath.Join(p.installDir, "addons", "common", "manifests", "certmanager", "cert-manager.yaml")
	cmd := exec.Command("kubectl", "apply", "-f", certManagerFile)
	if showOutput {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("applying cert-manager manifests: %w", err)
	}

	_ = exec.Command("kubectl", "wait", "--for=condition=Available", "deployment/cert-manager", "-n", "cert-manager", "--timeout=120s").Run()
	_ = exec.Command("kubectl", "wait", "--for=condition=Available", "deployment/cert-manager-cainjector", "-n", "cert-manager", "--timeout=120s").Run()
	_ = exec.Command("kubectl", "wait", "--for=condition=Available", "deployment/cert-manager-webhook", "-n", "cert-manager", "--timeout=120s").Run()

	// Wait for cainjector to populate the validating webhook caBundle
	caDeadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(caDeadline) {
		out, err := exec.Command("kubectl", "get", "validatingwebhookconfiguration", "cert-manager-webhook",
			"-o", "jsonpath={.webhooks[0].clientConfig.caBundle}").Output()
		if err == nil && len(strings.TrimSpace(string(out))) > 100 {
			break
		}
		time.Sleep(2 * time.Second)
	}
	time.Sleep(3 * time.Second)

	caIssuerFile := filepath.Join(p.installDir, "addons", "common", "manifests", "certmanager", "ca-issuer.yaml")
	var applyErr error
	issuerDeadline := time.Now().Add(90 * time.Second)
	for time.Now().Before(issuerDeadline) {
		cmdIssuer := exec.Command("kubectl", "apply", "--request-timeout=10s", "-f", caIssuerFile)
		out, err := cmdIssuer.CombinedOutput()
		if err == nil {
			applyErr = nil
			if showOutput && len(out) > 0 {
				fmt.Print(string(out))
			}
			break
		}
		applyErr = fmt.Errorf("%w: %s", err, string(out))
		time.Sleep(2 * time.Second)
	}
	if applyErr != nil {
		slog.Warn("[Addon] applying ca-issuer returned error", "error", applyErr)
	}

	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		out, err := exec.Command("kubectl", "get", "secret", "ca-issuer-root-secret", "-n", "cert-manager", "--ignore-not-found").Output()
		if err == nil && len(strings.TrimSpace(string(out))) > 0 {
			break
		}
		time.Sleep(2 * time.Second)
	}

	return nil
}

func (p *linuxAddonProvider) disableCertManager() error {
	if p.isAddonEnabledInConfig("security") ||
		p.isAddonEnabledInConfig("ingress", "nginx") ||
		p.isAddonEnabledInConfig("ingress", "traefik") ||
		p.isAddonEnabledInConfig("ingress", "nginx-gw") {
		return nil
	}

	caIssuerFile := filepath.Join(p.installDir, "addons", "common", "manifests", "certmanager", "ca-issuer.yaml")
	_ = exec.Command("kubectl", "delete", "--ignore-not-found", "--timeout=30s", "-f", caIssuerFile).Run()
	certManagerFile := filepath.Join(p.installDir, "addons", "common", "manifests", "certmanager", "cert-manager.yaml")
	_ = exec.Command("kubectl", "delete", "--ignore-not-found", "--timeout=30s", "-f", certManagerFile).Run()
	return nil
}

func isCertManagerReady() bool {
	out, err := exec.Command("kubectl", "get", "deployment", "cert-manager", "-n", "cert-manager", "-o", "jsonpath={.status.readyReplicas}").Output()
	return err == nil && strings.TrimSpace(string(out)) != "" && strings.TrimSpace(string(out)) != "0"
}

func isCaRootSecretAvailable() bool {
	out, err := exec.Command("kubectl", "get", "secret", "ca-issuer-root-secret", "-n", "cert-manager", "--ignore-not-found").Output()
	return err == nil && len(strings.TrimSpace(string(out))) > 0
}

func configureClusterLocalDns() {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = exec.CommandContext(ctx, "resolvectl", "dns", "cni0", "172.21.0.10").Run()
	_ = exec.CommandContext(ctx, "resolvectl", "domain", "cni0", "~cluster.local").Run()
}

func (p *linuxAddonProvider) List(_ AddonListConfig) (*AddonListResult, error) {
	slog.Debug("[Addon] Listing addons")

	addonsDir := filepath.Join(p.installDir, "addons")
	entries, err := os.ReadDir(addonsDir)
	if err != nil {
		return nil, fmt.Errorf("cannot read addons directory: %w", err)
	}

	result := &AddonListResult{}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		manifestPath := filepath.Join(addonsDir, entry.Name(), "addon.manifest.yaml")
		if _, err := os.Stat(manifestPath); err != nil {
			continue // not an addon directory
		}

		m, err := p.loadManifest(entry.Name())
		if err != nil {
			slog.Warn("[Addon] Could not load manifest", "addon", entry.Name(), "error", err)
			continue
		}

		enabled := isAddonDeployed(entry.Name())

		result.Addons = append(result.Addons, AddonInfo{
			Name:        m.Metadata.Name,
			Enabled:     enabled,
			Description: m.Metadata.Description,
		})
	}

	return result, nil
}

func (p *linuxAddonProvider) Status(cfg AddonStatusConfig) (*AddonStatusResult, error) {
	result := &AddonStatusResult{}
	nodeIP := getNodeIP()

	targetAddon := cfg.Name
	impl := ""
	if cfg.Directory != "" {
		base := filepath.Base(cfg.Directory)
		if base == "traefik" || base == "nginx" || base == "nginx-gw" {
			impl = base
		}
	}

	if targetAddon == "registry" {
		enabled := p.isAddonEnabledInConfig("registry")
		info := AddonStatusInfo{
			Name:    "registry",
			Enabled: enabled,
		}

		if enabled {
			podRunning := false
			out, err := exec.Command("kubectl", "get", "statefulset", "registry", "-n", "registry", "-o", "jsonpath={.status.readyReplicas}").Output()
			if err == nil && strings.TrimSpace(string(out)) != "" && strings.TrimSpace(string(out)) != "0" {
				podRunning = true
			}
			msgPod := "The registry pod is not working"
			if podRunning {
				msgPod = "The registry pod is working"
			}
			info.Props = append(info.Props, AddonStatusProp{
				Name:    "IsRegistryPodRunning",
				Value:   podRunning,
				Okay:    &podRunning,
				Message: &msgPod,
			})

			reachable := false
			regHost := "k2s.registry.local:30500"
			client := &http.Client{
				Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}},
				Timeout:   5 * time.Second,
			}
			for _, u := range []string{"https://k2s.registry.local/v2/", "http://k2s.registry.local:30500/v2/", "http://127.0.0.1:30500/v2/"} {
				resp, err := client.Get(u)
				if err == nil && (resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusUnauthorized) {
					reachable = true
					regHost = strings.TrimPrefix(strings.TrimPrefix(strings.TrimSuffix(u, "/v2/"), "http://"), "https://")
					resp.Body.Close()
					break
				}
			}
			msgReach := "The registry is not reachable"
			if reachable {
				msgReach = fmt.Sprintf("The registry '%s' is reachable", regHost)
			}
			info.Props = append(info.Props, AddonStatusProp{
				Name:    "IsRegistryReachable",
				Value:   reachable,
				Okay:    &reachable,
				Message: &msgReach,
			})
		}
		result.Addons = append(result.Addons, info)
		return result, nil
	}

	if targetAddon == "ingress" {
		if impl == "" {
			impl = "nginx"
		}
		enabled := p.isAddonEnabledInConfig("ingress", impl)
		info := AddonStatusInfo{
			Name:    "ingress",
			Enabled: enabled,
		}

		if enabled {
			controllerRunning := false
			extIpMatches := false
			depName := "ingress-nginx-controller"
			depNs := "ingress-nginx"
			svcName := "ingress-nginx-controller"
			svcNs := "ingress-nginx"
			propRunningName := "IsIngressNginxRunning"
			msgRunningTrue := "The nginx ingress controller is working"
			msgRunningFalse := "The nginx ingress controller is not working"
			msgExtIpTrue := fmt.Sprintf("The external IP for ingress-nginx service is set to %s", nodeIP)
			msgExtIpFalse := "The external IP for ingress-nginx service is not set properly"

			switch impl {
			case "traefik":
				depName = "traefik"
				depNs = "ingress-traefik"
				svcName = "traefik"
				svcNs = "ingress-traefik"
				propRunningName = "IsTraefikRunning"
				msgRunningTrue = "The traefik ingress controller is working"
				msgRunningFalse = "The traefik ingress controller is not working"
				msgExtIpTrue = fmt.Sprintf("The external IP for traefik service is set to %s", nodeIP)
				msgExtIpFalse = "The external IP for traefik service is not set properly"
			case "nginx-gw":
				depName = "nginx-gw-controller"
				depNs = "nginx-gw"
				svcName = "nginx-cluster-local-nginx-gw"
				svcNs = "nginx-gw"
				propRunningName = "IsNginxGatewayRunning"
				msgRunningTrue = "The nginx gateway fabric controller is working"
				msgRunningFalse = "The nginx gateway fabric controller is not working"
				msgExtIpTrue = fmt.Sprintf("The external IP for nginx-gw service is set to %s", nodeIP)
				msgExtIpFalse = "The external IP for nginx-gw service is not set properly"
			}

			out, err := exec.Command("kubectl", "get", "deployment", depName, "-n", depNs, "-o", "jsonpath={.status.readyReplicas}").Output()
			if err == nil && strings.TrimSpace(string(out)) != "" && strings.TrimSpace(string(out)) != "0" {
				controllerRunning = true
			}
			msgRunning := msgRunningFalse
			if controllerRunning {
				msgRunning = msgRunningTrue
			}
			info.Props = append(info.Props, AddonStatusProp{
				Name:    propRunningName,
				Value:   controllerRunning,
				Okay:    &controllerRunning,
				Message: &msgRunning,
			})

			outSvc, err := exec.Command("kubectl", "get", "service", svcName, "-n", svcNs, "-o", "jsonpath={.spec.externalIPs[0]}").Output()
			if err == nil && strings.Trim(strings.TrimSpace(string(outSvc)), "\"") == nodeIP {
				extIpMatches = true
			}
			msgExtIp := msgExtIpFalse
			if extIpMatches {
				msgExtIp = msgExtIpTrue
			}
			info.Props = append(info.Props, AddonStatusProp{
				Name:    "IsExternalIPSet",
				Value:   extIpMatches,
				Okay:    &extIpMatches,
				Message: &msgExtIp,
			})

			cmReady := isCertManagerReady()
			msgCm := "The cert-manager is not installed (omitted during addon enablement)."
			if cmReady {
				msgCm = "The cert-manager API is ready"
			}
			info.Props = append(info.Props, AddonStatusProp{
				Name:    "IsCertManagerAvailable",
				Value:   cmReady,
				Okay:    &cmReady,
				Message: &msgCm,
			})

			caReady := isCaRootSecretAvailable()
			msgCa := "The CA root certificate is not available (cert-manager was omitted)."
			if caReady {
				msgCa = "The CA root certificate is available"
			}
			info.Props = append(info.Props, AddonStatusProp{
				Name:    "IsCaRootCertificateAvailable",
				Value:   caReady,
				Okay:    &caReady,
				Message: &msgCa,
			})
		}

		result.Addons = append(result.Addons, info)
		return result, nil
	}

	// Fallback to List for any other addon
	list, err := p.List(AddonListConfig{})
	if err != nil {
		return nil, err
	}
	for _, addon := range list.Addons {
		if cfg.Name != "" && addon.Name != cfg.Name {
			continue
		}
		info := AddonStatusInfo{
			Name:    addon.Name,
			Enabled: addon.Enabled,
		}
		result.Addons = append(result.Addons, info)
	}
	return result, nil
}

func (p *linuxAddonProvider) Export(_ AddonExportConfig) error {
	return NotSupportedError("addons export",
		"addon export on Linux hosts is not yet implemented")
}

// Import mirrors addons/Import.ps1 for Linux hosts: it stages the addons of an exported OCI
// artifact into the addons directory and loads their Linux images into the container runtime
// of this host, or over SSH into the nodes selected with --node/--nodes. Addons are not
// enabled; that is 'k2s addons enable'.
func (p *linuxAddonProvider) Import(cfg AddonImportConfig) error {
	targets, err := p.resolveImportTargets(cfg.Nodes)
	if err != nil {
		return err
	}
	if !strings.HasSuffix(strings.ToLower(cfg.ArtifactFile), ociArtifactSuffix) {
		return fmt.Errorf("unknown artifact format of '%s'; supported formats: %s", cfg.ArtifactFile, ociArtifactSuffix)
	}

	slog.Info("[Addon] Importing addons", "artifact", cfg.ArtifactFile, "names", cfg.Names, "omit", cfg.Omit)

	// /tmp is a RAM-backed tmpfs on Debian 13, which multi-GB image layers would exhaust.
	tempDir := "/var/tmp"
	if _, err := os.Stat(tempDir); err != nil {
		tempDir = ""
	}
	workDir, err := os.MkdirTemp(tempDir, "k2s-addons-import-")
	if err != nil {
		return fmt.Errorf("creating working directory: %w", err)
	}
	defer os.RemoveAll(workDir)

	logAddonImport("Extracting artifact from %s", cfg.ArtifactFile)
	layoutDir := filepath.Join(workDir, "layout")
	if err := extractTar(cfg.ArtifactFile, layoutDir, false); err != nil {
		return fmt.Errorf("extracting OCI artifact: %w", err)
	}

	blobsDir, exported, err := readOciLayout(layoutDir)
	if err != nil {
		return err
	}
	selected, err := selectExportedAddons(exported, cfg.Names)
	if err != nil {
		return err
	}

	// Phase 1: stage the files of every selected addon and collect the images each one carries.
	entries := make([]*addonImportEntry, 0, len(selected))
	for _, addon := range selected {
		logAddonImport("Importing addon: %s", addon.key())
		entry, err := p.stageExportedAddon(addon, blobsDir, workDir)
		if err != nil {
			return fmt.Errorf("importing addon '%s': %w", addon.key(), err)
		}
		entries = append(entries, entry)
	}

	// Phase 2: decide globally which images the omit options allow to skip.
	plan := newImagePrunePlan(entries, parseOmitTokens(cfg.Omit))
	plan.log()

	// Phase 3: load the remaining images into the container runtime of every target node.
	importImage := p.imageImporter(targets, cfg)

	var imported, imageFailures []string
	for _, entry := range entries {
		key := entry.addon.key()
		imported = append(imported, key)
		if entry.imagesLayerPath == "" {
			logAddonImport("No Linux images layer found for '%s'", key)
			continue
		}
		failures, err := importLinuxImageLayer(entry.imagesLayerPath, filepath.Join(workDir, "images"), key, plan.skip[key], importImage)
		if err != nil {
			return fmt.Errorf("importing images of addon '%s': %w", key, err)
		}
		imageFailures = append(imageFailures, failures...)
	}
	if len(imageFailures) > 0 {
		return fmt.Errorf("addons '%s' were imported with image import failures: %s",
			strings.Join(imported, ", "), strings.Join(imageFailures, "; "))
	}

	logAddonImport("Addons '%s' imported successfully from OCI artifact", strings.Join(imported, ", "))
	plan.logSummary()
	return nil
}

const (
	ociArtifactSuffix     = ".oci.tar"
	ociLayoutVersion      = "1.0.0"
	addonManifestFileName = "addon.manifest.yaml"
	ociEmptyMediaType     = "application/vnd.oci.empty.v1+json"
	addonNameAnnotation   = "vnd.k2s.addon.name"
	addonImplAnnotation   = "vnd.k2s.addon.implementation"
)

type ociLayerKind int

const (
	unknownLayer ociLayerKind = iota
	configLayer
	manifestsLayer
	chartsLayer
	scriptsLayer
	sharedScriptsLayer
	windowsImagesLayer
	linuxImagesLayer
	packagesLayer
)

var (
	ociDigestPattern   = regexp.MustCompile(`^sha256:[a-f0-9]{64}$`)
	pathSegmentPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

	// Order matters: it mirrors the first-match-wins media type matching of addons/Import.ps1.
	ociLayerKinds = []struct {
		mediaTypePart string
		kind          ociLayerKind
	}{
		{"configfiles", configLayer},
		{"manifests", manifestsLayer},
		{"helm.chart", chartsLayer},
		{"shared-scripts", sharedScriptsLayer},
		{"scripts", scriptsLayer},
		{"images-windows", windowsImagesLayer},
		{"image.layer", linuxImagesLayer},
		{"packages", packagesLayer},
	}
)

type ociDescriptor struct {
	MediaType   string            `json:"mediaType"`
	Digest      string            `json:"digest"`
	Annotations map[string]string `json:"annotations"`
}

type ociManifest struct {
	Layers      []ociDescriptor   `json:"layers"`
	Annotations map[string]string `json:"annotations"`
}

type exportedAddon struct {
	name           string
	implementation string
	manifest       ociManifest
}

// key returns '<name>' or '<name>/<implementation>'.
func (a exportedAddon) key() string {
	if a.implementation == "" || a.implementation == a.name {
		return a.name
	}
	return a.name + "/" + a.implementation
}

func logAddonImport(format string, args ...any) {
	message := fmt.Sprintf(format, args...)
	slog.Info("[Addon] " + message)
	fmt.Println(message)
}

func readOciLayout(layoutDir string) (blobsDir string, addons []exportedAddon, err error) {
	var layout struct {
		ImageLayoutVersion string `json:"imageLayoutVersion"`
	}
	if err := readJSON(filepath.Join(layoutDir, "oci-layout"), &layout); err != nil {
		return "", nil, fmt.Errorf("invalid OCI artifact format: %w", err)
	}
	if layout.ImageLayoutVersion != ociLayoutVersion {
		return "", nil, fmt.Errorf("unsupported OCI image layout version '%s' (expected '%s')", layout.ImageLayoutVersion, ociLayoutVersion)
	}

	blobsDir = filepath.Join(layoutDir, "blobs", "sha256")
	if info, err := os.Stat(blobsDir); err != nil || !info.IsDir() {
		return "", nil, errors.New("invalid OCI artifact format: blobs/sha256 directory not found")
	}

	var index struct {
		SchemaVersion int             `json:"schemaVersion"`
		Manifests     []ociDescriptor `json:"manifests"`
	}
	if err := readJSON(filepath.Join(layoutDir, "index.json"), &index); err != nil {
		return "", nil, fmt.Errorf("invalid OCI artifact format: %w", err)
	}
	if index.SchemaVersion != 2 {
		return "", nil, fmt.Errorf("invalid OCI image index: schemaVersion must be 2, got %d", index.SchemaVersion)
	}

	for _, entry := range index.Manifests {
		manifestPath, err := verifiedBlob(blobsDir, entry.Digest)
		if err != nil {
			return "", nil, err
		}
		addon := exportedAddon{
			name:           entry.Annotations[addonNameAnnotation],
			implementation: entry.Annotations[addonImplAnnotation],
		}
		if err := readJSON(manifestPath, &addon.manifest); err != nil {
			return "", nil, fmt.Errorf("invalid addon manifest %s: %w", entry.Digest, err)
		}
		if name := addon.manifest.Annotations[addonNameAnnotation]; name != "" {
			addon.name = name
			addon.implementation = addon.manifest.Annotations[addonImplAnnotation]
		}
		if addon.name == "" {
			return "", nil, fmt.Errorf("invalid OCI artifact format: manifest %s does not name an addon", entry.Digest)
		}
		addons = append(addons, addon)
	}

	if len(addons) == 0 {
		return "", nil, errors.New("invalid OCI artifact format: no addons found")
	}

	return blobsDir, addons, nil
}

// selectExportedAddons resolves the requested names. A request is a base addon ('ingress'), a
// quoted implementation ('ingress traefik'), two separate tokens ('ingress', 'traefik') or the
// flattened form ('ingress-traefik').
func selectExportedAddons(exported []exportedAddon, names []string) ([]exportedAddon, error) {
	if len(names) == 0 {
		return exported, nil
	}

	filter := func(match func(exportedAddon) bool) []exportedAddon {
		var matches []exportedAddon
		for _, addon := range exported {
			if match(addon) {
				matches = append(matches, addon)
			}
		}
		return matches
	}

	var selected []exportedAddon
	for i := 0; i < len(names); i++ {
		name := names[i]
		requestedName, requestedImplementation := name, ""

		if parts := strings.Fields(name); len(parts) > 1 {
			requestedName, requestedImplementation = parts[0], strings.Join(parts[1:], "-")
		} else if i+1 < len(names) {
			matches := filter(func(a exportedAddon) bool {
				return strings.EqualFold(a.name, name) && strings.EqualFold(a.implementation, names[i+1])
			})
			if len(matches) > 0 {
				selected = append(selected, matches...)
				i++
				continue
			}
		}

		found := filter(func(a exportedAddon) bool {
			return strings.EqualFold(a.name, requestedName) &&
				(requestedImplementation == "" || strings.EqualFold(a.implementation, requestedImplementation))
		})
		if len(found) == 0 && requestedImplementation == "" {
			found = filter(func(a exportedAddon) bool {
				return strings.EqualFold(a.name+"-"+a.implementation, requestedName)
			})
		}
		if len(found) == 0 {
			return nil, fmt.Errorf("addon '%s' not found in OCI artifact for import", name)
		}
		selected = append(selected, found...)
	}

	slices.SortStableFunc(selected, func(a, b exportedAddon) int { return strings.Compare(a.key(), b.key()) })
	return slices.CompactFunc(selected, func(a, b exportedAddon) bool { return a.key() == b.key() }), nil
}

// resolveImportPath returns the addon directory name and, for multi-implementation addons,
// the implementation subdirectory. Both originate from the artifact and must be plain names.
func resolveImportPath(name, implementation string) (baseName, implementationName string, err error) {
	// Older artifacts carry the implementation as last segment of the name ('storage ceph').
	if segments := strings.Fields(name); len(segments) > 1 && segments[len(segments)-1] == implementation {
		name = strings.Join(segments[:len(segments)-1], " ")
	}
	if implementation == name {
		implementation = ""
	}

	if !pathSegmentPattern.MatchString(name) {
		return "", "", fmt.Errorf("addon name '%s' is not a valid directory name", name)
	}
	if implementation != "" && !pathSegmentPattern.MatchString(implementation) {
		return "", "", fmt.Errorf("addon implementation '%s' is not a valid directory name", implementation)
	}

	return name, implementation, nil
}

func kindOfLayer(mediaType string) ociLayerKind {
	for _, candidate := range ociLayerKinds {
		if strings.Contains(mediaType, candidate.mediaTypePart) {
			return candidate.kind
		}
	}
	return unknownLayer
}

// addonImportEntry is an addon that was staged and still has images to import.
type addonImportEntry struct {
	addon              exportedAddon
	implementationPath string
	flags              []addons.CliFlag
	imagesLayerPath    string
	imageFiles         []string
}

// stageExportedAddon stages the files of one addon and lists the Linux image archives it carries.
func (p *linuxAddonProvider) stageExportedAddon(addon exportedAddon, blobsDir, workDir string) (*addonImportEntry, error) {
	baseName, implementation, err := resolveImportPath(addon.name, addon.implementation)
	if err != nil {
		return nil, err
	}

	destination := filepath.Join(p.installDir, "addons", baseName)
	implementationPath := filepath.Join(destination, implementation)
	if err := os.MkdirAll(implementationPath, 0o755); err != nil {
		return nil, err
	}

	configDir, err := os.MkdirTemp(workDir, "config-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(configDir)

	imagesLayerPath := ""
	for _, layer := range addon.manifest.Layers {
		if layer.MediaType == ociEmptyMediaType {
			continue
		}

		kind := kindOfLayer(layer.MediaType)
		switch kind {
		case windowsImagesLayer:
			logAddonImport("Skipping Windows images of '%s': importing them is not supported on Linux hosts", addon.key())
			continue
		case packagesLayer:
			logAddonImport("Skipping offline packages of '%s': importing them is not supported on Linux hosts", addon.key())
			continue
		case unknownLayer:
			continue
		}

		blobPath, err := verifiedBlob(blobsDir, layer.Digest)
		if err != nil {
			return nil, err
		}

		switch kind {
		case configLayer:
			err = extractTar(blobPath, configDir, true)
		case manifestsLayer:
			err = extractTar(blobPath, filepath.Join(implementationPath, "manifests"), true)
		case chartsLayer:
			err = extractTar(blobPath, filepath.Join(implementationPath, "manifests", "chart"), true)
		case scriptsLayer:
			err = extractTar(blobPath, implementationPath, true)
		case sharedScriptsLayer:
			err = extractTar(blobPath, destination, true)
		case linuxImagesLayer:
			imagesLayerPath = blobPath
		}
		if err != nil {
			return nil, fmt.Errorf("extracting layer %s: %w", layer.Digest, err)
		}
	}

	// Read before staging replaces it: artifacts exported before an omit option existed do not declare it.
	installedManifest, _ := os.ReadFile(filepath.Join(destination, addonManifestFileName))

	if err := stageAddonConfig(configDir, destination, implementationPath, implementation != ""); err != nil {
		return nil, err
	}

	entry := &addonImportEntry{
		addon:              addon,
		implementationPath: implementationPath,
		flags:              omitFlagsFor(filepath.Join(configDir, addonManifestFileName), installedManifest, addon.implementation),
		imagesLayerPath:    imagesLayerPath,
	}
	if imagesLayerPath != "" {
		if entry.imageFiles, err = listImageArchives(imagesLayerPath); err != nil {
			return nil, err
		}
	}

	return entry, nil
}

// stageAddonConfig installs the content of the config layer: the addon manifest goes to the addon
// directory, all other configuration files to the implementation directory.
func stageAddonConfig(configDir, destination, implementationPath string, multiImplementation bool) error {
	importedManifest := filepath.Join(configDir, addonManifestFileName)
	installedManifest := filepath.Join(destination, addonManifestFileName)

	if _, err := os.Stat(importedManifest); err != nil {
		logAddonImport("Warning: %s not found in the artifact for '%s'", addonManifestFileName, filepath.Base(destination))
	} else if _, err := os.Stat(installedManifest); err == nil && multiImplementation {
		added, err := mergeImplementations(installedManifest, importedManifest)
		if err != nil {
			return fmt.Errorf("merging %s: %w", addonManifestFileName, err)
		}
		if len(added) > 0 {
			logAddonImport("Added implementations to %s: %s", installedManifest, strings.Join(added, ", "))
		}
	} else if err := copyFile(importedManifest, installedManifest); err != nil {
		return err
	}

	return filepath.WalkDir(configDir, func(source string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relativePath, err := filepath.Rel(configDir, source)
		if err != nil {
			return err
		}
		if relativePath == "." || relativePath == addonManifestFileName {
			return nil
		}
		target := filepath.Join(implementationPath, relativePath)
		if entry.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		return copyFile(source, target)
	})
}

// mergeImplementations appends the implementations of the imported manifest that the installed
// manifest does not know yet and returns their names. Existing implementations stay untouched.
func mergeImplementations(installedManifest, importedManifest string) ([]string, error) {
	installed, err := readYAMLDocument(installedManifest)
	if err != nil {
		return nil, err
	}
	imported, err := readYAMLDocument(importedManifest)
	if err != nil {
		return nil, err
	}

	installedImplementations := implementationsOf(installed)
	importedImplementations := implementationsOf(imported)
	if installedImplementations == nil || importedImplementations == nil {
		return nil, errors.New("spec.implementations is missing")
	}

	var known, added []string
	for _, implementation := range installedImplementations.Content {
		known = append(known, yamlScalar(implementation, "name"))
	}
	for _, implementation := range importedImplementations.Content {
		name := yamlScalar(implementation, "name")
		if name == "" || slices.Contains(known, name) {
			continue
		}
		installedImplementations.Content = append(installedImplementations.Content, implementation)
		added = append(added, name)
	}
	if len(added) == 0 {
		return nil, nil
	}

	var merged bytes.Buffer
	encoder := yaml.NewEncoder(&merged)
	encoder.SetIndent(2)
	if err := encoder.Encode(installed); err != nil {
		return nil, err
	}
	if err := encoder.Close(); err != nil {
		return nil, err
	}

	return added, os.WriteFile(installedManifest, merged.Bytes(), 0o644)
}

func readYAMLDocument(filePath string) (*yaml.Node, error) {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return nil, err
	}
	var document yaml.Node
	if err := yaml.Unmarshal(data, &document); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", filePath, err)
	}
	return &document, nil
}

func implementationsOf(document *yaml.Node) *yaml.Node {
	if len(document.Content) == 0 {
		return nil
	}
	implementations := yamlValue(yamlValue(document.Content[0], "spec"), "implementations")
	if implementations == nil || implementations.Kind != yaml.SequenceNode {
		return nil
	}
	return implementations
}

func yamlValue(node *yaml.Node, key string) *yaml.Node {
	if node == nil || node.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		if node.Content[i].Value == key {
			return node.Content[i+1]
		}
	}
	return nil
}

func yamlScalar(node *yaml.Node, key string) string {
	if value := yamlValue(node, key); value != nil {
		return value.Value
	}
	return ""
}

// importLinuxImageLayer hands the per-image archives of an images layer to importImage one at a
// time, so only a single image is unpacked on disk at any moment. Archives in skip are not imported.
func importLinuxImageLayer(layerPath, imagesDir, addonKey string, skip map[string]bool, importImage func(archivePath string) error) ([]string, error) {
	var failures []string
	if err := os.MkdirAll(imagesDir, 0o755); err != nil {
		return nil, err
	}

	layer, err := os.Open(layerPath)
	if err != nil {
		return nil, err
	}
	defer layer.Close()

	imageCount := 0
	reader := tar.NewReader(layer)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("reading Linux images layer: %w", err)
		}

		name := path.Base(strings.ReplaceAll(header.Name, `\`, "/"))
		if header.Typeflag != tar.TypeReg || !strings.HasSuffix(name, ".tar") {
			continue
		}
		imageCount++

		if skip[name] {
			logAddonImport("[Prune] Not importing '%s' for '%s'", name, addonKey)
			continue
		}

		archivePath := filepath.Join(imagesDir, name)
		if err := writeStream(archivePath, reader, 0o644); err != nil {
			return nil, err
		}

		logAddonImport("Importing image archive %s", name)
		err = importImage(archivePath)
		_ = os.Remove(archivePath)
		if err != nil {
			logAddonImport("Warning: importing image archive %s failed: %v", name, err)
			failures = append(failures, fmt.Sprintf("%s of '%s'", name, addonKey))
		}
	}

	if imageCount == 0 {
		failures = append(failures, fmt.Sprintf("no image archives in the Linux images layer of '%s'", addonKey))
	}

	return failures, nil
}

// verifiedBlob returns the path of a blob after checking its content against the digest.
func verifiedBlob(blobsDir, digest string) (string, error) {
	if !ociDigestPattern.MatchString(digest) {
		return "", fmt.Errorf("invalid digest format '%s' (expected sha256:<64 lowercase hex chars>)", digest)
	}

	blobPath := filepath.Join(blobsDir, strings.TrimPrefix(digest, "sha256:"))
	blob, err := os.Open(blobPath)
	if err != nil {
		return "", fmt.Errorf("blob not found for digest %s: %w", digest, err)
	}
	defer blob.Close()

	hash := sha256.New()
	if _, err := io.Copy(hash, blob); err != nil {
		return "", fmt.Errorf("reading blob %s: %w", digest, err)
	}
	if computed := "sha256:" + hex.EncodeToString(hash.Sum(nil)); computed != digest {
		return "", fmt.Errorf("blob integrity check failed for digest %s (computed %s)", digest, computed)
	}

	return blobPath, nil
}

// extractTar extracts the directories and regular files of a tar archive. Entries pointing
// outside of the destination are rejected.
func extractTar(archivePath, destination string, gzipped bool) error {
	archive, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer archive.Close()

	var content io.Reader = archive
	if gzipped {
		gzipReader, err := gzip.NewReader(archive)
		if err != nil {
			return err
		}
		defer gzipReader.Close()
		content = gzipReader
	}

	if err := os.MkdirAll(destination, 0o755); err != nil {
		return err
	}

	reader := tar.NewReader(content)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}

		relativePath := path.Clean(strings.ReplaceAll(header.Name, `\`, "/"))
		if relativePath == "." {
			continue
		}
		localPath := filepath.FromSlash(relativePath)
		if !filepath.IsLocal(localPath) {
			return fmt.Errorf("archive entry '%s' is outside of the extraction directory", header.Name)
		}
		target := filepath.Join(destination, localPath)

		// Links and special files are never part of an exported addon and are not extracted.
		switch header.Typeflag {
		case tar.TypeDir:
			err = os.MkdirAll(target, 0o755)
		case tar.TypeReg:
			mode := os.FileMode(0o644)
			if header.Mode&0o111 != 0 {
				mode = 0o755
			}
			if err = os.MkdirAll(filepath.Dir(target), 0o755); err == nil {
				err = writeStream(target, reader, mode)
			}
		}
		if err != nil {
			return err
		}
	}
}

func copyFile(source, target string) error {
	content, err := os.Open(source)
	if err != nil {
		return err
	}
	defer content.Close()

	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	return writeStream(target, content, 0o644)
}

func writeStream(target string, content io.Reader, mode os.FileMode) error {
	file, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(file, content); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

func readJSON(filePath string, target any) error {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, target); err != nil {
		return fmt.Errorf("parsing %s: %w", filepath.Base(filePath), err)
	}
	return nil
}

var nodeNamePattern = regexp.MustCompile(`^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$`)

// importTarget is a node that receives the images. ip and user are set for an additional Linux
// worker that is reached over SSH; the local host node has neither.
type importTarget struct {
	name, ip, user string
}

func (t importTarget) isLocal() bool { return t.ip == "" }

// workerShell is the SSH access to an additional node.
type workerShell interface {
	CopyToNode(source, target string) error
	Exec(command string) error
}

// connectWorker opens the SSH access to a node; replaced in tests.
var connectWorker = func(options sshprovider.ConnectionOptions) workerShell {
	return sshprovider.NewSSH(options)
}

// isNodeReady reports whether the cluster node is in Ready state; replaced in tests.
var isNodeReady = func(nodeName string) bool {
	output, err := exec.Command("kubectl", "get", "node", nodeName, "-o", `jsonpath={.status.conditions[?(@.type=="Ready")].status}`).Output()
	return err == nil && strings.TrimSpace(string(output)) == "True"
}

// localNodeNames lists the names under which the local host node can be addressed; the first is its node name.
func (p *linuxAddonProvider) localNodeNames() []string {
	names := []string{getNodeName()}

	if cfgMap, err := kjson.FromFile[map[string]any](filepath.Join(p.setupConfigDir(), definitions.K2sRuntimeConfigFileName)); err == nil {
		if hostname, ok := (*cfgMap)["ControlPlaneNodeHostname"].(string); ok && hostname != "" {
			names = append(names, strings.ToLower(hostname))
		}
	}

	return append(names, "linux")
}

func (p *linuxAddonProvider) setupConfigDir() string {
	if p.configDir != "" {
		return p.configDir
	}
	return host.K2sConfigDir()
}

// resolveImportTargets turns --node/--nodes into the nodes that receive the images: the local host
// without a node selector, otherwise exactly the selected nodes. Every node is checked before the
// import changes anything.
func (p *linuxAddonProvider) resolveImportTargets(nodes string) ([]importTarget, error) {
	localNames := p.localNodeNames()
	local := importTarget{name: localNames[0]}

	var targets []importTarget
	for _, node := range strings.Split(nodes, ",") {
		node = strings.ToLower(strings.TrimSpace(node))
		if node == "" {
			continue
		}

		target := local
		if !slices.Contains(localNames, node) {
			var err error
			if target, err = p.resolveWorker(node); err != nil {
				return nil, err
			}
		}
		if !slices.Contains(targets, target) {
			targets = append(targets, target)
		}
	}

	if len(targets) == 0 {
		return []importTarget{local}, nil
	}
	return targets, nil
}

// resolveWorker finds an additional Linux worker in the cluster descriptor (cluster.json), like
// Resolve-ImageNode of the Windows image scripts, and checks that it is Ready.
func (p *linuxAddonProvider) resolveWorker(node string) (importTarget, error) {
	if !nodeNamePattern.MatchString(node) {
		return importTarget{}, fmt.Errorf("'%s' is not a valid node name - run 'kubectl get nodes' to list available nodes", node)
	}

	cluster, err := clusterconfig.Read(p.setupConfigDir())
	if err != nil {
		return importTarget{}, err
	}
	var descriptor *clusterconfig.Node
	if cluster != nil {
		for i := range cluster.Nodes {
			if strings.EqualFold(cluster.Nodes[i].Name, node) {
				descriptor = &cluster.Nodes[i]
			}
		}
	}
	if descriptor == nil {
		return importTarget{}, fmt.Errorf("node '%s' was not found in the cluster - run 'kubectl get nodes' to list available nodes", node)
	}

	switch strings.ToLower(string(descriptor.OS)) {
	case clusterconfig.OsTypeLinux:
	case clusterconfig.OsTypeWindows:
		return importTarget{}, NotSupportedError("addons import --node/--nodes",
			fmt.Sprintf("node '%s' is a Windows node; Windows images cannot be imported from a Linux host", node))
	default:
		return importTarget{}, fmt.Errorf("node '%s' has unsupported OS '%s' in the cluster descriptor", node, descriptor.OS)
	}
	if descriptor.IpAddress == "" || descriptor.Username == "" {
		return importTarget{}, fmt.Errorf("node '%s' is a Linux worker but IpAddress or Username is missing in the cluster descriptor", node)
	}
	if !isNodeReady(node) {
		return importTarget{}, fmt.Errorf("node '%s' is not in Ready state - run 'kubectl get nodes' to check node status", node)
	}

	return importTarget{name: node, ip: descriptor.IpAddress, user: descriptor.Username}, nil
}

// imageImporter returns the function that loads one image archive into every target node. It tries
// all nodes and reports each failing one.
func (p *linuxAddonProvider) imageImporter(targets []importTarget, cfg AddonImportConfig) func(archivePath string) error {
	images := newLinuxImageProvider(ProviderConfig{InstallDir: p.installDir, ConfigDir: p.configDir})

	return func(archivePath string) error {
		var failures []error
		for _, target := range targets {
			var err error
			if target.isLocal() {
				err = images.Import(ImageImportConfig{TarPath: archivePath, ShowOutput: cfg.ShowOutput})
			} else {
				logAddonImport("Importing %s on node '%s' (%s)", filepath.Base(archivePath), target.name, target.ip)
				err = importImageOnWorker(target, archivePath, cfg.SshPrivateKeyPath)
			}
			if err != nil {
				failures = append(failures, fmt.Errorf("node '%s': %w", target.name, err))
			}
		}
		return errors.Join(failures...)
	}
}

// importImageOnWorker copies an image archive to a Linux worker and loads it there with buildah, like
// Invoke-LinuxNodeImageImport of the Windows image scripts. The copy is removed afterwards.
func importImageOnWorker(target importTarget, archivePath, privateKeyPath string) error {
	// A unique name keeps concurrent imports on the same node from overwriting each other's archive.
	remotePath := fmt.Sprintf("/tmp/k2s-image-import-%s.tar", rand.Text())

	var output bytes.Buffer
	worker := connectWorker(sshprovider.ConnectionOptions{
		IpAddress:         target.ip,
		Port:              definitions.SSHDefaultPort,
		RemoteUser:        target.user,
		SshPrivateKeyPath: privateKeyPath,
		Timeout:           definitions.SSHDefaultTimeout,
		StdOutWriter:      &output,
	})

	if err := worker.CopyToNode(archivePath, remotePath); err != nil {
		return fmt.Errorf("copying the image archive failed: %w", err)
	}

	var importErr error
	for _, transport := range []string{"oci-archive", "docker-archive"} {
		output.Reset()
		if importErr = worker.Exec(fmt.Sprintf("sudo buildah pull %s:%s 2>&1", transport, remotePath)); importErr == nil {
			break
		}
	}
	if importErr != nil {
		importErr = fmt.Errorf("buildah pull failed: %w: %s", importErr, strings.TrimSpace(output.String()))
	}

	if cleanupErr := worker.Exec("sudo rm -f " + remotePath); cleanupErr != nil {
		return errors.Join(importErr, fmt.Errorf("removing the temporary image archive %s failed: %w", remotePath, cleanupErr))
	}
	return importErr
}

// listImageArchives returns the names of the per-image archives of an images layer without unpacking them.
func listImageArchives(layerPath string) ([]string, error) {
	layer, err := os.Open(layerPath)
	if err != nil {
		return nil, err
	}
	defer layer.Close()

	var names []string
	reader := tar.NewReader(layer)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			return names, nil
		}
		if err != nil {
			return nil, fmt.Errorf("reading Linux images layer: %w", err)
		}

		name := path.Base(strings.ReplaceAll(header.Name, `\`, "/"))
		if header.Typeflag == tar.TypeReg && strings.HasSuffix(name, ".tar") && !slices.Contains(names, name) {
			names = append(names, name)
		}
	}
}

// omitToken is one '--omit' value: '<flag>', '<addon>:<flag>' or '<addon>/<implementation>:<flag>'.
type omitToken struct {
	raw, addon, implementation, flag string
}

func parseOmitTokens(values []string) []omitToken {
	var tokens []omitToken
	for _, value := range values {
		value = strings.TrimSpace(value)
		token := omitToken{raw: value, flag: value}
		if scope, flag, scoped := strings.Cut(value, ":"); scoped {
			token.flag = strings.TrimSpace(flag)
			addon, implementation, hasImplementation := strings.Cut(strings.TrimSpace(scope), "/")
			token.addon = strings.TrimSpace(addon)
			if hasImplementation {
				token.implementation = strings.TrimSpace(implementation)
			}
		}
		if token.flag != "" {
			tokens = append(tokens, token)
		}
	}
	return tokens
}

func matchingOmitToken(tokens []omitToken, addon exportedAddon, flagName string) *omitToken {
	for i := range tokens {
		token := &tokens[i]
		if strings.EqualFold(token.flag, flagName) &&
			(token.addon == "" || strings.EqualFold(token.addon, addon.name)) &&
			(token.implementation == "" || strings.EqualFold(token.implementation, addon.implementation)) {
			return token
		}
	}
	return nil
}

// omitFlagsFor returns the enable flags that declare omittedImages. The manifest of the artifact is
// preferred; the installed manifest is the fallback so older artifacts can still be imported with --omit.
func omitFlagsFor(artifactManifestPath string, installedManifest []byte, implementation string) []addons.CliFlag {
	artifactManifest, _ := os.ReadFile(artifactManifestPath)
	for _, source := range []struct {
		origin string
		data   []byte
	}{{"artifact", artifactManifest}, {"installation", installedManifest}} {
		var manifest addons.Addon
		if len(source.data) == 0 || yaml.Unmarshal(source.data, &manifest) != nil || len(manifest.Spec.Implementations) == 0 {
			continue
		}

		implementations := manifest.Spec.Implementations
		selected := implementations[0]
		for _, candidate := range implementations {
			if implementation != "" && candidate.Name == implementation {
				selected = candidate
				break
			}
		}
		if selected.Commands == nil || (*selected.Commands)["enable"].Cli == nil {
			continue
		}

		var flags []addons.CliFlag
		for _, flag := range (*selected.Commands)["enable"].Cli.Flags {
			if flag.OmittedImages != nil {
				flags = append(flags, flag)
			}
		}
		if len(flags) > 0 {
			slog.Debug("[Prune] Using omit options declared by the manifest", "origin", source.origin, "count", len(flags))
			return flags
		}
	}
	return nil
}

var (
	imageLinePattern   = regexp.MustCompile(`(?i)^\s*image:\s*(.+)$`)
	imageArgPattern    = regexp.MustCompile(`--[a-zA-Z-]+=([a-zA-Z0-9.\-_/]+/[a-zA-Z0-9.\-_/]+:[a-zA-Z0-9.\-_]+)`)
	taggedImagePattern = regexp.MustCompile(`^(.+):(.+)$`)
	imageNameReplacer  = strings.NewReplacer(":", "_", "/", "_")
	imageNameSanitizer = regexp.MustCompile(`[^a-zA-Z0-9_.-]`)
)

// imagesFromYAML extracts the 'image:' values and '--flag=repo/image:tag' arguments of a manifest.
func imagesFromYAML(content string) []string {
	var images []string
	for _, line := range strings.Split(content, "\n") {
		if match := imageLinePattern.FindStringSubmatch(line); match != nil {
			value, _, _ := strings.Cut(match[1], "#")
			value = strings.Trim(strings.Trim(strings.TrimSpace(value), `"`), "'")
			if value != "" {
				images = append(images, value)
			}
		} else if match := imageArgPattern.FindStringSubmatch(line); match != nil {
			images = append(images, strings.TrimSpace(match[1]))
		}
	}
	return images
}

// removeVersionlessImages drops an image without tag when the same image is listed with a tag.
func removeVersionlessImages(images []string) []string {
	versioned := map[string]bool{}
	for _, image := range images {
		if match := taggedImagePattern.FindStringSubmatch(image); match != nil && strings.TrimSpace(match[2]) != "" {
			versioned[match[1]] = true
		}
	}

	var result []string
	for _, image := range images {
		match := taggedImagePattern.FindStringSubmatch(image)
		isVersioned := match != nil && strings.TrimSpace(match[2]) != ""
		if (isVersioned || !versioned[image]) && !slices.Contains(result, image) {
			result = append(result, image)
		}
	}
	return result
}

// omittedImagesForFlag resolves the images a flag's omittedImages block covers; relative files
// are resolved against the implementation directory.
func omittedImagesForFlag(flag addons.CliFlag, baseDir string) []string {
	var images []string
	for _, file := range flag.OmittedImages.FromFiles {
		if !filepath.IsAbs(file) {
			file = filepath.Join(baseDir, file)
		}
		content, err := os.ReadFile(file)
		if err != nil {
			slog.Warn("[Prune] YAML file not found", "file", file)
			continue
		}
		images = append(images, imagesFromYAML(string(content))...)
	}
	images = append(images, flag.OmittedImages.Explicit...)

	var cleaned []string
	for _, image := range images {
		image = strings.TrimSpace(strings.Trim(strings.TrimSpace(image), `"'`))
		if image != "" && !slices.Contains(cleaned, image) {
			cleaned = append(cleaned, image)
		}
	}
	return removeVersionlessImages(cleaned)
}

// imageArchiveName is the name an image gets inside an images layer ('repo/name:tag' -> 'repo_name_tag.tar').
func imageArchiveName(image string) string {
	return imageNameSanitizer.ReplaceAllString(imageNameReplacer.Replace(image), "") + ".tar"
}

// comparableImageKey reduces an image reference to registry and repository so that an omit
// declaration still matches an artifact that carries another version of the image.
func comparableImageKey(image string) string {
	reference, _, _ := strings.Cut(strings.TrimSpace(image), "@")
	slash := strings.LastIndex(reference, "/")
	lastSegment := reference[slash+1:]
	if tag := strings.LastIndex(lastSegment, ":"); tag >= 0 {
		reference = reference[:slash+1] + lastSegment[:tag]
	}
	reference = strings.TrimSpace(reference)
	if reference == "" {
		return ""
	}
	return imageNameSanitizer.ReplaceAllString(imageNameReplacer.Replace(reference), "")
}

// archiveIdentityKey derives the comparable key of an image archive name by dropping the version segment.
func archiveIdentityKey(archiveName string) string {
	name := path.Base(strings.TrimSpace(archiveName))
	if !strings.HasSuffix(name, ".tar") {
		return ""
	}
	name = strings.TrimPrefix(strings.TrimSuffix(name, ".tar"), "windows_")
	if separator := strings.LastIndex(name, "_"); separator > 0 {
		return name[:separator]
	}
	return ""
}

type prunedImage struct {
	image      string
	omittedBy  []string
	requiredBy []string
}

// imagePrunePlan holds which image archives each addon must not import because of --omit.
type imagePrunePlan struct {
	skip           map[string]map[string]bool
	pruned         []prunedImage
	retained       []prunedImage
	warnings       []string
	applied        []string
	unmatched      []string
	availableFlags []string
}

// newImagePrunePlan ports New-AddonImagePrunePlan of addons/imageprune.module.psm1. With
//
//	A = images an addon carries, O = images of the requested omit options, K = images of its
//	omit options that were not requested
//
// an addon still requires R = A - (O - K). An image is skipped only when no imported addon requires it.
func newImagePrunePlan(entries []*addonImportEntry, tokens []omitToken) *imagePrunePlan {
	plan := &imagePrunePlan{skip: map[string]map[string]bool{}}
	for _, entry := range entries {
		plan.skip[entry.addon.key()] = map[string]bool{}
	}

	allFiles := map[string]bool{}
	requiredFiles := map[string]bool{}
	omittedFiles := map[string]bool{}
	matchedTokens := map[string]bool{}
	fileToImages := map[string][]string{}
	omittedBy := map[string][]string{}
	requiredBy := map[string][]string{}
	appendUnique := func(m map[string][]string, key, value string) {
		if !slices.Contains(m[key], value) {
			m[key] = append(m[key], value)
		}
	}

	for _, entry := range entries {
		key := entry.addon.key()
		entryFiles := map[string]bool{}
		filesByIdentity := map[string][]string{}
		for _, file := range entry.imageFiles {
			entryFiles[file] = true
			allFiles[file] = true
			if identity := archiveIdentityKey(file); identity != "" {
				appendUnique(filesByIdentity, identity, file)
			}
		}

		entryOmitted := map[string]bool{}
		entryKept := map[string]bool{}
		for _, flag := range entry.flags {
			plan.availableFlags = append(plan.availableFlags, key+":"+flag.Name)

			flagImages := omittedImagesForFlag(flag, entry.implementationPath)
			if len(flagImages) == 0 {
				plan.warnings = append(plan.warnings, fmt.Sprintf("[Prune] Omit option '%s' of '%s' declares 'omittedImages' but no image reference could be resolved - not pruning for this option.", flag.Name, key))
				continue
			}

			flagFiles := map[string]bool{}
			for _, image := range flagImages {
				// An exact match comes first; the identity fallback tolerates another version in the artifact.
				var matched []string
				if archive := imageArchiveName(image); entryFiles[archive] {
					matched = []string{archive}
				} else if identity := comparableImageKey(image); identity != "" {
					matched = filesByIdentity[identity]
				}
				for _, file := range matched {
					flagFiles[file] = true
					appendUnique(fileToImages, file, image)
				}
			}

			if token := matchingOmitToken(tokens, entry.addon, flag.Name); token != nil {
				matchedTokens[token.raw] = true
				for file := range flagFiles {
					entryOmitted[file] = true
					appendUnique(omittedBy, file, fmt.Sprintf("%s (--omit %s)", key, flag.Name))
				}
			} else {
				for file := range flagFiles {
					entryKept[file] = true
				}
			}
		}

		for _, file := range entry.imageFiles {
			if !entryOmitted[file] || entryKept[file] {
				requiredFiles[file] = true
				appendUnique(requiredBy, file, key)
			}
		}
		maps.Copy(omittedFiles, entryOmitted)
	}

	// The guard keeps an archive that two different images map onto after name sanitization.
	prunable := map[string]bool{}
	for _, file := range slices.Sorted(maps.Keys(allFiles)) {
		if requiredFiles[file] {
			continue
		}
		identities := map[string]bool{}
		for _, image := range fileToImages[file] {
			if identity := comparableImageKey(image); identity != "" {
				identities[identity] = true
			}
		}
		if len(identities) > 1 {
			plan.warnings = append(plan.warnings, fmt.Sprintf("[Prune] '%s' maps to more than one image reference (%s) - keeping it to stay on the safe side.", file, strings.Join(fileToImages[file], ", ")))
			continue
		}
		prunable[file] = true
	}

	for _, entry := range entries {
		for _, file := range entry.imageFiles {
			if prunable[file] {
				plan.skip[entry.addon.key()][file] = true
			}
		}
	}

	for _, file := range slices.Sorted(maps.Keys(omittedFiles)) {
		image := prunedImage{image: file, omittedBy: omittedBy[file], requiredBy: requiredBy[file]}
		if len(fileToImages[file]) > 0 {
			image.image = strings.Join(fileToImages[file], ", ")
		}
		if prunable[file] {
			plan.pruned = append(plan.pruned, image)
		} else {
			plan.retained = append(plan.retained, image)
		}
	}

	for _, token := range tokens {
		if matchedTokens[token.raw] {
			plan.applied = append(plan.applied, token.raw)
		} else {
			plan.unmatched = append(plan.unmatched, token.raw)
		}
	}
	plan.availableFlags = slices.Compact(slices.Sorted(slices.Values(plan.availableFlags)))

	return plan
}

// log reports the decisions of the plan before any image is imported.
func (plan *imagePrunePlan) log() {
	for _, warning := range plan.warnings {
		logAddonImport("%s", warning)
	}
	for _, token := range plan.unmatched {
		logAddonImport("[Prune] WARNING: '--omit %s' did not match any addon selected for import - ignoring it.", token)
		if len(plan.availableFlags) > 0 {
			logAddonImport("[Prune] Omit options available in this artifact: %s", strings.Join(plan.availableFlags, ", "))
		} else {
			logAddonImport("[Prune] This artifact does not declare any omit options.")
		}
	}
	if len(plan.applied) > 0 {
		logAddonImport("[Prune] Applied omit options: %s", strings.Join(plan.applied, ", "))
	}
	for _, image := range plan.pruned {
		logAddonImport("[Prune] SKIPPED  %s", image.image)
		logAddonImport("[Prune]          omitted by : %s", strings.Join(image.omittedBy, ", "))
	}
	for _, image := range plan.retained {
		logAddonImport("[Prune] RETAINED %s", image.image)
		logAddonImport("[Prune]          omitted by : %s", strings.Join(image.omittedBy, ", "))
		logAddonImport("[Prune]          required by: %s", strings.Join(image.requiredBy, ", "))
	}
}

// logSummary lists the images that were not imported once the import has finished.
func (plan *imagePrunePlan) logSummary() {
	if len(plan.pruned) == 0 {
		return
	}
	logAddonImport("Omit options were applied: %d image(s) were not imported.", len(plan.pruned))
	for _, image := range plan.pruned {
		logAddonImport("  - %s", image.image)
	}
	logAddonImport("Enable the affected addons with the matching omit options, or re-run the import without")
	logAddonImport("the omit options to add these images later. The OCI artifact itself is unchanged.")
}

func (p *linuxAddonProvider) RunCommand(cfg AddonRunCommandConfig) error {
	params := parsePsParams(cfg.Params)
	if err := rejectInfraNodeSelector(params, cfg.ParameterValues); err != nil {
		return err
	}
	switch cfg.CommandName {
	case "enable":
		return p.Enable(AddonEnableConfig{
			Name:           cfg.AddonName,
			Implementation: cfg.Implementation,
			Params:         params,
			ShowOutput:     cfg.ShowOutput,
		})
	case "disable":
		return p.Disable(AddonDisableConfig{
			Name:           cfg.AddonName,
			Implementation: cfg.Implementation,
			Params:         params,
			ShowOutput:     cfg.ShowOutput,
		})
	default:
		return NotSupportedError(fmt.Sprintf("addon %s", cfg.CommandName),
			fmt.Sprintf("addon '%s' command on Linux hosts is not yet implemented", cfg.CommandName))
	}
}

// rejectInfraNodeSelector fails before any side effect because selector placement is Windows-hosted only.
func rejectInfraNodeSelector(params, parameterValues map[string]string) error {
	if params["infranodeselector"] == "" && parameterValues["InfraNodeSelector"] == "" {
		return nil
	}
	return NotSupportedError("infra-node-selector",
		"infrastructure node selector placement is supported on Windows-hosted clusters only; remove --infra-node-selector")
}

func parsePsParams(params []string) map[string]string {
	m := make(map[string]string)
	for i := 0; i < len(params); i++ {
		p := strings.TrimSpace(params[i])
		if !strings.HasPrefix(p, "-") {
			continue
		}
		p = strings.TrimPrefix(p, "-")

		// Case 1: "-Key Value" (space-separated in single entry)
		if spaceIdx := strings.Index(p, " "); spaceIdx != -1 {
			key := strings.ToLower(strings.TrimSpace(p[:spaceIdx]))
			val := strings.Trim(strings.TrimSpace(p[spaceIdx+1:]), "'\"")
			m[key] = val
			continue
		}

		// Case 2: "-Key:Value"
		if colonIdx := strings.Index(p, ":"); colonIdx != -1 {
			key := strings.ToLower(strings.TrimSpace(p[:colonIdx]))
			val := strings.Trim(strings.TrimSpace(p[colonIdx+1:]), "'\"")
			m[key] = val
			continue
		}

		// Case 3: "-Key" followed by "Value" in next element
		key := strings.ToLower(strings.TrimSpace(p))
		if i+1 < len(params) && !strings.HasPrefix(strings.TrimSpace(params[i+1]), "-") {
			m[key] = strings.Trim(strings.TrimSpace(params[i+1]), "'\"")
			i++
		} else {
			// Case 4: Boolean flag
			m[key] = "true"
		}
	}
	return m
}

func (p *linuxAddonProvider) addAddonToConfig(addonName string, impl ...string) error {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := json.FromFile[map[string]any](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("loading setup config: %w", err)
	}

	implementation := ""
	if len(impl) > 0 {
		implementation = impl[0]
	}

	var addons []any
	if rawAddons, ok := (*cfgMap)["EnabledAddons"]; ok && rawAddons != nil {
		if list, ok := rawAddons.([]any); ok {
			addons = append(addons, list...)
		}
	}

	exists := false
	for _, a := range addons {
		if m, ok := a.(map[string]any); ok {
			if n, ok := m["Name"].(string); ok && strings.EqualFold(n, addonName) {
				if implementation == "" {
					exists = true
					break
				}
				if im, ok := m["Implementation"].(string); ok && strings.EqualFold(im, implementation) {
					exists = true
					break
				}
			}
		}
	}
	if !exists {
		addons = append(addons, map[string]any{
			"Name":           addonName,
			"Implementation": implementation,
		})
	}

	(*cfgMap)["EnabledAddons"] = addons
	return json.ToFile(configPath, cfgMap)
}

func (p *linuxAddonProvider) removeAddonFromConfig(addonName string, impl ...string) error {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := json.FromFile[map[string]any](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("loading setup config: %w", err)
	}

	implementation := ""
	if len(impl) > 0 {
		implementation = impl[0]
	}

	var addons []any
	if rawAddons, ok := (*cfgMap)["EnabledAddons"]; ok && rawAddons != nil {
		if list, ok := rawAddons.([]any); ok {
			for _, a := range list {
				if m, ok := a.(map[string]any); ok {
					if n, ok := m["Name"].(string); ok && strings.EqualFold(n, addonName) {
						if implementation != "" {
							if im, ok := m["Implementation"].(string); ok && strings.EqualFold(im, implementation) {
								continue
							}
						} else {
							continue
						}
					}
				}
				addons = append(addons, a)
			}
		}
	}

	(*cfgMap)["EnabledAddons"] = addons
	return json.ToFile(configPath, cfgMap)
}

func (p *linuxAddonProvider) addRegistryToConfig(registry string) error {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := json.FromFile[map[string]any](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("loading setup config: %w", err)
	}

	var registries []any
	if rawRegs, ok := (*cfgMap)["Registries"]; ok && rawRegs != nil {
		if list, ok := rawRegs.([]any); ok {
			registries = append(registries, list...)
		}
	}

	exists := false
	for _, r := range registries {
		if s, ok := r.(string); ok && s == registry {
			exists = true
			break
		}
	}
	if !exists {
		registries = append(registries, registry)
	}

	(*cfgMap)["Registries"] = registries
	return json.ToFile(configPath, cfgMap)
}

func (p *linuxAddonProvider) removeRegistryFromConfig(registry string) error {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := json.FromFile[map[string]any](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("loading setup config: %w", err)
	}

	var registries []any
	if rawRegs, ok := (*cfgMap)["Registries"]; ok && rawRegs != nil {
		if list, ok := rawRegs.([]any); ok {
			for _, r := range list {
				if s, ok := r.(string); ok && s == registry {
					continue
				}
				registries = append(registries, r)
			}
		}
	}

	(*cfgMap)["Registries"] = registries
	return json.ToFile(configPath, cfgMap)
}

func updateHostsContent(content, hostname, ip string) string {
	lines := strings.Split(content, "\n")
	var newLines []string
	found := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") {
			newLines = append(newLines, line)
			continue
		}
		fields := strings.Fields(trimmed)
		if len(fields) >= 2 {
			var remaining []string
			hasHost := false
			for _, f := range fields[1:] {
				if f == hostname {
					hasHost = true
				} else {
					remaining = append(remaining, f)
				}
			}
			if hasHost {
				if fields[0] == ip && len(remaining) == 0 {
					found = true
					newLines = append(newLines, line)
					continue
				}
				if len(remaining) > 0 {
					newLines = append(newLines, fmt.Sprintf("%s %s", fields[0], strings.Join(remaining, " ")))
				}
				continue
			}
		}
		newLines = append(newLines, line)
	}
	if !found {
		newLines = append(newLines, fmt.Sprintf("%s %s", ip, hostname))
	}
	return strings.Join(newLines, "\n")
}

func removeHostsContent(content, hostname string) string {
	lines := strings.Split(content, "\n")
	var newLines []string
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") {
			newLines = append(newLines, line)
			continue
		}
		fields := strings.Fields(trimmed)
		if len(fields) >= 2 {
			var remaining []string
			hasHost := false
			for _, f := range fields[1:] {
				if f == hostname {
					hasHost = true
				} else {
					remaining = append(remaining, f)
				}
			}
			if hasHost {
				if len(remaining) > 0 {
					newLines = append(newLines, fmt.Sprintf("%s %s", fields[0], strings.Join(remaining, " ")))
				}
				continue
			}
		}
		newLines = append(newLines, line)
	}
	return strings.Join(newLines, "\n")
}

func setHostEntry(hostname, ip string) {
	content, err := os.ReadFile("/etc/hosts")
	if err != nil {
		return
	}
	newContent := updateHostsContent(string(content), hostname, ip)
	if err := os.WriteFile("/etc/hosts", []byte(newContent), 0o644); err != nil {
		cmd := exec.Command("sudo", "sh", "-c", fmt.Sprintf("printf '%%s\n' %q > /etc/hosts", newContent))
		_ = cmd.Run()
	}
}

func removeHostEntry(hostname string) {
	content, err := os.ReadFile("/etc/hosts")
	if err != nil {
		return
	}
	newContent := removeHostsContent(string(content), hostname)
	if err := os.WriteFile("/etc/hosts", []byte(newContent), 0o644); err != nil {
		cmd := exec.Command("sudo", "sh", "-c", fmt.Sprintf("printf '%%s\n' %q > /etc/hosts", newContent))
		_ = cmd.Run()
	}
}

func getNodeIP() string {
	out, err := exec.Command("kubectl", "get", "nodes", "-o", "jsonpath={.items[0].status.addresses[?(@.type==\"InternalIP\")].address}").Output()
	if err == nil && len(strings.TrimSpace(string(out))) > 0 {
		return strings.TrimSpace(string(out))
	}
	return "127.0.0.1"
}

func (p *linuxAddonProvider) isAddonEnabledInConfig(addonName string, impl ...string) bool {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := json.FromFile[map[string]any](configPath)
	if err != nil {
		return false
	}
	if rawAddons, ok := (*cfgMap)["EnabledAddons"]; ok && rawAddons != nil {
		if list, ok := rawAddons.([]any); ok {
			for _, a := range list {
				if m, ok := a.(map[string]any); ok {
					if n, ok := m["Name"].(string); ok && strings.EqualFold(n, addonName) {
						if len(impl) > 0 && impl[0] != "" {
							if im, ok := m["Implementation"].(string); ok && !strings.EqualFold(im, impl[0]) {
								continue
							}
						}
						return true
					}
				}
			}
		}
	}
	return false
}

// isAddonDeployed checks if an addon has any pods deployed in the cluster.
func isAddonDeployed(addonName string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), defaultKubeTimeout)
	defer cancel()

	namespaces := []string{addonName}
	if addonName == "ingress" {
		namespaces = append(namespaces, "ingress-nginx", "ingress-traefik", "nginx-gw")
	}

	for _, ns := range namespaces {
		output, err := exec.CommandContext(ctx, "kubectl", "get", "pods", "-n", ns,
			"-o", "jsonpath={.items}").Output()
		if err == nil && len(strings.TrimSpace(string(output))) > 2 {
			return true
		}
	}

	output, err := exec.CommandContext(ctx, "kubectl", "get", "pods", "-A",
		"-l", fmt.Sprintf("app.kubernetes.io/name=%s", addonName),
		"-o", "jsonpath={.items}").Output()
	if err == nil && len(strings.TrimSpace(string(output))) > 2 {
		return true
	}

	output, err = exec.CommandContext(ctx, "kubectl", "get", "pods", "-A",
		"-l", fmt.Sprintf("app=%s", addonName),
		"-o", "jsonpath={.items}").Output()
	if err == nil && len(strings.TrimSpace(string(output))) > 2 {
		return true
	}

	return false
}
