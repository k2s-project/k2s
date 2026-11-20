# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Creates a node-only delta package between two node package ZIP files.

.DESCRIPTION
    Compares two node package ZIP files (created with `k2s system package --node-package`) and
    produces a compact delta ZIP containing only changed node artifacts:
      - changed/added Debian packages under packages/<os>/
      - changed/added container images under images/
      - metadata in delta-manifest.json
      - helper scripts: apply-node-delta.sh and Apply-Delta.ps1

    Input ZIPs must contain at least:
      packages/<os>/...
      images/*.tar (optional)

.PARAMETER InputPackageOne
    Path to the base (older) node package ZIP.

.PARAMETER InputPackageTwo
    Path to the target (newer) node package ZIP.

.PARAMETER TargetDirectory
    Output directory for the resulting node delta ZIP.

.PARAMETER ZipPackageFileName
    Name of the output ZIP (must end with .zip).

.PARAMETER OS
    Optional explicit OS folder name (for example: debian12). If omitted, OS is auto-detected
    from the package folder structure and must exist in both input ZIPs.

.PARAMETER ShowLogs
    Show detailed logs in console.

.PARAMETER EncodeStructuredOutput
    If set, send structured output back to CLI.

.PARAMETER MessageType
    Message type for structured output mode.
#>

#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory = $true, HelpMessage = 'Input package one (older node package zip)')]
    [string] $InputPackageOne,

    [Parameter(Mandatory = $true, HelpMessage = 'Input package two (newer node package zip)')]
    [string] $InputPackageTwo,

    [Parameter(Mandatory = $true, HelpMessage = 'Target directory')]
    [string] $TargetDirectory,

    [Parameter(Mandatory = $true, HelpMessage = 'Output zip file name')]
    [string] $ZipPackageFileName,

    [Parameter(Mandatory = $false, HelpMessage = 'Optional explicit OS folder name (for example: debian12)')]
    [string] $OS = '',

    [Parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [Parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [Parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
Import-Module $infraModule

if ($EncodeStructuredOutput) {
    Initialize-Logging -ShowLogs:$false
} else {
    Initialize-Logging -ShowLogs:$ShowLogs
}

$ErrorActionPreference = 'Stop'

function Resolve-NodeDeltaOS {
    param(
        [string] $OldPackagesRoot,
        [string] $NewPackagesRoot,
        [string] $RequestedOS
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedOS)) {
        $normalized = $RequestedOS.Trim().ToLower()
        if (-not (Test-Path -LiteralPath (Join-Path $OldPackagesRoot $normalized))) {
            throw "[NodeDelta] OS folder '$normalized' not found in old package under packages/."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $NewPackagesRoot $normalized))) {
            throw "[NodeDelta] OS folder '$normalized' not found in new package under packages/."
        }
        return $normalized
    }

    $oldDirs = @(Get-ChildItem -LiteralPath $OldPackagesRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $newDirs = @(Get-ChildItem -LiteralPath $NewPackagesRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)

    if ($oldDirs.Count -eq 0) {
        throw '[NodeDelta] No OS directory found under old package packages/.'
    }
    if ($newDirs.Count -eq 0) {
        throw '[NodeDelta] No OS directory found under new package packages/.'
    }

    $common = @($oldDirs | Where-Object { $newDirs -contains $_ } | Sort-Object -Unique)
    if ($common.Count -eq 1) {
        return $common[0]
    }
    if ($common.Count -gt 1) {
        throw "[NodeDelta] Multiple common OS folders found ($($common -join ', ')). Specify -OS explicitly."
    }

    throw "[NodeDelta] No common OS folder found between old ($($oldDirs -join ', ')) and new ($($newDirs -join ', ')) node packages."
}

function Get-HashMap {
    param(
        [string] $Root,
        [string] $Filter,
        [switch] $Recurse
    )

    $map = @{}
    $items = if ($Recurse) {
        Get-ChildItem -LiteralPath $Root -File -Recurse -Filter $Filter -ErrorAction SilentlyContinue
    } else {
        Get-ChildItem -LiteralPath $Root -File -Filter $Filter -ErrorAction SilentlyContinue
    }

    foreach ($item in $items) {
        $rel = $item.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
              $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        $map[$rel] = [pscustomobject]@{
            Path = $item.FullName
            Hash = $hash
        }
    }

    return $map
}

function Compare-Maps {
    param(
        [hashtable] $OldMap,
        [hashtable] $NewMap
    )

    $added = @()
    $changed = @()
    $removed = @()

    foreach ($k in $NewMap.Keys) {
        if (-not $OldMap.ContainsKey($k)) {
            $added += $k
            continue
        }
        if ($OldMap[$k].Hash -ne $NewMap[$k].Hash) {
            $changed += $k
        }
    }

    foreach ($k in $OldMap.Keys) {
        if (-not $NewMap.ContainsKey($k)) {
            $removed += $k
        }
    }

    return [pscustomobject]@{
        Added = @($added | Sort-Object)
        Changed = @($changed | Sort-Object)
        Removed = @($removed | Sort-Object)
        AddedCount = $added.Count
        ChangedCount = $changed.Count
        RemovedCount = $removed.Count
    }
}

function Copy-SelectedFiles {
    param(
        [string] $SourceRoot,
        [string] $DestinationRoot,
        [string[]] $RelativePaths
    )

    foreach ($rel in $RelativePaths) {
        $src = Join-Path $SourceRoot $rel
        if (-not (Test-Path -LiteralPath $src)) { continue }

        $dst = Join-Path $DestinationRoot $rel
        $dstDir = Split-Path $dst -Parent
        if (-not (Test-Path -LiteralPath $dstDir)) {
            New-Item -Path $dstDir -ItemType Directory -Force | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
}

function Format-ImageSize {
    param([long] $Bytes)

    if ($Bytes -ge 1MB) {
        return ('{0:N1} MB' -f ($Bytes / 1MB))
    }
    if ($Bytes -ge 1KB) {
        return ('{0:N0} KB' -f ($Bytes / 1KB))
    }
    return ('{0} B' -f $Bytes)
}

function Get-OciArchiveImageMetadata {
    param([string] $TarPath)

    $leafName = [IO.Path]::GetFileNameWithoutExtension($TarPath)
    $defaultFullName = $leafName -replace '__', ':' -replace '_', '/'

    $meta = [ordered]@{
        FullName = $defaultFullName
        ImageId  = $null
        Size     = Format-ImageSize -Bytes (Get-Item -LiteralPath $TarPath).Length
    }

    try {
        $indexRaw = (& tar -xOf $TarPath 'index.json' 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($indexRaw -join ''))) {
            $indexJson = ($indexRaw -join "`n") | ConvertFrom-Json
            $manifestDescriptor = @($indexJson.manifests)[0]
            if ($null -ne $manifestDescriptor) {
                $refName = $manifestDescriptor.annotations.'org.opencontainers.image.ref.name'
                if (-not [string]::IsNullOrWhiteSpace($refName)) {
                    $meta.FullName = $refName
                }

                if ($manifestDescriptor.digest -match '^sha256:(?<dg>[0-9a-fA-F]{64})$') {
                    $manifestDigest = $matches['dg']
                    $manifestBlobPath = "blobs/sha256/$manifestDigest"
                    $manifestRaw = (& tar -xOf $TarPath $manifestBlobPath 2>$null)
                    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($manifestRaw -join ''))) {
                        $manifestJson = ($manifestRaw -join "`n") | ConvertFrom-Json
                        $configDigest = $manifestJson.config.digest
                        if ($configDigest -match '^sha256:(?<cfg>[0-9a-fA-F]{64})$') {
                            $meta.ImageId = $matches['cfg'].Substring(0, 12)
                        }
                    }
                }
            }
        }
    } catch {
        # Best-effort metadata extraction only; keep defaults.
    }

    return [pscustomobject]$meta
}

function Get-ImageMetadataMap {
    param([string] $ImagesRoot)

    $result = @{}
    if (-not (Test-Path -LiteralPath $ImagesRoot)) { return $result }

    $tarFiles = Get-ChildItem -LiteralPath $ImagesRoot -File -Filter '*.tar' -ErrorAction SilentlyContinue
    foreach ($tar in $tarFiles) {
        $result[$tar.Name] = Get-OciArchiveImageMetadata -TarPath $tar.FullName
    }

    return $result
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("k2s-node-delta-" + [guid]::NewGuid().ToString('N'))
$oldExtract = Join-Path $tempRoot 'old'
$newExtract = Join-Path $tempRoot 'new'
$stageDir = Join-Path $tempRoot 'stage'

try {
    Write-Log "[NodeDelta] Starting node delta creation" -Console

    if (-not (Test-Path -LiteralPath $InputPackageOne)) {
        throw "[NodeDelta] InputPackageOne not found: $InputPackageOne"
    }
    if (-not (Test-Path -LiteralPath $InputPackageTwo)) {
        throw "[NodeDelta] InputPackageTwo not found: $InputPackageTwo"
    }
    if (-not $ZipPackageFileName.ToLower().EndsWith('.zip')) {
        throw '[NodeDelta] ZipPackageFileName must end with .zip'
    }

    New-Item -Path $oldExtract -ItemType Directory -Force | Out-Null
    New-Item -Path $newExtract -ItemType Directory -Force | Out-Null
    New-Item -Path $stageDir -ItemType Directory -Force | Out-Null

    Write-Log '[NodeDelta] Extracting input node packages...' -Console
    Expand-Archive -LiteralPath $InputPackageOne -DestinationPath $oldExtract -Force
    Expand-Archive -LiteralPath $InputPackageTwo -DestinationPath $newExtract -Force

    $oldPackagesRoot = Join-Path $oldExtract 'packages'
    $newPackagesRoot = Join-Path $newExtract 'packages'
    if (-not (Test-Path -LiteralPath $oldPackagesRoot)) {
        throw "[NodeDelta] Old package does not contain 'packages' directory."
    }
    if (-not (Test-Path -LiteralPath $newPackagesRoot)) {
        throw "[NodeDelta] New package does not contain 'packages' directory."
    }

    $distKey = Resolve-NodeDeltaOS -OldPackagesRoot $oldPackagesRoot -NewPackagesRoot $newPackagesRoot -RequestedOS $OS
    Write-Log "[NodeDelta] Using OS folder: $distKey" -Console

    $oldDistRoot = Join-Path $oldPackagesRoot $distKey
    $newDistRoot = Join-Path $newPackagesRoot $distKey

    $oldImagesRoot = Join-Path $oldExtract 'images'
    $newImagesRoot = Join-Path $newExtract 'images'

    $oldDebMap = Get-HashMap -Root $oldDistRoot -Filter '*.deb' -Recurse
    $newDebMap = Get-HashMap -Root $newDistRoot -Filter '*.deb' -Recurse
    $debDiff = Compare-Maps -OldMap $oldDebMap -NewMap $newDebMap

    $oldImageMap = @{}
    if (Test-Path -LiteralPath $oldImagesRoot) {
        $oldImageMap = Get-HashMap -Root $oldImagesRoot -Filter '*.tar' -Recurse:$false
    }

    $newImageMap = @{}
    if (Test-Path -LiteralPath $newImagesRoot) {
        $newImageMap = Get-HashMap -Root $newImagesRoot -Filter '*.tar' -Recurse:$false
    }
    $imageDiff = Compare-Maps -OldMap $oldImageMap -NewMap $newImageMap

    $oldImageMetadataMap = Get-ImageMetadataMap -ImagesRoot $oldImagesRoot
    $newImageMetadataMap = Get-ImageMetadataMap -ImagesRoot $newImagesRoot

    $oldLinuxImages = @($oldImageMetadataMap.Values | Sort-Object -Property FullName)
    $newLinuxImages = @($newImageMetadataMap.Values | Sort-Object -Property FullName)

    Write-Log "[NodeDelta] Debian diff: Added=$($debDiff.AddedCount), Changed=$($debDiff.ChangedCount), Removed=$($debDiff.RemovedCount)" -Console
    Write-Log "[NodeDelta] Image diff: Added=$($imageDiff.AddedCount), Changed=$($imageDiff.ChangedCount), Removed=$($imageDiff.RemovedCount)" -Console

    $stagePackagesRoot = Join-Path $stageDir 'packages'
    $stageDistRoot = Join-Path $stagePackagesRoot $distKey
    New-Item -Path $stageDistRoot -ItemType Directory -Force | Out-Null

    $debToCopy = @($debDiff.Added + $debDiff.Changed)
    Copy-SelectedFiles -SourceRoot $newDistRoot -DestinationRoot $stageDistRoot -RelativePaths $debToCopy

    if ($newImageMap.Count -gt 0) {
        $stageImagesRoot = Join-Path $stageDir 'images'
        New-Item -Path $stageImagesRoot -ItemType Directory -Force | Out-Null
        $imagesToCopy = @($imageDiff.Added + $imageDiff.Changed)
        Copy-SelectedFiles -SourceRoot $newImagesRoot -DestinationRoot $stageImagesRoot -RelativePaths $imagesToCopy
    }

    if ($debDiff.RemovedCount -gt 0) {
        Set-Content -LiteralPath (Join-Path $stageDir 'packages.removed') -Value ($debDiff.Removed -join "`n") -Encoding ASCII
    }
    if ($imageDiff.RemovedCount -gt 0) {
        Set-Content -LiteralPath (Join-Path $stageDir 'images.removed') -Value ($imageDiff.Removed -join "`n") -Encoding ASCII
    }

    $scriptsSourceDir = Join-Path $PSScriptRoot 'scripts'

    $applyScriptSource = Join-Path $scriptsSourceDir 'apply-node-delta.sh'
    $applyPath = Join-Path $stageDir 'apply-node-delta.sh'
    if (Test-Path -LiteralPath $applyScriptSource) {
        Copy-Item -LiteralPath $applyScriptSource -Destination $applyPath -Force
    } else {
        throw "Required script not found: $applyScriptSource"
    }

    $verifyScriptSource = Join-Path $scriptsSourceDir 'verify-node-delta.sh'
    $verifyPath = Join-Path $stageDir 'verify-node-delta.sh'
    if (Test-Path -LiteralPath $verifyScriptSource) {
        Copy-Item -LiteralPath $verifyScriptSource -Destination $verifyPath -Force
    } else {
        throw "Required script not found: $verifyScriptSource"
    }

    $applyPs1 = @'
# SPDX-FileCopyrightText: (c) 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Applies this K2s node delta package to a worker node.
.DESCRIPTION
    Re-compresses the extracted delta directory into a temporary ZIP and calls
    'k2s system upgrade --node' using the installed k2s CLI. Must be executed
    from the root of the extracted node delta package directory.
.PARAMETER NodeName
    Name of the worker node to upgrade (must match the hostname registered in the cluster).
.PARAMETER ShowLogs
    Show detailed log output during the upgrade.
#>

#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory = $true, HelpMessage = 'Worker node name as registered in the cluster')]
    [string] $NodeName,
    [Parameter(Mandatory = $false)]
    [switch] $ShowLogs = $false
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot

$deltaManifestPath = Join-Path $scriptRoot 'delta-manifest.json'
if (-not (Test-Path -LiteralPath $deltaManifestPath)) {
    Write-Host "[ERROR] delta-manifest.json not found in $scriptRoot" -ForegroundColor Red
    Write-Host "[ERROR] Run this script from the root of the extracted node delta package directory." -ForegroundColor Red
    exit 1
}

# Locate the installed k2s.exe from setup.json, fall back to PATH.
$k2sExe = 'k2s.exe'
$setupConfigPath = "$env:SystemDrive\ProgramData\k2s\setup.json"
if (Test-Path -LiteralPath $setupConfigPath) {
    try {
        $setupConfig = Get-Content -LiteralPath $setupConfigPath -Raw | ConvertFrom-Json
        if ($setupConfig.InstallFolder) {
            $candidate = Join-Path $setupConfig.InstallFolder 'k2s.exe'
            if (Test-Path -LiteralPath $candidate) { $k2sExe = $candidate }
        }
    } catch { }
}

# Re-compress the extracted delta into a temporary ZIP so that
# 'k2s system upgrade --node' (which expects a .zip input) can consume it.
$tempZip = Join-Path $env:TEMP ("k2s-node-delta-" + [guid]::NewGuid().ToString('N') + ".zip")
Write-Host "Packaging delta contents into temporary ZIP..." -ForegroundColor Cyan
Compress-Archive -Path (Join-Path $scriptRoot '*') -DestinationPath $tempZip -Force

try {
    Write-Host ""
    Write-Host "=======================================" -ForegroundColor Cyan
    Write-Host "K2s Node Delta Upgrade" -ForegroundColor Cyan
    Write-Host "Node : $NodeName" -ForegroundColor Cyan
    Write-Host "Delta: $scriptRoot" -ForegroundColor Cyan
    Write-Host "=======================================" -ForegroundColor Cyan
    Write-Host ""

    $upgradeArgs = @('system', 'upgrade', '--node', $NodeName, '--path', $tempZip)
    if ($ShowLogs) { $upgradeArgs += '-o' }

    & $k2sExe @upgradeArgs
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Write-Host ""
        Write-Host "=======================================" -ForegroundColor Red
        Write-Host "Node delta upgrade failed! (exit $exitCode)" -ForegroundColor Red
        Write-Host "=======================================" -ForegroundColor Red
        exit $exitCode
    }

    Write-Host ""
    Write-Host "=======================================" -ForegroundColor Green
    Write-Host "Node delta upgrade completed!" -ForegroundColor Green
    Write-Host "=======================================" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $tempZip) {
        Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
    }
}
'@
    Set-Content -LiteralPath (Join-Path $stageDir 'Apply-Delta.ps1') -Value $applyPs1 -Encoding UTF8

    # Build top-level file lists (prefixed paths) — mirrors full cluster delta format.
    $addedFiles = @()
    $changedFiles = @()
    $removedFiles = @()

    if ($debDiff.AddedCount -gt 0) {
        $addedFiles += @($debDiff.Added | ForEach-Object { "packages/$distKey/$_" })
    }
    if ($debDiff.ChangedCount -gt 0) {
        $changedFiles += @($debDiff.Changed | ForEach-Object { "packages/$distKey/$_" })
    }
    if ($debDiff.RemovedCount -gt 0) {
        $removedFiles += @($debDiff.Removed | ForEach-Object { "packages/$distKey/$_" })
    }

    if ($imageDiff.AddedCount -gt 0) {
        $addedFiles += @($imageDiff.Added | ForEach-Object { "images/$_" })
    }
    if ($imageDiff.ChangedCount -gt 0) {
        $changedFiles += @($imageDiff.Changed | ForEach-Object { "images/$_" })
    }
    if ($imageDiff.RemovedCount -gt 0) {
        $removedFiles += @($imageDiff.Removed | ForEach-Object { "images/$_" })
    }

    $totalAddedCount   = $debDiff.AddedCount   + $imageDiff.AddedCount
    $totalChangedCount = $debDiff.ChangedCount  + $imageDiff.ChangedCount
    $totalRemovedCount = $debDiff.RemovedCount  + $imageDiff.RemovedCount

    # Build ContainerImageDiff image maps (tar filename as key, enriched metadata).
    $addedImagesMap   = [ordered]@{}
    $changedImagesMap = [ordered]@{}
    $removedImagesMap = [ordered]@{}
    foreach ($f in $imageDiff.Added) {
        $m = if ($newImageMetadataMap.ContainsKey($f)) { $newImageMetadataMap[$f] } else { [pscustomobject]@{ FullName = $f; ImageId = $null; Size = $null } }
        $addedImagesMap[$f] = [ordered]@{ FullName = $m.FullName; ImageId = $m.ImageId; Size = $m.Size }
    }
    foreach ($f in $imageDiff.Changed) {
        $m = if ($newImageMetadataMap.ContainsKey($f)) { $newImageMetadataMap[$f] } else { [pscustomobject]@{ FullName = $f; ImageId = $null; Size = $null } }
        $changedImagesMap[$f] = [ordered]@{ FullName = $m.FullName; ImageId = $m.ImageId; Size = $m.Size }
    }
    foreach ($f in $imageDiff.Removed) {
        $m = if ($oldImageMetadataMap.ContainsKey($f)) { $oldImageMetadataMap[$f] } else { [pscustomobject]@{ FullName = $f; ImageId = $null; Size = $null } }
        $removedImagesMap[$f] = [ordered]@{ FullName = $m.FullName; ImageId = $m.ImageId; Size = $m.Size }
    }

    # Manifest uses ManifestVersion "2.0" and the same field layout as the full cluster delta
    # so that tooling, dashboards, and the upgrade script can process it uniformly.
    # DeltaType = "node-package" is the discriminator that distinguishes it from a cluster delta.
    $manifest = [ordered]@{
        ManifestVersion              = '2.0'
        DeltaType                    = 'node-package'
        GeneratedUtc                 = (Get-Date).ToUniversalTime().ToString('o')
        BasePackage                  = [IO.Path]::GetFileName($InputPackageOne)
        TargetPackage                = [IO.Path]::GetFileName($InputPackageTwo)
        BaseVersion                  = ''
        TargetVersion                = ''
        WholeDirectories             = ''
        WholeDirectoriesCount        = 0
        SpecialSkippedFiles          = @()
        SpecialSkippedFilesCount     = 0
        Added                        = @($addedFiles   | Sort-Object -Unique)
        Changed                      = @($changedFiles  | Sort-Object -Unique)
        Removed                      = @($removedFiles  | Sort-Object -Unique)
        AddedCount                   = $totalAddedCount
        ChangedCount                 = $totalChangedCount
        RemovedCount                 = $totalRemovedCount
        HashAlgorithm                = 'SHA256'
        DebianPackageDiff            = [ordered]@{
            Processed        = $true
            Error            = $null
            File             = $null
            OldRelativePath  = $null
            NewRelativePath  = $null
            Added            = @($debDiff.Added)
            Removed          = @($debDiff.Removed)
            Changed          = @($debDiff.Changed)
            AddedCount       = $debDiff.AddedCount
            RemovedCount     = $debDiff.RemovedCount
            ChangedCount     = $debDiff.ChangedCount
            OldLinuxImages   = $oldLinuxImages
            NewLinuxImages   = $newLinuxImages
            OldConfigHashes  = [ordered]@{}
            NewConfigHashes  = [ordered]@{}
            NewVmContext     = $null
        }
        DebianDeltaRelativePath      = "packages/$distKey"
        DebianOfflinePackages        = [ordered]@{}
        DebianOfflinePackagesCount   = 0
        DebianOfflineDownloaded      = [ordered]@{}
        DebianOfflineDownloadedCount = 0
        ContainerImageDiff           = [ordered]@{
            AddedImages   = $addedImagesMap
            RemovedImages = $removedImagesMap
            ChangedImages = $changedImagesMap
            AddedCount    = $imageDiff.AddedCount
            RemovedCount  = $imageDiff.RemovedCount
            ChangedCount  = $imageDiff.ChangedCount
        }
        GuestConfigDiff              = [ordered]@{
            Added            = @()
            Changed          = @()
            Removed          = @()
            AddedCount       = 0
            ChangedCount     = 0
            RemovedCount     = 0
            CopiedFiles      = @()
            CopiedFilesCount = 0
            FailedFiles      = $null
            FailedFilesCount = 0
            ScannedPaths     = $null
        }
        GuestConfigRelativePath      = $null
    }

    $manifestPath = Join-Path $stageDir 'delta-manifest.json'
    ($manifest | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    if (-not (Test-Path -LiteralPath $TargetDirectory)) {
        New-Item -Path $TargetDirectory -ItemType Directory -Force | Out-Null
    }

    $zipTarget = Join-Path $TargetDirectory $ZipPackageFileName
    if (Test-Path -LiteralPath $zipTarget) {
        Remove-Item -LiteralPath $zipTarget -Force
    }

    Write-Log "[NodeDelta] Writing node delta ZIP: $zipTarget" -Console
    Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $zipTarget -Force

    Write-Log '[NodeDelta] Node delta package created successfully.' -Console

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
    }
}
catch {
    $errMsg = $_.Exception.Message
    Write-Log "[NodeDelta] ERROR: $errMsg" -Console
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Error -Code 'node-delta-package-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        exit 0
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
