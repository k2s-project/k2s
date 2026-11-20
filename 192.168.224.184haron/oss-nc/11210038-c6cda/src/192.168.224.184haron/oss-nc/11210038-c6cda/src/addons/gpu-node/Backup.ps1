# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Backs up gpu-node addon state (no-op).

.DESCRIPTION
The gpu-node addon is a pure infrastructure-provisioning addon that configures
Hyper-V GPU passthrough, installs NVIDIA drivers/kernel/toolkit on the control-plane
VM, and deploys static Kubernetes manifests. There are no user-configurable
ConfigMaps, Secrets, or PersistentVolumeClaims to back up.

A backup.json manifest is written for consistency with other addons.

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\gpu-node\Backup.ps1 -BackupDir C:\Temp\gpu-node-backup
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Directory where backup files will be written')]
    [string] $BackupDir,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

Write-Log "[AddonBackup] Backing up addon 'gpu-node'" -Console

$addon = [pscustomobject] @{ Name = 'gpu-node' }
if ((Test-IsAddonEnabled -Addon $addon) -ne $true) {
    $errMsg = "Addon 'gpu-node' is not enabled. Enable it before running backup."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-not-enabled' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log "[AddonBackup] gpu-node is a pure infrastructure addon (GPU passthrough, drivers, toolkit, static manifests). No user-configurable state to back up." -Console

if (!(Test-Path -LiteralPath $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

$version = 'unknown'
try { $version = Get-ConfigProductVersion } catch { Write-Log "[AddonBackup] Could not determine K2s version: $_" }

$manifest = [ordered]@{
    k2sVersion     = $version
    addon          = 'gpu-node'
    implementation = 'gpu-node'
    scope          = 'none'
    storageUsage   = 'none'
    files          = @()
    createdAt      = (Get-Date -Format 'o')
    note           = 'Infrastructure-only addon. Re-enable to restore. No user data to back up.'
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $BackupDir 'backup.json') -Encoding utf8

Write-Log "[AddonBackup] gpu-node backup complete (no artifacts to capture)." -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
