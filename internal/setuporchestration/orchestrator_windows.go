// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build windows

package setuporchestration

import (
	"fmt"
	"path/filepath"

	"github.com/k2s-project/k2s/cmd/k2s/utils"
	"github.com/k2s-project/k2s/internal/output"
	"github.com/k2s-project/k2s/internal/providers/powershell"
)

// WindowsOrchestrator implements Orchestrator by delegating to PowerShell scripts.
// This preserves the existing Windows behavior.
type WindowsOrchestrator struct {
	stdWriter output.StreamWriter
}

// NewOrchestrator returns the platform-specific orchestrator.
// On Windows, it returns a PowerShell-based orchestrator.
func NewOrchestrator(writer output.StreamWriter) Orchestrator {
	return &WindowsOrchestrator{stdWriter: writer}
}

func (o *WindowsOrchestrator) Install(config InstallConfig) error {
	path := filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "install", "install.ps1")
	cmd := utils.FormatScriptFilePath(path)
	cmd += fmt.Sprintf(" -MasterVMProcessorCount %s -MasterVMMemory %s -MasterDiskSize %s",
		config.MasterVMProcessorCount, config.MasterVMMemory, config.MasterDiskSize)

	if config.ShowLogs {
		cmd += " -ShowLogs"
	}
	if config.LinuxOnly {
		cmd += " -LinuxOnly"
	}
	if config.WSL {
		cmd += " -WSL"
	}
	if config.Proxy != "" {
		cmd += " -Proxy " + utils.EscapeWithSingleQuotes(config.Proxy)
	}
	if config.AdditionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(config.AdditionalHooksDir)
	}
	if config.ForceOnlineInstallation {
		cmd += " -ForceOnlineInstallation"
	}

	return powershell.ExecutePs(cmd, o.stdWriter)
}

func (o *WindowsOrchestrator) Uninstall(config UninstallConfig) error {
	path := filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "uninstall", "uninstall.ps1")
	cmd := utils.FormatScriptFilePath(path)

	if config.SkipPurge {
		cmd += " -SkipPurge"
	}
	if config.ShowLogs {
		cmd += " -ShowLogs"
	}
	if config.AdditionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(config.AdditionalHooksDir)
	}
	if config.DeleteFilesForOfflineInstallation {
		cmd += " -DeleteFilesForOfflineInstallation"
	}

	return powershell.ExecutePs(cmd, o.stdWriter)
}

func (o *WindowsOrchestrator) Start(config StartConfig) error {
	path := filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "start", "start.ps1")
	cmd := utils.FormatScriptFilePath(path)

	if config.ShowLogs {
		cmd += " -ShowLogs"
	}
	if config.AdditionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(config.AdditionalHooksDir)
	}
	if config.UseCachedK2sVSwitch {
		cmd += " -UseCachedK2sVSwitches"
	}

	return powershell.ExecutePs(cmd, o.stdWriter)
}

func (o *WindowsOrchestrator) Stop(config StopConfig) error {
	path := filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "stop", "stop.ps1")
	cmd := utils.FormatScriptFilePath(path)

	if config.ShowLogs {
		cmd += " -ShowLogs"
	}
	if config.AdditionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(config.AdditionalHooksDir)
	}

	return powershell.ExecutePs(cmd, o.stdWriter)
}
