# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
	$moduleName = (Import-Module "$PSScriptRoot\upgrade.module.psm1" -PassThru -Force).Name
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

	It 'surfaces the kubectl output when creating fails' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = 'Error from server (InternalError): failed calling webhook "webhook.cert-manager.io": service "cert-manager-webhook" not found'; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'create' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
			$errors[0] | Should -Match 'could not be restored'
			$errors[0] | Should -Match 'service "cert-manager-webhook" not found'
		}
	}

	It 'treats server errors as failure even when kubectl exits with 0' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = 'Error from server (Forbidden): admission denied'; ExitCode = 0 }
			} -ParameterFilter { $Arguments[0] -eq 'create' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
			$errors[0] | Should -Match 'admission denied'
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

	It 'keeps ClusterIssuers created by the re-enabled addons (e.g. the K2s CA issuer) and restores only missing ones' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = "clusterissuer.cert-manager.io/user-issuer created`nError from server (AlreadyExists): error when creating `"clusterissuers.yaml`": clusterissuers.cert-manager.io `"k2s-ca-issuer`" already exists"; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'create' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 0
			Should -Invoke Invoke-RestoreKubectl -Exactly 0 -Scope It -ParameterFilter { $Arguments[0] -in @('apply', 'replace', 'delete', 'patch') }
		}
	}

	It 'is idempotent when all backed-up ClusterIssuers already exist (e.g. restore invoked again)' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = "Error from server (AlreadyExists): error when creating `"clusterissuers.yaml`": clusterissuers.cert-manager.io `"k2s-ca-issuer`" already exists`nError from server (AlreadyExists): error when creating `"clusterissuers.yaml`": clusterissuers.cert-manager.io `"user-issuer`" already exists"; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'create' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 0
		}
	}

	It 'reports a failure when one issuer is rejected even though others already exist' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = "Error from server (AlreadyExists): error when creating `"clusterissuers.yaml`": clusterissuers.cert-manager.io `"k2s-ca-issuer`" already exists`nError from server (InternalError): error when creating `"clusterissuers.yaml`": failed calling webhook `"webhook.cert-manager.io`""; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'create' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
			$errors[0] | Should -Match 'failed calling webhook'
		}
	}

	It 'reports a failure when kubectl cannot read the backup file' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl {
				return [pscustomobject]@{ Output = 'error: the path "clusterissuers.yaml" cannot be parsed'; ExitCode = 1 }
			} -ParameterFilter { $Arguments[0] -eq 'create' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
			$errors[0] | Should -Match 'cannot be parsed'
		}
	}

	It 'reports a failure on a non-zero exit code without output' {
		InModuleScope $moduleName -Parameters @{ Folder = $folder } {
			Mock Invoke-RestoreKubectl { return [pscustomobject]@{ Output = ''; ExitCode = 1 } } -ParameterFilter { $Arguments[0] -eq 'create' }

			$errors = @(Restore-DeferredClusterIssuers -folderResources $Folder -ExePath 'C:\bin')

			$errors.Count | Should -Be 1
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
		Mock -ModuleName $moduleName Backup-AllPersistentVolumes -MockWith { return $null }
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
