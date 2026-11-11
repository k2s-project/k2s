// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build linux

package provider

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/k2s-project/k2s/internal/providers/bash"
	"github.com/k2s-project/k2s/internal/version"
	"gopkg.in/yaml.v3"
)

const (
	defaultKubeTimeout        = 30 * time.Second
	defaultImageExportTimeout = 10 * time.Minute
	defaultHookTimeout        = 5 * time.Minute
	clusterReachableTimeout   = 10 * time.Second
)

type rawBackupConfigJSON struct {
	SmallSetup struct {
		Backup struct {
			ExcludedNamespaces             string `json:"excludednamespaces"`
			ExcludedNamespacedResources    string `json:"excludednamespacedresources"`
			ExcludedClusterResources       string `json:"excludedclusterresources"`
			ExcludedAddonPersistentVolumes string `json:"excludedaddonpersistentvolumes"`
		} `json:"backup"`
	} `json:"smallsetup"`
	Backup struct {
		ExcludedNamespaces             string `json:"excludednamespaces"`
		ExcludedNamespacedResources    string `json:"excludednamespacedresources"`
		ExcludedClusterResources       string `json:"excludedclusterresources"`
		ExcludedAddonPersistentVolumes string `json:"excludedaddonpersistentvolumes"`
	} `json:"backup"`
	ClusterName string `json:"clusterName"`
}

type backupConfig struct {
	ExcludedNamespaces             []string
	ExcludedNamespacedResources    []string
	ExcludedClusterResources       []string
	ExcludedAddonPersistentVolumes []string
	ClusterName                    string
}

type backupManifest struct {
	APIVersion     string                 `json:"apiVersion"`
	Kind           string                 `json:"kind"`
	Metadata       backupManifestMetadata `json:"metadata"`
	Cluster        backupManifestCluster  `json:"cluster"`
	Content        backupManifestContent  `json:"content"`
	ConfigSnapshot backupConfigSnapshot   `json:"configSnapshot"`
}

type backupManifestMetadata struct {
	BackupTimestamp     string `json:"backupTimestamp"`
	BackupTool          string `json:"backupTool"`
	BackupToolVersion   string `json:"backupToolVersion"`
	BackupFormatVersion string `json:"backupFormatVersion"`
}

type backupManifestCluster struct {
	Name       string `json:"name"`
	K2sVersion string `json:"k2sVersion"`
}

type backupManifestContent struct {
	Included backupContentIncluded `json:"included"`
	Excluded backupContentExcluded `json:"excluded"`
}

type backupContentIncluded struct {
	ClusterResources bool     `json:"clusterResources"`
	Namespaces       []string `json:"namespaces"`
}

type backupContentExcluded struct {
	Namespaces          []string `json:"namespaces"`
	NamespacedResources []string `json:"namespacedResources"`
	ClusterResources    []string `json:"clusterResources"`
}

type backupConfigSnapshot struct {
	Source string `json:"source"`
}

type k8sPVList struct {
	Items []k8sPVItem `json:"items"`
}

type k8sPVItem struct {
	Metadata struct {
		Name string `json:"name"`
	} `json:"metadata"`
	Spec struct {
		Capacity struct {
			Storage string `json:"storage"`
		} `json:"capacity"`
		HostPath *struct {
			Path string `json:"path"`
		} `json:"hostPath"`
		Local *struct {
			Path string `json:"path"`
		} `json:"local"`
		ClaimRef *struct {
			Namespace string `json:"namespace"`
			Name      string `json:"name"`
		} `json:"claimRef"`
		PersistentVolumeReclaimPolicy string `json:"persistentVolumeReclaimPolicy"`
	} `json:"spec"`
	Status struct {
		Phase string `json:"phase"`
	} `json:"status"`
}

