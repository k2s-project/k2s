# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# Import.ps1


Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Path to OCI artifact tar file')]
    [string] $ArtifactFile,
    [parameter(Mandatory = $false, HelpMessage = 'Name of Addons to import')]
    [string[]] $Names,
    [parameter(Mandatory = $false, HelpMessage = 'Target node name(s) for addon image import (comma-separated, e.g. worker-1,worker-2); defaults to control-plane and local Windows host when omitted')]
    [string] $Nodes = '',
    [parameter(Mandatory = $false, HelpMessage = "Addon omit options, e.g. 'omitCertMgr' or 'ingress/nginx:omitCertMgr'. Images belonging to the omitted functionality are not imported.")]
    [string[]] $Omit = @(),
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot\..\lib\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\lib\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\addons.module.psm1"
$ociModule = "$PSScriptRoot\oci.module.psm1"
$imagePruneModule = "$PSScriptRoot\imageprune.module.psm1"
$importImageScript = "$PSScriptRoot\..\lib\scripts\windows\host\image\Import-Image.ps1"
$imageCommonModule = "$PSScriptRoot\..\lib\scripts\windows\host\image\Image-Common.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $ociModule, $imagePruneModule, $imageCommonModule

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

function Import-AddonImageLayer {
    <#
    .SYNOPSIS
    Extracts a staged image layer tar and imports its images via Import-Image.ps1.

    .DESCRIPTION
    Shared by the Layer 4 (Linux) and Layer 5 (Windows) image import sections. Sets
    $script:hasImportFailures on any extraction/import failure so the caller can
    propagate the overall command result.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $LayerTarPath,
        [Parameter(Mandatory = $true)]
        [string] $TempLayerDir,
        [Parameter(Mandatory = $true)]
        [string] $ExtractedDirName,
        [Parameter(Mandatory = $false)]
        [string[]] $TargetNodes = @(),
        [Parameter(Mandatory = $false)]
        [switch] $Windows,
        [Parameter(Mandatory = $true)]
        [string] $AddonName,
        [Parameter(Mandatory = $true)]
        [string] $ImportImageScript,
        [Parameter(Mandatory = $false)]
        [switch] $ShowLogs,
        [Parameter(Mandatory = $false)]
        [string[]] $SkipTarNames = @(),
        [Parameter(Mandatory = $false)]
        [string] $AddonKey = ''
    )

    if ([string]::IsNullOrWhiteSpace($AddonKey)) {
        $AddonKey = $AddonName
    }

    $osLabel = if ($Windows) { 'Windows' } else { 'Linux' }
    Write-Log "[Import] Importing $osLabel images layer from blob" -Console

    # Check if this is a consolidated tar (tar of tars) or single image tar
    $tempImagesDir = Join-Path $TempLayerDir $ExtractedDirName
    if (-not (Test-Path $tempImagesDir)) {
        New-Item -ItemType Directory -Path $tempImagesDir -Force | Out-Null
    }

    # Extract the tar file
    $extractFailed = $false
    $currentLocation = Get-Location
    try {
        Set-Location $tempImagesDir
        $extractResult = & tar -xf $LayerTarPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "[Import] Warning: Failed to extract $osLabel images tar: $extractResult" -Console
            $script:hasImportFailures = $true
            $extractFailed = $true
        }
    }
    finally {
        Set-Location $currentLocation
    }

    # Drop the images that no imported addon requires (see prune plan)
    $skippedTarCount = 0
    foreach ($tarToSkip in @($SkipTarNames)) {
        $skipPath = Join-Path $tempImagesDir $tarToSkip
        if (Test-Path $skipPath) {
            Remove-Item -Path $skipPath -Force -ErrorAction SilentlyContinue
            Write-Log "[Prune] Not importing '$tarToSkip' for '$AddonKey'" -Console
            $skippedTarCount++
        }
    }

    # Check if we extracted individual image tars or a single image
    $extractedTars = Get-ChildItem -Path $tempImagesDir -Filter '*.tar' -File
    $imageFiles = Get-ChildItem -Path $tempImagesDir -Recurse -File

    Write-Log "[Import] Extracted files in $tempImagesDir`: $($extractedTars.Count) tars" -Console
    if ($extractedTars.Count -gt 0) {
        foreach ($tar in $extractedTars) {
            Write-Log "[Import]   - $($tar.Name) ($([math]::Round($tar.Length / 1MB, 2)) MB)" -Console
        }
    }

    if ($extractedTars.Count -gt 0 -or $imageFiles.Count -gt 0) {
        if ($TargetNodes -and $TargetNodes.Count -gt 0) {
            $importResult = &$ImportImageScript -ImageDir $tempImagesDir -Windows:$Windows -Nodes ($TargetNodes -join ',') -ShowLogs:$ShowLogs -ReturnStatus
        } else {
            $importResult = &$ImportImageScript -ImageDir $tempImagesDir -Windows:$Windows -ShowLogs:$ShowLogs -ReturnStatus
        }
        if ($importResult -isnot [bool] -or -not $importResult) {
            Write-Log "[Import] Warning: $osLabel images import failed for $AddonName" -Console
            $script:hasImportFailures = $true
        } else {
            Write-Log "[Import] $osLabel images imported successfully for $AddonName" -Console
        }
    } elseif (-not $extractFailed -and $skippedTarCount -gt 0) {
        Write-Log "All $osLabel images of '$AddonKey' were skipped due to the requested omit options" -Console
    } else {
        Write-Log "[Import] Warning: No $osLabel image files found after extraction" -Console
        Write-Log "[Import] Warning: $osLabel images import failed for $AddonName with exit code 1" -Console
        $script:hasImportFailures = $true
    }

    # Cleanup extracted images
    Remove-Item -Path $tempImagesDir -Recurse -Force -ErrorAction SilentlyContinue
}

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$setupInfo = Get-SetupInfo

