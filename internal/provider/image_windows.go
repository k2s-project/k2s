// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package provider

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/k2s-project/k2s/cmd/k2s/utils"
	"github.com/k2s-project/k2s/internal/output"
	"github.com/k2s-project/k2s/internal/providers/powershell"
)

type windowsImageProvider struct {
	installDir string
	stdWriter  output.StreamWriter
}

func newWindowsImageProvider(cfg ProviderConfig) *windowsImageProvider {
	return &windowsImageProvider{
		installDir: cfg.InstallDir,
		stdWriter:  cfg.StdWriter,
	}
}

func (p *windowsImageProvider) scriptPath(script string) string {
	return utils.FormatScriptFilePath(filepath.Join(p.installDir, "lib", "scripts", "windows", "host", "image", script))
}

func (p *windowsImageProvider) execPS(psCmd string, params ...string) error {
	result, err := powershell.ExecutePsWithStructuredResult[*psCmdResult](psCmd, "CmdResult", p.stdWriter, params...)
	if err != nil {
		return err
	}
	return result.checkFailure()
}

func (p *windowsImageProvider) List(cfg ImageListConfig) (*ImageListResult, error) {
	psCmd := p.scriptPath("Get-Images.ps1")

	var params []string
	if cfg.IncludeK8sImages {
		params = append(params, "-IncludeK8sImages")
	}
	if cfg.Nodes != "" {
		params = append(params, " -Nodes '"+cfg.Nodes+"'")
	}

	type psImages struct {
		psCmdResult
		ContainerImages []struct {
			ImageId    string `json:"imageid"`
			Repository string `json:"repository"`
			Tag        string `json:"tag"`
			Node       string `json:"node"`
			Size       string `json:"size"`
		} `json:"containerimages"`
		ContainerRegistry *string `json:"containerregistry"`
		PushedImages      []struct {
			Name string `json:"name"`
			Tag  string `json:"tag"`
			Node string `json:"node"`
		} `json:"pushedimages"`
	}

	result, err := powershell.ExecutePsWithStructuredResult[*psImages](psCmd, "StoredImages", p.stdWriter, params...)
	if err != nil {
		return nil, err
	}
	if err := result.checkFailure(); err != nil {
		return nil, err
	}

	listResult := &ImageListResult{}
	if result.ContainerRegistry != nil {
		listResult.ContainerRegistry = *result.ContainerRegistry
	}

	for _, img := range result.ContainerImages {
		listResult.ContainerImages = append(listResult.ContainerImages, ContainerImage{
			ImageId:    img.ImageId,
			Repository: img.Repository,
			Tag:        img.Tag,
			Node:       img.Node,
			Size:       img.Size,
		})
	}

	for _, img := range result.PushedImages {
		listResult.PushedImages = append(listResult.PushedImages, PushedImage{
			Name: img.Name,
			Tag:  img.Tag,
			Node: img.Node,
		})
	}

	return listResult, nil
}

func (p *windowsImageProvider) Pull(cfg ImagePullConfig) error {
	psCmd := p.scriptPath("Pull-Image.ps1")

	var params []string
	params = append(params, " -ImageName "+cfg.ImageName)
	if cfg.Nodes != "" {
		params = append(params, " -Nodes '"+cfg.Nodes+"'")
	}
	if cfg.Windows {
		params = append(params, " -Windows")
	}
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}

	return p.execPS(psCmd, params...)
}

func (p *windowsImageProvider) Remove(cfg ImageRemoveConfig) error {
	psCmd := p.scriptPath("Remove-Image.ps1")

	var params []string
	if cfg.ImageId != "" {
		params = append(params, " -ImageId "+cfg.ImageId)
	}
	if cfg.ImageName != "" {
		params = append(params, " -ImageName "+cfg.ImageName)
	}
	if cfg.Nodes != "" {
		params = append(params, " -Nodes '"+cfg.Nodes+"'")
	}
	if cfg.FromRegistry {
		params = append(params, " -FromRegistry")
	}
	if cfg.Force {
		params = append(params, " -Force")
	}
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}

	return p.execPS(psCmd, params...)
}

func (p *windowsImageProvider) Build(cfg ImageBuildConfig) error {
	psCmd := p.scriptPath("Build-Image.ps1")

	var params []string
	params = append(params, " -InputFolder "+cfg.InputFolder)
	if cfg.Dockerfile != "" {
		params = append(params, " -Dockerfile "+cfg.Dockerfile)
	}
	if cfg.Windows {
		params = append(params, " -Windows")
	}
	if cfg.ImageName != "" {
		params = append(params, " -ImageName "+cfg.ImageName)
	}
	if cfg.Push {
		params = append(params, " -Push")
	}
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}
	if cfg.ImageTag != "" {
		params = append(params, " -ImageTag "+cfg.ImageTag)
	}
	if len(cfg.BuildArgs) > 0 {
		var args []string
		for k, v := range cfg.BuildArgs {
			args = append(args, k+"="+v)
		}
		params = append(params, " -BuildArgs "+strings.Join(args, ","))
	}

	return p.execPS(psCmd, params...)
}

