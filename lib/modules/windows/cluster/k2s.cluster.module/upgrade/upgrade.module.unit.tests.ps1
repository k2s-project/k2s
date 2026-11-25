# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
	$moduleName = (Import-Module "$PSScriptRoot\upgrade.module.psm1" -PassThru -Force).Name

	# builds a Backup-AllPersistentVolumes report; every PV in Results, Excluded and Unsupported is also discovered
	function New-PVBackupReport {
		param(
			[System.Collections.IDictionary] $Results = @{},
			[string[]] $Excluded = @(),
			[System.Collections.IDictionary] $Unsupported = @{},
			[System.Collections.IDictionary] $Types = @{},
			[string[]] $NotReported = @()
		)
		$discovered = @()
		foreach ($name in @(@($Results.Keys) + $Excluded + $NotReported)) {
			$type = if ($Types.Contains($name)) { $Types[$name] } else { 'local' }
			$discovered += [pscustomobject]@{ Name = $name; Type = $type }
		}
		$unsupportedEntries = @()
		foreach ($name in $Unsupported.Keys) {
			$discovered += [pscustomobject]@{ Name = $name; Type = $Unsupported[$name] }
			$unsupportedEntries += [pscustomobject]@{ Name = $name; Type = $Unsupported[$name] }
		}
		return [pscustomobject]@{ Discovered = $discovered; Excluded = @($Excluded); Unsupported = $unsupportedEntries; Results = $Results }
	}
}

Import-Module "$PSScriptRoot\..\..\k2s.cluster.module"
Import-Module "$PSScriptRoot\..\..\..\infra\k2s.infra.module"
Import-Module "$PSScriptRoot\..\..\..\..\..\..\addons\addons.module.psm1"

Describe 'Assert-UpgradeVersionIsValid' -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		Mock -ModuleName $moduleName Write-Log {}
	}

	It "returns '<ExpectedResult>' when current version is '<Current>' and new version is'<New>'" -ForEach @(
		@{ ExpectedResult = $true; Current = '1.0.0'; New = '1.0.1' }
		@{ ExpectedResult = $true; Current = '1.0.0'; New = '1.0.11' }
		@{ ExpectedResult = $true; Current = '1.0.0'; New = '1.1.0' }
		@{ ExpectedResult = $true; Current = '1.0.0'; New = '1.1.11' }
		@{ ExpectedResult = $true; Current = '1.1.1'; New = '1.2.0' }
		@{ ExpectedResult = $true; Current = '1.2.3'; New = '1.3.444' }
		@{ ExpectedResult = $true; Current = '2.3.4'; New = '2.4.0' }
		@{ ExpectedResult = $true; Current = '1.8.1'; New = '2.0.0' }

		@{ ExpectedResult = $false; Current = '1.0.0'; New = '1.2.0' }
		@{ ExpectedResult = $false; Current = '2.0.0'; New = '2.2.0' }

		@{ ExpectedResult = $false; Current = '1.1.0'; New = '1.0.0' }
		@{ ExpectedResult = $false; Current = '1.1.1'; New = '1.1.0' }
		@{ ExpectedResult = $false; Current = '2.0.0'; New = '1.0.0' }

		@{ ExpectedResult = $false; Current = '1.0'; New = '1.1.0' }
		@{ ExpectedResult = $false; Current = '1.0.0'; New = '1.1' }

		@{ ExpectedResult = $false; Current = '1.o.o'; New = '1.1.0' }
		@{ ExpectedResult = $false; Current = '1.0.0'; New = '1.1.o' }

		@{ ExpectedResult = $false; Current = '1'; New = '1.1.0' }
		@{ ExpectedResult = $false; Current = '1.0.0'; New = '2' }

		@{ ExpectedResult = $false; Current = '1.0.0.0'; New = '1.1.0' }
		@{ ExpectedResult = $false; Current = '1.0.0'; New = '1.1.0.0' }

		@{ ExpectedResult = $false; Current = '1.0.0-beta'; New = '1.1.0' }
		@{ ExpectedResult = $false; Current = '1.0.0'; New = '1.1.0-beta' }
	) {
		InModuleScope $moduleName -Parameters @{ ExpectedResult = $ExpectedResult; Current = $Current; New = $New } {
			Assert-UpgradeVersionIsValid -VersionInstalled $Current -VersionToBeUsed $New | Should -Be $ExpectedResult
		}
	}
}

Describe 'Invoke-ClusterInstall' -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		$log = [System.Collections.ArrayList]@()
		Mock -ModuleName $moduleName Copy-Item { }
		Mock -ModuleName $moduleName Write-Log { $log.Add($Messages) | Out-Null }
		Mock -ModuleName $moduleName Invoke-Cmd { return 0 }
	}

	It 'calls Write-Log with correct message' {
		InModuleScope -ModuleName $moduleName -Parameters @{log = $log } {
			Invoke-ClusterInstall
			$log.Count | Should -BeGreaterOrEqual 3
			$log[3] | Should -Be 'Install of cluster successfully called'
		}
	}

	It 'calls Copy-Item with correct source and destination' {
		InModuleScope -ModuleName $moduleName {
			Invoke-ClusterInstall
			Assert-MockCalled Copy-Item -ParameterFilter { $Path -eq "$kubePath\k2s.exe" -and $Destination -eq "$kubePath\k2sx.exe" -and $Force -and $PassThru }
		}
	}

	It 'calls Invoke-Cmd with correct command' {
		InModuleScope -ModuleName $moduleName {
			Invoke-ClusterInstall
			Assert-MockCalled Invoke-Cmd -ParameterFilter { $Executable -Match 'k2sx.exe' }
			Should -Invoke -CommandName Invoke-Cmd -Times 1 -Exactly
		}
	}
}

Describe 'Invoke-ClusterUninstall' -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		$log = [System.Collections.ArrayList]@()
		Mock -ModuleName $moduleName Copy-Item { }
		Mock -ModuleName $moduleName Write-Log { $log.Add($Messages) | Out-Null }
		Mock -ModuleName $moduleName Invoke-Cmd { return 0 }
		Mock -ModuleName $moduleName Test-Path { return $true }
	}

	It 'calls Write-Log with correct message' {
		InModuleScope -ModuleName $moduleName -Parameters @{log = $log } {
			Invoke-ClusterUninstall
			$log.Count | Should -BeGreaterOrEqual 3
			$log[2] | Should -Be 'Uninstall of cluster successfully called'
		}
	}   

	It 'calls Invoke-Cmd with correct command' {
		InModuleScope -ModuleName $moduleName {
			Invoke-ClusterUninstall
			Assert-MockCalled Invoke-Cmd -ParameterFilter { $Executable -Match 'k2s.exe' }
			Should -Invoke -CommandName Invoke-Cmd -Times 1 -Exactly
		}
	}
}

Describe 'Remove-SetupConfigIfExisting' -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		Mock -ModuleName $moduleName Write-Log { }
		Mock -ModuleName $moduleName Get-SetupConfigFilePath { return 'my-config' }
		Mock -ModuleName $moduleName Remove-Item { }
	}

	Context 'config not existing' {
		BeforeAll {
			Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -eq 'my-config' }
		}

		It 'does nothing' {
			InModuleScope -ModuleName $moduleName {
				Remove-SetupConfigIfExisting

				Should -Invoke -Scope Context Remove-Item -Times 0
			}
		}
	}

	Context 'config existing' {
		BeforeAll {
			Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'my-config' }
		}

		It 'removes the config' {
			InModuleScope -ModuleName $moduleName {
				Remove-SetupConfigIfExisting

				Should -Invoke -Scope Context Remove-Item -Times 1 -ParameterFilter { $Path -eq 'my-config' }
			}
		}
	}
}

Describe "Restart-ClusterIfBuildVersionMismatch" -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		$log = [System.Collections.ArrayList]@()
		Mock -ModuleName $moduleName RestartCluster  {  }
		Mock -ModuleName $moduleName Write-Log { $log.Add($Messages) | Out-Null }
	}

	It "should restart the cluster if only the build version is different" {
		InModuleScope -ModuleName $moduleName {
			$currentVersion = "1.2.3"
			$nextVersion = "1.2.4"
			$installFolder = "C:\Program Files\K2s"
			$kubePath = "C:\Program Files\K2s\kube"

			$result = Restart-ClusterIfBuildVersionMismatch -currentVersion $currentVersion -nextVersion $nextVersion -installFolder $installFolder -kubePath $kubePath
			# Assert that RestartCluster was called
			Should -Invoke RestartCluster -Exactly 1 -Scope It

			# Assert that the function returns $false
			$result | Should -Be $false
		}
	}

	It "should not restart the cluster if the major version is different" {
		InModuleScope -ModuleName $moduleName {
			$currentVersion = "1.2.3"
			$nextVersion = "2.0.0"
			$installFolder = "C:\Program Files\K2s"
			$kubePath = "C:\Program Files\K2s\kube"

			$result = Restart-ClusterIfBuildVersionMismatch -currentVersion $currentVersion -nextVersion $nextVersion -installFolder $installFolder -kubePath $kubePath

			# Assert that RestartCluster was not called
			Should -Invoke RestartCluster -Exactly 0 -Scope It

			# Assert that the function returns $true
			$result | Should -Be $true
		}
	}

	It "should not restart the cluster if the minor version is increased by more than one" {
		InModuleScope -ModuleName $moduleName {
			$currentVersion = "1.2.3"
			$nextVersion = "1.4.0"
			$installFolder = "C:\Program Files\K2s"
			$kubePath = "C:\Program Files\K2s\kube"

			$result = Restart-ClusterIfBuildVersionMismatch -currentVersion $currentVersion -nextVersion $nextVersion -installFolder $installFolder -kubePath $kubePath

			# Assert that RestartCluster was not called
			Should -Invoke RestartCluster -Exactly 0 -Scope It

			# Assert that the function returns $true
			$result | Should -Be $true
		}
	}

	It "should not restart the cluster if the minor version is the same and the build version is the same" {
		InModuleScope -ModuleName $moduleName {
			$currentVersion = "1.2.3"
			$nextVersion = "1.2.3"
			$installFolder = "C:\Program Files\K2s"
			$kubePath = "C:\Program Files\K2s\kube"

			$result = Restart-ClusterIfBuildVersionMismatch -currentVersion $currentVersion -nextVersion $nextVersion -installFolder $installFolder -kubePath $kubePath

			# Assert that RestartCluster was not called
			Should -Invoke RestartCluster -Exactly 0 -Scope It

			# Assert that the function returns $false
			$result | Should -Be $false
		}
	}
}

