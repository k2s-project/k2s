# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

function Initialize-K2sCiProxy {
    param (
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,
        [switch] $IncludeWindowsProxyBypass
    )

    $proxy = $env:K2S_CONFIG_HTTP_PROXY
    if ([string]::IsNullOrWhiteSpace($proxy)) { $proxy = $env:K2S_HTTP_PROXY }
    if ([string]::IsNullOrWhiteSpace($proxy)) { $proxy = $env:HTTPS_PROXY }
    if ([string]::IsNullOrWhiteSpace($proxy)) { $proxy = $env:HTTP_PROXY }
    if (-not [string]::IsNullOrWhiteSpace($proxy)) {
        $proxyUri = $null
        if (-not [Uri]::TryCreate($proxy, [UriKind]::Absolute, [ref]$proxyUri) -or
            $proxyUri.Scheme -notin @('http', 'https') -or -not $proxyUri.Host -or $proxyUri.UserInfo) {
            throw 'Configure an absolute HTTP(S) proxy URL without embedded credentials for K2s CI.'
        }
        $env:HTTP_PROXY = $proxy
        $env:HTTPS_PROXY = $proxy
    }

    $network = (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json).smallsetup
    $requiredFields = @('masterIP', 'kubeSwitch', 'masterNetworkCIDR', 'podNetworkCIDR', 'servicesCIDR')
    foreach ($field in $requiredFields) {
        if ([string]::IsNullOrWhiteSpace($network.$field)) {
            throw "Missing network field '$field' in $ConfigPath."
        }
    }
    $bypass = @('localhost', '127.0.0.1', '::1', '.local', '.cluster.local')
    $bypass += $requiredFields | ForEach-Object { $network.$_ }
    $bypass += @($env:NO_PROXY, $env:K2S_NO_PROXY) | ForEach-Object { $_ -split ',' }
    $bypass += $env:K2S_CONFIG_NO_PROXY -split ','
    if ($IncludeWindowsProxyBypass -and [string]::IsNullOrWhiteSpace($proxy)) {
        $settingsPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        if (Test-Path -LiteralPath $settingsPath) {
            $settings = Get-ItemProperty -LiteralPath $settingsPath -ErrorAction Stop
            if ($settings.ProxyEnable) {
                $bypass += $settings.ProxyOverride -split '[;,]'
            }
        }
    }
    $env:NO_PROXY = ($bypass | ForEach-Object { $_.Trim() } |
        Where-Object { $_ } | Sort-Object -Unique) -join ','
}

function Clear-K2sCiProxyEnvironment {
    # This script runs in a step's child process, never in the parent Actions runner.
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'ALL_PROXY')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
}
