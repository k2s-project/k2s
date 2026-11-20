# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [string] $NodeName = $(throw 'Argument missing: NodeName'),
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing stop header display')]
    [switch] $SkipHeaderDisplay = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Indicates this is a single node stop operation')]
    [switch] $SingleNode = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Wait for node to become not ready')]
    [switch] $WaitForNotReady = $false
)

$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

# Dot-source common Linux worker node functions
$linuxWorkerCommon = "$PSScriptRoot\..\common\LinuxWorkerNode.Common.ps1"
. $linuxWorkerCommon

Initialize-Logging -ShowLogs:$ShowLogs

# make sure we are at the right place for executing this script
$kubePath = Get-KubePath
Set-Location $kubePath

$ProgressPreference = 'SilentlyContinue'

$workerNodeName = $NodeName.ToLower()

$workerNodeStopParams = @{
    AdditionalHooksDir = $AdditionalHooksDir
    NodeName           = $workerNodeName
}
Stop-LinuxWorkerNode @workerNodeStopParams

# Stop kubelet/runtime so the node transitions to NotReady.
# -WaitForNotReady controls whether to block until the transition completes.
Invoke-LinuxWorkerNodeStop -NodeName $workerNodeName -WaitForNotReady:$WaitForNotReady -LogPrefix '[existing-vm]'
