# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Image backup and restore functionality for K2s cluster upgrades

.DESCRIPTION
This module provides image backup and restore functionality during K2s cluster upgrades.
It backs up user application images before upgrade and restores them after successful upgrade.
#>

Import-Module "$PSScriptRoot\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"

<#
.SYNOPSIS
Creates an empty backup manifest for when no images are found

.DESCRIPTION
Helper function that creates a standard empty backup result structure

.PARAMETER BackupDirectory
Directory where the backup would be stored

.OUTPUTS
Empty backup manifest object
#>
function New-EmptyBackupResult {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BackupDirectory,
        
        [Parameter(Mandatory = $false)]
        [scriptblock] $DateTimeProvider = { Get-Date -Format "yyyy-MM-dd HH:mm:ss" }
    )
    
    Write-Log "No images to backup" -Console
    $result = @{
        BackupTimestamp = & $DateTimeProvider
        BackupDirectory = $BackupDirectory
        Images = @()
        Success = $true
    }
    $result.Images = @($result.Images)  
    return $result
}

<#
.SYNOPSIS
Creates backup directory structure if it doesn't exist

.DESCRIPTION
Helper function to ensure backup directories exist before starting backup operations

.PARAMETER BackupDirectory
Main backup directory path

.PARAMETER CreateImagesSubdir
If true, also creates an 'images' subdirectory

.PARAMETER FileSystemProvider
Provider for file system operations (for testing)

.OUTPUTS
None
#>
function New-BackupDirectoryStructure {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BackupDirectory,
        
        [Parameter(Mandatory = $false)]
        [switch] $CreateImagesSubdir,
        
        [Parameter(Mandatory = $false)]
        [hashtable] $FileSystemProvider = @{
            TestPath = { param($path) Test-Path $path }
            NewItem = { param($path, $type) New-Item -ItemType $type -Path $path -Force | Out-Null }
            JoinPath = { param($parent, $child) Join-Path $parent $child }
        }
    )
    
    # Create main backup directory
    if (-not (& $FileSystemProvider.TestPath $BackupDirectory)) {
        Write-Log "Creating backup directory: $BackupDirectory"
        & $FileSystemProvider.NewItem $BackupDirectory "Directory"
    }
    
    # Create images subdirectory if requested
    if ($CreateImagesSubdir) {
        $imagesDir = & $FileSystemProvider.JoinPath $BackupDirectory "images"
        if (-not (& $FileSystemProvider.TestPath $imagesDir)) {
            Write-Log "Creating images directory: $imagesDir"
            & $FileSystemProvider.NewItem $imagesDir "Directory"
        }
    }
}

<#
.SYNOPSIS
Creates standardized log files for image processing operations

.DESCRIPTION
Helper function to create consistent log files for backup and restore operations

.PARAMETER LogPath
Full path where the log file will be created

.PARAMETER LogType
Type of operation: "Backup" or "Restore"

.PARAMETER Result
Result object containing processing details

