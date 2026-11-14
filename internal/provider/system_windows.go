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

type windowsSystemProvider struct {
	installDir string
	configDir  string
	stdWriter  output.StreamWriter
}

func newWindowsSystemProvider(cfg ProviderConfig) *windowsSystemProvider {
	return &windowsSystemProvider{
		installDir: cfg.InstallDir,
		configDir:  cfg.ConfigDir,
		stdWriter:  cfg.StdWriter,
	}
}

func (p *windowsSystemProvider) scriptPath(script string) string {
	return utils.FormatScriptFilePath(filepath.Join(p.installDir, "lib", "scripts", "windows", "host", "system", script))
}

func (p *windowsSystemProvider) execPS(psCmd string, params ...string) error {
	result, err := powershell.ExecutePsWithStructuredResult[*psCmdResult](psCmd, "CmdResult", p.stdWriter, params...)
	if err != nil {
		return err
	}
	return result.checkFailure()
}

func (p *windowsSystemProvider) Dump(cfg SystemDumpConfig) error {
	psCmd := p.scriptPath("dump/dump.ps1")
	var params string
	if cfg.SkipOpenDump {
		params += " -OpenDumpFolder $false"
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	if cfg.Nodes != "" {
		params += " -Nodes " + utils.EscapeWithSingleQuotes(cfg.Nodes)
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) Upgrade(cfg SystemUpgradeConfig) error {
	if cfg.NodeName != "" && cfg.NodePackagePath != "" {
		psCmd := p.scriptPath("upgrade/Upgrade-K2sNode.ps1")
		var params string
		params += " -NodeName " + utils.EscapeWithSingleQuotes(cfg.NodeName)
		params += " -NodePackagePath " + utils.EscapeWithSingleQuotes(cfg.NodePackagePath)
		if cfg.ShowOutput {
			params += " -ShowLogs"
		}
		return powershell.ExecutePs(psCmd+params, p.stdWriter)
	}

	return powershell.ExecutePs(p.clusterUpgradeCommand(cfg), p.stdWriter)
}

func (p *windowsSystemProvider) clusterUpgradeCommand(cfg SystemUpgradeConfig) string {
	psCmd := p.scriptPath("upgrade/Start-ClusterUpgrade.ps1")
	var params string
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	if cfg.SkipResources {
		params += " -SkipResources"
	}
	if cfg.SkipImages {
		params += " -SkipImages"
	}
	if cfg.DeletePackage {
		params += " -DeleteFiles"
	}
	if cfg.ConfigFile != "" {
		params += " -Config " + utils.EscapeWithSingleQuotes(cfg.ConfigFile)
	}
	if cfg.Proxy != "" {
		params += " -Proxy " + utils.EscapeWithSingleQuotes(cfg.Proxy)
	}
	if cfg.BackupDir != "" {
		params += " -BackupDir " + utils.EscapeWithSingleQuotes(cfg.BackupDir)
	}
	if cfg.AdditionalHooksDir != "" {
		params += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(cfg.AdditionalHooksDir)
	}
	if cfg.Force {
		params += " -Force"
	}
	return psCmd + params
}

func (p *windowsSystemProvider) Package(cfg SystemPackageConfig) error {
	psCmd := p.scriptPath("package/New-K2sPackage.ps1")
	var params []string
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}
	return p.execPS(psCmd, params...)
}

func (p *windowsSystemProvider) Reset(cfg SystemResetConfig) error {
	psCmd := p.scriptPath("reset/Reset-System.ps1")
	var params string
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) ResetNetwork(cfg SystemResetNetworkConfig) error {
	psCmd := p.scriptPath("reset/network/Reset-Network.ps1")
	var params []string
	if cfg.Force {
		params = append(params, " -Force")
	}
	if cfg.AdditionalHooksDir != "" {
		params = append(params, " -AdditionalHooksDir "+utils.EscapeWithSingleQuotes(cfg.AdditionalHooksDir))
	}
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}
	return p.execPS(psCmd, params...)
}

func (p *windowsSystemProvider) Compact(cfg SystemCompactConfig) error {
	psCmd := p.scriptPath("compact/Invoke-VhdxCompaction.ps1")
	var params string
	if cfg.NoRestart {
		params += " -NoRestart"
	}
	if cfg.Yes {
		params += " -Yes"
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) Backup(cfg SystemBackupConfig) error {
	psCmd := p.scriptPath("backup/Start-SystemBackup.ps1")
	var params string
	if cfg.BackupFile != "" {
		params += " -BackupFile " + utils.EscapeWithSingleQuotes(cfg.BackupFile)
	}
	if cfg.AdditionalHooksDir != "" {
		params += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(cfg.AdditionalHooksDir)
	}
	if cfg.SkipImages {
		params += " -SkipImages"
	}
	if cfg.SkipPVs {
		params += " -SkipPVs"
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) Restore(cfg SystemRestoreConfig) error {
	psCmd := p.scriptPath("restore/Start-SystemRestore.ps1")
	var params string
	if cfg.BackupFile != "" {
		params += " -BackupFile " + utils.EscapeWithSingleQuotes(cfg.BackupFile)
	}
	if cfg.ErrorOnFailure {
		params += " -ErrorOnFailure"
	}
	if cfg.AdditionalHooksDir != "" {
		params += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(cfg.AdditionalHooksDir)
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) CertificateRenew(cfg SystemCertRenewConfig) error {
	psCmd := p.scriptPath("certificate/renew.ps1")
	var params []string
	if cfg.Force {
		params = append(params, "-Force")
	}
	if cfg.ShowOutput {
		params = append(params, "-ShowLogs")
	}
	return p.execPS(psCmd, params...)
}

func (p *windowsSystemProvider) CertificateAutoRotation(cfg SystemCertAutoRotationConfig) error {
	psCmd := p.scriptPath("certificate/autorotation.ps1")
	var params []string
	if cfg.Enable {
		params = append(params, "-Enable")
	} else if cfg.Disable {
		params = append(params, "-Disable")
	} else {
		params = append(params, "-Status")
	}
	if cfg.ShowOutput {
		params = append(params, "-ShowLogs")
	}
	return p.execPS(psCmd, params...)
}
