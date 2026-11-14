// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package lifecycle

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Operation carries non-secret lifecycle inputs. The shell reads registry.dat
// itself so credentials never appear in this operation document.
type Operation struct {
	InstallDir           string   `json:"installDir"`
	ConfigDir            string   `json:"configDir"`
	Version              string   `json:"version"`
	ClusterName          string   `json:"clusterName"`
	ControlPlaneHostname string   `json:"controlPlaneHostname"`
	Proxy                string   `json:"proxy"`
	NoProxy              []string `json:"noProxy"`
	SkipStart            bool     `json:"skipStart"`
	SkipPurge            bool     `json:"skipPurge"`
	NoRestart            bool     `json:"noRestart"`
	LinuxOnly            bool     `json:"linuxOnly"`
	WorkerCPUCount       string   `json:"workerCPUCount"`
	WorkerMemory         string   `json:"workerMemory"`
	WorkerDiskSize       string   `json:"workerDiskSize"`
	WindowsQCOW2Path     string   `json:"windowsQCOW2Path"`
}

// Execute invokes the platform-first native Linux lifecycle script.
func Execute(operation string, input Operation) error {
	if !filepath.IsAbs(input.InstallDir) || filepath.Clean(input.InstallDir) == string(os.PathSeparator) {
		return fmt.Errorf("native Linux install directory must be a non-root absolute path")
	}
	if !filepath.IsAbs(input.ConfigDir) || filepath.Clean(input.ConfigDir) == string(os.PathSeparator) {
		return fmt.Errorf("native Linux config directory must be a non-root absolute path")
	}
	if strings.TrimSpace(input.InstallDir) == "" || strings.TrimSpace(input.ConfigDir) == "" {
		return fmt.Errorf("native Linux install and config directories must be specified")
	}
	script, err := ScriptPath(input.InstallDir, LinuxOnly, operation)
	if err != nil {
		return err
	}
	info, err := os.Stat(script)
	if err != nil {
		return fmt.Errorf("native Linux lifecycle script %s: %w", script, err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("native Linux lifecycle script is not a regular file: %s", script)
	}
	if err := os.MkdirAll(input.ConfigDir, 0700); err != nil {
		return fmt.Errorf("create lifecycle state directory: %w", err)
	}
	file, err := os.CreateTemp(input.ConfigDir, ".lifecycle-*.json")
	if err != nil {
		return fmt.Errorf("create lifecycle operation file: %w", err)
	}
	path := file.Name()
	defer os.Remove(path)
	// CreateTemp creates files with 0600 permissions. Verify that invariant
	// before writing the operation data so a platform-specific umask cannot
	// expose its non-secret but operationally sensitive inputs.
	fileInfo, err := file.Stat()
	if err != nil {
		file.Close()
		return fmt.Errorf("verify lifecycle operation file permissions: %w", err)
	}
	if fileInfo.Mode().Perm() != 0600 {
		file.Close()
		return fmt.Errorf("lifecycle operation file has unsafe permissions: %o", fileInfo.Mode().Perm())
	}
	if err := file.Chmod(0600); err != nil {
		file.Close()
		return fmt.Errorf("secure lifecycle operation file: %w", err)
	}
	if err := json.NewEncoder(file).Encode(input); err != nil {
		file.Close()
		return fmt.Errorf("write lifecycle operation file: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close lifecycle operation file: %w", err)
	}

	cmd := exec.Command("bash", script, "--operation-file", path)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("native Linux %s failed: %w", operation, err)
	}
	return nil
}
