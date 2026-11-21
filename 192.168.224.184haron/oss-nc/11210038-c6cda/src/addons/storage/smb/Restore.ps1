# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Restores storage smb configuration and shared-folder data

.DESCRIPTION
Restores the storage smb config snapshot (if present), then re-installs the addon using that config
and finally copies the backed-up shared-folder data back into the configured WinMountPath(s).

Notes:
- The CLI already ensures the addon is disabled before restore, then enables it.
- This script intentionally performs an additional disable/enable cycle (with -Keep) to ensure
  the addon is configured according to the restored config snapshot before data is copied.

.PARAMETER BackupDir
Directory containing extracted backup artifacts (staging folder).

.EXAMPLE
powershell <installation folder>\addons\storage\smb\Restore.ps1 -BackupDir C:\Temp\storage-smb-restore
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Back-up directory to restore data from.')]
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

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

Write-Log "[StorageSmbRestore] Restoring addon 'storage smb'" -Console

if (-not (Test-Path -LiteralPath $BackupDir)) {
    $errMsg = "Restore failed: BackupDir not found: $BackupDir"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

try {
    # 1) Restore config file snapshot (if present)
    $configSnapshotPath = Join-Path $BackupDir 'storage-smb-config.json'
    if (Test-Path -LiteralPath $configSnapshotPath) {
        $configPath = Get-StorageConfigPath
        Write-Log "[StorageSmbRestore] Restoring config snapshot to '$configPath'" -Console
        Copy-Item -LiteralPath $configSnapshotPath -Destination $configPath -Force
    }
    else {
        Write-Log "[StorageSmbRestore] No config snapshot found (storage-smb-config.json); using current config." -Console
    }

    # 2) Determine desired SMB host type from addon config snapshot (best-effort)
    $smbHostType = 'windows'
    $addonConfigSnapshotPath = Join-Path $BackupDir 'storage-smb-addon-config.json'
    if (Test-Path -LiteralPath $addonConfigSnapshotPath) {
        try {
            $cfg = Get-Content -LiteralPath $addonConfigSnapshotPath -Raw | ConvertFrom-Json
            if ($null -ne $cfg -and $null -ne $cfg.SmbHostType) {
                $candidate = ("$($cfg.SmbHostType)".Trim().ToLowerInvariant())
                if ($candidate -eq 'windows' -or $candidate -eq 'linux') {
                    $smbHostType = $candidate
                }
            }
        }
        catch {
            Write-Log "[StorageSmbRestore] Failed to parse storage-smb-addon-config.json; defaulting SMB host type to 'windows'" -Console
        }
    }

    # 3) Re-install addon to apply restored config before copying data
    Write-Log "[StorageSmbRestore] Re-installing addon with -Keep (host type: $smbHostType)" -Console

    $disableResult = Disable-SmbShare -Keep
    if ($disableResult -and $disableResult.Error) {
        throw "Disable-SmbShare failed: $($disableResult.Error.Message)"
    }

    $enableResult = Enable-SmbShare -SmbHostType $smbHostType
    if ($enableResult -and $enableResult.Error) {
        throw "Enable-SmbShare failed: $($enableResult.Error.Message)"
    }

    # 4) Restore shared-folder data
    Restore-AddonData -BackupDir $BackupDir

    Write-Log "[StorageSmbRestore] Restore completed" -Console
}
catch {
    $errMsg = "Restore of addon 'storage smb' failed: $($_.Exception.Message)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