.PARAMETER OriginalTimestamp
Original backup timestamp (for restore operations)
#>
function New-ImageProcessingLog {
    param(
        [Parameter(Mandatory = $true)]
        [string] $LogPath,
        
        [Parameter(Mandatory = $true)]
        [string] $LogType,
        
        [Parameter(Mandatory = $true)]
        [hashtable] $Result,
        
        [Parameter(Mandatory = $false)]
        [string] $OriginalTimestamp
    )
    
    # Log summary to console with timestamps
    Write-Log "=== K2s Image $LogType Summary ===" -Console
    Write-Log "$LogType Date: $($Result."${LogType}Timestamp")" -Console
    if ($OriginalTimestamp) {
        Write-Log "Original Backup Date: $OriginalTimestamp" -Console
    }
    Write-Log "Total Images: $($Result.Images.Count + $Result.FailedImages.Count)" -Console
    Write-Log "Successful ${LogType}s: $($Result.Images.Count)" -Console
    Write-Log "Failed ${LogType}s: $($Result.FailedImages.Count)" -Console

    if ($Result.Images.Count -gt 0) {
        Write-Log "${LogType}d Images:" -Console
        foreach ($img in $Result.Images) {
            Write-Log "[OK] $($img.Repository):$($img.Tag) (ID: $($img.ImageId))" -Console
        }
    }

    if ($Result.FailedImages.Count -gt 0) {
        Write-Log "Failed Images:" -Console
        foreach ($img in $Result.FailedImages) {
            Write-Log "[FAIL] $($img.Repository):$($img.Tag) (ID: $($img.ImageId)) - Error: $($img.Error)" -Console
        }
    }
    
    # Create file content for log file
    $logContent = @"
K2s Image $LogType Log
$('=' * (15 + $LogType.Length))
$LogType Date: $($Result."${LogType}Timestamp")
$(if ($OriginalTimestamp) { "Original Backup Date: $OriginalTimestamp" })
Total Images: $($Result.Images.Count + $Result.FailedImages.Count)
Successful ${LogType}s: $($Result.Images.Count)
Failed ${LogType}s: $($Result.FailedImages.Count)

${LogType}d Images:
"@
    
    foreach ($img in $Result.Images) {
        $logContent += "`n- $($img.Repository):$($img.Tag) (ID: $($img.ImageId))"
    }
    
    if ($Result.FailedImages.Count -gt 0) {
        $logContent += "`n`nFailed Images:"
        foreach ($img in $Result.FailedImages) {
            $logContent += "`n- $($img.Repository):$($img.Tag) (ID: $($img.ImageId)) - Error: $($img.Error)"
        }
    }
    
    $logContent | Out-File -FilePath $LogPath -Encoding UTF8
    Write-Log "Log file created: $LogPath" -Console
}

<#
.SYNOPSIS
Executes K2s image commands with standardized error handling

.DESCRIPTION
Helper function to execute k2s image export/import commands with consistent error handling.
Uses proper argument arrays to handle executable paths with spaces correctly.

.PARAMETER K2sExecutable
The path to the k2s executable

.PARAMETER Arguments
Array of command arguments to pass to k2s

.PARAMETER ImageName
Name of the image being processed (for error messages)

.PARAMETER ExpectedFile
Optional file path that should be created by the command

.PARAMETER CommandExecutor
Script block for executing commands (for testing)
#>
function Invoke-K2sImageCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $K2sExecutable,
        
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,
        
        [Parameter(Mandatory = $true)]
        [string] $ImageName,
        
        [Parameter(Mandatory = $false)]
        [string] $ExpectedFile,
        
        [Parameter(Mandatory = $false)]
        [scriptblock] $CommandExecutor = { 
            param($exe, $arguments) 
            Write-Log "Executing: $exe with arguments: $($arguments -join ' ')"
            & $exe $arguments 2>&1 
        }
    )
    
    Write-Log "Executing k2s command for image: $ImageName"
    $result = & $CommandExecutor $K2sExecutable $Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE : $result"
    }
    
    # Verify expected file if specified
    if ($ExpectedFile) {
        if (-not (Test-Path $ExpectedFile)) {
            throw "Expected file was not created: $ExpectedFile"
        }
        
        if ((Get-Item $ExpectedFile).Length -eq 0) {
            throw "Created file is empty: $ExpectedFile"
        }
    }
    
    # Don't return the command result to avoid polluting the pipeline
    # Just return success indication or nothing
}

<#
.SYNOPSIS
Writes progress messages for image processing operations

.DESCRIPTION
Helper function to provide consistent progress tracking during backup/restore operations

.PARAMETER Current
Current image number being processed

.PARAMETER Total
Total number of images to process

.PARAMETER Action
Action being performed ("Backing up" or "Restoring")

.PARAMETER Image
Image object being processed
#>
function Write-ProcessingProgress {
    param(
        [Parameter(Mandatory = $true)]
        [int] $Current,
        
        [Parameter(Mandatory = $true)]
        [int] $Total,
        
        [Parameter(Mandatory = $true)]
        [string] $Action,
        
        [Parameter(Mandatory = $true)]
        [object] $Image
    )
    
    Write-Log "[$Current/$Total] $Action image: $($Image.repository):$($Image.tag)" -Console
}

