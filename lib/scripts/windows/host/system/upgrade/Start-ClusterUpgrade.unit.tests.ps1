# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
	# Load only the Start-ClusterUpgrade function: the script itself imports modules and starts a real upgrade
	$scriptPath = "$PSScriptRoot\Start-ClusterUpgrade.ps1"
	$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
	$functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-ClusterUpgrade' }, $true)
	. ([scriptblock]::Create($functionAst.Extent.Text))

	function Write-Log { param([string[]] $Messages, [switch] $Console) }
	function Get-TempPath { }
	function PrepareClusterUpgrade { param([Parameter(ValueFromRemainingArguments = $true)] $Rest) }
	function PerformClusterUpgrade {
		param(
			[switch] $ExecuteHooks,
			[string] $K2sPathToInstallFrom,
			[ref] $resourceRestoreErrors,
			[Parameter(ValueFromRemainingArguments = $true)] $Rest
		)
	}
	function Backup-EffectiveInstallConfig { param([string] $BackupDir) }
	function Resolve-UpgradeInstallConfig { param($RequestedConfig, $PreviousConfig, [switch] $Rollback) }
	function Get-ClusterInstalledFolder { }
	function Backup-LogFile { param([string] $LogFile) }
	function Remove-ExportedClusterResources { param([string] $PathResources, [switch] $DeleteFiles) }
}

