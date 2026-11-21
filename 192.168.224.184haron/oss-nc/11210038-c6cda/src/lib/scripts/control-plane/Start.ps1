# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator


Param(
    [parameter(Mandatory = $false, HelpMessage = 'Number of processors for VM')]
    [string] $VmProcessors,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Use cached vSwitches')]
    [switch] $UseCachedK2sVSwitches,
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
    [switch] $SkipHeaderDisplay = $false,
    [string] $DnsAddresses = $(throw 'Argument missing: DnsAddresses')
)

$infraModule = "$PSScriptRoot\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\addons\addons.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs
$kubePath = Get-KubePath

# make sure we are at the right place for executing this script
Set-Location $kubePath

$ProgressPreference = 'SilentlyContinue'

$controlPlaneStartParams = @{
    VmProcessors = $VmProcessors
    AdditionalHooksDir = $AdditionalHooksDir
    UseCachedK2sVSwitches = $UseCachedK2sVSwitches
    SkipHeaderDisplay = $SkipHeaderDisplay
    DnsServers = $DnsAddresses
}
Start-ControlPlaneNodeOnNewVM @controlPlaneStartParams

# proxy and dns needs to be started first
Start-WinHttpProxy -OnlyProxy
Start-WinDnsProxy

# change default policy in VM (after restart of VM always policy is changed automatically)
Write-Log 'Reconfiguring volatile settings in VM...'
(Invoke-CmdOnControlPlaneViaSSHKey 'sudo iptables --policy FORWARD ACCEPT').Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey 'sudo sysctl fs.inotify.max_user_instances=8192').Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey 'sudo sysctl fs.inotify.max_user_watches=524288').Output | Write-Log

# $loopbackAdapter = Get-L2BridgeName
# Set DNS proxy for all physical network interfaces on Windows host to the DNS proxy
# Set-K2sDnsProxyForActivePhysicalInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
