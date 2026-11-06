# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Continue'

# make sure we are at the right place for executing this script
$installationPath = Get-KubePath
Set-Location $installationPath

$installationType = 'Build-only'
Write-Log "Uninstalling $installationType setup"

Uninstall-WinNode

try {
    $controlPlaneNodeParams = @{
        ShowLogs = $ShowLogs
        DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
        SkipHeaderDisplay = $true
    }
    & "$PSScriptRoot\..\..\..\control-plane\Uninstall.ps1" @controlPlaneNodeParams
}
catch {
    Write-Log "Warning: Control-plane cleanup encountered an error: $($_.Exception.Message)" -Console
}

Remove-K2sHostsFromNoProxyEnvVar

Write-Log "K2s $installationType setup uninstalled."

Save-k2sLogDirectory -RemoveVar