Describe "RestartCluster" -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		$log = [System.Collections.ArrayList]@()
		Mock -ModuleName $moduleName Write-Log {
			$log.Add($Messages) | Out-Null }
		Mock -ModuleName $moduleName Invoke-Cmd { return 0 }
		Mock -ModuleName $moduleName Get-SetupInfo { return @{ Name = "k2s" } }
	}

	It "should not restart the cluster if it is not running" {
		InModuleScope -ModuleName $moduleName -Parameters @{log = $log } {
			Mock Get-RunningState { return @{ IsRunning = $false } }
			RestartCluster -CurrentKubePath "C:\Current\KubePath" -NextVersionKubePath "C:\Next\KubePath"
			# Assert that Write-Log was called with the expected message
			Should -Invoke Write-Log -Exactly 1 -Scope It
			$log.Count | Should -BeGreaterOrEqual 1
			$log[0] | Should -Be 'Cluster is not running, no need to restart'
		}
	}

	It "should log a message if the k2s.exe does not exist" {
		InModuleScope -ModuleName $moduleName -Parameters @{log = $log } {
			Mock Get-RunningState { return @{ IsRunning = $true } }
			Mock Test-Path  { return $false }
			RestartCluster -CurrentKubePath "C:\Current\KubePath" -NextVersionKubePath "C:\Next\KubePath"
			# Assert that Write-Log was called with the expected message
			Should -Invoke Write-Log -Exactly 2 -Scope It
			$log.Count | Should -BeGreaterOrEqual 2
			$log[2] | Should -Be "K2s exe: 'C:\Current\KubePath\k2s.exe' does not exist. Skipping stop."
		}
	}

	It "should restart the cluster if it is running and k2s.exe exists" {
		InModuleScope -ModuleName $moduleName -Parameters @{log = $log }  {
			Mock Get-RunningState { return @{ IsRunning = $true } }
			Mock Test-Path  { return $true }
			RestartCluster -CurrentKubePath "C:\Current\KubePath" -NextVersionKubePath "C:\Next\KubePath"
			# Assert that Invoke-Cmd was called with the expected arguments
			Should -Invoke Invoke-Cmd -Exactly 1 -Scope It -ParameterFilter { $Executable -eq "C:\Current\KubePath\k2s.exe" -and $Arguments -eq "stop" }

			# Assert that Write-Log was called with the expected message
			Should -Invoke Write-Log -Exactly 3 -Scope It
			$log.Count | Should -BeGreaterOrEqual 5
			$log[4] | Should -Be "Stop of cluster successfully called"
			$log[5] | Should -Be "Start of cluster successfully called"
		}
	}

	It "should throw an exception if stopping the cluster fails" {
		InModuleScope -ModuleName $moduleName  -Parameters @{log = $log } {
			Mock Get-RunningState { return @{ IsRunning = $true } }
			Mock Test-Path  { return $true }
			Mock Invoke-Cmd { return 1 }
			{ RestartCluster -CurrentKubePath "C:\Current\KubePath" -NextVersionKubePath "C:\Next\KubePath" } | Should -Throw -ExpectedMessage 'Error: Not possible to stop existing cluster!'
		}
	}

	It "should throw an exception if starting the cluster fails" {
		InModuleScope -ModuleName $moduleName  -Parameters @{log = $log } {
			Mock Get-RunningState { return @{ IsRunning = $true } }
			$script:count = 0
			Mock Test-Path  { return $true }
			Mock Invoke-Cmd {
				# This is done to simulate that the first call to Invoke-Cmd is successful and the second fails
				$script:count++
				if ($script:count++ -eq 1) {
					return 0
				} else {
					return 1
				}
			 }
			{ RestartCluster -CurrentKubePath "C:\Current\KubePath" -NextVersionKubePath "C:\Next\KubePath" } | Should -Throw -ExpectedMessage 'Error: Not possible to start cluster!'
		}
	}
}

