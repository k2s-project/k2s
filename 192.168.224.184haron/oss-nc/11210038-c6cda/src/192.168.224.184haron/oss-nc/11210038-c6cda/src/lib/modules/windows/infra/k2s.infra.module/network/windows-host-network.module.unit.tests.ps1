# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    function Get-HnsNetwork {}
    function Remove-HnsNetwork {}
    function Get-VMSwitch {}
    function Remove-VMSwitch {}

    $modulePath = Join-Path $PSScriptRoot 'windows-host-network.module.psm1'
    Import-Module $modulePath -Force
}

Describe 'Test-DefaultSwitch' -Tag 'unit', 'ci', 'network' {
    BeforeEach {
        Mock Write-Log -ModuleName windows-host-network.module
        Mock Get-ConfiguredK2sSubnets -ModuleName windows-host-network.module {
            @(
                @{ Name = 'masterNetworkCIDR'; Value = '172.19.1.0/24' },
                @{ Name = 'podNetworkCIDR'; Value = '172.20.0.0/16' },
                @{ Name = 'servicesCIDR'; Value = '172.21.0.0/16' },
                @{ Name = 'loopbackAdapterCIDR'; Value = '172.22.1.0/24' }
            )
        }
        Mock Remove-K2sDefaultSwitch -ModuleName windows-host-network.module
        Mock Start-Sleep -ModuleName windows-host-network.module
        Mock Get-VMSwitch -ModuleName windows-host-network.module
        Mock Get-NetAdapter -ModuleName windows-host-network.module
        Mock Get-CimInstance -ModuleName windows-host-network.module {
            [pscustomobject]@{ ProductType = 1 }
        }
    }

    It 'returns without removal when the Default Switch does not conflict' {
        Mock Get-NetIPAddress -ModuleName windows-host-network.module {
            [pscustomobject]@{ IPAddress = '192.168.128.1'; PrefixLength = 20 }
        }

        Test-DefaultSwitch -ResolveConflict

        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 0
    }

    It 'throws without removal when recovery is not requested' {
        Mock Get-NetIPAddress -ModuleName windows-host-network.module {
            [pscustomobject]@{ IPAddress = '172.21.16.1'; PrefixLength = 20 }
        }

        { Test-DefaultSwitch } | Should -Throw '*collides with K2s network configuration servicesCIDR*'

        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 0
    }

    It 'removes a conflicting switch and succeeds after revalidation' {
        $global:defaultSwitchRemovedForTest = $false
        Mock Get-NetIPAddress -ModuleName windows-host-network.module {
            if (-not $global:defaultSwitchRemovedForTest) {
                [pscustomobject]@{ IPAddress = '172.21.160.1'; PrefixLength = 20 }
            }
        }
        Mock Remove-K2sDefaultSwitch -ModuleName windows-host-network.module {
            $global:defaultSwitchRemovedForTest = $true
        }

        try {
            Test-DefaultSwitch -ResolveConflict -RetryDelaySeconds 0
        }
        finally {
            Remove-Variable -Name defaultSwitchRemovedForTest -Scope Global -ErrorAction SilentlyContinue
        }

        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 1 -Exactly
        Assert-MockCalled Get-NetIPAddress -ModuleName windows-host-network.module -Times 2 -Exactly
    }

    It 'throws after bounded recovery attempts keep finding a conflict' {
        Mock Get-NetIPAddress -ModuleName windows-host-network.module {
            [pscustomobject]@{ IPAddress = '172.21.16.1'; PrefixLength = 20 }
        }

        { Test-DefaultSwitch -ResolveConflict -MaxAttempts 2 -RetryDelaySeconds 0 } |
            Should -Throw '*Automatic recovery failed after 2 attempts*'

        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 1 -Exactly
        Assert-MockCalled Get-NetIPAddress -ModuleName windows-host-network.module -Times 2 -Exactly
    }

    It 'waits for a delayed non-conflicting IPv4 address' {
        $global:defaultSwitchProbeCount = 0
        Mock Get-NetIPAddress -ModuleName windows-host-network.module {
            $global:defaultSwitchProbeCount++
            if ($global:defaultSwitchProbeCount -eq 3) {
                [pscustomobject]@{ IPAddress = '192.168.128.1'; PrefixLength = 20 }
            }
        }
        try {
            Test-DefaultSwitch -SwitchObservationSeconds 120
        }
        finally {
            Remove-Variable defaultSwitchProbeCount -Scope Global
        }
        Assert-MockCalled Start-Sleep -ModuleName windows-host-network.module -Times 2 -Exactly
        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 0
    }

    It 'detects a conflicting switch that appears late without removing it in check-only mode' {
        $global:defaultSwitchProbeCount = 0
        Mock Get-NetIPAddress -ModuleName windows-host-network.module {
            $global:defaultSwitchProbeCount++
            if ($global:defaultSwitchProbeCount -gt 1) {
                [pscustomobject]@{ IPAddress = '172.20.192.1'; PrefixLength = 20 }
            }
        }
        try {
            { Test-DefaultSwitch -SwitchObservationSeconds 120 } |
                Should -Throw '*collides with K2s network configuration podNetworkCIDR*'
        }
        finally {
            Remove-Variable defaultSwitchProbeCount -Scope Global
        }
        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 0
    }

    It 'observes an absent switch on Windows client hosts to detect late creation' {
        Mock Get-NetIPAddress -ModuleName windows-host-network.module

        Test-DefaultSwitch -SwitchObservationSeconds 120

        Assert-MockCalled Get-NetIPAddress -ModuleName windows-host-network.module -Times 25 -Exactly
        Assert-MockCalled Start-Sleep -ModuleName windows-host-network.module -Times 24 -Exactly -ParameterFilter { $Seconds -eq 5 }
        Assert-MockCalled Get-VMSwitch -ModuleName windows-host-network.module -Times 2 -Exactly
        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 0
    }

    It 'skips observation when the Default Switch is absent on a server host' -TestCases @(
        @{ ProductType = 2 },
        @{ ProductType = 3 }
    ) {
        param($ProductType)
        Mock Get-NetIPAddress -ModuleName windows-host-network.module
        Mock Get-CimInstance -ModuleName windows-host-network.module {
            [pscustomobject]@{ ProductType = $ProductType }
        }

        Test-DefaultSwitch -SwitchObservationSeconds 120

        Assert-MockCalled Start-Sleep -ModuleName windows-host-network.module -Times 0
        Assert-MockCalled Get-NetIPAddress -ModuleName windows-host-network.module -Times 1 -Exactly
        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 0
    }

    It 'fails when the switch exists but its IPv4 address never initializes' {
        Mock Get-NetIPAddress -ModuleName windows-host-network.module
        Mock Get-VMSwitch -ModuleName windows-host-network.module {
            [pscustomobject]@{ Name = 'Default Switch' }
        }

        { Test-DefaultSwitch -SwitchObservationSeconds 7 } | Should -Throw '*subnet cannot be validated*'

        Assert-MockCalled Start-Sleep -ModuleName windows-host-network.module -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
        Assert-MockCalled Start-Sleep -ModuleName windows-host-network.module -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 0
    }

    It 'still observes an existing uninitialized switch on Windows Server' {
        Mock Get-NetIPAddress -ModuleName windows-host-network.module
        Mock Get-NetAdapter -ModuleName windows-host-network.module {
            [pscustomobject]@{ Name = 'vEthernet (Default Switch)' }
        }
        Mock Get-CimInstance -ModuleName windows-host-network.module {
            [pscustomobject]@{ ProductType = 3 }
        }

        { Test-DefaultSwitch -SwitchObservationSeconds 5 } | Should -Throw '*subnet cannot be validated*'

        Assert-MockCalled Start-Sleep -ModuleName windows-host-network.module -Times 1 -Exactly
        Assert-MockCalled Get-CimInstance -ModuleName windows-host-network.module -Times 0
    }

    It 'detects a conflict on final validation after an initially absent switch' {
        $global:defaultSwitchAppearedForTest = $false
        Mock Get-NetIPAddress -ModuleName windows-host-network.module {
            if ($global:defaultSwitchAppearedForTest) {
                [pscustomobject]@{ IPAddress = '172.20.192.1'; PrefixLength = 20 }
            }
        }
        try {
            Test-DefaultSwitch -ResolveConflict
            $global:defaultSwitchAppearedForTest = $true
            { Test-DefaultSwitch } | Should -Throw '*collides with K2s network configuration podNetworkCIDR*'
        }
        finally {
            Remove-Variable defaultSwitchAppearedForTest -Scope Global
        }
        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 0
    }

    It 'recovers a late conflicting switch and validates its replacement' {
        $global:defaultSwitchProbeCount = 0
        $global:defaultSwitchRemovedForTest = $false
        Mock Get-NetIPAddress -ModuleName windows-host-network.module {
            $global:defaultSwitchProbeCount++
            if ($global:defaultSwitchRemovedForTest) {
                [pscustomobject]@{ IPAddress = '192.168.128.1'; PrefixLength = 20 }
            }
            elseif ($global:defaultSwitchProbeCount -gt 1) {
                [pscustomobject]@{ IPAddress = '172.20.192.1'; PrefixLength = 20 }
            }
        }
        Mock Remove-K2sDefaultSwitch -ModuleName windows-host-network.module {
            $global:defaultSwitchRemovedForTest = $true
        }
        try {
            Test-DefaultSwitch -ResolveConflict -SwitchObservationSeconds 120 -RetryDelaySeconds 0
        }
        finally {
            Remove-Variable defaultSwitchProbeCount, defaultSwitchRemovedForTest -Scope Global
        }
        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 1 -Exactly
        Assert-MockCalled Get-NetIPAddress -ModuleName windows-host-network.module -Times 3 -Exactly
    }

    It 'allows an absent switch when Hyper-V management is unavailable' {
        Mock Get-NetIPAddress -ModuleName windows-host-network.module
        Mock Get-Command -ModuleName windows-host-network.module -ParameterFilter { $Name -eq 'Get-VMSwitch' }
        Mock Get-NetAdapter -ModuleName windows-host-network.module

        { Test-DefaultSwitch } | Should -Not -Throw

        Assert-MockCalled Get-VMSwitch -ModuleName windows-host-network.module -Times 0
        Assert-MockCalled Get-NetAdapter -ModuleName windows-host-network.module -Times 1 -Exactly
    }

    It 'rejects an uninitialized switch adapter when Hyper-V management is unavailable' {
        Mock Get-NetIPAddress -ModuleName windows-host-network.module
        Mock Get-Command -ModuleName windows-host-network.module -ParameterFilter { $Name -eq 'Get-VMSwitch' }
        Mock Get-NetAdapter -ModuleName windows-host-network.module {
            [pscustomobject]@{ Name = 'vEthernet (Default Switch)' }
        }

        { Test-DefaultSwitch } | Should -Throw '*subnet cannot be validated*'

        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 0
    }

    It 'logs Hyper-V query failure and falls back to detecting a newly visible adapter' {
        $global:defaultSwitchAdapterProbeCount = 0
        Mock Get-NetIPAddress -ModuleName windows-host-network.module
        Mock Get-VMSwitch -ModuleName windows-host-network.module { throw 'VMMS is starting' }
        Mock Get-NetAdapter -ModuleName windows-host-network.module {
            $global:defaultSwitchAdapterProbeCount++
            if ($global:defaultSwitchAdapterProbeCount -gt 1) {
                [pscustomobject]@{ Name = 'vEthernet (Default Switch)' }
            }
        }
        try {
            { Test-DefaultSwitch } | Should -Throw '*subnet cannot be validated*'
        }
        finally {
            Remove-Variable defaultSwitchAdapterProbeCount -Scope Global
        }
        Assert-MockCalled Write-Log -ModuleName windows-host-network.module -Times 1 -Exactly -ParameterFilter {
            ($Messages -join ' ') -like '*Hyper-V switch query failed*VMMS is starting*'
        }
        Assert-MockCalled Get-NetAdapter -ModuleName windows-host-network.module -Times 2 -Exactly
    }

    It 'continues observing a client host after transient Hyper-V query failures' {
        $global:defaultSwitchProbeCount = 0
        Mock Get-NetIPAddress -ModuleName windows-host-network.module {
            $global:defaultSwitchProbeCount++
            if ($global:defaultSwitchProbeCount -gt 1) {
                [pscustomobject]@{ IPAddress = '192.168.128.1'; PrefixLength = 20 }
            }
        }
        Mock Get-VMSwitch -ModuleName windows-host-network.module { throw 'VMMS is starting' }
        try {
            Test-DefaultSwitch -SwitchObservationSeconds 120
        }
        finally {
            Remove-Variable defaultSwitchProbeCount -Scope Global
        }
        Assert-MockCalled Start-Sleep -ModuleName windows-host-network.module -Times 1 -Exactly
        Assert-MockCalled Write-Log -ModuleName windows-host-network.module -Times 1 -Exactly -ParameterFilter {
            ($Messages -join ' ') -like '*Hyper-V switch query failed*'
        }
    }

    It 'propagates adapter query errors rather than reporting an absent switch' {
        Mock Get-NetIPAddress -ModuleName windows-host-network.module
        Mock Get-NetAdapter -ModuleName windows-host-network.module { throw 'Adapter query failed' }

        { Test-DefaultSwitch } | Should -Throw '*Adapter query failed*'
    }

    It 'does not stall an absent-switch server when VMMS is unavailable' {
        Mock Get-NetIPAddress -ModuleName windows-host-network.module
        Mock Get-VMSwitch -ModuleName windows-host-network.module { throw 'VMMS is stopped' }
        Mock Get-CimInstance -ModuleName windows-host-network.module {
            [pscustomobject]@{ ProductType = 3 }
        }

        { Test-DefaultSwitch -SwitchObservationSeconds 120 } | Should -Not -Throw

        Assert-MockCalled Start-Sleep -ModuleName windows-host-network.module -Times 0
        Assert-MockCalled Write-Log -ModuleName windows-host-network.module -Times 1 -Exactly -ParameterFilter {
            ($Messages -join ' ') -like '*Hyper-V switch query failed*VMMS is stopped*'
        }
    }
}

