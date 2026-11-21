# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# ──────────────────────────────────────────────────────────────────────────────
# Core methods for building the K2s Headlamp plugin OCI images.
#
# Dot-sourced by Build-HeadlampPluginImages.ps1 (thin orchestrator).
# Daemonless build path using crane (google/go-containerregistry), mirroring the
# existing fluentbit autoupdate pipeline in K2s-Support/ci/autoupdate.
#
# Logging: lightweight Write-HlPluginLog wrapper with the [HlPlugin] category tag
# so this build tool stays self-contained (it must run in CI containers and dev
# shells where the k2s.infra.module is not importable).
# ──────────────────────────────────────────────────────────────────────────────

function Write-HlPluginLog {
    param(
        [Parameter(Mandatory = $true)] [string] $Message,
        [ValidateSet('Info', 'Warn', 'Error')] [string] $Level = 'Info'
    )
    $tagged = "[HlPlugin] $Message"
    switch ($Level) {
        'Warn'  { Write-Warning $tagged }
        'Error' { Write-Error  $tagged }
        default { Write-Information $tagged -InformationAction Continue }
    }
}

function Get-HeadlampPluginLock {
    <#
    .SYNOPSIS
    Loads and validates headlamp-plugins.lock.json.
    #>
    param([Parameter(Mandatory = $true)] [string] $LockFile)

    if (-not (Test-Path $LockFile)) {
        throw "[HlPlugin] Lock file not found: '$LockFile'"
    }
    $lock = Get-Content -Raw -Path $LockFile | ConvertFrom-Json
    if (-not $lock.plugins -or $lock.plugins.Count -eq 0) {
        throw "[HlPlugin] Lock file '$LockFile' contains no plugins"
    }
    foreach ($p in $lock.plugins) {
        foreach ($field in 'name', 'pluginDir', 'version', 'image') {
            if ([string]::IsNullOrWhiteSpace($p.$field)) {
                throw "[HlPlugin] Plugin entry is missing required field '$field' in '$LockFile'"
            }
        }
    }
    return $lock
}

function Resolve-CraneExe {
    <#
    .SYNOPSIS
    Resolves a usable crane executable. Honors an explicit path, then PATH.
    #>
    param([string] $CraneExe)

    if ($CraneExe) {
        if (-not (Test-Path $CraneExe)) { throw "[HlPlugin] crane not found at '$CraneExe'" }
        return (Resolve-Path $CraneExe).Path
    }
    $cmd = Get-Command 'crane' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "[HlPlugin] crane not found. Install crane (google/go-containerregistry) or pass -CraneExe. See build/README.md."
}

