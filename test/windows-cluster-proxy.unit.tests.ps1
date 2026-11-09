# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    . "$PSScriptRoot\..\.github\scripts\windows-cluster-proxy.ps1"
    $configPath = Join-Path $PSScriptRoot '..\cfg\config.json'
    $proxyVariables = @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'ALL_PROXY', 'K2S_HTTP_PROXY', 'K2S_NO_PROXY',
                        'K2S_CONFIG_HTTP_PROXY', 'K2S_CONFIG_NO_PROXY')
}

Describe 'Windows cluster CI proxy configuration' -Tag 'unit' {
    BeforeEach {
        $originalEnvironment = @{}
        foreach ($variableName in $proxyVariables) {
            $originalEnvironment[$variableName] = [Environment]::GetEnvironmentVariable($variableName, 'Process')
            [Environment]::SetEnvironmentVariable($variableName, $null, 'Process')
        }
    }

    AfterEach {
        foreach ($variableName in $proxyVariables) {
            [Environment]::SetEnvironmentVariable($variableName, $originalEnvironment[$variableName], 'Process')
        }
    }

    It 'prefers explicit K2s configuration without changing the persistent environment' {
        $env:K2S_HTTP_PROXY = 'http://k2s-proxy.example:81'
        $env:HTTPS_PROXY = 'http://runner-proxy.example:81'
        $machineProxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Machine')

        Initialize-K2sCiProxy -ConfigPath $configPath

        $env:HTTPS_PROXY | Should -Be $env:K2S_HTTP_PROXY
        $env:HTTP_PROXY | Should -Be $env:K2S_HTTP_PROXY
        [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Machine') | Should -Be $machineProxy
    }

    It 'uses the inherited <Name> proxy when no override is set' -TestCases @(
        @{ Name = 'HTTPS_PROXY' }
        @{ Name = 'HTTP_PROXY' }
    ) {
        param($Name)
        [Environment]::SetEnvironmentVariable($Name, 'http://runner-proxy.example:81', 'Process')

        Initialize-K2sCiProxy -ConfigPath $configPath

        $env:HTTPS_PROXY | Should -Be 'http://runner-proxy.example:81'
        $env:HTTP_PROXY | Should -Be 'http://runner-proxy.example:81'
    }

    It 'preserves inherited K2s overrides when GitHub configuration is empty' {
        $env:K2S_CONFIG_HTTP_PROXY = ''
        $env:K2S_CONFIG_NO_PROXY = ''
        $env:K2S_HTTP_PROXY = 'http://k2s-proxy.example:81'
        $env:K2S_NO_PROXY = 'inherited.example'
        $env:HTTPS_PROXY = 'http://runner-proxy.example:81'

        Initialize-K2sCiProxy -ConfigPath $configPath

        $env:HTTPS_PROXY | Should -Be 'http://k2s-proxy.example:81'
        ($env:NO_PROXY -split ',') | Should -Contain 'inherited.example'
    }

    It 'prefers nonempty GitHub proxy configuration and merges both bypass sources' {
        $env:K2S_CONFIG_HTTP_PROXY = 'http://configured-proxy.example:81'
        $env:K2S_CONFIG_NO_PROXY = 'configured.example'
        $env:K2S_HTTP_PROXY = 'http://inherited-proxy.example:81'
        $env:K2S_NO_PROXY = 'inherited.example'

        Initialize-K2sCiProxy -ConfigPath $configPath

        $env:HTTPS_PROXY | Should -Be 'http://configured-proxy.example:81'
        ($env:NO_PROXY -split ',') | Should -Contain 'configured.example'
        ($env:NO_PROXY -split ',') | Should -Contain 'inherited.example'
    }

    It 'merges Windows proxy exceptions on the install fallback path' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like 'HKCU:*' }
        Mock Get-ItemProperty {
            [pscustomobject]@{ ProxyEnable = 1; ProxyOverride = 'windows.example;duplicate.example,<local>' }
        } -ParameterFilter { $LiteralPath -like 'HKCU:*' }
        $env:NO_PROXY = 'environment.example,duplicate.example'
        $env:K2S_NO_PROXY = 'inherited.example'
        $env:K2S_CONFIG_NO_PROXY = 'configured.example'

        Initialize-K2sCiProxy -ConfigPath $configPath -IncludeWindowsProxyBypass

        $env:HTTPS_PROXY | Should -BeNullOrEmpty
        $entries = $env:NO_PROXY -split ','
        foreach ($expected in @('windows.example', 'environment.example', 'inherited.example',
                                 'configured.example', '<local>')) {
            $entries | Should -Contain $expected
        }
        @($entries | Where-Object { $_ -eq 'duplicate.example' }).Count | Should -Be 1
    }

    It 'does not include disabled Windows proxy exceptions' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like 'HKCU:*' }
        Mock Get-ItemProperty {
            [pscustomobject]@{ ProxyEnable = 0; ProxyOverride = 'disabled.example' }
        } -ParameterFilter { $LiteralPath -like 'HKCU:*' }

        Initialize-K2sCiProxy -ConfigPath $configPath -IncludeWindowsProxyBypass

        ($env:NO_PROXY -split ',') | Should -Not -Contain 'disabled.example'
    }

    It 'preserves corporate bypasses and adds configured K2s destinations once' {
        $env:HTTP_PROXY = 'http://runner-proxy.example:81'
        $env:NO_PROXY = ' localhost,office.example '
        $env:K2S_NO_PROXY = 'registry.example,office.example'

        Initialize-K2sCiProxy -ConfigPath $configPath

        $network = (Get-Content $configPath -Raw | ConvertFrom-Json).smallsetup
        $entries = $env:NO_PROXY -split ','
        foreach ($expected in @('localhost', '127.0.0.1', '::1', '.local', '.cluster.local',
                                 'office.example', 'registry.example', $network.masterIP,
                                 $network.kubeSwitch, $network.masterNetworkCIDR,
                                 $network.podNetworkCIDR, $network.servicesCIDR)) {
            @($entries | Where-Object { $_ -eq $expected }).Count | Should -Be 1
        }
    }

    It 'does not invent a proxy for a direct-connect runner' {
        Initialize-K2sCiProxy -ConfigPath $configPath

        $env:HTTP_PROXY | Should -BeNullOrEmpty
        $env:HTTPS_PROXY | Should -BeNullOrEmpty
    }

    It 'rejects invalid or credential-bearing proxy <Proxy>' -TestCases @(
        @{ Proxy = 'proxy.example:81' }
        @{ Proxy = 'socks5://proxy.example:81' }
        @{ Proxy = 'http://user:password@proxy.example:81' }
    ) {
        param($Proxy)
        $env:K2S_HTTP_PROXY = $Proxy

        { Initialize-K2sCiProxy -ConfigPath $configPath } | Should -Throw '*absolute HTTP(S) proxy URL*'
    }

    It 'rejects missing network configuration' {
        $invalidConfig = Join-Path $TestDrive 'invalid-config.json'
        '{"smallsetup":{}}' | Set-Content $invalidConfig

        { Initialize-K2sCiProxy -ConfigPath $invalidConfig } | Should -Throw '*Missing network field*'
    }

    It 'clears only the child-process proxy variables for CLI operations' {
        $env:HTTP_PROXY = 'http://runner-proxy.example:81'
        $env:HTTPS_PROXY = $env:HTTP_PROXY
        $env:NO_PROXY = 'localhost'
        $env:ALL_PROXY = $env:HTTP_PROXY
        $env:K2S_HTTP_PROXY = 'http://k2s-proxy.example:81'
        $machineProxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Machine')

        Clear-K2sCiProxyEnvironment

        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'ALL_PROXY')) {
            [Environment]::GetEnvironmentVariable($name, 'Process') | Should -BeNullOrEmpty
        }
        $env:K2S_HTTP_PROXY | Should -Be 'http://k2s-proxy.example:81'
        [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Machine') | Should -Be $machineProxy
    }
}
