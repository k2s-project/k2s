# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $scriptPath = "$PSScriptRoot\ResetProxy.ps1"
    $scriptContent = (Get-Content -Path $scriptPath | Where-Object { $_ -notmatch '^#Requires\b' }) -join [Environment]::NewLine

    function global:Initialize-Logging { }

    function global:Reset-ProxyConfig { }
    function global:Get-ProxyConfig {
        return [PSCustomObject]@{
            HttpProxy = ''
            HttpsProxy = ''
            NoProxy = @()
        }
    }
    function global:Get-K2sHosts { return @('172.19.1.100', '172.19.1.1', '.local', '.cluster.local') }
    function global:Stop-WinHttpProxy { }
    function global:Start-WinHttpProxy { }
    function global:Get-ConfiguredIPControlPlane { return '172.19.1.100' }
    function global:Get-DefaultUserNameControlPlane { return 'remote' }
    function global:Remove-ProxySettingsOnKubenode { param($IpAddress, $UserName) }
    function global:Set-ProxyConfigInHttpProxy { param($Proxy, $ProxyOverrides) }
    function global:Send-ToCli { param($MessageType, $Message) }
    function global:Write-Log { param([string]$Message, [switch]$Error) }
    function Invoke-ResetProxyScript {
        param(
            [switch] $ShowLogs = $false,
            [switch] $EncodeStructuredOutput,
            [string] $MessageType
        )

        $invokeParams = @{
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

Describe 'ResetProxy.ps1' -Tag 'unit', 'ci', 'proxy' {

    Context 'Parameter validation' {
        BeforeEach {
            Mock -CommandName Reset-ProxyConfig { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = ''; NoProxy = @() }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Remove-ProxySettingsOnKubenode { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'runs without parameters' {
            { Invoke-ResetProxyScript } | Should -Not -Throw
        }

        It 'accepts ShowLogs switch parameter' {
            { Invoke-ResetProxyScript -ShowLogs } | Should -Not -Throw
        }

        It 'accepts EncodeStructuredOutput switch parameter' {
            { Invoke-ResetProxyScript -EncodeStructuredOutput -MessageType 'Test' } | Should -Not -Throw
        }
    }

    Context 'Module imports' {
        BeforeEach {
            Mock -CommandName Import-Module { }
            Mock -CommandName Reset-ProxyConfig { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = ''; NoProxy = @() }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Remove-ProxySettingsOnKubenode { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'imports infra module' {
            Invoke-ResetProxyScript

            Should -Invoke Import-Module -ParameterFilter {
                $Name -like '*k2s.infra.module.psm1'
            }
        }

        It 'imports node module' {
            Invoke-ResetProxyScript

            Should -Invoke Import-Module -ParameterFilter {
                $Name -like '*k2s.node.module.psm1'
            }
        }

        It 'initializes logging' {
            Invoke-ResetProxyScript

            Should -Invoke Initialize-Logging -Exactly 1
        }
    }

    Context 'Proxy reset operations' {
        BeforeEach {
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = ''; NoProxy = @() }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Remove-ProxySettingsOnKubenode { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'calls Reset-ProxyConfig' {
            Mock -CommandName Reset-ProxyConfig { }

            Invoke-ResetProxyScript

            Should -Invoke Reset-ProxyConfig -Exactly 1
        }

        It 'stops WinHttpProxy service' {
            Mock -CommandName Reset-ProxyConfig { }

            Invoke-ResetProxyScript

            Should -Invoke Stop-WinHttpProxy -Exactly 1
        }

        It 'retrieves updated proxy configuration after reset' {
            Mock -CommandName Reset-ProxyConfig { }

            Invoke-ResetProxyScript

            Should -Invoke Get-ProxyConfig -Exactly 1
        }

        It 'retrieves K2s hosts for NoProxy configuration' {
            Mock -CommandName Reset-ProxyConfig { }

            Invoke-ResetProxyScript

            Should -Invoke Get-K2sHosts -Exactly 1
        }
    }

    Context 'WinHttpProxy configuration after reset' {
        BeforeEach {
            Mock -CommandName Reset-ProxyConfig { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = ''; NoProxy = @() }
            }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Remove-ProxySettingsOnKubenode { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'configures WinHttpProxy with empty proxy and K2s hosts only' {
            Mock -CommandName Get-K2sHosts { return @('localhost', '127.0.0.1', '.local') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }

            Invoke-ResetProxyScript

            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $Proxy -eq '' -and
                $ProxyOverrides -contains 'localhost' -and
                $ProxyOverrides -contains '127.0.0.1' -and
                $ProxyOverrides -contains '.local'
            }
        }

        It 'starts WinHttpProxy service after configuration' {
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }

            Invoke-ResetProxyScript

            Should -Invoke Start-WinHttpProxy -Exactly 1
        }

        It 'uses only K2s hosts as ProxyOverride after reset' {
            Mock -CommandName Get-K2sHosts { return @('172.19.1.100', '172.19.1.1') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }

            Invoke-ResetProxyScript

            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                ($ProxyOverrides | Measure-Object).Count -eq 2 -and
                $ProxyOverrides -contains '172.19.1.100' -and
                $ProxyOverrides -contains '172.19.1.1'
            }
        }
    }

    Context 'Structured output' {
        BeforeEach {
            Mock -CommandName Reset-ProxyConfig { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = ''; NoProxy = @() }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Remove-ProxySettingsOnKubenode { }
            Mock -CommandName Write-Log { }
        }

        It 'sends structured output when EncodeStructuredOutput is set' {
            Mock -CommandName Send-ToCli { }

            Invoke-ResetProxyScript -EncodeStructuredOutput -MessageType 'ResetProxyResult'

            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $MessageType -eq 'ResetProxyResult' -and
                $Message.Error -eq $null
            }
        }

        It 'does not send structured output by default' {
            Mock -CommandName Send-ToCli { }

            Invoke-ResetProxyScript

            Should -Invoke Send-ToCli -Exactly 0
        }
    }

    Context 'Linux proxy cleanup' {
        BeforeEach {
            Mock -CommandName Reset-ProxyConfig { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = ''; NoProxy = @() }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Send-ToCli { }
        }

        It 'removes Linux proxy settings when control plane is reachable' {
            Mock -CommandName Test-Connection { return $true }
            Mock -CommandName Remove-ProxySettingsOnKubenode { }

            Invoke-ResetProxyScript

            Should -Invoke Remove-ProxySettingsOnKubenode -Exactly 1 -ParameterFilter {
                $IpAddress -eq '172.19.1.100' -and
                $UserName -eq 'remote'
            }
        }

        It 'skips Linux proxy cleanup when control plane is unreachable' {
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Remove-ProxySettingsOnKubenode { }
            Mock -CommandName Write-Log { }

            Invoke-ResetProxyScript

            Should -Invoke Remove-ProxySettingsOnKubenode -Exactly 0
        }
    }

    Context 'Error handling' {
        BeforeEach {
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig {
                return [PSCustomObject]@{ HttpProxy = ''; NoProxy = @() }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
            Mock -CommandName Get-DefaultUserNameControlPlane { return 'remote' }
            Mock -CommandName Test-Connection { return $false }
            Mock -CommandName Remove-ProxySettingsOnKubenode { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }

        It 'throws exception when Reset-ProxyConfig fails' {
            Mock -CommandName Reset-ProxyConfig { throw 'Configuration reset failed' }

            { Invoke-ResetProxyScript } | Should -Throw '*Configuration reset failed*'
        }

        It 'throws exception when Stop-WinHttpProxy fails' {
            Mock -CommandName Reset-ProxyConfig { }
            Mock -CommandName Stop-WinHttpProxy { throw 'Service stop failed' }

            { Invoke-ResetProxyScript } | Should -Throw '*Service stop failed*'
        }

        It 'throws exception when Get-ProxyConfig fails' {
            Mock -CommandName Reset-ProxyConfig { }
            Mock -CommandName Get-ProxyConfig { throw 'Failed to read config' }

            { Invoke-ResetProxyScript } | Should -Throw '*Failed to read config*'
        }

        It 'throws exception when Set-ProxyConfigInHttpProxy fails' {
            Mock -CommandName Reset-ProxyConfig { }
            Mock -CommandName Set-ProxyConfigInHttpProxy { throw 'Configuration update failed' }

            { Invoke-ResetProxyScript } | Should -Throw '*Configuration update failed*'
        }

        It 'throws exception when Start-WinHttpProxy fails' {
            Mock -CommandName Reset-ProxyConfig { }
            Mock -CommandName Start-WinHttpProxy { throw 'Service start failed' }

            { Invoke-ResetProxyScript } | Should -Throw '*Service start failed*'
        }
    }
}

