// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/pterm/pterm"
	"gopkg.in/yaml.v3"

	kos "github.com/k2s-project/k2s/internal/os"
)

const (
	pvRestoreTempPrefix       = ".k2s-restore-"
	consumerStopTimeout       = 3 * time.Minute
	consumerRolloutTimeout    = 3 * time.Minute
	crdEstablishedTimeout     = 90 * time.Second
	trustedVolumeRootsEnvName = "K2S_RESTORE_PV_ROOTS"
)

var orderedClusterResourceTypes = []string{
	"customresourcedefinitions",
	"storageclasses",
	"priorityclasses",
	"namespaces",
	"clusterroles",
	"clusterrolebindings",
	"persistentvolumes",
}

// Admission webhooks are restored after all namespaced resources, because they are fail-closed and their backing
// services may not exist yet on a fresh cluster.
var deferredClusterResourceTypes = []string{
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

// restoreKubeconfig is the kubeconfig of the local K2s cluster that every restore kubectl command is bound to.
var restoreKubeconfig string

// trustedVolumeRoots are the host directories below which persistent volume data may be restored.
var trustedVolumeRoots = []string{"/mnt", "/srv", "/var/lib/k2s/volumes"}

var protectedVolumeRoots = []string{
	"/bin", "/sbin", "/usr", "/etc", "/lib", "/lib32", "/lib64",
	"/boot", "/dev", "/proc", "/sys", "/root", "/run", "/opt",
	"/var/run", "/var/lib/kubelet", "/var/lib/etcd", "/var/lib/containerd", "/var/lib/docker",
	"/var/spool", "/var/log",
}

type pvRestoreMetadata struct {
	Version            string `json:"version"`
	BackupType         string `json:"backupType"`
	PVName             string `json:"pvName"`
	VolumeType         string `json:"volumeType"`
	VolumePath         string `json:"volumePath"`
	VolumeKind         string `json:"volumeKind"`
	Capacity           string `json:"capacity"`
	CreatedAt          string `json:"createdAt"`
	BackupFile         string `json:"backupFile"`
	ClaimNamespace     string `json:"claimNamespace"`
	ClaimName          string `json:"claimName"`
	ReclaimPolicy      string `json:"reclaimPolicy"`
	VolumeRootMetadata bool   `json:"volumeRootMetadata"`
	VolumeRootMode     uint32 `json:"volumeRootMode"`
	VolumeRootUID      uint32 `json:"volumeRootUID"`
	VolumeRootGID      uint32 `json:"volumeRootGID"`
}

type imageRestoreManifestEntry struct {
	ImageId    string `json:"ImageId"`
	Repository string `json:"Repository"`
	Tag        string `json:"Tag"`
	TarFile    string `json:"TarFile"`
	Node       string `json:"Node"`
}

type imageRestoreManifest struct {
	Images []imageRestoreManifestEntry `json:"Images"`
}

type k8sOwnerReference struct {
	Kind       string `json:"kind"`
	Name       string `json:"name"`
	Controller bool   `json:"controller"`
}

type k8sPodList struct {
	Items []struct {
		Metadata struct {
			Name            string              `json:"name"`
			Namespace       string              `json:"namespace"`
			OwnerReferences []k8sOwnerReference `json:"ownerReferences"`
		} `json:"metadata"`
		Spec struct {
			Volumes []struct {
				PersistentVolumeClaim *struct {
					ClaimName string `json:"claimName"`
				} `json:"persistentVolumeClaim"`
			} `json:"volumes"`
		} `json:"spec"`
		Status struct {
			Phase string `json:"phase"`
		} `json:"status"`
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

// canonicalizePath resolves symlinks of the nearest existing ancestor and appends the missing suffix.
func canonicalizePath(p string) (string, error) {
	existing := filepath.Clean(p)
	var suffix []string
	for {
		_, err := os.Lstat(existing)
		if err == nil {
			break
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
		parent := filepath.Dir(existing)
		if parent == existing {
			return "", fmt.Errorf("no existing ancestor found for '%s'", p)
		}
		suffix = append([]string{filepath.Base(existing)}, suffix...)
		existing = parent
	}
	resolved, err := filepath.EvalSymlinks(existing)
	if err != nil {
		return "", err
	}
	return filepath.Join(append([]string{resolved}, suffix...)...), nil
}

func effectiveTrustedVolumeRoots() []string {
	roots := append([]string{}, trustedVolumeRoots...)
	for _, r := range strings.Split(os.Getenv(trustedVolumeRootsEnvName), ":") {
		if r = strings.TrimSpace(r); r != "" {
			roots = append(roots, r)
		}
	}
	return roots
}

func isWithin(p, root string) bool {
	return strings.HasPrefix(p, strings.TrimSuffix(root, "/")+"/")
}

// resolveVolumePath returns the canonical form of a PV destination after validating it. Only locations strictly inside
// a trusted storage root are accepted; protected system locations and their ancestors are always rejected.
func resolveVolumePath(volumePath string) (string, error) {
	if !filepath.IsAbs(volumePath) {
		return "", fmt.Errorf("volume path '%s' is not absolute", volumePath)
	}
	canonical, err := canonicalizePath(volumePath)
	if err != nil {
		return "", fmt.Errorf("volume path '%s' cannot be resolved: %w", volumePath, err)
	}
	if canonical == "/" {
		return "", fmt.Errorf("volume path '%s' resolves to the filesystem root", volumePath)
	}
	for _, root := range protectedVolumeRoots {
		if canonical == root || isWithin(canonical, root) || isWithin(root, canonical) {
			return "", fmt.Errorf("volume path '%s' resolves to '%s' which overlaps protected location '%s'", volumePath, canonical, root)
		}
	}
	for _, root := range effectiveTrustedVolumeRoots() {
		canonicalRoot := filepath.Clean(root)
		if resolved, err := canonicalizePath(canonicalRoot); err == nil {
			canonicalRoot = resolved
		}
		if isWithin(canonical, canonicalRoot) {
			return canonical, nil
		}
	}
	return "", fmt.Errorf("volume path '%s' is not located in a trusted storage root", volumePath)
}

func isDangerousVolumePath(volumePath string) bool {
	_, err := resolveVolumePath(volumePath)
	return err != nil
}

func isMountPoint(volumePath string) (bool, error) {
	mountInfo, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return false, err
	}
	canonical, err := canonicalizePath(volumePath)
	if err != nil {
		return false, err
	}
	for _, line := range strings.Split(string(mountInfo), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 5 {
			continue
		}
		mountPath := strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`).Replace(fields[4])
		if filepath.Clean(mountPath) == canonical {
			return true, nil
		}
	}
	return false, nil
}

func getLivePVClaim(pvName, fallbackNamespace, fallbackName string) (string, string, error) {
	out, err := runRestoreKubectl(defaultKubeTimeout, "get", "pv", pvName, "-o", "json")
	if err != nil {
		if strings.Contains(err.Error(), "NotFound") {
			return fallbackNamespace, fallbackName, nil
		}
		return "", "", err
	}
	var pv struct {
		Spec struct {
			ClaimRef *struct {
				Namespace string `json:"namespace"`
				Name      string `json:"name"`
			} `json:"claimRef"`
		} `json:"spec"`
	}
	if err := json.Unmarshal([]byte(out), &pv); err != nil {
		return "", "", err
	}
	if pv.Spec.ClaimRef == nil {
		return "", "", nil
	}
	return pv.Spec.ClaimRef.Namespace, pv.Spec.ClaimRef.Name, nil
}

func resolveVolumeKind(meta pvRestoreMetadata, stagingDir, targetPath string) (string, error) {
	if meta.VolumeKind != "" {
		if meta.VolumeKind != "file" && meta.VolumeKind != "directory" {
			return "", fmt.Errorf("unsupported volumeKind %q", meta.VolumeKind)
		}
		return meta.VolumeKind, nil
	}
	if info, err := os.Lstat(targetPath); err == nil {
		switch {
		case info.Mode().IsRegular():
			return "file", nil
		case info.IsDir():
			return "directory", nil
		default:
			return "", fmt.Errorf("existing destination is neither a regular file nor a directory")
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}

	pvFile := filepath.Join(stagingDir, "NotNamespaced", "persistentvolumes.yaml")
	data, err := os.ReadFile(pvFile)
	if err != nil {
		return "", fmt.Errorf("legacy backup has no volumeKind and PV definition is unavailable")
	}
	var list struct {
		Items []struct {
			Metadata struct {
				Name string `yaml:"name"`
			} `yaml:"metadata"`
			Spec struct {
				HostPath *struct {
					Type string `yaml:"type"`
				} `yaml:"hostPath"`
				Local *struct {
					Path string `yaml:"path"`
				} `yaml:"local"`
			} `yaml:"spec"`
		} `yaml:"items"`
	}
	if err := yaml.Unmarshal(data, &list); err != nil {
		return "", fmt.Errorf("failed to parse PV definitions: %w", err)
	}
	for _, pv := range list.Items {
		if pv.Metadata.Name != meta.PVName {
			continue
		}
		if pv.Spec.Local != nil {
			return "directory", nil
		}
		if pv.Spec.HostPath != nil {
			switch pv.Spec.HostPath.Type {
			case "File", "FileOrCreate":
				return "file", nil
			case "Directory", "DirectoryOrCreate":
				return "directory", nil
			}
		}
		return "", fmt.Errorf("legacy PV definition does not identify a file or directory volume")
	}
	return "", fmt.Errorf("legacy PV definition for %q was not found", meta.PVName)
}

// resolveInDir joins a name from untrusted input to dir and verifies the result stays beneath dir.
func resolveInDir(dir, name string) (string, bool) {
	name = strings.ReplaceAll(name, "\\", "/")
	if name == "" || path.IsAbs(name) {
		return "", false
	}
	cleaned := path.Clean(name)
	if cleaned == "." || cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return "", false
	}
	return filepath.Join(dir, filepath.FromSlash(cleaned)), true
}

// readJSONFile reads a JSON file and strips an optional UTF-8 byte-order mark (written by Windows PowerShell 5.1).
func readJSONFile(file string) ([]byte, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	return bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF}), nil
}

func restoreKubectlCmd(ctx context.Context, args ...string) *exec.Cmd {
	if restoreKubeconfig != "" {
		args = append([]string{"--kubeconfig", restoreKubeconfig}, args...)
	}
	return exec.CommandContext(ctx, "kubectl", args...)
}

// runRestoreKubectl returns the standard output of kubectl; standard error is part of the returned error.
var restoreKubectlRunner = func(timeout time.Duration, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	var stdout, stderr bytes.Buffer
	cmd := restoreKubectlCmd(ctx, args...)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return stdout.String(), fmt.Errorf("kubectl %s failed: %w: %s", args[0], err, strings.TrimSpace(stderr.String()+stdout.String()))
	}
	return stdout.String(), nil
}

func runRestoreKubectl(timeout time.Duration, args ...string) (string, error) {
	return restoreKubectlRunner(timeout, args...)
}

// selectLocalKubeconfig binds the restore to the kubeconfig of the local K2s cluster and verifies that it is reachable.
func selectLocalKubeconfig() error {
	if _, err := os.Stat(linuxAdminKubeconfig); err != nil {
		return fmt.Errorf("kubeconfig of the local K2s cluster '%s' not found: %w", linuxAdminKubeconfig, err)
	}
	restoreKubeconfig = linuxAdminKubeconfig

	ctx, cancel := context.WithTimeout(context.Background(), clusterReachableTimeout)
	defer cancel()
	if out, err := restoreKubectlCmd(ctx, "cluster-info", "--request-timeout=5s").CombinedOutput(); err != nil {
		return fmt.Errorf("local K2s cluster is not reachable using '%s': %w: %s", linuxAdminKubeconfig, err, string(out))
	}
	return nil
}

func runLinuxSystemRestore(installDir string, cfg SystemRestoreConfig) error {
	return runLinuxSystemRestoreWithProviderConfig(installDir, ProviderConfig{InstallDir: installDir}, cfg)
}

func runLinuxSystemRestoreWithProviderConfig(installDir string, providerCfg ProviderConfig, cfg SystemRestoreConfig) error {
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

	if err := selectLocalKubeconfig(); err != nil {
		return fmt.Errorf("Kubernetes cluster is not running or reachable: %w", err)
	}

	previousKubeconfig, hadKubeconfig := os.LookupEnv("KUBECONFIG")
	_ = os.Setenv("KUBECONFIG", restoreKubeconfig)
	defer func() {
		if hadKubeconfig {
			_ = os.Setenv("KUBECONFIG", previousKubeconfig)
		} else {
			_ = os.Unsetenv("KUBECONFIG")
		}
	}()

	// Step 2: Create staging directory & Extract backup
	stagingDir, err := os.MkdirTemp("", "k2s-restore-")
	if err != nil {
		return fmt.Errorf("failed to create temporary staging directory: %w", err)
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
	imageProvider := newLinuxImageProvider(providerCfg)
	importImage := func(tarPath string, windows bool) error {
		return imageProvider.Import(ImageImportConfig{TarPath: tarPath, Windows: windows, ShowOutput: cfg.ShowOutput})
	}
	if errs := restoreContainerImages(stagingDir, importImage); len(errs) > 0 {
		allErrors = append(allErrors, errs...)
		if cfg.ErrorOnFailure {
			return fmt.Errorf("image restore failed: %s", strings.Join(errs, "; "))
		}
	}

	// Step 5: Execute restore hooks
	if errs := executeRestoreHooks(installDir, stagingDir, cfg.AdditionalHooksDir); len(errs) > 0 {
		allErrors = append(allErrors, errs...)
		if cfg.ErrorOnFailure {
			return fmt.Errorf("restore hooks failed: %s", strings.Join(errs, "; "))
		}
	}

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

	// Step 8: Release stale volume bindings and restore namespaced resources
	if errs := releaseStalePVBindings(stagingDir); len(errs) > 0 {
		allErrors = append(allErrors, errs...)
		if cfg.ErrorOnFailure {
			return fmt.Errorf("persistent volume binding reconciliation failed: %s", strings.Join(errs, "; "))
		}
	}

	if errs := restoreNamespacedResources(stagingDir); len(errs) > 0 {
		allErrors = append(allErrors, errs...)
		if cfg.ErrorOnFailure {
			return fmt.Errorf("namespaced resource restore failed: %s", strings.Join(errs, "; "))
		}
	}

	// Step 9: Restore admission webhooks once their backing services exist
	if errs := restoreDeferredClusterResources(stagingDir); len(errs) > 0 {
		allErrors = append(allErrors, errs...)
		if cfg.ErrorOnFailure {
			return fmt.Errorf("webhook configuration restore failed: %s", strings.Join(errs, "; "))
		}
	}

	// Step 10: Final error evaluation
	if len(allErrors) > 0 {
		msg := fmt.Sprintf("system restore finished with %d error(s): %s", len(allErrors), strings.Join(allErrors, "; "))
		if cfg.ErrorOnFailure {
			return errors.New(msg)
		}
		slog.Warn("[System Restore] " + msg)
		pterm.Warning.Printfln("System restore completed WITH %d ERROR(S); parts of the backup were not restored:", len(allErrors))
		for _, e := range allErrors {
			pterm.Warning.Printfln("  - %s", e)
		}
		return nil
	}

	slog.Info("[System Restore] System restore completed successfully")
	pterm.Success.Println("System restore completed successfully")
	return nil
}

func validateBackupManifest(stagingDir string) (*backupManifest, error) {
	manifestPath := filepath.Join(stagingDir, "backup.json")
	data, err := readJSONFile(manifestPath)
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

func restoreContainerImages(stagingDir string, importImage func(tarPath string, windows bool) error) []string {
	imagesDir := filepath.Join(stagingDir, "images")
	stat, err := os.Stat(imagesDir)
	if err != nil || !stat.IsDir() {
		slog.Debug("[System Restore] No images directory found in backup, skipping image restore")
		return nil
	}

	slog.Info("[System Restore] Restoring container images...")

	var errorsList []string
	tarSet := make(map[string]bool)

	// Check for manifest.json
	manifestPath := filepath.Join(imagesDir, "manifest.json")
	if mData, err := readJSONFile(manifestPath); err == nil {
		var imgManifest imageRestoreManifest
		if err := json.Unmarshal(mData, &imgManifest); err != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to parse image manifest 'images/manifest.json': %v", err))
		} else {
			for _, item := range imgManifest.Images {
				if item.TarFile == "" {
					continue
				}
				if found, ok := findManifestImageArchive(stagingDir, imagesDir, item.TarFile); ok {
					tarSet[found] = tarSet[found] || isWindowsImageNode(item.Node)
				} else {
					errorsList = append(errorsList, fmt.Sprintf("image archive '%s' referenced in the image manifest was not found in the backup", item.TarFile))
				}
			}
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		errorsList = append(errorsList, fmt.Sprintf("failed to read image manifest 'images/manifest.json': %v", err))
	}

	// Scan images directory recursively for .tar files
	_ = filepath.WalkDir(imagesDir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to scan images directory: %v", err))
			return nil
		}
		if !d.IsDir() && d.Type().IsRegular() && strings.HasSuffix(strings.ToLower(d.Name()), ".tar") {
			if _, exists := tarSet[p]; !exists {
				tarSet[p] = false
			}
		}
		return nil
	})

	if len(tarSet) == 0 {
		slog.Info("[System Restore] No container image archives found to restore")
		return errorsList
	}

	restoredCount := 0

	tarPaths := make([]string, 0, len(tarSet))
	for tarPath := range tarSet {
		tarPaths = append(tarPaths, tarPath)
	}
	sort.Strings(tarPaths)

	failedCount := 0
	for _, tarPath := range tarPaths {
		slog.Info("[System Restore] Importing container image archive", "tar", tarPath)
		if err := importImage(tarPath, tarSet[tarPath]); err != nil {
			errMsg := fmt.Sprintf("failed to import image archive '%s': %v", filepath.Base(tarPath), err)
			slog.Warn("[System Restore] " + errMsg)
			errorsList = append(errorsList, errMsg)
			failedCount++
		} else {
			restoredCount++
		}
	}

	slog.Info("[System Restore] Image restore finished", "restored", restoredCount, "failed", failedCount)
	return errorsList
}

func isWindowsImageNode(node string) bool {
	return node != "" && !strings.EqualFold(node, "kubemaster")
}

// findManifestImageArchive resolves an archive path of the image manifest (which may use Windows separators and is
// relative to the backup root) and verifies that it stays beneath imagesDir.
func findManifestImageArchive(stagingDir, imagesDir, tarFile string) (string, bool) {
	for _, base := range []string{stagingDir, imagesDir} {
		candidate, ok := resolveInDir(base, tarFile)
		if !ok || !isWithin(candidate, imagesDir) {
			continue
		}
		if fileExists(candidate) {
			return candidate, true
		}
	}
	return "", false
}

// Hooks are never executed from the backup archive itself; it only provides the data directory for them.
func executeRestoreHooks(installDir, stagingDir, additionalHooksDir string) []string {
	hooksDir := filepath.Join(stagingDir, "hooks")
	if err := os.MkdirAll(hooksDir, 0755); err != nil {
		return []string{fmt.Sprintf("failed to create hooks data directory: %v", err)}
	}

	slog.Info("[System Restore] Executing restore hooks...")

	var errorsList []string
	isHook := func(name string) bool {
		return name == "Restore.sh" || strings.HasSuffix(name, ".Restore.sh")
	}

	// Scan addon directory in installDir
	addonsRoot := filepath.Join(installDir, "addons")
	if _, err := os.Stat(addonsRoot); err == nil {
		_ = filepath.WalkDir(addonsRoot, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				errorsList = append(errorsList, fmt.Sprintf("failed to discover restore hooks in '%s': %v", p, err))
				return nil
			}
			if d.IsDir() || !isHook(d.Name()) {
				return nil
			}
			relPath, err := filepath.Rel(addonsRoot, p)
			if err == nil {
				parts := strings.Split(filepath.ToSlash(relPath), "/")
				if len(parts) > 1 {
					addonName := parts[len(parts)-2]
					if !isAddonDeployed(addonName) {
						slog.Debug("[System Restore] Skipping restore hook for disabled addon", "addon", addonName, "path", p)
						return nil
					}
				}
			}
			if err := runRestoreHook(p, hooksDir); err != nil {
				errorsList = append(errorsList, err.Error())
			}
			return nil
		})
	}

	// Scan additional hooks directory
	if additionalHooksDir != "" {
		walkErr := filepath.WalkDir(additionalHooksDir, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				errorsList = append(errorsList, fmt.Sprintf("failed to discover restore hooks in '%s': %v", p, err))
				return nil
			}
			if d.IsDir() || !isHook(d.Name()) {
				return nil
			}
			if err := runRestoreHook(p, hooksDir); err != nil {
				errorsList = append(errorsList, err.Error())
			}
			return nil
		})
		if walkErr != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to discover restore hooks in '%s': %v", additionalHooksDir, walkErr))
		}
	}

	return errorsList
}

func runRestoreHook(scriptPath, hooksDir string) error {
	slog.Info("[System Restore] Running hook", "path", scriptPath)
	ctx, cancel := context.WithTimeout(context.Background(), defaultHookTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "bash", scriptPath, "--backup-dir", hooksDir)
	out, err := cmd.CombinedOutput()
	if err != nil {
		slog.Warn("[System Restore] Hook execution failed", "path", scriptPath, "error", err, "output", string(out))
		return fmt.Errorf("restore hook '%s' failed: %w", scriptPath, err)
	}
	slog.Debug("[System Restore] Hook output", "path", scriptPath, "output", string(out))
	return nil
}

func restorePersistentVolumes(stagingDir string) (errorsList []string) {
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

	restoredCount := 0
	var quiescedConsumers []*consumerQuiesce
	defer func() {
		for i := len(quiescedConsumers) - 1; i >= 0; i-- {
			errorsList = append(errorsList, quiescedConsumers[i].resume()...)
		}
	}()

	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}

		metadataPath := filepath.Join(pvDir, entry.Name())
		data, err := readJSONFile(metadataPath)
		if err != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to read PV metadata file '%s': %v", entry.Name(), err))
			continue
		}

		var meta pvRestoreMetadata
		if err := json.Unmarshal(data, &meta); err != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to parse PV metadata file '%s': %v", entry.Name(), err))
			continue
		}

		targetPath, err := resolveVolumePath(meta.VolumePath)
		if err != nil {
			errMsg := fmt.Sprintf("PV '%s' has dangerous volume path target '%s' and was rejected: %v", meta.PVName, meta.VolumePath, err)
			slog.Error("[System Restore] " + errMsg)
			errorsList = append(errorsList, errMsg)
			continue
		}
		mountPoint, err := isMountPoint(targetPath)
		if err != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to inspect PV destination '%s': %v", targetPath, err))
			continue
		}
		if mountPoint {
			errorsList = append(errorsList, fmt.Sprintf("PV '%s' destination '%s' is a mount point and cannot be safely replaced", meta.PVName, targetPath))
			continue
		}

		tarGzPath := ""
		candidates := []string{meta.BackupFile, meta.PVName + "-backup.tar.gz", strings.TrimSuffix(entry.Name(), "-metadata.json") + ".tar.gz"}
		for _, candidate := range candidates {
			if resolved, ok := resolveInDir(pvDir, candidate); ok && fileExists(resolved) {
				tarGzPath = resolved
				break
			}
		}
		if tarGzPath == "" {
			errMsg := fmt.Sprintf("backup tar.gz archive not found for PV '%s'", meta.PVName)
			slog.Warn("[System Restore] " + errMsg)
			errorsList = append(errorsList, errMsg)
			continue
		}

		volumeKind, kindErr := resolveVolumeKind(meta, stagingDir, targetPath)
		if kindErr != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to determine volume type for PV '%s': %v", meta.PVName, kindErr))
			continue
		}
		claimNamespace, claimName, err := getLivePVClaim(meta.PVName, meta.ClaimNamespace, meta.ClaimName)
		if err != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to inspect live claim binding for PV '%s': %v", meta.PVName, err))
			continue
		}
		var quiesced *consumerQuiesce
		if claimNamespace != "" && claimName != "" {
			var qErr error
			quiesced, qErr = quiescePVCConsumers(claimNamespace, claimName)
			quiescedConsumers = append(quiescedConsumers, quiesced)
			if qErr != nil {
				errMsg := fmt.Sprintf("failed to stop consumers of PVC '%s/%s' for PV '%s': %v", claimNamespace, claimName, meta.PVName, qErr)
				slog.Warn("[System Restore] " + errMsg)
				errorsList = append(errorsList, errMsg)
				continue
			}
		}

		slog.Info("[System Restore] Extracting persistent volume data", "pv", meta.PVName, "target", targetPath)
		installErr := installVolumeData(tarGzPath, targetPath, volumeKind, meta)
		if installErr != nil {
			errMsg := fmt.Sprintf("failed to restore PV archive '%s' to '%s': %v", tarGzPath, targetPath, installErr)
			slog.Warn("[System Restore] " + errMsg)
			errorsList = append(errorsList, errMsg)
		} else {
			restoredCount++
		}

	}

	slog.Info("[System Restore] Persistent volume restore finished", "restored", restoredCount, "failed", len(errorsList))
	return errorsList
}

// installVolumeData extracts the archive into a clean sibling location and then swaps it with the current volume
// data. The previous data is kept until the swap succeeded and is moved back if it fails.
func installVolumeData(tarGzPath, targetPath, volumeKind string, meta pvRestoreMetadata) error {
	parent := filepath.Dir(targetPath)
	if err := os.MkdirAll(parent, 0755); err != nil {
		return fmt.Errorf("failed to create parent directory '%s': %w", parent, err)
	}

	oldInfo, oldErr := os.Lstat(targetPath)
	oldExists := oldErr == nil
	if oldErr != nil && !errors.Is(oldErr, fs.ErrNotExist) {
		return fmt.Errorf("failed to inspect '%s': %w", targetPath, oldErr)
	}

	isFile := volumeKind == "file"

	stageDir, err := os.MkdirTemp(parent, pvRestoreTempPrefix)
	if err != nil {
		return fmt.Errorf("failed to create staging directory beneath '%s': %w", parent, err)
	}
	preserveStage := false
	defer func() {
		if !preserveStage {
			_ = os.RemoveAll(stageDir)
		}
	}()

	extractDir := filepath.Join(stageDir, "data")
	if err := kos.ExtractTarGz(tarGzPath, extractDir); err != nil {
		return err
	}

	newData := extractDir
	if isFile {
		entries, err := os.ReadDir(extractDir)
		if err != nil {
			return err
		}
		if len(entries) != 1 || !entries[0].Type().IsRegular() {
			return fmt.Errorf("archive of file volume must contain exactly one regular file")
		}
		newData = filepath.Join(extractDir, entries[0].Name())
	} else {
		rootInfo, err := os.Lstat(extractDir)
		if err != nil {
			return err
		}
		rootMetadata := volumeRootMetadataFromInfo(rootInfo)
		if meta.VolumeRootMetadata {
			rootMetadata = volumeRootMetadata{
				mode: meta.VolumeRootMode,
				uid:  meta.VolumeRootUID,
				gid:  meta.VolumeRootGID,
			}
		} else if oldExists && oldInfo.IsDir() {
			rootMetadata = volumeRootMetadataFromInfo(oldInfo)
		}
		if err := os.Chmod(extractDir, 0700); err != nil {
			return fmt.Errorf("failed to make staged volume root accessible: %w", err)
		}
		if err := applyVolumeRootMetadata(extractDir, rootMetadata); err != nil {
			return err
		}
	}

	previous := filepath.Join(stageDir, "previous")
	if oldExists {
		if err := os.Rename(targetPath, previous); err != nil {
			return fmt.Errorf("failed to move existing volume data aside (the volume path must not be a mount point): %w", err)
		}
	}
	if err := os.Rename(newData, targetPath); err != nil {
		if oldExists {
			if rbErr := os.Rename(previous, targetPath); rbErr != nil {
				preserveStage = true
				return fmt.Errorf("failed to install restored data: %v; ROLLBACK FAILED, previous data is kept in '%s': %w", err, previous, rbErr)
			}
		}
		return fmt.Errorf("failed to install restored data: %w", err)
	}
	return nil
}

type volumeRootMetadata struct {
	mode uint32
	uid  uint32
	gid  uint32
}

func volumeRootMetadataFromInfo(info os.FileInfo) volumeRootMetadata {
	meta := volumeRootMetadata{mode: unixFileMode(info.Mode())}
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		meta.uid, meta.gid = st.Uid, st.Gid
	}
	return meta
}

func applyVolumeRootMetadata(dir string, meta volumeRootMetadata) error {
	if os.Geteuid() == 0 {
		if err := os.Chown(dir, int(meta.uid), int(meta.gid)); err != nil {
			return fmt.Errorf("failed to restore ownership of '%s': %w", dir, err)
		}
	}
	if err := os.Chmod(dir, fileModeFromUnix(meta.mode)); err != nil {
		return fmt.Errorf("failed to restore permissions of '%s': %w", dir, err)
	}
	return nil
}

func fileModeFromUnix(raw uint32) os.FileMode {
	mode := os.FileMode(raw & 0777)
	if raw&04000 != 0 {
		mode |= os.ModeSetuid
	}
	if raw&02000 != 0 {
		mode |= os.ModeSetgid
	}
	if raw&01000 != 0 {
		mode |= os.ModeSticky
	}
	return mode
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

type quiescedWorkload struct {
	kind         string
	name         string
	replicas     int
	wasSuspended bool
}

// consumerQuiesce remembers what was stopped so that it can be resumed after the volume data was replaced.
type consumerQuiesce struct {
	namespace string
	workloads []quiescedWorkload
}

type consumerPod struct {
	name  string
	owner *k8sOwnerReference
}

func listPVCConsumerPods(namespace, claimName string) ([]consumerPod, error) {
	out, err := runRestoreKubectl(defaultKubeTimeout, "get", "pods", "-n", namespace, "-o", "json")
	if err != nil {
		return nil, err
	}

	var podList k8sPodList
	if err := json.Unmarshal([]byte(out), &podList); err != nil {
		return nil, fmt.Errorf("failed to parse pod list: %w", err)
	}

	var pods []consumerPod
	for _, pod := range podList.Items {
		if pod.Status.Phase == "Succeeded" || pod.Status.Phase == "Failed" {
			continue
		}
		for _, vol := range pod.Spec.Volumes {
			if vol.PersistentVolumeClaim == nil || vol.PersistentVolumeClaim.ClaimName != claimName {
				continue
			}
			cp := consumerPod{name: pod.Metadata.Name}
			for i := range pod.Metadata.OwnerReferences {
				if pod.Metadata.OwnerReferences[i].Controller {
					cp.owner = &pod.Metadata.OwnerReferences[i]
					break
				}
			}
			pods = append(pods, cp)
			break
		}
	}
	return pods, nil
}

// resolveTopLevelWorkload maps the controller of a pod to the workload that has to be scaled down or suspended.
func resolveTopLevelWorkload(namespace string, owner k8sOwnerReference) (kind, name string, err error) {
	switch owner.Kind {
	case "Deployment", "StatefulSet", "Job":
		return strings.ToLower(owner.Kind), owner.Name, nil
	case "ReplicaSet":
		out, err := runRestoreKubectl(defaultKubeTimeout, "get", "replicaset", owner.Name, "-n", namespace, "-o", "json")
		if err != nil {
			return "", "", err
		}
		var rs struct {
			Metadata struct {
				OwnerReferences []k8sOwnerReference `json:"ownerReferences"`
			} `json:"metadata"`
		}
		if err := json.Unmarshal([]byte(out), &rs); err != nil {
			return "", "", err
		}
		for _, ref := range rs.Metadata.OwnerReferences {
			if ref.Controller && ref.Kind == "Deployment" {
				return "deployment", ref.Name, nil
			}
		}
		return "replicaset", owner.Name, nil
	default:
		return "", "", fmt.Errorf("consumer controlled by %s '%s' cannot be stopped safely", owner.Kind, owner.Name)
	}
}

// quiescePVCConsumers stops all pods using the claim, prevents their controllers from recreating them and waits until
// they are gone. The returned state must always be resumed, even when an error is returned.
func quiescePVCConsumers(namespace, claimName string) (*consumerQuiesce, error) {
	q := &consumerQuiesce{namespace: namespace}

	pods, err := listPVCConsumerPods(namespace, claimName)
	if err != nil {
		return q, err
	}
	if len(pods) == 0 {
		return q, nil
	}

	for _, pod := range pods {
		if pod.owner == nil {
			return q, fmt.Errorf("standalone pod '%s' uses PVC '%s/%s'; refusing to delete a pod that cannot be recreated safely", pod.name, namespace, claimName)
		}
	}

	seen := make(map[string]bool)
	for _, pod := range pods {
		kind, name, err := resolveTopLevelWorkload(namespace, *pod.owner)
		if err != nil {
			return q, err
		}
		key := kind + "/" + name
		if seen[key] {
			continue
		}
		seen[key] = true

		w := quiescedWorkload{kind: kind, name: name}
		if kind == "job" {
			out, err := runRestoreKubectl(defaultKubeTimeout, "get", "job", name, "-n", namespace, "-o", "jsonpath={.spec.suspend}")
			if err != nil {
				return q, err
			}
			w.wasSuspended = strings.TrimSpace(out) == "true"
			slog.Info("[System Restore] Suspending job using PVC", "namespace", namespace, "job", name)
			if _, err := runRestoreKubectl(defaultKubeTimeout, "patch", "job", name, "-n", namespace, "--type=merge", "-p", `{"spec":{"suspend":true}}`); err != nil {
				return q, err
			}
			q.workloads = append(q.workloads, w)
			continue
		}

		if kind == "statefulset" {
			retention, err := runRestoreKubectl(defaultKubeTimeout, "get", "statefulset", name, "-n", namespace, "-o", "jsonpath={.spec.persistentVolumeClaimRetentionPolicy.whenScaled}")
			if err != nil {
				return q, err
			}
			if strings.EqualFold(strings.TrimSpace(retention), "Delete") {
				return q, fmt.Errorf("StatefulSet '%s/%s' deletes PVCs when scaled down; refusing to risk deleting PV data", namespace, name)
			}
		}

		out, err := runRestoreKubectl(defaultKubeTimeout, "get", kind, name, "-n", namespace, "-o", "jsonpath={.spec.replicas}")
		if err != nil {
			return q, err
		}
		w.replicas = 1
		if trimmed := strings.TrimSpace(out); trimmed != "" {
			if n, convErr := strconv.Atoi(trimmed); convErr == nil {
				w.replicas = n
			}
		}
		slog.Info("[System Restore] Scaling down workload using PVC", "namespace", namespace, "workload", key)
		q.workloads = append(q.workloads, w)
		if _, err := runRestoreKubectl(defaultKubeTimeout, "scale", kind, name, "-n", namespace, "--replicas=0"); err != nil {
			return q, err
		}
	}

	deadline := time.Now().Add(consumerStopTimeout)
	for {
		remaining, err := listPVCConsumerPods(namespace, claimName)
		if err != nil {
			return q, err
		}
		if len(remaining) == 0 {
			return q, nil
		}
		if time.Now().After(deadline) {
			return q, fmt.Errorf("timed out waiting for %d consumer pod(s) of PVC '%s/%s' to stop", len(remaining), namespace, claimName)
		}
		time.Sleep(2 * time.Second)
	}
}

// resume restarts what was stopped and waits for readiness; failures are returned instead of being swallowed.
func (q *consumerQuiesce) resume() []string {
	if q == nil {
		return nil
	}
	var errorsList []string
	for _, w := range q.workloads {
		ref := w.kind + "/" + w.name
		if w.kind == "job" {
			if w.wasSuspended {
				continue
			}
			if _, err := runRestoreKubectl(defaultKubeTimeout, "patch", "job", w.name, "-n", q.namespace, "--type=merge", "-p", `{"spec":{"suspend":false}}`); err != nil {
				errorsList = append(errorsList, fmt.Sprintf("failed to resume %s in namespace '%s': %v", ref, q.namespace, err))
			}
			continue
		}

		slog.Info("[System Restore] Scaling workload back up", "namespace", q.namespace, "workload", ref, "replicas", w.replicas)
		if _, err := runRestoreKubectl(defaultKubeTimeout, "scale", w.kind, w.name, "-n", q.namespace, fmt.Sprintf("--replicas=%d", w.replicas)); err != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to scale %s in namespace '%s' back to %d replicas: %v", ref, q.namespace, w.replicas, err))
			continue
		}
		if w.kind == "deployment" || w.kind == "statefulset" {
			timeout := fmt.Sprintf("--timeout=%ds", int(consumerRolloutTimeout.Seconds()))
			if _, err := runRestoreKubectl(consumerRolloutTimeout+30*time.Second, "rollout", "status", ref, "-n", q.namespace, timeout); err != nil {
				errorsList = append(errorsList, fmt.Sprintf("%s in namespace '%s' did not become ready after restore: %v", ref, q.namespace, err))
			}
		}
	}
	return errorsList
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
	for _, resType := range deferredClusterResourceTypes {
		applied[filepath.Join(notNamespacedDir, resType+".yaml")] = true
	}
	var errorsList []string

	// 1. Apply ordered types
	for _, resType := range orderedClusterResourceTypes {
		file := filepath.Join(notNamespacedDir, resType+".yaml")
		if fileExists(file) {
			slog.Info("[System Restore] Applying cluster resource", "type", resType)
			if err := applyResourceYaml(file, ""); err != nil {
				errorsList = append(errorsList, err.Error())
			} else if resType == "customresourcedefinitions" {
				if err := waitForCRDsEstablished(file); err != nil {
					errorsList = append(errorsList, err.Error())
				}
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

func restoreDeferredClusterResources(stagingDir string) []string {
	var errorsList []string
	for _, resType := range deferredClusterResourceTypes {
		file := filepath.Join(stagingDir, "NotNamespaced", resType+".yaml")
		if fileExists(file) {
			slog.Info("[System Restore] Applying cluster resource", "type", resType)
			if err := applyResourceYaml(file, ""); err != nil {
				errorsList = append(errorsList, err.Error())
			}
		}
	}
	return errorsList
}

// waitForCRDsEstablished waits until the API server serves the applied CRDs, so that custom resources can be applied.
func waitForCRDsEstablished(crdFile string) error {
	slog.Info("[System Restore] Waiting for restored CustomResourceDefinitions to be established")
	if _, err := runRestoreKubectl(crdEstablishedTimeout+30*time.Second, "wait", "--for=condition=Established",
		fmt.Sprintf("--timeout=%ds", int(crdEstablishedTimeout.Seconds())), "-f", crdFile); err != nil {
		return fmt.Errorf("restored CustomResourceDefinitions did not become established: %w", err)
	}
	return nil
}

// releaseStalePVBindings clears the claimRef of restored PVs whose claim no longer exists (or was replaced by a claim
// with another UID), so that the restored PVC can bind to them. PVs used by valid claims are left untouched.
func releaseStalePVBindings(stagingDir string) []string {
	pvFile := filepath.Join(stagingDir, "NotNamespaced", "persistentvolumes.yaml")
	data, err := os.ReadFile(pvFile)
	if err != nil {
		return nil
	}

	var pvList struct {
		Items []struct {
			Metadata struct {
				Name string `yaml:"name"`
			} `yaml:"metadata"`
		} `yaml:"items"`
	}
	if err := yaml.Unmarshal(data, &pvList); err != nil {
		return []string{fmt.Sprintf("failed to parse persistentvolumes.yaml: %v", err)}
	}

	var errorsList []string
	for _, item := range pvList.Items {
		pvName := item.Metadata.Name
		if pvName == "" {
			continue
		}

		out, err := runRestoreKubectl(defaultKubeTimeout, "get", "pv", pvName, "-o", "json")
		if err != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to inspect PV '%s': %v", pvName, err))
			continue
		}
		var pv struct {
			Spec struct {
				ClaimRef *struct {
					Namespace string `json:"namespace"`
					Name      string `json:"name"`
					UID       string `json:"uid"`
				} `json:"claimRef"`
			} `json:"spec"`
		}
		if err := json.Unmarshal([]byte(out), &pv); err != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to parse PV '%s': %v", pvName, err))
			continue
		}
		ref := pv.Spec.ClaimRef
		if ref == nil || ref.UID == "" {
			continue
		}

		stale := false
		uid, err := runRestoreKubectl(defaultKubeTimeout, "get", "pvc", ref.Name, "-n", ref.Namespace, "-o", "jsonpath={.metadata.uid}")
		if err != nil {
			if !strings.Contains(err.Error(), "NotFound") {
				errorsList = append(errorsList, fmt.Sprintf("failed to inspect claim '%s/%s' of PV '%s': %v", ref.Namespace, ref.Name, pvName, err))
				continue
			}
			stale = true
		} else if strings.TrimSpace(uid) != ref.UID {
			stale = true
		}
		if !stale {
			continue
		}

		slog.Info("[System Restore] Clearing stale claim binding of PV", "pv", pvName, "claim", ref.Namespace+"/"+ref.Name)
		if _, err := runRestoreKubectl(defaultKubeTimeout, "patch", "pv", pvName, "--type=json", "-p", `[{"op":"remove","path":"/spec/claimRef"}]`); err != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to clear stale claim binding of PV '%s': %v", pvName, err))
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

		if err := ensureNamespaceExists(ns); err != nil {
			errorsList = append(errorsList, fmt.Sprintf("failed to ensure namespace '%s' exists: %v", ns, err))
			continue
		}

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

func ensureNamespaceExists(ns string) error {
	if _, err := runRestoreKubectl(defaultKubeTimeout, "get", "namespace", ns); err == nil {
		return nil
	} else if !strings.Contains(err.Error(), "NotFound") {
		return err
	}

	slog.Info("[System Restore] Creating namespace", "namespace", ns)
	out, err := runRestoreKubectl(defaultKubeTimeout, "create", "namespace", ns)
	if err != nil && !strings.Contains(err.Error(), "AlreadyExists") {
		return fmt.Errorf("%w: %s", err, out)
	}
	return nil
}

func applyResourceYaml(yamlFile, namespace string) error {
	args := []string{"apply", "--server-side", "--force-conflicts", "-f", yamlFile}
	if namespace != "" {
		args = append(args, "-n", namespace)
	}

	ctx, cancel := context.WithTimeout(context.Background(), defaultKubeTimeout)
	defer cancel()

	cmd := restoreKubectlCmd(ctx, args...)
	out, err := cmd.CombinedOutput()
	outStr := string(out)

	if err != nil || strings.Contains(outStr, "error:") || strings.Contains(outStr, "Error from server") {
		return fmt.Errorf("failed to apply resource file '%s': %s", filepath.Base(yamlFile), strings.TrimSpace(outStr))
	}

	return nil
}
