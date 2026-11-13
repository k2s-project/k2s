// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build windows

package provider

import (
	"fmt"
	"path/filepath"

	"github.com/k2s-project/k2s/cmd/k2s/utils"
	"github.com/k2s-project/k2s/internal/output"
	"github.com/k2s-project/k2s/internal/providers/powershell"
)

type windowsNodeProvider struct {
	installDir string
	stdWriter  output.StreamWriter
}

func (p *windowsNodeProvider) Rename(cfg NodeRenameConfig) error {
	cfg, err := cfg.Validated()
	if err != nil {
		return err
	}
	script, params := buildRenameScript(p.installDir, cfg)
	// The script reports failures as structured data; its exit code alone does not reach the CLI.
	result, err := powershell.ExecutePsWithStructuredResult[*psCmdResult](script, "CmdResult", p.stdWriter, params...)
	if err != nil {
		return err
	}
	return result.checkFailure()
}

func buildRenameScript(installDir string, cfg NodeRenameConfig) (string, []string) {
	script := utils.FormatScriptFilePath(filepath.Join(installDir, "lib", "scripts", "windows", "worker", "Rename.ps1"))
	params := []string{
		"-OldName " + utils.EscapeWithSingleQuotes(cfg.OldName),
		"-NewName " + utils.EscapeWithSingleQuotes(cfg.NewName),
		fmt.Sprintf("-TimeoutSeconds %d", int(cfg.Timeout.Seconds())),
	}
	if cfg.Force {
		params = append(params, "-Force")
	}
	if cfg.ShowOutput {
		params = append(params, "-ShowLogs")
	}
	return script, params
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
