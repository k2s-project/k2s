# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

param(
    [Parameter(Mandatory = $true)]
    [string] $BackupFile,

    [Parameter(Mandatory = $false)]
    [switch] $ShowLogs = $false,

    [Parameter(Mandatory = $false)]
    [string] $AdditionalHooksDir = '',

    [Parameter(Mandatory = $false)]
    [switch] $SkipImages = $false,

    [Parameter(Mandatory = $false)]
    [switch] $SkipPVs = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot "..\\..\\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\\..\\..\..\..\modules\windows\cluster\k2s.cluster.module\upgrade\upgrade.module.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\\..\\..\..\..\modules\windows\cluster\k2s.cluster.module\setupinfo\setupinfo.module.psm1") -Force

# ------------------------------------------------------------
# Verify K2s is installed
# ------------------------------------------------------------
Write-Log "Checking cluster status" -Console

$setupInfo = Get-SetupInfo
if ($null -eq $setupInfo -or -not $setupInfo.Name) {
    throw "K2s is not installed. Please run 'k2s install' first."
}

Write-Log "Starting K2s system backup..." -Console

# ------------------------------------------------------------
# Validate backup file path early (fail fast on invalid paths)
# ------------------------------------------------------------
# First check for obvious invalid patterns (Unix paths, invalid characters)
if ($BackupFile.StartsWith('/')) {
    throw "Invalid backup path: '$BackupFile'. Unix-style paths (/) are not supported on Windows. Use Windows paths (e.g., C:\path\to\backup.zip)"
}

if ($BackupFile -match '^\\\\[^\\]*$') {
    throw "Invalid backup path: '$BackupFile'. Incomplete UNC path. Use full UNC path (\\server\share\path) or local path (C:\path)"
}

try {
    # Test if path can be resolved
    $resolvedPath = [System.IO.Path]::GetFullPath($BackupFile)

    # Check if it's a valid Windows path format (must have drive letter)
    if ($resolvedPath -notmatch '^[a-zA-Z]:\\') {
        throw "Path resolved to invalid format: '$resolvedPath'. Must be a Windows path with drive letter"
    }

    # Verify drive exists
    $drive = $resolvedPath.Substring(0, 3) # e.g., "C:\"
    if (-not (Test-Path $drive)) {
        throw "Drive not accessible or does not exist: $drive"
    }
} catch {
    throw "Invalid backup file path: '$BackupFile'. $_"
}

# ------------------------------------------------------------
# Prepare backup directory based on BackupFile location
# ------------------------------------------------------------
# Extract the directory from the BackupFile path
$backupDir = Split-Path -Path $BackupFile -Parent
if ([string]::IsNullOrWhiteSpace($backupDir)) {
    # Relative path with no directory component, use current directory
    $backupDir = Get-Location | Select-Object -ExpandProperty Path
    Write-Log "Using current directory for backup: $backupDir"
} else {
    if (-not (Test-Path $backupDir)) {
        try {
            New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
            Write-Log "Created backup directory: $backupDir"
        } catch {
            throw "Failed to create backup directory '$backupDir'. Error: $_"
        }
    }
}

# Create a temporary staging directory within the backup directory
$backupRoot = Join-Path $backupDir "k2s-backup-staging-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
Write-Log "Using backup staging directory: $backupRoot"

# ------------------------------------------------------------
# Resolve kube paths (once, reuse)
# ------------------------------------------------------------
$kubePath    = Get-KubePath
$kubeExePath = Get-KubeBinPathGivenKubePath -KubePathLocal $kubePath


# ------------------------------------------------------------
# Export cluster resources (no cluster start/stop)
# ------------------------------------------------------------
Write-Log "Exporting cluster resources..."

