# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $modulePath = "$PSScriptRoot/windows-worker-node.module.psm1"
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    foreach ($functionName in @('Set-RoutesToKubemaster', 'Test-NetworkL2BridgeReady')) {
        $functionAst = $moduleAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $false)
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    function Get-ConfiguredControlPlaneCIDR { '172.19.1.0/24' }
    function Get-ConfiguredKubeSwitchIP { '172.19.1.1' }
    function Get-L2BridgeSwitchName { 'cbr0' }
    function Get-ConfiguredClusterCIDRNextHop { param($PodSubnetworkNumber) '172.20.1.2' }
    function Get-ConfiguredClusterCIDRHost { param($PodSubnetworkNumber) '172.20.1.0/24' }
    function Write-Log { param($Message) }
    function Get-NetAdapter { [CmdletBinding()] param($Name, [switch]$IncludeHidden) }
    function Get-NetIPAddress { [CmdletBinding()] param($IPAddress, $InterfaceIndex, $AddressFamily) }
    function Get-NetRoute { [CmdletBinding()] param($AddressFamily, $PolicyStore, $DestinationPrefix, $InterfaceIndex) }
    function New-NetRoute { [CmdletBinding()] param($DestinationPrefix, $InterfaceIndex, $NextHop, $RouteMetric, $PolicyStore) }
    function Remove-NetRoute { [CmdletBinding(SupportsShouldProcess)] param([Parameter(ValueFromPipeline)]$InputObject) }
    function Enable-NetAdapter { [CmdletBinding(SupportsShouldProcess)] param($Name) }
}

