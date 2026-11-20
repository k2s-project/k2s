# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
Builds (and optionally publishes) the K2s Headlamp plugin OCI images that the
dashboard addon injects as init-containers.

.DESCRIPTION
Reads headlamp-plugins.lock.json, acquires each compiled plugin bundle, validates
the Headlamp runtime layout, builds a minimal OCI image (busybox base + plugin
layer) with crane, validates that the built image exposes /plugins/<dir>/main.js,
and writes an offline OCI tarball per image. With -Push, images are published to
shsk2s.azurecr.io so the K2s offline packaging/export pipeline can bundle them.

This closes the Phase 3 P0 gap: addons/dashboard/addon.manifest.yaml references
shsk2s.azurecr.io/headlamp-plugin-* under additionalImages, but nothing produced
those images. This script is the producer.

.PARAMETER LockFile
Path to headlamp-plugins.lock.json. Defaults to the file next to this script.

.PARAMETER OutputDir
Directory for the offline OCI tarballs. Defaults to <scriptdir>\out.

.PARAMETER CraneExe
Explicit path to crane. Defaults to crane on PATH.

.PARAMETER Mode
Acquisition mode: 'prebuilt' (download pinned tarball, default) or 'source'
(build from a pinned git ref with the official headlamp-plugin toolchain).

.PARAMETER PluginName
Optional filter: build only the named plugin (flux | cert-manager | prometheus).

.PARAMETER Push
Publish the built images to the registry referenced in the lock file.

.PARAMETER UpdateLock
Pin currently-unpinned (TO-PIN) checksums into the lock file after download.

.PARAMETER Proxy
Optional HTTP(S) proxy for downloads/clone in restricted CI environments.

.EXAMPLE
.\Build-HeadlampPluginImages.ps1 -UpdateLock
Build all three images offline-to-tarball and pin checksums on first run.

.EXAMPLE
.\Build-HeadlampPluginImages.ps1 -Push
Build and publish all three images to shsk2s.azurecr.io.
#>
[CmdletBinding()]
param(
    [string] $LockFile = "$PSScriptRoot\headlamp-plugins.lock.json",
    [string] $OutputDir = "$PSScriptRoot\out",
    [string] $CraneExe,
    [ValidateSet('prebuilt', 'source')] [string] $Mode = 'prebuilt',
    [string] $PluginName,
    [switch] $Push,
    [switch] $UpdateLock,
    [string] $Proxy
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Build-HeadlampPluginImages.Methods.ps1"

Write-HlPluginLog "Reading lock file: $LockFile"
$lock = Get-HeadlampPluginLock -LockFile $LockFile
$crane = Resolve-CraneExe -CraneExe $CraneExe

$tempRoot = $env:TEMP
if ([string]::IsNullOrWhiteSpace($tempRoot)) {
    $tempRoot = [System.IO.Path]::GetTempPath()
}
if ([string]::IsNullOrWhiteSpace($tempRoot)) {
    throw "[HlPlugin] Could not determine a temporary directory (TEMP and GetTempPath() were empty)"
}

# Use a GUID (not a second-precision timestamp) so concurrent builds sharing the
# same TEMP (self-hosted CI runners, parallel local shells) never collide and
# delete each other's staged bundles via the finally-block cleanup. Mirrors the
# GUID pattern already used in Expand-PluginTarball / Test-PluginImageLayout.
$staging = Join-Path $tempRoot ("hlplugin-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force | Out-Null

# Directory the lock file lives in — used to resolve relative vendored bundle paths
# (prebuilt.localPath) against the repository.
$lockDir = Split-Path -Parent $LockFile

$plugins = $lock.plugins
if ($PluginName) {
    $plugins = @($plugins | Where-Object { $_.name -eq $PluginName })
    if ($plugins.Count -eq 0) { throw "[HlPlugin] No plugin named '$PluginName' in lock file" }
}

$built = @()
try {
    foreach ($plugin in $plugins) {
        Write-HlPluginLog "=== Building headlamp-plugin-$($plugin.name) v$($plugin.version) ==="

        $bundleDir = Invoke-PluginAcquisition -Plugin $plugin -StagingDir $staging -Mode $Mode -Proxy $Proxy -LockDir $lockDir -UpdateLock:$UpdateLock
        Write-HlPluginLog "Staged bundle: $bundleDir"

        $layerTar = Join-Path $staging "$($plugin.pluginDir)-layer.tar.gz"
        New-PluginLayerTar -StagingDir $staging -PluginDir $plugin.pluginDir -OutputTar $layerTar | Out-Null

        $ociTar = Build-PluginOciImage -CraneExe $crane -Plugin $plugin -BaseImage $lock.baseImage `
            -LayerTar $layerTar -OutputDir $OutputDir -Push:$Push

        Test-PluginImageLayout -CraneExe $crane -OciTar $ociTar -PluginDir $plugin.pluginDir

        $built += [pscustomobject]@{ Image = $plugin.image; OciTar = $ociTar }
    }

    if ($UpdateLock) {
        Write-HlPluginLog "Writing updated checksums back to $LockFile" -Level Warn
        ($lock | ConvertTo-Json -Depth 20) | Set-Content -Path $LockFile -Encoding UTF8
    }
}
finally {
    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
}

Write-HlPluginLog "=== Build summary ==="
foreach ($b in $built) {
    Write-HlPluginLog ("  {0}  ->  {1}{2}" -f $b.Image, $b.OciTar, $(if ($Push) { '  (pushed)' } else { '' }))
}
Write-HlPluginLog "Done. $($built.Count) image(s) built$(if ($Push) { ' and pushed' } else { ' to offline tarballs' })."