func runLinuxSystemBackup(installDir string, cfg SystemBackupConfig) error {
	slog.Info("[System Backup] Starting K2s system backup...")

	if cfg.BackupFile == "" {
		return fmt.Errorf("backup file path must not be empty")
	}

	absBackupFile, err := filepath.Abs(cfg.BackupFile)
	if err != nil {
		return fmt.Errorf("invalid backup file path '%s': %w", cfg.BackupFile, err)
	}

	targetDir := filepath.Dir(absBackupFile)
	if err := os.MkdirAll(targetDir, 0755); err != nil {
		return fmt.Errorf("failed to create backup directory '%s': %w", targetDir, err)
	}

	stagingDir, err := os.MkdirTemp(targetDir, "k2s-backup-staging-")
	if err != nil {
		return fmt.Errorf("failed to create temporary staging directory: %w", err)
	}
	defer func() {
		slog.Debug("[System Backup] Cleaning up staging directory", "dir", stagingDir)
		_ = os.RemoveAll(stagingDir)
	}()

	slog.Info("[System Backup] Using staging directory", "dir", stagingDir)

	// Step 1: Check cluster connectivity
	if err := checkClusterReachable(); err != nil {
		return err
	}

	// Step 2: Load configuration exclusions & cluster name
	backupCfg := loadBackupConfig(installDir)

	// Step 3: Export Namespaced and Cluster resources
	includedNamespaces, err := exportClusterResources(stagingDir, backupCfg)
	if err != nil {
		return fmt.Errorf("failed to export cluster resources: %w", err)
	}

	// Step 4: Backup Persistent Volumes
	if cfg.SkipPVs {
		slog.Info("[System Backup] Skipping PV backup as requested")
	} else {
		if err := backupPersistentVolumes(stagingDir, backupCfg); err != nil {
			return fmt.Errorf("failed to backup persistent volumes: %w", err)
		}
	}

	// Step 5: Backup Container Images
	if cfg.SkipImages {
		slog.Info("[System Backup] Skipping image backup as requested")
	} else {
		if err := backupContainerImages(stagingDir, includedNamespaces); err != nil {
			return fmt.Errorf("failed to backup container images: %w", err)
		}
	}

	// Step 6: Execute Backup Hooks
	executeBackupHooks(installDir, stagingDir, cfg.AdditionalHooksDir)

	// Step 7: Snapshot config.json
	snapshotConfig(installDir, stagingDir)

	// Step 8: Generate backup.json manifest
	if err := generateBackupManifest(stagingDir, backupCfg, includedNamespaces); err != nil {
		return fmt.Errorf("failed to generate backup.json manifest: %w", err)
	}

	// Step 9: Create final ZIP archive
	slog.Info("[System Backup] Creating backup archive", "path", absBackupFile)
	if err := createZipFromDirectory(stagingDir, absBackupFile); err != nil {
		return fmt.Errorf("failed to create backup archive '%s': %w", absBackupFile, err)
	}

	slog.Info("[System Backup] System backup completed successfully", "file", absBackupFile)
	return nil
}

func checkClusterReachable() error {
	slog.Info("[System Backup] Checking cluster status...")
	ctx, cancel := context.WithTimeout(context.Background(), clusterReachableTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "kubectl", "cluster-info", "--request-timeout=5s")
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("Kubernetes cluster is not reachable: %w: %s", err, string(out))
	}
	return nil
}