<#
.SYNOPSIS
Validates input parameters for image operations

.DESCRIPTION
Helper function to validate common input parameters for backup/restore operations

.PARAMETER BackupDirectory
Directory path to validate

.PARAMETER Images
Images array to validate

.PARAMETER RequiredSpaceGB
Required space to validate

.OUTPUTS
Validation result object
#>
function Test-ImageOperationParameters {
    param(
        [Parameter(Mandatory = $false)]
        [string] $BackupDirectory,
        
        [Parameter(Mandatory = $false)]
        [array] $Images,
        
        [Parameter(Mandatory = $false)]
        [int] $RequiredSpaceGB
    )
    
    $validationResult = @{
        IsValid = $true
        Errors = @()
    }
    
    if ($BackupDirectory -ne $null) {
        if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
            $validationResult.IsValid = $false
            $validationResult.Errors += "BackupDirectory cannot be empty or whitespace"
        }
        else {
            # Validate path format
            try {
                [System.IO.Path]::GetFullPath($BackupDirectory) | Out-Null
            }
            catch {
                $validationResult.IsValid = $false
                $validationResult.Errors += "BackupDirectory contains invalid path characters"
            }
        }
    }
    
    if ($Images -ne $null -and $Images.Count -gt 0) {
        for ($i = 0; $i -lt $Images.Count; $i++) {
            $image = $Images[$i]
            if (-not $image.repository -or -not $image.tag -or -not $image.imageid) {
                $validationResult.IsValid = $false
                $validationResult.Errors += "Image at index $i is missing required properties (repository, tag, imageid)"
            }
        }
    }
    
    if ($RequiredSpaceGB -and $RequiredSpaceGB -lt 0) {
        $validationResult.IsValid = $false
        $validationResult.Errors += "RequiredSpaceGB must be a positive number"
    }
    
    return $validationResult
}

<#
.SYNOPSIS
Gets list of images in the cluster

.DESCRIPTION
By default returns only user application images. Use -IncludeSystemImages to get all images.

.PARAMETER IncludeSystemImages
If set to true, includes system/infrastructure images in the list

.OUTPUTS
Array of image objects with metadata
#>
function Get-K2sImageList {
    param(
        [Parameter(Mandatory = $false)]
        [switch] $IncludeSystemImages,

        [Parameter(Mandatory = $false)]
        [switch] $ExcludeAddonImages,

        [Parameter(Mandatory = $false)]
        [string] $CrictlExePath = '',

        [Parameter(Mandatory = $false)]
        [string] $CrictlConfigPath = ''
    )
    
    Write-Log "Discovering images in the cluster..." -Console

    try {
        # Use the existing Get-Images.ps1 script which already has proper filtering logic
        $getImagesScript = "$PSScriptRoot\..\..\..\..\..\scripts\windows\host\image\Get-Images.ps1"
        
        if (-not (Test-Path $getImagesScript)) {
            Write-Log "Get-Images.ps1 script not found at: $getImagesScript" -Console
            return ,@()
        }
        
        # Build command arguments based on parameters using hashtable for proper splatting
        $scriptArgs = @{}
        if ($IncludeSystemImages) {
            $scriptArgs['IncludeK8sImages'] = $true
            $imageType = "all images including system images"
            $resultType = "total images"
        }
        if ($ExcludeAddonImages) {
            $scriptArgs['ExcludeAddonImages'] = $true
            $imageType = "user workload images only (excluding system and addon images)"
            $resultType = "user workload images"
            Write-Log "[ImageBackup] Adding -ExcludeAddonImages flag to Get-Images.ps1"
        } else {
            $imageType = "user application images only (excluding system images)"
            $resultType = "user application images"
        }
        
        if (-not [string]::IsNullOrWhiteSpace($CrictlExePath)) {
            $scriptArgs['CrictlExePath'] = $CrictlExePath
        }
        if (-not [string]::IsNullOrWhiteSpace($CrictlConfigPath)) {
            $scriptArgs['CrictlConfigPath'] = $CrictlConfigPath
        }

        Write-Log "Getting $imageType" -Console

        if (-not [string]::IsNullOrWhiteSpace($CrictlExePath)) {
            Import-Module "$PSScriptRoot\image.module.psm1" -Force -Global
        }

        $imageResult = & $getImagesScript @scriptArgs
        
        $images = $imageResult.ContainerImages
        if (-not $images) {
            Write-Log "No container images found in cluster" -Console
            return ,@()
        }
        
        Write-Log "Found $($images.Count) $resultType" -Console
        
        return ,$images
    }
    catch {
        Write-Log "Error discovering images: $_" -Console
        return ,@()
    }
}