Describe 'Set-RoutesToKubemaster' -Tag 'unit', 'ci', 'network' {
    BeforeEach {
        Mock Write-Log {}
        Mock Get-NetIPAddress { [pscustomobject]@{ InterfaceIndex = 27 } }
        Mock Get-NetRoute {}
        Mock New-NetRoute {}
        Mock Remove-NetRoute {}
    }

    It 'creates a missing on-link route on the configured host IP interface' {
        Set-RoutesToKubemaster

        Should -Invoke Get-NetIPAddress -Times 1 -Exactly -ParameterFilter { $IPAddress -eq '172.19.1.1' -and $AddressFamily -eq 'IPv4' }
        Should -Invoke New-NetRoute -Times 1 -Exactly -ParameterFilter {
            $DestinationPrefix -eq '172.19.1.0/24' -and $InterfaceIndex -eq 27 -and
            $NextHop -eq '0.0.0.0' -and $PolicyStore -eq 'ActiveStore'
        }
        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }

    It 'preserves the connected route and removes only legacy routes from both stores' {
        Mock Get-NetRoute {
            [pscustomobject]@{ DestinationPrefix = '172.19.1.0/24'; InterfaceIndex = 27; NextHop = '0.0.0.0' }
            [pscustomobject]@{ DestinationPrefix = '172.19.1.0/24'; InterfaceIndex = 9; NextHop = '172.19.1.1'; Store = $PolicyStore }
            [pscustomobject]@{ DestinationPrefix = '172.19.1.0/24'; InterfaceIndex = 9; NextHop = '172.22.7.1' }
            [pscustomobject]@{ DestinationPrefix = '172.19.1.100/32'; InterfaceIndex = 27; NextHop = '0.0.0.0' }
            [pscustomobject]@{ DestinationPrefix = '172.22.0.0/16'; InterfaceIndex = 9; NextHop = '172.19.1.1' }
        }

        Set-RoutesToKubemaster

        Should -Invoke New-NetRoute -Times 0 -Exactly
        Should -Invoke Remove-NetRoute -Times 2 -Exactly
        Should -Invoke Remove-NetRoute -Times 1 -Exactly -ParameterFilter {
            $InputObject.DestinationPrefix -eq '172.19.1.0/24' -and $InputObject.NextHop -eq '172.19.1.1' -and $InputObject.Store -eq 'PersistentStore'
        }
        Should -Invoke Remove-NetRoute -Times 1 -Exactly -ParameterFilter {
            $InputObject.DestinationPrefix -eq '172.19.1.0/24' -and $InputObject.NextHop -eq '172.19.1.1' -and $InputObject.Store -eq 'ActiveStore'
        }
    }


    It 'accepts an empty persistent store during Windows-hosted Linux-only startup' {
        Mock Get-NetRoute {
            if ($AddressFamily) {
                throw "No MSFT_NetRoute objects found with property 'AddressFamily' equal to 'IPv4'"
            }
            if ($PolicyStore -eq 'ActiveStore') {
                [pscustomobject]@{ DestinationPrefix = '172.19.1.0/24'; InterfaceIndex = 27; NextHop = '0.0.0.0' }
            }
        }

        Set-RoutesToKubemaster

        Should -Invoke Get-NetRoute -Times 1 -Exactly -ParameterFilter { $PolicyStore -eq 'PersistentStore' -and -not $AddressFamily }
        Should -Invoke Get-NetRoute -Times 0 -Exactly -ParameterFilter { $AddressFamily }
        Should -Invoke New-NetRoute -Times 0 -Exactly
        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }

    It 'restores the on-link route when stores contain only unrelated IPv6 routes' {
        Mock Get-NetRoute {
            if ($AddressFamily) {
                throw "No MSFT_NetRoute objects found with property 'AddressFamily' equal to 'IPv4'"
            }
            [pscustomobject]@{ DestinationPrefix = 'fe80::/64'; InterfaceIndex = 27; NextHop = '::' }
        }

        Set-RoutesToKubemaster

        Should -Invoke New-NetRoute -Times 1 -Exactly -ParameterFilter {
            $DestinationPrefix -eq '172.19.1.0/24' -and $InterfaceIndex -eq 27 -and $NextHop -eq '0.0.0.0'
        }
        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }

    It 'propagates genuine persistent-store query failures' {
        Mock Get-NetRoute {
            if ($PolicyStore -eq 'PersistentStore') {
                throw 'Access denied reading route store'
            }
            [pscustomobject]@{ DestinationPrefix = '172.19.1.0/24'; InterfaceIndex = 27; NextHop = '0.0.0.0' }
        }

        { Set-RoutesToKubemaster } | Should -Throw '*Access denied reading route store*'

        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }

    It 'uses the current interface index after switch recreation or for WSL' {
        Mock Get-NetIPAddress { [pscustomobject]@{ InterfaceIndex = 42 } }

        Set-RoutesToKubemaster

        Should -Invoke New-NetRoute -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 42 }
    }

    It 'does not mutate routes when the switch address is missing' {
        Mock Get-NetIPAddress {}

        { Set-RoutesToKubemaster } | Should -Throw '*unique control-plane switch interface*'

        Should -Invoke New-NetRoute -Times 0 -Exactly
        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }

    It 'does not mutate routes when the switch address is ambiguous' {
        Mock Get-NetIPAddress {
            [pscustomobject]@{ InterfaceIndex = 27 }
            [pscustomobject]@{ InterfaceIndex = 42 }
        }

        { Set-RoutesToKubemaster } | Should -Throw '*unique control-plane switch interface*'

        Should -Invoke New-NetRoute -Times 0 -Exactly
        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }

    It 'does not remove routes if restoring the connected route fails' {
        Mock New-NetRoute { throw 'route creation failed' }

        { Set-RoutesToKubemaster } | Should -Throw '*route creation failed*'

        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }

    It 'accepts a concurrently created route for duplicate error <ErrorId>' -TestCases @(
        @{ ErrorId = 'CimAlreadyExists'; Category = 'ResourceExists' }
        @{ ErrorId = 'Windows System Error 183,New-NetRoute'; Category = 'NotSpecified' }
        @{ ErrorId = 'Windows System Error 5010,New-NetRoute'; Category = 'NotSpecified' }
    ) {
        param($ErrorId, $Category)
        $script:routeCreated = $false
        Mock New-NetRoute {
            $script:routeCreated = $true
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('Instance MSFT_NetRoute already exists'),
                $ErrorId, [System.Management.Automation.ErrorCategory]$Category, $null)
        }
        Mock Get-NetRoute {
            if ($script:routeCreated -and $PolicyStore -eq 'ActiveStore') {
                [pscustomobject]@{ DestinationPrefix = '172.19.1.0/24'; InterfaceIndex = 27; NextHop = '0.0.0.0' }
            }
        }

        Set-RoutesToKubemaster

        Should -Invoke New-NetRoute -Times 1 -Exactly
        Should -Invoke Get-NetRoute -Times 3 -Exactly -ParameterFilter { $PolicyStore -eq 'ActiveStore' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like '*created concurrently*' }
    }

    It 'rejects a duplicate error without the expected active route: <Reason>' -TestCases @(
        @{ Reason = 'missing'; Prefix = $null; Index = 27; NextHop = '0.0.0.0'; Store = 'ActiveStore' }
        @{ Reason = 'wrong prefix'; Prefix = '172.22.0.0/16'; Index = 27; NextHop = '0.0.0.0'; Store = 'ActiveStore' }
        @{ Reason = 'wrong interface'; Prefix = '172.19.1.0/24'; Index = 42; NextHop = '0.0.0.0'; Store = 'ActiveStore' }
        @{ Reason = 'gateway route'; Prefix = '172.19.1.0/24'; Index = 27; NextHop = '172.22.7.1'; Store = 'ActiveStore' }
        @{ Reason = 'persistent only'; Prefix = '172.19.1.0/24'; Index = 27; NextHop = '0.0.0.0'; Store = 'PersistentStore' }
    ) {
        param($Reason, $Prefix, $Index, $NextHop, $Store)
        $script:routeCreated = $false
        Mock New-NetRoute {
            $script:routeCreated = $true
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('Instance MSFT_NetRoute already exists'),
                'CimAlreadyExists', [System.Management.Automation.ErrorCategory]::ResourceExists, $null)
        }
        Mock Get-NetRoute {
            if ($script:routeCreated -and $Prefix -and $PolicyStore -eq $Store) {
                [pscustomobject]@{ DestinationPrefix = $Prefix; InterfaceIndex = $Index; NextHop = $NextHop }
            }
        }

        { Set-RoutesToKubemaster } | Should -Throw '*MSFT_NetRoute already exists*'

        Should -Invoke Remove-NetRoute -Times 0 -Exactly
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Message -like '*created concurrently*' }
    }

    It 'propagates non-duplicate creation errors even if a matching route appears' {
        $script:routeCreated = $false
        Mock New-NetRoute {
            $script:routeCreated = $true
            throw 'Access denied creating route'
        }
        Mock Get-NetRoute {
            if ($script:routeCreated) {
                [pscustomobject]@{ DestinationPrefix = '172.19.1.0/24'; InterfaceIndex = 27; NextHop = '0.0.0.0' }
            }
        }

        { Set-RoutesToKubemaster } | Should -Throw '*Access denied creating route*'

        Should -Invoke Get-NetRoute -Times 1 -Exactly
        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }

    It 'propagates route-store query failures after a duplicate creation error' {
        $script:routeCreated = $false
        Mock New-NetRoute {
            $script:routeCreated = $true
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('Instance MSFT_NetRoute already exists'),
                'CimAlreadyExists', [System.Management.Automation.ErrorCategory]::ResourceExists, $null)
        }
        Mock Get-NetRoute {
            if ($script:routeCreated) {
                throw 'Access denied re-reading route store'
            }
        }

        { Set-RoutesToKubemaster } | Should -Throw '*Access denied re-reading route store*'

        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }
}

