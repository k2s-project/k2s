// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/k2s-project/k2s/internal/version"
)

// Addon backups created on Linux hosts use the same layout as the Windows
// Backup.ps1 scripts (backup.json plus the files it lists), so an archive can
// be restored on either host variant.
const (
	addonBackupManifestFileName = "backup.json"

	registryNamespace         = "registry"
	registryStatefulSet       = "registry"
	registryRepositoryArchive = "registry-repository.tar.gz"
	registryConfigBackupFile  = "registry-config.json"
	registryConfigMapName     = "registry-config"

	registryPodsTerminationTimeout = 180 * time.Second
	registryPodsPollInterval       = 2 * time.Second
)

var (
	// linuxRegistryDataDir is the host directory backing the registry
	// PersistentVolume (see enableRegistry).
	linuxRegistryDataDir = "/registry"

	kubectlConflictPattern = regexp.MustCompile(`(?i)the object has been modified|conflict`)
)

// linuxAddonCommandOutput runs a command and returns its stdout. Stderr is kept
// out of the output so that warnings cannot corrupt exported manifests; it is
// part of the returned error instead.
var linuxAddonCommandOutput = func(name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return out, fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

// addonBackupManifest is the backup.json written next to the backup files.
type addonBackupManifest struct {
	K2sVersion     string   `json:"k2sVersion"`
	Addon          string   `json:"addon"`
	Implementation string   `json:"implementation,omitempty"`
	Files          []string `json:"files"`
	CreatedAt      string   `json:"createdAt"`
}

// linuxAddonDataHandler backs up and restores the data of one addon implementation.
// backup writes its files into the backup directory and returns their names;
// restore runs after the addon has been enabled again.
type linuxAddonDataHandler struct {
	backup  func(backupDir string) ([]string, error)
	restore func(backupDir string, files []string) error
}

// linuxAddonDataHandlers lists the addons whose backup and restore are
// implemented natively on Linux hosts, keyed by their 'k2s addons' name.
var linuxAddonDataHandlers = map[string]linuxAddonDataHandler{
	"registry": {backup: backupRegistry, restore: restoreRegistry},
	"ingress nginx": {
		backup: func(backupDir string) ([]string, error) {
			return backupKubeResources(backupDir, "ingress-nginx", []kubeResourceBackup{
				{kind: "configmap", name: "ingress-nginx-controller", file: "ingress-nginx-controller-configmap.yaml"},
				{kind: "ingress", name: "nginx-cluster-local", file: "nginx-cluster-local-ingress.yaml", optional: true},
			})
		},
		restore: applyBackupFiles,
	},
	"ingress traefik": {
		backup: func(backupDir string) ([]string, error) {
			return backupKubeResources(backupDir, "ingress-traefik", []kubeResourceBackup{
				{kind: "ingress", name: "traefik-cluster-local", file: "traefik-cluster-local-ingress.yaml"},
			})
		},
		restore: applyBackupFiles,
	},
}

func (p *linuxAddonProvider) Backup(cfg AddonBackupConfig) error {
	name := addonCmdName(cfg.AddonName, cfg.Implementation)
	handler, err := linuxAddonDataHandlerFor("addons backup", name)
	if err != nil {
		return err
	}

	implementation := configImplementation(cfg.AddonName, cfg.Implementation)
	if !p.isAddonEnabledInConfig(cfg.AddonName, implementation) {
		return fmt.Errorf("addon '%s' is not enabled; enable it before running backup", name)
	}

	slog.Info("[AddonBackup] Backing up addon", "name", name)
	files, err := handler.backup(cfg.BackupDir)
	if err != nil {
		return fmt.Errorf("backup of addon '%s' failed: %w", name, err)
	}
	if files == nil {
		files = []string{}
	}

	data, err := json.MarshalIndent(addonBackupManifest{
		K2sVersion:     version.GetVersion().Version,
		Addon:          cfg.AddonName,
		Implementation: implementation,
		Files:          files,
		CreatedAt:      time.Now().Format(time.RFC3339),
	}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(cfg.BackupDir, addonBackupManifestFileName), data, 0o600); err != nil {
		return fmt.Errorf("writing %s failed: %w", addonBackupManifestFileName, err)
	}

	slog.Info("[AddonBackup] Backup artifacts prepared", "name", name, "files", len(files))
	return nil
}

func (p *linuxAddonProvider) Restore(cfg AddonRestoreConfig) error {
	name := addonCmdName(cfg.AddonName, cfg.Implementation)
	handler, err := linuxAddonDataHandlerFor("addons restore", name)
	if err != nil {
		return err
	}
	if err := rejectInfraNodeSelector(nil, map[string]string{"InfraNodeSelector": cfg.InfraNodeSelector}); err != nil {
		return err
	}

	// Validate the backup before enabling anything, so a broken archive leaves the cluster untouched.
	files, err := readAddonBackupFiles(cfg.BackupDir)
	if err != nil {
		return err
	}

	if err := p.Enable(AddonEnableConfig{
		Name:           cfg.AddonName,
		Implementation: configImplementation(cfg.AddonName, cfg.Implementation),
		ShowOutput:     cfg.ShowOutput,
	}); err != nil {
		return fmt.Errorf("enabling addon '%s' for restore failed: %w", name, err)
	}

	if len(files) == 0 {
		slog.Info("[AddonRestore] Backup contains no files; addon was only re-enabled", "name", name)
		return nil
	}

	slog.Info("[AddonRestore] Restoring addon data", "name", name)
	if err := handler.restore(cfg.BackupDir, files); err != nil {
		return fmt.Errorf("restore of addon '%s' failed: %w", name, err)
	}
	slog.Info("[AddonRestore] Restore completed", "name", name)
	return nil
}

func linuxAddonDataHandlerFor(operation, name string) (linuxAddonDataHandler, error) {
	handler, ok := linuxAddonDataHandlers[name]
	if !ok {
		supported := make([]string, 0, len(linuxAddonDataHandlers))
		for key := range linuxAddonDataHandlers {
			supported = append(supported, "'"+key+"'")
		}
		slices.Sort(supported)
		return linuxAddonDataHandler{}, NotSupportedError(operation,
			fmt.Sprintf("addon '%s' cannot be backed up or restored on Linux hosts yet; supported addons: %s",
				name, strings.Join(supported, ", ")))
	}
	return handler, nil
}

// configImplementation returns the implementation name as stored in the
// runtime config: empty for single-implementation addons.
func configImplementation(addonName, implementation string) string {
	if implementation == addonName {
		return ""
	}
	return implementation
}

// readAddonBackupFiles returns the file list of backup.json and makes sure
// every entry is a plain file name that exists in the backup directory.
func readAddonBackupFiles(backupDir string) ([]string, error) {
	data, err := os.ReadFile(filepath.Join(backupDir, addonBackupManifestFileName))
	if err != nil {
		return nil, fmt.Errorf("reading %s failed: %w", addonBackupManifestFileName, err)
	}
	var manifest struct {
		Files []string `json:"files"`
	}
	if err := json.Unmarshal(bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF}), &manifest); err != nil {
		return nil, fmt.Errorf("invalid %s: %w", addonBackupManifestFileName, err)
	}
	for _, file := range manifest.Files {
		if file == "" || file != filepath.Base(file) || file == "." || file == ".." {
			return nil, fmt.Errorf("invalid %s: file entry '%s' is not a plain file name", addonBackupManifestFileName, file)
		}
		if _, err := os.Stat(filepath.Join(backupDir, file)); err != nil {
			return nil, fmt.Errorf("backup file '%s' not found: %w", file, err)
		}
	}
	return manifest.Files, nil
}

