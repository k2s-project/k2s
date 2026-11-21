# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

Import-Module "$PSScriptRoot\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"

function Confirm-SetupNameIsValid {
    param (
        [Parameter(Mandatory = $false)]
        [string]$SetupName
    )
    $validationError = switch ( $SetupName ) {
        'k2s' { $null }
        'BuildOnlyEnv' { $null }
        $null { Get-ErrCodeSystemNotInstalled }
        '' { Get-ErrCodeSystemNotInstalled }
        Default { "invalid:'$SetupName'" }
    }
    
    return $validationError
}

function Get-SetupInfo {
    $setupName = Get-ConfigSetupType
    $linuxOnly = (Get-ConfigLinuxOnly) -eq $true
    $validationError = Confirm-SetupNameIsValid -SetupName $setupName
    $productVersion = "v$(Get-ProductVersion)"

    if ($validationError) {
        $linuxOnly = $null
        $productVersion = $null
        $setupName = $null
    }

    return [pscustomobject]@{
        Name      = $setupName; 
        Version   = $productVersion; 
        Error     = $validationError; 
        LinuxOnly = $linuxOnly
    }
}

Export-ModuleMember -Function Get-SetupInfo