$linuxNodes = @()
$windowsNodes = @()
$script:hasImportFailures = $false

$nodeList = Resolve-NodeList -Nodes $Nodes
if ($nodeList.Count -gt 0) {
    foreach ($node in $nodeList) {
        $targetNode = Resolve-ImageNode -NodeName $node
        if ($null -eq $targetNode) {
            $nodeError = New-Error -Severity Warning -Code 'import-node-not-found' -Message "Node '$node' was not found in the cluster - run 'kubectl get nodes' to list available nodes"
            if ($EncodeStructuredOutput -eq $true) {
                Send-ToCli -MessageType $MessageType -Message @{Error = $nodeError }
                return
            }
            Write-Log "[Import] $($nodeError.Message)" -Error
            exit 1
        }
        if (-not (Test-NodeReady -NodeName $node -Kind $targetNode.Kind)) {
            $nodeError = New-Error -Severity Warning -Code 'import-node-not-ready' -Message "Node '$node' is not in Ready state - run 'kubectl get nodes' to check node status"
            if ($EncodeStructuredOutput -eq $true) {
                Send-ToCli -MessageType $MessageType -Message @{Error = $nodeError }
                return
            }
            Write-Log "[Import] $($nodeError.Message)" -Error
            exit 1
        }
        if ($targetNode.OS -eq 'linux') {
            $linuxNodes += $node
        }
        elseif ($targetNode.OS -eq 'windows') {
            $windowsNodes += $node
        }
    }
}

$tmpDir = "$env:TEMP\$(Get-Date -Format ddMMyyyy-HHmmss)-tmp-extracted-addons"
$extractionFolder = $tmpDir

# Import targets are node-specific. When the user imports to a Linux worker,
# only the Linux image layer should be applied there; Windows-only images must stay
# on the Windows target(s). The same rule applies in reverse for Windows workers.
# Base the decision on the full set of resolved target nodes (not a single node),
# so a mixed '--nodes' list (e.g. control-plane + Linux workers + Windows host) imports
# both layers to their matching targets.
$shouldImportLinuxImages = $true
$shouldImportWindowsImages = $true

if (-not [string]::IsNullOrWhiteSpace($Nodes)) {
    $shouldImportLinuxImages = $linuxNodes.Count -gt 0
    $shouldImportWindowsImages = $windowsNodes.Count -gt 0
}
elseif ($setupInfo.LinuxOnly) {
    $shouldImportWindowsImages = $false
}