// kubeResourceBackup describes a Kubernetes object exported as YAML.
type kubeResourceBackup struct {
	kind     string
	name     string
	file     string
	optional bool // a missing object is skipped instead of failing the backup
}

func backupKubeResources(backupDir, namespace string, resources []kubeResourceBackup) ([]string, error) {
	if _, err := linuxAddonCommandOutput("kubectl", "get", "namespace", namespace); err != nil {
		return nil, fmt.Errorf("checking namespace '%s' failed: %w", namespace, err)
	}

	files := []string{}
	for _, resource := range resources {
		out, err := linuxAddonCommandOutput("kubectl", "get", resource.kind, resource.name, "-n", namespace, "-o", "yaml")
		if err != nil {
			if resource.optional && isKubectlNotFound(err) {
				slog.Info("[AddonBackup] Optional resource not found; skipping", "kind", resource.kind, "name", resource.name, "namespace", namespace)
				continue
			}
			return nil, fmt.Errorf("exporting %s '%s' failed: %w", resource.kind, resource.name, err)
		}
		if err := os.WriteFile(filepath.Join(backupDir, resource.file), out, 0o600); err != nil {
			return nil, err
		}
		files = append(files, resource.file)
	}
	return files, nil
}

// applyBackupFiles applies exported manifests. Exports carry a resourceVersion,
// so an object that changed since the backup is replaced instead.
func applyBackupFiles(backupDir string, files []string) error {
	for _, file := range files {
		path := filepath.Join(backupDir, file)
		_, err := linuxAddonCommandOutput("kubectl", "apply", "-f", path)
		if err == nil {
			continue
		}
		if !kubectlConflictPattern.MatchString(err.Error()) {
			return fmt.Errorf("applying '%s' failed: %w", file, err)
		}
		slog.Info("[AddonRestore] Conflict while applying backup file; replacing object", "file", file)
		if _, err := linuxAddonCommandOutput("kubectl", "replace", "--force", "-f", path); err != nil {
			return fmt.Errorf("applying '%s' failed with a conflict and replacing it failed too: %w", file, err)
		}
	}
	return nil
}

