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

type linuxNodeProvider struct {
	installDir string
	configDir  string
	stdWriter  output.StreamWriter
}

// Must match the K2S_NODE_EXIT_* constants in lib/modules/linux/node/worker-node.module.sh.
const (
	nodeScriptExitNotSupported  = 3
	nodeScriptExitAlreadyExists = 4
	nodeScriptExitNotFound      = 5
)

func newLinuxNodeProvider(cfg ProviderConfig) *linuxNodeProvider {
	return &linuxNodeProvider{installDir: cfg.InstallDir, configDir: cfg.ConfigDir, stdWriter: cfg.StdWriter}
}

func (p *linuxNodeProvider) Rename(cfg NodeRenameConfig) error {
	if _, err := cfg.Validated(); err != nil {
		return err
	}
	return NotSupportedError("node rename", "worker identity repair is currently available only from a Windows K2s host")
}

// Add joins a Debian 13 worker node (amd64 or arm64) to the cluster that runs on this host via
// lib/scripts/linux/debian/worker/bare-metal/Add.sh; without a node package the node downloads its packages itself.
func (p *linuxNodeProvider) Add(cfg NodeAddConfig) error {
	if cfg.IpAddress == "" {
		return errors.New("--ip-addr is required to add a node")
	}
	if cfg.UserName == "" {
		return errors.New("--username is required to add a node")
	}
	slog.Info("[Node] Adding node", "ip", cfg.IpAddress, "user", cfg.UserName, "package", cfg.NodePackagePath)
	args := []string{
		"--ip-address", cfg.IpAddress,
		"--user", cfg.UserName,
	}
	if cfg.NodePackagePath != "" {
		args = append(args, "--node-package", cfg.NodePackagePath)
	}
	return p.runNodeScript("Add.sh", "adding node "+cfg.IpAddress, cfg.ShowOutput, args...)
}

func (p *linuxNodeProvider) Remove(cfg NodeRemoveConfig) error {
	if cfg.NodeName == "" {
		return errors.New("--name is required to remove a node")
	}

	slog.Info("[Node] Removing node", "name", cfg.NodeName)
	return p.runNodeScript("Remove.sh", "removing node "+cfg.NodeName, cfg.ShowOutput, "--name", cfg.NodeName)
}

func (p *linuxNodeProvider) Start(cfg NodeStartConfig) error {
	if err := requireLinuxWorker(cfg.Role, cfg.OS, "node start"); err != nil {
		return err
	}
	slog.Info("[Node] Starting node", "name", cfg.NodeName)
	return p.runNodeScript("Start.sh", "starting node "+cfg.NodeName, cfg.ShowOutput, "--name", cfg.NodeName)
}

func (p *linuxNodeProvider) Stop(cfg NodeStopConfig) error {
	if err := requireLinuxWorker(cfg.Role, cfg.OS, "node stop"); err != nil {
		return err
	}
	args := []string{"--name", cfg.NodeName}
	if cfg.WaitForNotReady {
		args = append(args, "--wait-for-not-ready")
	}
	slog.Info("[Node] Stopping node", "name", cfg.NodeName)
	return p.runNodeScript("Stop.sh", "stopping node "+cfg.NodeName, cfg.ShowOutput, args...)
}

func requireLinuxWorker(role, nodeOS, operation string) error {
	if role != "worker" || nodeOS != "linux" {
		return NotSupportedError(operation, fmt.Sprintf("only Linux worker nodes can be added to a Linux host; found role '%s', OS '%s'", role, nodeOS))
	}
	return nil
}

func (p *linuxNodeProvider) runNodeScript(name, operation string, showOutput bool, args ...string) error {
	script := filepath.Join(p.installDir, "lib", "scripts", "linux", "debian", "worker", "bare-metal", name)
	if _, err := os.Stat(script); err != nil {
		return fmt.Errorf("node script not found: %w", err)
	}

	scriptOut := &scriptOutput{next: p.stdWriter}
	err := bash.NewScript(script).
		WithArgs(append(args, "--install-dir", p.installDir, "--config-dir", p.configDir)...).
		WithShowLogs(showOutput).
		WithStdWriter(scriptOut).
		Exec()
	if err == nil {
		return nil
	}
	reason := scriptOut.lastError
	if reason == "" {
		reason = err.Error()
	}
	if exitErr, ok := errors.AsType[*exec.ExitError](err); ok {
		switch exitErr.ExitCode() {
		case nodeScriptExitNotSupported:
			return &ProviderFailure{Severity: SeverityWarning, Code: "node-os-not-supported", Message: reason}
		case nodeScriptExitAlreadyExists:
			return &ProviderFailure{Severity: SeverityWarning, Code: "node-already-exists", Message: reason}
		case nodeScriptExitNotFound:
			return &ProviderFailure{Severity: SeverityWarning, Code: "node-not-found", Message: reason}
		}
	}
	return fmt.Errorf("%s failed: %s (see log file for more information)", operation, reason)
}