Describe 'Start-ClusterUpgrade backup cleanup' -Tag 'unit', 'ci', 'upgrade' {
	BeforeEach {
		$script:performCalls = [System.Collections.ArrayList]@()
		Mock Write-Log { }
		Mock PrepareClusterUpgrade { return $true }
		Mock Backup-EffectiveInstallConfig { return 'previous-config' }
		Mock Resolve-UpgradeInstallConfig { return 'config' }
		Mock Get-ClusterInstalledFolder { return 'C:\k2s-old' }
		Mock Backup-LogFile { }
		Mock Remove-ExportedClusterResources { }
	}

	It 'deletes the backup after a successful upgrade with complete resource restore' {
		Mock PerformClusterUpgrade { $resourceRestoreErrors.Value = @() }

		$result = Start-ClusterUpgrade -BackupDir 'C:\Backup'

		$result | Should -BeNullOrEmpty
		Should -Invoke PerformClusterUpgrade -Exactly 1 -Scope It
		Should -Invoke Remove-ExportedClusterResources -Exactly 1 -Scope It -ParameterFilter { $PathResources -eq 'C:\Backup' -and $DeleteFiles }
	}

	It 'keeps the backup when resources could not be restored after an otherwise successful upgrade' {
		Mock PerformClusterUpgrade { $resourceRestoreErrors.Value = @('Backed-up issuers in namespace app were not restored') }

		$result = Start-ClusterUpgrade -BackupDir 'C:\Backup'

		$result | Should -BeNullOrEmpty
		Should -Invoke Remove-ExportedClusterResources -Exactly 0 -Scope It
		Should -Invoke Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "Keeping backup directory 'C:\\Backup' because some backed-up resources could not be restored" }
	}

	It 'rolls back and keeps the backup when the upgrade fails but the rollback succeeds' {
		Mock PerformClusterUpgrade { $script:performCalls.Add($ExecuteHooks.IsPresent) | Out-Null; throw 'upgrade failed' } -ParameterFilter { $ExecuteHooks }
		Mock PerformClusterUpgrade { $script:performCalls.Add($ExecuteHooks.IsPresent) | Out-Null; $resourceRestoreErrors.Value = @() } -ParameterFilter { -not $ExecuteHooks }

		$result = Start-ClusterUpgrade -BackupDir 'C:\Backup'

		$result | Should -BeNullOrEmpty
		$script:performCalls | Should -Be @($true, $false)
		Should -Invoke PerformClusterUpgrade -Exactly 1 -Scope It -ParameterFilter { -not $ExecuteHooks -and $K2sPathToInstallFrom -eq 'C:\k2s-old' }
		Should -Invoke Remove-ExportedClusterResources -Exactly 0 -Scope It
		Should -Invoke Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "Keeping backup directory 'C:\\Backup' because the upgrade failed: upgrade failed" }
	}

	It 'keeps the backup and returns false when the rollback fails' {
		Mock PerformClusterUpgrade { throw 'upgrade failed' } -ParameterFilter { $ExecuteHooks }
		Mock PerformClusterUpgrade { throw 'rollback failed' } -ParameterFilter { -not $ExecuteHooks }

		$result = Start-ClusterUpgrade -BackupDir 'C:\Backup' -ErrorAction SilentlyContinue

		$result | Should -Be $false
		Should -Invoke Remove-ExportedClusterResources -Exactly 0 -Scope It
		Should -Invoke Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "Keeping backup directory 'C:\\Backup' because the upgrade failed: upgrade failed; the rollback failed: rollback failed" }
	}

	It 'keeps the backup when PV restore errors are reported after an otherwise successful upgrade' {
		Mock PerformClusterUpgrade { $resourceRestoreErrors.Value = @("Persistent volume 'pv-b' could not be restored") }

		$result = Start-ClusterUpgrade -BackupDir 'C:\Backup'

		$result | Should -BeNullOrEmpty
		Should -Invoke Remove-ExportedClusterResources -Exactly 0 -Scope It
		Should -Invoke Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "Keeping backup directory 'C:\\Backup' because some backed-up resources could not be restored" }
	}

	It 'keeps the backup when the PV restore errors are recorded before the upgrade fails and the rollback succeeds' {
		Mock PerformClusterUpgrade { $resourceRestoreErrors.Value = @("Persistent volume 'pv-b' could not be restored"); throw 'upgrade failed' } -ParameterFilter { $ExecuteHooks }
		Mock PerformClusterUpgrade { $resourceRestoreErrors.Value = @() } -ParameterFilter { -not $ExecuteHooks }

		Start-ClusterUpgrade -BackupDir 'C:\Backup' | Out-Null

		Should -Invoke Remove-ExportedClusterResources -Exactly 0 -Scope It
	}

	It 'keeps the backup when the rolled-back cluster could not restore all resources' {
		Mock PerformClusterUpgrade { throw 'upgrade failed' } -ParameterFilter { $ExecuteHooks }
		Mock PerformClusterUpgrade { $resourceRestoreErrors.Value = @('Backed-up ClusterIssuers were not restored') } -ParameterFilter { -not $ExecuteHooks }

		Start-ClusterUpgrade -BackupDir 'C:\Backup' | Out-Null

		Should -Invoke Remove-ExportedClusterResources -Exactly 0 -Scope It
	}

	It 'keeps the backup and fails the upgrade when the preliminary export fails' {
		Mock PrepareClusterUpgrade { throw 'export failed' }
		Mock PerformClusterUpgrade { }

		{ Start-ClusterUpgrade -BackupDir 'C:\Backup' -ErrorAction SilentlyContinue } | Should -Throw 'export failed'

		Should -Invoke PerformClusterUpgrade -Exactly 0 -Scope It
		Should -Invoke Remove-ExportedClusterResources -Exactly 0 -Scope It
		Should -Invoke Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "Keeping backup directory 'C:\\Backup' because the preliminary steps failed" }
	}

	It 'fails the upgrade without uninstalling when the PV backup fails' {
		Mock PrepareClusterUpgrade { throw "PV backup failed for 1 of 2 persistent volume(s): pv-b. Upgrade aborted before uninstalling the current cluster" }
		Mock PerformClusterUpgrade { }

		{ Start-ClusterUpgrade -BackupDir 'C:\Backup' -ErrorAction SilentlyContinue } | Should -Throw '*PV backup failed for 1 of 2 persistent volume(s): pv-b*'

		Should -Invoke PerformClusterUpgrade -Exactly 0 -Scope It
		Should -Invoke Remove-ExportedClusterResources -Exactly 0 -Scope It
	}

	It 'returns false without upgrading when the preliminary checks decline the upgrade' {
		Mock PrepareClusterUpgrade { return $false }
		Mock PerformClusterUpgrade { }

		$result = Start-ClusterUpgrade -BackupDir 'C:\Backup'

		$result | Should -Be $false
		Should -Invoke PerformClusterUpgrade -Exactly 0 -Scope It
		Should -Invoke Remove-ExportedClusterResources -Exactly 0 -Scope It
	}
}

