// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

//go:build linux

package provider

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	kos "github.com/k2s-project/k2s/internal/os"
)

var orderedClusterResourceTypes = []string{
	"customresourcedefinitions",
	"storageclasses",
	"priorityclasses",
	"namespaces",
	"clusterroles",
	"clusterrolebindings",
	"persistentvolumes",
	"mutatingwebhookconfigurations",
	"validatingwebhookconfigurations",
}

var orderedNamespacedResourceTypes = []string{
	"serviceaccounts",
	"secrets",
	"configmaps",
	"persistentvolumeclaims",
	"roles",
	"rolebindings",
	"services",
	"deployments",
	"statefulsets",
	"daemonsets",
	"jobs",
	"cronjobs",
	"pods",
	"ingresses",
}

type pvRestoreMetadata struct {
	Version        string `json:"version"`
	BackupType     string `json:"backupType"`
	PVName         string `json:"pvName"`
	VolumeType     string `json:"volumeType"`
	VolumePath     string `json:"volumePath"`
	Capacity       string `json:"capacity"`
	CreatedAt      string `json:"createdAt"`
	BackupFile     string `json:"backupFile"`
	ClaimNamespace string `json:"claimNamespace"`
	ClaimName      string `json:"claimName"`
	ReclaimPolicy  string `json:"reclaimPolicy"`
}

type imageRestoreManifest struct {
	Images []struct {
		ImageId    string `json:"ImageId"`
		Repository string `json:"Repository"`
		Tag        string `json:"Tag"`
		TarFile    string `json:"TarFile"`
		Node       string `json:"Node"`
	} `json:"Images"`
}

type k8sPodList struct {
	Items []struct {
		Metadata struct {
			Name      string `json:"name"`
			Namespace string `json:"namespace"`
		} `json:"metadata"`
		Spec struct {
			Volumes []struct {
				PersistentVolumeClaim *struct {
					ClaimName string `json:"claimName"`
				} `json:"persistentVolumeClaim"`
			} `json:"volumes"`
		} `json:"spec"`
	} `json:"items"`
}

func isK2sInstalled(installDir string) bool {
	if _, err := os.Stat("/etc/kubernetes/admin.conf"); err == nil {
		return true
	}
	if _, err := os.Stat(filepath.Join(installDir, "setup.json")); err == nil {
		return true
	}
	if _, err := os.Stat(filepath.Join(installDir, "cfg", "config.json")); err == nil {
		return true
	}
	return false
}

func isDangerousVolumePath(path string) bool {
	if !filepath.IsAbs(path) {
		return true
	}
	cleaned := filepath.Clean(path)
	if resolved, err := filepath.EvalSymlinks(cleaned); err == nil {
		cleaned = resolved
	}
	if cleaned == "/" {
		return true
	}
	dangerousRoots := []string{
		"/bin", "/sbin", "/usr", "/etc", "/lib", "/lib32", "/lib64",
		"/boot", "/dev", "/proc", "/sys", "/root", "/run",
		"/var/run", "/var/lib/kubelet", "/var/lib/etcd", "/var/lib/containerd", "/var/lib/docker",
	}
	for _, root := range dangerousRoots {
		if cleaned == root || strings.HasPrefix(cleaned, root+"/") {
			return true
		}
	}
	return false
}