func (p *windowsImageProvider) Import(cfg ImageImportConfig) error {
	psCmd := p.scriptPath("Import-Image.ps1")

	var params []string
	if cfg.TarPath != "" {
		params = append(params, " -ImagePath '"+cfg.TarPath+"'")
	}
	if cfg.DirPath != "" {
		params = append(params, " -ImageDir '"+cfg.DirPath+"'")
	}
	if cfg.Nodes != "" {
		params = append(params, " -Nodes '"+cfg.Nodes+"'")
	}
	if cfg.Windows {
		params = append(params, " -Windows")
	}
	if cfg.DockerArchive {
		params = append(params, " -DockerArchive")
	}
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}

	return p.execPS(psCmd, params...)
}

func (p *windowsImageProvider) Export(cfg ImageExportConfig) error {
	psCmd := p.scriptPath("Export-Image.ps1")

	var params []string
	if cfg.ImageId != "" {
		params = append(params, " -Id '"+cfg.ImageId+"'")
	}
	if cfg.ImageName != "" {
		params = append(params, " -Name '"+cfg.ImageName+"'")
	}
	if cfg.Nodes != "" {
		params = append(params, " -Nodes '"+cfg.Nodes+"'")
	}
	if cfg.OutputPath != "" {
		params = append(params, " -ExportPath '"+cfg.OutputPath+"'")
	}
	if cfg.DockerArchive {
		params = append(params, " -DockerArchive")
	}
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}

	return p.execPS(psCmd, params...)
}

func (p *windowsImageProvider) Tag(cfg ImageTagConfig) error {
	psCmd := p.scriptPath("Tag-Image.ps1")

	var params []string
	if cfg.ImageId != "" {
		params = append(params, " -Id "+cfg.ImageId)
	}
	if cfg.ImageName != "" {
		params = append(params, fmt.Sprintf(" -ImageName '%s'", cfg.ImageName))
	}
	if cfg.Nodes != "" {
		params = append(params, " -Nodes '"+cfg.Nodes+"'")
	}
	if cfg.TargetImageName != "" {
		params = append(params, fmt.Sprintf(" -TargetImageName '%s'", cfg.TargetImageName))
	}
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}

	return p.execPS(psCmd, params...)
}

func (p *windowsImageProvider) Push(cfg ImagePushConfig) error {
	psCmd := p.scriptPath("Push-Image.ps1")

	var params []string
	if cfg.ImageId != "" {
		params = append(params, " -Id "+cfg.ImageId)
	}
	if cfg.ImageName != "" {
		params = append(params, " -ImageName "+cfg.ImageName)
	}
	if cfg.Nodes != "" {
		params = append(params, " -Nodes '"+cfg.Nodes+"'")
	}
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}

	return p.execPS(psCmd, params...)
}

func (p *windowsImageProvider) Clean(cfg ImageCleanConfig) error {
	psCmd := p.scriptPath("Clean-Images.ps1")

	var params []string
	if cfg.Nodes != "" {
		params = append(params, " -Nodes '"+cfg.Nodes+"'")
	}
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}

	return p.execPS(psCmd, params...)
}

func (p *windowsImageProvider) RegistryAdd(cfg ImageRegistryAddConfig) error {
	psCmd := p.scriptPath(filepath.Join("registry", "Add-Registry.ps1"))
	var params []string
	params = append(params, " -RegistryName "+utils.EscapeWithSingleQuotes(cfg.RegistryName))
	if cfg.Username != "" {
		params = append(params, " -Username "+utils.EscapeWithSingleQuotes(cfg.Username))
	}
	if cfg.Password != "" {
		params = append(params, " -Password "+utils.EscapeWithSingleQuotes(cfg.Password))
	}
	if cfg.SkipVerify {
		params = append(params, " -SkipVerify")
	}
	if cfg.PlainHttp {
		params = append(params, " -PlainHttp")
	}
	if cfg.Nodes != "" {
		params = append(params, " -Nodes "+utils.EscapeWithSingleQuotes(cfg.Nodes))
	}
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}
	return p.execPS(psCmd, params...)
}

func (p *windowsImageProvider) RegistryRemove(cfg ImageRegistryRemoveConfig) error {
	psCmd := p.scriptPath(filepath.Join("registry", "Remove-Registry.ps1"))
	var params []string
	params = append(params, " -RegistryName "+utils.EscapeWithSingleQuotes(cfg.RegistryName))
	if cfg.Nodes != "" {
		params = append(params, " -Nodes "+utils.EscapeWithSingleQuotes(cfg.Nodes))
	}
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}
	return p.execPS(psCmd, params...)
}