func backupRegistry(backupDir string) ([]string, error) {
	repositoryDir := filepath.Join(linuxRegistryDataDir, "repository")
	if info, err := os.Stat(repositoryDir); err != nil || !info.IsDir() {
		return nil, fmt.Errorf("registry repository directory '%s' not found", repositoryDir)
	}

	// Same archive layout as the Windows backup ('repository/...' relative to the data directory).
	archivePath := filepath.Join(backupDir, registryRepositoryArchive)
	if _, err := linuxAddonCommandOutput("sudo", "tar", "-czf", archivePath, "-C", linuxRegistryDataDir, "repository"); err != nil {
		return nil, fmt.Errorf("archiving '%s' failed: %w", repositoryDir, err)
	}
	files := []string{registryRepositoryArchive}

	out, err := linuxAddonCommandOutput("kubectl", "get", "configmap", registryConfigMapName, "-n", registryNamespace, "-o", "json")
	if err != nil {
		if !isKubectlNotFound(err) {
			return nil, fmt.Errorf("exporting configmap '%s' failed: %w", registryConfigMapName, err)
		}
		slog.Info("[AddonBackup] ConfigMap 'registry-config' not found; backup contains the registry data only")
		return files, nil
	}

	configMap, err := minimalConfigMap(out, registryConfigMapName, registryNamespace)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(backupDir, registryConfigBackupFile), configMap, 0o600); err != nil {
		return nil, err
	}
	return append(files, registryConfigBackupFile), nil
}

// minimalConfigMap keeps only the identity and data of a ConfigMap, dropping
// resourceVersion and managedFields so that restoring it does not conflict.
func minimalConfigMap(configMapJSON []byte, name, namespace string) ([]byte, error) {
	var source struct {
		Data map[string]string `json:"data"`
	}
	if err := json.Unmarshal(configMapJSON, &source); err != nil {
		return nil, fmt.Errorf("parsing configmap '%s' failed: %w", name, err)
	}
	return json.MarshalIndent(map[string]any{
		"apiVersion": "v1",
		"kind":       "ConfigMap",
		"metadata":   map[string]string{"name": name, "namespace": namespace},
		"data":       source.Data,
	}, "", "  ")
}

