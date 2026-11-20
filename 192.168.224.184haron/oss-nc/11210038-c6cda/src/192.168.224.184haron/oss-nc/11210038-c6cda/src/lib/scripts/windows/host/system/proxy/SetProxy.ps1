# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $true, HelpMessage = 'Proxy server URL to be used by k2s')]
    [string] $Uri,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"

Import-Module $infraModule, $nodeModule
Initialize-Logging

try {
    Set-ProxyServer -Proxy $Uri
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

    $controlPlaneIpAddress = Get-ConfiguredIPControlPlane
    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
    $transparentProxy = "http://$($windowsHostIpAddress):8181"
    $controlPlaneUserName = Get-DefaultUserNameControlPlane
    $controlPlaneReachable = Test-Connection -ComputerName $controlPlaneIpAddress -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($controlPlaneReachable) {
        Set-ProxySettingsOnKubenode -ProxySettings $transparentProxy -IpAddress $controlPlaneIpAddress -UserName $controlPlaneUserName
    }
    else {
        Write-Log "[Proxy] Skip Linux proxy update because control plane '$controlPlaneIpAddress' is not reachable"
    }

    if ($EncodeStructuredOutput) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null}
    }
    Write-Log "[$script] finished"
} catch {
    Write-Log "[$script] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}
