# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $scriptPath = "$PSScriptRoot\SetProxy.ps1"
    $scriptContent = (Get-Content -Path $scriptPath | Where-Object { $_ -notmatch '^#Requires\b' }) -join [Environment]::NewLine

    function global:Initialize-Logging { }

    function global:Set-ProxyServer { param($Proxy) }
    function global:Get-ProxyConfig {
        return [PSCustomObject]@{
            HttpProxy = 'http://proxy.example.com:8080'
            HttpsProxy = 'http://proxy.example.com:8080'
            NoProxy = @('localhost', '127.0.0.1')
        }
    }
    function global:Get-K2sHosts { return @('172.19.1.100', '172.19.1.1', '.local', '.cluster.local') }
    function global:Stop-WinHttpProxy { }
    function global:Start-WinHttpProxy { }
    function global:Get-ConfiguredIPControlPlane { return '172.19.1.100' }
    function global:Get-ConfiguredKubeSwitchIP { return '172.19.1.1' }
    function global:Get-DefaultUserNameControlPlane { return 'remote' }
    function global:Set-ProxySettingsOnKubenode { param($ProxySettings, $IpAddress, $UserName) }
    function global:Set-ProxyConfigInHttpProxy { param($Proxy, $ProxyOverrides) }
    function global:Send-ToCli { param($MessageType, $Message) }
    function global:Write-Log { param([string]$Message, [switch]$Error) }
    function Invoke-SetProxyScript {
        param(
            [string] $Uri,
            [switch] $ShowLogs = $false,
            [switch] $EncodeStructuredOutput,
            [string] $MessageType
        )

        $invokeParams = @{
            Uri = $Uri
            ShowLogs = $ShowLogs
        }
        if ($EncodeStructuredOutput) {
            $invokeParams.EncodeStructuredOutput = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($MessageType)) {
            $invokeParams.MessageType = $MessageType
        }

        & ([scriptblock]::Create($scriptContent)) @invokeParams
    }

    Mock -CommandName Import-Module { }
    Mock -CommandName Initialize-Logging { }
}

