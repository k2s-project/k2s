# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot/addons.module.psm1"

Import-Module $infraModule, $addonsModule

Initialize-Logging 

$script = $MyInvocation.MyCommand.Name

Write-Log "[$script] started with EncodeStructuredOutput='$EncodeStructuredOutput' and MessageType='$MessageType'"

try {
    $addons = Get-EnabledAddons

    Write-Log "[$script] Enabled addons determined: $addons"

    if ($EncodeStructuredOutput) {
        Send-ToCli -MessageType $MessageType -Message $addons
    }
    else {
        $addons
    }

    Write-Log "[$script] finished"
}
catch {
    Write-Log "[$script] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}