if ($ArtifactFile) {
    Write-Log "Extracting artifact from $ArtifactFile" -Console
    Write-Log '---' -Console

    Remove-Item -Force $extractionFolder -Recurse -Confirm:$False -ErrorAction SilentlyContinue

    # Check disk space
    $artifactSize = (Get-Item $ArtifactFile).length
    $drive = (Get-Item $env:TEMP).PSDrive.Name
    $freeSpace = (Get-PSDrive -Name $drive).Free
    $freeSpaceGB = [math]::Round($freeSpace / 1GB, 2)
    $artifactSizeGB = [math]::Round($artifactSize / 1GB, 2)
    $additionalSpace = 2 * 1024 * 1024 * 1024 # 2 GB

    Write-Log "Free space $freeSpaceGB GB, size of artifact file: $artifactSizeGB GB" -Console

    if ($artifactSize -gt ($freeSpace + $additionalSpace)) {
        $errMsg = "Not enough space on drive $drive to extract the artifact. Required space: $artifactSize bytes, Free space: $freeSpace bytes."
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-space-insufficient' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    # Detect format and extract
    if ($ArtifactFile -match '\.oci\.tar$') {
        # OCI tar artifact
        Write-Log "Detected OCI artifact format" -Console
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

        $currentLocation = Get-Location
        try {
            Set-Location $tmpDir
            $tarResult = & tar -xf $ArtifactFile 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to extract OCI tar: $tarResult"
            }
        }
        finally {
            Set-Location $currentLocation
        }
    }
    else {
        $errMsg = "Unknown artifact format. Supported formats: .oci.tar"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-format-invalid' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
}
else {
    $errMsg = "No artifact source specified. Provide -ArtifactFile parameter."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-source-missing' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# Process OCI artifact
$addonsToImport = @()

# OCI Artifact format processing
Write-Log "Processing OCI artifact structure" -Console

# Verify OCI Image Layout compliance
$ociLayoutPath = Join-Path $extractionFolder 'oci-layout'
if (-not (Test-Path $ociLayoutPath)) {
    $errMsg = 'Invalid OCI artifact format: oci-layout file not found.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-format-invalid' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

$ociLayout = Get-Content $ociLayoutPath | ConvertFrom-Json
Write-Log "OCI Layout version: $($ociLayout.imageLayoutVersion)" -Console

# Validate OCI Image Layout version per spec (MUST be "1.0.0")
if ($ociLayout.imageLayoutVersion -ne '1.0.0') {
    $errMsg = "Unsupported OCI Image Layout version: '$($ociLayout.imageLayoutVersion)' (expected '1.0.0')"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-format-invalid' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# Verify blobs directory exists
$blobsDir = Join-Path $extractionFolder 'blobs\sha256'
if (-not (Test-Path $blobsDir)) {
    $errMsg = 'Invalid OCI artifact format: blobs/sha256 directory not found.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-format-invalid' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# Read index.json to get addon list from OCI-compliant structure
$indexJsonPath = Join-Path $extractionFolder 'index.json'
if (-not (Test-Path $indexJsonPath)) {
    $errMsg = 'Invalid OCI artifact format: index.json not found.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-format-invalid' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

$indexManifest = Get-Content $indexJsonPath | Out-String | ConvertFrom-Json

# Validate OCI Image Index required fields per spec
if ($indexManifest.schemaVersion -ne 2) {
    $errMsg = "Invalid OCI image index: schemaVersion must be 2, got '$($indexManifest.schemaVersion)'"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-format-invalid' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

if ($indexManifest.mediaType -and $indexManifest.mediaType -ne 'application/vnd.oci.image.index.v1+json') {
    Write-Log "Warning: Unexpected index.json mediaType: '$($indexManifest.mediaType)' (expected 'application/vnd.oci.image.index.v1+json')" -Console
}

$exportedAddons = @()
foreach ($manifest in $indexManifest.manifests) {
    $addonName = $manifest.annotations.'vnd.k2s.addon.name'
    $addonImplementation = $manifest.annotations.'vnd.k2s.addon.implementation'
    $addonVersion = $manifest.annotations.'org.opencontainers.image.version'

    if ($manifest.digest) {
        try {
            $innerManifest = Get-JsonBlobByDigest -BlobsDir $blobsDir -Digest $manifest.digest
            if ($innerManifest.annotations) {
                $innerAddonName = $innerManifest.annotations.'vnd.k2s.addon.name'
                if ($innerAddonName) {
                    $addonName = $innerAddonName
                    $addonImplementation = $innerManifest.annotations.'vnd.k2s.addon.implementation'
                    $addonVersion = $innerManifest.annotations.'org.opencontainers.image.version'
                }
            }
        }
        catch {
            Write-Log "Warning: Could not read addon annotations from manifest blob $($manifest.digest): $_" -Console
        }
    }

    $exportedAddons += @{
        name = $addonName
        implementation = $addonImplementation
        version = $addonVersion
        manifestDigest = $manifest.digest
        manifestSize = $manifest.size
    }
}

if ($null -eq $exportedAddons -or $exportedAddons.Count -lt 1) {
    $errMsg = 'Invalid OCI artifact format: no addons found.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-format-invalid' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# Resolve requested addon names. A request can be a base addon (`ingress`), a quoted
# implementation (`ingress traefik`), or two unquoted tokens (`ingress traefik`).
if ($Names.Count -gt 0) {
    $i = 0
    while ($i -lt $Names.Count) {
        $name = $Names[$i]
        $parts = @($name -split '\s+' | Where-Object { $_ })
        $requestedName = $name
        $requestedImplementation = $null

        if ($parts.Count -gt 1) {
            $requestedName = $parts[0]
            $requestedImplementation = ($parts[1..($parts.Count - 1)] -join '-')
        }
        elseif ($i + 1 -lt $Names.Count) {
            $nextName = $Names[$i + 1]
            $matchesImplementation = $exportedAddons | Where-Object { $_.name -eq $name -and $_.implementation -eq $nextName }

            if ($matchesImplementation) {
                Write-Log "Recognized addon implementation: '$name $nextName'" -Console
                $addonsToImport += $matchesImplementation
                $i += 2
                continue
            }
        }

        $normalizedName = $requestedName -replace '\s+', '-'
        if ($requestedImplementation) {
            $foundAddons = $exportedAddons | Where-Object { ($_.name -eq $normalizedName -or $_.name -eq $requestedName) -and $_.implementation -eq $requestedImplementation }
        }
        else {
            $foundAddons = $exportedAddons | Where-Object { $_.name -eq $normalizedName -or $_.name -eq $requestedName }
        }

        if ($null -eq $foundAddons -and -not $requestedImplementation) {
            # Accept legacy flattened requests like ingress-traefik for corrected metadata.
            $foundAddons = $exportedAddons | Where-Object { "$($_.name)-$($_.implementation)" -eq $normalizedName }
        }

        if ($null -eq $foundAddons) {
            Remove-Item -Force $tmpDir -Recurse -Confirm:$False -ErrorAction SilentlyContinue
            $errMsg = "Addon '$name' not found in OCI artifact for import!"
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code (Get-ErrCodeAddonNotFound) -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }
            Write-Log $errMsg -Error
            exit 1
        }
        $addonsToImport += $foundAddons
        $i++
    }

    # Deduplicate in case of multiple matches
    $addonsToImport = $addonsToImport | Sort-Object -Property { $_.name }, { $_.implementation } -Unique
}
else {
    $addonsToImport = $exportedAddons
}

# Phase 1: extract the non-image layers of every selected addon and collect the data needed
# to compute a GLOBAL image pruning plan. Image layers are only referenced here (never copied),
# the actual image import happens in phase 3.
$importPlan = @()

foreach ($addon in $addonsToImport) {
    Write-Log "Importing addon: $($addon.name)" -Console

    # Read manifest from blobs using digest
    $ociManifest = $null
    if ($addon.manifestDigest) {
        $ociManifest = Get-JsonBlobByDigest -BlobsDir $blobsDir -Digest $addon.manifestDigest

        # Validate manifest schemaVersion per OCI Image Manifest spec
        if ($ociManifest.schemaVersion -ne 2) {
            Write-Log "Warning: Unexpected manifest schemaVersion '$($ociManifest.schemaVersion)' for $($addon.name) (expected 2)" -Console
        }

        Write-Log "-> Manifest digest: $($addon.manifestDigest)"
        Write-Log "-> Version: $($ociManifest.annotations.'org.opencontainers.image.version')"
        Write-Log "-> K2s Version: $($ociManifest.annotations.'vnd.k2s.version')"
        Write-Log "-> Export Date: $($ociManifest.annotations.'org.opencontainers.image.created')"
    } else {
        Write-Log "Warning: No manifest digest for addon $($addon.name)" -Console
        continue
    }

    # Resolve addon folder path using OCI annotation metadata
    $resolved = Resolve-AddonImportPath -AddonName $addon.name -AddonImplementation $addon.implementation
    $baseAddonName = $resolved.BaseAddonName
    $implementationName = $resolved.ImplementationName

    # Build destination path: addons/<base-addon-name>
    $folderParts = $baseAddonName -split '\s+'
    $destinationPath = $PSScriptRoot
    foreach ($part in $folderParts) {
        $destinationPath = Join-Path -Path $destinationPath -ChildPath $part
    }

    # For multi-implementation addons, create implementation subdirectory
    $implementationPath = $destinationPath
    if ($implementationName) {
        $implementationPath = Join-Path $destinationPath $implementationName
        Write-Log "Destination: $implementationPath (base addon: $baseAddonName, implementation: $implementationName)"
    } else {
        Write-Log "Destination: $destinationPath (addon: $baseAddonName)"
    }

    # Ensure base destination path exists
    if (-not (Test-Path $destinationPath)) {
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
    }

    # For multi-implementation addons, create the implementation subdirectory
    if ($implementationName -and -not (Test-Path $implementationPath)) {
        New-Item -ItemType Directory -Path $implementationPath -Force | Out-Null
    }

    # Create temp directory for extracting layers from blobs.
    # The key must include the implementation, otherwise multi-implementation addons
    # (e.g. ingress nginx/traefik/nginx-gw) would all share one directory and leak
    # layer content into each other.
    $addonKey = $addon.name
    if (-not [string]::IsNullOrWhiteSpace($addon.implementation) -and $addon.implementation -ne $addon.name) {
        $addonKey = "$($addon.name)/$($addon.implementation)"
    }
    $tempLayerDirName = 'layer-temp-' + ($addonKey -replace '[\\/\s]', '-')
    $tempLayerDir = Join-Path $tmpDir $tempLayerDirName
    Remove-Item -Path $tempLayerDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $tempLayerDir -Force | Out-Null

    # Snapshot the addon manifest of the local installation BEFORE any config-layer
    # processing runs. The config/manifest handling further down replaces that file with
    # the manifest carried in the artifact (directly for single-level addons, and via the
    # 'yq not found' fallback for the merge paths). Without this snapshot the installed
    # manifest would no longer be available as fallback source for the omit options, which
    # would silently disable '--omit' for artifacts exported before 'omittedImages' existed.
    $installedManifestSnapshot = $null
    $installedManifestCandidates = @(Join-Path $destinationPath 'addon.manifest.yaml')
    if ($folderParts.Count -gt 1) {
        # space-separated addon names keep their manifest in the parent folder
        $installedManifestCandidates += (Join-Path (Split-Path -Path $destinationPath -Parent) 'addon.manifest.yaml')
    }
    foreach ($installedManifestCandidate in $installedManifestCandidates) {
        if (Test-Path $installedManifestCandidate) {
            $installedManifestSnapshot = Join-Path $tempLayerDir 'installed-addon.manifest.yaml'
            Copy-Item -Path $installedManifestCandidate -Destination $installedManifestSnapshot -Force
            Write-Log "[Prune] Snapshotted installed addon manifest from '$installedManifestCandidate'"
            break
        }
    }

    # Image layer blobs are referenced, not copied - copying would duplicate the largest
    # blobs of the artifact in %TEMP%.
    $linuxImagesBlob = $null
    $windowsImagesBlob = $null

    # Process each layer from manifest by resolving from blobs
    foreach ($layer in $ociManifest.layers) {
        $layerTitle = $layer.annotations.'org.opencontainers.image.title'
        $layerDigest = $layer.digest
        $layerMediaType = $layer.mediaType

        # Skip OCI empty descriptors (used as fallback for addons with no content layers)
        if ($layerMediaType -eq 'application/vnd.oci.empty.v1+json') {
            Write-Log "Skipping OCI empty descriptor layer"
            continue
        }

        Write-Log "Processing layer: $layerTitle ($layerDigest)"

        # Get the blob path for this layer (includes digest verification)
        $blobPath = Get-BlobByDigest -BlobsDir $blobsDir -Digest $layerDigest

        # Verify blob size matches descriptor size per OCI spec
        $actualSize = (Get-Item $blobPath).Length
        if ($layer.size -and $actualSize -ne $layer.size) {
            Write-Log "Warning: Size mismatch for layer $layerTitle - descriptor: $($layer.size), actual: $actualSize" -Console
        }

        switch -Wildcard ($layerMediaType) {
            '*configfiles*' {
                # Layer 0: Configuration files (addon.manifest.yaml, values.yaml, settings.json, etc.)
                Write-Log "Extracting config files layer from blob"
                $tempConfigDir = Join-Path $tempLayerDir 'config'
                New-Item -ItemType Directory -Path $tempConfigDir -Force | Out-Null
                Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $tempConfigDir
                Write-Log "Staged config files layer for processing"
                break
            }
            '*manifests*' {
                # Layer 1: Manifests - extract to implementation path for multi-impl addons
                Write-Log "Extracting manifests layer from blob"
                $manifestsDestDir = Join-Path $implementationPath 'manifests'
                New-Item -ItemType Directory -Path $manifestsDestDir -Force | Out-Null
                Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $manifestsDestDir
                break
            }
            '*helm.chart*' {
                # Layer 2: Charts - extract to implementation path for multi-impl addons
                Write-Log "Extracting charts layer from blob"
                $chartsDestDir = Join-Path $implementationPath 'manifests\chart'
                New-Item -ItemType Directory -Path $chartsDestDir -Force | Out-Null
                Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $chartsDestDir
                break
            }
            '*scripts*' {
                # Layer 3: Scripts - extract to implementation path for multi-impl addons
                Write-Log "Extracting scripts layer from blob"
                Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $implementationPath
                break
            }
            '*images-windows*' {
                # Layer 5: Windows Images - referenced for later processing
                $windowsImagesBlob = $blobPath
                Write-Log "Staged Windows images layer for import"
                break
            }
            '*image.layer*' {
                # Layer 4: Linux Images - referenced for later processing
                $linuxImagesBlob = $blobPath
                Write-Log "Staged Linux images layer for import"
                break
            }
            '*packages*' {
                # Layer 6: Packages - extract to temp for processing
                $tempPackagesDir = Join-Path $tempLayerDir 'packages'
                New-Item -ItemType Directory -Path $tempPackagesDir -Force | Out-Null
                Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $tempPackagesDir
                Write-Log "Staged packages layer for import"
                break
            }
        }
    }

    # Handle config files from the config layer (Layer 0)
    $tempConfigDir = Join-Path $tempLayerDir 'config'
    $configManifestPath = $null
    if (Test-Path $tempConfigDir) {
        # Look for addon.manifest.yaml in the config layer
        $configManifestPath = Join-Path $tempConfigDir 'addon.manifest.yaml'
        if (-not (Test-Path $configManifestPath)) {
            $configManifestPath = $null
        }

        # Handle addon.manifest.yaml merging for multi-implementation addons
        if ($configManifestPath -and (Test-Path $configManifestPath)) {
            $destManifestPath = Join-Path $destinationPath 'addon.manifest.yaml'
            if (Test-Path $destManifestPath) {
                # Existing manifest - need to merge implementations
                Write-Log "Merging addon.manifest.yaml implementations" -Console

                $existingManifest = Get-FromYamlFile -Path $destManifestPath
                $importedManifest = Get-FromYamlFile -Path $configManifestPath
                $existingImplNames = $existingManifest.spec.implementations | ForEach-Object { $_.name }

                Write-Log "Existing implementations: $($existingImplNames -join ', ')"
                $importedImplNames = $importedManifest.spec.implementations | ForEach-Object { $_.name }
                Write-Log "Imported implementations: $($importedImplNames -join ', ')"

                foreach ($importedImpl in $importedManifest.spec.implementations) {
                    if ($importedImpl.name -notin $existingImplNames) {
                        Write-Log "Adding new implementation: $($importedImpl.name)" -Console
                        $existingManifest.spec.implementations += $importedImpl
                    } else {
                        Write-Log "Implementation '$($importedImpl.name)' already exists, skipping" -Console
                    }
                }

                $kubeBinPath = Get-KubeBinPath
                $yqExe = Join-Path $kubeBinPath "windowsnode\yaml\yq.exe"

                if (Test-Path $yqExe) {
                    $tempJsonFile = New-CompatTemporaryFile
                    try {
                        $originalContent = Get-Content -Path $destManifestPath -Raw -Encoding UTF8
                        $headerLines = @()
                        foreach ($line in ($originalContent -split "`r?`n")) {
                            if ($line.StartsWith("#") -or $line.Trim() -eq "") {
                                $headerLines += $line
                            } else {
                                break
                            }
                        }

                        $mergedJson = $existingManifest | ConvertTo-Json -Depth 100
                        Set-Content -Path $tempJsonFile.FullName -Value $mergedJson -Encoding UTF8

                        $yamlOutput = & $yqExe eval -P '.' $tempJsonFile.FullName
                        if ($yamlOutput -is [array]) {
                            $yamlContent = $yamlOutput -join "`n"
                        } else {
                            $yamlContent = $yamlOutput.ToString()
                        }

                        $finalContent = ($headerLines -join "`n") + "`n" + $yamlContent
                        Set-Content -Path $destManifestPath -Value $finalContent -Encoding UTF8
                        Write-Log "Merged manifest saved to: $destManifestPath" -Console
                    } finally {
                        Remove-Item -Path $tempJsonFile.FullName -Force -ErrorAction SilentlyContinue
                    }
                } else {
                    Write-Log "Warning: yq.exe not found, copying manifest as-is"
                    Copy-Item -Path $configManifestPath -Destination $destManifestPath -Force
                }
            } else {
                # No existing manifest - just copy
                Copy-Item -Path $configManifestPath -Destination $destManifestPath -Force
            }
        }

        # Copy any additional config files to the implementation path (values.yaml, settings.json, etc.)
        Get-ChildItem -Path $tempConfigDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'addon.manifest.yaml' } | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $implementationPath -Force
            Write-Log "Copied config file: $($_.Name)"
        }

        # Copy config subdirectory if present
        $configSubDir = Join-Path $tempConfigDir 'config'
        if (Test-Path $configSubDir) {
            $destConfigSubDir = Join-Path $implementationPath 'config'
            New-Item -ItemType Directory -Path $destConfigSubDir -Force | Out-Null
            Copy-Item -Path (Join-Path $configSubDir '*') -Destination $destConfigSubDir -Recurse -Force
            Write-Log "Copied config subdirectory"
        }
    }



    Write-Log "Looking for manifest at: $configManifestPath"
    if ($configManifestPath -and (Test-Path $configManifestPath)) {
        $importedManifest = Get-FromYamlFile -Path $configManifestPath

        if ($implementationName) {
            # Just log and skip - the yq-based merging has already handled this
            Write-Log "Multi-implementation addon '$baseAddonName/$implementationName' - manifest merging already completed"

            # Remove stray manifest in implementation folder if it exists
            $manifestAtImpl = Join-Path $implementationPath "addon.manifest.yaml"
            if (Test-Path $manifestAtImpl) {
                Remove-Item -Path $manifestAtImpl -Force
                Write-Log "Removed stray manifest from implementation folder"
            }
        }
        elseif ($folderParts.Count -gt 1) {
            # Space-separated addon name (e.g., "gpu node"): merge with parent manifest
            $parentAddonFolder = Split-Path -Path $destinationPath -Parent
            $parentManifestPath = Join-Path $parentAddonFolder "addon.manifest.yaml"

            if (-not (Test-Path $parentAddonFolder)) {
                New-Item -ItemType Directory -Path $parentAddonFolder -Force | Out-Null
            }

            if (Test-Path $parentManifestPath) {
                Write-Log "Merging with existing manifest at: $parentManifestPath" -Console
                $existingManifest = Get-FromYamlFile -Path $parentManifestPath
                $existingImplNames = $existingManifest.spec.implementations | ForEach-Object { $_.name }

                foreach ($importedImpl in $importedManifest.spec.implementations) {
                    if ($importedImpl.name -notin $existingImplNames) {
                        Write-Log "Adding new implementation: $($importedImpl.name)" -Console
                        $existingManifest.spec.implementations += $importedImpl
                    } else {
                        Write-Log "Implementation '$($importedImpl.name)' already exists, updating" -Console
                        for ($i = 0; $i -lt $existingManifest.spec.implementations.Count; $i++) {
                            if ($existingManifest.spec.implementations[$i].name -eq $importedImpl.name) {
                                $existingManifest.spec.implementations[$i] = $importedImpl
                                break
                            }
                        }
                    }
                }

                $kubeBinPath = Get-KubeBinPath
                $yqExe = Join-Path $kubeBinPath "windowsnode\yaml\yq.exe"

                if (Test-Path $yqExe) {
                    $tempJsonFile = New-CompatTemporaryFile
                    try {
                        $originalContent = Get-Content -Path $parentManifestPath -Raw -Encoding UTF8
                        $headerLines = @()
                        foreach ($line in ($originalContent -split "`r?`n")) {
                            if ($line.StartsWith("#") -or $line.Trim() -eq "") {
                                $headerLines += $line
                            } else {
                                break
                            }
                        }

                        $mergedJson = $existingManifest | ConvertTo-Json -Depth 100
                        Set-Content -Path $tempJsonFile.FullName -Value $mergedJson -Encoding UTF8

                        $yamlOutput = & $yqExe eval -P '.' $tempJsonFile.FullName
                        if ($yamlOutput -is [array]) {
                            $yamlContent = $yamlOutput -join "`n"
                        } else {
                            $yamlContent = $yamlOutput.ToString()
                        }

                        $finalContent = ($headerLines -join "`n") + "`n" + $yamlContent
                        Set-Content -Path $parentManifestPath -Value $finalContent -Encoding UTF8
                        Write-Log "Merged manifest saved to: $parentManifestPath" -Console
                    } finally {
                        Remove-Item -Path $tempJsonFile.FullName -Force -ErrorAction SilentlyContinue
                    }
                } else {
                    Write-Log "Warning: yq.exe not found, copying manifest as-is"
                    Copy-Item -Path $configManifestPath -Destination $parentManifestPath -Force
                }
            } else {
                Copy-Item -Path $configManifestPath -Destination $parentManifestPath -Force
                Write-Log "New manifest created at: $parentManifestPath" -Console
            }

            # Remove stray manifest in implementation folder
            $manifestAtImpl = Join-Path $destinationPath "addon.manifest.yaml"
            if (Test-Path $manifestAtImpl) {
                Remove-Item -Path $manifestAtImpl -Force
            }
        }
        else {
            # Single-level addon
            $finalManifestPath = Join-Path $destinationPath "addon.manifest.yaml"
            Copy-Item -Path $configManifestPath -Destination $finalManifestPath -Force
            Write-Log "Single-level addon manifest copied to: $finalManifestPath"
        }
    }
    else {
        Write-Log "Warning: addon.manifest.yaml not found for $($addon.name)" -Console
    }

    # Resolve the omit options of this addon implementation.
    # Preferred source is the manifest carried in the artifact; the SNAPSHOT of the local
    # installation manifest (taken before the config-layer processing overwrote it) is used
    # as fallback so that artifacts exported before an omit option existed can still be
    # imported with '--omit'.
    $planFlags = @(Get-OmitFlagsForAddon `
                -ArtifactManifestPath $configManifestPath `
                -InstalledManifestPath $installedManifestSnapshot `
                -ImplementationName $addon.implementation)

    # List the per-image tars without extracting them (tar -tf only reads the index).
    $linuxTarNames = @(Get-TarEntryName -ArchivePath $linuxImagesBlob)
    $windowsTarNames = @(Get-TarEntryName -ArchivePath $windowsImagesBlob)

    $importPlan += [pscustomobject]@{
        Key                = $addonKey
        Name               = $addon.name
        Implementation     = $addon.implementation
        Addon              = $addon
        TempLayerDir       = $tempLayerDir
        ImplementationPath = $implementationPath
        Flags              = $planFlags
        LinuxImagesBlob    = $linuxImagesBlob
        WindowsImagesBlob  = $windowsImagesBlob
        LinuxTarNames      = $linuxTarNames
        WindowsTarNames    = $windowsTarNames
    }

    Write-Log "Staged '$addonKey': $($linuxTarNames.Count) Linux image(s), $($windowsTarNames.Count) Windows image(s)"
    Write-Log '---' -Console
}

# Phase 2: compute the global pruning plan.
# An image may only be skipped when NO imported addon/implementation requires it after
# applying the requested omit options.
$prunePlan = New-AddonImagePrunePlan -Entries $importPlan -Omit $Omit
Write-AddonImagePrunePlan -Plan $prunePlan


# Phase 3: import the container images and packages of every selected addon.
foreach ($planEntry in $importPlan) {
    $addon = $planEntry.Addon
    $addonKey = $planEntry.Key
    $tempLayerDir = $planEntry.TempLayerDir
    $skipForAddon = $prunePlan.SkipByKey[$addonKey]
    if ($null -eq $skipForAddon) {
        $skipForAddon = @{ Linux = @(); Windows = @() }
    }


    # Import Layer 4: Linux Images (referenced blob)
    $linuxImagesLayer = $planEntry.LinuxImagesBlob
    if (-not [string]::IsNullOrWhiteSpace($linuxImagesLayer) -and (Test-Path $linuxImagesLayer)) {
        if ($nodeList.Count -eq 0 -or $linuxNodes.Count -gt 0) {
            Import-AddonImageLayer `
                -LayerTarPath $linuxImagesLayer `
                -TempLayerDir $tempLayerDir `
                -ExtractedDirName 'images-linux-extracted' `
                -TargetNodes $linuxNodes `
                -AddonName $addon.name `
                -ImportImageScript $importImageScript `
                -ShowLogs:$ShowLogs `
                -SkipTarNames @($skipForAddon.Linux) `
                -AddonKey $addonKey
        }
        else {
            Write-Log "[Import] Skipping Linux images import: no Linux target nodes specified in '$Nodes'" -Console
        }
    }
    else {
        Write-Log "[Import] No Linux images layer found for $($addon.name)" -Console
    }

    # Import Layer 5: Windows Images (referenced blob)
    $windowsImagesLayer = $planEntry.WindowsImagesBlob
    if ((-not [string]::IsNullOrWhiteSpace($windowsImagesLayer)) -and
            (Test-Path $windowsImagesLayer) -and
            (-not $setupInfo.LinuxOnly)) {
        if ($nodeList.Count -eq 0 -or $windowsNodes.Count -gt 0) {
            Import-AddonImageLayer `
                -LayerTarPath $windowsImagesLayer `
                -TempLayerDir $tempLayerDir `
                -ExtractedDirName 'images-windows-extracted' `
                -TargetNodes $windowsNodes `
                -Windows `
                -AddonName $addon.name `
                -ImportImageScript $importImageScript `
                -ShowLogs:$ShowLogs `
                -SkipTarNames @($skipForAddon.Windows) `
                -AddonKey $addonKey
        }
        else {
            Write-Log "[Import] Skipping Windows images import: no Windows target nodes specified in '$Nodes'" -Console
        }
    }
    else {
        Write-Log "[Import] No Windows images layer found for $($addon.name) or Linux-only setup" -Console
    }

    # Process Layer 6: Packages (already extracted to temp location)
    $packagesExtractDir = Join-Path $tempLayerDir 'packages'
    if (Test-Path $packagesExtractDir) {
        # Load addon manifest from config layer to get offline_usage information
        $tempConfigDir = Join-Path $tempLayerDir 'config'
        $configManifestPath = Join-Path $tempConfigDir 'addon.manifest.yaml'
        if (Test-Path $configManifestPath) {
            $importedManifest = Get-FromYamlFile -Path $configManifestPath

            # Find the matching implementation
            $matchingImpl = $null
            if ($addon.implementation) {
                $matchingImpl = $importedManifest.spec.implementations | Where-Object { $_.name -eq $addon.implementation } | Select-Object -First 1
            } else {
                # Single implementation addon - use first (and only) implementation
                $matchingImpl = $importedManifest.spec.implementations | Select-Object -First 1
            }

            if ($null -ne $matchingImpl -and $null -ne $matchingImpl.offline_usage) {
                Write-Log "Installing packages for addon $($addon.name)" -Console
                $linuxPackages = $matchingImpl.offline_usage.linux
                $linuxCurlPackages = $linuxPackages.curl
                $windowsPackages = $matchingImpl.offline_usage.windows
                $windowsCurlPackages = $windowsPackages.curl

                # Import debian packages
                # When --node targets a Linux worker, copy the packages directly to that node
                # instead of kubemaster so enable can install them offline on the correct host.
                $debianPkgDir = Join-Path $packagesExtractDir 'debianpackages'
                if (Test-Path $debianPkgDir) {
                    if ($null -ne $targetNode -and $targetNode.Kind -eq 'LinuxWorker') {
                        $nodeIp = $targetNode.IpAddress
                        $nodeUser = $targetNode.Username
                        Write-Log "Copying debian packages for addon $($addon.name) to node '$($targetNode.Name)' ($nodeIp)" -Console
                        (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo rm -rf .$($addon.name)" -UserName $nodeUser -IpAddress $nodeIp -NoLog -IgnoreErrors).Output | Write-Log
                        (Invoke-CmdOnVmViaSSHKey -CmdToExecute "mkdir -p .$($addon.name)" -UserName $nodeUser -IpAddress $nodeIp -NoLog -IgnoreErrors).Output | Write-Log
                        Copy-ToRemoteComputerViaSshKey -Source "$debianPkgDir\*" -Target ".$($addon.name)" -UserName $nodeUser -IpAddress $nodeIp
                    }
                    else {
                        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf .$($addon.name)").Output | Write-Log
                        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "mkdir -p .$($addon.name)").Output | Write-Log
                        Copy-ToControlPlaneViaSSHKey -Source "$debianPkgDir\*" -Target ".$($addon.name)"
                    }
                }

                # Import Linux packages
                $linuxPkgDir = Join-Path $packagesExtractDir 'linuxpackages'
                if (Test-Path $linuxPkgDir) {
                    foreach ($package in $linuxCurlPackages) {
                        $filename = ([uri]$package.url).Segments[-1]
                        $destination = $package.destination
                        $sourcePath = Join-Path $linuxPkgDir $filename
                        if (-not (Test-Path $sourcePath)) {
                            continue
                        }

                        if ($destination -match '^/') {
                            # Absolute destination: install the binary system-wide on the control plane.
                            Copy-ToControlPlaneViaSSHKey -Source $sourcePath -Target '/tmp'
                            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo cp /tmp/${filename} ${destination}").Output | Write-Log
                            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf /tmp/${filename}").Output | Write-Log
                        }
                        else {
                            # Relative destination: stage the binary into the addon storage folder (~/.<addon>)
                            # on the target node so enable/bootstrap can consume it fully offline.
                            if ($null -ne $targetNode -and $targetNode.Kind -eq 'LinuxWorker') {
                                $nodeIp = $targetNode.IpAddress
                                $nodeUser = $targetNode.Username
                                (Invoke-CmdOnVmViaSSHKey -CmdToExecute "mkdir -p .$($addon.name)" -UserName $nodeUser -IpAddress $nodeIp -NoLog -IgnoreErrors).Output | Write-Log
                                Copy-ToRemoteComputerViaSshKey -Source $sourcePath -Target ".$($addon.name)/${destination}" -UserName $nodeUser -IpAddress $nodeIp
                            }
                            else {
                                (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "mkdir -p .$($addon.name)").Output | Write-Log
                                Copy-ToControlPlaneViaSSHKey -Source $sourcePath -Target ".$($addon.name)/${destination}"
                            }
                        }
                    }
                }

                # Import Windows packages
                $windowsPkgDir = Join-Path $packagesExtractDir 'windowspackages'
                if (Test-Path $windowsPkgDir) {
                    foreach ($package in $windowsCurlPackages) {
                        $filename = ([uri]$package.url).Segments[-1]
                        $destination = $package.destination
                        $sourcePath = Join-Path $windowsPkgDir $filename
                        $destPath = "$PSScriptRoot\..\$destination"
                        $destinationFolder = Split-Path -Path $destPath
                        if (Test-Path $sourcePath) {
                            mkdir -Force $destinationFolder | Out-Null
                            # If the downloaded package is a zip archive but the destination is not,
                            # extract the matching file from the archive instead of copying the zip as-is.
                            if ($sourcePath -like '*.zip' -and $destPath -notlike '*.zip') {
                                $destFileName = [IO.Path]::GetFileName($destPath)
                                $tempExtractDir = Join-Path ([IO.Path]::GetTempPath()) ("k2s-pkg-{0}" -f [guid]::NewGuid().ToString('N'))
                                try {
                                    Expand-Archive -LiteralPath $sourcePath -DestinationPath $tempExtractDir -Force
                                    $extractedFile = Get-ChildItem -Path $tempExtractDir -Filter $destFileName -Recurse -File | Select-Object -First 1
                                    if (-not $extractedFile) { throw "Expected file '$destFileName' not found in archive '$sourcePath'." }
                                    Copy-Item -LiteralPath $extractedFile.FullName -Destination $destPath -Force
                                    Write-Log "[Import] Extracted '$destFileName' from archive to '$destPath'." -Console
                                } finally {
                                    Remove-Item -LiteralPath $tempExtractDir -Force -Recurse -ErrorAction SilentlyContinue
                                }
                            } else {
                                Copy-Item -Path $sourcePath -Destination $destPath -Force
                            }
                        }
                    }
                }
            }
        }
    }

    # Cleanup temp layer directory
    Remove-Item -Path $tempLayerDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Log '---' -Console
}


Remove-Item -Force "$tmpDir" -Recurse -Confirm:$False -ErrorAction SilentlyContinue

Write-Log '---'
$importedNames = ($addonsToImport | ForEach-Object { $_.name }) -join ', '

if ($script:hasImportFailures) {
    $errMsg = "Addons '$importedNames' import completed with image import failures - check the log for details"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-import-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

Write-Log "Addons '$importedNames' imported successfully from OCI artifact!" -Console
Write-Log "OCI Artifact layers processed:" -Console
Write-Log "  Config:  metadata.json       (addon metadata)" -Console
Write-Log "  Layer 0: config.tar.gz       (addon.manifest.yaml, addon configs etc.)" -Console
Write-Log "  Layer 1: manifests.tar.gz    (Kubernetes manifests)" -Console
Write-Log "  Layer 2: charts.tar.gz       (Helm charts)" -Console
Write-Log "  Layer 3: scripts.tar.gz      (Enable/Disable scripts)" -Console
Write-Log "  Layer 4: images-linux.tar    (Linux container images)" -Console
Write-Log "  Layer 5: images-windows.tar  (Windows container images)" -Console
Write-Log "  Layer 6: packages.tar.gz     (Offline packages)" -Console

if (@($prunePlan.Pruned).Count -gt 0) {
    Write-Log '---' -Console
    Write-Log "Omit options were applied: $(@($prunePlan.Pruned).Count) image(s) were not imported." -Console
    foreach ($prunedImage in @($prunePlan.Pruned)) {
        Write-Log "  - $($prunedImage.Image)" -Console
    }
    Write-Log 'Enable the affected addons with the matching omit options, or re-run the import without' -Console
    Write-Log 'the omit options to add these images later. The OCI artifact itself is unchanged.' -Console
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
