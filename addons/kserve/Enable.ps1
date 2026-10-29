# SPDX-FileCopyrightText: (c) 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

param(
    [switch] $ShowLogs = $false,
    [ValidateSet('none', 'qwen-cpu', 'qwen-gpu')][string] $Model = 'none',
    [string] $Proxy = 'auto',
    [string] $CaBundle,
    [pscustomobject] $Config,
    [switch] $EncodeStructuredOutput,
    [string] $MessageType
)

Import-Module "$PSScriptRoot\..\..\lib\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1",
    "$PSScriptRoot\..\..\lib\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1",
    "$PSScriptRoot\..\addons.module.psm1"
. "$PSScriptRoot\Kserve.Helpers.ps1"

Initialize-Logging -ShowLogs:$ShowLogs
$ErrorActionPreference = 'Stop'
$errorCode = Get-ErrCodeAddonEnableFailed
$restoredCaFile = $null
try {
    $systemError = Test-SystemAvailability -Structured
    if ($systemError) {
        $errorCode = $systemError.Code
        throw $systemError.Message
    }
    if ((Get-SetupInfo).Name -ne 'k2s') {
        $errorCode = Get-ErrCodeWrongSetupType
        throw "[KServe] Addon 'kserve' requires a k2s setup."
    }
    if (Test-IsAddonEnabled -Addon ([pscustomobject]@{ Name = 'kserve' })) {
        $errorCode = Get-ErrCodeAddonAlreadyEnabled
        throw "[KServe] Addon 'kserve' is already enabled. Disable it before changing its configuration."
    }
    if ($Config) {
        if ($null -ne $Config.Model) { $Model = $Config.Model }
        if ($null -ne $Config.Proxy) { $Proxy = $Config.Proxy }
        if ($Config.CaBundlePem) {
            $restoredCaFile = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-kserve-restore-$([guid]::NewGuid()).crt"
            [System.IO.File]::WriteAllText($restoredCaFile, $Config.CaBundlePem, [System.Text.UTF8Encoding]::new($false))
            $CaBundle = $restoredCaFile
        }
    }
    Install-Kserve -Model $Model -Proxy $Proxy -CaBundle $CaBundle
    Copy-ScriptsToHooksDir -ScriptPaths @(Get-ChildItem -LiteralPath "$PSScriptRoot\hooks" -Filter '*.ps1' | ForEach-Object { $_.FullName })
    $ca = Invoke-KserveKubectl -Params 'get', 'configmap', 'k2s-kserve-ca', '-n', 'kserve', '--ignore-not-found', '-o', 'json'
    $caPem = ''
    if ($ca) { $caPem = ($ca | ConvertFrom-Json -ErrorAction Stop).data.'cabundle.crt' }
    Add-AddonToSetupJson -Addon ([pscustomobject]@{ Name = 'kserve'; Model = $Model; Proxy = $Proxy; CaBundlePem = $caPem })
    Write-Log "[KServe] Addon enabled (model: $Model). See addons\kserve\README.md for access and offline model preparation." -Console
}
catch {
    Write-Log "[KServe] Enable failed: $($_.Exception.Message)" -Error -ErrorAction Continue
    if ($EncodeStructuredOutput) {
        $err = New-Error -Code $errorCode -Message $_.Exception.Message
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }
    throw
}
finally {
    if ($restoredCaFile) { Remove-Item -LiteralPath $restoredCaFile -Force -ErrorAction Stop }
}
if ($EncodeStructuredOutput) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
