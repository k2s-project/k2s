# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

Describe 'Enable-MissingFeature' -Tag 'unit', 'ci', 'prerequisites' {
BeforeAll {
    $modulePath = "$PSScriptRoot/system.module.psm1"
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    $featureFunction = $moduleAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Enable-MissingFeature'
    }, $false)
    . ([scriptblock]::Create($featureFunction.Extent.Text))

    function Write-Log { param($Message) }
    function Get-WindowsOptionalFeature { [CmdletBinding()] param([switch]$Online, $FeatureName) }
    function Enable-WindowsOptionalFeature {
        [CmdletBinding()]
        param([switch]$Online, $FeatureName, [switch]$All, [switch]$NoRestart)
    }
}

    BeforeEach {
        Mock Write-Log {}
        Mock Get-WindowsOptionalFeature { [pscustomobject]@{ State = 'Disabled' } }
        Mock Enable-WindowsOptionalFeature { [pscustomobject]@{ RestartNeeded = $false } }
    }

    It 'returns the restart requirement reported by DISM' {
        Mock Enable-WindowsOptionalFeature { [pscustomobject]@{ RestartNeeded = $true } }

        Enable-MissingFeature -Name 'Containers' | Should -BeTrue
    }

    It 'does not request a restart when DISM reports none is needed' {
        Enable-MissingFeature -Name 'Containers' | Should -BeFalse
    }

    It 'fails when DISM does not return feature state' {
        Mock Enable-WindowsOptionalFeature {}

        { Enable-MissingFeature -Name 'Containers' } | Should -Throw '*returned no result*'
    }

    It 'does not enable or request a restart for an enabled feature' {
        Mock Get-WindowsOptionalFeature { [pscustomobject]@{ State = 'Enabled' } }

        Enable-MissingFeature -Name 'Containers' | Should -BeFalse

        Should -Invoke Enable-WindowsOptionalFeature -Times 0 -Exactly
    }
}

Describe 'Remove-K2sEventLogSources' -Tag 'unit', 'ci', 'uninstall' {
    BeforeAll {
        $modulePath = "$PSScriptRoot/system.module.psm1"
        $parseErrors = $null
        $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$parseErrors)
        if ($parseErrors) { throw ($parseErrors | Out-String) }
        $eventLogFunction = $moduleAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-K2sEventLogSources'
        }, $false)
        . ([scriptblock]::Create($eventLogFunction.Extent.Text))

        function Write-Log { param($Message) }

        $sourcesKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application'

        function New-EventLogSource {
            param($Name, [hashtable]$Properties)
            [pscustomobject]@{
                PSChildName = $Name
                PSPath      = "Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\EventLog\Application\$Name"
                Properties  = [pscustomobject]$Properties
            }
        }
    }

    BeforeEach {
        $script:sources = @()
        Mock Write-Log {}
        Mock Get-ChildItem { $script:sources }
        Mock Get-ItemProperty { ($script:sources | Where-Object PSPath -eq $Path).Properties }
        Mock Remove-Item {}
    }

    It 'removes the nssm source whose message file is the nssm.exe of the installation folder' {
        $script:sources = @(New-EventLogSource -Name 'nssm' -Properties @{ EventMessageFile = 'C:\k\bin\nssm.exe'; TypesSupported = 7 })

        Remove-K2sEventLogSources -InstallationPath 'C:\k'

        Should -Invoke Get-ChildItem -Times 1 -Exactly -ParameterFilter { $Path -eq $sourcesKey }
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $Path -like '*\EventLog\Application\nssm' -and $Recurse -and $Force }
    }

    It 'keeps sources whose message files are outside of the installation folder' {
        $script:sources = @(
            New-EventLogSource -Name 'Application Error' -Properties @{ EventMessageFile = 'C:\Windows\System32\wer.dll' }
            New-EventLogSource -Name 'nssm' -Properties @{ EventMessageFile = 'C:\tools\nssm\nssm.exe' }
            New-EventLogSource -Name 'other' -Properties @{ EventMessageFile = 'C:\k2\bin\other.exe' }
            New-EventLogSource -Name 'no-message-file' -Properties @{ TypesSupported = 7 }
        )

        Remove-K2sEventLogSources -InstallationPath 'C:\k'

        Should -Invoke Remove-Item -Times 0 -Exactly
    }

    It 'checks every message file property and every file of a semicolon-separated list' {
        $script:sources = @(
            New-EventLogSource -Name 'category' -Properties @{ EventMessageFile = 'C:\Windows\System32\EventCreate.exe'; CategoryMessageFile = 'C:\K\bin\category.dll' }
            New-EventLogSource -Name 'parameter' -Properties @{ ParameterMessageFile = 'C:\Windows\System32\kernel32.dll; "C:\k\bin\parameter.dll"' }
        )

        Remove-K2sEventLogSources -InstallationPath 'C:\k\'

        Should -Invoke Remove-Item -Times 2 -Exactly
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $Path -like '*\Application\category' }
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $Path -like '*\Application\parameter' }
    }

    It 'logs a failed removal and continues with the remaining sources' {
        $script:sources = @(
            New-EventLogSource -Name 'locked' -Properties @{ EventMessageFile = 'C:\k\bin\locked.exe' }
            New-EventLogSource -Name 'nssm' -Properties @{ EventMessageFile = 'C:\k\bin\nssm.exe' }
        )
        Mock Remove-Item { throw 'Access is denied.' } -ParameterFilter { $Path -like '*\Application\locked' }

        { Remove-K2sEventLogSources -InstallationPath 'C:\k' } | Should -Not -Throw

        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like "Failed to remove event log source 'locked'*Access is denied.*" }
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $Path -like '*\Application\nssm' }
    }

    It 'does not remove any source when the installation path is a drive root' {
        $script:sources = @(
            New-EventLogSource -Name 'Application Error' -Properties @{ EventMessageFile = 'C:\Windows\System32\wer.dll' }
            New-EventLogSource -Name 'nssm' -Properties @{ EventMessageFile = 'C:\bin\nssm.exe' }
        )

        Remove-K2sEventLogSources -InstallationPath 'C:\'

        Should -Invoke Get-ChildItem -Times 0 -Exactly
        Should -Invoke Remove-Item -Times 0 -Exactly
    }

    It 'does nothing when no event log sources exist' {
        Remove-K2sEventLogSources -InstallationPath 'C:\k'

        Should -Invoke Get-ItemProperty -Times 0 -Exactly
        Should -Invoke Remove-Item -Times 0 -Exactly
    }
}
