# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Restores dashboard addon configuration from a backup staging folder.

.PARAMETER BackupDir
Directory containing extracted backup artifacts (including backup.json).
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Directory where backup files were extracted')]
    [string] $BackupDir,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dashboardModule = "$PSScriptRoot\dashboard.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $dashboardModule

Initialize-Logging -ShowLogs:$ShowLogs

function Fail([string]$errMsg, [string]$code = 'addon-restore-failed') {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code $code -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        exit 1
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log "[DashboardRestore] Restoring addon 'dashboard' (Headlamp)" -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Fail $systemError.Message 'system-not-available'
}

if (-not (Test-Path -Path $BackupDir)) {
    Fail "BackupDir '$BackupDir' does not exist." 'backupdir-not-found'
}

$manifestPath = Join-Path $BackupDir 'backup.json'
if (-not (Test-Path -Path $manifestPath)) {
    Fail "Missing backup.json in '$BackupDir'" 'manifest-missing'
}

$manifest = $null
try {
    $manifest = (Get-Content -Path $manifestPath -Raw) | ConvertFrom-Json
}
catch {
    Fail "Failed to parse backup.json: $($_.Exception.Message)" 'manifest-invalid'
}

$desiredIngress = 'none'
if ($manifest.PSObject.Properties.Name -contains 'ingress') {
    $desiredIngress = [string]$manifest.ingress
}

$desiredEnableMetrics = $false
if ($manifest.PSObject.Properties.Name -contains 'enableMetrics') {
    $desiredEnableMetrics = [bool]$manifest.enableMetrics
}

# Normalize (Windows PowerShell 5.1 compatible)
if ([string]::IsNullOrWhiteSpace($desiredIngress)) {
    $desiredIngress = 'none'
}
else {
    $desiredIngress = $desiredIngress.Trim().ToLowerInvariant()
}
if ($desiredIngress -notin @('none', 'nginx', 'traefik', 'nginx-gw')) {
    Write-Log "[DashboardRestore] Unknown ingress '$desiredIngress' in backup.json; falling back to 'none'" -Console
    $desiredIngress = 'none'
}

try {
    if ($desiredEnableMetrics -eq $true) {
        if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{ Name = 'metrics' })) -ne $true) {
            Write-Log "[DashboardRestore] Enabling metrics addon (requested by backup)" -Console
            &"$PSScriptRoot\..\metrics\Enable.ps1" -ShowLogs:$ShowLogs
        }
        else {
            Write-Log "[DashboardRestore] Metrics addon already enabled" -Console
        }
    }

    if ($desiredIngress -ne 'none') {
        Write-Log "[DashboardRestore] Ensuring ingress addon '$desiredIngress' is enabled" -Console
        Enable-IngressAddon -Ingress:$desiredIngress
    }

    Write-Log "[DashboardRestore] Applying dashboard ingress integration (preferred: $desiredIngress)" -Console
    $selector = Get-AddonEffectiveInfrastructureSelector -Name 'dashboard' -Selector (Get-AddonBackupInfrastructureSelector -BackupDir $BackupDir)
    &"$PSScriptRoot\Update.ps1" -PreferredIngress $desiredIngress -InfraNodeSelector $selector

    Write-Log "[DashboardRestore] Waiting for Headlamp to become ready" -Console
    $ok = if (-not [string]::IsNullOrWhiteSpace($selector) -and -not (Test-AddonInfrastructureSelectorOnCluster -Name 'dashboard' -Selector $selector)) { $true } else { Wait-ForHeadlampAvailable }
    if (-not $ok) {
        throw "Headlamp dashboard pods did not become ready after restore."
    }
}
catch {
    Fail "Restore of addon 'dashboard' failed: $($_.Exception.Message)"
}

Write-Log "[DashboardRestore] Restore finished" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
