# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $scriptPath = "$PSScriptRoot\AddProxyOverride.ps1"

    function global:Initialize-Logging { }

    function global:Add-NoProxyEntry { param($Entries) }
    function global:Get-ProxyConfig {
        return [PSCustomObject]@{
            HttpProxy = 'http://proxy.example.com:8080'
            HttpsProxy = 'http://proxy.example.com:8080'
            NoProxy = @('localhost', '127.0.0.1', '*.example.com')
        }
    }
    function global:Get-K2sHosts { return @('172.19.1.100', '172.19.1.1', '.local', '.cluster.local') }
    function global:Stop-WinHttpProxy { }
    function global:Start-WinHttpProxy { }
    function global:Set-ProxyConfigInHttpProxy { param($Proxy, $ProxyOverrides) }
    function global:Send-ToCli { param($MessageType, $Message) }
    function global:Write-Log { param([string]$Message, [switch]$Error) }

    Mock -CommandName Import-Module { }
    Mock -CommandName Initialize-Logging { }
}

Describe 'AddProxyOverride.ps1' -Tag 'unit', 'ci', 'proxy' {

    Context 'Parameter validation' {
        BeforeEach {
            Mock -CommandName Add-NoProxyEntry { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = 'http://proxy.test:8080'; NoProxy = @('localhost') }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'accepts single override entry' {
            { & $scriptPath -Overrides '*.internal.com' } | Should -Not -Throw
        }

        It 'accepts multiple override entries as array' {
            { & $scriptPath -Overrides @('*.internal.com', '192.168.1.0/24', 'intranet.local') } | Should -Not -Throw
        }

        It 'accepts ShowLogs switch parameter' {
            { & $scriptPath -Overrides '*.test.com' -ShowLogs } | Should -Not -Throw
        }

        It 'accepts EncodeStructuredOutput switch parameter' {
            { & $scriptPath -Overrides '*.test.com' -EncodeStructuredOutput -MessageType 'Test' } | Should -Not -Throw
        }
    }

    Context 'Module imports' {
        BeforeEach {
            Mock -CommandName Add-NoProxyEntry { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = 'http://proxy.test:8080'; NoProxy = @() }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'imports infra module' {
            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Import-Module -ParameterFilter {
                $Name -like '*k2s.infra.module.psm1'
            }
        }

        It 'imports node module' {
            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Import-Module -ParameterFilter {
                $Name -like '*k2s.node.module.psm1'
            }
        }

        It 'initializes logging' {
            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Initialize-Logging -Exactly 1
        }
    }

    Context 'Adding proxy overrides' {
        BeforeEach {
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost', '127.0.0.1', '*.example.com')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('172.19.1.100', '.local') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'calls Add-NoProxyEntry with single override' {
            Mock -CommandName Add-NoProxyEntry { }
            $override = '*.company.com'

            & $scriptPath -Overrides $override

            Should -Invoke Add-NoProxyEntry -Exactly 1 -ParameterFilter {
                $Entries.Count -eq 1 -and
                $Entries[0] -eq $override
            }
        }

        It 'calls Add-NoProxyEntry with multiple overrides' {
            Mock -CommandName Add-NoProxyEntry { }
            $overrides = @('*.internal.com', '10.0.0.0/8', 'localhost')

            & $scriptPath -Overrides $overrides

            Should -Invoke Add-NoProxyEntry -Exactly 1 -ParameterFilter {
                $Entries.Count -eq 3 -and
                $Entries -contains '*.internal.com' -and
                $Entries -contains '10.0.0.0/8' -and
                $Entries -contains 'localhost'
            }
        }

        It 'stops WinHttpProxy before updating configuration' {
            Mock -CommandName Add-NoProxyEntry { }

            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Stop-WinHttpProxy -Exactly 1
        }

        It 'retrieves updated proxy configuration after adding overrides' {
            Mock -CommandName Add-NoProxyEntry { }

            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Get-ProxyConfig -Exactly 1
        }

        It 'retrieves K2s hosts for NoProxy merging' {
            Mock -CommandName Add-NoProxyEntry { }

            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Get-K2sHosts -Exactly 1
        }
    }

    Context 'NoProxy hosts merging after override addition' {
        BeforeEach {
            Mock -CommandName Add-NoProxyEntry { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'merges updated NoProxy with K2s hosts' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost', '*.example.com', '*.newly-added.com')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('172.19.1.100', '.local') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }

            & $scriptPath -Overrides '*.newly-added.com'

            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $ProxyOverrides -contains 'localhost' -and
                $ProxyOverrides -contains '*.example.com' -and
                $ProxyOverrides -contains '*.newly-added.com' -and
                $ProxyOverrides -contains '172.19.1.100' -and
                $ProxyOverrides -contains '.local'
            }
        }

        It 'removes duplicate entries from merged NoProxy list' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost', '*.example.com')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost', '.local') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }

            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                ($ProxyOverrides | Where-Object { $_ -eq 'localhost' } | Measure-Object).Count -eq 1
            }
        }

        It 'handles empty NoProxy after override addition' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @()
                }
            }
            Mock -CommandName Get-K2sHosts { return @('172.19.1.100', '.local') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }

            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $ProxyOverrides -contains '172.19.1.100' -and
                $ProxyOverrides -contains '.local'
            }
        }
    }

    Context 'WinHttpProxy configuration' {
        BeforeEach {
            Mock -CommandName Add-NoProxyEntry { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'configures WinHttpProxy with updated proxy and merged NoProxy' {
            Mock -CommandName Set-ProxyConfigInHttpProxy { }

            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $Proxy -eq 'http://proxy.example.com:8080'
            }
        }

        It 'starts WinHttpProxy service after configuration' {
            Mock -CommandName Start-WinHttpProxy { }

            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Start-WinHttpProxy -Exactly 1
        }
    }

    Context 'Structured output' {
        BeforeEach {
            Mock -CommandName Add-NoProxyEntry { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = 'http://proxy.test:8080'; NoProxy = @('localhost') }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Write-Log { }
        }

        It 'sends structured output when EncodeStructuredOutput is set' {
            Mock -CommandName Send-ToCli { }

            & $scriptPath -Overrides '*.test.com' -EncodeStructuredOutput -MessageType 'AddOverrideResult'

            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $MessageType -eq 'AddOverrideResult' -and
                $Message.Error -eq $null
            }
        }

        It 'does not send structured output by default' {
            Mock -CommandName Send-ToCli { }

            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Send-ToCli -Exactly 0
        }
    }

    Context 'Error handling' {
        BeforeEach {
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = 'http://proxy.test:8080'; NoProxy = @('localhost') }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'throws exception when Add-NoProxyEntry fails' {
            Mock -CommandName Add-NoProxyEntry { throw 'Entry addition failed' }

            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Entry addition failed*'
        }

        It 'throws exception when Stop-WinHttpProxy fails' {
            Mock -CommandName Add-NoProxyEntry { }
            Mock -CommandName Stop-WinHttpProxy { throw 'Service stop failed' }

            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Service stop failed*'
        }

        It 'throws exception when Get-ProxyConfig fails' {
            Mock -CommandName Add-NoProxyEntry { }
            Mock -CommandName Get-ProxyConfig { throw 'Failed to read config' }

            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Failed to read config*'
        }

        It 'throws exception when Set-ProxyConfigInHttpProxy fails' {
            Mock -CommandName Add-NoProxyEntry { }
            Mock -CommandName Set-ProxyConfigInHttpProxy { throw 'Configuration update failed' }

            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Configuration update failed*'
        }

        It 'throws exception when Start-WinHttpProxy fails' {
            Mock -CommandName Add-NoProxyEntry { }
            Mock -CommandName Start-WinHttpProxy { throw 'Service start failed' }

            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Service start failed*'
        }
    }
}

