# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
Syncs addons from an OCI registry to the K2s addons directory on the Windows host.

.DESCRIPTION
This script runs inside a HostProcess container on the Windows node. It discovers
per-addon OCI repositories at <RegistryUrl>/addons/<name>, checks per-addon digests,
and pulls only changed addon artifacts using oras. For each pulled artifact it
extracts layers 0-3 (config, manifests, helm charts, scripts) into the K2s addons
directory.

Registry layout expected by this script:
  <registry>/addons/monitoring:<version>   one OCI artifact per addon
  <registry>/addons/security:<version>
  <registry>/addons/<name>:<version>       ...

Image layers (4/5) and package layers (6) are intentionally skipped - in the GitOps
flow, container images are pulled directly from the registry at enable time.

After extraction, addons appear in `k2s addons ls` and can be enabled normally via
`k2s addons enable <addon>`.

This script replicates the layer-processing logic of Import.ps1 but operates:
- Without a .oci.tar file (pulls directly from registry via oras)
- Without image/package import (layers 4-6 skipped)
- Inside a HostProcess container (direct Windows host filesystem access)
#>

Param(
    [Parameter(Mandatory = $true, HelpMessage = 'OCI base registry URL without /addons suffix (e.g., oci://k2s.registry.local:30500)')]
    [string]$RegistryUrl,

    [Parameter(Mandatory = $true, HelpMessage = 'K2s installation directory on the Windows host')]
    [string]$K2sInstallDir,

    [Parameter(Mandatory = $false, HelpMessage = 'Path to oras executable')]
    [string]$OrasExe = 'oras',

    [Parameter(Mandatory = $false, HelpMessage = 'Allow insecure (HTTP) registry connections')]
    [string]$Insecure = 'false',

    [Parameter(Mandatory = $false, HelpMessage = 'Check registry digest before pulling; skip sync if unchanged')]
    [string]$CheckDigest = 'false',

    [Parameter(Mandatory = $false, HelpMessage = 'Sync only a specific addon by name; if empty, discovers all addons via oras repo ls')]
    [string]$AddonName = ''
)

$ErrorActionPreference = 'Stop'

# Convert string parameters to booleans (Kubernetes env substitution passes strings like "true"/"false")
$InsecureBool = $Insecure -eq 'true' -or $Insecure -eq '$true' -or $Insecure -eq '1'
$CheckDigestBool = $CheckDigest -eq 'true' -or $CheckDigest -eq '$true' -or $CheckDigest -eq '1'

# Resolve oras executable path - fall back to PATH if the specified path doesn't exist
if (-not (Test-Path $OrasExe)) {
    $orasOnPath = Get-Command 'oras' -ErrorAction SilentlyContinue
    if ($orasOnPath) {
        $OrasExe = $orasOnPath.Source
    }
}