Describe 'Test-NetworkL2BridgeReady' -Tag 'unit', 'ci', 'network' {
    BeforeEach {
        Mock Write-Log {}
        Mock Get-NetAdapter { [pscustomobject]@{ Name = 'vEthernet (cbr0_ep)'; ifIndex = 31; Status = 'Up' } }
        Mock Get-NetIPAddress { [pscustomobject]@{ IPAddress = '172.20.1.2'; InterfaceIndex = 31 } }
        Mock Get-NetRoute { [pscustomobject]@{ DestinationPrefix = '172.20.1.0/24'; InterfaceIndex = 31; NextHop = '0.0.0.0' } }
        Mock New-NetRoute {}
        Mock Enable-NetAdapter {}
    }

    It 'accepts only the exact healthy cbr0 endpoint and route' {
        Test-NetworkL2BridgeReady -PodSubnetworkNumber '1' | Should -BeTrue

        Should -Invoke Get-NetAdapter -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'vEthernet (cbr0_ep)' -and $IncludeHidden
        }
        Should -Invoke Get-NetIPAddress -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 31 -and $AddressFamily -eq 'IPv4' }
        Should -Invoke Get-NetRoute -Times 1 -Exactly -ParameterFilter {
            $DestinationPrefix -eq '172.20.1.0/24' -and $InterfaceIndex -eq 31 -and $PolicyStore -eq 'ActiveStore'
        }
        Should -Invoke New-NetRoute -Times 0 -Exactly
    }

    It 'accepts a disconnected HNS endpoint with the expected address and route' {
        Mock Get-NetAdapter { [pscustomobject]@{ Name = 'vEthernet (cbr0_ep)'; ifIndex = 31; Status = 'Disconnected' } }

        Test-NetworkL2BridgeReady -PodSubnetworkNumber '1' | Should -BeTrue

        Should -Invoke Get-NetIPAddress -Times 1 -Exactly
        Should -Invoke New-NetRoute -Times 0 -Exactly
    }

    It 'rejects an endpoint without the expected bridge address' {
        Mock Get-NetIPAddress { [pscustomobject]@{ IPAddress = '172.20.1.99'; InterfaceIndex = 31 } }

        Test-NetworkL2BridgeReady -PodSubnetworkNumber '1' | Should -BeFalse

        Should -Invoke New-NetRoute -Times 0 -Exactly
    }

    It 'repairs a missing active on-link route' {
        Mock Get-NetRoute {}

        Test-NetworkL2BridgeReady -PodSubnetworkNumber '1' | Should -BeTrue

        Should -Invoke New-NetRoute -Times 1 -Exactly -ParameterFilter {
            $DestinationPrefix -eq '172.20.1.0/24' -and $InterfaceIndex -eq 31 -and
            $NextHop -eq '0.0.0.0' -and $PolicyStore -eq 'ActiveStore'
        }
    }

    It 'enables a disabled endpoint before validating it' {
        $script:adapterQuery = 0
        Mock Get-NetAdapter {
            $script:adapterQuery++
            if ($script:adapterQuery -eq 1) {
                return [pscustomobject]@{ Name = 'vEthernet (cbr0_ep)'; ifIndex = 31; Status = 'Disabled' }
            }
            return [pscustomobject]@{ Name = 'vEthernet (cbr0_ep)'; ifIndex = 31; Status = 'Up' }
        }

        Test-NetworkL2BridgeReady -PodSubnetworkNumber '1' | Should -BeTrue

        Should -Invoke Enable-NetAdapter -Times 1 -Exactly -ParameterFilter { $Name -eq 'vEthernet (cbr0_ep)' }
        Should -Invoke Get-NetAdapter -Times 2 -Exactly -ParameterFilter { $IncludeHidden }
    }
}
