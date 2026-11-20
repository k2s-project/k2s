# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

param(
    [parameter(Mandatory = $false, HelpMessage = 'Set to TRUE to omit script headers.')]
    [switch] $HideHeaders = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Do a full reset of the HNS network at start')]
    [switch] $ResetHns = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Use cached vSwitches')]
    [switch] $UseCachedK2sVSwitches,
    [string] $DnsAddresses = $(throw 'Argument missing: DnsAddresses')
)

$infraModule = "$PSScriptRoot\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\..\..\addons\addons.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs
$kubePath = Get-KubePath

# make sure we are at the right place for executing this script
Set-Location $kubePath

$ProgressPreference = 'SilentlyContinue'

$workerNodeStartParams = @{
    ResetHns              = $ResetHns
    AdditionalHooksDir    = $AdditionalHooksDir
    UseCachedK2sVSwitches = $UseCachedK2sVSwitches
    SkipHeaderDisplay     = $HideHeaders
    DnsServers            = $DnsAddresses
    PodSubnetworkNumber      = '1'
}
Start-WindowsWorkerNodeOnWindowsHost @workerNodeStartParams