Describe "PerformClusterUpgrade" -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		function global:Enable-AddonFromConfig {
			param (
				[Parameter(Mandatory = $false)]
				[pscustomobject] $Config,
				[Parameter(Mandatory = $false)]
				[string] $Root
			)
		}

		# Mock the dependencies
		Mock -ModuleName $moduleName Get-LogFilePath -MockWith { return 'TestDrive:\logfile.log' }
		Mock -ModuleName $moduleName Get-Content -MockWith { return "log content" }
		Mock -ModuleName $moduleName Remove-SetupConfigIfExisting
		Mock -ModuleName $moduleName Start-Sleep
		Mock -ModuleName $moduleName Invoke-ClusterInstall
		Mock -ModuleName $moduleName Invoke-UpgradeBackupRestoreHooks
		Mock -ModuleName $moduleName Get-KubeToolsPath -MockWith { return "C:\KubeTools" }
		Mock -ModuleName $moduleName Import-NotNamespacedResources
		Mock -ModuleName $moduleName Import-NamespacedResources
		Mock -ModuleName $moduleName Restore-LogFile
		Mock -ModuleName $moduleName Write-Log
		Mock -ModuleName $moduleName Write-Progress
		Mock -ModuleName $moduleName Get-ProductVersion -MockWith { return "1.0.0" }
		Mock -ModuleName $moduleName Get-KubePath -MockWith { return "C:\KubePath" }
		Mock -ModuleName $moduleName Write-RefreshEnvVariables
		Mock -ModuleName $moduleName Enable-ClusterIsRunning
		Mock -ModuleName $moduleName Wait-ForAPIServerInGivenKubePath
		Mock -ModuleName $moduleName Get-KubeBinPathGivenKubePath -MockWith { return "C:\KubeBinPath" }
		Mock -ModuleName $moduleName Enable-AddonFromConfig
		Mock -ModuleName $moduleName Restore-DeferredClusterIssuers { return @() }
	}

	It "should perform cluster upgrade with execute hooks successfully" {
		InModuleScope $moduleName {
			$memoryVM = @{ Startup = '4GB'; DynamicMemoryEnabled = $false }
			$coresVM = [ref]"2"
			$storageVM = [ref]"100GB"
			$enabledAddonsList = [System.Collections.ArrayList]@([pscustomobject]@{ Name = 'dashboard' })
			$hooksBackupPath = [ref]"C:\Backup\Hooks"
			$logFilePathBeforeUninstall = [ref]"C:\Backup\logfile.log"

			Mock Invoke-ClusterUninstall

			PerformClusterUpgrade -ExecuteHooks -ShowProgress -DeleteFiles -ShowLogs -K2sPathToInstallFrom "C:\K2sPath" -Config "config.yaml" -Proxy "http://proxy" -BackupDir "C:\Backup" -AdditionalHooksDir "C:\Hooks" -memoryVM $memoryVM -coresVM $coresVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall

			# Assert that the mocked functions were called
			Should -Invoke Invoke-ClusterUninstall -Exactly 1 -Scope It
			Should -Invoke Invoke-ClusterInstall -Exactly 1 -Scope It
			Should -Invoke Invoke-UpgradeBackupRestoreHooks -Exactly 1 -Scope It -ParameterFilter { $HookType -eq "Restore" -and $BackupDir -eq $hooksBackupPath.Value }
			Should -Invoke Import-NotNamespacedResources -Exactly 1 -Scope It
			Should -Invoke Import-NamespacedResources -Exactly 1 -Scope It
			Should -Invoke Restore-LogFile -Exactly 1 -Scope It
			Should -Invoke Write-Log -Times 1 -Scope It
			Should -Invoke Write-Progress -Times 1 -Scope It
		}
	}
	
	It "starts the rebuilt cluster before waiting for API readiness" {
		InModuleScope $moduleName {
			$events = [System.Collections.ArrayList]@()
			$memoryVM = @{ Startup = '4GB'; DynamicMemoryEnabled = $false }
			$coresVM = [ref]"2"
			$storageVM = [ref]"100GB"
			$enabledAddonsList = [System.Collections.ArrayList]@()
			$hooksBackupPath = [ref]"C:\Backup\Hooks"
			$logFilePathBeforeUninstall = [ref]"C:\Backup\logfile.log"

			Mock Invoke-ClusterUninstall
			Mock Invoke-ClusterInstall { $events.Add('install') | Out-Null }
			Mock Enable-ClusterIsRunning { $events.Add('start') | Out-Null }
			Mock Wait-ForAPIServerInGivenKubePath { $events.Add('ready') | Out-Null }

			PerformClusterUpgrade -ExecuteHooks -K2sPathToInstallFrom "C:\K2sPath" -Config "C:\Backup\previous.json" -BackupDir "C:\Backup" -memoryVM $memoryVM -coresVM $coresVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall -skipResources

			$events | Should -Be @('install', 'start', 'ready')
		}
	}

	It "should perform cluster upgrade without execute hooks successfully" {
		InModuleScope $moduleName {
			$memoryVM = @{ Startup = '4GB'; DynamicMemoryEnabled = $false }
			$coresVM = [ref]"2"
			$storageVM = [ref]"100GB"
			$enabledAddonsList = [System.Collections.ArrayList]@()
			$hooksBackupPath = [ref]"C:\Backup\Hooks"
			$logFilePathBeforeUninstall = [ref]"C:\Backup\logfile.log"

			Mock Invoke-ClusterUninstall
			PerformClusterUpgrade -ShowProgress -DeleteFiles -ShowLogs -K2sPathToInstallFrom "C:\K2sPath" -Config "config.yaml" -Proxy "http://proxy" -BackupDir "C:\Backup" -AdditionalHooksDir "C:\Hooks" -memoryVM $memoryVM -coresVM $coresVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall

			# Assert that the mocked functions were called
			Should -Invoke  Invoke-ClusterUninstall -Exactly 1 -Scope It
			Should -Invoke Invoke-ClusterInstall -Exactly 1 -Scope It
			Should -Invoke Invoke-UpgradeBackupRestoreHooks -Exactly 0 -Scope It -ParameterFilter { $HookType -eq "Restore" -and $BackupDir -eq $hooksBackupPath.Value }
			Should -Invoke Import-NotNamespacedResources -Exactly 1 -Scope It
			Should -Invoke Import-NamespacedResources -Exactly 1 -Scope It
			Should -Invoke Restore-LogFile -Exactly 1 -Scope It
			Should -Invoke Write-Log -Times 1 -Scope It
			Should -Invoke Write-Progress -Times 1 -Scope It
		}
	}

	It "should throw an error if an exception occurs" {
		InModuleScope $moduleName {
			Mock Invoke-ClusterUninstall -MockWith { throw "Uninstall failed" }
	
			$memoryVM = @{ Startup = '4GB'; DynamicMemoryEnabled = $false }
			$coresVM = [ref]"2"
			$storageVM = [ref]"100GB"
			$enabledAddonsList = [System.Collections.ArrayList]@()
			$hooksBackupPath = [ref]"C:\Backup\Hooks"
			$logFilePathBeforeUninstall = [ref]"C:\Backup\logfile.log"
	
			{ PerformClusterUpgrade -ShowProgress -DeleteFiles -ShowLogs -K2sPathToInstallFrom "C:\K2sPath" -Config "config.yaml" -Proxy "http://proxy" -BackupDir "C:\Backup" -AdditionalHooksDir "C:\Hooks" -memoryVM $memoryVM -coresVM $coresVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall } | Should -Throw "Uninstall failed"
		}
	}

	It 'calls Enable-AddonFromConfig for each addon in enabledAddonsList' {
		InModuleScope $moduleName {
			$memoryVM = @{ Startup = '4GB'; DynamicMemoryEnabled = $false }
			$coresVM = [ref]'2'
			$storageVM = [ref]'100GB'
			$enabledAddonsList = [System.Collections.ArrayList]@(
				[pscustomobject]@{ Name = 'dashboard' },
				[pscustomobject]@{ Name = 'metrics' }
			)
			$hooksBackupPath = [ref]'C:\Backup\Hooks'
			$logFilePathBeforeUninstall = [ref]'C:\Backup\logfile.log'

			Mock Invoke-ClusterUninstall
			Mock Enable-AddonFromConfig

			PerformClusterUpgrade -ShowProgress -DeleteFiles -ShowLogs -K2sPathToInstallFrom 'C:\K2sPath' -Config 'config.yaml' -Proxy 'http://proxy' -BackupDir 'C:\Backup' -AdditionalHooksDir 'C:\Hooks' -memoryVM $memoryVM -coresVM $coresVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall

			Should -Invoke Enable-AddonFromConfig -Times 1 -Scope It -ParameterFilter { $Config.Name -eq 'dashboard' }
			Should -Invoke Enable-AddonFromConfig -Times 1 -Scope It -ParameterFilter { $Config.Name -eq 'metrics' }
			Should -Invoke Enable-AddonFromConfig -Times 2 -Scope It
		}
	}

	It 'calls Enable-AddonFromConfig with Implementation set to first implementation when addon has implementations' {
		InModuleScope $moduleName {
			$memoryVM = @{ Startup = '4GB'; DynamicMemoryEnabled = $false }
			$coresVM = [ref]'2'
			$storageVM = [ref]'100GB'
			$enabledAddonsList = [System.Collections.ArrayList]@(
				[pscustomobject]@{ Name = 'ingress'; Implementations = @('traefik') }
			)
			$hooksBackupPath = [ref]'C:\Backup\Hooks'
			$logFilePathBeforeUninstall = [ref]'C:\Backup\logfile.log'

			Mock Invoke-ClusterUninstall
			Mock Enable-AddonFromConfig

			PerformClusterUpgrade -ShowProgress -DeleteFiles -ShowLogs -K2sPathToInstallFrom 'C:\K2sPath' -Config 'config.yaml' -Proxy 'http://proxy' -BackupDir 'C:\Backup' -AdditionalHooksDir 'C:\Hooks' -memoryVM $memoryVM -coresVM $coresVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall

			Should -Invoke Enable-AddonFromConfig -Times 1 -Scope It -ParameterFilter { $Config.Name -eq 'ingress' -and $Config.Implementation -eq 'traefik' }
		}
	}

	It 'logs warning but does not throw when Enable-AddonFromConfig fails for an addon' {
		InModuleScope $moduleName {
			$memoryVM = @{ Startup = '4GB'; DynamicMemoryEnabled = $false }
			$coresVM = [ref]'2'
			$storageVM = [ref]'100GB'
			$enabledAddonsList = [System.Collections.ArrayList]@(
				[pscustomobject]@{ Name = 'logging' }
			)
			$hooksBackupPath = [ref]'C:\Backup\Hooks'
			$logFilePathBeforeUninstall = [ref]'C:\Backup\logfile.log'

			Mock Invoke-ClusterUninstall
			Mock Enable-AddonFromConfig { throw 'addon enable failed' }

			{ PerformClusterUpgrade -ShowProgress -DeleteFiles -ShowLogs -K2sPathToInstallFrom 'C:\K2sPath' -Config 'config.yaml' -Proxy 'http://proxy' -BackupDir 'C:\Backup' -AdditionalHooksDir 'C:\Hooks' -memoryVM $memoryVM -coresVM $coresVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall } | Should -Not -Throw

			Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter { $Messages -match "Warning.*logging" }
		}
	}

	It 'defers ClusterIssuers during resource import and restores them after addon re-enablement' {
		InModuleScope $moduleName {
			$events = [System.Collections.ArrayList]@()
			$memoryVM = @{ Startup = '4GB'; DynamicMemoryEnabled = $false }
			$enabledAddonsList = [System.Collections.ArrayList]@([pscustomobject]@{ Name = 'ingress'; Implementations = @('traefik') })
			$restoreErrors = [ref]@('stale')

			Mock Invoke-ClusterUninstall
			Mock Import-NotNamespacedResources { $events.Add('import-cluster') | Out-Null }
			Mock Import-NamespacedResources { $events.Add('import-namespaced') | Out-Null }
			Mock Enable-AddonFromConfig { $events.Add('enable-addon') | Out-Null }
			Mock Restore-DeferredClusterIssuers { $events.Add('restore-clusterissuers') | Out-Null; return @() }

			PerformClusterUpgrade -ExecuteHooks -K2sPathToInstallFrom 'C:\K2sPath' -Config 'config.yaml' -BackupDir 'C:\Backup' -memoryVM $memoryVM -coresVM '2' -storageVM '100GB' -enabledAddonsList $enabledAddonsList -hooksBackupPath 'C:\Backup\Hooks' -logFilePathBeforeUninstall 'C:\Backup\logfile.log' -resourceRestoreErrors $restoreErrors

			$events | Should -Be @('import-cluster', 'import-namespaced', 'enable-addon', 'restore-clusterissuers')
			Should -Invoke Import-NotNamespacedResources -Exactly 1 -Scope It -ParameterFilter { $DeferredResourceTypes -contains 'clusterissuers' }
			Should -Invoke Restore-DeferredClusterIssuers -Exactly 1 -Scope It -ParameterFilter { $folderResources -eq 'C:\Backup\NotNamespaced' -and $ExePath -eq 'C:\KubeBinPath' }
			@($restoreErrors.Value).Count | Should -Be 0
			Should -Invoke Write-Log -Times 0 -Scope It -ParameterFilter { $Messages -match 'RESOURCE RESTORE ERRORS' }
		}
	}

	It 'does not restore deferred ClusterIssuers when resource import is skipped' {
		InModuleScope $moduleName {
			$memoryVM = @{ Startup = '4GB'; DynamicMemoryEnabled = $false }
			Mock Invoke-ClusterUninstall
			Mock Restore-DeferredClusterIssuers { return @() }

			PerformClusterUpgrade -ExecuteHooks -K2sPathToInstallFrom 'C:\K2sPath' -Config 'config.yaml' -BackupDir 'C:\Backup' -memoryVM $memoryVM -coresVM '2' -storageVM '100GB' -enabledAddonsList ([System.Collections.ArrayList]@()) -hooksBackupPath 'C:\Backup\Hooks' -logFilePathBeforeUninstall 'C:\Backup\logfile.log' -skipResources

			Should -Invoke Restore-DeferredClusterIssuers -Exactly 0 -Scope It
		}
	}

	It 'surfaces ClusterIssuer restore errors in the summary and to the caller without failing the upgrade' {
		InModuleScope $moduleName {
			$memoryVM = @{ Startup = '4GB'; DynamicMemoryEnabled = $false }
			$restoreErrors = [ref]@()
			Mock Invoke-ClusterUninstall
			Mock Restore-DeferredClusterIssuers { return @('Backed-up ClusterIssuers were not restored: the cert-manager API/webhook did not become ready') }

			{ PerformClusterUpgrade -ExecuteHooks -K2sPathToInstallFrom 'C:\K2sPath' -Config 'config.yaml' -BackupDir 'C:\Backup' -memoryVM $memoryVM -coresVM '2' -storageVM '100GB' -enabledAddonsList ([System.Collections.ArrayList]@()) -hooksBackupPath 'C:\Backup\Hooks' -logFilePathBeforeUninstall 'C:\Backup\logfile.log' -resourceRestoreErrors $restoreErrors } | Should -Not -Throw

			@($restoreErrors.Value).Count | Should -Be 1
			$restoreErrors.Value[0] | Should -Match 'did not become ready'
			Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter { $Messages -match 'RESOURCE RESTORE ERRORS' -and $Console }
			Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter { $Messages -match 'backup directory is kept: C:\\Backup' }
			Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter { $Messages -match 'kubectl create -f .*C:\\Backup\\NotNamespaced\\clusterissuers\.yaml' }
		}
	}

	It 'records an unexpected ClusterIssuer restore exception as restore error instead of failing (and rolling back) the upgrade' {
		InModuleScope $moduleName {
			$memoryVM = @{ Startup = '4GB'; DynamicMemoryEnabled = $false }
			$restoreErrors = [ref]@()
			Mock Invoke-ClusterUninstall
			Mock Restore-DeferredClusterIssuers { throw 'unexpected kubectl failure' }

			{ PerformClusterUpgrade -ExecuteHooks -K2sPathToInstallFrom 'C:\K2sPath' -Config 'config.yaml' -BackupDir 'C:\Backup' -memoryVM $memoryVM -coresVM '2' -storageVM '100GB' -enabledAddonsList ([System.Collections.ArrayList]@()) -hooksBackupPath 'C:\Backup\Hooks' -logFilePathBeforeUninstall 'C:\Backup\logfile.log' -resourceRestoreErrors $restoreErrors } | Should -Not -Throw

			@($restoreErrors.Value).Count | Should -Be 1
			$restoreErrors.Value[0] | Should -Match 'unexpected kubectl failure'
			Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter { $Messages -match 'RESOURCE RESTORE ERRORS' -and $Console }
			Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter { $Messages -match 'Upgraded successfully' }
		}
	}
}

Describe 'Import-NotNamespacedResources deferred resource types' -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		$folder = Join-Path $TestDrive 'NotNamespaced'
		New-Item -ItemType Directory -Path $folder -Force | Out-Null
		Set-Content -Path (Join-Path $folder 'clusterissuers.yaml') -Value 'kind: List'
		# kubectl is intentionally absent: any attempt to apply a file would be logged and recorded as error
		$missingExePath = Join-Path $TestDrive 'no-kubectl'
	}

	It 'reproduces the original behavior: ClusterIssuers are applied during the cluster-scoped import' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder; ExePath = $missingExePath } {
			$logs = [System.Collections.ArrayList]@()
			Mock Write-Log { $logs.Add("$Messages") | Out-Null }

			try { Import-NotNamespacedResources -folderResources $Folder -ExePath $ExePath | Out-Null } catch { }

			$logs | Should -Contain '[Restore] Applying cluster resource: clusterissuers'
		}
	}

	It 'skips deferred ClusterIssuers without invoking kubectl' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder; ExePath = $missingExePath } {
			$logs = [System.Collections.ArrayList]@()
			Mock Write-Log { $logs.Add("$Messages") | Out-Null }

			$result = Import-NotNamespacedResources -folderResources $Folder -ExePath $ExePath -DeferredResourceTypes @('clusterissuers')

			$logs | Should -Not -Contain '[Restore] Applying cluster resource: clusterissuers'
			$logs | Should -Contain '[Restore] Deferring cluster resource: clusterissuers (applied after addon re-enablement)'
			$result.Errors.Count | Should -Be 0
		}
	}
}

