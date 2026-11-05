# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    function Get-HnsNetwork {}
    function Remove-HnsNetwork {}
    Import-Module (Join-Path $PSScriptRoot 'windows-host-network.module.psm1') -Force
}

Describe 'Test-WslNetwork' -Tag 'unit', 'ci', 'network' {
    BeforeEach {
        Mock Write-Log -ModuleName windows-host-network.module
        Mock Import-K2sHnsModule -ModuleName windows-host-network.module
        Mock Remove-HnsNetwork -ModuleName windows-host-network.module
        Mock Get-ConfiguredK2sSubnets -ModuleName windows-host-network.module {
            @(
                @{ Name = 'masterNetworkCIDR'; Value = '172.19.1.0/24' },
                @{ Name = 'podNetworkCIDR'; Value = '172.20.0.0/16' },
                @{ Name = 'podNetworkMasterCIDR'; Value = '172.20.0.0/24' },
                @{ Name = 'podNetworkWorkerCIDR'; Value = '172.20.1.0/24' },
                @{ Name = 'servicesCIDR'; Value = '172.21.0.0/16' },
                @{ Name = 'servicesCIDRLinux'; Value = '172.21.0.0/24' },
                @{ Name = 'servicesCIDRWindows'; Value = '172.21.1.0/24' },
                @{ Name = 'loopbackAdapterCIDR'; Value = '172.22.1.0/24' }
            )
        }
        Mock Get-HnsNetwork -ModuleName windows-host-network.module {
            [pscustomobject]@{
                Name = 'WSL'; Id = 'wsl-network-id'
                Subnets = @([pscustomobject]@{ AddressPrefix = '192.168.128.0/20' })
            }
        }
    }

    AfterEach {
        Should -Invoke Remove-HnsNetwork -ModuleName windows-host-network.module -Times 0
    }

    It 'accepts a non-overlapping HNS subnet and logs its identity' {
        Test-WslNetwork

        Should -Invoke Get-HnsNetwork -ModuleName windows-host-network.module -Times 1 -Exactly -ParameterFilter {
            $ErrorAction -eq 'Stop'
        }
        Should -Invoke Write-Log -ModuleName windows-host-network.module -Times 1 -Exactly -ParameterFilter {
            ($Messages -join ' ') -like '*WSL*wsl-network-id*192.168.128.0/20*'
        }
    }

    It 'rejects <Cidr> overlapping <Name>' -TestCases @(
        @{ Cidr = '172.19.0.0/20'; Name = 'masterNetworkCIDR' },
        @{ Cidr = '172.20.0.0/20'; Name = 'podNetworkMasterCIDR' },
        @{ Cidr = '172.20.1.0/24'; Name = 'podNetworkWorkerCIDR' },
        @{ Cidr = '172.21.0.0/20'; Name = 'servicesCIDRLinux' },
        @{ Cidr = '172.21.1.0/24'; Name = 'servicesCIDRWindows' },
        @{ Cidr = '172.22.0.0/20'; Name = 'loopbackAdapterCIDR' },
        @{ Cidr = '172.19.1.128/25'; Name = 'masterNetworkCIDR' }
    ) {
        param($Cidr, $Name)
        Mock Get-HnsNetwork -ModuleName windows-host-network.module {
            [pscustomobject]@{
                Name = 'WSL'; Id = 'wsl-network-id'
                Subnets = @([pscustomobject]@{ AddressPrefix = $Cidr })
            }
        }

        { Test-WslNetwork } | Should -Throw "*$Cidr overlaps K2s $Name*"
        Should -Invoke Write-Log -ModuleName windows-host-network.module -Times 1 -Exactly -ParameterFilter {
            ($Messages -join ' ') -like '*Changing only the host adapter IP does not change the HNS subnet*'
        }
    }

    It 'warns but does not reject aggregate-only overlap with <Cidr>' -TestCases @(
        @{ Cidr = '172.20.128.0/20' },
        @{ Cidr = '172.21.128.0/20' }
    ) {
        param($Cidr)
        Mock Get-HnsNetwork -ModuleName windows-host-network.module {
            [pscustomobject]@{
                Name = 'WSL'; Id = 'wsl-network-id'
                Subnets = @([pscustomobject]@{ AddressPrefix = $Cidr })
            }
        }

        { Test-WslNetwork } | Should -Not -Throw
        Should -Invoke Write-Log -ModuleName windows-host-network.module -Times 1 -Exactly -ParameterFilter {
            $Console -and ($Messages -join ' ') -like '*WARNING*Aggregate overlap alone*'
        }
    }

    It 'ignores unrelated HNS networks' {
        Mock Get-HnsNetwork -ModuleName windows-host-network.module {
            [pscustomobject]@{
                Name = 'WSL'; Id = 'wsl-network-id'
                Subnets = @([pscustomobject]@{ AddressPrefix = '192.168.128.0/20' })
            }
            [pscustomobject]@{
                Name = 'cbr0'; Id = 'bridge-id'
                Subnets = @([pscustomobject]@{ AddressPrefix = '172.20.1.0/24' })
            }
        }

        { Test-WslNetwork } | Should -Not -Throw
    }

    It 'checks all WSL networks and every subnet' {
        Mock Get-HnsNetwork -ModuleName windows-host-network.module {
            [pscustomobject]@{
                Name = 'WSL'; Id = 'first-id'
                Subnets = @([pscustomobject]@{ AddressPrefix = '192.168.128.0/20' })
            }
            [pscustomobject]@{
                Name = 'WSL (Hyper-V firewall)'; Id = 'second-id'
                Subnets = @(
                    [pscustomobject]@{ AddressPrefix = '192.168.144.0/20' },
                    [pscustomobject]@{ AddressPrefix = '172.19.0.0/20' }
                )
            }
        }

        { Test-WslNetwork } | Should -Throw '*WSL (Hyper-V firewall)*172.19.0.0/20 overlaps K2s masterNetworkCIDR*'
    }

    It 'fails closed when the WSL HNS network is missing' {
        Mock Get-HnsNetwork -ModuleName windows-host-network.module

        { Test-WslNetwork } | Should -Throw '*No WSL HNS network found*'
    }

    It 'fails closed when WSL subnet information is unavailable' -TestCases @(
        @{ Subnets = $null },
        @{ Subnets = @() }
    ) {
        param($Subnets)
        Mock Get-HnsNetwork -ModuleName windows-host-network.module {
            [pscustomobject]@{ Name = 'WSL'; Id = 'wsl-network-id'; Subnets = $Subnets }
        }

        { Test-WslNetwork } | Should -Throw '*has no inspectable subnets*'
    }

    It 'rejects invalid HNS CIDR <Cidr>' -TestCases @(
        @{ Cidr = '' },
        @{ Cidr = 'not-a-subnet' },
        @{ Cidr = '172.19.0.0' },
        @{ Cidr = '172.19.0.0/33' },
        @{ Cidr = '172.19.0.0/-1' },
        @{ Cidr = '999.19.0.0/20' },
        @{ Cidr = 'fd00::/64' }
    ) {
        param($Cidr)
        Mock Get-HnsNetwork -ModuleName windows-host-network.module {
            [pscustomobject]@{
                Name = 'WSL'; Id = 'wsl-network-id'
                Subnets = @([pscustomobject]@{ AddressPrefix = $Cidr })
            }
        }

        { Test-WslNetwork } | Should -Throw '*Cannot validate HNS*expected an IPv4 CIDR*'
    }

    It 'rejects missing or malformed configured subnets' -TestCases @(
        @{ Cidr = $null },
        @{ Cidr = '172.19.1.0/99' }
    ) {
        param($Cidr)
        Mock Get-ConfiguredK2sSubnets -ModuleName windows-host-network.module {
            @{ Name = 'masterNetworkCIDR'; Value = $Cidr }
        }

        { Test-WslNetwork } | Should -Throw '*Cannot validate K2s masterNetworkCIDR*'
    }

    It 'propagates HNS query failures' {
        Mock Get-HnsNetwork -ModuleName windows-host-network.module { throw 'HNS query failed' }

        { Test-WslNetwork } | Should -Throw '*HNS query failed*'
    }

    It 'uses configured CIDRs rather than assuming the default ranges' {
        Mock Get-ConfiguredK2sSubnets -ModuleName windows-host-network.module {
            @{ Name = 'masterNetworkCIDR'; Value = '192.168.130.0/24' }
        }

        { Test-WslNetwork } | Should -Throw '*192.168.128.0/20 overlaps K2s masterNetworkCIDR 192.168.130.0/24*'
    }
}

