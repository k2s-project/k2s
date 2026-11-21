# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Backs up kubevirt addon state (metadata-only).

.DESCRIPTION
The kubevirt addon is an infrastructure-provisioning addon that configures nested
virtualization (Hyper-V), installs QEMU/libvirt packages on the control-plane VM,
deploys the KubeVirt operator and CR, and installs virtctl + VirtViewer on the
Windows host. There are no user-configurable ConfigMaps, Secrets, or
PersistentVolumeClaims to back up.

A backup.json manifest is written for consistency with other addons.

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\kubevirt\Backup.ps1 -BackupDir C:\Temp\kubevirt-backup
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

Write-Log "[AddonBackup] Backing up addon 'kubevirt'" -Console

$addon = [pscustomobject] @{ Name = 'kubevirt' }
if ((Test-IsAddonEnabled -Addon $addon) -ne $true) {
    $errMsg = "Addon 'kubevirt' is not enabled. Enable it before running backup."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-not-enabled' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log "[AddonBackup] kubevirt is an infrastructure addon (nested virtualization, QEMU/libvirt packages, KubeVirt operator/CR, virtctl). No user-configurable state to back up." -Console

if (!(Test-Path -LiteralPath $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

$version = 'unknown'
try { $version = Get-ConfigProductVersion } catch { Write-Log "[AddonBackup] Could not determine K2s version: $_" }

$manifest = [ordered]@{
    k2sVersion     = $version
    addon          = 'kubevirt'
    implementation = 'kubevirt'
    scope          = 'none'
    storageUsage   = 'none'
    files          = @()
    createdAt      = (Get-Date -Format 'o')
    note           = 'Infrastructure-only addon. Re-enable to restore. No user data to back up.'
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $BackupDir 'backup.json') -Encoding utf8

Write-Log "[AddonBackup] kubevirt backup complete (no artifacts to capture)." -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
