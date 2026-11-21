# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
List all container images present in K2s

.DESCRIPTION
List all container images present in K2s

.PARAMETER EncodeStructuredOutput
If set to true, will encode and send result as structured data to the CLI

.PARAMETER MessageType
Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true

.PARAMETER IncludeK8sImages
If set to true, will list K8s images as well

.PARAMETER ExcludeAddonImages
If set to true, will exclude addon images from excluded namespaces (for system backup)

.PARAMETER Nodes
Optional comma-separated node names to fetch images from (e.g. "worker-1,worker-2")

.PARAMETER Node
Optional single node name to fetch images from (e.g. "worker-1")

.PARAMETER CrictlExePath
Optional path to crictl.exe; overrides the module-scope default (use during upgrade to supply the installed cluster path)

.PARAMETER CrictlConfigPath
Optional path to crictl.yaml config; overrides the module-scope default (use during upgrade to supply the installed cluster path)

.EXAMPLE
# Outputs all container images present in K2s
PS> .\Get-Images.ps1

.EXAMPLE
# Outputs all container images present in K2s including K8s images and will encode and send result as structured data to the CLI
PS> .\Get-Images.ps1 -IncludeK8sImages -EncodeStructuredOutput -MessageType my-images

.EXAMPLE
# Outputs only user workload container images (excludes infrastructure and addon images)
PS> .\Get-Images.ps1 -ExcludeAddonImages
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false)]
    [switch] $IncludeK8sImages,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will exclude addon images from excluded namespaces')]
    [switch] $ExcludeAddonImages,
    [parameter(Mandatory = $false, HelpMessage = 'Optional single node name to fetch images from (e.g. worker-1)')]
    [string] $Node = '',
    [parameter(Mandatory = $false, HelpMessage = 'Optional comma-separated node names to fetch images from (e.g. worker-1,worker-2)')]
    [string] $Nodes = '',
    [parameter(Mandatory = $false, HelpMessage = 'Optional path to crictl.exe; overrides the module-scope default (use during upgrade to supply the installed cluster path)')]
    [string] $CrictlExePath = '',
    [parameter(Mandatory = $false, HelpMessage = 'Optional path to crictl.yaml config; overrides the module-scope default (use during upgrade to supply the installed cluster path)')]
    [string] $CrictlConfigPath = ''
)
$imageCommonModule = "$PSScriptRoot/Image-Common.module.psm1"
Import-Module $imageCommonModule

$script = $MyInvocation.MyCommand.Name

$crictlOverride = if ($CrictlExePath -ne '') { " and CrictlExePath='$CrictlExePath' and CrictlConfigPath='$CrictlConfigPath'" } else { '' }
Write-Log "[$script] started with EncodeStructuredOutput='$EncodeStructuredOutput' and MessageType='$MessageType' and IncludeK8sImages='$IncludeK8sImages' and ExcludeAddonImages='$ExcludeAddonImages' and Node='$Node' and Nodes='$Nodes'$crictlOverride"

try {
    if (-not (Initialize-ImageScriptContext -EncodeStructuredOutput:$EncodeStructuredOutput -MessageType $MessageType)) {
        return
    }

    $imageSelection = Get-ImagesByNodeSelection `
        -Nodes $Nodes `
        -Node $Node `
        -IncludeK8sImages $IncludeK8sImages `
        -ExcludeAddonImages $ExcludeAddonImages `
        -LogPrefix $script `
        -CrictlExePath $CrictlExePath `
        -CrictlConfigPath $CrictlConfigPath

    $allImages = @($imageSelection.AllImages)

    Write-Log "[$script] Total images collected: $($allImages.Count)"

    $images = @{Error = $null }
    $images.ContainerImages = $allImages
    $images.ContainerRegistry = $(Get-RegistriesFromSetupJson) | Where-Object { $_ -match 'k2s.registry.*' }
    $images.PushedImages = @(Get-PushedContainerImages)

    if ($EncodeStructuredOutput) {
        Send-ToCli -MessageType $MessageType -Message $images
    }
    else {
        $images
    }

    Write-Log "[$script] finished"
}
catch {
    Write-Log "[$script] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}