func runLinuxSystemRestore(installDir string, cfg SystemRestoreConfig) error {
	slog.Info("[System Restore] Starting K2s system restore...")

	if cfg.BackupFile == "" {
		return fmt.Errorf("backup file path must not be empty")
	}

	absBackupFile, err := filepath.Abs(cfg.BackupFile)
	if err != nil {
		return fmt.Errorf("invalid backup file path '%s': %w", cfg.BackupFile, err)
	}

	if _, err := os.Stat(absBackupFile); err != nil {
		return fmt.Errorf("backup file '%s' not found: %w", absBackupFile, err)
	}

	// Step 1: Pre-flight checks
	if !isK2sInstalled(installDir) {
		return fmt.Errorf("K2s is not installed or Kubernetes configuration not found. Please run 'k2s install' first")
	}

	if err := checkClusterReachable(); err != nil {
		return fmt.Errorf("Kubernetes cluster is not running or reachable: %w", err)
	}

	// Step 2: Create staging directory & Extract backup
	stagingDir, err := os.MkdirTemp("/tmp", "k2s-restore-")
	if err != nil {
		stagingDir, err = os.MkdirTemp("", "k2s-restore-")
		if err != nil {
			return fmt.Errorf("failed to create temporary staging directory: %w", err)
		}
	}
	defer func() {
		slog.Debug("[System Restore] Cleaning up staging directory", "dir", stagingDir)
		_ = os.RemoveAll(stagingDir)
	}()

	slog.Info("[System Restore] Extracting backup file", "file", absBackupFile, "target", stagingDir)
	if err := kos.ExtractZip(absBackupFile, stagingDir); err != nil {
		return fmt.Errorf("failed to extract backup archive '%s': %w", absBackupFile, err)
	}

	// Step 3: Validate backup manifest
	manifest, err := validateBackupManifest(stagingDir)
	if err != nil {
		return err
	}
	slog.Info("[System Restore] Validated backup manifest", "version", manifest.APIVersion, "kind", manifest.Kind, "cluster", manifest.Cluster.Name)

	var allErrors []string

	// Step 4: Restore user workload container images
	if errs := restoreContainerImages(stagingDir); len(errs) > 0 {
		allErrors = append(allErrors, errs...)
		if cfg.ErrorOnFailure {
			return fmt.Errorf("image restore failed: %s", strings.Join(errs, "; "))
		}
	}

	// Step 5: Execute restore hooks
	executeRestoreHooks(installDir, stagingDir, cfg.AdditionalHooksDir)

	// Step 6: Restore persistent volumes
	if errs := restorePersistentVolumes(stagingDir); len(errs) > 0 {
		allErrors = append(allErrors, errs...)
		if cfg.ErrorOnFailure {
			return fmt.Errorf("persistent volume restore failed: %s", strings.Join(errs, "; "))
		}
	}

	// Step 7: Restore cluster-scoped resources
	if errs := restoreClusterResources(stagingDir); len(errs) > 0 {
		allErrors = append(allErrors, errs...)
		if cfg.ErrorOnFailure {
			return fmt.Errorf("cluster resource restore failed: %s", strings.Join(errs, "; "))
		}
	}

	// Step 8: Restore namespaced resources
	if errs := restoreNamespacedResources(stagingDir); len(errs) > 0 {
		allErrors = append(allErrors, errs...)
		if cfg.ErrorOnFailure {
			return fmt.Errorf("namespaced resource restore failed: %s", strings.Join(errs, "; "))
		}
	}

	// Step 9: Final error evaluation
	if len(allErrors) > 0 {
		msg := fmt.Sprintf("system restore finished with %d error(s): %s", len(allErrors), strings.Join(allErrors, "; "))
		if cfg.ErrorOnFailure {
			return errors.New(msg)
		}
		slog.Warn("[System Restore] " + msg)
	}

	slog.Info("[System Restore] System restore completed successfully")
	return nil
}

func validateBackupManifest(stagingDir string) (*backupManifest, error) {
	manifestPath := filepath.Join(stagingDir, "backup.json")
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return nil, fmt.Errorf("backup manifest (backup.json) not found in backup file. The backup may be incomplete or corrupted: %w", err)
	}

	var manifest backupManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, fmt.Errorf("failed to parse backup manifest (backup.json): %w", err)
	}

	if manifest.APIVersion != "k2s.backup/v1" {
		return nil, fmt.Errorf("unsupported backup apiVersion: %s", manifest.APIVersion)
	}

	if manifest.Kind != "SystemBackup" {
		return nil, fmt.Errorf("invalid backup kind: %s", manifest.Kind)
	}

	return &manifest, nil
}