<#
.SYNOPSIS
Backs up user application images before cluster upgrade

.DESCRIPTION
Exports user application images to tar files and creates a manifest with metadata

.PARAMETER BackupDirectory
Directory where to store the backed up images

.PARAMETER Images
Array of image objects to backup

.OUTPUTS
Backup manifest object with image metadata
#>
function Backup-K2sImages {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BackupDirectory,
        
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [array] $Images = @(),

        [Parameter(Mandatory = $false)]
        [string] $CrictlExePath = '',

        [Parameter(Mandatory = $false)]
        [string] $CrictlConfigPath = '',

        [Parameter(Mandatory = $false)]
        [string] $ExportImageScriptPath = "$PSScriptRoot\..\..\..\..\..\scripts\windows\host\image\Export-Image.ps1"
    )
    
    Write-Log "Starting image backup to directory: $BackupDirectory" -Console

    if ($Images.Count -eq 0) {
        return New-EmptyBackupResult -BackupDirectory $BackupDirectory
    }
    
    try {
        # Create backup directory structure
        New-BackupDirectoryStructure -BackupDirectory $BackupDirectory -CreateImagesSubdir
        
        $imagesDir = Join-Path $BackupDirectory "images"
        
        $exportImageScript = $ExportImageScriptPath
        if (-not (Test-Path $exportImageScript)) {
            throw "Export-Image.ps1 not found at '$exportImageScript'"
        }

        $resolvedCrictlExe = if ($CrictlExePath -ne '') { $CrictlExePath } else { Get-CrictlExePath }
        $resolvedCrictlConfig = if ($CrictlConfigPath -ne '') { $CrictlConfigPath } else {
            Join-Path (Split-Path $resolvedCrictlExe -Parent) 'crictl.yaml'
        }
        $resolvedNerdctlExe = if ($CrictlExePath -ne '') { Join-Path (Split-Path $resolvedCrictlExe -Parent) 'nerdctl.exe' } else { "$((Get-KubeBinPath))\nerdctl.exe" }
        $resolvedCtrExe = if ($CrictlExePath -ne '') { Join-Path (Split-Path $resolvedCrictlExe -Parent) 'containerd\ctr.exe' } else { "$((Get-KubeBinPath))\containerd\ctr.exe" }
        $backupManifest = @{
            BackupTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            BackupDirectory = $BackupDirectory
            Images = @()
            FailedImages = @()
            Success = $true
        }
        
        $totalImages = $Images.Count
        $currentImage = 0
        $usedFileNames = @{}
        
        foreach ($image in $Images) {
            $currentImage++
            
            Write-ProcessingProgress -Current $currentImage -Total $totalImages -Action "Backing up" -Image $image
            
            try {
                # Generate safe filename for tar archive
                $safeFileName = "$($image.repository -replace '[/\\:*?"<>|]', '_')-$($image.tag -replace '[/\\:*?"<>|]', '_')"
                # The same image can exist on several nodes (e.g. linkerd proxy on Linux and Windows); keep one tar per node
                if ($usedFileNames.ContainsKey($safeFileName) -and -not [string]::IsNullOrWhiteSpace("$($image.node)")) {
                    $safeFileName = "$safeFileName-$($image.node -replace '[/\\:*?"<>|]', '_')"
                }
                $usedFileNames[$safeFileName] = $true
                $tarPath = Join-Path $imagesDir "$safeFileName.tar"

                # Scope the export to the image's node; otherwise Export-Image.ps1 renames the output when the image exists on both OSes
                $exportNodeArgs = @{}
                if (-not [string]::IsNullOrWhiteSpace("$($image.node)")) {
                    $exportNodeArgs['Nodes'] = "$($image.node)"
                }

                & $exportImageScript `
                    -Name "$($image.repository):$($image.tag)" `
                    -ExportPath $tarPath `
                    -CrictlExePath $resolvedCrictlExe `
                    -CrictlConfigPath $resolvedCrictlConfig `
                    -NerdctlExePath $resolvedNerdctlExe `
                    -CtrExePath $resolvedCtrExe `
                    @exportNodeArgs
                
                if (-not (Test-Path $tarPath)) {
                    throw "Export-Image.ps1 did not produce $tarPath for image $($image.repository):$($image.tag)"
                }

                $relativeTarPath = "images\images\$safeFileName.tar"
                $imageBackupInfo = @{
                    ImageId = $image.imageid
                    Repository = $image.repository
                    Tag = $image.tag
                    Node = $image.node
                    Size = $image.size
                    TarFile = $relativeTarPath
                    BackupTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                }
                $backupManifest.Images += $imageBackupInfo
                Write-Log "Successfully backed up image: $($image.repository):$($image.tag)"
            }
            catch {
                Write-Log "Failed to backup image $($image.repository):$($image.tag) - $_" -Console
                $backupManifest.FailedImages += @{
                    ImageId = $image.imageid
                    Repository = $image.repository
                    Tag = $image.tag
                    Error = $_.ToString()
                }
                $backupManifest.Success = $false
            }
        }
        
        # Save backup manifest
        $manifestPath = Join-Path $BackupDirectory "manifest.json"
        $backupManifest | ConvertTo-Json -Depth 10 | Out-File -FilePath $manifestPath -Encoding UTF8

        # Create backup log in the configured log directory
        $logDirectory = Get-ConfiguredLogDirectory
        if (-not (Test-Path $logDirectory)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $logPath = Join-Path $logDirectory "k2s-image-backup-$timestamp.txt"
        New-ImageProcessingLog -LogPath $logPath -LogType "Backup" -Result $backupManifest
        
        if ($backupManifest.FailedImages.Count -gt 0) {
            Write-Log "Image backup completed with $($backupManifest.FailedImages.Count) failures. See $logPath for details." -Console
        } else {
            Write-Log "Successfully backed up all $($backupManifest.Images.Count) images" -Console
        }
        
        return $backupManifest
    }
    catch {
        Write-Log "Critical error during image backup: $_" -Console
        throw $_
    }
}

<#
.SYNOPSIS
Restores user application images after cluster upgrade

.DESCRIPTION
Imports previously backed up images from tar files using backup manifest

.PARAMETER BackupDirectory
Directory containing the backed up images

.PARAMETER ManifestPath
Path to the backup manifest file (optional, will be auto-detected)

.OUTPUTS
Restore result object with success/failure information
#>
function Restore-K2sImages {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BackupDirectory,
        
        [Parameter(Mandatory = $false)]
        [string] $ManifestPath
    )
    
    Write-Log "Starting image restore from directory: $BackupDirectory" -Console
    
    try {
        # Load backup manifest
        if (-not $ManifestPath) {
            $ManifestPath = Join-Path $BackupDirectory "manifest.json"
        }
        
        if (-not (Test-Path $ManifestPath)) {
            Write-Log "Backup manifest not found at: $ManifestPath" -Console
            return @{
                Success = $false
                Error = "Backup manifest not found"
                RestoredImages = @()
                FailedImages = @()
            }
        }
        
        $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        
        if ($manifest.Images.Count -eq 0) {
            Write-Log "No images found in backup manifest" -Console
            return @{
                Success = $true
                RestoredImages = @()
                FailedImages = @()
                Message = "No images to restore"
            }
        }
        
        $k2sExe = Get-K2sExePath
        $restoreResult = @{
            RestoreTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            RestoredImages = @()
            FailedImages = @()
            Success = $true
        }
        
        $totalImages = $manifest.Images.Count
        $currentImage = 0
        
        foreach ($imageInfo in $manifest.Images) {
            $currentImage++
            
            Write-ProcessingProgress -Current $currentImage -Total $totalImages -Action "Restoring" -Image $imageInfo
            
            try {
                # TarFile is stored as relative path (images/images/filename.tar)
                # Convert to absolute path by going up to backup root and joining
                $backupRoot = Split-Path -Parent $BackupDirectory  # Go up from 'images' to backup root
                $tarPath = Join-Path $backupRoot $imageInfo.TarFile

                if (-not (Test-Path $tarPath)) {
                    throw "Tar file not found: $tarPath"
                }
                
                # Import image using k2s image import
                $importArgs = @("image", "import", "-t", $tarPath)
                
                # Check if this is a Windows image
                # Windows images come from Windows nodes - check if Node is NOT the Linux control plane
                $setupInfo = Get-SetupInfo
                $isWindowsImage = $false

               # If node name is NOT 'kubemaster' (Linux control plane), it's a Windows node
                if ($imageInfo.Node -and ($imageInfo.Node -ne "kubemaster" -or $imageInfo.Node -like "*win*" -or $imageInfo.Node -like "*windows*")) {
                    $isWindowsImage = $true
                    $importArgs += "-w"
                    Write-Log "Importing Windows image from node: $($imageInfo.Node)"
                }else {
                    Write-Log "Importing Linux image from node: $($imageInfo.Node)"
                }
                
                Invoke-K2sImageCommand -K2sExecutable $k2sExe -Arguments $importArgs -ImageName "$($imageInfo.Repository):$($imageInfo.Tag)"
                
                $restoreResult.RestoredImages += @{
                    ImageId = $imageInfo.ImageId
                    Repository = $imageInfo.Repository
                    Tag = $imageInfo.Tag
                    TarFile = $tarPath
                    RestoreTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                }
                Write-Log "Successfully restored image: $($imageInfo.Repository):$($imageInfo.Tag)"
            }
            catch {
                Write-Log "Failed to restore image $($imageInfo.Repository):$($imageInfo.Tag) - $_" -Console
                $restoreResult.FailedImages += @{
                    ImageId = $imageInfo.ImageId
                    Repository = $imageInfo.Repository
                    Tag = $imageInfo.Tag
                    TarFile = $imageInfo.TarFile
                    Error = $_.ToString()
                }
                $restoreResult.Success = $false
            }
        }
        
        # Create restore log in the configured log directory
        $logDirectory = Get-ConfiguredLogDirectory
        if (-not (Test-Path $logDirectory)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $logPath = Join-Path $logDirectory "k2s-image-restore-$timestamp.txt"
        
        # Prepare result for log creation (add Images property to match log function expectations)
        $logResult = $restoreResult.Clone()
        $logResult.Images = $restoreResult.RestoredImages
        
        New-ImageProcessingLog -LogPath $logPath -LogType "Restore" -Result $logResult -OriginalTimestamp $manifest.BackupTimestamp
        
        if ($restoreResult.FailedImages.Count -gt 0) {
            Write-Log "Image restore completed with $($restoreResult.FailedImages.Count) failures. See $logPath for details." -Console
        } else {
            Write-Log "Successfully restored all $($restoreResult.RestoredImages.Count) images" -Console
        }
        
        return $restoreResult
    }
    catch {
        Write-Log "Critical error during image restore: $_" -Console
        throw $_
    }
}

<#
.SYNOPSIS
Validates available disk space for image backup

.DESCRIPTION
Checks if there's sufficient disk space for backing up images

.PARAMETER BackupDirectory
Directory where images will be backed up

.PARAMETER RequiredSpaceGB
Required space in GB (optional, calculated from images if not provided)

.PARAMETER Images
Array of images to backup (used for space calculation)

.OUTPUTS
Boolean indicating if sufficient space is available
#>
function Test-BackupDiskSpace {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BackupDirectory,
        
        [Parameter(Mandatory = $false)]
        [int] $RequiredSpaceGB,
        
        [Parameter(Mandatory = $false)]
        [array] $Images
    )
    
    try {
        # Validate input - prevent dangerous defaults
        if (-not $RequiredSpaceGB -and (-not $Images -or $Images.Count -eq 0)) {
            throw "Either RequiredSpaceGB must be specified or Images array must be provided for space calculation."
        }
        
        $drive = Split-Path $BackupDirectory -Qualifier
        if (-not $drive) {
            $drive = "C:"
        }
        
        $driveInfo = Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $drive }
        if (-not $driveInfo) {
            throw "Could not get disk information for drive: $drive"
        }
        
        $freeSpaceGB = [math]::Round($driveInfo.FreeSpace / 1GB, 2)
        
        if ($RequiredSpaceGB) {
            $requiredSpace = $RequiredSpaceGB
        } else {
            # Calculate size from images
            $totalSizeGB = 0
            foreach ($image in $Images) {
                if ($image.size -match "(\d+(?:\.\d+)?)\s*(KB|MB|GB|TB)") {
                    $size = [double]$Matches[1]
                    $unit = $Matches[2].ToUpper()
                    
                    switch ($unit) {
                        "KB" { $totalSizeGB += $size / (1024 * 1024) }
                        "MB" { $totalSizeGB += $size / 1024 }
                        "GB" { $totalSizeGB += $size }
                        "TB" { $totalSizeGB += $size * 1024 }
                    }
                }
            }
            
            # Add just 5% buffer (1.05 multiplier)
            $requiredSpace = [math]::Ceiling($totalSizeGB * 1.05)
        }
        
        Write-Log "Disk space check: Available: ${freeSpaceGB}GB, Required: ${requiredSpace}GB" -Console
        
        if ($freeSpaceGB -ge $requiredSpace) {
            Write-Log "[OK] Sufficient disk space available for backup" -Console
            return $true
        } else {
            $shortfall = $requiredSpace - $freeSpaceGB
            Write-Log "[FAIL] Insufficient disk space for image backup. Available: ${freeSpaceGB}GB, Required: ${requiredSpace}GB (Shortfall: ${shortfall}GB)" -Console
            return $false
        }
    }
    catch {
        Write-Log "Error checking disk space: $_" -Console
        return $false
    }
}

<#
.SYNOPSIS
Cleans up backup files based on retention policy

.DESCRIPTION
Removes old backup files to free up disk space

.PARAMETER BackupDirectory
Directory containing backup files

.PARAMETER RetentionDays
Number of days to retain backup files (default: 7)

.PARAMETER DryRun
If true, only shows what would be deleted without actually deleting
#>
function Remove-OldImageBackups {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BackupDirectory,
        
        [Parameter(Mandatory = $false)]
        [int] $RetentionDays = 7,
        
        [Parameter(Mandatory = $false)]
        [switch] $DryRun
    )
    
    try {
        $cutoffDate = (Get-Date).AddDays(-$RetentionDays)
        $oldBackups = Get-ChildItem -Path $BackupDirectory -Directory | Where-Object { $_.CreationTime -lt $cutoffDate }
        
        if ($oldBackups.Count -eq 0) {
            Write-Log "No old backup directories found to clean up" -Console
            return
        }
        
        foreach ($backup in $oldBackups) {
            if ($DryRun) {
                Write-Log "Would delete backup directory: $($backup.FullName) (Created: $($backup.CreationTime))" -Console
            } else {
                Write-Log "Deleting old backup directory: $($backup.FullName) (Created: $($backup.CreationTime))" -Console
                Remove-Item -Path $backup.FullName -Recurse -Force
            }
        }
        
        if (-not $DryRun) {
            Write-Log "Cleanup completed. Removed $($oldBackups.Count) old backup directories" -Console
        }
    }
    catch {
        Write-Log "Error during backup cleanup: $_" -Console
    }
}

Export-ModuleMember -Function Get-K2sImageList, Backup-K2sImages, Restore-K2sImages, Test-BackupDiskSpace, Remove-OldImageBackups, `
    New-EmptyBackupResult, New-BackupDirectoryStructure, New-ImageProcessingLog, Invoke-K2sImageCommand, Write-ProcessingProgress, Test-ImageOperationParameters