Describe 'Startup Default Switch validation' -Tag 'unit', 'ci', 'network' {
    BeforeAll {
        function Write-Log { param($Message, [switch]$Error) }
        function Test-DefaultSwitch { param([switch]$ResolveConflict, [int]$SwitchObservationSeconds = 0) }
        function Select-K2sIsRunning {}
        function Get-L2BridgeSwitchName {}
        function Invoke-HNSCommand {}
        function Test-NetworkL2BridgeReady {}
        function Confirm-LoopbackAdapterIP {}

        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..\..')).Path
        $startupPath = Join-Path $repoRoot 'lib\scripts\windows\host\system\startup\Start-System.ps1'
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($startupPath, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw ($parseErrors | Out-String)
        }
        $startupTry = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] }
        $startupBody = [scriptblock]::Create($startupTry.Extent.Text)
    }

    BeforeEach {
        $networkStartupAttempted = $false
        $EncodeStructuredOutput = $false
        $logUseCase = 'Start-System'
        Mock Write-Log
        Mock Test-DefaultSwitch
        Mock Select-K2sIsRunning { $false }
        Mock Get-L2BridgeSwitchName { 'cbr0' }
        Mock Invoke-HNSCommand { [pscustomobject]@{ Name = 'cbr0' } }
        Mock Test-NetworkL2BridgeReady { $true }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Confirm-LoopbackAdapterIP
        Mock Start-Service
    }

    It 'observes the switch before networking and performs a final check-only validation' {
        & $startupBody

        Assert-MockCalled Test-DefaultSwitch -Times 1 -Exactly -ParameterFilter { $ResolveConflict -and $SwitchObservationSeconds -eq 120 }
        Assert-MockCalled Test-DefaultSwitch -Times 1 -Exactly -ParameterFilter { -not $ResolveConflict -and -not $SwitchObservationSeconds }
    }

    It 'validates only once before the already-running early return' {
        Mock Select-K2sIsRunning { $true }

        & $startupBody

        Assert-MockCalled Test-DefaultSwitch -Times 1 -Exactly -ParameterFilter { $ResolveConflict -and $SwitchObservationSeconds -eq 120 }
        Assert-MockCalled Invoke-HNSCommand -Times 0
    }

    It 'propagates final validation failure instead of reporting successful startup' {
        Mock Test-DefaultSwitch {
            if (-not $ResolveConflict) {
                throw '[PREREQ-FAILED] late Default Switch collision'
            }
        }

        { & $startupBody } | Should -Throw '*late Default Switch collision*'

        Assert-MockCalled Write-Log -Times 0 -ParameterFilter { $Message -eq '[Start-System] finished' }
    }
}

