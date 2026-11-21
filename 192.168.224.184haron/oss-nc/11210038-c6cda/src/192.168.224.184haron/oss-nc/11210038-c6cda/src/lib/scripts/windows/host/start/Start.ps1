# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Number of processors for VM')]
    [string] $VmProcessors,
    [parameter(Mandatory = $false, HelpMessage = 'Do a full reset of the HNS network at start')]
    [switch] $ResetHns = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Use cached vSwitches')]
    [switch] $UseCachedK2sVSwitches,
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
    [switch] $SkipHeaderDisplay = $false
)

$infraModule = "$PSScriptRoot\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\..\..\addons\addons.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

$startTime = Get-Date

Initialize-Logging -ShowLogs:$ShowLogs
$kubePath = Get-KubePath

$logUseCase = 'Start'

# make sure we are at the right place for executing this script
Set-Location $kubePath

if ($SkipHeaderDisplay -eq $false) {
    Write-Log "[$logUseCase] Starting K2s"
}

$ProgressPreference = 'SilentlyContinue'

Write-Log "[$logUseCase] Starting Kubernetes System"

$loopbackAdapter = Get-L2BridgeName
$dnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
if ([string]::IsNullOrWhiteSpace($dnsServers)) {
    $dnsServers = '8.8.8.8,8.8.4.4'
}

# start the control plane
$controlPlaneParams = @{
    VmProcessors = $VmProcessors
    ShowLogs = $ShowLogs
    AdditionalHooksDir = $AdditionalHooksDir
    UseCachedK2sVSwitches = $UseCachedK2sVSwitches
    SkipHeaderDisplay = $SkipHeaderDisplay
    DnsAddresses = $dnsServers
}
& "$PSScriptRoot\..\..\..\control-plane\Start.ps1" @controlPlaneParams

# start the worker node on the host
Write-Log "[$logUseCase] Starting worker node"
$workerNodeParams = @{
    HideHeaders = $SkipHeaderDisplay
    ShowLogs = $ShowLogs
    AdditionalHooksDir = $AdditionalHooksDir
    UseCachedK2sVSwitches = $UseCachedK2sVSwitches
    ResetHns = $ResetHns
    DnsAddresses = $dnsServers
}
& "$PSScriptRoot\..\..\..\windows\worker\windows-host\Start.ps1" @workerNodeParams

# Actions which need to be done at the end in order to not block the commands before !!!
# ensure cni0 interface is created (this needs to be done at the end in oder to ensure that initially no extra time is needed)
Write-Log "[$logUseCase] Initializing cni0 interface"
$controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
$WSL = Get-ConfigWslFlag
Initialize-Cni0Interface -VmName $controlPlaneVMHostName -WSL:$WSL

Write-Log "[$logUseCase] Waiting for control-plane pods to be ready"
Wait-ForControlPlanePodsReady

# change loopback adapter to private network profile
# Set-PrivateNetworkProfileForLoopbackAdapter

$endTime = Get-Date
$durationSeconds = Get-DurationInSeconds -StartTime $startTime -EndTime $endTime
Write-Log "K2s start command finished, total duration: ${durationSeconds} seconds" -Console

Invoke-AddonsHooks -HookType 'AfterStart'

if ($SkipHeaderDisplay -eq $false) {
    Write-Log 'K2s started.'
}
