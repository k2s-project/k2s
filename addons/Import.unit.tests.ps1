# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        "$PSScriptRoot\Import.ps1", [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw ($parseErrors | Out-String)
    }

    $statements = $ast.EndBlock.Statements
    $start = ($statements | Where-Object { $_.Extent.Text -eq '$setupInfo = Get-SetupInfo' }).Extent.StartOffset
    $end = ($statements | Where-Object { $_.Extent.Text.StartsWith('if ($ArtifactFile)') }).Extent.StartOffset
    if ($null -eq $start -or $null -eq $end) {
        throw 'Could not locate addon import target selection.'
    }
    $script:selectImportTargets = [scriptblock]::Create(
        $ast.Extent.Text.Substring($start, $end - $start))

    function Get-SetupInfo { }
    function Resolve-NodeList { param($Nodes) }
    function Resolve-ImageNode { param($NodeName) }
    function Test-NodeReady { param($NodeName, $Kind) }
}

Describe 'Addon import target selection' -Tag 'unit', 'ci', 'addon' {
    It 'selects the appropriate image layers for <Name>' -TestCases @(
        @{ Name = 'mixed Windows-hosted defaults'; LinuxOnly = $false; Targets = ''; Linux = $true; Windows = $true }
        @{ Name = 'Windows-hosted Linux-only defaults'; LinuxOnly = $true; Targets = ''; Linux = $true; Windows = $false }
        @{ Name = 'an explicit Linux worker in a mixed setup'; LinuxOnly = $false; Targets = 'linux-worker'; Linux = $true; Windows = $false }
        @{ Name = 'an explicit Linux worker in a Linux-only setup'; LinuxOnly = $true; Targets = 'linux-worker'; Linux = $true; Windows = $false }
        @{ Name = 'an explicit Windows worker'; LinuxOnly = $false; Targets = 'windows-worker'; Linux = $false; Windows = $true }
        @{ Name = 'explicit Linux and Windows workers'; LinuxOnly = $false; Targets = 'linux-worker,windows-worker'; Linux = $true; Windows = $true }
    ) {
        param($Name, $LinuxOnly, $Targets, $Linux, $Windows)

        Mock Get-SetupInfo { @{ LinuxOnly = $LinuxOnly } }
        Mock Resolve-NodeList { @($Nodes -split ',' | Where-Object { $_ }) }
        Mock Resolve-ImageNode {
            if ($NodeName -eq 'linux-worker') {
                return @{ OS = 'linux'; Kind = 'LinuxWorker' }
            }
            return @{ OS = 'windows'; Kind = 'WindowsWorker' }
        }
        Mock Test-NodeReady { $true }

        $Nodes = $Targets
        . $script:selectImportTargets

        $shouldImportLinuxImages | Should -Be $Linux
        $shouldImportWindowsImages | Should -Be $Windows
        $linuxNodes.Count | Should -Be @($Targets -split ',' | Where-Object { $_ -eq 'linux-worker' }).Count
        $windowsNodes.Count | Should -Be @($Targets -split ',' | Where-Object { $_ -eq 'windows-worker' }).Count
    }
}
