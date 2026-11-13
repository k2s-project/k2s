// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package lifecycle

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/k2s-project/k2s/internal/output"
	"github.com/k2s-project/k2s/internal/providers/bash"
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
	LinuxOnly            bool     `json:"linuxOnly"`
	WorkerCPUCount       string   `json:"workerCPUCount"`
	WorkerMemory         string   `json:"workerMemory"`
	WorkerDiskSize       string   `json:"workerDiskSize"`
	WindowsQCOW2Path     string   `json:"windowsQCOW2Path"`
}

// Execute invokes the native Linux lifecycle script. A nil writer discards the script output.
func Execute(operation string, input Operation, writer output.StreamWriter, showLogs bool) error {
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
	if err := os.MkdirAll(input.ConfigDir, 0o700); err != nil {
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
	if fileInfo.Mode().Perm() != 0o600 {
		file.Close()
		return fmt.Errorf("lifecycle operation file has unsafe permissions: %o", fileInfo.Mode().Perm())
	}
	if err := file.Chmod(0o600); err != nil {
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

	err = bash.NewScript(script).
		WithArgs("--operation-file", path).
		WithShowLogs(showLogs).
		WithStdWriter(writer).
		Exec()
	if err != nil {
		return fmt.Errorf("native Linux %s failed: %w (see log file for more information)", operation, err)
	}
	return nil
}
