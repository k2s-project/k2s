// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build windows

package provider

import (
	"fmt"
	"path/filepath"

	"github.com/k2s-project/k2s/cmd/k2s/utils"
	"github.com/k2s-project/k2s/internal/core/addonplacement"
	"github.com/k2s-project/k2s/internal/output"
	"github.com/k2s-project/k2s/internal/providers/powershell"
)

type windowsAddonProvider struct {
	installDir string
	stdWriter  output.StreamWriter
}

func newWindowsAddonProvider(cfg ProviderConfig) *windowsAddonProvider {
	return &windowsAddonProvider{
		installDir: cfg.InstallDir,
		stdWriter:  cfg.StdWriter,
	}
}

func (p *windowsAddonProvider) Enable(cfg AddonEnableConfig) error {
	if cfg.Params["InfraNodeSelector"] != "" && !addonplacement.SupportsAddon(cfg.Name) {
		return NotSupportedError("infra-node-selector",
			fmt.Sprintf("addon '%s' does not have a selector-aware pre-creation renderer", cfg.Name))
	}
	if selector := cfg.Params["InfraNodeSelector"]; selector != "" {
		if _, err := addonplacement.ParseSelector(selector); err != nil {
			return err
		}
	}
	scriptPath := utils.FormatScriptFilePath(filepath.Join(p.installDir, "addons", cfg.Name, "Enable.ps1"))

	var params string
	for key, val := range cfg.Params {
		params += fmt.Sprintf(" -%s '%s'", key, val)
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}

	result, err := powershell.ExecutePsWithStructuredResult[*psCmdResult](scriptPath+params, "CmdResult", p.stdWriter)
	if err != nil {
		return err
	}
	return result.checkFailure()
}

func (p *windowsAddonProvider) Disable(cfg AddonDisableConfig) error {
	scriptPath := utils.FormatScriptFilePath(filepath.Join(p.installDir, "addons", cfg.Name, "Disable.ps1"))

	var params string
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}

	result, err := powershell.ExecutePsWithStructuredResult[*psCmdResult](scriptPath+params, "CmdResult", p.stdWriter)
	if err != nil {
		return err
	}
	return result.checkFailure()
}

func (p *windowsAddonProvider) List(cfg AddonListConfig) (*AddonListResult, error) {
	scriptPath := utils.FormatScriptFilePath(filepath.Join(p.installDir, "addons", "Get-EnabledAddons.ps1"))

	type psEnabledAddon struct {
		Name            string   `json:"name"`
		Implementations []string `json:"implementations"`
	}

	result, err := powershell.ExecutePsWithStructuredResult[[]psEnabledAddon](scriptPath, "EnabledAddons", p.stdWriter)
	if err != nil {
		return nil, err
	}

	listResult := &AddonListResult{}
	for _, a := range result {
		listResult.Addons = append(listResult.Addons, AddonInfo{
			Name:            a.Name,
			Enabled:         true,
			Implementations: a.Implementations,
		})
	}

	return listResult, nil
}

func (p *windowsAddonProvider) Status(cfg AddonStatusConfig) (*AddonStatusResult, error) {
	scriptPath := utils.FormatScriptFilePath(filepath.Join(p.installDir, "addons", "Get-Status.ps1"))

	// The PS Get-Status.ps1 returns: {enabled: bool, props: [...], error: {severity, code, message}}
	type psProp struct {
		Name    string  `json:"name"`
		Value   any     `json:"value"`
		Okay    *bool   `json:"okay"`
		Message *string `json:"message"`
	}
	type psError struct {
		Severity int    `json:"severity"`
		Code     string `json:"code"`
		Message  string `json:"message"`
	}
	type psStatus struct {
		Enabled *bool    `json:"enabled"`
		Props   []psProp `json:"props"`
		Error   *psError `json:"error"`
	}

	params := " -Name " + cfg.Name
	if cfg.Directory != "" {
		params += " -Directory " + utils.EscapeWithSingleQuotes(cfg.Directory)
	}

	result, err := powershell.ExecutePsWithStructuredResult[*psStatus](scriptPath+params, "Status", p.stdWriter)
	if err != nil {
		return nil, err
	}

	statusResult := &AddonStatusResult{}

	if result.Error != nil {
		// Return as a provider failure instead of silently ignoring
		return nil, &ProviderFailure{
			Severity: FailureSeverity(result.Error.Severity),
			Code:     result.Error.Code,
			Message:  result.Error.Message,
		}
	}

	info := AddonStatusInfo{
		Name: cfg.Name,
	}
	if result.Enabled != nil {
		info.Enabled = *result.Enabled
	}
	for _, prop := range result.Props {
		sp := AddonStatusProp{
			Name:    prop.Name,
			Value:   prop.Value,   // preserve native type (bool, string, etc.)
			Okay:    prop.Okay,    // preserve nil for informational props
			Message: prop.Message, // preserve optional display message
		}
		info.Props = append(info.Props, sp)
	}
	statusResult.Addons = append(statusResult.Addons, info)

	return statusResult, nil
}

func (p *windowsAddonProvider) Export(cfg AddonExportConfig) error {
	scriptPath := utils.FormatScriptFilePath(filepath.Join(p.installDir, "addons", "Export.ps1"))

	var params string
	if cfg.OutputDir != "" {
		params += fmt.Sprintf(" -ExportDir '%s'", cfg.OutputDir)
	}
	if cfg.Name != "" {
		params += " -Name " + cfg.Name
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}

	result, err := powershell.ExecutePsWithStructuredResult[*psCmdResult](scriptPath+params, "CmdResult", p.stdWriter)
	if err != nil {
		return err
	}
	return result.checkFailure()
}

func (p *windowsAddonProvider) Import(cfg AddonImportConfig) error {
	scriptPath := utils.FormatScriptFilePath(filepath.Join(p.installDir, "addons", "Import.ps1"))

	var params string
	if cfg.InputDir != "" {
		params += fmt.Sprintf(" -ImportDir '%s'", cfg.InputDir)
	}
	if cfg.Name != "" {
		params += " -Name " + cfg.Name
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}

	result, err := powershell.ExecutePsWithStructuredResult[*psCmdResult](scriptPath+params, "CmdResult", p.stdWriter)
	if err != nil {
		return err
	}
	return result.checkFailure()
}

func (p *windowsAddonProvider) RunCommand(cfg AddonRunCommandConfig) error {
	if cfg.ParameterValues["InfraNodeSelector"] != "" &&
		(!addonplacement.SupportsAddon(cfg.AddonName) || cfg.CommandName != "enable") {
		return NotSupportedError("infra-node-selector",
			fmt.Sprintf("addon '%s' command '%s' does not support infrastructure placement", cfg.AddonName, cfg.CommandName))
	}
	scriptPath := utils.FormatScriptFilePath(filepath.Join(cfg.AddonDirectory, cfg.ScriptSubPath))
	result, err := powershell.ExecutePsWithStructuredResult[*psCmdResult](scriptPath, "CmdResult", p.stdWriter, cfg.Params...)
	if err != nil {
		return err
	}
	return result.checkFailure()
}
