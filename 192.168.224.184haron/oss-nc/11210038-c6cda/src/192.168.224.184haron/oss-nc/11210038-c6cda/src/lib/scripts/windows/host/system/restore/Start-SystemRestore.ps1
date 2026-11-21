# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

param(
    [string] $BackupFile,
    [switch] $ShowLogs = $false,
    [switch] $ErrorOnFailure = $false,
    [string] $AdditionalHooksDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Modules
Import-Module (Join-Path $PSScriptRoot "..\\..\\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\\..\\..\..\..\modules\windows\cluster\k2s.cluster.module\upgrade\upgrade.module.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\\..\\..\..\..\modules\windows\cluster\k2s.cluster.module\setupinfo\setupinfo.module.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\\..\\..\..\..\modules\windows\cluster\k2s.cluster.module\runningstate\runningstate.module.psm1") -Force

Write-Log "Checking cluster status" -Console

# ------------------------------------------------------------
# Verify K2s is installed
# ------------------------------------------------------------
$setupInfo = Get-SetupInfo
if ($null -eq $setupInfo -or -not $setupInfo.Name) {
    throw "K2s is not installed. Please run 'k2s install' first."
}

Write-Log "Starting system restore" -Console

if (-not (Test-Path $BackupFile)) {
    throw "Backup file not found"
}

$restoreRoot = Get-TempPath
Write-Log "Using temp restore directory" -Console

try
{
    Write-Log "Extracting backup file: $BackupFile"
    Expand-ZipWithProgress -ZipPath $BackupFile -Destination $restoreRoot -Label 'backup' -Show:$ShowLogs
} catch {
    Write-Log "[Restore] Failed to extract backup file: $_" -Console
    throw "Invalid or corrupt backup file. Failed to extract: $_"
}


$manifestPath = Join-Path $restoreRoot "backup.json"
if (-not (Test-Path $manifestPath)) {
    throw "Backup manifest (backup.json) not found in backup file. The backup may be incomplete or corrupted."
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

if ($manifest.apiVersion -ne "k2s.backup/v1") {
    throw "Unsupported backup apiVersion"
}

if ($manifest.kind -ne "SystemBackup") {
    throw "Invalid backup kind"
}

Enable-ClusterIsRunning -ShowLogs:$ShowLogs

$kubePath    = Get-KubePath
$kubectlPath = Get-KubeBinPathGivenKubePath -KubePathLocal $kubePath

# ------------------------------------------------------------
# Restore user workload images
# ------------------------------------------------------------
Write-Log "Restoring user workload images..." -Console

$imagesBackupPath = Join-Path $restoreRoot "images"
if (Test-Path $imagesBackupPath) {
    try {
        $imageRestoreResult = Invoke-ImageRestore -BackupDirectory $imagesBackupPath -ErrorOnFailure:$ErrorOnFailure

        if ($imageRestoreResult.RestoredImages.Count -gt 0) {
            Write-Log "Successfully restored $($imageRestoreResult.RestoredImages.Count) user workload container images" -Console
        } else {
            Write-Log "No images found to restore" -Console
        }

        if ($imageRestoreResult.FailedImages.Count -gt 0) {
            Write-Log "Warning: Failed to restore $($imageRestoreResult.FailedImages.Count) images" -Console
        }
    }
    catch {
        if ($ErrorOnFailure) {
            throw
        }
        Write-Log "Warning: Image restore failed - $_. Continuing with restore..." -Console
    }
} else {
    Write-Log "No image backup found, skipping image restore" -Console
}

Write-Log "Running restore hooks" -Console
Invoke-UpgradeBackupRestoreHooks -HookType Restore -BackupDir (Join-Path $restoreRoot "hooks") -AdditionalHooksDir $AdditionalHooksDir

# ------------------------------------------------------------
# Restore persistent volumes
# ------------------------------------------------------------
Write-Log "Restoring persistent volumes..." -Console

$pvBackupPath = Join-Path $restoreRoot "pv"
if (Test-Path $pvBackupPath) {
    try {
        $pvRestoreResult = Invoke-PVRestore -BackupDirectory $pvBackupPath -Force -ErrorOnFailure:$ErrorOnFailure

        if ($pvRestoreResult.RestoredCount -gt 0) {
            Write-Log "Successfully restored $($pvRestoreResult.RestoredCount) persistent volume(s)" -Console
        } else {
            Write-Log "No persistent volumes found to restore" -Console
        }

        if ($pvRestoreResult.FailedCount -gt 0) {
            Write-Log "Warning: Failed to restore $($pvRestoreResult.FailedCount) persistent volume(s)" -Console
        }
    }
    catch {
        if ($ErrorOnFailure) {
            throw
        }
        Write-Log "Warning: PV restore failed - $_. Continuing with restore..." -Console
    }
} else {
    Write-Log "No PV backup found, skipping PV restore" -Console
}


$notNamespacedDir = Join-Path $restoreRoot "NotNamespaced"
$namespacedDir    = Join-Path $restoreRoot "Namespaced"

# ------------------------------------------------------------
# Restore cluster-scoped resources
# ------------------------------------------------------------
Write-Log "Restoring cluster-scoped resources" -Console

$clusterResult = Import-NotNamespacedResources `
    -folderResources $notNamespacedDir `
    -ExePath $kubectlPath `
    -ShowLogs:$ShowLogs `
    -ErrorOnFailure:$ErrorOnFailure

if ($ErrorOnFailure -and $clusterResult.Errors.Count -gt 0) {
    throw "Cluster-scoped resource restore failed"
}

# ------------------------------------------------------------
# Restore namespaced resources
# ------------------------------------------------------------
Write-Log "Restoring namespaced resources" -Console

$namespacedResult = Import-NamespacedResources `
    -folderNamespaces $namespacedDir `
    -ExePath $kubectlPath `
    -ShowLogs:$ShowLogs `
    -ErrorOnFailure:$ErrorOnFailure

# Collect all errors from both cluster and namespaced restores
$allErrors = @()
$allErrors += $clusterResult.Errors
$allErrors += $namespacedResult.Errors

if ($allErrors.Count -gt 0) {
    Write-Log "⚠️  Restore completed with $($allErrors.Count) error(s)" -Console
    Write-Log "Review errors above and consider re-running restore after fixing issues" -Console

    if ($ErrorOnFailure) {
        throw "System restore finished with errors"
    }
}

Write-Log "System restore completed" -Console
