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

	It 'rolls back and keeps the existing cleanup when the upgrade fails but the rollback succeeds' {
		Mock PerformClusterUpgrade { $script:performCalls.Add($ExecuteHooks.IsPresent) | Out-Null; throw 'upgrade failed' } -ParameterFilter { $ExecuteHooks }
		Mock PerformClusterUpgrade { $script:performCalls.Add($ExecuteHooks.IsPresent) | Out-Null; $resourceRestoreErrors.Value = @() } -ParameterFilter { -not $ExecuteHooks }

		$result = Start-ClusterUpgrade -BackupDir 'C:\Backup'

		$result | Should -BeNullOrEmpty
		$script:performCalls | Should -Be @($true, $false)
		Should -Invoke PerformClusterUpgrade -Exactly 1 -Scope It -ParameterFilter { -not $ExecuteHooks -and $K2sPathToInstallFrom -eq 'C:\k2s-old' }
		Should -Invoke Remove-ExportedClusterResources -Exactly 1 -Scope It -ParameterFilter { $PathResources -eq 'C:\Backup' -and $DeleteFiles }
	}

	It 'keeps the backup when the rolled-back cluster could not restore all resources' {
		Mock PerformClusterUpgrade { throw 'upgrade failed' } -ParameterFilter { $ExecuteHooks }
		Mock PerformClusterUpgrade { $resourceRestoreErrors.Value = @('Backed-up ClusterIssuers were not restored') } -ParameterFilter { -not $ExecuteHooks }

		Start-ClusterUpgrade -BackupDir 'C:\Backup' | Out-Null

		Should -Invoke Remove-ExportedClusterResources -Exactly 0 -Scope It
	}

	It 'keeps the backup when the preliminary export fails' {
		Mock PrepareClusterUpgrade { throw 'export failed' }
		Mock PerformClusterUpgrade { }

		$result = Start-ClusterUpgrade -BackupDir 'C:\Backup' -ErrorAction SilentlyContinue

		$result | Should -Be $false
		Should -Invoke PerformClusterUpgrade -Exactly 0 -Scope It
		Should -Invoke Remove-ExportedClusterResources -Exactly 0 -Scope It
	}
}
