# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule   = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule  = "$PSScriptRoot\..\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

function Get-FluxConfig {
    <#
    .SYNOPSIS
    Return path to the flux-system manifests for this addon.
    .OUTPUTS
    System.String
    #>
    return (Join-Path $PSScriptRoot 'manifests\flux-system')
}

function Install-FluxCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ManifestPath,

        [Parameter(Mandatory = $true)]
        [string] $K2sRoot,

        [Parameter(Mandatory = $false)]
        [string] $Proxy
    )

    Write-Log 'Checking Flux CLI' -Console

    $manifest = Get-FromYamlFile -Path $ManifestPath
    $fluxImpl = $manifest.spec.implementations | Where-Object { $_.name -eq 'fluxcd' }
    $windowsCurlPackages = $fluxImpl.offline_usage.windows.curl

    if (!$windowsCurlPackages) {
        return
    }

    foreach ($package in $windowsCurlPackages) {
        $destination = $package.destination
        $destination = "$K2sRoot\$destination"
        $destination = [System.IO.Path]::GetFullPath($destination)

        if (Test-Path -LiteralPath $destination) {
            Write-Log "Flux CLI already present at '$destination'." -Console
            continue
        }

        Write-Log "Downloading Flux CLI from '$($package.url)'..." -Console
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("k2s-flux-{0}" -f [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $zipName = [IO.Path]::GetFileName($package.url)
            $tmpZip = Join-Path $tmp $zipName

            Invoke-DownloadFile $tmpZip $package.url $true -ProxyToUse $Proxy
            Write-Log 'Download complete. Extracting...'

            if (Get-Command -Name Expand-ZipWithProgress -ErrorAction SilentlyContinue) {
                Expand-ZipWithProgress -ZipPath $tmpZip -Destination $tmp
            }
            else {
                Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmp -Force
            }

            $exe = Get-ChildItem -Path $tmp -Filter 'flux.exe' -Recurse -File | Select-Object -First 1
            if (-not $exe) { throw 'flux.exe not found in downloaded archive.' }

            $destDir = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

            Copy-Item -LiteralPath $exe.FullName -Destination $destination -Force
            Write-Log "Flux CLI installed to '$destination'." -Console
        }
        finally {
            Remove-Item -LiteralPath $tmp -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function Get-FluxConfig, Install-FluxCli
