// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/k2s-project/k2s/internal/output"
	"github.com/k2s-project/k2s/internal/providers/bash"
)

// Must match K2S_NODE_EXIT_NOT_SUPPORTED in lib/modules/linux/node/worker-node.module.sh.
const nodeScriptExitNotSupported = 3

type linuxNodeProvider struct {
	installDir string
	stdWriter  output.StreamWriter
}

func newLinuxNodeProvider(cfg ProviderConfig) *linuxNodeProvider {
	return &linuxNodeProvider{installDir: cfg.InstallDir, stdWriter: cfg.StdWriter}
}

func (p *linuxNodeProvider) Rename(cfg NodeRenameConfig) error {
	if _, err := cfg.Validated(); err != nil {
		return err
	}
	return NotSupportedError("node rename", "worker identity repair is currently available only from a Windows K2s host")
}

// Add joins a Debian 13 worker node (amd64 or arm64) to the cluster that runs on this host. The
// work is done by lib/scripts/linux/debian/worker/bare-metal/Add.sh, the Linux counterpart of the
// Windows bare-metal Add.ps1. Only offline node packages are supported on this path.
func (p *linuxNodeProvider) Add(cfg NodeAddConfig) error {
	if cfg.IpAddress == "" {
		return errors.New("--ip-addr is required to add a node")
	}
	if cfg.UserName == "" {
		return errors.New("--username is required to add a node")
	}
	if cfg.NodePackagePath == "" {
		return NotSupportedError("node add without --node-package", "the Linux host adds nodes from an offline node package; build one with 'k2s system package --node-package'")
	}

	script := filepath.Join(p.installDir, "lib", "scripts", "linux", "debian", "worker", "bare-metal", "Add.sh")
	if _, err := os.Stat(script); err != nil {
		return fmt.Errorf("node add script not found: %w", err)
	}

	slog.Info("[Node] Adding node", "ip", cfg.IpAddress, "user", cfg.UserName, "package", cfg.NodePackagePath)
	scriptOut := &scriptOutput{next: p.stdWriter}
	err := bash.NewScript(script).
		WithArgs(
			"--ip-address", cfg.IpAddress,
			"--user", cfg.UserName,
			"--node-package", cfg.NodePackagePath,
			"--install-dir", p.installDir,
		).
		WithShowLogs(cfg.ShowOutput).
		WithStdWriter(scriptOut).
		Exec()
	return nodeScriptError("adding node "+cfg.IpAddress, err, scriptOut.lastError)
}

func nodeScriptError(operation string, err error, lastError string) error {
	if err == nil {
		return nil
	}
	reason := lastError
	if reason == "" {
		reason = err.Error()
	}
	if exitErr, ok := errors.AsType[*exec.ExitError](err); ok && exitErr.ExitCode() == nodeScriptExitNotSupported {
		return &ProviderFailure{Severity: SeverityWarning, Code: "node-os-not-supported", Message: reason}
	}
	return fmt.Errorf("%s failed: %s (see log file for more information)", operation, reason)
}

func (p *linuxNodeProvider) Remove(cfg NodeRemoveConfig) error {
	slog.Info("[Node] Removing node", "name", cfg.NodeName)

	// Drain the node
	if err := exec.Command("kubectl", "drain", cfg.NodeName, "--ignore-daemonsets", "--delete-emptydir-data", "--force").Run(); err != nil {
		slog.Warn("[Node] Drain failed (continuing with removal)", "error", err)
	}

	// Delete the node from the cluster
	if err := exec.Command("kubectl", "delete", "node", cfg.NodeName).Run(); err != nil {
		return fmt.Errorf("failed to delete node '%s': %w", cfg.NodeName, err)
	}

	slog.Info("[Node] Node removed", "name", cfg.NodeName)
	return nil
}