Describe 'Restore-DeferredClusterIssuers' -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		$folder = Join-Path $TestDrive 'NotNamespaced'
		New-Item -ItemType Directory -Path $folder -Force | Out-Null
		$issuerFile = Join-Path $folder 'clusterissuers.yaml'
		Set-Content -Path $issuerFile -Value 'kind: List'
		$emptyFolder = Join-Path $TestDrive 'Empty'
		New-Item -ItemType Directory -Path $emptyFolder -Force | Out-Null
	}

	BeforeEach {
		InModuleScope $moduleName {
			$script:restoreEvents = [System.Collections.ArrayList]@()
			Mock Write-Log { }
			Mock Wait-ForCertManagerAvailable { $script:restoreEvents.Add('wait') | Out-Null; return $true }
			Mock Invoke-RestoreKubectl {
				$script:restoreEvents.Add($Arguments[0]) | Out-Null
				if ($Arguments[0] -eq 'get') { return [pscustomobject]@{ Output = 'deployment.apps/cert-manager-webhook'; ExitCode = 0 } }
				return [pscustomobject]@{ Output = 'clusterissuer.cert-manager.io/user-issuer created'; ExitCode = 0 }
			}
		}
	}

	It 'does nothing and does not wait when no ClusterIssuers were backed up' {
		InModuleScope $moduleName -Parameters @{ Folder = $emptyFolder } {
			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 0
			Should -Invoke Wait-ForCertManagerAvailable -Exactly 0 -Scope It
			Should -Invoke Invoke-RestoreKubectl -Exactly 0 -Scope It
		}
	}

	It 'creates ClusterIssuers exactly once after the cert-manager readiness check succeeds' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder; IssuerFile = $issuerFile } {
			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 0
			$script:restoreEvents | Should -Be @('get', 'wait', 'create')
			Should -Invoke Wait-ForCertManagerAvailable -Exactly 1 -Scope It
			Should -Invoke Invoke-RestoreKubectl -Exactly 1 -Scope It -ParameterFilter {
				$ExePath -eq 'C:\bin' -and ($Arguments -join ' ') -eq "create -f $IssuerFile"
			}
		}
	}

	It 'reports an error without waiting or creating when cert-manager is not installed' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl { return [pscustomobject]@{ Output = ''; ExitCode = 0 } } -ParameterFilter { $Arguments[0] -eq 'get' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
			$errors[0] | Should -Match 'cert-manager is not installed'
			Should -Invoke Wait-ForCertManagerAvailable -Exactly 0 -Scope It
			Should -Invoke Invoke-RestoreKubectl -Exactly 0 -Scope It -ParameterFilter { $Arguments[0] -eq 'create' }
		}
	}

	It 'reports a clear error and does not create when the readiness check times out' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Wait-ForCertManagerAvailable { return $false }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
			$errors[0] | Should -Match 'cert-manager API/webhook did not become ready'
			Should -Invoke Invoke-RestoreKubectl -Exactly 0 -Scope It -ParameterFilter { $Arguments[0] -eq 'create' }
		}
	}

	It 'reports an error when the readiness check cannot run' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Wait-ForCertManagerAvailable { throw 'cmctl.exe not found' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
			$errors[0] | Should -Match 'did not become ready'
			Should -Invoke Invoke-RestoreKubectl -Exactly 0 -Scope It -ParameterFilter { $Arguments[0] -eq 'create' }
		}
	}

	It 'reports the create and verification output when creating fails and the issuers are missing' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder; IssuerFile = $issuerFile } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = 'Error from server (InternalError): failed calling webhook "webhook.cert-manager.io": service "cert-manager-webhook" not found'; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'create' }
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = 'Error from server (NotFound): clusterissuers.cert-manager.io "user-issuer" not found'; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'get' -and $Arguments[1] -eq '-f' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
			$errors[0] | Should -Match 'could not be restored or verified'
			$errors[0] | Should -Match 'service "cert-manager-webhook" not found'
			$errors[0] | Should -Match '"user-issuer" not found'
			$errors[0] | Should -Match ([regex]::Escape("kubectl create -f `"$IssuerFile`""))
			Should -Invoke Invoke-RestoreKubectl -Exactly 1 -Scope It -ParameterFilter { ($Arguments -join ' ') -eq "get -f $IssuerFile -o name" }
		}
	}

	It 'trusts a zero create exit code and does not run the verification' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 0
			Should -Invoke Invoke-RestoreKubectl -Exactly 0 -Scope It -ParameterFilter { $Arguments[0] -eq 'get' -and $Arguments[1] -eq '-f' }
		}
	}

	It 'restores multiple backed-up ClusterIssuers with a single create' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = "clusterissuer.cert-manager.io/issuer-a created`nclusterissuer.cert-manager.io/issuer-b created`nclusterissuer.cert-manager.io/issuer-c created"; ExitCode = 0 }
			} -ParameterFilter { $Arguments[0] -eq 'create' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 0
			Should -Invoke Invoke-RestoreKubectl -Exactly 1 -Scope It -ParameterFilter { $Arguments[0] -eq 'create' }
		}
	}

	It 'keeps ClusterIssuers created by the re-enabled addons and succeeds once all backed-up issuers are verified' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = "clusterissuer.cert-manager.io/user-issuer created`nError from server (AlreadyExists): error when creating `"clusterissuers.yaml`": clusterissuers.cert-manager.io `"k2s-ca-issuer`" already exists"; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'create' }
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = "clusterissuer.cert-manager.io/k2s-ca-issuer`nclusterissuer.cert-manager.io/user-issuer"; ExitCode = 0 }
			} -ParameterFilter { $Arguments[0] -eq 'get' -and $Arguments[1] -eq '-f' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 0
			Should -Invoke Invoke-RestoreKubectl -Exactly 1 -Scope It -ParameterFilter { $Arguments[0] -eq 'get' -and $Arguments[1] -eq '-f' }
			Should -Invoke Invoke-RestoreKubectl -Exactly 0 -Scope It -ParameterFilter { $Arguments[0] -in @('apply', 'replace', 'delete', 'patch') }
		}
	}

	It 'is idempotent when all backed-up ClusterIssuers already exist and are verified' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = "Error from server (AlreadyExists): error when creating `"clusterissuers.yaml`": clusterissuers.cert-manager.io `"k2s-ca-issuer`" already exists`nError from server (AlreadyExists): error when creating `"clusterissuers.yaml`": clusterissuers.cert-manager.io `"user-issuer`" already exists"; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'create' }
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = "clusterissuer.cert-manager.io/k2s-ca-issuer`nclusterissuer.cert-manager.io/user-issuer"; ExitCode = 0 }
			} -ParameterFilter { $Arguments[0] -eq 'get' -and $Arguments[1] -eq '-f' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 0
		}
	}

	It 'reports a failure when one issuer fails validation even though others already exist' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = "Error from server (AlreadyExists): error when creating `"clusterissuers.yaml`": clusterissuers.cert-manager.io `"k2s-ca-issuer`" already exists`nThe ClusterIssuer `"bad-issuer`" is invalid: spec: Required value"; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'create' }
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = "clusterissuer.cert-manager.io/k2s-ca-issuer`nError from server (NotFound): clusterissuers.cert-manager.io `"bad-issuer`" not found"; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'get' -and $Arguments[1] -eq '-f' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
			$errors[0] | Should -Match '"bad-issuer" is invalid'
			$errors[0] | Should -Match '"bad-issuer" not found'
		}
	}

	It 'reports a failure when one issuer is rejected by the webhook even though others already exist' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = "Error from server (AlreadyExists): error when creating `"clusterissuers.yaml`": clusterissuers.cert-manager.io `"k2s-ca-issuer`" already exists`nError from server (InternalError): error when creating `"clusterissuers.yaml`": failed calling webhook `"webhook.cert-manager.io`""; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'create' }
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = 'Error from server (NotFound): clusterissuers.cert-manager.io "user-issuer" not found'; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'get' -and $Arguments[1] -eq '-f' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
			$errors[0] | Should -Match 'failed calling webhook'
		}
	}

	It 'reports a failure when the verification itself fails' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = "Error from server (AlreadyExists): error when creating `"clusterissuers.yaml`": clusterissuers.cert-manager.io `"k2s-ca-issuer`" already exists"; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'create' }
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = 'The connection to the server 172.19.1.100:6443 was refused'; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'get' -and $Arguments[1] -eq '-f' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
			$errors[0] | Should -Match 'could not be restored or verified'
			$errors[0] | Should -Match 'connection to the server .* was refused'
		}
	}

	It 'reports a failure when kubectl cannot read the backup file' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = 'error: the path "clusterissuers.yaml" cannot be parsed'; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'create' -or ($Arguments[0] -eq 'get' -and $Arguments[1] -eq '-f') }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
			$errors[0] | Should -Match 'cannot be parsed'
		}
	}

	It 'reports a failure on a non-zero exit code without output when verification fails' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl { return [pscustomobject]@{ Output = ''; ExitCode = 1 } } -ParameterFilter { $Arguments[0] -eq 'create' -or ($Arguments[0] -eq 'get' -and $Arguments[1] -eq '-f') }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
		}
	}

	It 'reports a failure when some issuers exist and another one is still missing after the create' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = "Error from server (AlreadyExists): error when creating `"clusterissuers.yaml`": clusterissuers.cert-manager.io `"k2s-ca-issuer`" already exists`nError from server (Forbidden): error when creating `"clusterissuers.yaml`": clusterissuers.cert-manager.io `"user-issuer`" is forbidden"; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'create' }
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = "clusterissuer.cert-manager.io/k2s-ca-issuer`nError from server (NotFound): clusterissuers.cert-manager.io `"user-issuer`" not found"; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'get' -and $Arguments[1] -eq '-f' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
			$errors[0] | Should -Match '"user-issuer" not found'
			$errors[0] | Should -Match 'kubectl create -f'
		}
	}
}

Describe 'Invoke-RestoreKubectl' -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		# a real native executable is needed to reproduce the stderr handling of Windows PowerShell 5.1
		$fakeBin = Join-Path $TestDrive 'bin'
		New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
		Add-Type -OutputType ConsoleApplication -OutputAssembly (Join-Path $fakeBin 'kubectl.exe') -TypeDefinition @'
using System;
public static class FakeKubectl {
	public static int Main(string[] args) {
		string stdout = Environment.GetEnvironmentVariable("FAKE_KUBECTL_STDOUT");
		string stderr = Environment.GetEnvironmentVariable("FAKE_KUBECTL_STDERR");
		string exitCode = Environment.GetEnvironmentVariable("FAKE_KUBECTL_EXIT");
		if (!String.IsNullOrEmpty(stdout)) { Console.Out.WriteLine(stdout); }
		if (!String.IsNullOrEmpty(stderr)) { Console.Error.WriteLine(stderr); }
		return String.IsNullOrEmpty(exitCode) ? 0 : Int32.Parse(exitCode);
	}
}
'@
	}

	AfterEach {
		$env:FAKE_KUBECTL_STDOUT = $null
		$env:FAKE_KUBECTL_STDERR = $null
		$env:FAKE_KUBECTL_EXIT = $null
	}

	It 'captures native stderr as plain text with the exit code even when the caller uses ErrorActionPreference Stop' {
		$env:FAKE_KUBECTL_STDOUT = 'clusterissuer.cert-manager.io/user-issuer created'
		$env:FAKE_KUBECTL_STDERR = 'Error from server (AlreadyExists): clusterissuers.cert-manager.io "k2s-ca-issuer" already exists'
		$env:FAKE_KUBECTL_EXIT = '1'
		InModuleScope $moduleName -Parameters @{ Bin = $fakeBin } {
			$ErrorActionPreference = 'Stop'

			$result = Invoke-RestoreKubectl -ExePath $Bin -Arguments @('create', '-f', 'clusterissuers.yaml')

			$result.ExitCode | Should -Be 1
			$result.Output | Should -Match 'user-issuer created'
			$result.Output | Should -Match '(?m)^Error from server \(AlreadyExists\): .*"k2s-ca-issuer" already exists$'
			$result.Output | Should -Not -Match 'NativeCommandError'
			$ErrorActionPreference | Should -Be 'Stop'
		}
	}

	It 'returns a zero exit code and stdout on success' {
		$env:FAKE_KUBECTL_STDOUT = 'deployment.apps/cert-manager-webhook'
		InModuleScope $moduleName -Parameters @{ Bin = $fakeBin } {
			$result = Invoke-RestoreKubectl -ExePath $Bin -Arguments @('get', 'deployment')

			$result.ExitCode | Should -Be 0
			$result.Output | Should -Be 'deployment.apps/cert-manager-webhook'
		}
	}

	It 'restores the ErrorActionPreference and does not swallow the exception when kubectl cannot be invoked' {
		InModuleScope $moduleName -Parameters @{ Missing = (Join-Path $TestDrive 'missing') } {
			$ErrorActionPreference = 'Stop'

			{ Invoke-RestoreKubectl -ExePath $Missing -Arguments @('get', 'clusterissuers') } | Should -Throw

			$ErrorActionPreference | Should -Be 'Stop'
		}
	}
}

Describe 'Enable-ClusterIsRunning' -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		$log = [System.Collections.ArrayList]@()
		Mock -ModuleName $moduleName Write-Log { $log.Add($Messages) | Out-Null }
		Mock -ModuleName $moduleName Get-ClusterInstalledFolder { return 'C:\temp\k2s' }
		Mock -ModuleName $moduleName Test-Path { return $true }
		Mock -ModuleName $moduleName Invoke-Cmd { return 0 }
	}

	It 'does nothing when cluster is already running' {
		InModuleScope -ModuleName $moduleName {
			Mock Get-SetupInfo { return @{ Name = 'k2s' } }
			Mock Get-RunningState { return @{ IsRunning = $true } }
			Enable-ClusterIsRunning
			Should -Invoke -CommandName Get-ClusterInstalledFolder -Times 0 -Exactly
			Should -Invoke -CommandName Invoke-Cmd -Times 0 -Exactly
		}
	}

	It 'throws when installed k2s.exe is not found' {
		Mock -ModuleName $moduleName Test-Path { return $false }

		InModuleScope -ModuleName $moduleName {
			Mock Get-SetupInfo { return @{ Name = 'k2s' } }
			Mock Get-RunningState { return @{ IsRunning = $false } }
			{ Enable-ClusterIsRunning } | Should -Throw '*Installed k2s.exe not found*'
		}
	}

	It 'starts cluster using installed k2s.exe when cluster is stopped' {
		InModuleScope -ModuleName $moduleName {
			Mock Get-SetupInfo { return @{ Name = 'k2s' } }
			Mock Get-RunningState { return @{ IsRunning = $false } }
			Enable-ClusterIsRunning
			Assert-MockCalled Invoke-Cmd -ParameterFilter {
				$Executable -eq 'C:\temp\k2s\k2s.exe' -and $Arguments -eq 'start'
			}
			Should -Invoke -CommandName Invoke-Cmd -Times 1 -Exactly
		}
	}

	It 'throws when start of cluster fails' {
		Mock -ModuleName $moduleName Invoke-Cmd { return 1 }

		InModuleScope -ModuleName $moduleName {
			Mock Get-SetupInfo { return @{ Name = 'k2s' } }
			Mock Get-RunningState { return @{ IsRunning = $false } }
			{ Enable-ClusterIsRunning } | Should -Throw '*Not possible to start existing cluster*'
		}
	}

	It 'passes -o flag to start command when ShowLogs is set' {
		InModuleScope -ModuleName $moduleName {
			Mock Get-SetupInfo { return @{ Name = 'k2s' } }
			Mock Get-RunningState { return @{ IsRunning = $false } }
			Enable-ClusterIsRunning -ShowLogs
			Assert-MockCalled Invoke-Cmd -ParameterFilter {
				$Executable -eq 'C:\temp\k2s\k2s.exe' -and $Arguments -eq 'start -o'
			}
			Should -Invoke -CommandName Invoke-Cmd -Times 1 -Exactly
		}
	}
}

Describe "PrepareClusterUpgrade" -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		function global:Get-EnabledAddons {
			return [System.Collections.ArrayList]@()
		}

		# Mock the dependencies
		Mock -ModuleName $moduleName Get-SetupInfo -MockWith { return @{ Name = "k2s" } }
		Mock -ModuleName $moduleName Get-LinuxVMCores -MockWith { return 4 }
		Mock -ModuleName $moduleName Get-LinuxVMMemory -MockWith { return @{ Startup = '4GB'; DynamicMemoryEnabled = $false } }
		Mock -ModuleName $moduleName Get-LinuxVMStorageSize -MockWith { return 100 }
		Mock -ModuleName $moduleName Assert-UpgradeOperation -MockWith { return $true }
		Mock -ModuleName $moduleName Enable-ClusterIsRunning
		Mock -ModuleName $moduleName Get-EnabledAddons -MockWith { return [System.Collections.ArrayList]@() }
		Mock -ModuleName $moduleName Assert-YamlTools
		Mock -ModuleName $moduleName Get-ClusterInstalledFolder -MockWith { return "C:\Cluster" }
		Mock -ModuleName $moduleName Test-Path -MockWith { return $true }
		Mock -ModuleName $moduleName Export-ClusterResources
		Mock -ModuleName $moduleName Invoke-UpgradeBackupRestoreHooks
		Mock -ModuleName $moduleName Backup-LogFile
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes -MockWith { return (New-PVBackupReport) }
		Mock -ModuleName $moduleName Write-Log
		Mock -ModuleName $moduleName Write-Progress
	}

	It "should prepare cluster upgrade successfully" {
		InModuleScope $moduleName {
			$coresVM = [ref]0
			$memoryVM = [ref]0
			$storageVM = [ref]0
			$enabledAddonsList = [ref]$null
			$hooksBackupPath = [ref]""
			$logFilePathBeforeUninstall = [ref]""
			$imagesBackupPath = [ref]""
			$pvBackupPath = [ref]""

			$result = PrepareClusterUpgrade -ShowProgress -SkipResources -SkipImages -ShowLogs -Proxy "http://proxy" -BackupDir "C:\Backup" -AdditionalHooksDir "C:\Hooks" -coresVM $coresVM -memoryVM $memoryVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall -imagesBackupPath $imagesBackupPath -pvBackupPath $pvBackupPath

			# Assert that the mocked functions were called
			Should -Invoke Get-SetupInfo -Exactly 1 -Scope It
			Should -Invoke Assert-UpgradeOperation -Exactly 1 -Scope It
			Should -Invoke Enable-ClusterIsRunning -Exactly 1 -Scope It
			Should -Invoke Get-EnabledAddons -Exactly 1 -Scope It
			Should -Invoke Get-LinuxVMCores -Exactly 1 -Scope It
			Should -Invoke Get-LinuxVMMemory -Exactly 1 -Scope It
			Should -Invoke Get-LinuxVMStorageSize -Exactly 1 -Scope It
			Should -Invoke Assert-YamlTools -Exactly 1 -Scope It
			Should -Invoke Get-ClusterInstalledFolder -Exactly 1 -Scope It
			Should -Invoke Test-Path -Exactly 1 -Scope It
			Should -Invoke Export-ClusterResources -Exactly 1 -Scope It
			Should -Invoke Invoke-UpgradeBackupRestoreHooks -Exactly 1 -Scope It
			Should -Invoke Backup-LogFile -Exactly 1 -Scope It
			Should -Invoke Write-Log -Times 1 -Scope It
			Should -Invoke Write-Progress -Times 1 -Scope It

			# Assert the return value
			$result | Should -Be $true
		}
	}

	It "should return false if no previous version of K2s is installed" {
		InModuleScope $moduleName {
			Mock Get-SetupInfo -MockWith { return @{ Name = $null } }

			$coresVM = [ref]0
			$memoryVM = [ref]0
			$storageVM = [ref]0
			$enabledAddonsList = [ref]$null
			$hooksBackupPath = [ref]""
			$logFilePathBeforeUninstall = [ref]""
			$imagesBackupPath = [ref]""
			$pvBackupPath = [ref]""

			$result = PrepareClusterUpgrade -ShowProgress -SkipResources -SkipImages -ShowLogs -Proxy "http://proxy" -BackupDir "C:\Backup" -AdditionalHooksDir "C:\Hooks" -coresVM $coresVM -memoryVM $memoryVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall -imagesBackupPath $imagesBackupPath -pvBackupPath $pvBackupPath

			# Assert that the mocked functions were called
			Should -Invoke Get-SetupInfo -Exactly 1 -Scope It
			Should -Invoke Write-Log -Times 1 -Scope It
			Should -Invoke Write-Progress -Times 1 -Scope It

			# Assert the return value
			$result | Should -Be $false
		}
	}

	It "should throw an error if the setup name is not 'k2s'" {
		InModuleScope $moduleName {
			Mock Get-SetupInfo -MockWith { return @{ Name = "other" } }

			$coresVM = [ref]0
			$memoryVM = [ref]0
			$storageVM = [ref]0
			$enabledAddonsList = [ref]$null
			$hooksBackupPath = [ref]""
			$logFilePathBeforeUninstall = [ref]""
			$imagesBackupPath = [ref]""
			$pvBackupPath = [ref]""

			{ PrepareClusterUpgrade -ShowProgress -SkipResources -SkipImages -ShowLogs -Proxy "http://proxy" -BackupDir "C:\Backup" -AdditionalHooksDir "C:\Hooks" -coresVM $coresVM -memoryVM $memoryVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall -imagesBackupPath $imagesBackupPath -pvBackupPath $pvBackupPath } | Should -Throw "Upgrade is only available for 'k2s' setup"
		}
	}

	It "should handle errors and log them" {
		InModuleScope $moduleName {
			Mock Get-SetupInfo -MockWith { throw "Unexpected error" }

			$coresVM = [ref]0
			$memoryVM = [ref]0
			$storageVM = [ref]0
			$enabledAddonsList = [ref]$null
			$hooksBackupPath = [ref]""
			$logFilePathBeforeUninstall = [ref]""
			$imagesBackupPath = [ref]""
			$pvBackupPath = [ref]""

			{ PrepareClusterUpgrade -ShowProgress -SkipResources -SkipImages -ShowLogs -Proxy "http://proxy" -BackupDir "C:\Backup" -AdditionalHooksDir "C:\Hooks" -coresVM $coresVM -memoryVM $memoryVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall -imagesBackupPath $imagesBackupPath -pvBackupPath $pvBackupPath } | Should -Throw "Unexpected error"

			# Assert that the mocked functions were called
			Should -Invoke Write-Log -Times 1 -Scope It
		}
	}
}

Describe 'Get-PVOperationSummary' -Tag 'unit', 'ci', 'upgrade' {
	It 'classifies boolean PV results' {
		InModuleScope $moduleName {
			$summary = Get-PVOperationSummary -Result @{ 'pv-b' = $true; 'pv-a' = $true; 'pv-c' = $false }

			$summary.IsValid | Should -BeTrue
			$summary.Succeeded | Should -Be @('pv-a', 'pv-b')
			$summary.Failed | Should -Be @('pv-c')
		}
	}

	It 'treats an empty hashtable as a valid result without PVs' {
		InModuleScope $moduleName {
			$summary = Get-PVOperationSummary -Result @{}

			$summary.IsValid | Should -BeTrue
			$summary.Succeeded.Count | Should -Be 0
			$summary.Failed.Count | Should -Be 0
		}
	}

	It 'treats non-boolean PV results as failed' {
		InModuleScope $moduleName {
			$summary = Get-PVOperationSummary -Result @{ 'pv-null' = $null; 'pv-string' = 'True'; 'pv-array' = @($true, $true); 'pv-ok' = $true }

			$summary.IsValid | Should -BeTrue
			$summary.Succeeded | Should -Be @('pv-ok')
			$summary.Failed | Should -Be @('pv-array', 'pv-null', 'pv-string')
		}
	}

	It 'reports <Name> as invalid result' -TestCases @(
		@{ Name = 'null'; Value = $null },
		@{ Name = 'boolean true'; Value = $true },
		@{ Name = 'string'; Value = 'pv-a' },
		@{ Name = 'array'; Value = @('pv-a', 'pv-b') }
	) {
		param($Value)
		InModuleScope $moduleName -Parameters @{ Value = $Value } {
			param($Value)
			$summary = Get-PVOperationSummary -Result $Value

			$summary.IsValid | Should -BeFalse
		}
	}
}

Describe 'PrepareClusterUpgrade PV backup validation' -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		if (-not (Get-Command Get-EnabledAddons -ErrorAction SilentlyContinue)) {
			function global:Get-EnabledAddons { return [System.Collections.ArrayList]@() }
		}

		Mock -ModuleName $moduleName Get-SetupInfo -MockWith { return @{ Name = 'k2s' } }
		Mock -ModuleName $moduleName Get-LinuxVMCores -MockWith { return 4 }
		Mock -ModuleName $moduleName Get-LinuxVMMemory -MockWith { return @{ Startup = '4GB'; DynamicMemoryEnabled = $false } }
		Mock -ModuleName $moduleName Get-LinuxVMStorageSize -MockWith { return 100 }
		Mock -ModuleName $moduleName Assert-UpgradeOperation -MockWith { return $true }
		Mock -ModuleName $moduleName Enable-ClusterIsRunning
		Mock -ModuleName $moduleName Get-EnabledAddons -MockWith { return [System.Collections.ArrayList]@() }
		Mock -ModuleName $moduleName Assert-YamlTools
		Mock -ModuleName $moduleName Get-ClusterInstalledFolder -MockWith { return 'C:\Cluster' }
		Mock -ModuleName $moduleName Export-ClusterResources
		Mock -ModuleName $moduleName Invoke-UpgradeBackupRestoreHooks
		Mock -ModuleName $moduleName Backup-LogFile
		Mock -ModuleName $moduleName Write-Log
		Mock -ModuleName $moduleName Write-Progress

		function Invoke-PrepareClusterUpgradeForPVTest {
			param(
				[string] $BackupDir,
				[ref] $PVBackupPath
			)
			PrepareClusterUpgrade -SkipResources -SkipImages -BackupDir $BackupDir -coresVM ([ref]0) -memoryVM ([ref]0) -storageVM ([ref]0) -enabledAddonsList ([ref]$null) -hooksBackupPath ([ref]'') -logFilePathBeforeUninstall ([ref]'') -imagesBackupPath ([ref]'') -pvBackupPath $PVBackupPath
		}
	}

	BeforeEach {
		$backupDir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
		New-Item -Path $backupDir -ItemType Directory | Out-Null
		$pvBackupPath = [ref]''
	}

	It 'continues when PV discovery succeeds and the cluster has no PVs' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport) }

		$result = Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath

		$result | Should -BeTrue
		$pvBackupPath.Value | Should -BeNullOrEmpty
		Should -Invoke -ModuleName $moduleName Backup-LogFile -Exactly 1 -Scope It
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'No persistent volumes found to backup' }
	}

	It 'continues without a PV backup when every discovered PV is excluded' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Excluded @('pv-addon-a', 'pv-addon-b')) }

		$result = Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath

		$result | Should -BeTrue
		$pvBackupPath.Value | Should -BeNullOrEmpty
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'all 2 discovered PV\(s\) are excluded' }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'intentionally excluded from backup: pv-addon-a, pv-addon-b' }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'No persistent volumes found to backup' }
	}

	It 'continues when every discovered PV is either excluded or backed up' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Results @{ 'pv-a' = $true } -Excluded @('pv-addon')) }

		$result = Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath

		$result | Should -BeTrue
		$pvBackupPath.Value | Should -Be (Join-Path $backupDir 'pv')
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'PV backup completed: 1 PV\(s\) backed up successfully' }
	}

	It 'continues when every discovered PV was backed up' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Results @{ 'pv-a' = $true; 'pv-b' = $true }) }

		$result = Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath

		$result | Should -BeTrue
		$pvBackupPath.Value | Should -Be (Join-Path $backupDir 'pv')
		Should -Invoke -ModuleName $moduleName Backup-AllPersistentVolumes -Exactly 1 -Scope It -ParameterFilter { $ExportPath -eq (Join-Path $backupDir 'pv') }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'PV backup completed: 2 PV\(s\) backed up successfully' }
		Should -Invoke -ModuleName $moduleName Backup-LogFile -Exactly 1 -Scope It
	}

	It 'aborts and logs PV names and types when a discovered PV has an unsupported volume type' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Unsupported @{ 'pv-nfs' = 'nfs' }) }

		{ Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath } | Should -Throw "*1 of 1 discovered persistent volume(s) are neither excluded nor backed up*Unsupported volume type for 1 persistent volume(s): pv-nfs (nfs)*Upgrade aborted before uninstalling the current cluster*"

		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "\[PVBackup\] ERROR: Persistent volume 'pv-nfs' \(type 'nfs'\) is not backed up: unsupported volume type" }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'No persistent volumes found' }
		Should -Invoke -ModuleName $moduleName Backup-LogFile -Exactly 0 -Scope It
	}

	It 'aborts when an unsupported PV exists next to successfully backed-up and excluded PVs' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes {
			return (New-PVBackupReport -Results @{ 'pv-a' = $true } -Excluded @('pv-addon') -Unsupported @{ 'pv-smb' = 'csi (smb.csi.k8s.io)'; 'pv-nfs' = 'nfs' })
		}

		{ Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath } | Should -Throw "*2 of 4 discovered persistent volume(s) are neither excluded nor backed up*Unsupported volume type for 2 persistent volume(s): pv-nfs (nfs), pv-smb (csi (smb.csi.k8s.io))*"

		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "Persistent volume 'pv-smb' \(type 'csi \(smb\.csi\.k8s\.io\)'\) is not backed up" }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'PV backup completed' }
	}

	It 'aborts when a discovered PV is neither excluded nor reported as backed up' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Results @{ 'pv-a' = $true } -NotReported @('pv-b') -Types @{ 'pv-b' = 'hostPath' }) }

		{ Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath } | Should -Throw '*1 of 2 discovered persistent volume(s) are neither excluded nor backed up*No backup result for 1 persistent volume(s): pv-b (hostPath)*'

		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "Persistent volume 'pv-b' \(type 'hostPath'\) was neither excluded nor backed up" }
	}

	It 'aborts when PV discovery fails' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { throw 'Failed to query PersistentVolumes: The connection to the server was refused' }

		{ Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath } | Should -Throw '*PV backup failed*connection to the server was refused*Upgrade aborted before uninstalling the current cluster*'

		Should -Invoke -ModuleName $moduleName Backup-LogFile -Exactly 0 -Scope It
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'Continuing with upgrade' }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'No persistent volumes found' }
	}

	It 'aborts when Backup-AllPersistentVolumes throws an exception' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { throw 'unexpected backup error' }

		{ Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath } | Should -Throw "*PV backup failed: unexpected backup error*backup data is kept in '$backupDir'*"

		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match '\[PVBackup\] ERROR: PV backup failed: unexpected backup error' }
	}

	It 'aborts when the backup of a single PV fails' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Results @{ 'pv-a' = $false }) }

		{ Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath } | Should -Throw '*PV backup failed for 1 of 1 persistent volume(s): pv-a (local).*'

		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "Backup of persistent volume 'pv-a' \(type 'local'\) failed" }
		Should -Invoke -ModuleName $moduleName Backup-LogFile -Exactly 0 -Scope It
	}

	It 'aborts when one of multiple PV backups fails' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Results @{ 'pv-a' = $true; 'pv-b' = $false; 'pv-c' = $true } -Types @{ 'pv-b' = 'hostPath' }) }

		{ Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath } | Should -Throw '*PV backup failed for 1 of 3 persistent volume(s): pv-b (hostPath).*'

		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "Backup of persistent volume 'pv-b' \(type 'hostPath'\) failed" }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'PV backup completed' }
	}

	It 'aborts and reports every PV when several PV backups fail' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Results @{ 'pv-a' = $false; 'pv-b' = $true; 'pv-c' = $false }) }

		{ Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath } | Should -Throw '*PV backup failed for 2 of 3 persistent volume(s): pv-a (local), pv-c (local).*'

		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "Backup of persistent volume 'pv-a' \(type 'local'\) failed" }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "Backup of persistent volume 'pv-c' \(type 'local'\) failed" }
	}

	It 'aborts and reports unsupported and failed PVs together' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Results @{ 'pv-a' = $true; 'pv-b' = $false } -Unsupported @{ 'pv-nfs' = 'nfs' }) }

		{ Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath } | Should -Throw '*2 of 3 discovered persistent volume(s) are neither excluded nor backed up. Unsupported volume type for 1 persistent volume(s): pv-nfs (nfs). PV backup failed for 1 of 2 persistent volume(s): pv-b (local).*'

		Should -Invoke -ModuleName $moduleName Backup-LogFile -Exactly 0 -Scope It
	}

	It 'aborts when a PV backup result is not a boolean' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Results @{ 'pv-a' = $true; 'pv-b' = $null }) }

		{ Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath } | Should -Throw '*PV backup failed for 1 of 2 persistent volume(s): pv-b (local).*'
	}

	It 'aborts instead of assuming success or no PVs when the backup returns <Name>' -TestCases @(
		@{ Name = 'null'; Value = $null },
		@{ Name = 'boolean true'; Value = $true },
		@{ Name = 'a string'; Value = 'done' },
		@{ Name = 'a plain result hashtable'; Value = @{ 'pv-a' = $true } },
		@{ Name = 'an empty hashtable'; Value = @{} }
	) {
		param($Value)
		$script:pvBackupMockResult = $Value
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return $script:pvBackupMockResult }

		{ Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath } | Should -Throw '*PV backup returned an unexpected result*Upgrade aborted before uninstalling*'

		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'No persistent volumes found' }
		Should -Invoke -ModuleName $moduleName Backup-LogFile -Exactly 0 -Scope It
	}

	It 'keeps partially created PV backup data after a backup failure' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes {
			New-Item -Path $ExportPath -ItemType Directory -Force | Out-Null
			Set-Content -Path (Join-Path $ExportPath 'pv-a-backup.tar.gz') -Value 'pv-a data'
			Set-Content -Path (Join-Path $ExportPath 'pv-a-backup-metadata.json') -Value '{ "pvName": "pv-a" }'
			return (New-PVBackupReport -Results @{ 'pv-a' = $true; 'pv-b' = $false })
		}

		{ Invoke-PrepareClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvBackupPath } | Should -Throw '*pv-b*'

		Join-Path $backupDir 'pv\pv-a-backup.tar.gz' | Should -Exist
		Join-Path $backupDir 'pv\pv-a-backup-metadata.json' | Should -Exist
		$pvBackupPath.Value | Should -Be (Join-Path $backupDir 'pv')
	}
}

Describe 'Invoke-PVBackup' -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		Mock -ModuleName $moduleName Write-Log
		$script:originalRootConfig = InModuleScope $moduleName { $script:rootConfig }
	}

	AfterAll {
		InModuleScope $moduleName -Parameters @{ Original = $script:originalRootConfig } { $script:rootConfig = $Original }
	}

	BeforeEach {
		InModuleScope $moduleName { $script:rootConfig = [pscustomobject]@{ backup = [pscustomobject]@{ excludedAddonPersistentVolumes = '' } } }
		$backupDir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
	}

	It 'succeeds when every supported PV was backed up' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Results @{ 'pv-a' = $true; 'pv-b' = $true } -Types @{ 'pv-b' = 'hostPath' }) }

		$result = Invoke-PVBackup -BackupDirectory $backupDir

		$result.Success | Should -BeTrue
		$result.BackedUpCount | Should -Be 2
		@($result.Details.Keys | Sort-Object) | Should -Be @('pv-a', 'pv-b')
		$result.ContainsKey('Message') | Should -BeFalse
		Should -Invoke -ModuleName $moduleName Backup-AllPersistentVolumes -Exactly 1 -Scope It -ParameterFilter { $ExportPath -eq $backupDir }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'PV backup completed: 2 PV\(s\) backed up successfully' }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'ERROR' }
	}

	It 'fails when an unsupported PV exists next to successfully backed-up PVs' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Results @{ 'pv-a' = $true } -Unsupported @{ 'pv-nfs' = 'nfs' }) }

		$result = Invoke-PVBackup -BackupDirectory $backupDir

		$result.Success | Should -BeFalse
		$result.BackedUpCount | Should -Be 1
		$result.Details['pv-a'] | Should -BeTrue
		$result.Message | Should -BeLike '1 of 2 discovered persistent volume(s) are neither excluded nor backed up. Unsupported volume type for 1 persistent volume(s): pv-nfs (nfs)'
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "\[PVBackup\] ERROR: Persistent volume 'pv-nfs' \(type 'nfs'\) is not backed up: unsupported volume type" }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'PV backup completed|No persistent volumes' }
	}

	It 'fails when only unsupported PVs are discovered' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Unsupported @{ 'pv-smb' = 'csi (smb.csi.k8s.io)' }) }

		$result = Invoke-PVBackup -BackupDirectory $backupDir

		$result.Success | Should -BeFalse
		$result.BackedUpCount | Should -Be 0
		$result.Message | Should -BeLike '*pv-smb (csi (smb.csi.k8s.io))*'
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'No persistent volumes found' }
	}

	It 'fails and reports the PV when its backup failed' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Results @{ 'pv-a' = $true; 'pv-b' = $false; 'pv-c' = $true } -Types @{ 'pv-b' = 'hostPath' }) }

		$result = Invoke-PVBackup -BackupDirectory $backupDir

		$result.Success | Should -BeFalse
		$result.BackedUpCount | Should -Be 2
		$result.Details['pv-b'] | Should -BeFalse
		$result.Message | Should -BeLike '1 of 3 discovered persistent volume(s) are neither excluded nor backed up. PV backup failed for 1 of 3 persistent volume(s): pv-b (hostPath)'
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "\[PVBackup\] ERROR: Backup of persistent volume 'pv-b' \(type 'hostPath'\) failed" }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'PV backup completed' }
	}

	It 'fails when a PV backup result is not a boolean' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Results @{ 'pv-a' = $true; 'pv-b' = 'done' }) }

		$result = Invoke-PVBackup -BackupDirectory $backupDir

		$result.Success | Should -BeFalse
		$result.BackedUpCount | Should -Be 1
		$result.Message | Should -BeLike '*PV backup failed for 1 of 2 persistent volume(s): pv-b (local)*'
	}

	It 'rethrows when Backup-AllPersistentVolumes throws' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { throw 'Failed to query PersistentVolumes: connection refused' }

		{ Invoke-PVBackup -BackupDirectory $backupDir } | Should -Throw '*connection refused*'

		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'Error during PV backup: .*connection refused' }
	}

	It 'fails when a discovered PV is missing from the backup results' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Results @{ 'pv-a' = $true } -NotReported @('pv-b') -Types @{ 'pv-b' = 'hostPath' }) }

		$result = Invoke-PVBackup -BackupDirectory $backupDir

		$result.Success | Should -BeFalse
		$result.BackedUpCount | Should -Be 1
		$result.Message | Should -BeLike '1 of 2 discovered persistent volume(s) are neither excluded nor backed up. No backup result for 1 persistent volume(s): pv-b (hostPath)'
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "\[PVBackup\] ERROR: Persistent volume 'pv-b' \(type 'hostPath'\) was neither excluded nor backed up" }
	}

	It 'fails instead of assuming success when the backup returns <Name>' -TestCases @(
		@{ Name = 'null'; Value = $null },
		@{ Name = 'a plain result hashtable'; Value = @{ 'pv-a' = $true } },
		@{ Name = 'an empty hashtable'; Value = @{} }
	) {
		param($Value)
		$script:pvBackupMockResult = $Value
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return $script:pvBackupMockResult }

		$result = Invoke-PVBackup -BackupDirectory $backupDir

		$result.Success | Should -BeFalse
		$result.BackedUpCount | Should -Be 0
		$result.Message | Should -BeLike '*unexpected result*'
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'No persistent volumes found' }
	}

	It 'succeeds without a backup when no PVs are discovered' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport) }

		$result = Invoke-PVBackup -BackupDirectory $backupDir

		$result.Success | Should -BeTrue
		$result.BackedUpCount | Should -Be 0
		$result.Details.Count | Should -Be 0
		$result.Message | Should -Be 'No PVs to backup'
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'No persistent volumes found to backup' }
	}

	It 'succeeds without a backup when every discovered PV is excluded by configuration' {
		InModuleScope $moduleName { $script:rootConfig = [pscustomobject]@{ backup = [pscustomobject]@{ excludedAddonPersistentVolumes = 'pv-addon-a,pv-addon-b' } } }
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Excluded @('pv-addon-a', 'pv-addon-b')) }

		$result = Invoke-PVBackup -BackupDirectory $backupDir

		$result.Success | Should -BeTrue
		$result.BackedUpCount | Should -Be 0
		$result.Details.Count | Should -Be 0
		$result.Message | Should -Be 'No PVs to backup'
		Should -Invoke -ModuleName $moduleName Backup-AllPersistentVolumes -Exactly 1 -Scope It -ParameterFilter { (@($ExcludeNames) -join ',') -eq 'pv-addon-a,pv-addon-b' }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'all 2 discovered PV\(s\) are excluded' }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'ERROR' }
	}

	It 'succeeds when every discovered PV is either excluded or backed up' {
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes { return (New-PVBackupReport -Results @{ 'pv-a' = $true } -Excluded @('pv-addon')) }

		$result = Invoke-PVBackup -BackupDirectory $backupDir

		$result.Success | Should -BeTrue
		$result.BackedUpCount | Should -Be 1
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'intentionally excluded from backup: pv-addon' }
	}
}

Describe 'PerformClusterUpgrade PV restore error handling' -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		Mock -ModuleName $moduleName Get-LogFilePath -MockWith { return 'TestDrive:\logfile.log' }
		Mock -ModuleName $moduleName Get-Content -MockWith { return 'log content' }
		Mock -ModuleName $moduleName Remove-SetupConfigIfExisting
		Mock -ModuleName $moduleName Start-Sleep
		Mock -ModuleName $moduleName Invoke-ClusterUninstall
		Mock -ModuleName $moduleName Invoke-ClusterInstall
		Mock -ModuleName $moduleName Invoke-UpgradeBackupRestoreHooks
		Mock -ModuleName $moduleName Import-NotNamespacedResources
		Mock -ModuleName $moduleName Import-NamespacedResources
		Mock -ModuleName $moduleName Restore-LogFile
		Mock -ModuleName $moduleName Write-Log
		Mock -ModuleName $moduleName Write-Progress
		Mock -ModuleName $moduleName Get-ProductVersion -MockWith { return '1.0.0' }
		Mock -ModuleName $moduleName Get-KubePath -MockWith { return 'C:\KubePath' }
		Mock -ModuleName $moduleName Write-RefreshEnvVariablesGivenKubePath
		Mock -ModuleName $moduleName Enable-ClusterIsRunning
		Mock -ModuleName $moduleName Wait-ForAPIServerInGivenKubePath
		Mock -ModuleName $moduleName Get-KubeBinPathGivenKubePath -MockWith { return 'C:\KubeBinPath' }
		Mock -ModuleName $moduleName Restore-DeferredClusterIssuers { return @() }

		function Invoke-PerformClusterUpgradeForPVTest {
			param(
				[string] $BackupDir,
				[string] $PVBackupPath,
				[ref] $RestoreErrors
			)
			PerformClusterUpgrade -ExecuteHooks -K2sPathToInstallFrom 'C:\K2sPath' -Config 'config.yaml' -BackupDir $BackupDir -memoryVM @{ Startup = '4GB'; DynamicMemoryEnabled = $false } -coresVM '2' -storageVM '100GB' -enabledAddonsList ([System.Collections.ArrayList]@()) -hooksBackupPath (Join-Path $BackupDir 'hooks') -logFilePathBeforeUninstall (Join-Path $BackupDir 'k2s-before-uninstall.log') -pvBackupPath $PVBackupPath -resourceRestoreErrors $RestoreErrors
		}
	}

	BeforeEach {
		$backupDir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
		$pvDir = Join-Path $backupDir 'pv'
		New-Item -Path $pvDir -ItemType Directory -Force | Out-Null
		foreach ($pvName in @('pv-a', 'pv-b', 'pv-c')) {
			Set-Content -Path (Join-Path $pvDir "$pvName-backup.tar.gz") -Value "$pvName data"
			Set-Content -Path (Join-Path $pvDir "$pvName-backup-metadata.json") -Value "{ `"pvName`": `"$pvName`" }"
		}
		$restoreErrors = [ref]@()
	}

	It 'records no error when all PV restores succeed' {
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return @{ 'pv-a' = $true; 'pv-b' = $true; 'pv-c' = $true } }

		Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors

		Should -Invoke -ModuleName $moduleName Restore-AllPersistentVolumes -Exactly 1 -Scope It -ParameterFilter { $BackupPath -eq $pvDir -and $Force }
		@($restoreErrors.Value).Count | Should -Be 0
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'PERSISTENT VOLUME RESTORE ERRORS' }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'Upgraded successfully' }
	}

	It 'records a failed restore of a single PV' {
		Remove-Item -Path (Join-Path $pvDir 'pv-b-*'), (Join-Path $pvDir 'pv-c-*')
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return @{ 'pv-a' = $false } }

		{ Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors } | Should -Not -Throw

		$restoreErrors.Value | Should -Be @("Persistent volume 'pv-a' could not be restored")
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'PERSISTENT VOLUME RESTORE ERRORS' -and $Console }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "\[PVRestore\] ERROR: Persistent volume 'pv-a' could not be restored" }
	}

	It 'records only the failed PV when one of multiple PV restores fails' {
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return @{ 'pv-a' = $true; 'pv-b' = $false; 'pv-c' = $true } }

		Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors

		$restoreErrors.Value | Should -Be @("Persistent volume 'pv-b' could not be restored")
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'PV restore completed: 2 persistent volume\(s\) restored, 1 failed' }
	}

	It 'records every failed PV when several PV restores fail' {
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return @{ 'pv-a' = $false; 'pv-b' = $true; 'pv-c' = $false } }

		Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors

		$restoreErrors.Value | Should -Be @("Persistent volume 'pv-a' could not be restored", "Persistent volume 'pv-c' could not be restored")
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "\*\*   - Persistent volume 'pv-a' could not be restored" }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "\*\*   - Persistent volume 'pv-c' could not be restored" }
	}

	It 'records the original exception when Restore-AllPersistentVolumes throws, without failing the upgrade' {
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { throw 'scp transfer to the VM failed' }

		{ Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors } | Should -Not -Throw

		$restoreErrors.Value | Should -Be @('PV restore failed: scp transfer to the VM failed')
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match '\[PVRestore\] ERROR: PV restore failed: scp transfer to the VM failed' }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'Continuing with upgrade' }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'Upgraded successfully' }
	}

	It 'records an error when the PV restore returns <Name>' -TestCases @(
		@{ Name = 'null'; Value = $null },
		@{ Name = 'boolean true'; Value = $true },
		@{ Name = 'a string'; Value = 'done' }
	) {
		param($Value)
		$script:pvRestoreMockResult = $Value
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return $script:pvRestoreMockResult }

		Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors

		@($restoreErrors.Value).Count | Should -Be 1
		$restoreErrors.Value[0] | Should -Match 'PV restore returned an unexpected result'
	}

	It 'records an error when backup archives were not restored' {
		# e.g. archives skipped by Restore-AllPersistentVolumes because their metadata is missing
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return @{ 'pv-a' = $true } }

		Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors

		@($restoreErrors.Value).Count | Should -Be 1
		$restoreErrors.Value[0] | Should -Match "Only 1 of 3 PV backup archive\(s\) in '.*' were restored, not restored: pv-b, pv-c"
	}

	It 'calls the restore with RequireBackups so that missing archives are not reported as success' {
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return @{ 'pv-a' = $true; 'pv-b' = $true; 'pv-c' = $true } }

		Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors

		Should -Invoke -ModuleName $moduleName Restore-AllPersistentVolumes -Exactly 1 -Scope It -ParameterFilter { $RequireBackups }
	}

	It 'records a restore failure when the expected PV backup directory does not exist' {
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return @{} }
		Remove-Item -Path $pvDir -Recurse -Force

		{ Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors } | Should -Not -Throw

		Should -Invoke -ModuleName $moduleName Restore-AllPersistentVolumes -Exactly 0 -Scope It
		@($restoreErrors.Value).Count | Should -Be 1
		$restoreErrors.Value[0] | Should -Match "PV backup directory '.*' not found"
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match '\[PVRestore\] ERROR: PV backup directory' }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'PERSISTENT VOLUME RESTORE ERRORS' }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 0 -Scope It -ParameterFilter { $Messages -match 'skipping PV restore' }
	}

	It 'records a restore failure when the PV backup directory contains <Name>' -TestCases @(
		@{ Name = 'no files'; Files = @() },
		@{ Name = 'no backup archives'; Files = @('notes.txt') }
	) {
		param($Files)
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return @{} }
		Get-ChildItem -Path $pvDir -File | Remove-Item -Force
		foreach ($file in $Files) { Set-Content -Path (Join-Path $pvDir $file) -Value 'x' }

		Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors

		Should -Invoke -ModuleName $moduleName Restore-AllPersistentVolumes -Exactly 0 -Scope It
		@($restoreErrors.Value).Count | Should -Be 1
		$restoreErrors.Value[0] | Should -Match "No PV backup archives found in '.*'"
		$pvDir | Should -Exist
	}

	It 'records a restore failure for every PV whose backup archive is missing' {
		Remove-Item -Path (Join-Path $pvDir 'pv-b-backup.tar.gz')
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return @{ 'pv-a' = $true; 'pv-c' = $true } }

		Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors

		Should -Invoke -ModuleName $moduleName Restore-AllPersistentVolumes -Exactly 1 -Scope It
		@($restoreErrors.Value).Count | Should -Be 1
		$restoreErrors.Value[0] | Should -Match "Backup archive 'pv-b-backup\.tar\.gz' of persistent volume 'pv-b' is missing"
	}

	It 'records a restore failure when only metadata files are left in the PV backup directory' {
		Get-ChildItem -Path $pvDir -Filter '*.tar.gz' -File | Remove-Item -Force
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return @{} }

		Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors

		Should -Invoke -ModuleName $moduleName Restore-AllPersistentVolumes -Exactly 0 -Scope It
		@($restoreErrors.Value).Count | Should -Be 4
		@($restoreErrors.Value | Where-Object { $_ -match 'Backup archive .* is missing' }).Count | Should -Be 3
		$restoreErrors.Value | Should -Contain "No PV backup archives found in '$pvDir', the backed-up persistent volumes could not be restored"
	}

	It 'keeps PV restore errors together with ClusterIssuer restore errors' {
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return @{ 'pv-a' = $true; 'pv-b' = $false; 'pv-c' = $true } }
		Mock -ModuleName $moduleName Restore-DeferredClusterIssuers { return @('Backed-up ClusterIssuers were not restored') }

		Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors

		$restoreErrors.Value | Should -Be @("Persistent volume 'pv-b' could not be restored", 'Backed-up ClusterIssuers were not restored')
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'RESOURCE RESTORE ERRORS' }
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'PERSISTENT VOLUME RESTORE ERRORS' }
	}

	It 'keeps the recorded PV restore errors when a later upgrade step fails' {
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return @{ 'pv-a' = $true; 'pv-b' = $false; 'pv-c' = $true } }
		Mock -ModuleName $moduleName Import-NamespacedResources { throw 'import failed' }

		{ Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors } | Should -Throw '*import failed*'

		$restoreErrors.Value | Should -Be @("Persistent volume 'pv-b' could not be restored")
	}

	It 'does not touch the PV backup files' {
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return @{ 'pv-a' = $true; 'pv-b' = $false; 'pv-c' = $true } }

		Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath $pvDir -RestoreErrors $restoreErrors

		@(Get-ChildItem -Path $pvDir -File).Count | Should -Be 6
	}

	It 'skips the PV restore when no PV backup was created' {
		Mock -ModuleName $moduleName Restore-AllPersistentVolumes { return @{} }

		Invoke-PerformClusterUpgradeForPVTest -BackupDir $backupDir -PVBackupPath '' -RestoreErrors $restoreErrors

		Should -Invoke -ModuleName $moduleName Restore-AllPersistentVolumes -Exactly 0 -Scope It
		@($restoreErrors.Value).Count | Should -Be 0
		Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match 'skipping PV restore' }
	}
}

