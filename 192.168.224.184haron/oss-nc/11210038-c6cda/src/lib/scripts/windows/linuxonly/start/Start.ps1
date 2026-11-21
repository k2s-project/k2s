# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

param(
    [parameter(Mandatory = $false, HelpMessage = 'Set to TRUE to omit script headers.')]
    [switch] $HideHeaders = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = ''
)

$infraModule = "$PSScriptRoot\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\..\..\addons\addons.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Continue'

if ($HideHeaders -eq $false) {
    Write-Log 'Starting Linux-only K2s'
}

$loopbackAdapter = Get-L2BridgeName
$dnsServersForControlPlane = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
if ([string]::IsNullOrWhiteSpace($dnsServersForControlPlane)) {
    $dnsServersForControlPlane = '8.8.8.8,8.8.4.4'
}

$controlPlaneParams = " -AdditionalHooksDir '$AdditionalHooksDir'"
$controlPlaneParams += " -DnsAddresses '$dnsServersForControlPlane'"
if ($HideHeaders.IsPresent) {
    $controlPlaneParams += ' -SkipHeaderDisplay'
}
if ($ShowLogs.IsPresent) {
    $controlPlaneParams += ' -ShowLogs'
}
& powershell.exe "$PSScriptRoot\..\..\..\control-plane\Start.ps1" $controlPlaneParams

Write-Log 'Waiting for control-plane pods to be ready'
Wait-ForControlPlanePodsReady

Invoke-Hook -HookName 'BeforeStartK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

Invoke-AddonsHooks -HookType 'AfterStart'

Invoke-Hook -HookName 'AfterStartK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

if ($HideHeaders -eq $false) {
    Write-Log 'K2s Linux-only started.'
}