# Temporarily allow kubectl warnings to not fail the backup
$previousErrorAction = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'

    Export-ClusterResources `
        -SkipResources:$false `
        -PathResources $backupRoot `
        -ExePath $kubeExePath

    $ErrorActionPreference = $previousErrorAction
}
catch {
    $ErrorActionPreference = $previousErrorAction

    # Only fail if it's a real error, not just warnings
    if ($_.Exception.Message -notmatch "Warning:" -and $_.Exception.Message -notmatch "deprecated") {
        throw $_
    }
    else {
        Write-Log "Kubectl warnings encountered during export (non-fatal): $_" -Console
    }
}

# ------------------------------------------------------------
# Determine included namespaces from exported content
# ------------------------------------------------------------
$namespacedDir = Join-Path $backupRoot "Namespaced"
$includedNamespaces = @()

if (Test-Path $namespacedDir) {
    $includedNamespaces = Get-ChildItem -Path $namespacedDir -Directory |
            Select-Object -ExpandProperty Name
}

# ------------------------------------------------------------
# Execute backup hooks (if any)
# ------------------------------------------------------------
$hooksBackupPath = Join-Path $backupRoot "hooks"
New-Item -ItemType Directory -Path $hooksBackupPath -Force | Out-Null

try {
    Invoke-UpgradeBackupRestoreHooks `
        -HookType Backup `
        -BackupDir $hooksBackupPath `
        -ShowLogs:$ShowLogs `
        -AdditionalHooksDir $AdditionalHooksDir

    Write-Log "Backup hooks executed successfully" -Console
}
catch {
    throw "Backup hooks execution failed: $_"
}

# ------------------------------------------------------------
# Backup persistent volumes
# ------------------------------------------------------------
if ($SkipPVs) {
    Write-Log "Skipping PV backup as requested" -Console
} else {
    Write-Log "Backing up persistent volumes..." -Console
    $pvBackupPath = Join-Path $backupRoot "pv"

    try {
        $pvBackupResult = Invoke-PVBackup -BackupDirectory $pvBackupPath

        if ($null -eq $pvBackupResult) {
            throw "PV backup operation returned no result. This indicates a critical failure in the backup process."
        }

        if (-not $pvBackupResult.Success) {
            throw "PV backup failed. Backed up $($pvBackupResult.BackedUpCount) volume(s) but encountered errors. Use -SkipPVs to exclude PVs from backup."
        }

        Write-Log "Successfully backed up $($pvBackupResult.BackedUpCount) persistent volume(s)" -Console
    }
    catch {
        throw "PV backup operation failed: $_"
    }
}

# ------------------------------------------------------------
# Backup user workload images (excluding addon images)
# ------------------------------------------------------------
if ($SkipImages) {
    Write-Log "Skipping image backup as requested" -Console
} else {
    Write-Log "Backing up user workload images..." -Console
    $imagesBackupPath = Join-Path $backupRoot "images"

    try {
        # For system backup, exclude addon images (they're handled by addon backup)
        $imageBackupResult = Invoke-ImageBackup -BackupDirectory $imagesBackupPath -ExcludeAddonImages

        if ($null -eq $imageBackupResult) {
            throw "Image backup operation returned no result. This indicates a critical failure in the backup process."
        }

        if (-not $imageBackupResult.Success) {
            throw "Image backup failed. Backed up $($imageBackupResult.Images.Count) image(s) but encountered errors. Use -SkipImages to exclude images from backup."
        }

        Write-Log "Successfully backed up $($imageBackupResult.Images.Count) user workload container images" -Console
    }
    catch {
        throw "Image backup operation failed: $_"
    }
}

# ------------------------------------------------------------
# Snapshot config.json separately (human-friendly design)
# ------------------------------------------------------------
$configBackupDir = Join-Path $backupRoot "config"
New-Item -ItemType Directory -Path $configBackupDir -Force | Out-Null

$configSourcePath = Join-Path $kubePath "cfg\config.json"
$configTargetPath = Join-Path $configBackupDir "config.json"

if (Test-Path $configSourcePath) {
    Copy-Item $configSourcePath -Destination $configTargetPath -Force
} else {
    Write-Log "Warning: config.json not found at $configSourcePath"
}

# ------------------------------------------------------------
# Create backup.json manifest (CLEAN + READABLE)
# ------------------------------------------------------------
Write-Log "Creating backup metadata (backup.json)..."

try {
    $rootConfig  = Get-RootConfigk2s
    $clusterName = Get-ClusterName
    $productVersion = Get-ProductVersion

    # Build excluded lists safely (handle missing backup config section)
    $excludedNamespaces = @()
    $excludedNamespacedRes = @()
    $excludedClusterRes = @()
    if ($rootConfig.backup) {
        if ($rootConfig.backup.excludednamespaces) {
            $excludedNamespaces = ($rootConfig.backup.excludednamespaces -split ",")
        }
        if ($rootConfig.backup.excludednamespacedresources) {
            $excludedNamespacedRes = ($rootConfig.backup.excludednamespacedresources -split ",")
        }
        if ($rootConfig.backup.excludedclusterresources) {
            $excludedClusterRes = ($rootConfig.backup.excludedclusterresources -split ",")
        }
    } else {
        Write-Log "Warning: No 'backup' section found in root config. Using empty exclusion lists."
    }

    $backupManifest = @{
        apiVersion = "k2s.backup/v1"
        kind       = "SystemBackup"

        metadata = @{
            backupTimestamp     = (Get-Date).ToString("o")
            backupTool          = "k2s system backup"
            backupToolVersion   = $productVersion
            backupFormatVersion = "1"
        }

        cluster = @{
            name       = $clusterName
            k2sVersion = $productVersion
        }

        content = @{
            included = @{
                clusterResources = $true
                namespaces       = $includedNamespaces
            }
            excluded = @{
                namespaces          = $excludedNamespaces
                namespacedResources = $excludedNamespacedRes
                clusterResources    = $excludedClusterRes
            }
        }

        configSnapshot = @{
            source = "config/config.json"
        }
    }

    $metadataPath = Join-Path $backupRoot "backup.json"
    $backupManifest |
            ConvertTo-Json -Depth 10 |
            Out-File -FilePath $metadataPath -Encoding utf8

    if (-not (Test-Path $metadataPath)) {
        throw "backup.json was not created at '$metadataPath' despite no write error"
    }
    Write-Log "backup.json created successfully at: $metadataPath"
}
catch {
    throw "Failed to create backup.json manifest: $_"
}

# ------------------------------------------------------------
# Verify staging directory contents before zipping
# ------------------------------------------------------------
$stagingFiles = Get-ChildItem -Path $backupRoot -Recurse -File
Write-Log "Staging directory contains $($stagingFiles.Count) file(s):"
foreach ($sf in $stagingFiles) {
    $relPath = $sf.FullName.Substring($backupRoot.Length).TrimStart('\', '/')
    Write-Log "  $relPath ($($sf.Length) bytes)"
}

if (-not (Test-Path (Join-Path $backupRoot 'backup.json'))) {
    throw "Critical: backup.json is missing from staging directory '$backupRoot'. Cannot create backup archive."
}

# ------------------------------------------------------------
# Create final ZIP archive
# ------------------------------------------------------------
Write-Log "Creating backup archive: $BackupFile" -Console

if (Test-Path $BackupFile) {
    Write-Log "Removing existing backup file: $BackupFile"
    Remove-Item $BackupFile -Force
}

New-ZipWithProgress -SourceDir $backupRoot -ZipPath $BackupFile -Label 'backup' -Show:$ShowLogs

Write-Log "System backup completed successfully." -Console
Write-Log "Backup file created at: $BackupFile" -Console

# ------------------------------------------------------------
# Cleanup staging directory
# ------------------------------------------------------------
try {
    Write-Log "Cleaning up staging directory: $backupRoot"
    Remove-Item -Path $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Staging directory cleaned up successfully"
}
catch {
    Write-Log "Warning: Failed to clean up staging directory: $_"
}

