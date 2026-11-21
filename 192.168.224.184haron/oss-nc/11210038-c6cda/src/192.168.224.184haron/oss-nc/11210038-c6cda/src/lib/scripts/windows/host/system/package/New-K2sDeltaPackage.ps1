# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Creates a delta package between two K2s offline installation packages.

.DESCRIPTION
    New-K2sDeltaPackage.ps1 orchestrates creation of a delta package that contains
    only the differences between two K2s offline packages. This dramatically reduces
    package size for updates.

    The delta package includes:
    - Changed and added files (with hash-based comparison)
    - Debian package differences from Kubemaster VM base images
    - Container image layer differences (Linux and Windows)
    - Wholesale directory replacements as specified

    Container Image Delta Processing:
    - Discovers images from buildah (Linux) and addon manifests (Windows)
    - Compares image versions between packages by image ID and digest
    - Exports only changed images as OCI archives to minimize delta size
    - Achieves 80-95% size reduction for image-only updates
    - Linux images processed via buildah in temporary VM
    - Windows images marked for full export (layer extraction not yet implemented)

    Requirements:
    - Hyper-V enabled for VM-based analysis
    - buildah 1.23+ (present in Kubemaster base image)
    - containerd 1.6+ (for image management)
    - Both input packages must be offline-installation packages with VHDX images

    The generated delta manifest (v2.0) includes ContainerImageDiff metadata with
    added, removed, and changed image lists, plus extracted layer paths and sizes.

.PARAMETER InputPackageOne
    Path to the older (base) K2s offline package ZIP file.

.PARAMETER InputPackageTwo
    Path to the newer (target) K2s offline package ZIP file.

.PARAMETER TargetDirectory
    Directory where the delta package ZIP will be created.

.PARAMETER ZipPackageFileName
    Name of the output delta package ZIP file (must end with .zip).

.PARAMETER ShowLogs
    Show detailed logs during delta creation.

.PARAMETER EncodeStructuredOutput
    Encode output as structured data for CLI consumption.

.PARAMETER MessageType
    Message type for structured output (used with EncodeStructuredOutput).

.PARAMETER CertificatePath
    Path to code signing certificate (.pfx file) for signing executables and scripts.

.PARAMETER Password
    Password for the certificate file (plain string).

.PARAMETER WholeDirectories
    Directories to include wholesale from newer package without diffing.
    Relative paths (e.g., 'docs', 'addons/monitoring').

.PARAMETER SkipImageDelta
    Skip container image delta processing. Use this to create delta packages
    without image layer analysis (faster but larger packages).

.EXAMPLE
    .\New-K2sDeltaPackage.ps1 -InputPackageOne 'C:\packages\k2s-1.6.0.zip' `
                               -InputPackageTwo 'C:\packages\k2s-1.7.0.zip' `
                               -TargetDirectory 'C:\output' `
                               -ZipPackageFileName 'k2s-delta-1.6.0-to-1.7.0.zip' `
                               -ShowLogs

.EXAMPLE
    # Create delta with image processing skipped (faster creation)
    .\New-K2sDeltaPackage.ps1 -InputPackageOne 'old.zip' `
                               -InputPackageTwo 'new.zip' `
                               -TargetDirectory 'C:\output' `
                               -ZipPackageFileName 'delta.zip' `
                               -SkipImageDelta