function Invoke-PluginAcquisition {
    <#
    .SYNOPSIS
    Acquires a compiled Headlamp plugin bundle and stages it at
    <StagingDir>/plugins/<pluginDir>/ ready to be packed into the image.

    .DESCRIPTION
    Two acquisition modes:
      prebuilt : use a repository-vendored bundle tarball (prebuilt.localPath) when
                 present — reproducible from a clean checkout, no network — otherwise
                 download the pinned tarball (prebuilt.url). Both verify prebuilt.sha256.
      source   : clone source.repo at source.ref and build with the official
                 @headlamp-k8s/headlamp-plugin toolchain (requires node/npm).
    Prebuilt is preferred for offline-friendly, fast, deterministic CI builds.

    .PARAMETER LockDir
    Directory the lock file lives in. Used to resolve a relative prebuilt.localPath
    (the vendored bundle) against the repository, not the staging directory.
    #>
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Plugin,
        [Parameter(Mandatory = $true)] [string] $StagingDir,
        [ValidateSet('prebuilt', 'source')] [string] $Mode = 'prebuilt',
        [string] $Proxy,
        [string] $LockDir,
        [switch] $UpdateLock
    )

    $pluginDir = $Plugin.pluginDir
    $dest = Join-Path $StagingDir "plugins/$pluginDir"
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    if ($Mode -eq 'prebuilt') {
        if (-not $Plugin.prebuilt) {
            throw "[HlPlugin] Plugin '$($Plugin.name)' has no prebuilt section; use -Mode source"
        }

        # Acquisition order (hybrid model — consistent with how other addons vendor
        # Helm charts / rendered manifests in-repo):
        #   1. Prefer a repository-vendored bundle tarball (prebuilt.localPath). This
        #      makes the build reproducible from a clean checkout with no network
        #      egress, exactly like manifests/chart/headlamp-*.tgz for the chart.
        #   2. Fall back to the pinned GitHub Release asset URL (prebuilt.url) when the
        #      vendored file is absent (e.g. before the first auto-update run commits it).
        # Either source passes through the same prebuilt.sha256 gate below.
        $tar = $null
        $cleanupTar = $false
        $localPath = $Plugin.prebuilt.localPath
        if (-not [string]::IsNullOrWhiteSpace($localPath)) {
            $resolved = if ([IO.Path]::IsPathRooted($localPath)) { $localPath }
                        elseif ($LockDir) { Join-Path $LockDir $localPath }
                        else { $localPath }
            if (Test-Path $resolved) {
                Write-HlPluginLog "Using vendored bundle for '$($Plugin.name)' v$($Plugin.version): $resolved"
                $tar = (Resolve-Path $resolved).Path
            }
            else {
                Write-HlPluginLog "Vendored bundle '$resolved' not found; falling back to prebuilt.url" -Level Warn
            }
        }

        if (-not $tar) {
            if ([string]::IsNullOrWhiteSpace($Plugin.prebuilt.url)) {
                throw "[HlPlugin] Plugin '$($Plugin.name)' has no vendored bundle and no prebuilt.url; use -Mode source"
            }
            $tar = Join-Path $StagingDir "$pluginDir.download"
            $cleanupTar = $true
            Write-HlPluginLog "Downloading '$($Plugin.name)' v$($Plugin.version) from $($Plugin.prebuilt.url)"
            $iwrParams = @{ Uri = $Plugin.prebuilt.url; OutFile = $tar; UseBasicParsing = $true }
            if ($Proxy) { $iwrParams.Proxy = $Proxy }
            Invoke-WebRequest @iwrParams
        }

        $actual = (Get-FileHash -Path $tar -Algorithm SHA256).Hash.ToLowerInvariant()
        $expected = "$($Plugin.prebuilt.sha256)".ToLowerInvariant()
        if ($expected -eq 'to-pin' -or [string]::IsNullOrWhiteSpace($expected)) {
            if (-not $UpdateLock) {
                throw "[HlPlugin] Plugin '$($Plugin.name)' checksum is unpinned (sha256='$($Plugin.prebuilt.sha256)'). Re-run with -UpdateLock to pin it after manual verification."
            }
            Write-HlPluginLog "Pinning checksum for '$($Plugin.name)': $actual" -Level Warn
            $Plugin.prebuilt.sha256 = $actual
        }
        elseif ($actual -ne $expected) {
            throw "[HlPlugin] Checksum mismatch for '$($Plugin.name)': expected '$expected', got '$actual'"
        }

        Expand-PluginTarball -TarballPath $tar -DestinationDir $dest
        if ($cleanupTar) { Remove-Item -Force $tar -ErrorAction SilentlyContinue }
    }
    else {
        Build-PluginFromSource -Plugin $Plugin -StagingDir $StagingDir -DestinationDir $dest -Proxy $Proxy
    }

    Test-PluginBundleLayout -BundleDir $dest -PluginName $Plugin.name
    return $dest
}

function Expand-PluginTarball {
    <#
    .SYNOPSIS
    Extracts a Headlamp plugin .tar.gz and flattens its single top-level directory
    so that DestinationDir directly contains main.js + package.json.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $TarballPath,
        [Parameter(Mandatory = $true)] [string] $DestinationDir
    )
    $tmp = Join-Path ([IO.Path]::GetDirectoryName($DestinationDir)) ("extract-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        & tar -xzf $TarballPath -C $tmp
        if ($LASTEXITCODE -ne 0) { throw "[HlPlugin] tar extraction failed for '$TarballPath'" }

        # Headlamp plugin archives wrap files in a single top-level directory.
        $roots = @(Get-ChildItem -Path $tmp -Directory)
        $payloadDir = if ($roots.Count -eq 1 -and -not (Get-ChildItem -Path $tmp -File)) { $roots[0].FullName } else { $tmp }

        Copy-Item -Path (Join-Path $payloadDir '*') -Destination $DestinationDir -Recurse -Force
    }
    finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