func loadBackupConfig(installDir string) *backupConfig {
	cfg := &backupConfig{
		ExcludedNamespaces: []string{
			"kube-flannel", "kube-node-lease", "kube-public", "kube-system",
			"k2s-webhook", "kubernetes-dashboard", "nginx-gw", "gpu-node",
			"ingress-nginx", "kubevirt", "monitoring", "registry", "dicom",
			"ingress-traefik", "logging", "security", "viewer", "storage-smb",
			"linkerd", "cert-manager", "dashboard", "autoscaling", "metrics", "rollout",
		},
		ExcludedNamespacedResources: []string{
			"endpoints", "endpointslices", "events",
		},
		ExcludedClusterResources: []string{
			"componentstatuses", "nodes", "csinodes", "ipaddresses",
			"certificatesigningrequests", "storageclasses", "servicecidrs",
			"apiservices", "flowschemas", "prioritylevelconfigurations",
			"ingressclasses", "runtimeclasses", "mutatingwebhookconfigurations",
		},
		ExcludedAddonPersistentVolumes: []string{
			"postgresql-pv-volume", "dicom-pv-volume", "orthanc-pv",
			"registry-pv", "smb-static-pv", "opensearch-cluster-master-pv",
		},
		ClusterName: "k2s-cluster",
	}

	configPath := filepath.Join(installDir, "cfg", "config.json")
	data, err := os.ReadFile(configPath)
	if err != nil {
		slog.Warn("[System Backup] Could not read config.json, using defaults", "path", configPath, "error", err)
		return cfg
	}

	var raw rawBackupConfigJSON
	if err := json.Unmarshal(data, &raw); err != nil {
		slog.Warn("[System Backup] Could not parse config.json, using defaults", "error", err)
		return cfg
	}

	if raw.ClusterName != "" {
		cfg.ClusterName = raw.ClusterName
	}

	b := raw.SmallSetup.Backup
	if b.ExcludedNamespaces == "" && raw.Backup.ExcludedNamespaces != "" {
		b = raw.Backup
	}

	if b.ExcludedNamespaces != "" {
		cfg.ExcludedNamespaces = splitAndTrim(b.ExcludedNamespaces)
	}
	if b.ExcludedNamespacedResources != "" {
		cfg.ExcludedNamespacedResources = splitAndTrim(b.ExcludedNamespacedResources)
	}
	if b.ExcludedClusterResources != "" {
		cfg.ExcludedClusterResources = splitAndTrim(b.ExcludedClusterResources)
	}
	if b.ExcludedAddonPersistentVolumes != "" {
		cfg.ExcludedAddonPersistentVolumes = splitAndTrim(b.ExcludedAddonPersistentVolumes)
	}

	return cfg
}

func splitAndTrim(s string) []string {
	parts := strings.Split(s, ",")
	var res []string
	for _, p := range parts {
		trimmed := strings.TrimSpace(p)
		if trimmed != "" {
			res = append(res, trimmed)
		}
	}
	return res
}

func containsString(slice []string, val string) bool {
	for _, item := range slice {
		if strings.EqualFold(item, val) {
			return true
		}
	}
	return false
}

