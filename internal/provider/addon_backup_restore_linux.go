// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"archive/tar"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/k2s-project/k2s/internal/version"
)

const (
	registryBackupArchive = "registry-repository.tar.gz"
	registryConfigBackup  = "registry-config.json"
)

type linuxAddonBackupManifest struct {
	K2sVersion     string   `json:"k2sVersion"`
	Files          []string `json:"files"`
	Addon          string   `json:"addon"`
	Implementation string   `json:"implementation,omitempty"`
	CreatedAt      string   `json:"createdAt,omitempty"`
}

func (p *linuxAddonProvider) backupAddon(cfg AddonRunCommandConfig, params map[string]string) error {
	if cfg.AddonName != "registry" {
		return NotSupportedError("addon backup",
			fmt.Sprintf("native Linux backup is not implemented for addon '%s'", cfg.AddonName))
	}
	if !p.isAddonEnabledInConfig("registry") {
		return errors.New("addon 'registry' is not enabled. Enable it before running backup.")
	}

	backupDir := addonBackupDir(cfg, params)
	if backupDir == "" {
		return errors.New("backup directory is required")
	}
	if err := os.MkdirAll(backupDir, 0o700); err != nil {
		return fmt.Errorf("create addon backup directory: %w", err)
	}

	repositoryPath := "/registry"
	archivePath := filepath.Join(backupDir, registryBackupArchive)
	if err := createRegistryDataArchive(repositoryPath, archivePath); err != nil {
		return fmt.Errorf("backup registry repository: %w", err)
	}
	files := []string{registryBackupArchive}

	configMapJSON, err := kubectlAddonOutput("get", "configmap", "registry-config", "-n", "registry", "-o", "json")
	if err != nil {
		if !strings.Contains(strings.ToLower(err.Error()), "not found") {
			return fmt.Errorf("read registry-config ConfigMap: %w", err)
		}
		slog.Info("[Addon Backup] registry-config ConfigMap was not found; backing up repository data only")
	} else {
		var configMap struct {
			Data map[string]string `json:"data"`
		}
		if err := json.Unmarshal([]byte(configMapJSON), &configMap); err != nil {
			return fmt.Errorf("parse registry-config ConfigMap: %w", err)
		}
		minimalConfigMap := struct {
			APIVersion string `json:"apiVersion"`
			Kind       string `json:"kind"`
			Metadata   struct {
				Name      string `json:"name"`
				Namespace string `json:"namespace"`
			} `json:"metadata"`
			Data map[string]string `json:"data,omitempty"`
		}{
			APIVersion: "v1",
			Kind:       "ConfigMap",
			Data:       configMap.Data,
		}
		minimalConfigMap.Metadata.Name = "registry-config"
		minimalConfigMap.Metadata.Namespace = "registry"
		data, err := json.MarshalIndent(minimalConfigMap, "", "  ")
		if err != nil {
			return fmt.Errorf("encode registry-config ConfigMap: %w", err)
		}
		if err := os.WriteFile(filepath.Join(backupDir, registryConfigBackup), data, 0o600); err != nil {
			return fmt.Errorf("write registry-config backup: %w", err)
		}
		files = append(files, registryConfigBackup)
	}

	manifest := linuxAddonBackupManifest{
		K2sVersion:     version.GetVersion().Version,
		Files:          files,
		Addon:          cfg.AddonName,
		Implementation: cfg.Implementation,
		CreatedAt:      time.Now().Format(time.RFC3339),
	}
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("encode addon backup manifest: %w", err)
	}
	if err := os.WriteFile(filepath.Join(backupDir, "backup.json"), data, 0o600); err != nil {
		return fmt.Errorf("write addon backup manifest: %w", err)
	}

	slog.Info("[Addon Backup] Registry addon backup prepared", "files", files)
	return nil
}

