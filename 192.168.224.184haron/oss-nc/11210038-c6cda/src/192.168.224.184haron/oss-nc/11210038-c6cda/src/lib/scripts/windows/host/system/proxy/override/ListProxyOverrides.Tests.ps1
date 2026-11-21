# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $scriptPath = "$PSScriptRoot\ListProxyOverrides.ps1"

    function global:Initialize-Logging { }

    function global:Get-ProxyConfig {
        return [PSCustomObject]@{
            HttpProxy = 'http://proxy.example.com:8080'
            HttpsProxy = 'http://proxy.example.com:8080'
            NoProxy = @('localhost', '127.0.0.1', '*.example.com', '.local')
        }
    }
    function global:Send-ToCli { param($MessageType, $Message) }
    function global:Write-Log { param([string]$Message, [switch]$Error) }

    function global:Stop-WinHttpProxy { }
    function global:Start-WinHttpProxy { }
    function global:Set-ProxyConfigInHttpProxy { param($Proxy, $ProxyOverrides) }
    function global:Add-NoProxyEntry { param($Entries) }
    function global:Remove-NoProxyEntry { param($Entries) }
    function global:Set-ProxyServer { param($Proxy) }

    Mock -CommandName Import-Module { }
    Mock -CommandName Initialize-Logging { }
}