func exportClusterResources(stagingDir string, bcfg *backupConfig) ([]string, error) {
	slog.Info("[System Backup] Exporting cluster resources...")

	// 1. Get all namespaces
	ctxNs, cancelNs := context.WithTimeout(context.Background(), defaultKubeTimeout)
	out, err := exec.CommandContext(ctxNs, "kubectl", "get", "namespaces", "-o", "jsonpath={.items[*].metadata.name}").CombinedOutput()
	cancelNs()
	if err != nil {
		return nil, fmt.Errorf("failed to list namespaces: %w: %s", err, string(out))
	}

	allNamespaces := strings.Fields(string(out))
	var includedNamespaces []string
	for _, ns := range allNamespaces {
		if !containsString(bcfg.ExcludedNamespaces, ns) {
			includedNamespaces = append(includedNamespaces, ns)
		}
	}

	// 2. Export Namespaced Resources
	ctxRes, cancelRes := context.WithTimeout(context.Background(), defaultKubeTimeout)
	namespacedResOut, err := exec.CommandContext(ctxRes, "kubectl", "api-resources", "--namespaced=true", "--verbs=list").CombinedOutput()
	cancelRes()
	if err != nil {
		slog.Warn("[System Backup] Failed to query namespaced api-resources", "error", err)
	} else {
		var namespacedTypes []string
		for _, line := range strings.Split(string(namespacedResOut), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 0 || fields[0] == "NAME" {
				continue
			}
			resName := fields[0]
			if !containsString(bcfg.ExcludedNamespacedResources, resName) && !containsString(namespacedTypes, resName) {
				namespacedTypes = append(namespacedTypes, resName)
			}
		}

		for _, ns := range includedNamespaces {
			nsDir := filepath.Join(stagingDir, "Namespaced", ns)
			if err := os.MkdirAll(nsDir, 0755); err != nil {
				return nil, err
			}

			for _, resType := range namespacedTypes {
				ctxGet, cancelGet := context.WithTimeout(context.Background(), defaultKubeTimeout)
				resJSON, err := exec.CommandContext(ctxGet, "kubectl", "get", resType, "-n", ns, "-o", "json").Output()
				cancelGet()
				if err != nil {
					continue
				}

				yamlBytes, hasItems, err := cleanAndConvertResourceJSON(resJSON)
				if err != nil || !hasItems {
					continue
				}

				outFile := filepath.Join(nsDir, resType+".yaml")
				if err := os.WriteFile(outFile, yamlBytes, 0644); err != nil {
					slog.Warn("[System Backup] Failed to write namespaced resource yaml", "file", outFile, "error", err)
				}
			}
		}
	}

	// 3. Export Cluster-scoped Resources
	ctxClusterRes, cancelClusterRes := context.WithTimeout(context.Background(), defaultKubeTimeout)
	clusterResOut, err := exec.CommandContext(ctxClusterRes, "kubectl", "api-resources", "--namespaced=false", "--verbs=list").CombinedOutput()
	cancelClusterRes()
	if err != nil {
		slog.Warn("[System Backup] Failed to query cluster-scoped api-resources", "error", err)
	} else {
		notNamespacedDir := filepath.Join(stagingDir, "NotNamespaced")
		_ = os.MkdirAll(notNamespacedDir, 0755)

		var clusterTypes []string
		for _, line := range strings.Split(string(clusterResOut), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 0 || fields[0] == "NAME" {
				continue
			}
			resName := fields[0]
			if !containsString(bcfg.ExcludedClusterResources, resName) && !containsString(clusterTypes, resName) {
				clusterTypes = append(clusterTypes, resName)
			}
		}

		for _, resType := range clusterTypes {
			ctxGet, cancelGet := context.WithTimeout(context.Background(), defaultKubeTimeout)
			resJSON, err := exec.CommandContext(ctxGet, "kubectl", "get", resType, "-o", "json").Output()
			cancelGet()
			if err != nil {
				continue
			}

			yamlBytes, hasItems, err := cleanAndConvertResourceJSON(resJSON)
			if err != nil || !hasItems {
				continue
			}

			outFile := filepath.Join(notNamespacedDir, resType+".yaml")
			if err := os.WriteFile(outFile, yamlBytes, 0644); err != nil {
				slog.Warn("[System Backup] Failed to write cluster resource yaml", "file", outFile, "error", err)
			}
		}
	}

	return includedNamespaces, nil
}

func cleanAndConvertResourceJSON(rawJSON []byte) ([]byte, bool, error) {
	var data map[string]any
	if err := json.Unmarshal(rawJSON, &data); err != nil {
		return nil, false, err
	}

	if items, ok := data["items"].([]any); ok && len(items) == 0 {
		return nil, false, nil
	}

	cleanResourceMap(data)

	yamlBytes, err := yaml.Marshal(data)
	if err != nil {
		return nil, false, err
	}
	return yamlBytes, true, nil
}

func cleanResourceMap(data map[string]any) {
	if items, ok := data["items"].([]any); ok {
		for _, item := range items {
			if itemMap, ok := item.(map[string]any); ok {
				cleanSingleResource(itemMap)
			}
		}
	} else {
		cleanSingleResource(data)
	}
	cleanMetadata(data)
}

func cleanSingleResource(m map[string]any) {
	delete(m, "status")
	cleanMetadata(m)
	if spec, ok := m["spec"].(map[string]any); ok {
		delete(spec, "finalizers")
		delete(spec, "claimRef")
	}
}

func cleanMetadata(m map[string]any) {
	if meta, ok := m["metadata"].(map[string]any); ok {
		delete(meta, "creationTimestamp")
		delete(meta, "resourceVersion")
		delete(meta, "uid")
		delete(meta, "selfLink")
		delete(meta, "generation")
		delete(meta, "managedFields")
		delete(meta, "ownerReferences")
		if annotations, ok := meta["annotations"].(map[string]any); ok {
			delete(annotations, "kubectl.kubernetes.io/last-applied-configuration")
			if len(annotations) == 0 {
				delete(meta, "annotations")
			}
		}
	}
}