func restoreContainerImages(stagingDir string) []string {
	imagesDir := filepath.Join(stagingDir, "images")
	stat, err := os.Stat(imagesDir)
	if err != nil || !stat.IsDir() {
		slog.Debug("[System Restore] No images directory found in backup, skipping image restore")
		return nil
	}

	slog.Info("[System Restore] Restoring container images...")

	tarSet := make(map[string]struct{})

	// Check for manifest.json
	manifestPath := filepath.Join(imagesDir, "manifest.json")
	if mData, err := os.ReadFile(manifestPath); err == nil {
		var imgManifest imageRestoreManifest
		if err := json.Unmarshal(mData, &imgManifest); err == nil {
			for _, item := range imgManifest.Images {
				if item.TarFile != "" {
					c := filepath.Join(imagesDir, filepath.Base(filepath.ToSlash(item.TarFile)))
					if _, err := os.Stat(c); err == nil {
						tarSet[c] = struct{}{}
					}
				}
			}
		}
	}

	// Scan images directory for .tar files
	entries, err := os.ReadDir(imagesDir)
	if err == nil {
		for _, entry := range entries {
			if !entry.IsDir() && strings.HasSuffix(strings.ToLower(entry.Name()), ".tar") {
				tarSet[filepath.Join(imagesDir, entry.Name())] = struct{}{}
			}
		}
	}

	if len(tarSet) == 0 {
		slog.Info("[System Restore] No container image archives found to restore")
		return nil
	}

	var errorsList []string
	restoredCount := 0

	tarPaths := make([]string, 0, len(tarSet))
	for tarPath := range tarSet {
		tarPaths = append(tarPaths, tarPath)
	}
	sort.Strings(tarPaths)

	for _, tarPath := range tarPaths {
		slog.Info("[System Restore] Importing container image archive", "tar", tarPath)
		if err := importSingleImage(tarPath); err != nil {
			errMsg := fmt.Sprintf("failed to import image archive '%s': %v", filepath.Base(tarPath), err)
			slog.Warn("[System Restore] " + errMsg)
			errorsList = append(errorsList, errMsg)
		} else {
			restoredCount++
		}
	}

	slog.Info("[System Restore] Image restore finished", "restored", restoredCount, "failed", len(errorsList))
	return errorsList
}

func importSingleImage(tarPath string) error {
	ctxCtr, cancelCtr := context.WithTimeout(context.Background(), defaultImageExportTimeout)
	cmdCtr := exec.CommandContext(ctxCtr, "ctr", "-n", "k8s.io", "images", "import", tarPath)
	outCtr, errCtr := cmdCtr.CombinedOutput()
	cancelCtr()
	if errCtr == nil {
		return nil
	}

	ctxNerd, cancelNerd := context.WithTimeout(context.Background(), defaultImageExportTimeout)
	cmdNerd := exec.CommandContext(ctxNerd, "nerdctl", "-n", "k8s.io", "load", "-i", tarPath)
	outNerd, errNerd := cmdNerd.CombinedOutput()
	cancelNerd()
	if errNerd == nil {
		return nil
	}

	ctxDoc, cancelDoc := context.WithTimeout(context.Background(), defaultImageExportTimeout)
	cmdDoc := exec.CommandContext(ctxDoc, "docker", "load", "-i", tarPath)
	outDoc, errDoc := cmdDoc.CombinedOutput()
	cancelDoc()
	if errDoc == nil {
		return nil
	}

	return fmt.Errorf("ctr import failed (%v: %s), nerdctl load failed (%v: %s), docker load failed (%v: %s)",
		errCtr, string(outCtr), errNerd, string(outNerd), errDoc, string(outDoc))
}

