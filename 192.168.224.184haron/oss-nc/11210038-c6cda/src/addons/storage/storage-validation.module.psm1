# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
Storage addon validation module

.DESCRIPTION
Provides validation functions to ensure only one storage implementation is enabled at a time.
#>

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $addonsModule

function Test-StorageImplementationEnabled {
    <#
    .SYNOPSIS
    Check if a specific storage implementation is already enabled

    .PARAMETER Implementation
    Storage implementation name: 'smb' or 'ceph'

    .RETURNS
    $true if implementation is enabled, $false otherwise
    #>
    param(
        [ValidateSet('smb', 'ceph')]
        [string]$Implementation
    )

    return (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'storage'; Implementation = $Implementation }))
}

function Test-ConflictingStorageImplementation {
    <#
    .SYNOPSIS
    Check if a conflicting storage implementation is already enabled

    .PARAMETER RequestedImplementation
    The implementation being requested to enable ('smb' or 'ceph')

    .RETURNS
    Error message if conflict exists, $null if no conflict
    #>
    param(
        [ValidateSet('smb', 'ceph')]
        [string]$RequestedImplementation
    )

    $conflictingImpl = @{
        'smb' = 'ceph'
        'ceph' = 'smb'
    }[$RequestedImplementation]

    if (Test-StorageImplementationEnabled -Implementation $conflictingImpl) {
        return ('Cannot enable storage {0}: {1} storage is already enabled. Please disable {1} storage first using: k2s addons disable storage {1}' -f $RequestedImplementation, $conflictingImpl)
    }

    return $null
}

Export-ModuleMember -Function @(
    'Test-StorageImplementationEnabled',
    'Test-ConflictingStorageImplementation'
)