func backupPersistentVolumes(stagingDir string, bcfg *backupConfig) error {
	slog.Info("[System Backup] Backing up persistent volumes...")
	pvDir := filepath.Join(stagingDir, "pv")

	ctx, cancel := context.WithTimeout(context.Background(), defaultKubeTimeout)
	defer cancel()

	out, err := exec.CommandContext(ctx, "kubectl", "get", "pv", "-o", "json").CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to query persistent volumes: %w: %s", err, string(out))
	}

	var pvList k8sPVList
	if err := json.Unmarshal(out, &pvList); err != nil {
		return fmt.Errorf("failed to parse pv list: %w", err)
	}

	if err := os.MkdirAll(pvDir, 0755); err != nil {
		return err
	}

	backedUpCount := 0
	var pvErrors []string
	for _, pv := range pvList.Items {
		pvName := pv.Metadata.Name
		if pvName == "" || containsString(bcfg.ExcludedAddonPersistentVolumes, pvName) {
			continue
		}

		var volumeType, volumePath string
		if pv.Spec.HostPath != nil && pv.Spec.HostPath.Path != "" {
			volumeType = "hostPath"
			volumePath = pv.Spec.HostPath.Path
		} else if pv.Spec.Local != nil && pv.Spec.Local.Path != "" {
			volumeType = "local"
			volumePath = pv.Spec.Local.Path
		} else {
			continue
		}

		stat, err := os.Stat(volumePath)
		if err != nil {
			slog.Warn("[System Backup] PV volume path not accessible", "pv", pvName, "path", volumePath, "error", err)
			pvErrors = append(pvErrors, fmt.Sprintf("%s (path '%s' not accessible: %v)", pvName, volumePath, err))
			continue
		}

		targetTarGz := filepath.Join(pvDir, pvName+"-backup.tar.gz")
		if stat.IsDir() {
			if err := tarGzDirectory(volumePath, targetTarGz); err != nil {
				_ = os.Remove(targetTarGz)
				slog.Warn("[System Backup] Failed to archive PV directory", "pv", pvName, "error", err)
				pvErrors = append(pvErrors, fmt.Sprintf("%s: %v", pvName, err))
				continue
			}
		} else {
			if err := tarGzSingleFile(volumePath, targetTarGz); err != nil {
				_ = os.Remove(targetTarGz)
				slog.Warn("[System Backup] Failed to archive PV file", "pv", pvName, "error", err)
				pvErrors = append(pvErrors, fmt.Sprintf("%s: %v", pvName, err))
				continue
			}
		}

		claimNs := ""
		claimName := ""
		if pv.Spec.ClaimRef != nil {
			claimNs = pv.Spec.ClaimRef.Namespace
			claimName = pv.Spec.ClaimRef.Name
		}

		metadata := map[string]any{
			"version":        "1.0",
			"backupType":     "persistent-volume",
			"pvName":         pvName,
			"volumeType":     volumeType,
			"volumePath":     volumePath,
			"capacity":       pv.Spec.Capacity.Storage,
			"createdAt":      time.Now().UTC().Format(time.RFC3339),
			"backupFile":     pvName + "-backup.tar.gz",
			"claimNamespace": claimNs,
			"claimName":      claimName,
			"reclaimPolicy":  pv.Spec.PersistentVolumeReclaimPolicy,
		}

		metaJSON, _ := json.MarshalIndent(metadata, "", "  ")
		_ = os.WriteFile(filepath.Join(pvDir, pvName+"-backup-metadata.json"), metaJSON, 0644)
		backedUpCount++
	}

	if len(pvErrors) > 0 {
		return fmt.Errorf("failed to backup %d persistent volume(s): %s (use --skip-pvs to exclude PVs from backup)", len(pvErrors), strings.Join(pvErrors, "; "))
	}

	slog.Info("[System Backup] Successfully backed up persistent volumes", "count", backedUpCount)
	return nil
}