Describe 'ListProxyOverrides.ps1' -Tag 'unit', 'ci', 'proxy' {

    Context 'Parameter validation' {
        BeforeEach {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ NoProxy = @('localhost') }
            }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'runs without parameters' {
            { & $scriptPath } | Should -Not -Throw
        }

        It 'accepts ShowLogs switch parameter' {
            { & $scriptPath -ShowLogs } | Should -Not -Throw
        }

        It 'accepts EncodeStructuredOutput switch parameter' {
            { & $scriptPath -EncodeStructuredOutput -MessageType 'Test' } | Should -Not -Throw
        }
    }

    Context 'Module imports' {
        BeforeEach {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ NoProxy = @('localhost') }
            }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'imports infra module' {
            & $scriptPath

            Should -Invoke Import-Module -ParameterFilter {
                $Name -like '*k2s.infra.module.psm1'
            }
        }

        It 'imports node module' {
            & $scriptPath

            Should -Invoke Import-Module -ParameterFilter {
                $Name -like '*k2s.node.module.psm1'
            }
        }

        It 'initializes logging' {
            & $scriptPath

            Should -Invoke Initialize-Logging -Exactly 1
        }
    }

    Context 'Listing proxy overrides' {
        BeforeEach {
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'retrieves proxy configuration' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ NoProxy = @('localhost') }
            }

            & $scriptPath

            Should -Invoke Get-ProxyConfig -Exactly 1
        }

        It 'returns result with ProxyOverrides property' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ NoProxy = @('localhost') }
            }

            $result = & $scriptPath

            $result.ProxyOverrides | Should -Not -BeNullOrEmpty
            $result.Error | Should -BeNullOrEmpty
        }

        It 'returns NoProxy list from configuration' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    NoProxy = @('override1', 'override2', 'override3')
                }
            }

            $result = & $scriptPath

            $result.ProxyOverrides | Should -HaveCount 3
            $result.ProxyOverrides | Should -Contain 'override1'
            $result.ProxyOverrides | Should -Contain 'override2'
            $result.ProxyOverrides | Should -Contain 'override3'
        }

        It 'handles empty NoProxy list' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    NoProxy = @()
                }
            }

            $result = & $scriptPath

            $result.ProxyOverrides | Should -BeNullOrEmpty
            $result.Error | Should -BeNullOrEmpty
        }

        It 'handles null NoProxy' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    NoProxy = $null
                }
            }

            $result = & $scriptPath

            $result.ProxyOverrides | Should -BeNullOrEmpty
        }

        It 'returns all types of override entries' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    NoProxy = @('localhost', '*.domain.com', '192.168.1.0/24', '.local')
                }
            }

            $result = & $scriptPath

            $result.ProxyOverrides | Should -Contain 'localhost'
            $result.ProxyOverrides | Should -Contain '*.domain.com'
            $result.ProxyOverrides | Should -Contain '192.168.1.0/24'
            $result.ProxyOverrides | Should -Contain '.local'
        }
    }

    Context 'Structured output' {
        BeforeEach {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    NoProxy = @('localhost', '127.0.0.1', '*.example.com', '.local')
                }
            }
            Mock -CommandName Write-Log { }
        }

        It 'sends structured output when EncodeStructuredOutput is set' {
            Mock -CommandName Send-ToCli { }

            & $scriptPath -EncodeStructuredOutput -MessageType 'ListOverridesResult'

            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $MessageType -eq 'ListOverridesResult' -and
                $Message.ProxyOverrides -ne $null -and
                $Message.Error -eq $null
            }
        }

        It 'sends correct ProxyOverrides in structured output' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    NoProxy = @('entry1', 'entry2')
                }
            }
            Mock -CommandName Send-ToCli { }

            & $scriptPath -EncodeStructuredOutput -MessageType 'ListOverridesResult'

            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $Message.ProxyOverrides.Count -eq 2 -and
                $Message.ProxyOverrides -contains 'entry1' -and
                $Message.ProxyOverrides -contains 'entry2'
            }
        }

        It 'returns result directly when not encoding' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    NoProxy = @('test1', 'test2')
                }
            }

            $result = & $scriptPath

            $result | Should -BeOfType [hashtable]
            $result.ProxyOverrides | Should -HaveCount 2
        }

        It 'does not send structured output by default' {
            Mock -CommandName Send-ToCli { }

            & $scriptPath

            Should -Invoke Send-ToCli -Exactly 0
        }
    }

    Context 'Return value structure' {
        BeforeEach {
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'returns hashtable with Error and ProxyOverrides properties' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ NoProxy = @('localhost') }
            }

            $result = & $scriptPath

            $result | Should -BeOfType [hashtable]
            $result.ContainsKey('Error') | Should -Be $true
            $result.ContainsKey('ProxyOverrides') | Should -Be $true
        }

        It 'sets Error to null on success' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ NoProxy = @('localhost') }
            }

            $result = & $scriptPath

            $result.Error | Should -BeNullOrEmpty
        }

        It 'includes all NoProxy entries in ProxyOverrides' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    NoProxy = @('a', 'b', 'c', 'd', 'e')
                }
            }

            $result = & $scriptPath

            $result.ProxyOverrides | Should -HaveCount 5
        }
    }

    Context 'Error handling' {
        BeforeEach {
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'throws exception when Get-ProxyConfig fails' {
            Mock -CommandName Get-ProxyConfig { throw 'Failed to read config' }

            { & $scriptPath } | Should -Throw '*Failed to read config*'
        }
    }

    Context 'No service operations' {
        BeforeEach {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ NoProxy = @('localhost') }
            }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Add-NoProxyEntry { }
            Mock -CommandName Remove-NoProxyEntry { }
            Mock -CommandName Set-ProxyServer { }
        }

        It 'does not stop WinHttpProxy' {
            & $scriptPath

            Should -Not -Invoke Stop-WinHttpProxy
        }

        It 'does not start WinHttpProxy' {
            & $scriptPath

            Should -Not -Invoke Start-WinHttpProxy
        }

        It 'does not modify proxy configuration' {
            & $scriptPath

            Should -Not -Invoke Set-ProxyConfigInHttpProxy
        }

        It 'only reads configuration without modifications' {
            & $scriptPath

            Should -Invoke Get-ProxyConfig -Exactly 1
            Should -Not -Invoke Add-NoProxyEntry
            Should -Not -Invoke Remove-NoProxyEntry
            Should -Not -Invoke Set-ProxyServer
        }
    }
}