.EXAMPLE
    # Create delta with code signing
    .\New-K2sDeltaPackage.ps1 -InputPackageOne 'old.zip' `
                               -InputPackageTwo 'new.zip' `
                               -TargetDirectory 'C:\output' `
                               -ZipPackageFileName 'delta.zip' `
                               -CertificatePath 'cert.pfx' `
                               -Password 'certpass'

.NOTES
    Container image delta processing adds 5-15 minutes to delta creation time
    but can reduce delta package size by 500MB-2GB for image-heavy updates.

    Temporary VMs are created and cleaned up automatically during processing.
    Ensure sufficient disk space for temporary extraction directories.
#>

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Input package one (the older version)')]
    [string] $InputPackageOne,
    [parameter(Mandatory = $false, HelpMessage = 'Input package two (the newer version)')]
    [string] $InputPackageTwo,
    [parameter(Mandatory = $false, HelpMessage = 'Target directory')]
    [string] $TargetDirectory,
    [parameter(Mandatory = $false, HelpMessage = 'The name of the zip package (it must have the extension .zip)')]
    [string] $ZipPackageFileName,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'Path to code signing certificate (.pfx file)')]
    [string] $CertificatePath,
    [parameter(Mandatory = $false, HelpMessage = 'Password for the certificate file (plain string; consider SecureString in future)')]
    [string] $Password,
    [parameter(Mandatory = $false, HelpMessage = 'Directories to include wholesale from newer package (no diffing). Relative paths; can be specified multiple times.')]
    [string[]] $WholeDirectories = @(),
    [parameter(Mandatory = $false, HelpMessage = 'Skip container image delta processing')]
    [switch] $SkipImageDelta = $false,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy for Debian package downloads inside the transient VM (corporate environments). Leave empty to download directly through the host NAT.')]
    [string] $Proxy = ''
)

# Internal flag to suppress duplicate terminal error logs
$script:SuppressFinalErrorLog = $false
# Set once a specific structured CLI error has already been emitted at the failure point, so the
# surrounding catch blocks do not re-emit a generic (downgraded) error on top of it.
$script:StructuredErrorSent = $false

### Import modules required for logging and signing
$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$signingModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\common\k2s.signing.module\k2s.signing.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $signingModule

# CRITICAL: When encoding structured output, suppress ALL console output to prevent base64 contamination
if ($EncodeStructuredOutput) {
    Initialize-Logging -ShowLogs:$false
} else {
    Initialize-Logging -ShowLogs:$ShowLogs
}

### Dot-source helper methods
$script:DeltaHelperParts = @(
    'New-K2sDelta.Phase.ps1',
    'New-K2sDelta.IO.ps1',
    'New-K2sDelta.Hash.ps1',
    'New-K2sDelta.Skip.ps1',
    'New-K2sDelta.Validation.ps1',
    'New-K2sDelta.Staging.ps1',
    'New-K2sDelta.Mandatory.ps1',
    'New-K2sDelta.Manifest.ps1',
    'New-K2sDelta.Signing.ps1',
    'New-K2sDelta.Debian.ps1',
    'New-K2sDelta.HyperV.ps1',
    'New-K2sDelta.Diff.ps1',
    'New-K2sDelta.ImageDiff.ps1',
    'New-K2sDelta.ImageAcquisition.ps1',
    'New-K2sDelta.GuestConfig.ps1'
)

foreach ($part in $script:DeltaHelperParts) {
    $path = Join-Path $PSScriptRoot $part
    if (Test-Path -LiteralPath $path) {
        . $path
    } else {
        Write-Log "[DeltaHelpers][Warning] Part missing: $part (expected at $path)" -Console
    }
}

Write-Log "[DeltaPackage] Target Directory: $TargetDirectory" -Console
Write-Log "[DeltaPackage] Package file name: $ZipPackageFileName" -Console

# Validate input parameters using helper function
$validationContext = @{
    InputPackageOne    = $InputPackageOne
    InputPackageTwo    = $InputPackageTwo
    TargetDirectory    = $TargetDirectory
    ZipPackageFileName = $ZipPackageFileName
}
$validationResult = Test-DeltaPackageParameters -Context $validationContext

if (-not $validationResult.Valid) {
    Write-Log $validationResult.ErrorMessage -Error
    if ($EncodeStructuredOutput -eq $true) {
        $severity = if ($validationResult.ExitCode -eq 1) { 'Warning' } else { $null }
        $err = New-Error -Severity $severity -Code $validationResult.ErrorCode -Message $validationResult.ErrorMessage
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }
    exit $validationResult.ExitCode
}

$zipPackagePath = Join-Path "$TargetDirectory" "$ZipPackageFileName"

if (Test-Path $zipPackagePath) {
    Write-Log "[DeltaPackage] Removing already existing file '$zipPackagePath'" -Console
    Remove-Item $zipPackagePath -Force
}

Write-Log "[DeltaPackage] Output path: '$zipPackagePath'" -Console

# --- Delta Package Construction -------------------------------------------------
# Input packages already validated at script start (before SSH key generation)

Write-Log "[DeltaPackage] Building delta: '$InputPackageOne' -> '$InputPackageTwo'" -Console

# Initialize phase tracking for numbered phase output
# Phases: 1.Extraction, 2.Hashing, 3.Staging, 4.VHDXAnalysis, 5.ImageDelta, 6.GuestConfig, 7.DebianArtifacts, 8.Manifest, 9.Signing, 10.Zipping
Initialize-PhaseTracking -TotalPhases 10

# Create temporary directories for extraction and staging
$tempDirs = New-DeltaTempDirectories
$tempRoot = $tempDirs.TempRoot
$oldExtract = $tempDirs.OldExtract
$newExtract = $tempDirs.NewExtract
$stageDir = $tempDirs.StageDir

$overallError = $null
try {
    $extractPhase = Start-Phase 'Extraction'
    try {
    Expand-ZipWithProgress -ZipPath $InputPackageOne -Destination $oldExtract -Label 'old package' -Show:$ShowLogs
    Expand-ZipWithProgress -ZipPath $InputPackageTwo -Destination $newExtract -Label 'new package' -Show:$ShowLogs
    }
    catch {
        Write-Log "Extraction failed: $($_.Exception.Message)" -Error
        throw
    }
    Stop-Phase 'Extraction' $extractPhase

 # (Get-FileMap provided via methods file)

# Get default skip lists using helper function
$skipLists = Get-DefaultSkipLists
$SpecialSkippedFiles = $skipLists.SpecialSkippedFiles
$ClusterConfigSkippedPaths = $skipLists.ClusterConfigSkippedPaths

# Combine user-specified wholesale directories with defaults (Windows binaries must always be replaced)
$userWholeDirs = Expand-WholeDirList -WholeDirectories $WholeDirectories
$defaultWholeDirs = $skipLists.DefaultWholesaleDirectories
$wholeDirsNormalized = @($defaultWholeDirs) + @($userWholeDirs) | Sort-Object -Unique

if ($wholeDirsNormalized.Count -gt 0) {
    Write-Log "[DeltaPackage] Whole directories (no diffing): $($wholeDirsNormalized -join ', ')" -Console
}

Write-Log "[DeltaPackage] Special skipped files: $($SpecialSkippedFiles -join ', ')" -Console
Write-Log "[DeltaPackage] Cluster config skipped paths: $($ClusterConfigSkippedPaths -join ', ')" -Console
 # (Test-SpecialSkippedFile / Test-InWholeDir provided via methods file)

# ---- Special Handling: Analyze Debian packages inside Kubemaster-Base.vhdx (best effort) ---------
# This avoids fully booting a VM by attempting offline extraction of /var/lib/dpkg/status using 7zip.
# If 7z.exe is not available or the dpkg status file cannot be located, the analysis is skipped gracefully.

 # (Get-DebianPackageMapFromStatusFile provided)

 # (Get-DebianPackagesFromVHDX provided)


 # (Get-SkippedFileDebianPackageDiff provided)

$hashPhase = Start-Phase "Hashing"
$oldMap = Get-FileMap -root $oldExtract -label 'old package'
$newMap = Get-FileMap -root $newExtract -label 'new package'
Stop-Phase "Hashing" $hashPhase

# Compute file diff using helper function
$diffContext = @{
    OldMap                    = $oldMap
    NewMap                    = $newMap
    WholeDirsNormalized       = $wholeDirsNormalized
    SpecialSkippedFiles       = $SpecialSkippedFiles
    ClusterConfigSkippedPaths = $ClusterConfigSkippedPaths
}
$fileDiff = Compare-FileMaps -Context $diffContext
$added = $fileDiff.Added
$removed = $fileDiff.Removed
$changed = $fileDiff.Changed

Write-Log "[DeltaPackage] Diff results: Added=$($added.Count) Changed=$($changed.Count) Removed=$($removed.Count)" -Console

# Stage wholesale directories verbatim using helper function
$stagePhase = Start-Phase "Staging"
$wholesaleContext = @{
    NewExtract          = $newExtract
    StageDir            = $stageDir
    WholeDirsNormalized = $wholeDirsNormalized
}
Copy-WholesaleDirectories -Context $wholesaleContext

# Extract Windows binaries from WindowsNodeArtifacts.zip to staging
# These binaries (kubelet, kubectl, docker, etc.) are stored inside the ZIP in the offline package
# but need to be extracted and staged for delta upgrades to update Windows nodes properly
# Only changed or added binaries are staged - unchanged binaries are skipped
$winArtifactsContext = @{
    OldExtract = $oldExtract
    NewExtract = $newExtract
    StageDir   = $stageDir
}
$winArtifactsResult = Copy-WindowsNodeArtifactsToStaging -Context $winArtifactsContext
if ($winArtifactsResult.ExtractedDirs.Count -gt 0) {
    # Add extracted directories to the wholesale list for manifest tracking
    $wholeDirsNormalized = @($wholeDirsNormalized) + @($winArtifactsResult.ExtractedDirs) | Sort-Object -Unique
}

# Helper to purge any special skipped files that were copied indirectly (e.g. via wholesale directories)
 # (Remove-SpecialSkippedFilesFromStage provided)

# Initial purge after wholesale copy
Remove-SpecialSkippedFilesFromStage -StagePath $stageDir -Skipped $SpecialSkippedFiles

# Filter delta file list and copy to staging using helper functions
$deltaFileList = Get-FilteredDeltaFileList -FileList ($added + $changed) `
    -SpecialSkippedFiles $SpecialSkippedFiles `
    -ClusterConfigSkippedPaths $ClusterConfigSkippedPaths

# Final purge to ensure no special skipped files remain (handles files among added/changed set)
Remove-SpecialSkippedFilesFromStage -StagePath $stageDir -Skipped $SpecialSkippedFiles

$stagingContext = @{
    NewExtract    = $newExtract
    StageDir      = $stageDir
    DeltaFileList = $deltaFileList
    ShowLogs      = $ShowLogs
}
Copy-DeltaFilesToStaging -Context $stagingContext
Stop-Phase "Staging" $stagePhase

# --- MANDATORY: Ensure required files are included using helper function ---
$mandatoryContext = @{
    NewExtract = $newExtract
    StageDir   = $stageDir
    ScriptRoot = $PSScriptRoot
    Added      = $added
    Changed    = $changed
}
$mandatoryResult = Ensure-MandatoryFiles -Context $mandatoryContext

# Staging summary using helper function
$summaryContext = @{
    StageDir            = $stageDir
    WholeDirsNormalized = $wholeDirsNormalized
    Added               = $added
    Changed             = $changed
}
Write-StagingSummary -Context $summaryContext

# Special diff for Debian packages inside Kubemaster-Base.vhdx (if present and analyzable)
$debianPackageDiff = $null
$offlineDebInfo = $null
$imageDiffResult = $null
$guestConfigDiff = $null
if ($SpecialSkippedFiles -contains 'Kubemaster-Base.vhdx') {
        $vhdxPhase = Start-Phase 'VHDXAnalysis'
        Write-Log '[VHDXAnalysis] Analyzing Debian packages in Kubemaster-Base.vhdx...' -Console
                $debianPackageDiff = Get-SkippedFileDebianPackageDiff -OldRoot $oldExtract -NewRoot $newExtract -FileName 'Kubemaster-Base.vhdx' -QueryImages:(-not $SkipImageDelta) -QueryConfigHashes -KeepNewVmAlive:$true
        if ($debianPackageDiff.Processed) {
            Write-Log ("[VHDXAnalysis] Debian package diff: Added={0} Changed={1} Removed={2}" -f $debianPackageDiff.AddedCount, $debianPackageDiff.ChangedCount, $debianPackageDiff.RemovedCount) -Console

            # Process image delta if enabled
            if (-not $SkipImageDelta) {
                Write-Log '[ImageDiff] Processing container image delta...' -Console
                $imagePhase = Start-Phase 'Image Delta'

                try {
                    # Get Windows images from both packages
                    Write-Log '[ImageDiff] Extracting Windows images from packages...' -Console
                    $oldWinImages = Get-WindowsImagesFromPackage -PackageRoot $oldExtract
                    $newWinImages = Get-WindowsImagesFromPackage -PackageRoot $newExtract

                    # Compare all images
                    $imageDiffResult = Compare-ContainerImages -OldLinuxImages $debianPackageDiff.OldLinuxImages `
                                                                -NewLinuxImages $debianPackageDiff.NewLinuxImages `
                                                                -OldWindowsImages $oldWinImages.Images `
                                                                -NewWindowsImages $newWinImages.Images

                    Write-Log "[ImageDiff] Image comparison complete: Added=$($imageDiffResult.Added.Count), Removed=$($imageDiffResult.Removed.Count), Changed=$($imageDiffResult.Changed.Count)" -Console

                    # Extract layers for changed images (Added + Changed)
                    $imagesToProcess = @()
                    if ($imageDiffResult.Added) { $imagesToProcess += $imageDiffResult.Added }
                    if ($imageDiffResult.Changed) { $imagesToProcess += $imageDiffResult.Changed }

                    if ($imagesToProcess.Count -gt 0) {
                        Write-Log "[ImageAcq] Starting image export for $($imagesToProcess.Count) images..." -Console

                        # Debug: show platforms of all images
                        foreach ($img in $imagesToProcess) {
                            Write-Log "[ImageAcq] DEBUG: Image '$($img.FullName)' has Platform='$($img.Platform)'" -Console
                        }

                        # Separate Windows and Linux images (ensure array output)
                        $windowsImagesToProcess = @($imagesToProcess | Where-Object { $_.Platform -eq 'windows' })
                        $linuxImagesToProcess = @($imagesToProcess | Where-Object { $_.Platform -eq 'linux' })

                        Write-Log "[ImageAcq] Images to process: $($windowsImagesToProcess.Count) Windows, $($linuxImagesToProcess.Count) Linux" -Console

                        # Get path to new VHDX
                        $newVhdxPath = Join-Path $newExtract 'bin\Kubemaster-Base.vhdx'

                        # Always process Windows images (they don't need a VM)
                        # Process Linux images only if we have a VM context
                        $imagesToExport = @()
                        $imagesToExport += $windowsImagesToProcess

                        if ((Test-Path $newVhdxPath) -and $debianPackageDiff.NewVmContext) {
                            $imagesToExport += $linuxImagesToProcess
                            $vmContext = $debianPackageDiff.NewVmContext
                        } else {
                            if ($linuxImagesToProcess.Count -gt 0) {
                                Write-Log "[ImageAcq] Warning: Cannot export Linux images - VHDX not found or VM context missing" -Console
                            }
                            $vmContext = $null
                        }

                        if ($imagesToExport.Count -gt 0) {
                            $layerExtractionResult = Export-ChangedImageLayers -NewPackageRoot $newExtract `
                                                                                -NewVhdxPath $newVhdxPath `
                                                                                -ChangedImages $imagesToExport `
                                                                                -StagingDir $stageDir `
                                                                                -ExistingVmContext $vmContext `
                                                                                -ShowLogs:$false

                            if ($layerExtractionResult.Success) {
                                Write-Log "[ImageAcq] Image export successful: Exported $($layerExtractionResult.ExtractedLayers.Count) image archives, Total size: $([math]::Round($layerExtractionResult.TotalSize / 1MB, 2)) MB" -Console

                                if ($layerExtractionResult.FailedImages.Count -gt 0) {
                                    throw "Image export returned success with failed images: $($layerExtractionResult.FailedImages -join ', ')"
                                }
                            } else {
                                throw "Required image export failed: $($layerExtractionResult.ErrorMessage)"
                            }
                        }

                        # VM cleanup moved to after guest config diff phase
                    } else {
                        Write-Log "[ImageAcq] No images to process for layer extraction" -Console
                        # VM cleanup moved to after guest config diff phase
                    }

                } catch {
                    Write-Log "[ImageDiff][Error] Image delta processing failed: $($_.Exception.Message)" -Console
                    throw
                } finally {
                    Stop-Phase 'Image Delta' $imagePhase
                }
            }

            # --- Guest configuration file diff (use hashes collected during deb diff phase) ---
            $configPhase = Start-Phase 'GuestConfigDiff'
            try {
                Write-Log '[GuestConfig] Processing guest configuration file diff from collected hashes...' -Console

                $oldHashes = $debianPackageDiff.OldConfigHashes
                $newHashes = $debianPackageDiff.NewConfigHashes

                if ($oldHashes.Count -gt 0 -or $newHashes.Count -gt 0) {
                    # Compute diff from collected hashes
                    $configAdded = @()
                    $configRemoved = @()
                    $configChanged = @()

                    foreach ($path in $newHashes.Keys) {
                        if (-not $oldHashes.ContainsKey($path)) {
                            $configAdded += $path
                        } elseif ($oldHashes[$path] -ne $newHashes[$path]) {
                            $configChanged += $path
                        }
                    }
                    foreach ($path in $oldHashes.Keys) {
                        if (-not $newHashes.ContainsKey($path)) {
                            $configRemoved += $path
                        }
                    }

                    Write-Log "[GuestConfig] Guest config diff: Added=$($configAdded.Count), Changed=$($configChanged.Count), Removed=$($configRemoved.Count)" -Console

                    # Copy added/changed files from new VM if it's still alive
                    $filesToCopy = @($configAdded) + @($configChanged)
                    $copiedFiles = @()

                    if ($filesToCopy.Count -gt 0 -and $debianPackageDiff.NewVmContext) {
                        # Copy-GuestConfigFiles appends 'guest-config' to its -OutputDir (its documented
                        # contract: "guest-config/ will be the root"). Pass the staging ROOT here so the
                        # payload lands at '<stage>/guest-config/<abs-path>' (single nesting). Passing
                        # '<stage>/guest-config' caused a '<stage>/guest-config/guest-config/...' double
                        # nesting that did not match the manifest's GuestConfigRelativePath at apply time.
                        Write-Log "[GuestConfig] Copying $($filesToCopy.Count) config files from new VM..." -Console
                        $copyResult = Copy-GuestConfigFiles -VmContext $debianPackageDiff.NewVmContext `
                                                            -NewExtract $newExtract `
                                                            -OldExtract $oldExtract `
                                                            -FilePaths $filesToCopy `
                                                            -OutputDir $stageDir

                        if ($copyResult.Error) {
                            Write-Log "[GuestConfig] Warning: File copy had errors: $($copyResult.Error)" -Console
                        }
                        $copiedFiles = $copyResult.CopiedFiles
                        Write-Log "[GuestConfig] Copied $($copiedFiles.Count) config files to delta package" -Console
                    } elseif ($filesToCopy.Count -gt 0) {
                        Write-Log "[GuestConfig] Warning: Cannot copy config files - new VM context not available" -Console
                    }

                    # Build result object for manifest
                    $guestConfigDiff = [pscustomobject]@{
                        Processed     = $true
                        Added         = $configAdded
                        Changed       = $configChanged
                        Removed       = $configRemoved
                        AddedCount    = $configAdded.Count
                        ChangedCount  = $configChanged.Count
                        RemovedCount  = $configRemoved.Count
                        CopiedFiles   = $copiedFiles
                        Error         = $null
                    }
                } else {
                    Write-Log '[GuestConfig] Warning: No config hashes collected, skipping config diff' -Console
                    $guestConfigDiff = [pscustomobject]@{ Processed = $false; Error = 'No config hashes collected' }
                }
            } catch {
                Write-Log "[GuestConfig] Warning: Guest config diff failed: $($_.Exception.Message)" -Console
                $guestConfigDiff = [pscustomobject]@{ Processed = $false; Error = $_.Exception.Message }
            } finally {
                Stop-Phase 'GuestConfigDiff' $configPhase

                # Clean up new VM now that all VM-based processing is done (old VM already shut down)
                if ($debianPackageDiff.NewVmContext) {
                    Write-Log "[GuestConfig] Cleaning up new VM after config diff: $($debianPackageDiff.NewVmContext.VmName)" -Console
                    Remove-K2sHvEnvironment -Context $debianPackageDiff.NewVmContext
                }
            }

                        # --- Generate Debian delta artifact directory (lists + scripts) -----------------
            $debArtifactPhase = Start-Phase 'DebianArtifacts'
            try {
                $debianDeltaDir = Join-Path $stageDir 'debian-delta'
                if (-not (Test-Path -LiteralPath $debianDeltaDir)) { New-Item -ItemType Directory -Path $debianDeltaDir | Out-Null }

                # Collect offline package specs (added + upgraded new versions)
                $offlineSpecs = @()
                if ($debianPackageDiff.Added) { $offlineSpecs += $debianPackageDiff.Added }
                if ($debianPackageDiff.Changed) {
                    foreach ($c in $debianPackageDiff.Changed) {
                        if ($c -match '^(?<n>[^:]+):\s+[^ ]+\s+->\s+(?<nv>.+)$') { $offlineSpecs += ("{0}={1}" -f $matches['n'], $matches['nv']) }
                    }
                }
                $offlineSpecs = $offlineSpecs | Sort-Object -Unique

                # Added packages list (keep full pkg=version form)
                $addedPkgs = $debianPackageDiff.Added
                if ($addedPkgs) { $addedPkgs | Sort-Object | Out-File -FilePath (Join-Path $debianDeltaDir 'packages.added') -Encoding ASCII -Force }

                # Removed packages list (strip versions to just names)
                $removedNames = @()
                foreach ($r in ($debianPackageDiff.Removed)) { if ($r -match '^(?<n>[^=]+)=(?<v>.+)$') { $removedNames += $matches['n'] } }
                if ($removedNames) { $removedNames | Sort-Object -Unique | Out-File -FilePath (Join-Path $debianDeltaDir 'packages.removed') -Encoding ASCII -Force }

                # Upgraded packages (Changed list lines formatted: name: old -> new)
                $upgradedLines = @()
                foreach ($c in ($debianPackageDiff.Changed)) { if ($c -match '^(?<n>[^:]+):\s+(?<o>[^ ]+)\s+->\s+(?<nv>.+)$') { $upgradedLines += ("{0} {1} {2}" -f $matches['n'], $matches['o'], $matches['nv']) } }
                if ($upgradedLines) { $upgradedLines | Sort-Object | Out-File -FilePath (Join-Path $debianDeltaDir 'packages.upgraded') -Encoding ASCII -Force }

                # Expected target Kubernetes version (kubelet X.Y.Z). Written so the apply script can hard-fail
                # if the installed kubelet does not reach this version (i.e. the package is incomplete). Only
                # written when the kubelet package actually changes between versions.
                $expectedKubeletVersion = $null
                foreach ($spec in $offlineSpecs) {
                    if ($spec -match '^kubelet=(?<v>[0-9]+\.[0-9]+\.[0-9]+)') { $expectedKubeletVersion = $matches['v']; break }
                }
                if (-not $expectedKubeletVersion) {
                    foreach ($line in $upgradedLines) { if ($line -match '^kubelet\s+\S+\s+(?<v>[0-9]+\.[0-9]+\.[0-9]+)') { $expectedKubeletVersion = $matches['v']; break } }
                }
                if ($expectedKubeletVersion) {
                    $expectedKubeletVersion | Out-File -FilePath (Join-Path $debianDeltaDir 'expected-k8s-version') -Encoding ASCII -Force -NoNewline
                }

                # Debian delta manifest (JSON)
                $debDeltaManifest = [pscustomobject]@{
                    SourceVhdxOld       = $debianPackageDiff.OldRelativePath
                    SourceVhdxNew       = $debianPackageDiff.NewRelativePath
                    Added               = $addedPkgs
                    Removed             = $removedNames
                    Upgraded            = $upgradedLines
                    AddedCount          = $debianPackageDiff.AddedCount
                    RemovedCount        = $debianPackageDiff.RemovedCount
                    UpgradedCount       = $upgradedLines.Count
                    OfflinePackages     = $offlineSpecs
                    OfflinePackagesCount = $offlineSpecs.Count
                    GeneratedUtc        = [DateTime]::UtcNow.ToString('o')
                }
                $debDeltaManifest | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path $debianDeltaDir 'debian-delta-manifest.json') -Encoding UTF8 -Force

                # Apply script (bash) - installs added + upgraded with explicit versions, removes removed
                # Copy bash scripts from external files (maintained separately for readability)
                $scriptsSourceDir = Join-Path $PSScriptRoot 'scripts'

                $applyScriptSource = Join-Path $scriptsSourceDir 'apply-debian-delta.sh'
                $applyPath = Join-Path $debianDeltaDir 'apply-debian-delta.sh'
                if (Test-Path -LiteralPath $applyScriptSource) {
                    Copy-Item -LiteralPath $applyScriptSource -Destination $applyPath -Force
                } else {
                    throw "Required script not found: $applyScriptSource"
                }

                $verifyScriptSource = Join-Path $scriptsSourceDir 'verify-debian-delta.sh'
                $verifyPath = Join-Path $debianDeltaDir 'verify-debian-delta.sh'
                if (Test-Path -LiteralPath $verifyScriptSource) {
                    Copy-Item -LiteralPath $verifyScriptSource -Destination $verifyPath -Force
                } else {
                    throw "Required script not found: $verifyScriptSource"
                }

                # Attempt offline .deb acquisition using a second VHDX scan pass (best effort)
                try {
                    if ($offlineSpecs.Count -gt 0) {
                        $debDownloadDir = Join-Path $debianDeltaDir 'packages'
                        if (-not (Test-Path -LiteralPath $debDownloadDir)) { New-Item -ItemType Directory -Path $debDownloadDir | Out-Null }
                        Write-Log ("[DebPkg] Attempting offline .deb acquisition for {0} packages" -f $offlineSpecs.Count) -Console
                        $kubemasterNewRel = $debianPackageDiff.NewRelativePath
                        $kubemasterNewAbs = Join-Path $newExtract $kubemasterNewRel
                        if (Test-Path -LiteralPath $kubemasterNewAbs) {
                            $dlResult = Get-DebianPackagesFromVHDX -VhdxPath $kubemasterNewAbs -NewExtract $newExtract -OldExtract $oldExtract -switchNameEnding 'delta' -DownloadPackageSpecs $offlineSpecs -DownloadLocalDir $debDownloadDir -DownloadDebs -AllowPartialAcquisition -Proxy $Proxy
                            if ($dlResult.Error) {
                                Write-Log ("[DebPkg][Warning] Offline package acquisition error: {0}" -f $dlResult.Error) -Console
                                 throw "Offline deb acquisition failed: $($dlResult.Error)"    # mandatory failure
                            }
                            elseif ($dlResult.DownloadedDebs.Count -gt 0) {
                                # Hard guard: critical Kubernetes packages that changed between versions MUST
                                # have been downloaded. A partial acquisition that drops these silently produces
                                # a delta that cannot upgrade the Linux control plane (kubeadm upgrade would just
                                # re-apply the old kubelet version). Fail loudly so the package is never shipped.
                                $criticalPkgNames = @('cri-o', 'cri-tools', 'kubeadm', 'kubectl', 'kubelet', 'kubernetes-cni')
                                $missingCritical = @()
                                foreach ($spec in $offlineSpecs) {
                                    $pname = ($spec -split '=')[0]
                                    if ($criticalPkgNames -notcontains $pname) { continue }
                                    $present = $dlResult.DownloadedDebs | Where-Object { $_ -like "${pname}_*.deb" }
                                    if (-not $present) { $missingCritical += $pname }
                                }
                                if ($missingCritical.Count -gt 0) {
                                    $criticalMsg = ("Offline deb acquisition is missing critical Kubernetes package(s): {0}. The delta package would not upgrade the Linux control plane. Check network/proxy/DNS for the package-creation VM (use --proxy for corporate environments) and retry." -f ($missingCritical -join ', '))
                                    Write-Log ("[DebPkg][Error] {0}" -f $criticalMsg) -Console
                                    if ($EncodeStructuredOutput -eq $true) {
                                        $err = New-Error -Severity Error -Code 'delta-critical-packages-missing' -Message $criticalMsg
                                        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
                                        $script:StructuredErrorSent = $true
                                    }
                                    throw $criticalMsg
                                }
                                $debMeta = [pscustomobject]@{
                                    Downloaded = $dlResult.DownloadedDebs
                                    DownloadedCount = $dlResult.DownloadedDebs.Count
                                    GeneratedUtc = [DateTime]::UtcNow.ToString('o')
                                }
                                $debMeta | ConvertTo-Json -Depth 3 | Out-File -FilePath (Join-Path $debDownloadDir 'download-manifest.json') -Encoding UTF8 -Force
                                Write-Log ("[DebPkg] Offline .deb acquisition completed: {0} files" -f $dlResult.DownloadedDebs.Count) -Console
                                # FailureDetails removed; no failed-packages.json emitted
                                $offlineDebInfo = [pscustomobject]@{
                                    Specs = $offlineSpecs
                                    Downloaded = $dlResult.DownloadedDebs | ForEach-Object { Join-Path 'debian-delta/packages' $_ }
                                }
                            } else {
                                Write-Log '[DebPkg][Warning] No .deb files downloaded (empty list)' -Console
                                throw 'Offline deb acquisition produced zero files (mandatory)'
                            }
                        } else {
                            Write-Log ("[DebPkg][Warning] Expected VHDX for offline acquisition not found: {0}" -f $kubemasterNewAbs) -Console
                            throw 'Offline deb acquisition VHDX missing (mandatory)'
                        }
                    }
                } catch {
                    Write-Log ("[DebPkg][Warning] Offline acquisition attempt failed: {0}" -f $_.Exception.Message) -Console
                    throw
                }
                Write-Log "[DebPkg] Created Debian delta artifact at '$debianDeltaDir'" -Console
                Stop-Phase 'DebianArtifacts' $debArtifactPhase
            }
            catch {
                Stop-Phase 'DebianArtifacts' $debArtifactPhase
                if ($script:StructuredErrorSent) {
                    # A specific structured error was already emitted at the failure point (e.g. missing
                    # critical Kubernetes packages). Do not re-emit a generic/downgraded error on top of it.
                    # NOTE: this 'return' exits the ENTIRE script (a return inside a catch in a top-level
                    # script returns from the script), which is the intended behavior here - the structured
                    # error has been sent to the CLI and no further phases should run.
                    $script:SuppressFinalErrorLog = $true
                    return
                }
                Write-Log "[Error] Failed to generate Debian delta artifact: $($_.Exception.Message)"
                if ($EncodeStructuredOutput -eq $true) {
                    $err = New-Error -Severity Warning -Code '[Error] Failed to generate Debian delta artifact' -Message $_.Exception.Message
                    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                    return
                }
                else {
                    throw $_
                }
            }
            Stop-Phase 'VHDXAnalysis' $vhdxPhase
    } else {
        Stop-Phase 'VHDXAnalysis' $vhdxPhase
        $err = "Debian package diff not processed: $($debianPackageDiff.Error)"
        # Attempt a quick verification that no temp Hyper-V artifacts remain (best effort)
        try {
            if (Get-Module -ListAvailable -Name Hyper-V) {
                $leftVMs = Get-VM -Name 'k2s-kubemaster-*' -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Off' -or $_ }
                $leftSwitches = Get-VMSwitch -Name 'k2s-switch-*' -ErrorAction SilentlyContinue
                if ($leftVMs) { Write-Log ("[Cleanup][Warning] Residual VM objects after diff failure: {0}" -f ($leftVMs.Name -join ', ')) -Console }
                if ($leftSwitches) { Write-Log ("[Cleanup][Warning] Residual VMSwitch objects after diff failure: {0}" -f ($leftSwitches.Name -join ', ')) -Console }
            }
        } catch { Write-Log "[Cleanup][Warning] Cleanup verification failed: $($_.Exception.Message)" -Console }
        Write-Log $err -Error
        $script:SuppressFinalErrorLog = $true
        throw $err
    }
} else {
    # VHDX not in skip list - skip phases 4-7 (VHDXAnalysis, ImageDelta, GuestConfig, DebianArtifacts)
    Write-Log '[Phase 4/10] VHDXAnalysis - skipped (no VHDX in skip list)' -Console
    Write-Log '[Phase 5/10] ImageDelta - skipped (no VHDX)' -Console
    Write-Log '[Phase 6/10] GuestConfigDiff - skipped (no VHDX)' -Console
    Write-Log '[Phase 7/10] DebianArtifacts - skipped (no VHDX)' -Console
    # Advance phase counter to align with manifest phase
    $script:DeltaPhaseNumber = 7
}

# Build and write delta manifest using helper function
$manifestPhase = Start-Phase 'Manifest'
$manifestContext = @{
    InputPackageOne     = $InputPackageOne
    InputPackageTwo     = $InputPackageTwo
    OldExtract          = $oldExtract
    NewExtract          = $newExtract
    StageDir            = $stageDir
    WholeDirsNormalized = $wholeDirsNormalized
    SpecialSkippedFiles = $SpecialSkippedFiles
    Added               = $added
    Changed             = $changed
    Removed             = $removed
    DebianPackageDiff   = $debianPackageDiff
    OfflineDebInfo      = $offlineDebInfo
    ImageDiffResult     = $imageDiffResult
    GuestConfigDiff     = $guestConfigDiff
}
$manifestPath = New-DeltaManifest -Context $manifestContext
Stop-Phase 'Manifest' $manifestPhase

    # --- Code Signing (optional) using helper function -------------------------------------------------
    $signingPhase = Start-Phase 'Signing'
    $signingContext = @{
        StageDir        = $stageDir
        CertificatePath = $CertificatePath
        Password        = $Password
    }
    $signingResult = Invoke-DeltaCodeSigning -Context $signingContext
    Stop-Phase 'Signing' $signingPhase

    # --- Create delta zip after (optional) signing ------------------------------
    $zipPhase = Start-Phase "Zipping"
    try {
        New-ZipWithProgress -SourceDir $stageDir -ZipPath $zipPackagePath -Label 'delta' -Show:$ShowLogs
        Write-Log "[Zipping] Delta package created: $zipPackagePath" -Console
    }
    catch {
        Write-Log "Failed to create delta zip: $($_.Exception.Message)" -Error
        throw
    }
    Stop-Phase "Zipping" $zipPhase
}
catch {
    $overallError = $_
}
finally {
    # Cleanup temp extraction directories using helper function
    Remove-DeltaTempDirectories -TempRoot $tempRoot
}

if ($overallError) {
    if (-not $script:SuppressFinalErrorLog) {
        Write-Log "Delta creation encountered an error: $($overallError.Exception.Message)" -Error
    }
    exit 5
}

if ($EncodeStructuredOutput -eq $true) {
    # Send CmdResult structure expected by Go CLI (lowercase 'error' field)
    Send-ToCli -MessageType $MessageType -Message @{
        error = $null
    }
} else {
    Write-Log '[DeltaPackage] All phases completed successfully' -Console
    Write-Log '[DeltaPackage] DONE' -Console
}