func tarGzDirectory(srcDir, destTarGz string) error {
	out, err := os.Create(destTarGz)
	if err != nil {
		return err
	}
	gw := gzip.NewWriter(out)
	tw := tar.NewWriter(gw)

	var success bool
	defer func() {
		if !success {
			_ = tw.Close()
			_ = gw.Close()
			_ = out.Close()
			_ = os.Remove(destTarGz)
		}
	}()

	err = filepath.Walk(srcDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		relPath, err := filepath.Rel(srcDir, path)
		if err != nil {
			return err
		}
		if relPath == "." {
			return nil
		}

		header, err := tar.FileInfoHeader(info, info.Name())
		if err != nil {
			return err
		}
		header.Name = filepath.ToSlash(relPath)

		if info.IsDir() {
			header.Name += "/"
			return tw.WriteHeader(header)
		}

		if info.Mode()&os.ModeSymlink != 0 {
			linkTarget, err := os.Readlink(path)
			if err != nil {
				return err
			}
			header.Linkname = linkTarget
			return tw.WriteHeader(header)
		}

		if !info.Mode().IsRegular() {
			slog.Debug("[System Backup] Skipping non-regular file in PV directory", "path", path, "mode", info.Mode().String())
			return nil
		}

		if err := tw.WriteHeader(header); err != nil {
			return err
		}

		file, err := os.Open(path)
		if err != nil {
			return err
		}

		_, copyErr := io.Copy(tw, file)
		_ = file.Close()
		return copyErr
	})
	if err != nil {
		return err
	}

	if err := tw.Close(); err != nil {
		return fmt.Errorf("failed to close tar writer: %w", err)
	}
	if err := gw.Close(); err != nil {
		return fmt.Errorf("failed to close gzip writer: %w", err)
	}
	if err := out.Close(); err != nil {
		return fmt.Errorf("failed to close archive file '%s': %w", destTarGz, err)
	}
	success = true

	return nil
}

func tarGzSingleFile(srcFile, destTarGz string) error {
	out, err := os.Create(destTarGz)
	if err != nil {
		return err
	}
	gw := gzip.NewWriter(out)
	tw := tar.NewWriter(gw)

	var success bool
	defer func() {
		if !success {
			_ = tw.Close()
			_ = gw.Close()
			_ = out.Close()
			_ = os.Remove(destTarGz)
		}
	}()

	info, err := os.Stat(srcFile)
	if err != nil {
		return err
	}

	if !info.Mode().IsRegular() {
		return fmt.Errorf("source file '%s' is not a regular file (mode: %s)", srcFile, info.Mode().String())
	}

	header, err := tar.FileInfoHeader(info, info.Name())
	if err != nil {
		return err
	}
	header.Name = filepath.Base(srcFile)

	if err := tw.WriteHeader(header); err != nil {
		return err
	}

	file, err := os.Open(srcFile)
	if err != nil {
		return err
	}

	_, copyErr := io.Copy(tw, file)
	_ = file.Close()
	if copyErr != nil {
		return copyErr
	}

	if err := tw.Close(); err != nil {
		return fmt.Errorf("failed to close tar writer: %w", err)
	}
	if err := gw.Close(); err != nil {
		return fmt.Errorf("failed to close gzip writer: %w", err)
	}
	if err := out.Close(); err != nil {
		return fmt.Errorf("failed to close archive file '%s': %w", destTarGz, err)
	}
	success = true

	return nil
}

