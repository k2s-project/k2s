# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
Helper functions for container image comparison in delta packages.

.DESCRIPTION
Provides image discovery, comparison, and layer analysis for delta package creation.
Works with both Linux (buildah) and Windows (containerd/nerdctl) images.
Images are discovered by reusing existing VM sessions (Linux) or extracting from
WindowsNodeArtifacts.zip (Windows).
#>

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Extracts Windows container images from WindowsNodeArtifacts.zip.

.DESCRIPTION
Reads the WindowsNodeArtifacts.zip file from the extracted package and lists
all .tar files in the images/ subdirectory. Parses filenames to extract
repository and tag information.

.PARAMETER PackageRoot
Root directory of the extracted package.

.OUTPUTS
Array of PSCustomObjects with FullName, FileName, and Size properties.
#>
function Get-WindowsImagesFromPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot
    )

    $result = @{
        Success      = $false
        Images       = @()
        ErrorMessage = ''
    }

    try {
        $winArtifactsZip = Join-Path $PackageRoot 'bin\WindowsNodeArtifacts.zip'

        if (-not (Test-Path $winArtifactsZip)) {
            $result.ErrorMessage = "WindowsNodeArtifacts.zip not found at: $winArtifactsZip"
            Write-Log "[ImageDiff] $($result.ErrorMessage)" -Console
            return $result
        }

        Write-Log "[ImageDiff] Extracting Windows image list from WindowsNodeArtifacts.zip..." -Console

        # Load the zip file
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($winArtifactsZip)

        try {
            # Find all .tar files in the images/ folder (handle both / and \ path separators)
            $imageTars = $zip.Entries | Where-Object {
                $_.FullName -match '^images[/\\][^/\\]+\.tar$'
            }

            foreach ($entry in $imageTars) {
                $fileName = [System.IO.Path]::GetFileName($entry.FullName)

                # Parse image name from filename
                # Expected format: registry.domain__repo__subpath_tag.tar
                # Example: shsk2s.azurecr.io__pause-win_v1.5.0.tar
                # Double underscore (__) separates registry from image path
                # Single underscore (_) before version is the tag separator
                $imageName = $fileName -replace '\.tar$', ''

                # Replace __ with / for registry/path separators
                $imageName = $imageName -replace '__', '/'

                # Find the last underscore followed by 'v' which indicates version tag
                # This handles cases like: registry/image_vtag
                if ($imageName -match '^(.+)_v(.+)$') {
                    # Tag starts with 'v', keep it
                    $imageName = "$($matches[1]):v$($matches[2])"
                } elseif ($imageName -match '^(.+)_([^_/]+)$') {
                    # Tag doesn't start with 'v', use as-is
                    $imageName = "$($matches[1]):$($matches[2])"
                }

                $result.Images += [PSCustomObject]@{
                    FullName = $imageName
                    FileName = $fileName
                    Size     = $entry.Length
                }
            }

            $result.Success = $true
            Write-Log "[ImageDiff] Found $($result.Images.Count) Windows images in WindowsNodeArtifacts.zip" -Console

        } finally {
            $zip.Dispose()
        }

    } catch {
        $result.ErrorMessage = "Failed to extract Windows images: $_"
        Write-Log "[ImageDiff] $($result.ErrorMessage)" -Console
    }

    return $result
}

<#
.SYNOPSIS
Compares container images between two packages to identify added, removed, and changed images.

.DESCRIPTION
Takes buildah image lists from both packages (obtained during Debian diff phase) and
Windows image lists extracted from WindowsNodeArtifacts.zip files.

.PARAMETER OldLinuxImages
Linux images from old package (from Debian diff result).

.PARAMETER NewLinuxImages
Linux images from new package (from Debian diff result).

.PARAMETER OldWindowsImages
Windows images from old package (from Get-WindowsImagesFromPackage).

.PARAMETER NewWindowsImages
Windows images from new package (from Get-WindowsImagesFromPackage).

