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

    if ($AddonPath -eq $ImplementationPath) {
        return
    }

    # The manifest is merged by the import through the config layer, so it must not be shipped here.
    Get-ChildItem -LiteralPath $AddonPath -File -Force |
        Where-Object { $_.Name -notin @('addon.manifest.yaml', 'addon.manifest.yaml.license') } |
        Copy-Item -Destination $DestinationPath -Force -ErrorAction Stop
}