func backupContainerImages(stagingDir string, includedNamespaces []string) error {
	slog.Info("[System Backup] Backing up user workload images...")
	imagesDir := filepath.Join(stagingDir, "images")
	if err := os.MkdirAll(imagesDir, 0755); err != nil {
		return err
	}

	imageSet := make(map[string]struct{})
	queryFailures := 0
	for _, ns := range includedNamespaces {
		ctx, cancel := context.WithTimeout(context.Background(), defaultKubeTimeout)
		out, err := exec.CommandContext(ctx, "kubectl", "get", "pods", "-n", ns,
			"-o", "jsonpath={.items[*].spec.containers[*].image} {.items[*].spec.initContainers[*].image}").Output()
		cancel()
		if err != nil {
			queryFailures++
			slog.Warn("[System Backup] Failed to query pods for namespace", "namespace", ns, "error", err)
			continue
		}
		for _, img := range strings.Fields(string(out)) {
			img = strings.TrimSpace(img)
			if img != "" {
				imageSet[img] = struct{}{}
			}
		}
	}

	if len(includedNamespaces) > 0 && queryFailures == len(includedNamespaces) {
		return fmt.Errorf("failed to query pod images: all %d namespace queries failed", queryFailures)
	}

	backedUpCount := 0
	var exportErrors []string
	for img := range imageSet {
		sanitized := sanitizeImageName(img) + ".tar"
		targetTar := filepath.Join(imagesDir, sanitized)

		// Try ctr (containerd in k8s.io namespace) first
		ctxCtr, cancelCtr := context.WithTimeout(context.Background(), defaultImageExportTimeout)
		cmd := exec.CommandContext(ctxCtr, "ctr", "-n", "k8s.io", "images", "export", targetTar, img)
		errCtr := cmd.Run()
		cancelCtr()

		if errCtr != nil {
			_ = os.Remove(targetTar)
			// Fall back to nerdctl or docker
			ctxNerd, cancelNerd := context.WithTimeout(context.Background(), defaultImageExportTimeout)
			cmd2 := exec.CommandContext(ctxNerd, "nerdctl", "-n", "k8s.io", "save", "-o", targetTar, img)
			errNerd := cmd2.Run()
			cancelNerd()

			if errNerd != nil {
				_ = os.Remove(targetTar)
				ctxDoc, cancelDoc := context.WithTimeout(context.Background(), defaultImageExportTimeout)
				cmd3 := exec.CommandContext(ctxDoc, "docker", "save", "-o", targetTar, img)
				errDoc := cmd3.Run()
				cancelDoc()

				if errDoc != nil {
					_ = os.Remove(targetTar)
					slog.Warn("[System Backup] Failed to export image", "image", img, "error", errDoc)
					exportErrors = append(exportErrors, fmt.Sprintf("%s: %v", img, errDoc))
					continue
				}
			}
		}
		backedUpCount++
	}

	if len(exportErrors) > 0 {
		return fmt.Errorf("failed to export %d image(s): %s (use --skip-images to exclude images from backup)", len(exportErrors), strings.Join(exportErrors, "; "))
	}

	slog.Info("[System Backup] Successfully backed up user workload container images", "count", backedUpCount)
	return nil
}

func sanitizeImageName(image string) string {
	r := strings.NewReplacer("/", "_", ":", "_", "@", "_")
	return r.Replace(image)
}

func executeBackupHooks(installDir, stagingDir, additionalHooksDir string) {
	hooksDir := filepath.Join(stagingDir, "hooks")
	_ = os.MkdirAll(hooksDir, 0755)

	slog.Info("[System Backup] Executing backup hooks...")

	// Scan addon backup scripts
	addonsRoot := filepath.Join(installDir, "addons")
	_ = filepath.WalkDir(addonsRoot, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		name := d.Name()
		if name == "Backup.sh" || strings.HasSuffix(name, ".Backup.sh") {
			relPath, err := filepath.Rel(addonsRoot, path)
			if err == nil {
				parts := strings.Split(filepath.ToSlash(relPath), "/")
				if len(parts) > 1 {
					addonName := parts[len(parts)-2]
					if !isAddonDeployed(addonName) {
						slog.Debug("[System Backup] Skipping backup hook for disabled addon", "addon", addonName, "path", path)
						return nil
					}
				}
			}
			runBackupHook(path, hooksDir)
		}
		return nil
	})

	// Scan additional hooks directory
	if additionalHooksDir != "" {
		_ = filepath.WalkDir(additionalHooksDir, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			name := d.Name()
			if strings.HasSuffix(name, ".Backup.sh") || strings.HasSuffix(name, ".sh") {
				runBackupHook(path, hooksDir)
			}
			return nil
		})
	}
}

func runBackupHook(scriptPath, hooksDir string) {
	slog.Info("[System Backup] Running hook", "path", scriptPath)
	ctx, cancel := context.WithTimeout(context.Background(), defaultHookTimeout)
	defer cancel()

	cmd := bash.NewScript(scriptPath).
		WithContext(ctx).
		WithArgs("--backup-dir", hooksDir).
		WithStdOutWriter(slog.Debug).
		WithStdErrWriter(slog.Warn)
	if err := cmd.Exec(); err != nil {
		slog.Warn("[System Backup] Hook execution failed", "path", scriptPath, "error", err)
	}
}

