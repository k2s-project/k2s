# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $scriptPath = "$PSScriptRoot\GetProxy.ps1"

    function global:Initialize-Logging { }

    function global:Get-ProxyConfig {
        return [PSCustomObject]@{
            HttpProxy = 'http://proxy.example.com:8080'
            HttpsProxy = 'http://proxy.example.com:8080'
            NoProxy = @('localhost', '127.0.0.1')
        }
    }
    function global:Send-ToCli { param($MessageType, $Message) }
    function global:Write-Log { param([string]$Message, [switch]$Error) }

    Mock -CommandName Import-Module { }
    Mock -CommandName Initialize-Logging { }
}

Describe 'GetProxy.ps1' -Tag 'unit', 'ci', 'proxy' {

    Context 'Parameter validation' {
        BeforeEach {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                }
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
                return [PSCustomObject]@{ HttpProxy = 'http://test.proxy:8080' }
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

    Context 'Proxy retrieval' {
        BeforeEach {
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'retrieves proxy configuration' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = 'http://proxy.example.com:8080' }
            }

            & $scriptPath

            Should -Invoke Get-ProxyConfig -Exactly 1
        }

        It 'returns result with Proxy property' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = 'http://proxy.example.com:8080' }
            }

            $result = & $scriptPath

            $result.Proxy | Should -Not -BeNullOrEmpty
            $result.Error | Should -BeNullOrEmpty
        }

        It 'returns HttpProxy value from configuration' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://custom.proxy.net:3128'
                }
            }

            $result = & $scriptPath

            $result.Proxy | Should -Be 'http://custom.proxy.net:3128'
        }

        It 'handles null proxy configuration' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = $null
                }
            }

            $result = & $scriptPath

            $result.Proxy | Should -BeNullOrEmpty
            $result.Error | Should -BeNullOrEmpty
        }
    }

    Context 'Structured output' {
        BeforeEach {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                }
            }
            Mock -CommandName Write-Log { }
        }

        It 'sends structured output when EncodeStructuredOutput is set' {
            Mock -CommandName Send-ToCli { }

            & $scriptPath -EncodeStructuredOutput -MessageType 'GetProxyResult'

            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $MessageType -eq 'GetProxyResult' -and
                $Message.Proxy -eq 'http://proxy.example.com:8080' -and
                $Message.Error -eq $null
            }
        }

        It 'does not send structured output by default' {
            Mock -CommandName Send-ToCli { }

            & $scriptPath

            Should -Invoke Send-ToCli -Exactly 0
        }

        It 'returns hashtable with Error and Proxy properties' {
            Mock -CommandName Send-ToCli { }

            $result = & $scriptPath

            $result | Should -BeOfType [hashtable]
            $result.ContainsKey('Error') | Should -Be $true
            $result.ContainsKey('Proxy') | Should -Be $true
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
}