func (p *linuxAddonProvider) restoreAddon(cfg AddonRunCommandConfig, params map[string]string) error {
	if cfg.AddonName != "registry" {
		return NotSupportedError("addon restore",
			fmt.Sprintf("native Linux restore is not implemented for addon '%s'", cfg.AddonName))
	}

	backupDir := addonBackupDir(cfg, params)
	if backupDir == "" {
		return errors.New("backup directory is required")
	}
	manifestData, err := os.ReadFile(filepath.Join(backupDir, "backup.json"))
	if err != nil {
		return fmt.Errorf("read addon backup manifest: %w", err)
	}
	var manifest linuxAddonBackupManifest
	if err := json.Unmarshal(manifestData, &manifest); err != nil {
		return fmt.Errorf("parse addon backup manifest: %w", err)
	}

	hasArchive := containsAddonString(manifest.Files, registryBackupArchive)
	hasConfigMap := containsAddonString(manifest.Files, registryConfigBackup)
	if !hasArchive && !hasConfigMap {
		slog.Info("[Addon Restore] Registry backup contains no addon data")
		return nil
	}

	if hasArchive {
		archivePath := filepath.Join(backupDir, registryBackupArchive)
		if _, err := os.Stat(archivePath); err != nil {
			return fmt.Errorf("registry repository archive listed in backup is unavailable: %w", err)
		}
		if err := kubectlAddonRun(cfg.ShowOutput, "scale", "statefulset", "registry", "-n", "registry", "--replicas=0"); err != nil {
			return fmt.Errorf("stop registry before restoring repository: %w", err)
		}
		if err := waitForRegistryPodsToStop(); err != nil {
			restartErr := kubectlAddonRun(cfg.ShowOutput, "scale", "statefulset", "registry", "-n", "registry", "--replicas=1")
			return errors.Join(err, restartErr)
		}
		if err := extractRegistryDataArchive(archivePath, "/registry"); err != nil {
			restartErr := kubectlAddonRun(cfg.ShowOutput, "scale", "statefulset", "registry", "-n", "registry", "--replicas=1")
			return errors.Join(fmt.Errorf("restore registry repository: %w", err), restartErr)
		}
	}

	if hasConfigMap {
		configMapPath := filepath.Join(backupDir, registryConfigBackup)
		if _, err := os.Stat(configMapPath); err != nil {
			return fmt.Errorf("registry ConfigMap backup listed in manifest is unavailable: %w", err)
		}
		if err := kubectlAddonRun(cfg.ShowOutput, "apply", "--server-side", "--force-conflicts",
			"--field-manager=k2s-addon-restore", "-f", configMapPath); err != nil {
			if hasArchive {
				restartErr := kubectlAddonRun(cfg.ShowOutput, "scale", "statefulset", "registry", "-n", "registry", "--replicas=1")
				return errors.Join(fmt.Errorf("restore registry ConfigMap: %w", err), restartErr)
			}
			return fmt.Errorf("restore registry ConfigMap: %w", err)
		}
	}

	if hasArchive {
		if err := kubectlAddonRun(cfg.ShowOutput, "scale", "statefulset", "registry", "-n", "registry", "--replicas=1"); err != nil {
			return fmt.Errorf("start registry after restoring repository: %w", err)
		}
		if err := kubectlAddonRun(cfg.ShowOutput, "rollout", "status", "statefulset/registry", "-n", "registry", "--timeout=300s"); err != nil {
			return fmt.Errorf("wait for registry after restore: %w", err)
		}
	} else if err := kubectlAddonRun(cfg.ShowOutput, "rollout", "restart", "statefulset/registry", "-n", "registry"); err != nil {
		return fmt.Errorf("restart registry after restoring ConfigMap: %w", err)
	}

	slog.Info("[Addon Restore] Registry addon restore completed")
	return nil
}

