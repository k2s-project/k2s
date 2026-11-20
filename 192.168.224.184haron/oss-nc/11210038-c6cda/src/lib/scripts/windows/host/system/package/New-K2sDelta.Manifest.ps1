# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Delta manifest construction helpers

<#
.SYNOPSIS
    Converts container image diff result to manifest-compatible object.

.DESCRIPTION
    Transforms the internal image diff result into a simplified structure
    suitable for JSON serialization in the delta manifest.

.PARAMETER ImageDiffResult
    The image diff result object from Compare-ContainerImages.

.OUTPUTS
    PSCustomObject with AddedImages, RemovedImages, ChangedImages arrays and counts,
    or $null if input is null.
#>
function ConvertTo-ImageDiffObject {
    param(
        [Parameter(Mandatory = $false)]
        $ImageDiffResult
    )

    if (-not $ImageDiffResult) { return $null }

    return [pscustomobject]@{
        AddedImages   = $ImageDiffResult.Added | ForEach-Object {
            [pscustomobject]@{
                FullName = $_.FullName
                Platform = $_.Platform
            }
        }
        RemovedImages = $ImageDiffResult.Removed | ForEach-Object {
            [pscustomobject]@{
                FullName = $_.FullName
                Platform = $_.Platform
            }
        }
        ChangedImages = $ImageDiffResult.Changed | ForEach-Object {
            [pscustomobject]@{
                FullName = $_.FullName
                Platform = $_.Platform
            }
        }
        AddedCount    = $ImageDiffResult.Added.Count
        RemovedCount  = $ImageDiffResult.Removed.Count
        ChangedCount  = $ImageDiffResult.Changed.Count
    }
}

<#
.SYNOPSIS
    Converts guest config diff result to manifest-compatible object.

.DESCRIPTION
    Transforms the internal guest config diff result into a simplified structure
    suitable for JSON serialization in the delta manifest.

.PARAMETER GuestConfigDiff
    The guest config diff result object.

.OUTPUTS
    PSCustomObject with Added, Changed, Removed arrays and metadata,
    or $null if input is null or not processed.
#>
function ConvertTo-GuestConfigDiffObject {
    param(
        [Parameter(Mandatory = $false)]
        $GuestConfigDiff
    )

    if (-not $GuestConfigDiff -or -not $GuestConfigDiff.Processed) { return $null }

    return [pscustomobject]@{
        Added            = $GuestConfigDiff.Added
        Changed          = $GuestConfigDiff.Changed
        Removed          = $GuestConfigDiff.Removed
        AddedCount       = $GuestConfigDiff.AddedCount
        ChangedCount     = $GuestConfigDiff.ChangedCount
        RemovedCount     = $GuestConfigDiff.RemovedCount
        CopiedFiles      = $GuestConfigDiff.CopiedFiles
        CopiedFilesCount = $GuestConfigDiff.CopiedFiles.Count
        FailedFiles      = $GuestConfigDiff.FailedFiles
        FailedFilesCount = $(if ($GuestConfigDiff.FailedFiles) { $GuestConfigDiff.FailedFiles.Count } else { 0 })
        ScannedPaths     = $GuestConfigDiff.ScannedPaths
    }
}

<#
.SYNOPSIS
    Builds and writes the delta-manifest.json file.

.DESCRIPTION
    Constructs the complete delta manifest object containing all metadata about
    the delta package and writes it to the staging directory.

.PARAMETER Context
    Hashtable containing all required manifest data:
    - InputPackageOne, InputPackageTwo: Original package paths
    - OldExtract, NewExtract: Extraction paths for version reading
    - StageDir: Where to write the manifest
    - WholeDirsNormalized: Wholesale directories list
    - SpecialSkippedFiles: Skipped files list
    - Added, Changed, Removed: File diff arrays
    - DebianPackageDiff: Debian package diff result
    - OfflineDebInfo: Offline deb acquisition info
    - ImageDiffResult: Container image diff result
    - GuestConfigDiff: Guest config diff result

.OUTPUTS
    Path to the created manifest file.
#>
function New-DeltaManifest {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Context
    )

    # Read VERSION files
    $baseVersion = Get-PackageVersion -ExtractPath $Context.OldExtract
    $targetVersion = Get-PackageVersion -ExtractPath $Context.NewExtract
    $baseKubernetesVersion = Get-PackageKubernetesVersion -ExtractPath $Context.OldExtract
    $targetKubernetesVersion = Get-PackageKubernetesVersion -ExtractPath $Context.NewExtract

    if ($baseVersion) {
        Write-Log "Base package version: $baseVersion" -Console
    }
    else {
        Write-Log "[Warning] VERSION file not found in base package" -Console
    }

    if ($targetVersion) {
        Write-Log "Target package version: $targetVersion" -Console
    }
    else {
        Write-Log "[Warning] VERSION file not found in target package" -Console
    }

    # Build manifest object
    $manifest = [pscustomobject]@{
        ManifestVersion          = '2.0'
        GeneratedUtc             = [DateTime]::UtcNow.ToString('o')
        BasePackage              = (Split-Path -Leaf $Context.InputPackageOne)
        TargetPackage            = (Split-Path -Leaf $Context.InputPackageTwo)
        BaseVersion              = $baseVersion
        TargetVersion            = $targetVersion
        BaseKubernetesVersion    = $baseKubernetesVersion
        TargetKubernetesVersion  = $targetKubernetesVersion
        WholeDirectories         = $Context.WholeDirsNormalized
        WholeDirectoriesCount    = $Context.WholeDirsNormalized.Count
        SpecialSkippedFiles      = $Context.SpecialSkippedFiles
        SpecialSkippedFilesCount = $Context.SpecialSkippedFiles.Count
        Added                    = $Context.Added
        Changed                  = $Context.Changed
        Removed                  = $Context.Removed
        AddedCount               = $Context.Added.Count
        ChangedCount             = $Context.Changed.Count
        RemovedCount             = $Context.Removed.Count
        HashAlgorithm            = 'SHA256'
        DebianPackageDiff        = $Context.DebianPackageDiff
        DebianDeltaRelativePath  = $(if (Test-Path -LiteralPath (Join-Path $Context.StageDir 'debian-delta')) { 'debian-delta' } else { $null })
        DebianOfflinePackages    = $(if ($Context.OfflineDebInfo) { $Context.OfflineDebInfo.Specs } else { @() })
        DebianOfflinePackagesCount = $(if ($Context.OfflineDebInfo) { $Context.OfflineDebInfo.Specs.Count } else { 0 })
        DebianOfflineDownloaded  = $(if ($Context.OfflineDebInfo) { $Context.OfflineDebInfo.Downloaded } else { @() })
        DebianOfflineDownloadedCount = $(if ($Context.OfflineDebInfo) { $Context.OfflineDebInfo.Downloaded.Count } else { 0 })
        ContainerImageDiff       = (ConvertTo-ImageDiffObject -ImageDiffResult $Context.ImageDiffResult)
        GuestConfigDiff          = (ConvertTo-GuestConfigDiffObject -GuestConfigDiff $Context.GuestConfigDiff)
        GuestConfigRelativePath  = $(if ($Context.GuestConfigDiff -and $Context.GuestConfigDiff.Processed -and (Test-Path -LiteralPath (Join-Path $Context.StageDir 'guest-config'))) { 'guest-config' } else { $null })
    }

    $manifestPath = Join-Path $Context.StageDir 'delta-manifest.json'
    $manifest | ConvertTo-Json -Depth 6 | Out-File -FilePath $manifestPath -Encoding UTF8 -Force

    return $manifestPath
}
