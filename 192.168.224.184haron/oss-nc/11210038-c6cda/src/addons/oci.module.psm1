# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
OCI Artifact module for K2s addon export/import operations

.DESCRIPTION
Provides functions for creating and consuming OCI artifacts with layered structure
for addon distribution supporting FluxCD and ArgoCD consumption.

Media Types:
- application/vnd.k2s.addon.config.v1+json     - Addon metadata configuration (JSON)
- application/vnd.k2s.addon.configfiles.v1.tar+gzip - Addon configuration files (addon.manifest.yaml, values.yaml, etc.)
- application/vnd.k2s.addon.manifests.v1.tar+gzip - Kubernetes manifests
- application/vnd.cncf.helm.chart.content.v1.tar+gzip - Helm charts
- application/vnd.k2s.addon.scripts.v1.tar+gzip - Enable/Disable scripts
- application/vnd.oci.image.layer.v1.tar       - Linux container images
- application/vnd.k2s.addon.images-windows.v1.tar - Windows container images
- application/vnd.k2s.addon.packages.v1.tar+gzip - Offline packages
#>

$infraModule = "$PSScriptRoot/../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$pathModule = "$PSScriptRoot/../lib/modules/windows/infra/k2s.infra.module/path/path.module.psm1"
Import-Module $infraModule, $pathModule

# OCI Media Types for K2s addon artifacts
$script:MediaTypes = @{
    Config      = 'application/vnd.k2s.addon.config.v1+json'
    ConfigFiles = 'application/vnd.k2s.addon.configfiles.v1.tar+gzip'
    Manifests   = 'application/vnd.k2s.addon.manifests.v1.tar+gzip'
    Charts      = 'application/vnd.cncf.helm.chart.content.v1.tar+gzip'
    Scripts     = 'application/vnd.k2s.addon.scripts.v1.tar+gzip'
    ImagesLinux = 'application/vnd.oci.image.layer.v1.tar'
    ImagesWindows = 'application/vnd.k2s.addon.images-windows.v1.tar'
    Packages    = 'application/vnd.k2s.addon.packages.v1.tar+gzip'
}

# OCI Image Layout version
$script:OciLayoutVersion = '1.0.0'

function Get-Sha256HexLower {
    <#
    .SYNOPSIS
    Computes SHA256 for a file and returns a lowercase hexadecimal hash
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash($stream)
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }

    return ([System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant())
}

function New-CompatTemporaryFile {
    <#
    .SYNOPSIS
    Creates a temporary file object compatible with New-TemporaryFile usage
    #>
    $tempPath = [System.IO.Path]::GetTempFileName()
    return [PSCustomObject]@{
        FullName = $tempPath
    }
}

function Get-OciMediaTypes {
    <#
    .SYNOPSIS
    Returns the media types used for OCI artifacts
    #>
    return $script:MediaTypes
}

function New-OciLayoutFile {
    <#
    .SYNOPSIS
    Creates the required oci-layout file for OCI Image Layout compliance
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$LayoutPath
    )
    
    $ociLayout = @{
        imageLayoutVersion = $script:OciLayoutVersion
    }
    
    $ociLayoutPath = Join-Path $LayoutPath 'oci-layout'
    $json = $ociLayout | ConvertTo-Json
    [System.IO.File]::WriteAllText($ociLayoutPath, $json, [System.Text.UTF8Encoding]::new($false))
    
    Write-Log "[OCI] Created oci-layout file with version $($script:OciLayoutVersion)"
    return $ociLayoutPath
}

function New-OciBlobsDirectory {
    <#
    .SYNOPSIS
    Creates the blobs/sha256 directory structure for OCI Image Layout
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$LayoutPath
    )
    
    $blobsDir = Join-Path $LayoutPath 'blobs\sha256'
    if (-not (Test-Path $blobsDir)) {
        New-Item -ItemType Directory -Path $blobsDir -Force | Out-Null
    }
    
    Write-Log "[OCI] Created blobs directory: $blobsDir"
    return $blobsDir
}

function Add-ContentToBlobs {
    <#
    .SYNOPSIS
    Adds content to the blobs directory and returns the digest
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$BlobsDir,
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $false)]
        [switch]$Move = $false
    )
    
    if (-not (Test-Path $SourcePath)) {
        throw "Source path not found: $SourcePath"
    }
    
    # Use .NET hashing to avoid dependency on Get-FileHash availability.
    $digest = Get-Sha256HexLower -Path $SourcePath
    $blobPath = Join-Path $BlobsDir $digest
    
    if ($Move) {
        Move-Item -Path $SourcePath -Destination $blobPath -Force
    } else {
        Copy-Item -Path $SourcePath -Destination $blobPath -Force
    }
    
    $size = (Get-Item $blobPath).Length
    
    return @{
        Digest = "sha256:$digest"
        Size = $size
        Path = $blobPath
    }
}