function Build-PluginFromSource {
    <#
    .SYNOPSIS
    Builds a Headlamp plugin from a pinned git ref using the official toolchain.
    Requires node + npm on PATH. Produces compiled files into DestinationDir.
    #>
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Plugin,
        [Parameter(Mandatory = $true)] [string] $StagingDir,
        [Parameter(Mandatory = $true)] [string] $DestinationDir,
        [string] $Proxy
    )
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw "[HlPlugin] -Mode source requires node/npm on PATH for plugin '$($Plugin.name)'"
    }
    if (-not $Plugin.source -or [string]::IsNullOrWhiteSpace($Plugin.source.repo)) {
        throw "[HlPlugin] Plugin '$($Plugin.name)' has no source.repo for -Mode source"
    }

    $clone = Join-Path $StagingDir ("src-" + $Plugin.pluginDir)
    if (Test-Path $clone) { Remove-Item -Recurse -Force $clone }

    Write-HlPluginLog "Cloning $($Plugin.source.repo) @ $($Plugin.source.ref)"
    & git clone --depth 1 --branch $Plugin.source.ref $Plugin.source.repo $clone
    if ($LASTEXITCODE -ne 0) { throw "[HlPlugin] git clone failed for '$($Plugin.name)'" }

    $pluginSrc = if ($Plugin.source.subdir) { Join-Path $clone $Plugin.source.subdir } else { $clone }
    Push-Location $pluginSrc
    try {
        # Scope proxy config to this process via npm_config_* environment variables
        # instead of 'npm config set', which would permanently mutate the user's global
        # ~/.npmrc. Cleaned up in the finally block.
        if ($Proxy) {
            $env:npm_config_proxy = $Proxy
            $env:npm_config_https_proxy = $Proxy
        }
        & npm ci
        if ($LASTEXITCODE -ne 0) { throw "[HlPlugin] npm ci failed for '$($Plugin.name)'" }
        & npx --yes @headlamp-k8s/headlamp-plugin build
        if ($LASTEXITCODE -ne 0) { throw "[HlPlugin] headlamp-plugin build failed for '$($Plugin.name)'" }
        # The build emits dist/main.js + package.json — the exact layout Headlamp loads.
        Copy-Item -Path (Join-Path $pluginSrc 'dist/*') -Destination $DestinationDir -Recurse -Force
        Copy-Item -Path (Join-Path $pluginSrc 'package.json') -Destination $DestinationDir -Force
    }
    finally {
        if ($Proxy) {
            Remove-Item Env:\npm_config_proxy -ErrorAction SilentlyContinue
            Remove-Item Env:\npm_config_https_proxy -ErrorAction SilentlyContinue
        }
        Pop-Location
    }
}

function Test-PluginBundleLayout {
    <#
    .SYNOPSIS
    Validates the staged bundle satisfies the Headlamp runtime contract:
    DestinationDir must contain main.js and package.json.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $BundleDir,
        [Parameter(Mandatory = $true)] [string] $PluginName
    )
    foreach ($required in 'main.js', 'package.json') {
        if (-not (Test-Path (Join-Path $BundleDir $required))) {
            throw "[HlPlugin] Plugin '$PluginName' bundle is missing required file '$required' in '$BundleDir'"
        }
    }
    Write-HlPluginLog "Bundle layout OK for '$PluginName' (main.js + package.json present)"
}

function New-PluginLayerTar {
    <#
    .SYNOPSIS
    Creates a gzip-compressed OCI layer tar whose paths are plugins/<pluginDir>/...
    so the files land at /plugins/<pluginDir>/ inside the image.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $StagingDir,
        [Parameter(Mandatory = $true)] [string] $PluginDir,
        [Parameter(Mandatory = $true)] [string] $OutputTar
    )
    # tar from StagingDir so archived paths start with plugins/<pluginDir>/
    & tar -czf $OutputTar -C $StagingDir "plugins/$PluginDir"
    if ($LASTEXITCODE -ne 0) { throw "[HlPlugin] failed to create layer tar for '$PluginDir'" }
    return $OutputTar
}