// Hooks are never executed from the backup archive itself; it only provides the data directory for them.
func executeRestoreHooks(installDir, stagingDir, additionalHooksDir string) {
	hooksDir := filepath.Join(stagingDir, "hooks")
	_ = os.MkdirAll(hooksDir, 0755)

	slog.Info("[System Restore] Executing restore hooks...")

	// Scan addon directory in installDir
	addonsRoot := filepath.Join(installDir, "addons")
	_ = filepath.WalkDir(addonsRoot, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		name := d.Name()
		if name == "Restore.sh" || strings.HasSuffix(name, ".Restore.sh") {
			relPath, err := filepath.Rel(addonsRoot, path)
			if err == nil {
				parts := strings.Split(filepath.ToSlash(relPath), "/")
				if len(parts) > 1 {
					addonName := parts[len(parts)-2]
					if !isAddonDeployed(addonName) {
						slog.Debug("[System Restore] Skipping restore hook for disabled addon", "addon", addonName, "path", path)
						return nil
					}
				}
			}
			runRestoreHook(path, hooksDir)
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
			if name == "Restore.sh" || strings.HasSuffix(name, ".Restore.sh") {
				runRestoreHook(path, hooksDir)
			}
			return nil
		})
	}
}

func runRestoreHook(scriptPath, hooksDir string) {
	slog.Info("[System Restore] Running hook", "path", scriptPath)
	ctx, cancel := context.WithTimeout(context.Background(), defaultHookTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "bash", scriptPath, "--backup-dir", hooksDir)
	if out, err := cmd.CombinedOutput(); err != nil {
		slog.Warn("[System Restore] Hook execution failed", "path", scriptPath, "error", err, "output", string(out))
	} else {
		slog.Debug("[System Restore] Hook output", "path", scriptPath, "output", string(out))
	}
}

