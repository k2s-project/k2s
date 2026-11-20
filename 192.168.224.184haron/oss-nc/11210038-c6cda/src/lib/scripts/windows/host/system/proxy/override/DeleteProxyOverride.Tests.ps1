# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $scriptPath = "$PSScriptRoot\DeleteProxyOverride.ps1"

    function global:Initialize-Logging { }

    function global:Remove-NoProxyEntry { param($Entries) }
    function global:Get-ProxyConfig {
        return [PSCustomObject]@{
            HttpProxy = 'http://proxy.example.com:8080'
            HttpsProxy = 'http://proxy.example.com:8080'
            NoProxy = @('localhost', '127.0.0.1')
        }
    }
    function global:Stop-WinHttpProxy { }
    function global:Start-WinHttpProxy { }
    function global:Set-ProxyConfigInHttpProxy { param($Proxy, $ProxyOverrides) }
    function global:Send-ToCli { param($MessageType, $Message) }
    function global:Write-Log { param([string]$Message, [switch]$Error) }

    Mock -CommandName Import-Module { }
    Mock -CommandName Initialize-Logging { }
}

Describe 'DeleteProxyOverride.ps1' -Tag 'unit', 'ci', 'proxy' {

    Context 'Parameter validation' {
        BeforeEach {
            Mock -CommandName Remove-NoProxyEntry { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = 'http://proxy.test:8080'; NoProxy = @('localhost') }
            }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'accepts single override entry to delete' {
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
            Mock -CommandName Remove-NoProxyEntry { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = 'http://proxy.test:8080'; NoProxy = @() }
            }
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

    Context 'Deleting proxy overrides' {
        BeforeEach {
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost', '127.0.0.1')
                }
            }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'calls Remove-NoProxyEntry with single override' {
            Mock -CommandName Remove-NoProxyEntry { }
            $override = '*.company.com'

            & $scriptPath -Overrides $override

            Should -Invoke Remove-NoProxyEntry -Exactly 1 -ParameterFilter {
                $Entries.Count -eq 1 -and
                $Entries[0] -eq $override
            }
        }

        It 'calls Remove-NoProxyEntry with multiple overrides' {
            Mock -CommandName Remove-NoProxyEntry { }
            $overrides = @('*.internal.com', '10.0.0.0/8', 'localhost')

            & $scriptPath -Overrides $overrides

            Should -Invoke Remove-NoProxyEntry -Exactly 1 -ParameterFilter {
                $Entries.Count -eq 3 -and
                $Entries -contains '*.internal.com' -and
                $Entries -contains '10.0.0.0/8' -and
                $Entries -contains 'localhost'
            }
        }

        It 'stops WinHttpProxy before updating configuration' {
            Mock -CommandName Remove-NoProxyEntry { }

            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Stop-WinHttpProxy -Exactly 1
        }

        It 'retrieves updated proxy configuration after deleting overrides' {
            Mock -CommandName Remove-NoProxyEntry { }

            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Get-ProxyConfig -Exactly 1
        }
    }

    Context 'WinHttpProxy configuration after deletion' {
        BeforeEach {
            Mock -CommandName Remove-NoProxyEntry { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'configures WinHttpProxy with updated NoProxy list' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost', '127.0.0.1')
                }
            }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }

            & $scriptPath -Overrides '*.removed.com'

            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $Proxy -eq 'http://proxy.example.com:8080' -and
                $ProxyOverrides -contains 'localhost' -and
                $ProxyOverrides -contains '127.0.0.1'
            }
        }

        It 'uses NoProxy directly from config without K2s hosts merging' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('example.com')
                }
            }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }

            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                ($ProxyOverrides | Measure-Object).Count -eq 1 -and
                $ProxyOverrides[0] -eq 'example.com'
            }
        }

        It 'handles empty NoProxy after all overrides deleted' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @()
                }
            }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }

            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $ProxyOverrides.Count -eq 0
            }
        }

        It 'starts WinHttpProxy service after configuration' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = 'http://proxy.test:8080'; NoProxy = @('localhost') }
            }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }

            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Start-WinHttpProxy -Exactly 1
        }
    }

    Context 'Structured output' {
        BeforeEach {
            Mock -CommandName Remove-NoProxyEntry { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = 'http://proxy.test:8080'; NoProxy = @('localhost') }
            }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Write-Log { }
        }

        It 'sends structured output when EncodeStructuredOutput is set' {
            Mock -CommandName Send-ToCli { }

            & $scriptPath -Overrides '*.test.com' -EncodeStructuredOutput -MessageType 'DeleteOverrideResult'

            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $MessageType -eq 'DeleteOverrideResult' -and
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
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'throws exception when Remove-NoProxyEntry fails' {
            Mock -CommandName Remove-NoProxyEntry { throw 'Entry removal failed' }

            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Entry removal failed*'
        }

        It 'throws exception when Stop-WinHttpProxy fails' {
            Mock -CommandName Remove-NoProxyEntry { }
            Mock -CommandName Stop-WinHttpProxy { throw 'Service stop failed' }

            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Service stop failed*'
        }

        It 'throws exception when Get-ProxyConfig fails' {
            Mock -CommandName Remove-NoProxyEntry { }
            Mock -CommandName Get-ProxyConfig { throw 'Failed to read config' }

            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Failed to read config*'
        }

        It 'throws exception when Set-ProxyConfigInHttpProxy fails' {
            Mock -CommandName Remove-NoProxyEntry { }
            Mock -CommandName Set-ProxyConfigInHttpProxy { throw 'Configuration update failed' }

            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Configuration update failed*'
        }

        It 'throws exception when Start-WinHttpProxy fails' {
            Mock -CommandName Remove-NoProxyEntry { }
            Mock -CommandName Start-WinHttpProxy { throw 'Service start failed' }

            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Service start failed*'
        }
    }

    Context 'Behavioral differences from Add' {
        BeforeEach {
            Mock -CommandName Remove-NoProxyEntry { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
            Mock -CommandName Get-K2sHosts { }
        }

        It 'does not merge with K2s hosts unlike AddProxyOverride' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = 'http://proxy.test:8080'; NoProxy = @('localhost') }
            }

            & $scriptPath -Overrides '*.test.com'

            Should -Not -Invoke Get-K2sHosts
        }

        It 'uses exact NoProxy from config without additional entries' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('entry1', 'entry2')
                }
            }

            & $scriptPath -Overrides '*.test.com'

            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                ($ProxyOverrides | Measure-Object).Count -eq 2 -and
                $ProxyOverrides -contains 'entry1' -and
                $ProxyOverrides -contains 'entry2'
            }
        }
    }
}