func restoreRegistry(backupDir string, files []string) error {
	if !slices.Contains(files, registryRepositoryArchive) {
		return fmt.Errorf("backup does not contain required archive '%s'", registryRepositoryArchive)
	}
	archivePath := filepath.Join(backupDir, registryRepositoryArchive)
	repositoryDir := filepath.Join(linuxRegistryDataDir, "repository")

	slog.Info("[AddonRestore] Scaling registry StatefulSet to 0")
	if _, err := linuxAddonCommandOutput("kubectl", "scale", "statefulset", registryStatefulSet, "-n", registryNamespace, "--replicas=0"); err != nil {
		return fmt.Errorf("scaling down StatefulSet '%s' failed: %w", registryStatefulSet, err)
	}
	if !waitForNoRegistryPods() {
		slog.Warn("[AddonRestore] Registry pods did not terminate in time; continuing restore")
	}

	slog.Info("[AddonRestore] Restoring registry repository", "dir", repositoryDir)
	if _, err := linuxAddonCommandOutput("sudo", "mkdir", "-p", repositoryDir); err != nil {
		return fmt.Errorf("creating '%s' failed: %w", repositoryDir, err)
	}
	if _, err := linuxAddonCommandOutput("sudo", "find", repositoryDir, "-mindepth", "1", "-delete"); err != nil {
		return fmt.Errorf("clearing '%s' failed: %w", repositoryDir, err)
	}
	if _, err := linuxAddonCommandOutput("sudo", "tar", "-xzf", archivePath, "-C", linuxRegistryDataDir); err != nil {
		return fmt.Errorf("extracting '%s' failed: %w", registryRepositoryArchive, err)
	}

	// Older Windows backups may carry the ConfigMap as YAML.
	for _, configFile := range []string{registryConfigBackupFile, "registry-config.yaml"} {
		if !slices.Contains(files, configFile) {
			continue
		}
		slog.Info("[AddonRestore] Restoring ConfigMap 'registry-config'", "file", configFile)
		if _, err := linuxAddonCommandOutput("kubectl", "apply", "--server-side", "--force-conflicts",
			"--field-manager=k2s-addon-restore", "-f", filepath.Join(backupDir, configFile)); err != nil {
			slog.Warn("[AddonRestore] Restoring ConfigMap 'registry-config' failed; keeping the current configuration", "error", err)
		}
		break
	}

	if _, err := linuxAddonCommandOutput("kubectl", "scale", "statefulset", registryStatefulSet, "-n", registryNamespace, "--replicas=1"); err != nil {
		return fmt.Errorf("scaling up StatefulSet '%s' failed: %w", registryStatefulSet, err)
	}
	if _, err := linuxAddonCommandOutput("kubectl", "rollout", "status", "statefulset", registryStatefulSet, "-n", registryNamespace, "--timeout=300s"); err != nil {
		return fmt.Errorf("registry did not become ready in time: %w", err)
	}
	return nil
}

func waitForNoRegistryPods() bool {
	deadline := time.Now().Add(registryPodsTerminationTimeout)
	for {
		out, err := linuxAddonCommandOutput("kubectl", "get", "pods", "-n", registryNamespace, "-l", "app=registry", "-o", "name")
		if err == nil && strings.TrimSpace(string(out)) == "" {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(registryPodsPollInterval)
	}
}

// isKubectlNotFound reports whether kubectl failed because the object does not
// exist ("Error from server (NotFound): ...").
func isKubectlNotFound(err error) bool {
	return err != nil && strings.Contains(err.Error(), "(NotFound)")
}