Describe 'Start-ClusterUpgrade PV backup and restore safety with the upgrade module' -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		$upgradeModulePath = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\upgrade\upgrade.module.psm1"
		$upgradeModuleName = (Import-Module $upgradeModulePath -PassThru -Force).Name

		if (-not (Get-Command Get-EnabledAddons -ErrorAction SilentlyContinue)) {
			function global:Get-EnabledAddons { return [System.Collections.ArrayList]@() }
			$script:removeEnabledAddonsStub = $true
		}

		# run Start-ClusterUpgrade inside the module so that it calls the real PrepareClusterUpgrade and PerformClusterUpgrade
		$functionText = $functionAst.Extent.Text -replace '^function Start-ClusterUpgrade', 'function script:Start-ClusterUpgrade'
		InModuleScope $upgradeModuleName -Parameters @{ FunctionText = $functionText } {
			param($FunctionText)
			. ([scriptblock]::Create($FunctionText))
		}

		$logFile = Join-Path $TestDrive 'k2s.log'
		Set-Content -Path $logFile -Value 'log'

		Mock -ModuleName $upgradeModuleName Get-SetupInfo { return @{ Name = 'k2s' } }
		Mock -ModuleName $upgradeModuleName Assert-UpgradeOperation { return $true }
		Mock -ModuleName $upgradeModuleName Enable-ClusterIsRunning
		Mock -ModuleName $upgradeModuleName Get-EnabledAddons { return [System.Collections.ArrayList]@() }
		Mock -ModuleName $upgradeModuleName Get-LinuxVMCores { return 4 }
		Mock -ModuleName $upgradeModuleName Get-LinuxVMMemory { return @{ Startup = '4GB'; DynamicMemoryEnabled = $false } }
		Mock -ModuleName $upgradeModuleName Get-LinuxVMStorageSize { return 100 }
		Mock -ModuleName $upgradeModuleName Assert-YamlTools
		Mock -ModuleName $upgradeModuleName Get-ClusterInstalledFolder { return 'C:\k2s-old' }
		Mock -ModuleName $upgradeModuleName Export-ClusterResources
		Mock -ModuleName $upgradeModuleName Invoke-UpgradeBackupRestoreHooks
		Mock -ModuleName $upgradeModuleName Backup-LogFile
		Mock -ModuleName $upgradeModuleName Restore-LogFile
		Mock -ModuleName $upgradeModuleName Write-Log
		Mock -ModuleName $upgradeModuleName Write-Progress
		Mock -ModuleName $upgradeModuleName Backup-EffectiveInstallConfig { return '' }
		Mock -ModuleName $upgradeModuleName Get-LogFilePath { return $logFile }
		Mock -ModuleName $upgradeModuleName Remove-SetupConfigIfExisting
		Mock -ModuleName $upgradeModuleName Start-Sleep
		Mock -ModuleName $upgradeModuleName Get-KubePath { return 'C:\k2s-new' }
		Mock -ModuleName $upgradeModuleName Wait-ForAPIServerInGivenKubePath
		Mock -ModuleName $upgradeModuleName Get-KubeBinPathGivenKubePath { return 'C:\k2s-new\bin\kube' }
		Mock -ModuleName $upgradeModuleName Get-ProductVersion { return '2.1.0' }
		Mock -ModuleName $upgradeModuleName Get-ProductVersionGivenKubePath { return '2.0.0' }
		Mock -ModuleName $upgradeModuleName Write-RefreshEnvVariablesGivenKubePath
		Mock -ModuleName $upgradeModuleName Invoke-ClusterUninstall {
			$script:events.Add('uninstall') | Out-Null
			# simulates PV backup data getting lost between backup and restore
			$pvDir = Join-Path $script:currentBackupDir 'pv'
			if ($script:pvBackupLoss -eq 'directory') {
				Remove-Item -Path $pvDir -Recurse -Force
			}
			elseif ($script:pvBackupLoss -eq 'archives') {
				Get-ChildItem -Path $pvDir -File | Remove-Item -Force
			}
		}
		Mock -ModuleName $upgradeModuleName Remove-ExportedClusterResources {
			param($PathResources)
			Remove-Item -Path $PathResources -Recurse -Force
		}
		Mock -ModuleName $upgradeModuleName Invoke-ClusterInstall {
			$script:events.Add('install') | Out-Null
			$script:installCalls++
			if ($script:installCalls -le $script:failingInstallCalls) {
				throw "install $($script:installCalls) failed"
			}
		}
		Mock -ModuleName $upgradeModuleName Backup-AllPersistentVolumes {
			param($ExportPath)
			$script:events.Add('backup') | Out-Null
			New-Item -Path $ExportPath -ItemType Directory -Force | Out-Null
			foreach ($pvName in $script:pvNames) {
				Set-Content -Path (Join-Path $ExportPath "$pvName-backup.tar.gz") -Value "$pvName data"
			}
			if ($script:backupThrows) {
				throw 'kubectl get pv failed with exit code 1'
			}
			$result = @{}
			foreach ($pvName in $script:pvNames) {
				$result[$pvName] = $script:failingBackups -notcontains $pvName
			}
			$discovered = @($script:pvNames | ForEach-Object { [pscustomobject]@{ Name = $_; Type = 'local' } })
			$unsupported = @($script:unsupportedPVs.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Type = $script:unsupportedPVs[$_] } })
			return [pscustomobject]@{ Discovered = @($discovered + $unsupported); Excluded = @(); Unsupported = $unsupported; Results = $result }
		}
		Mock -ModuleName $upgradeModuleName Restore-AllPersistentVolumes {
			$script:events.Add('restore') | Out-Null
			if ($script:restoreThrows) {
				throw 'restore crashed'
			}
			$result = @{}
			foreach ($pvName in $script:pvNames) {
				$result[$pvName] = $script:failingRestores -notcontains $pvName
			}
			return $result
		}

		function Invoke-StartClusterUpgradeInModule {
			param([string] $BackupDir)
			InModuleScope $upgradeModuleName -Parameters @{ BackupDir = $BackupDir } {
				param($BackupDir)
				Start-ClusterUpgrade -BackupDir $BackupDir -SkipResources -SkipImages -ErrorAction SilentlyContinue
			}
		}
	}

	AfterAll {
		if ($script:removeEnabledAddonsStub) {
			Remove-Item -Path Function:\Get-EnabledAddons -ErrorAction SilentlyContinue
		}
		Remove-Module $upgradeModuleName -Force -ErrorAction SilentlyContinue
	}

	BeforeEach {
		$script:events = [System.Collections.ArrayList]@()
		$script:pvNames = @('pv-a', 'pv-b')
		$script:failingBackups = @()
		$script:failingRestores = @()
		$script:backupThrows = $false
		$script:restoreThrows = $false
		$script:installCalls = 0
		$script:failingInstallCalls = 0
		$script:unsupportedPVs = @{}
		$script:pvBackupLoss = ''
		$backupDir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
		$script:currentBackupDir = $backupDir
		New-Item -Path $backupDir -ItemType Directory | Out-Null
	}

	It 'backs up, uninstalls, installs and restores in order and deletes the backup after success' {
		$result = Invoke-StartClusterUpgradeInModule -BackupDir $backupDir

		$result | Should -BeNullOrEmpty
		$script:events | Should -Be @('backup', 'uninstall', 'install', 'restore')
		Test-Path $backupDir | Should -BeFalse
		Should -Invoke -ModuleName $upgradeModuleName Remove-ExportedClusterResources -Exactly 1 -Scope It
	}

	It 'aborts before uninstalling and keeps the backup directory when a PV has an unsupported volume type' {
		$script:unsupportedPVs = @{ 'pv-nfs' = 'nfs' }

		{ Invoke-StartClusterUpgradeInModule -BackupDir $backupDir } | Should -Throw '*1 of 3 discovered persistent volume(s) are neither excluded nor backed up*pv-nfs (nfs)*'

		$script:events | Should -Be @('backup')
		Should -Invoke -ModuleName $upgradeModuleName Invoke-ClusterUninstall -Exactly 0 -Scope It
		Should -Invoke -ModuleName $upgradeModuleName Remove-ExportedClusterResources -Exactly 0 -Scope It
		Test-Path (Join-Path $backupDir 'pv\pv-a-backup.tar.gz') | Should -BeTrue
		Should -Invoke -ModuleName $upgradeModuleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "\[PVBackup\] ERROR: Persistent volume 'pv-nfs' \(type 'nfs'\) is not backed up" }
	}

	It 'keeps the backup directory when the expected PV backup directory is missing at restore time' {
		$script:pvBackupLoss = 'directory'

		$result = Invoke-StartClusterUpgradeInModule -BackupDir $backupDir

		$result | Should -BeNullOrEmpty
		$script:events | Should -Be @('backup', 'uninstall', 'install')
		Test-Path $backupDir | Should -BeTrue
		Should -Invoke -ModuleName $upgradeModuleName Remove-ExportedClusterResources -Exactly 0 -Scope It
		Should -Invoke -ModuleName $upgradeModuleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "\[PVRestore\] ERROR: PV backup directory '.*' not found" }
		Should -Invoke -ModuleName $upgradeModuleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'Keeping backup directory .* because some backed-up resources could not be restored' }
	}

	It 'keeps the backup directory when the PV backup directory contains no backup archives at restore time' {
		$script:pvBackupLoss = 'archives'

		$result = Invoke-StartClusterUpgradeInModule -BackupDir $backupDir

		$result | Should -BeNullOrEmpty
		$script:events | Should -Be @('backup', 'uninstall', 'install')
		Test-Path (Join-Path $backupDir 'pv') | Should -BeTrue
		Should -Invoke -ModuleName $upgradeModuleName Remove-ExportedClusterResources -Exactly 0 -Scope It
		Should -Invoke -ModuleName $upgradeModuleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "\[PVRestore\] ERROR: No PV backup archives found in '.*'" }
	}

	It 'keeps the backup directory when some backup archives were not restored' {
		$script:pvNames = @('pv-a', 'pv-b')
		Mock -ModuleName $upgradeModuleName Restore-AllPersistentVolumes {
			$script:events.Add('restore') | Out-Null
			return @{ 'pv-a' = $true }
		}

		$result = Invoke-StartClusterUpgradeInModule -BackupDir $backupDir

		$result | Should -BeNullOrEmpty
		Test-Path (Join-Path $backupDir 'pv\pv-b-backup.tar.gz') | Should -BeTrue
		Should -Invoke -ModuleName $upgradeModuleName Remove-ExportedClusterResources -Exactly 0 -Scope It
		Should -Invoke -ModuleName $upgradeModuleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "\[PVRestore\] ERROR: Only 1 of 2 PV backup archive\(s\) in '.*' were restored, not restored: pv-b" }
	}

	It 'upgrades and deletes the backup when the cluster has no PVs' {
		$script:pvNames = @()

		$result = Invoke-StartClusterUpgradeInModule -BackupDir $backupDir

		$result | Should -BeNullOrEmpty
		$script:events | Should -Be @('backup', 'uninstall', 'install')
		Test-Path $backupDir | Should -BeFalse
	}

	It 'aborts before uninstalling and keeps the partial backup when one PV backup fails' {
		$script:failingBackups = @('pv-b')

		{ Invoke-StartClusterUpgradeInModule -BackupDir $backupDir } | Should -Throw "*PV backup failed for 1 of 2 persistent volume(s): pv-b*"

		$script:events | Should -Be @('backup')
		Should -Invoke -ModuleName $upgradeModuleName Invoke-ClusterUninstall -Exactly 0 -Scope It
		Test-Path (Join-Path $backupDir 'pv\pv-a-backup.tar.gz') | Should -BeTrue
		Test-Path (Join-Path $backupDir 'pv\pv-b-backup.tar.gz') | Should -BeTrue
	}

	It 'aborts before uninstalling and keeps the backup directory when PV discovery fails' {
		$script:backupThrows = $true

		{ Invoke-StartClusterUpgradeInModule -BackupDir $backupDir } | Should -Throw '*PV backup failed: kubectl get pv failed with exit code 1*'

		Should -Invoke -ModuleName $upgradeModuleName Invoke-ClusterUninstall -Exactly 0 -Scope It
		Test-Path $backupDir | Should -BeTrue
	}

	It 'keeps the complete backup directory when one PV restore fails' {
		$script:failingRestores = @('pv-b')

		$result = Invoke-StartClusterUpgradeInModule -BackupDir $backupDir

		$result | Should -BeNullOrEmpty
		$script:events | Should -Be @('backup', 'uninstall', 'install', 'restore')
		Test-Path (Join-Path $backupDir 'pv\pv-a-backup.tar.gz') | Should -BeTrue
		Test-Path (Join-Path $backupDir 'pv\pv-b-backup.tar.gz') | Should -BeTrue
		Should -Invoke -ModuleName $upgradeModuleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "\[PVRestore\] ERROR: Persistent volume 'pv-b' could not be restored" }
	}

	It 'keeps the backup directory when the PV restore throws' {
		$script:restoreThrows = $true

		$result = Invoke-StartClusterUpgradeInModule -BackupDir $backupDir

		$result | Should -BeNullOrEmpty
		Test-Path (Join-Path $backupDir 'pv\pv-a-backup.tar.gz') | Should -BeTrue
		Should -Invoke -ModuleName $upgradeModuleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match '\[PVRestore\] ERROR: PV restore failed: restore crashed' }
	}

	It 'keeps the backup directory when the upgrade fails and the rollback succeeds' {
		$script:failingInstallCalls = 1

		$result = Invoke-StartClusterUpgradeInModule -BackupDir $backupDir

		$result | Should -BeNullOrEmpty
		$script:events | Should -Be @('backup', 'uninstall', 'install', 'uninstall', 'install', 'restore')
		Test-Path (Join-Path $backupDir 'pv\pv-a-backup.tar.gz') | Should -BeTrue
		Test-Path (Join-Path $backupDir 'pv\pv-b-backup.tar.gz') | Should -BeTrue
	}

	It 'keeps the backup directory and returns false when the rollback fails' {
		$script:failingInstallCalls = 2

		$result = Invoke-StartClusterUpgradeInModule -BackupDir $backupDir

		$result | Should -Be $false
		$script:events | Should -Be @('backup', 'uninstall', 'install', 'uninstall', 'install')
		Test-Path (Join-Path $backupDir 'pv\pv-a-backup.tar.gz') | Should -BeTrue
		Test-Path (Join-Path $backupDir 'pv\pv-b-backup.tar.gz') | Should -BeTrue
	}
}