# ---------------------------------------------------------------------------
# Logging helper - Write-Log may not be available inside the container, so we
# provide a lightweight fallback that writes timestamped lines to stdout.
# ---------------------------------------------------------------------------
function Write-SyncLog {
    param(
        [string]$Message,
        [switch]$IsError,
        [switch]$Warning
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = '[AddonSync]'
    if ($IsError)   { $prefix = '[AddonSync][ERROR]' }
    if ($Warning) { $prefix = '[AddonSync][WARN]' }
    # Write-Host is intentional: this script runs inside a HostProcess container where
    # k2s.infra.module (and Write-Log) are not available. Stdout is the only log channel.
    Write-Host "$ts $prefix $Message"
}

function Get-Sha256HexLower {
    param(
        [Parameter(Mandatory)]
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
    $tempPath = [System.IO.Path]::GetTempFileName()
    return [PSCustomObject]@{
        FullName = $tempPath
    }
}

# ---------------------------------------------------------------------------
# OCI helper functions - inlined from oci.module.psm1 so the script is
# self-contained and can run without importing PS modules from the host.
# ---------------------------------------------------------------------------

function Get-BlobPathByDigest {
    param(
        [Parameter(Mandatory)] [string]$BlobsDir,
        [Parameter(Mandatory)] [string]$Digest
    )
    if ($Digest -notmatch '^sha256:[a-f0-9]{64}$') {
        throw "Invalid digest format: $Digest"
    }
    $hash = $Digest -replace '^sha256:', ''
    $blobPath = Join-Path $BlobsDir $hash
    if (-not (Test-Path $blobPath)) {
        throw "Blob not found for digest: $Digest"
    }
    # Integrity check
    $computed = Get-Sha256HexLower -Path $blobPath
    if ($computed -ne $hash) {
        throw "Blob integrity check failed for $Digest (computed sha256:$computed)"
    }
    return $blobPath
}

function Get-JsonBlobContent {
    param(
        [Parameter(Mandatory)] [string]$BlobsDir,
        [Parameter(Mandatory)] [string]$Digest
    )
    $path = Get-BlobPathByDigest -BlobsDir $BlobsDir -Digest $Digest
    return (Get-Content -Path $path -Raw | ConvertFrom-Json)
}

function Expand-TarGz {
    param(
        [Parameter(Mandatory)] [string]$Archive,
        [Parameter(Mandatory)] [string]$Destination
    )
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $saved = Get-Location
    try {
        Set-Location $Destination
        $result = & tar -xzf $Archive 2>&1
        if ($LASTEXITCODE -ne 0) { throw "tar extract failed: $result" }
    } finally {
        Set-Location $saved
    }
}

function Get-KubeBinPath {
    # Mirrors the module function from k2s.infra.module\path\path.module.psm1:
    # returns <K2sInstallDir>\bin - the single authoritative bin path used across k2s.
    return Join-Path $K2sInstallDir 'bin'
}

function Get-YamlContent {
    <#
    .SYNOPSIS
    Parses a YAML file into a PowerShell object using yq (JSON round-trip).
    #>
    param([Parameter(Mandatory)] [string]$Path)

    $kubeBinPath = Get-KubeBinPath
    $yqExe = Join-Path $kubeBinPath 'windowsnode\yaml\yq.exe'
    if (Test-Path $yqExe) {
        $json = & $yqExe eval -o=json '.' $Path 2>&1
        if ($LASTEXITCODE -eq 0) {
            return ($json | Out-String | ConvertFrom-Json)
        }
    }

    # yq not available - return $null so callers can fall back to a plain copy.
    Write-SyncLog "yq.exe not found (tried $yqExe) - YAML merge unavailable" -Warning
    return $null
}

function Get-SemVerTag {
    param(
        [Parameter(Mandatory)] [string]$Tag
    )

    $match = [regex]::Match($Tag, '^[vV]?(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)$')
    if (-not $match.Success) {
        return $null
    }

    return [PSCustomObject]@{
        Tag = $Tag
        Major = [int]$match.Groups['major'].Value
        Minor = [int]$match.Groups['minor'].Value
        Patch = [int]$match.Groups['patch'].Value
    }
}

function Select-AddonTag {
    param(
        [Parameter(Mandatory)] [string]$AddonRepoName,
        [Parameter(Mandatory)] [string[]]$Tags
    )

    $normalizedTags = @(
        $Tags |
            ForEach-Object { $_.ToString().Trim() } |
            Where-Object { $_ -ne '' }
    )

    if ($normalizedTags.Count -eq 0) {
        return $null
    }

    $latestTag = $normalizedTags | Where-Object { $_ -ieq 'latest' } | Select-Object -First 1
    if ($latestTag) {
        Write-SyncLog "  [TagSelect] '$AddonRepoName': using 'latest' tag"
        return $latestTag
    }

    $semVerCandidates = @()
    foreach ($tag in $normalizedTags) {
        $parsed = Get-SemVerTag -Tag $tag
        if ($parsed) {
            $semVerCandidates += $parsed
        }
    }

    if ($semVerCandidates.Count -gt 0) {
        $selectedSemVer = $semVerCandidates |
            Sort-Object -Property @{ Expression = 'Major'; Descending = $true }, @{ Expression = 'Minor'; Descending = $true }, @{ Expression = 'Patch'; Descending = $true }, @{ Expression = 'Tag'; Descending = $true } |
            Select-Object -First 1
        Write-SyncLog "  [TagSelect] '$AddonRepoName': using semver-desc tag '$($selectedSemVer.Tag)'"
        return $selectedSemVer.Tag
    }

    $lexicalTag = $normalizedTags | Sort-Object -Descending | Select-Object -First 1
    Write-SyncLog "  [TagSelect] '$AddonRepoName': semver unavailable, using lexical-desc tag '$lexicalTag'"
    return $lexicalTag
}

# ===========================================================================
# Helper: Validate an OCI Image Layout directory and extract addon layers 0-3
# into the K2s addons directory. Mirrors Import.ps1 layer-processing logic.
# ===========================================================================
function Sync-AddonFromOciLayout {
    param(
        [Parameter(Mandatory)] [string]$OciLayoutDir,
        [Parameter(Mandatory)] [string]$AddonsDir
    )

    # Validate OCI Image Layout structure
    $ociLayoutPath = Join-Path $OciLayoutDir 'oci-layout'
    if (-not (Test-Path $ociLayoutPath)) { throw 'Invalid OCI artifact: oci-layout file not found' }
    $ociLayout = Get-Content $ociLayoutPath | ConvertFrom-Json
    if ($ociLayout.imageLayoutVersion -ne '1.0.0') {
        throw "Unsupported OCI layout version: $($ociLayout.imageLayoutVersion)"
    }

    $blobsDir = Join-Path $OciLayoutDir 'blobs\sha256'
    if (-not (Test-Path $blobsDir)) { throw 'Invalid OCI artifact: blobs/sha256 directory not found' }

    $indexPath = Join-Path $OciLayoutDir 'index.json'
    if (-not (Test-Path $indexPath)) { throw 'Invalid OCI artifact: index.json not found' }
    $index = Get-Content $indexPath -Raw | ConvertFrom-Json
    if ($index.schemaVersion -ne 2) {
        throw "Invalid OCI index: schemaVersion must be 2, got $($index.schemaVersion)"
    }

    # Enumerate addons from index
    # Index entries may lack addon annotations when coming via oras copy (registry round-trip);
    # in that case read the manifest blob directly to get vnd.k2s.addon.* annotations.
    $exportedAddons = @()
    foreach ($m in $index.manifests) {
        $addonName = $m.annotations.'vnd.k2s.addon.name'
        $addonImpl = $m.annotations.'vnd.k2s.addon.implementation'
        $addonVer  = $m.annotations.'org.opencontainers.image.version'

        if (-not $addonName) {
            $innerManifest = Get-JsonBlobContent -BlobsDir $blobsDir -Digest $m.digest
            if ($innerManifest.annotations) {
                $addonName = $innerManifest.annotations.'vnd.k2s.addon.name'
                $addonImpl = $innerManifest.annotations.'vnd.k2s.addon.implementation'
                $addonVer  = $innerManifest.annotations.'org.opencontainers.image.version'
            }
        }

        if (-not $addonName) {
            Write-SyncLog "  Skipping index entry $($m.digest) - no addon name annotation" -Warning
            continue
        }
        $exportedAddons += [PSCustomObject]@{ Name = $addonName; Implementation = $addonImpl; Version = $addonVer; Digest = $m.digest }
    }

    if ($exportedAddons.Count -eq 0) { throw 'No addons found in OCI artifact index' }

    foreach ($addon in $exportedAddons) {
        Write-SyncLog "  Processing addon: $($addon.Name)"
        $ociManifest = Get-JsonBlobContent -BlobsDir $blobsDir -Digest $addon.Digest

        # Determine destination paths - mirrors Import.ps1 logic.
        # Use the vnd.k2s.addon.implementation annotation directly (set by Export.ps1).
        # This is more reliable than parsing the addon name for a '-' separator:
        #   - single-impl: Name='monitoring', Implementation='monitoring'  → dest: addons\monitoring
        #   - multi-impl:  Name='ingress',    Implementation='nginx'        → dest: addons\ingress\nginx
        $implementationName = $null
        $baseAddonName = $addon.Name
        if ($addon.Implementation -and $addon.Implementation -ne $addon.Name) {
            $implementationName = $addon.Implementation
        }

        $destinationPath = $AddonsDir
        foreach ($part in ($baseAddonName -split '\s+')) {
            $destinationPath = Join-Path $destinationPath $part
        }
        $implementationPath = if ($implementationName) { Join-Path $destinationPath $implementationName } else { $destinationPath }

        if (-not (Test-Path $destinationPath)) { New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null }
        if ($implementationName -and -not (Test-Path $implementationPath)) {
            New-Item -ItemType Directory -Path $implementationPath -Force | Out-Null
        }
        Write-SyncLog "    Destination: $implementationPath"

        $layerTmpDir = Join-Path $OciLayoutDir "layer-$($addon.Name)"
        New-Item -ItemType Directory -Path $layerTmpDir -Force | Out-Null

        foreach ($layer in $ociManifest.layers) {
            if ($layer.mediaType -eq 'application/vnd.oci.empty.v1+json') { continue }
            $blobPath = Get-BlobPathByDigest -BlobsDir $blobsDir -Digest $layer.digest

            switch -Wildcard ($layer.mediaType) {
                '*configfiles*' {
                    Write-SyncLog "    Extracting config files layer"
                    $tempConfigDir = Join-Path $layerTmpDir 'config'
                    New-Item -ItemType Directory -Path $tempConfigDir -Force | Out-Null
                    Expand-TarGz -Archive $blobPath -Destination $tempConfigDir; break
                }
                '*manifests*' {
                    Write-SyncLog "    Extracting manifests layer"
                    $manifestsDest = Join-Path $implementationPath 'manifests'
                    New-Item -ItemType Directory -Path $manifestsDest -Force | Out-Null
                    Expand-TarGz -Archive $blobPath -Destination $manifestsDest; break
                }
                '*helm.chart*' {
                    Write-SyncLog "    Extracting helm charts layer"
                    $chartsDest = Join-Path $implementationPath 'manifests\chart'
                    New-Item -ItemType Directory -Path $chartsDest -Force | Out-Null
                    Expand-TarGz -Archive $blobPath -Destination $chartsDest; break
                }
                '*scripts*' {
                    Write-SyncLog "    Extracting scripts layer"
                    Expand-TarGz -Archive $blobPath -Destination $implementationPath; break
                }
                '*image.layer*'    { Write-SyncLog "    Skipping Linux images layer (pulled from registry at enable time)"; break }
                '*images-windows*' { Write-SyncLog "    Skipping Windows images layer (pulled from registry at enable time)"; break }
                '*packages*'       { Write-SyncLog "    Skipping packages layer (not used in GitOps flow)"; break }
                default            { Write-SyncLog "    Skipping unknown layer type: $($layer.mediaType)" -Warning }
            }
        }

        # Handle addon.manifest.yaml from config layer (Layer 0)
        # Mirrors Import.ps1: merge for multi-impl addons; overwrite for single-impl.
        $tempConfigDir = Join-Path $layerTmpDir 'config'
        if (Test-Path $tempConfigDir) {
            $configManifestSrc = Join-Path $tempConfigDir 'addon.manifest.yaml'
            if (Test-Path $configManifestSrc) {
                $destManifestPath = Join-Path $destinationPath 'addon.manifest.yaml'
                if ($implementationName -and (Test-Path $destManifestPath)) {
                    Write-SyncLog "    Merging addon.manifest.yaml implementations"
                    $existingManifest = Get-YamlContent -Path $destManifestPath
                    $importedManifest = Get-YamlContent -Path $configManifestSrc
                    if ($existingManifest -and $importedManifest) {
                        $existingImplNames = @($existingManifest.spec.implementations | ForEach-Object { $_.name })
                        foreach ($impl in $importedManifest.spec.implementations) {
                            if ($impl.name -notin $existingImplNames) {
                                Write-SyncLog "      Adding new implementation: $($impl.name)"
                                $existingManifest.spec.implementations += $impl
                            } else {
                                Write-SyncLog "      Implementation '$($impl.name)' already exists, skipping"
                            }
                        }
                        $kubeBinPath = Get-KubeBinPath
                        $yqExe = Join-Path $kubeBinPath 'windowsnode\yaml\yq.exe'
                        if (Test-Path $yqExe) {
                            $originalContent = Get-Content -Path $destManifestPath -Raw -Encoding UTF8
                            $headerLines = @()
                            foreach ($line in ($originalContent -split "`r?`n")) {
                                if ($line.StartsWith('#') -or $line.Trim() -eq '') { $headerLines += $line } else { break }
                            }
                            $tempJson = New-CompatTemporaryFile
                            try {
                                $existingManifest | ConvertTo-Json -Depth 100 | Set-Content -Path $tempJson.FullName -Encoding UTF8
                                $yamlOutput = & $yqExe eval -P '.' $tempJson.FullName
                                $yamlContent = if ($yamlOutput -is [array]) { $yamlOutput -join "`n" } else { $yamlOutput.ToString() }
                                [System.IO.File]::WriteAllText($destManifestPath, (($headerLines -join "`n") + "`n" + $yamlContent), [System.Text.UTF8Encoding]::new($false))
                                Write-SyncLog "    Merged manifest saved"
                            } finally { Remove-Item -Path $tempJson.FullName -Force -ErrorAction SilentlyContinue }
                        } else {
                            Write-SyncLog "    yq.exe not found, copying manifest as-is" -Warning
                            Copy-Item -Path $configManifestSrc -Destination $destManifestPath -Force
                        }
                    } else {
                        Write-SyncLog "    yq unavailable for merge, overwriting manifest from registry" -Warning
                        Copy-Item -Path $configManifestSrc -Destination $destManifestPath -Force
                    }
                } else {
                    Copy-Item -Path $configManifestSrc -Destination $destManifestPath -Force
                    Write-SyncLog "    Copied addon.manifest.yaml"
                }
                if ($implementationName) {
                    $strayManifest = Join-Path $implementationPath 'addon.manifest.yaml'
                    if (Test-Path $strayManifest) { Remove-Item -Path $strayManifest -Force }
                }
            }

            Get-ChildItem -Path $tempConfigDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'addon.manifest.yaml' } |
                ForEach-Object { Copy-Item -Path $_.FullName -Destination $implementationPath -Force; Write-SyncLog "    Copied config: $($_.Name)" }

            $configSubDir = Join-Path $tempConfigDir 'config'
            if (Test-Path $configSubDir) {
                $destConfigSub = Join-Path $implementationPath 'config'
                New-Item -ItemType Directory -Path $destConfigSub -Force | Out-Null
                Copy-Item -Path (Join-Path $configSubDir '*') -Destination $destConfigSub -Recurse -Force
                Write-SyncLog "    Copied config subdirectory"
            }
        }

        Remove-Item -Path $layerTmpDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-SyncLog "    Addon '$($addon.Name)' extracted successfully"
    }
}

# ===========================================================================
# Main
# ===========================================================================

# Strip oci:// prefix - oras expects plain host/path references.
# REGISTRY_URL is the base registry (e.g. k2s.registry.local:30500).
# Per-addon repos are discovered via: oras repo ls <registryBase> | addons/*
$registryBase = $RegistryUrl -replace '^oci://', ''

Write-SyncLog "Starting per-addon sync from $registryBase"
Write-SyncLog "K2s install dir: $K2sInstallDir"
if ($CheckDigestBool) {
    Write-SyncLog "Digest-check mode enabled - only syncing changed addons"
}

$addonsDir = Join-Path $K2sInstallDir 'addons'
if (-not (Test-Path $addonsDir)) {
    throw "Addons directory not found: $addonsDir - is K2sInstallDir correct?"
}

# Per-addon digest tracking: one file per addon under .addon-sync-digests/
$digestDir = Join-Path $addonsDir '.addon-sync-digests'
if (-not (Test-Path $digestDir)) { New-Item -ItemType Directory -Path $digestDir -Force | Out-Null }

# ---------------------------------------------------------------------------
# Step 1: Discover per-addon repositories at <registryBase>/addons/<name>
# ---------------------------------------------------------------------------
if ($AddonName -ne '') {
    Write-SyncLog "AddonName filter set - syncing only '$AddonName'"
    $addonRepos = @($AddonName)
} else {
    Write-SyncLog "Discovering addon repositories under $registryBase/addons/"

    $repoListArgs = @('repo', 'ls', $registryBase)
    if ($InsecureBool) { $repoListArgs += '--plain-http' }

    try {
        $allRepos = & $OrasExe @repoListArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "oras repo ls failed (exit $LASTEXITCODE): $allRepos" }
    } catch {
        Write-SyncLog "Failed to list repositories at $registryBase : $_" -IsError
        throw
    }

    $addonRepos = @($allRepos | Where-Object { $_ -match '^addons/' } | ForEach-Object { $_ -replace '^addons/', '' })
    if ($addonRepos.Count -eq 0) {
        Write-SyncLog "No addon repositories found at $registryBase/addons/ - push addons first" -Warning
        [System.Environment]::Exit(0)
    }
}
Write-SyncLog "Found $($addonRepos.Count) addon repo(s): $($addonRepos -join ', ')"