function Build-PluginOciImage {
    <#
    .SYNOPSIS
    Builds one plugin OCI image by appending the plugin layer onto the pinned base
    image with crane, writing the result to an OCI tarball (offline artifact) and,
    when -Push is set, publishing it to the registry.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $CraneExe,
        [Parameter(Mandatory = $true)] [pscustomobject] $Plugin,
        [Parameter(Mandatory = $true)] [string] $BaseImage,
        [Parameter(Mandatory = $true)] [string] $LayerTar,
        [Parameter(Mandatory = $true)] [string] $OutputDir,
        [switch] $Push
    )
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
    $ociTar = Join-Path $OutputDir ("headlamp-plugin-$($Plugin.name)-$($Plugin.version).tar")

    Write-HlPluginLog "Appending layer onto $BaseImage -> $($Plugin.image)"
    & $CraneExe append --base $BaseImage --new_layer $LayerTar --new_tag $Plugin.image --output $ociTar | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "[HlPlugin] crane append failed for '$($Plugin.image)'" }

    if ($Push) {
        Write-HlPluginLog "Pushing $($Plugin.image)"
        & $CraneExe push $ociTar $Plugin.image | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "[HlPlugin] crane push failed for '$($Plugin.image)'" }
    }
    return $ociTar
}

function Test-PluginImageLayout {
    <#
    .SYNOPSIS
    Validates the built image contains /plugins/<pluginDir>/{main.js,package.json},
    matching the init-container copy logic in Build-PluginPatchJson.

    .DESCRIPTION
    The image tarball produced by 'crane append --output' is a docker-save layout
    (manifest.json + one .tar[.gz] blob per layer). Validation scans the layer blobs
    directly with tar — it does NOT shell out to 'crane export', which only accepts an
    image *reference* (a local file path fails with "could not parse reference") and
    would otherwise require non-portable stdin redirection. Scanning with tar works
    identically on Windows and Linux CI, with no daemon and no registry round-trip.

    Path separators are normalized so both 'plugins/<dir>/main.js' and
    'plugins\<dir>\main.js' (Windows tar listings) match.

    The $CraneExe parameter is retained for call-site compatibility but is unused.
    #>
    param(
        [string] $CraneExe = '',
        [Parameter(Mandatory = $true)] [string] $OciTar,
        [Parameter(Mandatory = $true)] [string] $PluginDir
    )
    $null = $CraneExe  # retained for signature compatibility; layout is validated via tar

    $extractDir = Join-Path ([IO.Path]::GetDirectoryName($OciTar)) ("imglayout-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    try {
        # Unpack the image tarball (manifest.json + layer blobs).
        & tar -xf $OciTar -C $extractDir
        if ($LASTEXITCODE -ne 0) { throw "[HlPlugin] failed to extract image tarball '$OciTar'" }

        # List the contents of every layer blob (tar auto-detects gzip).
        $entries = @()
        $layerFiles = @(Get-ChildItem -Path $extractDir -Recurse -File |
                Where-Object { $_.Name -match '\.tar(\.gz)?$' })
        foreach ($layer in $layerFiles) {
            $listing = & tar -tf $layer.FullName 2>$null
            if ($listing) { $entries += $listing }
        }

        # Normalize separators ('\' -> '/') and strip any leading './' so matching is
        # platform-independent.
        $normalized = @($entries | ForEach-Object { ($_ -replace '\\', '/') -replace '^\./', '' })

        # pluginDir must exist as a path prefix within the layer.
        $dirPrefix = "plugins/$PluginDir/"
        if (-not ($normalized | Where-Object { $_ -like "$dirPrefix*" -or $_ -like "*/$dirPrefix*" })) {
            throw "[HlPlugin] Built image '$OciTar' is missing plugin directory '/$dirPrefix' (runtime contract violated)"
        }

        # main.js and package.json must both be present under pluginDir.
        foreach ($required in 'main.js', 'package.json') {
            $needle = "plugins/$PluginDir/$required"
            $hit = $normalized | Where-Object { $_ -eq $needle -or $_.EndsWith("/$needle") }
            if (-not $hit) {
                throw "[HlPlugin] Built image '$OciTar' is missing required plugin file '/$needle' (runtime contract violated)"
            }
        }

        Write-HlPluginLog "Image layout OK: /plugins/$PluginDir/{main.js,package.json} present"
    }
    finally {
        Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue
    }
}

