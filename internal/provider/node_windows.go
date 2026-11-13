// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package provider

import (
	"path/filepath"

	"github.com/k2s-project/k2s/cmd/k2s/utils"
	"github.com/k2s-project/k2s/internal/output"
	"github.com/k2s-project/k2s/internal/providers/powershell"
)

type windowsNodeProvider struct {
	installDir string
	stdWriter  output.StreamWriter
}

func newWindowsNodeProvider(cfg ProviderConfig) *windowsNodeProvider {
	return &windowsNodeProvider{
		installDir: cfg.InstallDir,
		stdWriter:  cfg.StdWriter,
	}
}

func (p *windowsNodeProvider) Add(cfg NodeAddConfig) error {

	scriptDir := "bare-metal"
	if cfg.IsLocalVM {
		scriptDir = filepath.Join("hyper-v-vm", "existing-vm")
	}
	psCmd := utils.FormatScriptFilePath(filepath.Join(p.installDir, "lib", "scripts", "windows", "worker", "linux", scriptDir, "Add.ps1"))

	var params string
	if cfg.UserName != "" {
		params += " -UserName " + cfg.UserName
	}
	if cfg.IpAddress != "" {
		params += " -IpAddress " + cfg.IpAddress
	}
	if cfg.NodeName != "" {
		params += " -NodeName " + cfg.NodeName
	}
	if cfg.NodePackagePath != "" {
		params += " -NodePackagePath '" + cfg.NodePackagePath + "'"
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}

	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsNodeProvider) Remove(cfg NodeRemoveConfig) error {
	psCmd := utils.FormatScriptFilePath(filepath.Join(p.installDir, "lib", "scripts", "windows", "worker", "linux", "bare-metal", "Remove.ps1"))

	var params string
	if cfg.NodeName != "" {
		params += " -NodeName " + cfg.NodeName
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}

	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}