.OUTPUTS
Hashtable with Added, Removed, and Changed image references.
#>
function Compare-ContainerImages {
    param(
        [Parameter(Mandatory = $false)]
        [array]$OldLinuxImages = @(),

        [Parameter(Mandatory = $false)]
        [array]$NewLinuxImages = @(),

        [Parameter(Mandatory = $false)]
        [array]$OldWindowsImages = @(),

        [Parameter(Mandatory = $false)]
        [array]$NewWindowsImages = @()
    )

    $result = @{
        Added   = @()
        Removed = @()
        Changed = @()
    }

    Write-Log "[ImageDiff] Comparing container images between packages..." -Console

    # Compare Linux images
    if ($OldLinuxImages.Count -gt 0 -or $NewLinuxImages.Count -gt 0) {
        Write-Log "[ImageDiff] Comparing Linux images (buildah)..." -Console
        $result = Compare-ImageSets -OldImageSet $OldLinuxImages `
                                    -NewImageSet $NewLinuxImages `
                                    -Platform 'linux' `
                                    -Result $result
    }

    # Compare Windows images
    if ($OldWindowsImages.Count -gt 0 -or $NewWindowsImages.Count -gt 0) {
        Write-Log "[ImageDiff] Comparing Windows images..." -Console
        $result = Compare-ImageSets -OldImageSet $OldWindowsImages `
                                    -NewImageSet $NewWindowsImages `
                                    -Platform 'windows' `
                                    -Result $result
    }

    Write-Log "[ImageDiff] Comparison complete. Added: $($result.Added.Count), Removed: $($result.Removed.Count), Changed: $($result.Changed.Count)" -Console

    return $result
}

<#
.SYNOPSIS
Compares two sets of images (helper function).

.PARAMETER OldImageSet
Array of images from old package.

.PARAMETER NewImageSet
Array of images from new package.

.PARAMETER Platform
Platform identifier (linux or windows).

.PARAMETER Result
Result hashtable to update.

.OUTPUTS
Updated result hashtable.
#>
function Compare-ImageSets {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$OldImageSet,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$NewImageSet,

        [Parameter(Mandatory = $true)]
        [string]$Platform,

        [Parameter(Mandatory = $true)]
        [hashtable]$Result
    )

    # Build lookup maps by full name (repository:tag)
    $oldMap = @{}
    foreach ($img in $OldImageSet) {
        $oldMap[$img.FullName] = $img
    }

    $newMap = @{}
    foreach ($img in $NewImageSet) {
        $newMap[$img.FullName] = $img
    }

    # Find added images (in new but not in old)
    foreach ($imgName in $newMap.Keys) {
        if (-not $oldMap.ContainsKey($imgName)) {
            $Result.Added += [PSCustomObject]@{
                FullName = $imgName
                Platform = $Platform
                Image    = $newMap[$imgName]
            }
            Write-Log "[ImageDiff] Added: $imgName ($Platform)" -Console
        }
    }

    # Find removed images (in old but not in new)
    foreach ($imgName in $oldMap.Keys) {
        if (-not $newMap.ContainsKey($imgName)) {
            $Result.Removed += [PSCustomObject]@{
                FullName = $imgName
                Platform = $Platform
                Image    = $oldMap[$imgName]
            }
            Write-Log "[ImageDiff] Removed: $imgName ($Platform)" -Console
        }
    }

    # Find changed images (same name but different ID/digest)
    foreach ($imgName in $newMap.Keys) {
        if ($oldMap.ContainsKey($imgName)) {
            $oldImg = $oldMap[$imgName]
            $newImg = $newMap[$imgName]

            # For Linux images, compare by ImageId
            if ($Platform -eq 'linux') {
                $oldId = if ($oldImg.ImageId) { $oldImg.ImageId } elseif ($oldImg.Id) { $oldImg.Id } else { '' }
                $newId = if ($newImg.ImageId) { $newImg.ImageId } elseif ($newImg.Id) { $newImg.Id } else { '' }

                if ($oldId -and $newId -and $oldId -ne $newId) {
                    $Result.Changed += [PSCustomObject]@{
                        FullName = $imgName
                        Platform = $Platform
                        OldImage = $oldImg
                        NewImage = $newImg
                    }
                    Write-Log "[ImageDiff] Changed: $imgName ($Platform) - ID: $oldId -> $newId" -Console
                }
            }
            # For Windows images, compare by file size or assume changed
            elseif ($Platform -eq 'windows') {
                $oldSize = if ($oldImg.Size) { $oldImg.Size } else { 0 }
                $newSize = if ($newImg.Size) { $newImg.Size } else { 0 }

                if ($oldSize -ne $newSize) {
                    $Result.Changed += [PSCustomObject]@{
                        FullName = $imgName
                        Platform = $Platform
                        OldImage = $oldImg
                        NewImage = $newImg
                    }
                    Write-Log "[ImageDiff] Changed: $imgName ($Platform) - Size: $oldSize -> $newSize" -Console
                }
            }
        }
    }

    return $Result
}
