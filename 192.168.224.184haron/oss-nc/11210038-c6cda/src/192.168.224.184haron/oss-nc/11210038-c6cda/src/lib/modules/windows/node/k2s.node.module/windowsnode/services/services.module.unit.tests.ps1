# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
	$moduleName = (Import-Module "$PSScriptRoot\services.module.psm1" -PassThru -Force).Name
	Mock -ModuleName $moduleName Write-Log {}
}

Describe 'Update-NssmServiceInstallPath' -Tag 'unit', 'ci', 'update' {
	It 'returns an empty result when the service does not exist' {
		Mock -ModuleName $moduleName Get-Service { $null }
		$result = Update-NssmServiceInstallPath -Name 'containerd' -OldPath 'C:\k' -NewPath 'C:\k2s\1.9.0' -NssmPath 'nssm.exe'
		$result.Count | Should -Be 0
	}

	It 'returns an empty result when the nssm registry parameters are missing' {
		Mock -ModuleName $moduleName Get-Service { [pscustomobject]@{ Name = 'containerd'; Status = 'Stopped' } }
		# Scope the mock to the service Parameters registry key so unrelated Test-Path calls are not intercepted.
		Mock -ModuleName $moduleName Test-Path { $false } -ParameterFilter { $LiteralPath -like 'HKLM:\SYSTEM\CurrentControlSet\Services\*\Parameters' }
		$result = Update-NssmServiceInstallPath -Name 'containerd' -OldPath 'C:\k' -NewPath 'C:\k2s\1.9.0' -NssmPath 'nssm.exe'
		$result.Count | Should -Be 0
	}

	It 'trims trailing backslashes from OldPath so an exact-root registry value still matches' {
		Mock -ModuleName $moduleName Get-Service { [pscustomobject]@{ Name = 'containerd'; Status = 'Stopped' } }
		Mock -ModuleName $moduleName Test-Path { $true } -ParameterFilter { $LiteralPath -like 'HKLM:\SYSTEM\CurrentControlSet\Services\*\Parameters' }
		# AppDirectory is exactly the install root; without trimming, OldPath 'C:\k\' would not match it.
		Mock -ModuleName $moduleName Get-ItemProperty { [pscustomobject]@{ AppDirectory = 'C:\k' } }
		# The value is written directly to the registry via Set-ItemProperty; mock it so the test does not
		# touch the real registry.
		Mock -ModuleName $moduleName Set-ItemProperty { }
		$result = Update-NssmServiceInstallPath -Name 'containerd' -OldPath 'C:\k\' -NewPath 'C:\k2s\1.9.0\' -NssmPath 'nssm.exe'
		$result.Keys | Should -Contain 'AppDirectory'
		$result['AppDirectory'] | Should -Be 'C:\k'
	}

	It 'writes the re-pointed value verbatim to the registry (no native-command quoting) for paths with spaces' {
		Mock -ModuleName $moduleName Get-Service { [pscustomobject]@{ Name = 'dnsproxy'; Status = 'Stopped' } }
		Mock -ModuleName $moduleName Test-Path { $true } -ParameterFilter { $LiteralPath -like 'HKLM:\SYSTEM\CurrentControlSet\Services\*\Parameters' }
		# AppParameters mixes spaces with embedded double quotes - the exact case that broke 'nssm.exe set'.
		Mock -ModuleName $moduleName Get-ItemProperty { [pscustomobject]@{ AppParameters = '--config-path="C:\Program Files\k2s\1.8.0\bin\dnsproxy.yaml"' } }
		$script:capturedValue = $null
		Mock -ModuleName $moduleName Set-ItemProperty { $script:capturedValue = $Value } -ParameterFilter { $Name -eq 'AppParameters' }
		$result = Update-NssmServiceInstallPath -Name 'dnsproxy' -OldPath 'C:\Program Files\k2s\1.8.0' -NewPath 'C:\Program Files\k2s\1.8.1-from-1.8.0' -NssmPath 'nssm.exe'
		$result.Keys | Should -Contain 'AppParameters'
		$script:capturedValue | Should -Be '--config-path="C:\Program Files\k2s\1.8.1-from-1.8.0\bin\dnsproxy.yaml"'
	}

	It 'does not record a parameter for rollback when the registry write fails' {
		Mock -ModuleName $moduleName Get-Service { [pscustomobject]@{ Name = 'containerd'; Status = 'Stopped' } }
		Mock -ModuleName $moduleName Test-Path { $true } -ParameterFilter { $LiteralPath -like 'HKLM:\SYSTEM\CurrentControlSet\Services\*\Parameters' }
		Mock -ModuleName $moduleName Get-ItemProperty { [pscustomobject]@{ AppDirectory = 'C:\k' } }
		# Registry write fails (e.g. ACL-protected key / locked service).
		Mock -ModuleName $moduleName Set-ItemProperty { throw 'access denied' }
		$result = Update-NssmServiceInstallPath -Name 'containerd' -OldPath 'C:\k' -NewPath 'C:\k2s\1.9.0' -NssmPath 'nssm.exe'
		# The failed parameter must NOT be reported as updated, so the caller does not believe
		# the relocation succeeded for a service that still points at the old path.
		$result.Keys | Should -Not -Contain 'AppDirectory'
		$result.Count | Should -Be 0
	}
}


