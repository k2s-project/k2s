# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Backs up storage smb configuration and shared-folder data

.DESCRIPTION
Creates a backup in a staging folder. The CLI wraps the staging folder into a zip archive.

This backup contains:
- A snapshot of the storage smb config file (SmbStorage.json)
- A snapshot of the addon entry from setup.json (best-effort)
- The contents of the configured Windows mount path(s) (WinMountPath)

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\storage\smb\Backup.ps1 -BackupDir C:\Temp\storage-smb-backup
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

$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot/../../addons.module.psm1"
$smbShareModule = "$PSScriptRoot/module/Smb-share.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $smbShareModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "[StorageSmbBackup] Backing up addon 'storage smb'" -Console

# Best-effort only: allow backing up local data even if cluster isn't running
$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Write-Log "[StorageSmbBackup] Note: system not available ($($systemError.Message)). Backing up local data only." -Console
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

$files = @()

try {
    # 1) Snapshot config file
    $configPath = Get-StorageConfigPath
    $configSnapshotPath = Join-Path $BackupDir 'storage-smb-config.json'

    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Storage SMB config file not found: $configPath"
    }

    Copy-Item -LiteralPath $configPath -Destination $configSnapshotPath -Force
    $files += (Split-Path -Leaf $configSnapshotPath)

    # 2) Snapshot addon config from setup.json (best-effort)
    $addonConfigSnapshotPath = Join-Path $BackupDir 'storage-smb-addon-config.json'

    $storageAddonConfig = Get-AddonConfig -Name 'storage'
    if ($null -ne $storageAddonConfig -and ($null -eq $storageAddonConfig.Implementation -or $storageAddonConfig.Implementation -eq 'smb')) {
        $storageAddonConfig | ConvertTo-Json -Depth 100 | Set-Content -Path $addonConfigSnapshotPath -Encoding UTF8 -Force
        $files += (Split-Path -Leaf $addonConfigSnapshotPath)
    }
    else {
        Write-Log "[StorageSmbBackup] No matching addon config entry found in setup.json (or implementation is not 'smb'); skipping addon-config snapshot." -Console
    }

    # 3) Copy share data (WinMountPath) into staging dir
    Backup-AddonData -BackupDir $BackupDir
    $files += 'storage-smb'
}
catch {
    $errMsg = "Backup of addon 'storage smb' failed: $($_.Exception.Message)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-backup-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$version = 'unknown'
try {
    $version = Get-ConfigProductVersion
}
catch {
    # best-effort only
}

$manifest = [pscustomobject]@{
    k2sVersion     = $version
    addon          = 'storage'
    implementation = 'smb'
    files          = $files
    createdAt      = (Get-Date).ToString('o')
}

$manifestPath = Join-Path $BackupDir 'backup.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8 -Force

Write-Log "[StorageSmbBackup] Backup artifacts prepared" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
