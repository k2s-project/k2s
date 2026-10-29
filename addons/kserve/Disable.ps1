# SPDX-FileCopyrightText: (c) 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

param(
    [switch] $ShowLogs = $false,
    [switch] $EncodeStructuredOutput,
    [string] $MessageType
)

Import-Module "$PSScriptRoot\..\..\lib\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1",
    "$PSScriptRoot\..\..\lib\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1",
    "$PSScriptRoot\..\addons.module.psm1"
. "$PSScriptRoot\Kserve.Helpers.ps1"

Initialize-Logging -ShowLogs:$ShowLogs
$ErrorActionPreference = 'Stop'
$errorCode = 'addon-disable-failed'
try {
    $systemError = Test-SystemAvailability -Structured
    if ($systemError) {
        $errorCode = $systemError.Code
        throw $systemError.Message
    }
    if (-not (Test-IsAddonEnabled -Addon ([pscustomobject]@{ Name = 'kserve' }))) {
        $errorCode = Get-ErrCodeAddonAlreadyDisabled
        throw "[KServe] Addon 'kserve' is already disabled."
    }
    Uninstall-Kserve
    Remove-ScriptsFromHooksDir -ScriptNames @(Get-ChildItem -LiteralPath "$PSScriptRoot\hooks" -Filter '*.ps1' | ForEach-Object { $_.Name })
    Remove-AddonFromSetupJson -Addon ([pscustomobject]@{ Name = 'kserve' })
}
catch {
    Write-Log "[KServe] Disable failed: $($_.Exception.Message)" -Error -ErrorAction Continue
    if ($EncodeStructuredOutput) {
        $err = New-Error -Code $errorCode -Message $_.Exception.Message
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }
    throw
}
if ($EncodeStructuredOutput) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
