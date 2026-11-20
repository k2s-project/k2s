# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator


Param(
    [parameter(Mandatory = $false, HelpMessage = 'Do not purge all files')]
    [switch] $SkipPurge = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing uninstall header display')]
    [switch] $SkipHeaderDisplay = $false
)

$infraModule = "$PSScriptRoot\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\addons\addons.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

# make sure we are at the right place for executing this script
$installationPath = Get-KubePath
Set-Location $installationPath

Write-Log 'Stop the control plane'
& "$PSScriptRoot\Stop.ps1" -AdditionalHooksDir $AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay:$SkipHeaderDisplay

Remove-WinHttpProxy
Remove-WinDnsProxy

$controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
Write-Log "Uninstalling $controlPlaneVMHostName VM" -Console
Remove-ControlPlaneNodeOnNewVM -SkipPurge:$SkipPurge -AdditionalHooksDir $AdditionalHooksDir -SkipHeaderDisplay:$SkipHeaderDisplay -DeleteFilesForOfflineInstallation:$DeleteFilesForOfflineInstallation

Remove-KubeNodeBaseImage -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation
