# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $true, HelpMessage = 'Hostnames, Domains, IP addresses or Subnets for which proxy server must not be used.')]
    [string[]] $Overrides,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot\..\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"

Import-Module $infraModule, $nodeModule
Initialize-Logging

try {
    Add-NoProxyEntry -Entries $Overrides
    Stop-WinHttpProxy
    $updatedProxyConfig = Get-ProxyConfig

    $k2sHosts = Get-K2sHosts
    $allNoProxyHosts = @()
    if ($updatedProxyConfig.NoProxy.Count -gt 0) {
        $allNoProxyHosts += $updatedProxyConfig.NoProxy
    }
    $allNoProxyHosts += $k2sHosts
    $uniqueNoProxyHosts = $allNoProxyHosts | Sort-Object -Unique

    Set-ProxyConfigInHttpProxy -Proxy $updatedProxyConfig.HttpProxy -ProxyOverrides $uniqueNoProxyHosts
    Start-WinHttpProxy
    if ($EncodeStructuredOutput) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null}
    }
    Write-Log "[$script] finished"
} catch {
    Write-Log "[$script] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}