Describe 'Assert-UpgradeOperation with Force flag' -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		Mock -ModuleName $moduleName Write-Log { }
		Mock -ModuleName $moduleName Get-ClusterInstalledFolder { return "C:\k" }
		Mock -ModuleName $moduleName Get-ClusterCurrentVersion { return "1.0.0" }
		Mock -ModuleName $moduleName Get-ConfigSetupType { return "k2s" }
		Mock -ModuleName $moduleName Get-KubePath { return "C:\k2" }
		Mock -ModuleName $moduleName Restart-ClusterIfBuildVersionMismatch { return $true }
	}

	Context "When Force flag is not set" {
		It "should reject upgrade between non-consecutive versions" {
			InModuleScope $moduleName {
				# Setup: Set product version to simulate a jump of 2 minor versions
				$script:productVersion = "1.2.0"

				# Test
				{ Assert-UpgradeOperation } | Should -Throw "Upgrade not supported from 1.0.0 to 1.2.0*"
			}
		}

		It "should allow upgrade to a newer major version" {
			InModuleScope $moduleName {
				# Setup: Set product version to simulate major version change
				$script:productVersion = "2.0.0"

				# Test
				Assert-UpgradeOperation | Should -Be $true
			}
		}
	}

	Context "When Force flag is set" {
		It "should allow upgrade between non-consecutive versions" {
			InModuleScope $moduleName {
				# Setup: Set product version to simulate a jump of 2 minor versions
				$script:productVersion = "1.2.0"

				# Test
				Assert-UpgradeOperation -Force | Should -Be $true
			}
		}

		It "should allow upgrade between different major versions" {
			InModuleScope $moduleName {
				# Setup: Set product version to simulate major version change
				$script:productVersion = "2.0.0"

				# Test
				Assert-UpgradeOperation -Force | Should -Be $true
			}
		}

		It "should still validate version format" {
			InModuleScope $moduleName {
				# Setup: Set invalid version format
				$script:productVersion = "2.x.0"

				# Test
				{ Assert-UpgradeOperation -Force } | Should -Throw "*Upgrade not supported*"
			}
		}
	}

	Context "Common validation regardless of Force flag" {
		It "should reject when install folders are the same" {
            InModuleScope $moduleName {
                # Setup: Mock Get-ClusterInstalledFolder and Get-KubePath to return same path
                Mock Get-ClusterInstalledFolder { return "C:\same" }
                Mock Get-KubePath { return "C:\same" }
                $script:productVersion = "1.1.0"

                # Test
                { Assert-UpgradeOperation -Force } | Should -Throw "Current cluster is available from same folder*"
            }
        }

		It "should reject when setup type is not k2s" {
			InModuleScope $moduleName {
				# Setup
				Mock Get-ConfigSetupType { return "other" }
				$script:productVersion = "1.1.0"

				# Test
				{ Assert-UpgradeOperation -Force } | Should -Throw "Upgrade only supported in the default variant*"
			}
		}
	}
}