Describe 'SetProxy.ps1' -Tag 'unit', 'ci', 'proxy' {

    Context 'Parameter validation' {
        BeforeEach {
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-ConfiguredKubeSwitchIP { return '172.19.1.1' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Set-ProxySettingsOnKubenode { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'accepts valid Uri parameter' {
            { Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080' } | Should -Not -Throw
        }

        It 'accepts ShowLogs switch parameter' {
            { Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080' -ShowLogs } | Should -Not -Throw
        }

        It 'accepts EncodeStructuredOutput switch parameter' {
            { Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080' -EncodeStructuredOutput -MessageType 'Test' } | Should -Not -Throw
        }
    }

    Context 'Module imports' {
        BeforeEach {
            Mock -CommandName Import-Module { }
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = 'http://test.proxy:8080'; NoProxy = @() }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-ConfiguredKubeSwitchIP { return '172.19.1.1' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Set-ProxySettingsOnKubenode { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'imports infra module' {
            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080'

            Should -Invoke Import-Module -ParameterFilter {
                $Name -like '*k2s.infra.module.psm1'
            }
        }

        It 'imports node module' {
            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080'

            Should -Invoke Import-Module -ParameterFilter {
                $Name -like '*k2s.node.module.psm1'
            }
        }

        It 'initializes logging' {
            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080'

            Should -Invoke Initialize-Logging -Exactly 1
        }
    }

    Context 'Proxy configuration' {
        BeforeEach {
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-ConfiguredKubeSwitchIP { return '172.19.1.1' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Set-ProxySettingsOnKubenode { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'calls Set-ProxyServer with provided Uri' {
            Mock -CommandName Set-ProxyServer { }
            $testUri = 'http://custom.proxy.com:9090'

            Invoke-SetProxyScript -Uri $testUri

            Should -Invoke Set-ProxyServer -Exactly 1 -ParameterFilter {
                $Proxy -eq $testUri
            }
        }

        It 'stops WinHttpProxy service' {
            Mock -CommandName Set-ProxyServer { }

            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080'

            Should -Invoke Stop-WinHttpProxy -Exactly 1
        }

        It 'retrieves updated proxy configuration' {
            Mock -CommandName Set-ProxyServer { }

            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080'

            Should -Invoke Get-ProxyConfig -Exactly 1
        }

        It 'retrieves K2s hosts for NoProxy' {
            Mock -CommandName Set-ProxyServer { }

            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080'

            Should -Invoke Get-K2sHosts -Exactly 1
        }
    }

    Context 'NoProxy hosts merging' {
        BeforeEach {
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-ConfiguredKubeSwitchIP { return '172.19.1.1' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Set-ProxySettingsOnKubenode { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'merges existing NoProxy with K2s hosts' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('example.com', 'test.local')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost', '127.0.0.1') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }

            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080'

            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $ProxyOverrides -contains 'example.com' -and
                $ProxyOverrides -contains 'test.local' -and
                $ProxyOverrides -contains 'localhost' -and
                $ProxyOverrides -contains '127.0.0.1'
            }
        }

        It 'removes duplicate entries from NoProxy list' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost', 'example.com')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost', '127.0.0.1') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }

            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080'

            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                # Count occurrences of 'localhost' - should be only 1
                ($ProxyOverrides | Where-Object { $_ -eq 'localhost' } | Measure-Object).Count -eq 1
            }
        }

        It 'handles empty NoProxy from config' {
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @()
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost', '127.0.0.1') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }

            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080'

            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $ProxyOverrides -contains 'localhost' -and
                $ProxyOverrides -contains '127.0.0.1'
            }
        }
    }

    Context 'WinHttpProxy configuration' {
        BeforeEach {
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-ConfiguredKubeSwitchIP { return '172.19.1.1' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Set-ProxySettingsOnKubenode { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'configures WinHttpProxy with merged NoProxy hosts' {
            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080'

            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1
        }

        It 'starts WinHttpProxy service after configuration' {
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }

            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080'

            Should -Invoke Start-WinHttpProxy -Exactly 1
        }
    }

    Context 'Structured output' {
        BeforeEach {
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-ConfiguredKubeSwitchIP { return '172.19.1.1' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Set-ProxySettingsOnKubenode { }
            Mock -CommandName Write-Log { }
        }

        It 'sends structured output when EncodeStructuredOutput is set' {
            Mock -CommandName Send-ToCli { }

            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080' -EncodeStructuredOutput -MessageType 'ProxyResult'

            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $MessageType -eq 'ProxyResult' -and
                $Message.Error -eq $null
            }
        }

        It 'does not send structured output by default' {
            Mock -CommandName Send-ToCli { }

            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080'

            Should -Invoke Send-ToCli -Exactly 0
        }
    }

    Context 'Linux proxy update' {
        BeforeEach {
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-ConfiguredKubeSwitchIP { return '172.19.1.1' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Send-ToCli { }
        }

        It 'updates Linux proxy settings with transparent proxy when control plane is reachable' {
            Mock -CommandName Test-Connection { return $true }
            Mock -CommandName Set-ProxySettingsOnKubenode { }

            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080'

            Should -Invoke Set-ProxySettingsOnKubenode -Exactly 1 -ParameterFilter {
                $ProxySettings -eq 'http://172.19.1.1:8181' -and
                $IpAddress -eq '172.19.1.100' -and
                $UserName -eq 'remote'
            }
        }

        It 'skips Linux proxy update when control plane is unreachable' {
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Set-ProxySettingsOnKubenode { }
            Mock -CommandName Write-Log { }

            Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080'

            Should -Invoke Set-ProxySettingsOnKubenode -Exactly 0
        }
    }

    Context 'Error handling' {
        BeforeEach {
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-ConfiguredKubeSwitchIP { return '172.19.1.1' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Set-ProxySettingsOnKubenode { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'throws exception when Set-ProxyServer fails' {
            Mock -CommandName Set-ProxyServer { throw 'Proxy configuration failed' }

            { Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080' } | Should -Throw '*Proxy configuration failed*'
        }

        It 'throws exception when Get-ProxyConfig fails' {
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Get-ProxyConfig { throw 'Failed to read config' }

            { Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080' } | Should -Throw '*Failed to read config*'
        }

        It 'throws exception when WinHttpProxy operations fail' {
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Stop-WinHttpProxy { throw 'Service stop failed' }

            { Invoke-SetProxyScript -Uri 'http://proxy.test.com:8080' } | Should -Throw '*Service stop failed*'
        }
    }
}