function Add-JsonContentToBlobs {
    <#
    .SYNOPSIS
    Converts an object to JSON and stores it in blobs directory
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$BlobsDir,
        [Parameter(Mandatory = $true)]
        [object]$Content
    )
    
    $tempFile = New-CompatTemporaryFile
    try {
        $json = $Content | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($tempFile.FullName, $json, [System.Text.UTF8Encoding]::new($false))
        $result = Add-ContentToBlobs -BlobsDir $BlobsDir -SourcePath $tempFile.FullName -Move
        return $result
    }
    finally {
        if (Test-Path $tempFile.FullName) {
            Remove-Item -Path $tempFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-BlobByDigest {
    <#
    .SYNOPSIS
    Retrieves blob content by digest from the blobs directory
    .DESCRIPTION
    Resolves a blob path from its digest and optionally verifies content integrity
    per OCI spec: "Retrieved content SHOULD be verified against this digest"
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$BlobsDir,
        [Parameter(Mandatory = $true)]
        [string]$Digest,
        [Parameter(Mandatory = $false)]
        [switch]$SkipVerification = $false
    )
    
    # Validate digest format: must be sha256:<64 hex chars>
    if ($Digest -notmatch '^sha256:[a-f0-9]{64}$') {
        throw "Invalid digest format: $Digest (expected sha256:<64 lowercase hex chars>)"
    }
    
    # Extract hash from digest (remove sha256: prefix)
    $hash = $Digest -replace '^sha256:', ''
    $blobPath = Join-Path $BlobsDir $hash
    
    if (-not (Test-Path $blobPath)) {
        throw "Blob not found for digest: $Digest"
    }
    
    # Verify content integrity per OCI Image Spec descriptor verification
    if (-not $SkipVerification) {
        $computedHash = Get-Sha256HexLower -Path $blobPath
        if ($computedHash -ne $hash) {
            throw "Blob integrity check failed for digest: $Digest (computed: sha256:$computedHash)"
        }
    }
    
    return $blobPath
}

function Get-JsonBlobByDigest {
    <#
    .SYNOPSIS
    Retrieves and parses JSON blob content by digest
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$BlobsDir,
        [Parameter(Mandatory = $true)]
        [string]$Digest
    )
    
    $blobPath = Get-BlobByDigest -BlobsDir $BlobsDir -Digest $Digest
    $content = Get-Content -Path $blobPath -Raw | ConvertFrom-Json
    return $content
}

function New-TarGzArchive {
    <#
    .SYNOPSIS
    Creates a tar.gz archive from a directory or files
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [Parameter(Mandatory = $false)]
        [string]$BasePath = $null,
        [Parameter(Mandatory = $false)]
        [switch]$ArchiveContents = $false
    )
    
    if (Test-Path $SourcePath -PathType Container) {
        # Directory - create tar.gz with relative paths
        $currentLocation = Get-Location
        try {
            if ($ArchiveContents) {
                # Archive the contents of the directory (cd into it and tar .)
                Set-Location $SourcePath
                $tarResult = & tar -czf $DestinationPath . 2>&1
            } elseif ($BasePath) {
                Set-Location $BasePath
                $relativePath = Resolve-Path -Path $SourcePath -Relative
                $tarResult = & tar -czf $DestinationPath $relativePath 2>&1
            } else {
                Set-Location (Split-Path $SourcePath -Parent)
                $relativePath = Split-Path $SourcePath -Leaf
                $tarResult = & tar -czf $DestinationPath $relativePath 2>&1
            }
            
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create tar.gz archive: $tarResult"
            }
        }
        finally {
            Set-Location $currentLocation
        }
    }
    else {
        # Single file
        $parentDir = Split-Path $SourcePath -Parent
        $fileName = Split-Path $SourcePath -Leaf
        $currentLocation = Get-Location
        try {
            Set-Location $parentDir
            $tarResult = & tar -czf $DestinationPath $fileName 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create tar.gz archive: $tarResult"
            }
        }
        finally {
            Set-Location $currentLocation
        }
    }
    
    return (Test-Path $DestinationPath)
}

function New-TarArchive {
    <#
    .SYNOPSIS
    Creates a tar archive from files
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$SourceFiles,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory = $null
    )
    
    if ($SourceFiles.Count -eq 0) {
        Write-Log "[OCI] No source files provided for tar archive"
        return $false
    }
    
    $currentLocation = Get-Location
    try {
        if ($WorkingDirectory) {
            Set-Location $WorkingDirectory
        }
        
        # Build relative file list
        $relativeFiles = @()
        foreach ($file in $SourceFiles) {
            if (Test-Path $file) {
                if ($WorkingDirectory) {
                    $relativeFiles += Resolve-Path -Path $file -Relative -ErrorAction SilentlyContinue
                } else {
                    $relativeFiles += $file
                }
            }
        }
        
        if ($relativeFiles.Count -gt 0) {
            $tarResult = & tar -cvf $DestinationPath $relativeFiles 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Log "[OCI] Warning: tar command returned non-zero: $tarResult"
            }
        }
    }
    finally {
        Set-Location $currentLocation
    }
    
    return (Test-Path $DestinationPath)
}