func validateRegistryAddonBackup(cfg AddonRunCommandConfig, params map[string]string) error {
	backupDir := addonBackupDir(cfg, params)
	if backupDir == "" {
		return errors.New("backup directory is required")
	}
	manifestData, err := os.ReadFile(filepath.Join(backupDir, "backup.json"))
	if err != nil {
		return fmt.Errorf("read addon backup manifest: %w", err)
	}
	var manifest linuxAddonBackupManifest
	if err := json.Unmarshal(manifestData, &manifest); err != nil {
		return fmt.Errorf("parse addon backup manifest: %w", err)
	}
	if manifest.Addon != "registry" {
		return fmt.Errorf("backup is for addon '%s', not 'registry'", manifest.Addon)
	}

	if containsAddonString(manifest.Files, registryBackupArchive) {
		archivePath := filepath.Join(backupDir, registryBackupArchive)
		if _, err := os.Stat(archivePath); err != nil {
			return fmt.Errorf("registry repository archive listed in backup is unavailable: %w", err)
		}
		if err := validateRegistryDataArchive(archivePath); err != nil {
			return fmt.Errorf("invalid registry repository archive: %w", err)
		}
	}
	if containsAddonString(manifest.Files, registryConfigBackup) {
		configMapPath := filepath.Join(backupDir, registryConfigBackup)
		data, err := os.ReadFile(configMapPath)
		if err != nil {
			return fmt.Errorf("registry ConfigMap backup listed in manifest is unavailable: %w", err)
		}
		var configMap struct {
			Kind     string `json:"kind"`
			Metadata struct {
				Name      string `json:"name"`
				Namespace string `json:"namespace"`
			} `json:"metadata"`
		}
		if err := json.Unmarshal(data, &configMap); err != nil {
			return fmt.Errorf("parse registry ConfigMap backup: %w", err)
		}
		if configMap.Kind != "ConfigMap" || configMap.Metadata.Name != "registry-config" || configMap.Metadata.Namespace != "registry" {
			return errors.New("registry ConfigMap backup has an unexpected target")
		}
	}
	return nil
}

func addonBackupDir(cfg AddonRunCommandConfig, params map[string]string) string {
	if dir := strings.TrimSpace(cfg.ParameterValues["BackupDir"]); dir != "" {
		return dir
	}
	return strings.Trim(strings.TrimSpace(params["backupdir"]), "'\"")
}

func kubectlAddonOutput(args ...string) (string, error) {
	output, err := exec.Command("kubectl", args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("kubectl %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return string(output), nil
}

func kubectlAddonRun(showOutput bool, args ...string) error {
	cmd := exec.Command("kubectl", args...)
	if showOutput {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("kubectl %s: %w", strings.Join(args, " "), err)
		}
		return nil
	}
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("kubectl %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return nil
}

func waitForRegistryPodsToStop() error {
	deadline := time.Now().Add(3 * time.Minute)
	var lastErr error
	for time.Now().Before(deadline) {
		output, err := kubectlAddonOutput("get", "pods", "-n", "registry", "-l", "app=registry", "-o", "name")
		if err != nil {
			lastErr = err
		} else if strings.TrimSpace(output) == "" {
			return nil
		}
		time.Sleep(2 * time.Second)
	}
	if lastErr != nil {
		return fmt.Errorf("registry pods did not stop within 3 minutes: %w", lastErr)
	}
	return errors.New("registry pods did not stop within 3 minutes")
}

func createRegistryDataArchive(registryDir, archivePath string) error {
	repositoryPath := filepath.Join(registryDir, "repository")
	info, err := os.Lstat(repositoryPath)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("repository path %q is not a regular directory", repositoryPath)
	}

	file, err := os.OpenFile(archivePath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	gz := gzip.NewWriter(file)
	tw := tar.NewWriter(gz)

	walkErr := filepath.WalkDir(repositoryPath, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		entryInfo, err := entry.Info()
		if err != nil {
			return err
		}
		if entryInfo.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("repository contains a symbolic link: %s", path)
		}
		if !entry.IsDir() && !entryInfo.Mode().IsRegular() {
			return fmt.Errorf("repository contains an unsupported file type: %s", path)
		}
		header, err := tar.FileInfoHeader(entryInfo, "")
		if err != nil {
			return err
		}
		relativePath, err := filepath.Rel(registryDir, path)
		if err != nil {
			return err
		}
		header.Name = filepath.ToSlash(relativePath)
		if err := tw.WriteHeader(header); err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		source, err := os.Open(path)
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(tw, source)
		closeErr := source.Close()
		return errors.Join(copyErr, closeErr)
	})
	tarErr := tw.Close()
	gzipErr := gz.Close()
	fileErr := file.Close()
	if err := errors.Join(walkErr, tarErr, gzipErr, fileErr); err != nil {
		_ = os.Remove(archivePath)
		return err
	}
	return nil
}

