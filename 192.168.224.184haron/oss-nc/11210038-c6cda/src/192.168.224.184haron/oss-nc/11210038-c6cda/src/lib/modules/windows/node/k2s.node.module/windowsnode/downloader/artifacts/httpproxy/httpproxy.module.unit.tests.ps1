# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $modulePath = "$PSScriptRoot/httpproxy.module.psm1"
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    foreach ($functionName in 'Get-HttpProxyAllowedCIDRs', 'Set-ProxyConfigInHttpProxy', 'Install-WinHttpProxy') {
        $functionAst = $moduleAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $false)
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    $httpProxyPort = '8181'
    $proxyInboundFirewallRule = "HTTP Proxy Inbound Allow Port $httpProxyPort"

    # The module calls nssm by path; a script with the same name records the calls instead.
    $kubeBinPath = $TestDrive
    Set-Content -Path (Join-Path $TestDrive 'nssm.ps1') -Value '$global:nssmCalls.Add(($args -join " ")) | Out-Null'

    function Write-Log { param($Message) }
    function Get-ConfiguredClusterCIDR { }
    function Get-ConfiguredClusterCIDRServices { }
    function Get-ConfiguredControlPlaneCIDR { }
    function Get-LoopbackAdapterCIDR { }
    function Get-K2sHosts { }
    function Get-ConfiguredLogDirectory { }
    function Remove-ServiceIfExists { param($Name) }
    function Get-Service { [CmdletBinding()] param($Name) }
    function Start-Service { param($Name) }
    function New-NetFirewallRule {
        [CmdletBinding()]
        param($DisplayName, $Group, $Direction, $LocalPort, $Protocol, $RemoteAddress, $Action)
    }
}

Describe 'Get-HttpProxyAllowedCIDRs' -Tag 'unit', 'ci', 'httpproxy' {
    BeforeEach {
        Mock Get-ConfiguredClusterCIDR { '172.20.0.0/16' }
        Mock Get-ConfiguredClusterCIDRServices { '172.21.0.0/16' }
        Mock Get-ConfiguredControlPlaneCIDR { '172.19.1.0/24' }
        Mock Get-LoopbackAdapterCIDR { '172.22.1.0/24' }
    }

    It 'returns the cluster, service, control plane and loopback adapter networks' {
        $result = @(Get-HttpProxyAllowedCIDRs)

        $result | Should -Be @('172.20.0.0/16', '172.21.0.0/16', '172.19.1.0/24', '172.22.1.0/24')
    }

    It 'skips networks that are not configured' {
        Mock Get-LoopbackAdapterCIDR { '' }

        $result = @(Get-HttpProxyAllowedCIDRs)

        $result | Should -Be @('172.20.0.0/16', '172.21.0.0/16', '172.19.1.0/24')
    }

    It 'fails instead of returning an empty whitelist' {
        Mock Get-ConfiguredClusterCIDR { $null }
        Mock Get-ConfiguredClusterCIDRServices { '' }
        Mock Get-ConfiguredControlPlaneCIDR { ' ' }
        Mock Get-LoopbackAdapterCIDR { $null }

        { Get-HttpProxyAllowedCIDRs } | Should -Throw '*No cluster network CIDR configured*'
    }
}

Describe 'Set-ProxyConfigInHttpProxy' -Tag 'unit', 'ci', 'httpproxy' {
    BeforeEach {
        $global:nssmCalls = [System.Collections.Generic.List[string]]::new()
        Mock Get-HttpProxyAllowedCIDRs { '172.20.0.0/16', '172.19.1.0/24' }
        Mock Get-K2sHosts { }
    }

    AfterAll {
        Remove-Variable -Name nssmCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'passes every allowed network to httpproxy' {
        Set-ProxyConfigInHttpProxy

        $global:nssmCalls | Should -Contain 'set httpproxy AppParameters --allowed-cidr 172.20.0.0/16 --allowed-cidr 172.19.1.0/24'
    }

    It 'appends the forward proxy after the allowed networks' {
        Set-ProxyConfigInHttpProxy -Proxy 'http://proxy.example:3128'

        $global:nssmCalls | Should -Contain 'set httpproxy AppParameters --allowed-cidr 172.20.0.0/16 --allowed-cidr 172.19.1.0/24 --forwardproxy http://proxy.example:3128'
    }
}

Describe 'Install-WinHttpProxy' -Tag 'unit', 'ci', 'httpproxy' {
    BeforeEach {
        $global:nssmCalls = [System.Collections.Generic.List[string]]::new()
        Mock Get-HttpProxyAllowedCIDRs { '172.20.0.0/16', '172.19.1.0/24' }
        Mock Get-K2sHosts { }
        Mock Get-ConfiguredLogDirectory { Join-Path $TestDrive 'log' }
        Mock mkdir { }
        Mock Remove-ServiceIfExists { }
        Mock Get-Service { [pscustomobject]@{ Name = 'httpproxy' } }
        Mock Start-Service { }
        Mock New-NetFirewallRule { }
    }

    AfterAll {
        Remove-Variable -Name nssmCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'allows inbound proxy connections only from the allowed networks' {
        Install-WinHttpProxy

        Should -Invoke New-NetFirewallRule -Exactly 1 -ParameterFilter {
            $DisplayName -eq 'HTTP Proxy Inbound Allow Port 8181' -and
            $Direction -eq 'Inbound' -and
            $LocalPort -eq '8181' -and
            $Action -eq 'Allow' -and
            (@($RemoteAddress) -join ',') -eq '172.20.0.0/16,172.19.1.0/24'
        }
    }
}
