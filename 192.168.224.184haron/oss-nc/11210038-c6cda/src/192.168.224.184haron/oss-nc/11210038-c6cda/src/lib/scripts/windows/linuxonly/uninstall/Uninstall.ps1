# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Removes the Linux-only K2s setup.

.DESCRIPTION
This script assists in the following actions for K2s:
- Removal of
-- VMs
-- virtual disks
-- virtual switches
-- config files
-- config entries
-- etc.

.PARAMETER SkipPurge
Specifies whether to skip the deletion of binaries, config files etc.
#>
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

$infraModule = "$PSScriptRoot\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\..\..\addons\addons.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

if (-not $SkipHeaderDisplay) {
    Write-Log 'Uninstalling Linux-only K2s'
}

Invoke-AddonsHooks -HookType 'BeforeUninstall'

$ErrorActionPreference = 'Continue'

$controlPlaneParams = @{
    SkipPurge                         = $SkipPurge
    ShowLogs                          = $ShowLogs
    AdditionalHooksDir                = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    SkipHeaderDisplay                 = $SkipHeaderDisplay
}
& "$PSScriptRoot\..\..\..\control-plane\Uninstall.ps1" @controlPlaneParams

Remove-K2sHostsFromNoProxyEnvVar

Invoke-AddonsHooks -HookType 'AfterUninstall'

if (-not $SkipHeaderDisplay) {
    Write-Log 'K2s Linux-only uninstalled.'
}

# Refresh PATH for current session to avoid stale k2s entries
$env:PATH =
[Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
        [Environment]::GetEnvironmentVariable("Path", "User")

Save-k2sLogDirectory -RemoveVar