function Expand-TarGzArchive {
    <#
    .SYNOPSIS
    Extracts a tar.gz archive to a destination directory
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )
    
    if (-not (Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
    
    $currentLocation = Get-Location
    try {
        Set-Location $DestinationPath
        
        $tarResult = & tar -xzf $ArchivePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract tar.gz archive: $tarResult"
        }
    }
    finally {
        Set-Location $currentLocation
    }
    
    return $true
}

function ConvertTo-ImageTarFileName {
    <#
    .SYNOPSIS
    Converts a container image reference into the deterministic tar file name used inside
    the images-linux.tar / images-windows.tar layers.

    .DESCRIPTION
    Single source of truth for the sanitization rule. Both the exporter (when writing the
    per-image tars) and the importer (when deciding which tars to skip) must use this
    function so the names can never drift apart.

    The conversion is intentionally forward-only: 'repo/name:tag' -> 'repo_name_tag.tar'.
    It is lossy (both ':' and '/' collapse to '_'), therefore callers must never try to
    reconstruct a reference from a file name.

    .PARAMETER Image
    The container image reference, e.g. 'quay.io/keycloak/keycloak:26.7.2'.

    .PARAMETER Windows
    Produce the Windows variant of the name (prefixed with 'windows_').

    .EXAMPLE
    ConvertTo-ImageTarFileName -Image 'quay.io/keycloak/keycloak:26.7.2'
    # -> quay.io_keycloak_keycloak_26.7.2.tar
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Image,
        [Parameter(Mandatory = $false)]
        [switch]$Windows
    )

    $sanitizedImageName = ($Image -replace '[:/]', '_') -replace '[^a-zA-Z0-9_.-]', ''

    if ($Windows) {
        return "windows_${sanitizedImageName}.tar"
    }

    return "${sanitizedImageName}.tar"
}

function Get-TarEntryName {
    <#
    .SYNOPSIS
    Lists the file entry names contained in a tar archive without extracting it.

    .DESCRIPTION
    Uses 'tar -tf' which only reads the archive index, so this is cheap even for
    multi-GB image layers. Returns normalized leaf names (directory entries and any
    leading './' are stripped).

    .PARAMETER ArchivePath
    Path to the tar archive. May be null or empty (an addon layer that does not exist,
    e.g. a Linux-only addon has no Windows images layer); an empty result is returned then.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ArchivePath
    )

    if ([string]::IsNullOrWhiteSpace($ArchivePath) -or -not (Test-Path $ArchivePath)) {
        return @()
    }

    $errorLines = @()
    $listing = & tar -tf $ArchivePath 2>&1 | ForEach-Object {
        # tar writes warnings/errors to stderr; with '2>&1' those arrive as ErrorRecord objects.
        # They must never end up in the entry list, otherwise a warning text could be mistaken
        # for an image tar name.
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $errorLines += "$_"
        }
        else {
            $_
        }
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Log "[OCI] Warning: unable to list entries of '$ArchivePath': $($errorLines -join '; ')"
        return @()
    }

    if ($errorLines.Count -gt 0) {
        Write-Log "[OCI] 'tar -tf $ArchivePath' reported: $($errorLines -join '; ')"
    }

    $names = @()
    foreach ($line in @($listing)) {
        $name = "$line".Trim()
        if ($name -eq '') {
            continue
        }

        $name = $name -replace '\\', '/'
        $name = $name -replace '^\./', ''

        # skip directory entries
        if ($name.EndsWith('/')) {
            continue
        }

        $separatorIndex = $name.LastIndexOf('/')
        if ($separatorIndex -ge 0) {
            $name = $name.Substring($separatorIndex + 1)
        }

        if ($name -ne '') {
            $names += $name
        }
    }

    return @($names | Select-Object -Unique)
}

function Expand-TarArchive {
    <#
    .SYNOPSIS
    Extracts a tar archive to a destination directory
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )
    
    if (-not (Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
    
    $currentLocation = Get-Location
    try {
        Set-Location $DestinationPath
        
        $tarResult = & tar -xf $ArchivePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract tar archive: $tarResult"
        }
    }
    finally {
        Set-Location $currentLocation
    }
    
    return $true
}

Export-ModuleMember -Function Get-OciMediaTypes,
    New-OciLayoutFile, New-OciBlobsDirectory, Add-ContentToBlobs, Add-JsonContentToBlobs,
    Get-BlobByDigest, Get-JsonBlobByDigest,
    New-TarGzArchive, New-TarArchive, Expand-TarGzArchive, Expand-TarArchive,
    ConvertTo-ImageTarFileName, Get-TarEntryName
