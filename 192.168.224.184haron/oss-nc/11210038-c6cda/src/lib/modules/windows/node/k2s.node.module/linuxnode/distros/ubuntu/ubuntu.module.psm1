# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

$infraModule =   "$PSScriptRoot\..\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$vmModule = "$PSScriptRoot\..\..\vm\vm.module.psm1"

Import-Module $infraModule, $clusterModule, $vmModule

$netplanFilePath = '/etc/netplan/k2s.yaml'

function Add-RemoteIPAddress {
    param (
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $RemoteIpAddress = $(throw 'Argument missing: RemoteIpAddress'),
        [int] $PrefixLength = $(throw 'Argument missing: PrefixLength'),
        [string] $RemoteIpAddressGateway = $(throw 'Argument missing: RemoteIpAddressGateway'),
        [string] $DnsEntries = $(throw 'Argument missing: DnsEntries'),
        [string] $NetworkInterfaceName = $(throw 'Argument missing: NetworkInterfaceName')
    )

    $executeRemoteCommand = {
        param(
            $command = $(throw 'Argument missing: command'),
            [switch]$NoLog = $false
            )
        $result = (Invoke-CmdOnVmViaSSHKey -CmdToExecute $command -UserName $UserName -IpAddress $IpAddress -NoLog:$NoLog).Output

        return $result
    }

    $networkAddress = "$RemoteIpAddress/$PrefixLength"

    [string]$currentConfiguredIPAddresses = &$executeRemoteCommand "ip -f inet -h address show $NetworkInterfaceName | awk '/inet/ {print `$2}'" -NoLog
    $formattedCurrentConfiguredIPAddresses = $currentConfiguredIPAddresses.Replace(" ",",")

    $formattedCurrentConfiguredIPAddresses = "$networkAddress,$formattedCurrentConfiguredIPAddresses"

    $configPath = "$PSScriptRoot\NetplanK2s.yaml"
    $netplanConfigurationTemplate = Get-Content $configPath

    $netplanConfiguration = $netplanConfigurationTemplate.Replace('__NETWORK_INTERFACE_NAME__',$NetworkInterfaceName).Replace('__NETWORK_ADDRESSES__',$formattedCurrentConfiguredIPAddresses).Replace('__IP_GATEWAY__', $RemoteIpAddressGateway).Replace('__DNS_IP_ADDRESSES__',$DnsEntries)

    &$executeRemoteCommand "echo '' | sudo tee $netplanFilePath" -NoLog

    foreach ($line in $netplanConfiguration) {
        &$executeRemoteCommand "echo '$line' | sudo tee -a $netplanFilePath" -NoLog
    }

    &$executeRemoteCommand "sudo chmod 600 $netplanFilePath"
    &$executeRemoteCommand 'sudo netplan apply'
    &$executeRemoteCommand 'sudo systemctl restart systemd-networkd'

    [string]$hostname = &$executeRemoteCommand 'hostname' -NoLog

    Write-Log "Added network address '$networkAddress' and gateway IP '$RemoteIpAddressGateway' to Linux based computer '$hostname' reachable on IP address '$IpAddress'"
}

function Remove-RemoteIPAddress {
    param (
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    $executeRemoteCommand = {
        param(
            $command = $(throw 'Argument missing: command'),
            [switch]$NoLog = $false
            )
        $result = (Invoke-CmdOnVmViaSSHKey -CmdToExecute $command -UserName $UserName -IpAddress $IpAddress -NoLog:$NoLog).Output

        return $result
    }

    &$executeRemoteCommand "sudo rm -f $netplanFilePath" -NoLog
}

Export-ModuleMember -Function Add-RemoteIPAddress, Remove-RemoteIPAddress

