# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
	$moduleName = (Import-Module "$PSScriptRoot\path.module.psm1" -PassThru -Force).Name

	# The user PATH is written directly to HKCU via Set-ItemProperty; mock read/write so the tests never
	# touch the real registry. Get-ItemProperty is overridden per-test to model the current HKCU PATH value.
	$script:capturedPath = $null
	Mock -ModuleName $moduleName Set-ItemProperty { $script:capturedPath = $Value } -ParameterFilter { $Name -eq 'PATH' }
}

Describe 'Update-UserPath' -Tag 'unit', 'ci', 'update' {
	BeforeEach {
		# Preserve the real process PATH; Update-UserPath mutates $env:Path in-session by design.
		$script:originalEnvPath = $env:Path
		$script:capturedPath = $null
	}

	AfterEach {
		$env:Path = $script:originalEnvPath
	}

	It "add writes the entry to the user PATH registry value and updates the current process PATH" {
		Mock -ModuleName $moduleName Get-ItemProperty { [pscustomobject]@{ path = '' } }
		$env:Path = 'C:\existing'

		Update-UserPath -Action 'add' 'C:\Users\Test\.krew\bin'

		$script:capturedPath | Should -Be 'C:\Users\Test\.krew\bin'
		($env:Path.Split([IO.Path]::PathSeparator) -contains 'C:\Users\Test\.krew\bin') | Should -BeTrue
	}

	It "add is idempotent - an already present entry is not duplicated" {
		Mock -ModuleName $moduleName Get-ItemProperty { [pscustomobject]@{ path = 'C:\Users\Test\.krew\bin' } }

		Update-UserPath -Action 'add' 'C:\Users\Test\.krew\bin'

		($script:capturedPath.Split([IO.Path]::PathSeparator) | Where-Object { $_ -eq 'C:\Users\Test\.krew\bin' }).Count | Should -Be 1
	}

	It "add handles a missing HKCU PATH value without error (fresh profile / Server Core)" {
		# Get-ItemProperty returns nothing when HKCU:\Environment has no PATH value yet.
		Mock -ModuleName $moduleName Get-ItemProperty { $null }

		{ Update-UserPath -Action 'add' 'C:\Users\Test\.krew\bin' } | Should -Not -Throw
		# No leading separator should be produced from the empty starting value.
		$script:capturedPath | Should -Be 'C:\Users\Test\.krew\bin'
	}

	It "remove deletes the entry from the user PATH registry value but keeps unrelated entries" {
		Mock -ModuleName $moduleName Get-ItemProperty { [pscustomobject]@{ path = "C:\other$([IO.Path]::PathSeparator)C:\Users\Test\.krew\bin" } }

		Update-UserPath -Action 'remove' 'C:\Users\Test\.krew\bin'

		($script:capturedPath.Split([IO.Path]::PathSeparator) -contains 'C:\Users\Test\.krew\bin') | Should -BeFalse
		($script:capturedPath.Split([IO.Path]::PathSeparator) -contains 'C:\other') | Should -BeTrue
	}

	It "remove is case-insensitive" {
		Mock -ModuleName $moduleName Get-ItemProperty { [pscustomobject]@{ path = 'C:\Users\Test\.KREW\BIN' } }

		Update-UserPath -Action 'remove' 'C:\Users\Test\.krew\bin'

		($script:capturedPath.Split([IO.Path]::PathSeparator) | Where-Object { $_ -ne '' }).Count | Should -Be 0
	}

	It "remove also drops the entry from the current process PATH (no stale in-session entry)" {
		Mock -ModuleName $moduleName Get-ItemProperty { [pscustomobject]@{ path = 'C:\Users\Test\.krew\bin' } }
		$env:Path = "C:\before$([IO.Path]::PathSeparator)C:\Users\Test\.krew\bin$([IO.Path]::PathSeparator)C:\after"

		Update-UserPath -Action 'remove' 'C:\Users\Test\.krew\bin'

		($env:Path.Split([IO.Path]::PathSeparator) -contains 'C:\Users\Test\.krew\bin') | Should -BeFalse
		($env:Path.Split([IO.Path]::PathSeparator) -contains 'C:\before') | Should -BeTrue
		($env:Path.Split([IO.Path]::PathSeparator) -contains 'C:\after') | Should -BeTrue
	}

	It "remove does not create an HKCU PATH value when none existed (fresh profile / Server Core)" {
		# Get-ItemProperty returns nothing when HKCU:\Environment has no PATH value yet.
		Mock -ModuleName $moduleName Get-ItemProperty { $null }
		$env:Path = 'C:\before'

		Update-UserPath -Action 'remove' 'C:\Users\Test\.krew\bin'

		# Set-ItemProperty must not be invoked, so no (empty) PATH registry value is created.
		Should -Invoke -ModuleName $moduleName Set-ItemProperty -Times 0 -ParameterFilter { $Name -eq 'PATH' }
		$script:capturedPath | Should -BeNullOrEmpty
		# The current process PATH is still processed and left intact (the entry was not present anyway).
		($env:Path.Split([IO.Path]::PathSeparator) -contains 'C:\before') | Should -BeTrue
	}

	It "remove writes back the PATH when the entry is present, preserving unrelated entries" {
		Mock -ModuleName $moduleName Get-ItemProperty { [pscustomobject]@{ path = "C:\other$([IO.Path]::PathSeparator)C:\Users\Test\.krew\bin$([IO.Path]::PathSeparator)C:\more" } }

		Update-UserPath -Action 'remove' 'C:\Users\Test\.krew\bin'

		Should -Invoke -ModuleName $moduleName Set-ItemProperty -Times 1 -ParameterFilter { $Name -eq 'PATH' }
		($script:capturedPath.Split([IO.Path]::PathSeparator) -contains 'C:\Users\Test\.krew\bin') | Should -BeFalse
		($script:capturedPath.Split([IO.Path]::PathSeparator) -contains 'C:\other') | Should -BeTrue
		($script:capturedPath.Split([IO.Path]::PathSeparator) -contains 'C:\more') | Should -BeTrue
	}

	It "remove preserves an existing HKCU PATH that does not contain the entry" {
		Mock -ModuleName $moduleName Get-ItemProperty { [pscustomobject]@{ path = "C:\keep1$([IO.Path]::PathSeparator)C:\keep2" } }

		Update-UserPath -Action 'remove' 'C:\Users\Test\.krew\bin'

		# The value is still written back (it existed), but its contents are unchanged.
		$script:capturedPath | Should -Be "C:\keep1$([IO.Path]::PathSeparator)C:\keep2"
	}
}

