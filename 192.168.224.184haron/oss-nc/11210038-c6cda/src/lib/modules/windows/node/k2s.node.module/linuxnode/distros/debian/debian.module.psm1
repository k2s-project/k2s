# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

$infraModule = "$PSScriptRoot\..\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$vmModule = "$PSScriptRoot\..\..\vm\vm.module.psm1"
Import-Module $infraModule, $vmModule 

<#
.SYNOPSIS
Sets up the computer with Debian OS before it gets provisioned.
.DESCRIPTION
During the set-up the following is done:
- disable cloud-init.
- update grub.
- disable package validation date check to avoid "Release file expired" problem.
.PARAMETER UserName
The user name to log in.
.PARAMETER UserPwd
The password to use to log in.
.PARAMETER IpAddress
The IP address of the computer.
#>
Function Set-UpComputerWithSpecificOsBeforeProvisioning {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    $user = "$UserName@$IpAddress"
    $userPwd = $UserPwd

    $executeRemoteCommand = {
        param(
            $command = $(throw "Argument missing: Command"),
            [switch]$IgnoreErrors = $false
            )
        if ($IgnoreErrors) {
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$user" -RemoteUserPwd "$userPwd" -IgnoreErrors).Output | Write-Log
        } else {
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$user" -RemoteUserPwd "$userPwd").Output | Write-Log
        }
    }

    Write-Log "Check that a remote connection to the VM is possible"
    Wait-ForSSHConnectionToLinuxVMViaPwd -User "$user" -UserPwd "$userPwd"

    &$executeRemoteCommand "sudo touch /etc/cloud/cloud-init.disabled"
    &$executeRemoteCommand "sudo update-grub" -IgnoreErrors

    Write-Log "Disable release file validity check"
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        &$executeRemoteCommand 'echo Acquire::Check-Valid-Until \"false\"\; | sudo tee /etc/apt/apt.conf.d/00snapshot'
    } else {
        &$executeRemoteCommand 'echo Acquire::Check-Valid-Until \\\"false\\\"\; | sudo tee /etc/apt/apt.conf.d/00snapshot'
    }

    &$executeRemoteCommand 'echo Acquire::Max-FutureTime 86400\; | sudo tee -a /etc/apt/apt.conf.d/00snapshot'
}

<#
.SYNOPSIS
Sets up the computer with Debian OS after it gets provisioned.
.DESCRIPTION
During the set-up the following is done:
- clean up cloud-init logs and artifacts.
.PARAMETER UserName
The user name to log in.
.PARAMETER UserPwd
The password to use to log in.
.PARAMETER IpAddress
The IP address of the computer.
#>
Function Set-UpComputerWithSpecificOsAfterProvisioning {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    $user = "$UserName@$IpAddress"
    $userPwd = $UserPwd

    Copy-CloudInitFiles -IpAddress $IpAddress
    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo cloud-init clean" -RemoteUser "$user" -RemoteUserPwd "$userPwd").Output | Write-Log
}


function Copy-CloudInitFiles {
    param (
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    $source = '/var/log/cloud-init*'
    $target = Join-Path -Path (Get-ConfiguredLogDirectory) -ChildPath 'cloud-init'
    Remove-Item -Path $target -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
    mkdir $target -ErrorAction SilentlyContinue | Out-Null

    Write-Log "copy $source to $target"
    Copy-FromRemoteComputerViaUserAndPwd -Source $source -Target $target -IpAddress $IpAddress
}

Export-ModuleMember -Function Set-UpComputerWithSpecificOsBeforeProvisioning, Set-UpComputerWithSpecificOsAfterProvisioning
