# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Starts the update of the cluster.

.DESCRIPTION
Starts the update of the cluster by doing an in-place upgrade.


.EXAMPLE
# Starts the update of the cluster
PS> .\Start-ClusterUpdate.ps1

#>

Param(
	[Parameter(Mandatory = $false, HelpMessage = 'Show progress bar')]
	[switch] $ShowProgress = $false,
	[parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
	[switch] $ShowLogs = $false
)

# Detect if running from delta package (delta-manifest.json 6 levels up)
$possibleDeltaRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\..\..'))
$deltaManifestPath = Join-Path $possibleDeltaRoot 'delta-manifest.json'
$runningFromDelta = Test-Path -LiteralPath $deltaManifestPath

if ($runningFromDelta) {
	# Running from delta package - reference modules from target installation
	Write-Host "[Update] Detected delta package context - loading modules from target installation" -ForegroundColor Cyan

	# Get target installation path from setup.json
	$setupConfigPath = "$env:SystemDrive\ProgramData\k2s\setup.json"
	if (Test-Path -LiteralPath $setupConfigPath) {
		$setupConfig = Get-Content -LiteralPath $setupConfigPath -Raw | ConvertFrom-Json
		$targetInstallPath = $setupConfig.InstallFolder
	} else {
		$targetInstallPath = 'C:\k'
	}

	if (-not (Test-Path -LiteralPath $targetInstallPath)) {
		Write-Host "[Update][Error] Target installation not found at: $targetInstallPath" -ForegroundColor Red
		exit 1
	}

	$infraModule = Join-Path $targetInstallPath 'lib\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1'
	$clusterModule = Join-Path $targetInstallPath 'lib\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1'
	$addonsModule = Join-Path $targetInstallPath 'addons\addons.module.psm1'

	# Load update module from DELTA PACKAGE (it's new/updated and may not exist in target installation)
	# Infrastructure modules are loaded from target installation so paths resolve correctly via Get-KubePath.
	# NOTE: When the delta update relocates the installation to the new folder, PerformClusterUpdate
	# performs the re-home internally (it re-imports node modules from the new folder by absolute path,
	# restarts the cluster via the new k2s.exe and writes the new InstallFolder to setup.json, which
	# lives at the fixed ProgramData location). Therefore loading these modules from the previous
	# installation folder here remains correct for the whole update run.
	$updateModule = Join-Path $possibleDeltaRoot 'lib\modules\windows\cluster\k2s.cluster.module\update\update.module.psm1'
} else {
	# Running from installed k2s - use relative paths
	$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
	$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
	$addonsModule = "$PSScriptRoot\..\..\..\..\..\..\addons\addons.module.psm1"
	$updateModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\update\update.module.psm1"
}

Import-Module $infraModule, $clusterModule, $addonsModule, $updateModule -ErrorAction Stop

Initialize-Logging -ShowLogs:$ShowLogs

<#
 .Synopsis
  Updates the K8s cluster to new version from current directory.

  .Description
  Updates the K8s cluster to new version from current directory.

  .PARAMETER ShowProgress
  If set to $true, shows the overalls progress on operation-level.

 .Example
  Start-ClusterUpdate

 .Example
  Start-ClusterUpdate -ShowProgress $true -SkipResources $false

 .OUTPUTS
  Status object
#>
function Start-ClusterUpdate {
	param(
		[Parameter(Mandatory = $false, HelpMessage = 'Show progress bar')]
		[switch] $ShowProgress = $false,
		[parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
		[switch] $ShowLogs = $false
	)
	$errUpdate = $null

	try {
		PerformClusterUpdate -ExecuteHooks:$true -ShowProgress:$ShowProgress -ShowLogs:$ShowLogs
	}
	catch {
		Write-Log 'System update failed' -Console
		Write-Log 'An ERROR occurred:' -Console
		Write-Log $_.ScriptStackTrace -Console
		Write-Log $_ -Console
		Write-Error 'System update failed, please check the logs for more information!'
		return $false
	}

	if ( $errUpdate ) {
		return $false
	}
}

#####################################################
###############START OF UPDATE#######################
#####################################################

Write-Log 'Starting updating cluster' -Console
$updateSucceeded = Start-ClusterUpdate -ShowProgress:$ShowProgress -ShowLogs:$ShowLogs
if (-not $updateSucceeded) {
	exit 1
}
exit 0