func restorePersistentVolumes(stagingDir string) []string {
	pvDir := filepath.Join(stagingDir, "pv")
	stat, err := os.Stat(pvDir)
	if err != nil || !stat.IsDir() {
		slog.Debug("[System Restore] No PV directory found in backup, skipping PV restore")
		return nil
	}

	slog.Info("[System Restore] Restoring persistent volumes...")

	entries, err := os.ReadDir(pvDir)
	if err != nil {
		return []string{fmt.Sprintf("failed to read pv directory: %v", err)}
	}

	var errorsList []string
	restoredCount := 0

	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}

		metadataPath := filepath.Join(pvDir, entry.Name())
		data, err := os.ReadFile(metadataPath)
		if err != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to read PV metadata file '%s': %v", entry.Name(), err))
			continue
		}

		var meta pvRestoreMetadata
		if err := json.Unmarshal(data, &meta); err != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to parse PV metadata file '%s': %v", entry.Name(), err))
			continue
		}

		if isDangerousVolumePath(meta.VolumePath) {
			errMsg := fmt.Sprintf("PV '%s' has dangerous volume path target '%s' and was rejected", meta.PVName, meta.VolumePath)
			slog.Error("[System Restore] " + errMsg)
			errorsList = append(errorsList, errMsg)
			continue
		}

		tarGzPath := filepath.Join(pvDir, meta.BackupFile)
		if meta.BackupFile == "" || !fileExists(tarGzPath) {
			tarGzPath = filepath.Join(pvDir, meta.PVName+"-backup.tar.gz")
		}
		if !fileExists(tarGzPath) {
			tarGzPath = filepath.Join(pvDir, strings.TrimSuffix(entry.Name(), "-metadata.json")+".tar.gz")
		}
		if !fileExists(tarGzPath) {
			errMsg := fmt.Sprintf("backup tar.gz archive not found for PV '%s'", meta.PVName)
			slog.Warn("[System Restore] " + errMsg)
			errorsList = append(errorsList, errMsg)
			continue
		}

		slog.Info("[System Restore] Extracting persistent volume data", "pv", meta.PVName, "target", meta.VolumePath)
		if err := os.MkdirAll(meta.VolumePath, 0755); err != nil {
			errMsg := fmt.Sprintf("failed to create target directory '%s' for PV '%s': %v", meta.VolumePath, meta.PVName, err)
			slog.Warn("[System Restore] " + errMsg)
			errorsList = append(errorsList, errMsg)
			continue
		}

		if err := kos.ExtractTarGz(tarGzPath, meta.VolumePath); err != nil {
			errMsg := fmt.Sprintf("failed to extract PV archive '%s' to '%s': %v", tarGzPath, meta.VolumePath, err)
			slog.Warn("[System Restore] " + errMsg)
			errorsList = append(errorsList, errMsg)
			continue
		}

		restoredCount++

		// Restart consumer pods using this PVC
		if meta.ClaimNamespace != "" && meta.ClaimName != "" {
			restartPodsUsingPVC(meta.ClaimNamespace, meta.ClaimName)
		}
	}

	slog.Info("[System Restore] Persistent volume restore finished", "restored", restoredCount, "failed", len(errorsList))
	return errorsList
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func restartPodsUsingPVC(claimNamespace, claimName string) {
	slog.Info("[System Restore] Restarting pods using PVC...", "namespace", claimNamespace, "pvc", claimName)

	ctx, cancel := context.WithTimeout(context.Background(), defaultKubeTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "kubectl", "get", "pods", "-n", claimNamespace, "-o", "json")
	out, err := cmd.CombinedOutput()
	if err != nil {
		slog.Warn("[System Restore] Failed to list pods for PVC restart", "namespace", claimNamespace, "error", err, "output", string(out))
		return
	}

	var podList k8sPodList
	if err := json.Unmarshal(out, &podList); err != nil {
		slog.Warn("[System Restore] Failed to parse pod list for PVC restart", "namespace", claimNamespace, "error", err)
		return
	}

	for _, pod := range podList.Items {
		matches := false
		for _, vol := range pod.Spec.Volumes {
			if vol.PersistentVolumeClaim != nil && vol.PersistentVolumeClaim.ClaimName == claimName {
				matches = true
				break
			}
		}

		if matches {
			podName := pod.Metadata.Name
			podNs := pod.Metadata.Namespace
			slog.Info("[System Restore] Deleting consumer pod to trigger recreation", "namespace", podNs, "pod", podName)

			ctxDel, cancelDel := context.WithTimeout(context.Background(), defaultKubeTimeout)
			delCmd := exec.CommandContext(ctxDel, "kubectl", "delete", "pod", "-n", podNs, podName, "--wait=false")
			_ = delCmd.Run()
			cancelDel()

			ctxWait, cancelWait := context.WithTimeout(context.Background(), 60*time.Second)
			waitCmd := exec.CommandContext(ctxWait, "kubectl", "wait", "--for=condition=ready", "pod", "-n", podNs, podName, "--timeout=60s")
			_ = waitCmd.Run()
			cancelWait()
		}
	}
}

func restoreClusterResources(stagingDir string) []string {
	notNamespacedDir := filepath.Join(stagingDir, "NotNamespaced")
	stat, err := os.Stat(notNamespacedDir)
	if err != nil || !stat.IsDir() {
		slog.Debug("[System Restore] No NotNamespaced directory found in backup, skipping cluster-scoped resource restore")
		return nil
	}

	slog.Info("[System Restore] Restoring cluster-scoped resources...")

	applied := make(map[string]bool)
	var errorsList []string

	// 1. Apply ordered types
	for _, resType := range orderedClusterResourceTypes {
		file := filepath.Join(notNamespacedDir, resType+".yaml")
		if fileExists(file) {
			slog.Info("[System Restore] Applying cluster resource", "type", resType)
			if err := applyResourceYaml(file, ""); err != nil {
				errorsList = append(errorsList, err.Error())
			}
			applied[file] = true
		}
	}

	// 2. Apply remaining unordered YAML files
	entries, err := os.ReadDir(notNamespacedDir)
	if err == nil {
		for _, entry := range entries {
			if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".yaml") {
				continue
			}
			file := filepath.Join(notNamespacedDir, entry.Name())
			if !applied[file] {
				resName := strings.TrimSuffix(entry.Name(), ".yaml")
				slog.Info("[System Restore] Applying cluster resource", "type", resName)
				if err := applyResourceYaml(file, ""); err != nil {
					errorsList = append(errorsList, err.Error())
				}
			}
		}
	}

	return errorsList
}

