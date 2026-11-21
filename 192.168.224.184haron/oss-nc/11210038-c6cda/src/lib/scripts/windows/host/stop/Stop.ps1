# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Cache vSwitches on stop')]
    [switch] $CacheK2sVSwitches,
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing stop header display')]
    [switch] $SkipHeaderDisplay = $false
)

$infraModule = "$PSScriptRoot\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$logUseCase = 'Stop'

# make sure we are at the right place for executing this script
$kubePath = Get-KubePath
Set-Location $kubePath

if ($SkipHeaderDisplay -eq $false) {
    Write-Log "[$logUseCase] Stopping K2s"
}

$ProgressPreference = 'SilentlyContinue'


Write-Log "[$logUseCase] Stopping worker node"
$workerNodeParams = @{
    HideHeaders = $SkipHeaderDisplay
    ShowLogs = $ShowLogs
    AdditionalHooksDir = $AdditionalHooksDir
    CacheK2sVSwitches = $CacheK2sVSwitches
}
& "$PSScriptRoot\..\..\..\windows\worker\windows-host\Stop.ps1" @workerNodeParams

Write-Log "[$logUseCase] Stopping control plane"
$controlPlaneParams = @{
    ShowLogs = $ShowLogs
    AdditionalHooksDir = $AdditionalHooksDir
    CacheK2sVSwitches = $CacheK2sVSwitches
    SkipHeaderDisplay = $SkipHeaderDisplay
}
& "$PSScriptRoot\..\..\..\control-plane\Stop.ps1" @controlPlaneParams

if ($SkipHeaderDisplay -eq $false) {
    Write-Log "[$logUseCase] ...Kubernetes system stopped."
}