func extractRegistryDataArchive(archivePath, registryDir string) error {
	rootInfo, err := os.Lstat(registryDir)
	if err != nil {
		return err
	}
	if !rootInfo.IsDir() || rootInfo.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("registry data root %q is not a regular directory", registryDir)
	}
	stagingDir, err := os.MkdirTemp(registryDir, ".repository-restore-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stagingDir)

	if err := unpackRegistryArchive(archivePath, stagingDir); err != nil {
		return err
	}
	stagedRepository := filepath.Join(stagingDir, "repository")
	stagedInfo, err := os.Lstat(stagedRepository)
	if err != nil {
		return fmt.Errorf("archive does not contain repository directory: %w", err)
	}
	if !stagedInfo.IsDir() || stagedInfo.Mode()&os.ModeSymlink != 0 {
		return errors.New("archive repository entry is not a regular directory")
	}

	repositoryPath := filepath.Join(registryDir, "repository")
	oldRepository := filepath.Join(registryDir, fmt.Sprintf(".repository-old-%d", time.Now().UnixNano()))
	if _, err := os.Lstat(repositoryPath); err == nil {
		if err := os.Rename(repositoryPath, oldRepository); err != nil {
			return fmt.Errorf("move existing registry repository aside: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.Rename(stagedRepository, repositoryPath); err != nil {
		if _, statErr := os.Lstat(oldRepository); statErr == nil {
			if rollbackErr := os.Rename(oldRepository, repositoryPath); rollbackErr != nil {
				return errors.Join(fmt.Errorf("install restored registry repository: %w", err),
					fmt.Errorf("restore previous registry repository: %w", rollbackErr))
			}
		}
		return fmt.Errorf("install restored registry repository: %w", err)
	}
	if err := os.RemoveAll(oldRepository); err != nil {
		return fmt.Errorf("remove previous registry repository: %w", err)
	}
	return nil
}

func unpackRegistryArchive(archivePath, destination string) error {
	file, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer file.Close()
	gz, err := gzip.NewReader(file)
	if err != nil {
		return err
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	directoryModes := make(map[string]tar.Header)
	for {
		header, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		cleanName, err := registryArchiveEntryPath(header)
		if err != nil {
			return err
		}
		targetPath := filepath.Join(destination, cleanName)

		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(targetPath, 0o755); err != nil {
				return err
			}
			directoryModes[targetPath] = *header
		case tar.TypeReg, tar.TypeRegA:
			if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
				return err
			}
			target, err := os.OpenFile(targetPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, os.FileMode(header.Mode)&0o777)
			if err != nil {
				return err
			}
			_, copyErr := io.Copy(target, tr)
			closeErr := target.Close()
			if err := errors.Join(copyErr, closeErr); err != nil {
				return err
			}
			if os.Geteuid() == 0 {
				if err := os.Chown(targetPath, header.Uid, header.Gid); err != nil {
					return err
				}
			}
			if err := os.Chmod(targetPath, os.FileMode(header.Mode)&0o777); err != nil {
				return err
			}
		}
	}

	for path, header := range directoryModes {
		if os.Geteuid() == 0 {
			if err := os.Chown(path, header.Uid, header.Gid); err != nil {
				return err
			}
		}
		if err := os.Chmod(path, os.FileMode(header.Mode)&0o777); err != nil {
			return err
		}
	}
	return nil
}

func validateRegistryDataArchive(archivePath string) error {
	file, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer file.Close()
	gz, err := gzip.NewReader(file)
	if err != nil {
		return err
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	hasRepository := false
	for {
		header, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		cleanName, err := registryArchiveEntryPath(header)
		if err != nil {
			return err
		}
		if cleanName == "repository" {
			hasRepository = true
		}
	}
	if !hasRepository {
		return errors.New("archive does not contain repository directory")
	}
	return nil
}

func registryArchiveEntryPath(header *tar.Header) (string, error) {
	if header.Typeflag != tar.TypeDir && header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeRegA {
		return "", fmt.Errorf("unsupported registry archive entry type %d for %q", header.Typeflag, header.Name)
	}
	rawName := header.Name
	if header.Typeflag == tar.TypeDir {
		rawName = strings.TrimSuffix(rawName, "/")
	}
	name := filepath.FromSlash(rawName)
	cleanName := filepath.Clean(name)
	if filepath.IsAbs(name) || cleanName != name || cleanName == "." ||
		(cleanName != "repository" && !strings.HasPrefix(cleanName, "repository"+string(os.PathSeparator))) {
		return "", fmt.Errorf("unsafe registry archive path %q", header.Name)
	}
	if cleanName == "repository" && header.Typeflag != tar.TypeDir {
		return "", errors.New("archive repository entry is not a directory")
	}
	return cleanName, nil
}

func containsAddonString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
