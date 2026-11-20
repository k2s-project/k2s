# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Gathers K8s cluster status information.

.DESCRIPTION
Gathers K8s cluster status information and outputs the data either as structured, compressed data or as is.

.PARAMETER EncodeStructuredOutput
If set to true, will encode and send result as structured data to the CLI.

.PARAMETER MessageType
Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true

.EXAMPLE
# Outputs the K8s cluster status to default output stream as is
PS> .\Get-Status.ps1

.EXAMPLE
# Sends the K8s cluster status as structured, compressed data with a message type label to default output stream
PS> .\Get-Status.ps1 -EncodeStructuredOutput -MessageType my-status
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $clusterModule

Initialize-Logging

$script = $MyInvocation.MyCommand.Name

Write-Log "[$script] started with EncodeStructuredOutput='$EncodeStructuredOutput' and MessageType='$MessageType'"

try {
    $status = Get-Status -ShowProgress ($EncodeStructuredOutput -ne $true)

    Write-Log "[$script] Status determined: $status"

    if ($EncodeStructuredOutput -eq $true) {
        Write-Log "[$script] Sending status to CLI.."

        Send-ToCli -MessageType $MessageType -Message $status
    }
    else {
        $status
    }

    Write-Log "[$script] finished"
}
catch {
    Write-Log "[$script] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}