Describe 'Remove-K2sDefaultSwitch' -Tag 'unit', 'ci', 'network' {
    BeforeEach {
        Mock Write-Log -ModuleName windows-host-network.module
        Mock Import-K2sHnsModule -ModuleName windows-host-network.module
        Mock Get-HnsNetwork -ModuleName windows-host-network.module
        Mock Remove-HnsNetwork -ModuleName windows-host-network.module
        Mock Get-VMSwitch -ModuleName windows-host-network.module
        Mock Remove-VMSwitch -ModuleName windows-host-network.module
    }

    It 'removes the Default Switch through HNS' {
        Mock Get-HnsNetwork -ModuleName windows-host-network.module {
            [pscustomobject]@{ Name = 'Default Switch'; Id = 'default-switch-id' }
        }

        & (Get-Module windows-host-network.module) { Remove-K2sDefaultSwitch }

        Assert-MockCalled Import-K2sHnsModule -ModuleName windows-host-network.module -Times 1 -Exactly
        Assert-MockCalled Remove-HnsNetwork -ModuleName windows-host-network.module -Times 1 -Exactly -ParameterFilter {
            $InputObjects.Id -eq 'default-switch-id'
        }
        Assert-MockCalled Remove-VMSwitch -ModuleName windows-host-network.module -Times 0
    }

    It 'uses Hyper-V removal when no HNS Default Switch exists' {
        Mock Get-VMSwitch -ModuleName windows-host-network.module {
            [pscustomobject]@{ Name = 'Default Switch' }
        }

        & (Get-Module windows-host-network.module) { Remove-K2sDefaultSwitch }

        Assert-MockCalled Remove-HnsNetwork -ModuleName windows-host-network.module -Times 0
        Assert-MockCalled Remove-VMSwitch -ModuleName windows-host-network.module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Default Switch' -and $Force
        }
    }

    It 'throws when the conflicting switch cannot be found for removal' {
        { & (Get-Module windows-host-network.module) { Remove-K2sDefaultSwitch } } |
            Should -Throw '*could not be found through HNS or Hyper-V*'
    }

    It 'continues to revalidation when HNS removal succeeds but Hyper-V reports a stale switch' {
        Mock Get-HnsNetwork -ModuleName windows-host-network.module {
            [pscustomobject]@{ Name = 'Default Switch'; Id = 'default-switch-id' }
        }
        Mock Get-VMSwitch -ModuleName windows-host-network.module {
            [pscustomobject]@{ Name = 'Default Switch' }
        }
        Mock Remove-VMSwitch -ModuleName windows-host-network.module {
            throw 'Default Switch is managed by Windows'
        }

        { & (Get-Module windows-host-network.module) { Remove-K2sDefaultSwitch } } | Should -Not -Throw

        Assert-MockCalled Remove-HnsNetwork -ModuleName windows-host-network.module -Times 1 -Exactly
        Assert-MockCalled Remove-VMSwitch -ModuleName windows-host-network.module -Times 1 -Exactly
    }
}
