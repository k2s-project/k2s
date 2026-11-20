# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [string] $NodeName = $(throw 'Argument missing: NodeName'),
    [string] $UserName = '',
    [string] $IpAddress = '',
    [switch] $ShowLogs = $false,
    [string] $AdditionalHooksDir = '',
    [switch] $SkipHeaderDisplay = $false
)

$preparationStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule =   "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Stop'

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

$node = Get-NodeConfig -NodeName $NodeName

if ($null -ne $node) {
    if ($UserName -eq '') {
        $UserName = $node.UserName
    }

    if ($IpAddress -eq '') {
        $IpAddress = $node.IpAddress
    }
}

if ($UserName -eq '' -or $IpAddress -eq '') {
   Write-Log "[WARN] Cannot remove the node without Username and IpAddress."
   return
}

# check if the computer is already part of the cluster
$k8sFormattedNodeName = $NodeName.ToLower()
$clusterState = (Invoke-Kubectl -Params @('get', 'nodes', '-o', 'wide')).Output
if ($clusterState -notmatch $k8sFormattedNodeName) {
    Write-Log "The node '$k8sFormattedNodeName' is not part of the cluster."
}

$connectionCheck = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'which ls' -UserName $UserName -IpAddress $IpAddress)
$isNodeReachable = $connectionCheck.Success
if (!$isNodeReachable) {
    Write-Log "[WARN] Cannot connect to the computer with IP address '$IpAddress'. The node/VM may already be deleted. Proceeding with cluster-side cleanup only." -Console
}

$k8sFormattedNodeName = $NodeName.ToLower()
if ($isNodeReachable) {
    $actualHostname = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'echo $(hostname)' -UserName $UserName -IpAddress $IpAddress).Output
    if ($k8sFormattedNodeName -ne $actualHostname.ToLower()) {
        throw "The passed NodeName '$NodeName' is not the name of the node with IP '$IpAddress' ($actualHostname)"
    }

    Write-Log 'Stop the worker node'
    & "$PSScriptRoot\Stop.ps1" -AdditionalHooksDir $AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay:$SkipHeaderDisplay -NodeName $NodeName
}

$workerNodeParams = @{
    NodeName = $NodeName
    UserName = $UserName
    IpAddress = $IpAddress
    AdditionalHooksDir = $AdditionalHooksDir
    SkipRemoteCleanup = (-not $isNodeReachable)
}
Remove-LinuxWorkerNode @workerNodeParams

Write-Log "Current state of kubernetes nodes:`n"
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide 2>&1 | ForEach-Object { "$_" } | Write-Log

Write-Log '---------------------------------------------------------------'
Write-Log "Linux computer with IP '$IpAddress' and hostname '$NodeName' removed from the cluster.   Total duration: $('{0:hh\:mm\:ss}' -f $preparationStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'