Describe 'Set-WSLSwitch validation ordering' -Tag 'unit', 'ci', 'network' {
    BeforeAll {
        function Write-Log { param($Message) }
        function Test-WslNetwork {}
        function netsh {}

        $networkPath = Join-Path $PSScriptRoot '..\..\..\node\k2s.node.module\windowsnode\network\network.module.psm1'
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($networkPath, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw ($parseErrors | Out-String)
        }
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-WSLSwitch'
        }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }

    BeforeEach {
        Mock Write-Log
        Mock Start-Sleep
        Mock Get-NetAdapter { [pscustomobject]@{ ifIndex = 33; Name = 'vEthernet (WSL)' } }
        Mock Get-NetIPAddress { [pscustomobject]@{ IPAddress = '172.19.0.1' } }
        Mock Get-NetIPInterface {
            [pscustomobject]@{ ifIndex = 33; InterfaceAlias = 'vEthernet (WSL)'; AddressFamily = 'IPv4' }
        }
        Mock Test-WslNetwork
        Mock Remove-NetIPAddress
        Mock New-NetIPAddress
        Mock Set-NetIPInterface
        Mock netsh
    }

    It 'does not mutate the adapter when HNS validation fails' {
        Mock Test-WslNetwork { throw '[PREREQ-FAILED] WSL overlap' }

        { Set-WSLSwitch -IpAddress '172.19.1.1' } | Should -Throw '*WSL overlap*'

        Should -Invoke Remove-NetIPAddress -Times 0
        Should -Invoke New-NetIPAddress -Times 0
        Should -Invoke Set-NetIPInterface -Times 0
        Should -Invoke netsh -Times 0
    }

    It 'validates before removing addresses and preserves normal adapter configuration' {
        $script:wslValidated = $false
        Mock Test-WslNetwork { $script:wslValidated = $true }
        Mock Remove-NetIPAddress { $script:wslValidated | Should -BeTrue }
        Mock New-NetIPAddress { $script:wslValidated | Should -BeTrue }

        Set-WSLSwitch -IpAddress '172.19.1.1'

        Should -Invoke Test-WslNetwork -Times 1 -Exactly
        Should -Invoke Remove-NetIPAddress -Times 1 -Exactly
        Should -Invoke New-NetIPAddress -Times 1 -Exactly -ParameterFilter {
            $IpAddress -eq '172.19.1.1' -and $PrefixLength -eq 24 -and $InterfaceAlias -eq 'vEthernet (WSL)'
        }
        Should -Invoke Set-NetIPInterface -Times 1 -Exactly
        Should -Invoke netsh -Times 1 -Exactly
    }
}