func snapshotConfig(installDir, stagingDir string) {
	configDir := filepath.Join(stagingDir, "config")
	_ = os.MkdirAll(configDir, 0755)

	srcConfig := filepath.Join(installDir, "cfg", "config.json")
	data, err := os.ReadFile(srcConfig)
	if err != nil {
		slog.Warn("[System Backup] config.json not found", "path", srcConfig)
		return
	}

	destConfig := filepath.Join(configDir, "config.json")
	if err := os.WriteFile(destConfig, data, 0644); err != nil {
		slog.Warn("[System Backup] Failed to snapshot config.json", "error", err)
	}
}

func generateBackupManifest(stagingDir string, bcfg *backupConfig, includedNamespaces []string) error {
	slog.Info("[System Backup] Creating backup metadata (backup.json)...")

	v := version.GetVersion().Version
	if v == "" {
		v = "1.0.0"
	}

	manifest := backupManifest{
		APIVersion: "k2s.backup/v1",
		Kind:       "SystemBackup",
		Metadata: backupManifestMetadata{
			BackupTimestamp:     time.Now().UTC().Format(time.RFC3339),
			BackupTool:          "k2s system backup",
			BackupToolVersion:   v,
			BackupFormatVersion: "1",
		},
		Cluster: backupManifestCluster{
			Name:       bcfg.ClusterName,
			K2sVersion: v,
		},
		Content: backupManifestContent{
			Included: backupContentIncluded{
				ClusterResources: true,
				Namespaces:       includedNamespaces,
			},
			Excluded: backupContentExcluded{
				Namespaces:          bcfg.ExcludedNamespaces,
				NamespacedResources: bcfg.ExcludedNamespacedResources,
				ClusterResources:    bcfg.ExcludedClusterResources,
			},
		},
		ConfigSnapshot: backupConfigSnapshot{
			Source: "config/config.json",
		},
	}

	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}

	manifestPath := filepath.Join(stagingDir, "backup.json")
	return os.WriteFile(manifestPath, data, 0644)
}

func createZipFromDirectory(sourceDir, zipPath string) error {
	zipFile, err := os.OpenFile(zipPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("failed to create zip file '%s': %w", zipPath, err)
	}
	zipWriter := zip.NewWriter(zipFile)

	var success bool
	defer func() {
		if !success {
			_ = zipWriter.Close()
			_ = zipFile.Close()
			_ = os.Remove(zipPath)
		}
	}()

	err = filepath.Walk(sourceDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		relPath, err := filepath.Rel(sourceDir, path)
		if err != nil {
			return err
		}

		if relPath == "." {
			return nil
		}

		zipEntryName := filepath.ToSlash(relPath)

		header, err := zip.FileInfoHeader(info)
		if err != nil {
			return fmt.Errorf("failed to create zip header for '%s': %w", path, err)
		}

		header.Name = zipEntryName

		if info.IsDir() {
			header.Name += "/"
			header.Method = zip.Store
			_, err = zipWriter.CreateHeader(header)
			return err
		}

		if !info.Mode().IsRegular() {
			slog.Debug("[System Backup] Skipping non-regular file during zip archive creation", "path", path, "mode", info.Mode().String())
			return nil
		}

		header.Method = zip.Deflate

		writer, err := zipWriter.CreateHeader(header)
		if err != nil {
			return fmt.Errorf("failed to create zip entry '%s': %w", zipEntryName, err)
		}

		file, err := os.Open(path)
		if err != nil {
			return fmt.Errorf("failed to open file '%s': %w", path, err)
		}

		_, copyErr := io.Copy(writer, file)
		_ = file.Close()
		if copyErr != nil {
			return fmt.Errorf("failed to write file '%s' into zip: %w", path, copyErr)
		}

		return nil
	})
	if err != nil {
		return err
	}

	if err := zipWriter.Close(); err != nil {
		return fmt.Errorf("failed to close zip writer: %w", err)
	}
	if err := zipFile.Close(); err != nil {
		return fmt.Errorf("failed to close zip file '%s': %w", zipPath, err)
	}
	success = true

	return nil
}
