// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build linux

package provider

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/host"
	kjson "github.com/k2s-project/k2s/internal/json"
	"gopkg.in/yaml.v3"
)

func init() {
	if os.Getenv("KUBECONFIG") == "" {
		if _, err := os.Stat("/etc/kubernetes/admin.conf"); err == nil {
			_ = os.Setenv("KUBECONFIG", "/etc/kubernetes/admin.conf")
		}
	}
}

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
		if err := os.WriteFile(dstPath, data, 0644); err != nil {
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
	rmRegScript := filepath.Join(p.installDir, "lib", "scripts", "linux", "debian", "host", "image", "registry", "Remove-Registry.sh")
	if _, err := os.Stat(rmRegScript); err == nil {
		_ = exec.Command(rmRegScript, "--registry", "k2s.registry.local:30500").Run()
		_ = exec.Command(rmRegScript, "--registry", "k2s.registry.local").Run()
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

func (p *linuxAddonProvider) updateRegistryIngress() error {
	if !p.isAddonEnabledInConfig("registry") && !isAddonDeployed("registry") {
		return nil
	}

	addRegScript := filepath.Join(p.installDir, "lib", "scripts", "linux", "debian", "host", "image", "registry", "Add-Registry.sh")
	rmRegScript := filepath.Join(p.installDir, "lib", "scripts", "linux", "debian", "host", "image", "registry", "Remove-Registry.sh")

	if p.isAddonEnabledInConfig("ingress", "nginx") {
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-traefik"), "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx-gw"), "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "-f", filepath.Join(p.installDir, "addons", "registry", "manifests", "registry", "service-nodeport.yaml"), "--ignore-not-found").Run()

		_ = exec.Command("kubectl", "apply", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx")).Run()

		_ = exec.Command(rmRegScript, "--registry", "k2s.registry.local:30500").Run()
		_ = exec.Command(addRegScript, "--registry", "k2s.registry.local", "--plain-http").Run()

		_ = p.removeRegistryFromConfig("k2s.registry.local:30500")
		_ = p.addRegistryToConfig("k2s.registry.local")
	} else if p.isAddonEnabledInConfig("ingress", "traefik") {
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx"), "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx-gw"), "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "-f", filepath.Join(p.installDir, "addons", "registry", "manifests", "registry", "service-nodeport.yaml"), "--ignore-not-found").Run()

		_ = exec.Command("kubectl", "apply", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-traefik")).Run()

		_ = exec.Command(rmRegScript, "--registry", "k2s.registry.local:30500").Run()
		_ = exec.Command(addRegScript, "--registry", "k2s.registry.local", "--plain-http").Run()

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

		_ = exec.Command(rmRegScript, "--registry", "k2s.registry.local:30500").Run()
		_ = exec.Command(addRegScript, "--registry", "k2s.registry.local", "--plain-http").Run()

		_ = p.removeRegistryFromConfig("k2s.registry.local:30500")
		_ = p.addRegistryToConfig("k2s.registry.local")
	} else {
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx"), "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-traefik"), "--ignore-not-found").Run()
		_ = exec.Command("kubectl", "delete", "-k", filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx-gw"), "--ignore-not-found").Run()

		_ = exec.Command("kubectl", "apply", "-f", filepath.Join(p.installDir, "addons", "registry", "manifests", "registry", "service-nodeport.yaml")).Run()

		_ = exec.Command(rmRegScript, "--registry", "k2s.registry.local").Run()
		_ = exec.Command(addRegScript, "--registry", "k2s.registry.local:30500", "--plain-http").Run()

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

func (p *linuxAddonProvider) Import(_ AddonImportConfig) error {
	return NotSupportedError("addons import",
		"addon import on Linux hosts is not yet implemented")
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
	cfgMap, err := kjson.FromFile[map[string]any](configPath)
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
	return kjson.ToFile(configPath, cfgMap)
}

func (p *linuxAddonProvider) removeAddonFromConfig(addonName string, impl ...string) error {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := kjson.FromFile[map[string]any](configPath)
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
	return kjson.ToFile(configPath, cfgMap)
}

func (p *linuxAddonProvider) addRegistryToConfig(registry string) error {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := kjson.FromFile[map[string]any](configPath)
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
	return kjson.ToFile(configPath, cfgMap)
}

func (p *linuxAddonProvider) removeRegistryFromConfig(registry string) error {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := kjson.FromFile[map[string]any](configPath)
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
	return kjson.ToFile(configPath, cfgMap)
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
	if err := os.WriteFile("/etc/hosts", []byte(newContent), 0644); err != nil {
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
	if err := os.WriteFile("/etc/hosts", []byte(newContent), 0644); err != nil {
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
	cfgMap, err := kjson.FromFile[map[string]any](configPath)
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