# ---------------------------------------------------------------------------
# Step 2: For each addon repo - check digest, pull if changed, extract
# ---------------------------------------------------------------------------
$syncedCount  = 0
$skippedCount = 0
$failedCount  = 0

foreach ($addonRepoName in $addonRepos) {
    $addonRef = "$registryBase/addons/$addonRepoName"
    Write-SyncLog "Processing '$addonRepoName' ($addonRef)"

    # Discover tag: prefer 'latest', otherwise deterministic semver-desc / lexical-desc
    $tagListArgs = @('repo', 'tags', $addonRef)
    if ($InsecureBool) { $tagListArgs += '--plain-http' }
    $tagsOutput = & $OrasExe @tagListArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-SyncLog "  Failed to list tags for '$addonRepoName' (exit $LASTEXITCODE): $tagsOutput" -IsError
        $failedCount++
        continue
    }
    if (-not $tagsOutput) {
        Write-SyncLog "  No tags published for '$addonRepoName' - skipping (push a versioned tag first)" -Warning
        $skippedCount++
        continue
    }

    $tags = @($tagsOutput | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne '' })
    $selectedTag = Select-AddonTag -AddonRepoName $addonRepoName -Tags $tags
    if (-not $selectedTag) {
        Write-SyncLog "  Unable to select a tag for '$addonRepoName' (candidates: $($tags -join ', ')) - skipping" -IsError
        $failedCount++
        continue
    }
    $fullRef = "${addonRef}:${selectedTag}"

    # Per-addon digest check - skip if unchanged
    $digestFile = Join-Path $digestDir $addonRepoName
    if ($CheckDigestBool) {
        $fetchArgs = @('manifest', 'fetch', '--descriptor', $fullRef)
        if ($InsecureBool) { $fetchArgs += '--plain-http' }
        try {
            $descriptorJson = & $OrasExe @fetchArgs 2>&1
            if ($LASTEXITCODE -eq 0) {
                $currentDigest = ($descriptorJson | Out-String | ConvertFrom-Json).digest
                if (Test-Path $digestFile) {
                    $lastDigest = (Get-Content $digestFile -Raw).Trim()
                    if ($currentDigest -eq $lastDigest) {
                        # Digest matches — but only skip if the addon directory actually
                        # exists on disk. If content was deleted after the last sync the
                        # stale digest file would otherwise prevent re-extraction forever.
                        $expectedAddonDir = Join-Path $addonsDir $addonRepoName
                        if (Test-Path $expectedAddonDir) {
                            Write-SyncLog "  '$addonRepoName' unchanged (digest: $currentDigest), skipping"
                            $skippedCount++
                            continue
                        }
                        Write-SyncLog "  '$addonRepoName' digest unchanged but addon directory missing -- forcing re-sync"
                    } else {
                        Write-SyncLog "  '$addonRepoName' digest changed (was: $lastDigest)"
                    }
                } else {
                    Write-SyncLog "  '$addonRepoName' first sync run"
                }
            }
        } catch {
            Write-SyncLog "  Digest check failed for '$addonRepoName': $_ - proceeding with sync" -Warning
        }
    }

    # Pull per-addon OCI artifact into a temp OCI layout directory
    $addonTmpDir = Join-Path $env:TEMP "addon-sync-${addonRepoName}-$(Get-Date -Format 'HHmmss')"
    New-Item -ItemType Directory -Path $addonTmpDir -Force | Out-Null

    Write-SyncLog "  Pulling $fullRef"
    $orasArgs = @('copy', $fullRef, '--to-oci-layout', "${addonTmpDir}:${selectedTag}")
    if ($InsecureBool) { $orasArgs += '--from-plain-http' }

    try {
        $pullResult = & $OrasExe @orasArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "oras copy failed (exit $LASTEXITCODE): $pullResult" }
        Write-SyncLog "  Pull completed: $pullResult"

        # Extract layers 0-3 into the addons directory
        Sync-AddonFromOciLayout -OciLayoutDir $addonTmpDir -AddonsDir $addonsDir

        # Save per-addon digest after successful sync
        if ($CheckDigestBool) {
            try {
                $fetchArgs = @('manifest', 'fetch', '--descriptor', $fullRef)
                if ($InsecureBool) { $fetchArgs += '--plain-http' }
                $descriptorJson = & $OrasExe @fetchArgs 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $digest = ($descriptorJson | Out-String | ConvertFrom-Json).digest
                    Set-Content -Path $digestFile -Value $digest -NoNewline -Encoding UTF8 -Force
                    Write-SyncLog "  Saved digest for '$addonRepoName': $digest"
                }
            } catch {
                Write-SyncLog "  Failed to save digest for '$addonRepoName': $_" -Warning
            }
        }
        $syncedCount++
    } catch {
        Write-SyncLog "  Failed to sync '$addonRepoName': $_" -IsError
        $failedCount++
    } finally {
        Remove-Item -Path $addonTmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-SyncLog "Addon sync completed. Synced: $syncedCount, Skipped (unchanged): $skippedCount, Failed: $failedCount"
if ($failedCount -gt 0) {
    Write-SyncLog "Some addons failed to sync -- check logs above for details" -IsError
    exit 1
}
Write-SyncLog "Layers processed for each synced addon:"
Write-SyncLog "  Layer 0: config files      (addon.manifest.yaml, values.yaml, etc.)"
Write-SyncLog "  Layer 1: K8s manifests     (YAML, kustomization, CRDs)"
Write-SyncLog "  Layer 2: Helm charts       (.tgz packages)"
Write-SyncLog "  Layer 3: scripts           (Enable/Disable/Status/Update .ps1)"
Write-SyncLog "  Layer 4: Linux images      [SKIPPED - pulled from registry]"
Write-SyncLog "  Layer 5: Windows images    [SKIPPED - pulled from registry]"
Write-SyncLog "  Layer 6: packages          [SKIPPED - not used in GitOps flow]"
Write-SyncLog "Run 'k2s addons ls' to see synced addons."
