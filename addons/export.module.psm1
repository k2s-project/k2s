# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $infraModule

$binPath = Get-KubeBinPath
$nerdctlExe = "$binPath\nerdctl.exe"
$crictlExe = "$binPath\crictl.exe"

function Get-NerdctlExe {
    return $nerdctlExe    
}

function Get-CrictlExe {
    return $crictlExe    
}

function Copy-AddonSharedScripts {
    param(
        [Parameter(Mandatory = $true)]
        [string] $AddonPath,
        [Parameter(Mandatory = $true)]
        [string] $ImplementationPath,
        [Parameter(Mandatory = $true)]
        [string] $DestinationPath
    )

    if ($AddonPath -eq $ImplementationPath -or (Split-Path -Path $AddonPath -Leaf) -ne 'storage') {
        return
    }

    $modulePath = Join-Path $AddonPath 'storage-validation.module.psm1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Cannot export storage addon: shared module '$modulePath' is missing."
    }

    Copy-Item -LiteralPath $modulePath -Destination $DestinationPath -Force -ErrorAction Stop
    foreach ($optionalFile in @('storage-validation.module.psm1.license', 'README.md', 'README.md.license')) {
        $optionalPath = Join-Path $AddonPath $optionalFile
        if (Test-Path -LiteralPath $optionalPath -PathType Leaf) {
            Copy-Item -LiteralPath $optionalPath -Destination $DestinationPath -Force -ErrorAction Stop
        }
    }
}
