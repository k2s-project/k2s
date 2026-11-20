# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator


Param(
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
    Reset-ProxyConfig
    Stop-WinHttpProxy
    $updatedProxyConfig = Get-ProxyConfig

    $k2sHosts = Get-K2sHosts
    Set-ProxyConfigInHttpProxy -Proxy $updatedProxyConfig.HttpProxy -ProxyOverrides $k2sHosts
    Start-WinHttpProxy

    $controlPlaneIpAddress = Get-ConfiguredIPControlPlane
    $controlPlaneUserName = Get-DefaultUserNameControlPlane
    $controlPlaneReachable = Test-Connection -ComputerName $controlPlaneIpAddress -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($controlPlaneReachable) {
        Remove-ProxySettingsOnKubenode -IpAddress $controlPlaneIpAddress -UserName $controlPlaneUserName
    }
    else {
        Write-Log "[Proxy] Skip Linux proxy cleanup because control plane '$controlPlaneIpAddress' is not reachable"
    }

    if ($EncodeStructuredOutput) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null}
    }
    Write-Log "[$script] finished"
} catch {
    Write-Log "[$script] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}