func restoreNamespacedResources(stagingDir string) []string {
	namespacedDir := filepath.Join(stagingDir, "Namespaced")
	stat, err := os.Stat(namespacedDir)
	if err != nil || !stat.IsDir() {
		slog.Debug("[System Restore] No Namespaced directory found in backup, skipping namespaced resource restore")
		return nil
	}

	slog.Info("[System Restore] Restoring namespaced resources...")

	entries, err := os.ReadDir(namespacedDir)
	if err != nil {
		return []string{fmt.Sprintf("failed to read Namespaced directory: %v", err)}
	}

	var errorsList []string

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		ns := entry.Name()
		nsDir := filepath.Join(namespacedDir, ns)
		slog.Info("[System Restore] Restoring namespace", "namespace", ns)

		ensureNamespaceExists(ns)

		applied := make(map[string]bool)

		// 1. Apply ordered types within namespace
		for _, resType := range orderedNamespacedResourceTypes {
			file := filepath.Join(nsDir, resType+".yaml")
			if fileExists(file) {
				slog.Info("[System Restore] Applying namespaced resource", "namespace", ns, "type", resType)
				if err := applyResourceYaml(file, ns); err != nil {
					errorsList = append(errorsList, err.Error())
				}
				applied[file] = true
			}
		}

		// 2. Apply remaining unordered YAML files
		nsEntries, err := os.ReadDir(nsDir)
		if err == nil {
			for _, nsEntry := range nsEntries {
				if nsEntry.IsDir() || !strings.HasSuffix(nsEntry.Name(), ".yaml") {
					continue
				}
				file := filepath.Join(nsDir, nsEntry.Name())
				if !applied[file] {
					resName := strings.TrimSuffix(nsEntry.Name(), ".yaml")
					slog.Info("[System Restore] Applying namespaced resource", "namespace", ns, "type", resName)
					if err := applyResourceYaml(file, ns); err != nil {
						errorsList = append(errorsList, err.Error())
					}
				}
			}
		}
	}

	return errorsList
}

func ensureNamespaceExists(ns string) {
	ctx, cancel := context.WithTimeout(context.Background(), defaultKubeTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "kubectl", "get", "namespace", ns)
	if err := cmd.Run(); err != nil {
		slog.Info("[System Restore] Creating namespace", "namespace", ns)
		ctxCreate, cancelCreate := context.WithTimeout(context.Background(), defaultKubeTimeout)
		defer cancelCreate()
		if out, err := exec.CommandContext(ctxCreate, "kubectl", "create", "namespace", ns).CombinedOutput(); err != nil {
			slog.Warn("[System Restore] Failed to create namespace", "namespace", ns, "error", err, "output", string(out))
		}
	}
}

func applyResourceYaml(yamlFile, namespace string) error {
	args := []string{"apply", "--server-side", "--force-conflicts", "-f", yamlFile}
	if namespace != "" {
		args = append(args, "-n", namespace)
	}

	ctx, cancel := context.WithTimeout(context.Background(), defaultKubeTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "kubectl", args...)
	out, err := cmd.CombinedOutput()
	outStr := string(out)

	if err != nil || strings.Contains(outStr, "error:") || strings.Contains(outStr, "Error from server") {
		if strings.Contains(outStr, "Error from server (Invalid)") {
			slog.Warn("[System Restore] Warning: Some resources were invalid and skipped (will be recreated by addons)",
				"file", yamlFile, "output", outStr)
			return nil
		}
		return fmt.Errorf("failed to apply resource file '%s': %s", filepath.Base(yamlFile), strings.TrimSpace(outStr))
	}

	return nil
}
