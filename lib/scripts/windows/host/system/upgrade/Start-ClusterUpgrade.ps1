# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Starts the upgrade of the cluster.

.DESCRIPTION
Starts the upgrade of the cluster by exporting all resources and setting up a new cluster from current directory.


.EXAMPLE
# Starts the upgrade of the cluster
PS> .\Start-ClusterUpgrade.ps1

#>

Param(
	[Parameter(Mandatory = $false, HelpMessage = 'Show progress bar')]
	[switch] $ShowProgress = $false,
	[Parameter(Mandatory = $false, HelpMessage = 'Skip move of resources during upgrade')]
	[switch] $SkipResources = $false,
	[Parameter(Mandatory = $false, HelpMessage = 'Delete resource files after upgrade')]
	[switch] $DeleteFiles = $false,
	[parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
	[switch] $ShowLogs = $false,
	[Parameter(Mandatory = $false, HelpMessage = 'Skip takeover of container images')]
	[switch] $SkipImages = $false,
	[parameter(Mandatory = $false, HelpMessage = 'Config file for setting up new cluster')]
	[string] $Config,
	[parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
	[string] $Proxy,
	[parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
	[string] $AdditionalHooksDir = '',
	[parameter(Mandatory = $false, HelpMessage = 'Directory for resource backup')]
	[string] $BackupDir = '',
	[parameter(Mandatory = $false, HelpMessage = 'Force upgrade even if versions are not consecutive')]
	[switch] $Force = $false
)
$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\..\..\..\addons\addons.module.psm1"

Initialize-Logging -ShowLogs:$ShowLogs

# Check if we're running from a delta package directory
$deltaManifestPath = Join-Path $PSScriptRoot '..\\..\\..\..\..\..\delta-manifest.json'
if (Test-Path $deltaManifestPath) {
	Write-Log "Delta package detected at '$deltaManifestPath' - performing in-place update instead of full upgrade" -Console

	# Call the delta update script instead
	$updateScriptPath = Join-Path $PSScriptRoot '..\\..\\..\..\..\..\lib\scripts\windows\host\system\update\Start-ClusterUpdate.ps1'

	if (-not (Test-Path $updateScriptPath)) {
		Write-Log "ERROR: Delta update script not found at '$updateScriptPath'" -Console
		throw "Delta update script not found"
	}

	# Pass through all parameters to the update script
	$updateParams = @{}
	if ($ShowLogs) { $updateParams['ShowLogs'] = $true }

	Write-Log "Executing delta update: $updateScriptPath" -Console
	& $updateScriptPath @updateParams

	# Exit after delta update completes
	exit $LASTEXITCODE
}

Import-Module $infraModule, $clusterModule, $addonsModule
# If we reach here, we're doing a normal full upgrade
Write-Log "Performing full cluster upgrade from installation package" -Console

<#
 .Synopsis
  Upgrades the K8s cluster to new version from current directory.

  .Description
  Upgrades the K8s cluster to new version from current directory.

  .PARAMETER ShowProgress
  If set to $true, shows the overalls progress on operation-level.

 .Example
  Start-ClusterUpgrade

 .Example
  Start-ClusterUpgrade -ShowProgress $true -SkipResources $false

 .OUTPUTS
  Status object
#>
function Start-ClusterUpgrade {
	param(
		[Parameter(Mandatory = $false, HelpMessage = 'Show progress bar')]
		[switch] $ShowProgress = $false,
		[Parameter(Mandatory = $false, HelpMessage = 'Skip move of resources during upgrade')]
		[switch] $SkipResources = $false,
		[Parameter(Mandatory = $false, HelpMessage = 'Delete resource files after upgrade')]
		[switch] $DeleteFiles = $false,
		[parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
		[switch] $ShowLogs = $false,
		[parameter(Mandatory = $false, HelpMessage = 'Config file for setting up new cluster')]
		[string] $Config,
		[parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
		[string] $Proxy,
		[parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
		[string] $AdditionalHooksDir = '',
		[Parameter(Mandatory = $false, HelpMessage = 'Skip takeover of container images')]
		[switch] $SkipImages = $false,
		[parameter(Mandatory = $false, HelpMessage = 'Directory for resource backup')]
		[string] $BackupDir = '',
		[parameter(Mandatory = $false, HelpMessage = 'Force upgrade even if versions are not consecutive')]
		[switch] $Force = $false
	)
	$errUpgrade = $null

	$coresVM = [ref]''
	$memoryVM = [ref]''
	$storageVM = [ref]''

	$enabledAddonsList = [ref]$null
	$hooksBackupPath = [ref]''
	$logFilePathBeforeUninstall = [ref]''
	$imagesBackupPath = [ref]''
	$pvBackupPath = [ref]''
	$resourceRestoreErrors = [ref]@()

	if ($BackupDir -eq '') {
		$BackupDir = Get-TempPath
	}

	Write-Log "The backup directory is '$BackupDir'"

	try {
		$prepareSuccess = PrepareClusterUpgrade -ShowProgress:$ShowProgress -SkipResources:$SkipResources -SkipImages:$SkipImages -ShowLogs:$ShowLogs -Proxy $Proxy -BackupDir $BackupDir -Force:$Force -AdditionalHooksDir $AdditionalHooksDir -coresVM $coresVM -memoryVM $memoryVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall -imagesBackupPath $imagesBackupPath -pvBackupPath $pvBackupPath
		if (-not $prepareSuccess) {
			return $false
		}
	}
	catch {
		Write-Log 'An ERROR occurred:' -Console
		Write-Log $_.ScriptStackTrace -Console
		Write-Log $_ -Console
		$errUpgrade = $_
		Write-Error 'Unfortunately preliminary steps to export resources of current cluster failed, please check the logs for more information !'
		return $false
	}

	$previousInstallConfig = Backup-EffectiveInstallConfig -BackupDir $BackupDir
	$forwardInstallConfig = Resolve-UpgradeInstallConfig -RequestedConfig $Config -PreviousConfig $previousInstallConfig
	$installedFolder = Get-ClusterInstalledFolder
	try {
		PerformClusterUpgrade -ExecuteHooks:$true -ShowProgress:$ShowProgress -DeleteFiles:$DeleteFiles -ShowLogs:$ShowLogs -Config $forwardInstallConfig -Proxy $Proxy -BackupDir $BackupDir -AdditionalHooksDir $AdditionalHooksDir -memoryVM $memoryVM.Value -coresVM $coresVM.Value -storageVM $storageVM.Value -enabledAddonsList $enabledAddonsList.Value -hooksBackupPath $hooksBackupPath.Value -logFilePathBeforeUninstall $logFilePathBeforeUninstall.Value -imagesBackupPath $imagesBackupPath.Value -pvBackupPath $pvBackupPath.Value -SkipImages:$SkipImages -skipResources:$SkipResources -resourceRestoreErrors $resourceRestoreErrors
	}
	catch {
		Write-Log 'System upgrade failed, will rollback to previous state !'
		try {
			 # backup log file since it will be deleted during uninstall
			$logFilePathBeforeUninstall.Value = Join-Path $BackupDir 'k2s-before-uninstall.log'
			Backup-LogFile -LogFile $logFilePathBeforeUninstall.Value
			$rollbackInstallConfig = Resolve-UpgradeInstallConfig -RequestedConfig $Config -PreviousConfig $previousInstallConfig -Rollback
			# Execute the upgrade without executing the upgrade hooks and from the installed folder (folder used before upgrade)
			PerformClusterUpgrade -ExecuteHooks:$false -K2sPathToInstallFrom $installedFolder -ShowProgress:$ShowProgress -DeleteFiles:$DeleteFiles -ShowLogs:$ShowLogs -Config $rollbackInstallConfig -Proxy $Proxy -BackupDir $BackupDir -AdditionalHooksDir $AdditionalHooksDir -memoryVM $memoryVM.Value -coresVM $coresVM.Value -storageVM $storageVM.Value -enabledAddonsList $enabledAddonsList.Value -hooksBackupPath $hooksBackupPath.Value -logFilePathBeforeUninstall $logFilePathBeforeUninstall.Value -imagesBackupPath $imagesBackupPath.Value -pvBackupPath $pvBackupPath.Value -SkipImages:$SkipImages -skipResources:$SkipResources -resourceRestoreErrors $resourceRestoreErrors
		}
		catch {
			Write-Log 'An ERROR occurred:' -Console
			Write-Log $_.ScriptStackTrace -Console
			Write-Log $_ -Console
			Write-Error 'System upgrade failed, please check the logs for more information !'
			return $false
		}
	}
	finally {
		if ($ShowProgress -eq $true) {
			Write-Progress -Activity 'Remove exported resources..' -Id 1 -Status '5/8' -PercentComplete 50 -CurrentOperation 'Remove exported resources, please wait..'
		}
		if (-not $errUpgrade) {
			if (@($resourceRestoreErrors.Value).Count -gt 0) {
				Write-Log "Keeping backup directory '$BackupDir' because some backed-up resources could not be restored" -Console
			}
			else {
				# remove temp cluster resources
				Remove-ExportedClusterResources -PathResources $BackupDir -DeleteFiles:$true
			}
		}
	}
	if ( $errUpgrade ) {
		return $false
	}
}

#####################################################
###############START OF UPGRADE######################
#####################################################

Write-Log 'Starting upgrading cluster' -Console
$ret = Start-ClusterUpgrade -ShowProgress:$ShowProgress -SkipResources:$SkipResources -DeleteFiles:$DeleteFiles -ShowLogs:$ShowLogs -Config $Config -Proxy $Proxy -SkipImages:$SkipImages -AdditionalHooksDir $AdditionalHooksDir -BackupDir $BackupDir -Force:$Force
if ( $ret ) {
	Restore-MergeLogFiles
}
