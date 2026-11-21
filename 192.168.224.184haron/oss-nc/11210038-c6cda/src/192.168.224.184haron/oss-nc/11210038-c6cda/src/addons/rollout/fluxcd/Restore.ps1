# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Restores rollout fluxcd configuration/resources.

.DESCRIPTION
Applies previously exported FluxCD configuration from a staging folder.
This restore is intentionally scoped to the rollout namespace only.

The CLI restore flow enables the addon first; this script restores the backed up
Flux custom resources and referenced Secrets afterwards.

Ingress resources (webhook receiver exposure) are restored only if the respective
ingress controller is currently available.

.PARAMETER BackupDir
Directory containing backup.json and referenced files.

.EXAMPLE
powershell <installation folder>\addons\rollout\fluxcd\Restore.ps1 -BackupDir C:\Temp\rollout-fluxcd-restore
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Directory containing backup.json and referenced files')]
    [string] $BackupDir,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$manifestPath = Join-Path $BackupDir 'backup.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    $errMsg = "backup.json not found in '$BackupDir'"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json

Write-Log "[AddonRestore] Restoring addon 'rollout fluxcd'" -Console

# Sanity-check the backup metadata (best-effort warnings only).
$expectedAddon = 'rollout'
$expectedImplementation = 'fluxcd'
$expectedScope = 'namespace:rollout'

try {
    if ($null -ne $manifest.addon -and ("$($manifest.addon)" -ne $expectedAddon)) {
        Write-Log "[AddonRestore] Warning: backup.json addon is '$($manifest.addon)' (expected '$expectedAddon')." -Console
    }
    if ($null -ne $manifest.implementation -and ("$($manifest.implementation)" -ne $expectedImplementation)) {
        Write-Log "[AddonRestore] Warning: backup.json implementation is '$($manifest.implementation)' (expected '$expectedImplementation')." -Console
    }
    if ($null -ne $manifest.scope -and ("$($manifest.scope)" -ne $expectedScope)) {
        Write-Log "[AddonRestore] Warning: backup scope is '$($manifest.scope)'. This restore expects '$expectedScope' and will apply objects into namespace 'rollout'." -Console
    }
    if ($null -eq $manifest.scope) {
        Write-Log "[AddonRestore] Warning: backup.json does not specify a scope. This restore operates on namespace 'rollout' only." -Console
    }
}
catch {
    Write-Log "[AddonRestore] Warning: failed to validate backup.json metadata: $($_.Exception.Message)" -Console
}

$activeIngress = 'none'
if (Test-NginxIngressControllerAvailability) {
    $activeIngress = 'nginx'
}
elseif (Test-TraefikIngressControllerAvailability) {
    $activeIngress = 'traefik'
}
elseif (Test-NginxGatewayAvailability) {
    $activeIngress = 'nginx-gw'
}
Write-Log "[AddonRestore] Detected active ingress mode: $activeIngress" -Console

function Invoke-ApplyWithConflictFallback {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath
    )

    $applyResult = Invoke-Kubectl -Params 'apply', '-f', $FilePath
    if ($applyResult.Success) {
        if (-not [string]::IsNullOrWhiteSpace($applyResult.Output)) {
            $applyResult.Output | Write-Log
        }
        return
    }

    $outputText = "$($applyResult.Output)"
    if ($outputText -match '(the object has been modified|Error from server \(Conflict\)|conflict)') {
        Write-Log "[AddonRestore] Detected conflict during apply; retrying with 'kubectl replace --force' for '$FilePath'" -Console

        $replaceResult = Invoke-Kubectl -Params 'replace', '--force', '-f', $FilePath
        if (-not $replaceResult.Success) {
            throw "Failed to apply '$FilePath' (conflict) and replace also failed: $($replaceResult.Output)"
        }

        if (-not [string]::IsNullOrWhiteSpace($replaceResult.Output)) {
            $replaceResult.Output | Write-Log
        }
        return
    }

    throw "Failed to apply '$FilePath': $outputText"
}

try {
    # Ensure Flux controllers are available before applying CRs.
    Write-Log "[AddonRestore] Waiting for deployments in namespace 'rollout' to be Available" -Console
    $waitResult = Invoke-Kubectl -Params 'wait', '--for=condition=available', '--timeout=180s', 'deployment', '--all', '-n', 'rollout'
    if (-not $waitResult.Success) {
        throw "Flux controllers not ready: $($waitResult.Output)"
    }

    foreach ($file in $manifest.files) {
        # Ingress objects are controller-specific.
        if ($file -eq 'fluxcd-ingress-nginx.json' -and $activeIngress -ne 'nginx') {
            Write-Log "[AddonRestore] Skipping nginx ingress from backup (active: $activeIngress)" -Console
            continue
        }
        if ($file -eq 'fluxcd-ingress-traefik.json' -and $activeIngress -ne 'traefik') {
            Write-Log "[AddonRestore] Skipping traefik ingress from backup (active: $activeIngress)" -Console
            continue
        }
        if ($file -match '^fluxcd-ingress-nginx-gw-' -and $activeIngress -ne 'nginx-gw') {
            Write-Log "[AddonRestore] Skipping nginx-gw resource from backup (active: $activeIngress)" -Console
            continue
        }

        $filePath = Join-Path $BackupDir $file
        if (-not (Test-Path -LiteralPath $filePath)) {
            throw "Backup file not found: $file"
        }

        Invoke-ApplyWithConflictFallback -FilePath $filePath
    }

    # Ensure ingress + linkerd integration is consistent with current cluster setup.
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Update.ps1')) {
        Write-Log "[AddonRestore] Running fluxcd Update.ps1" -Console
        &"$PSScriptRoot\Update.ps1"
    }
}
catch {
    $errMsg = "Restore of addon 'rollout fluxcd' failed: $($_.Exception.Message)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log '[AddonRestore] Restore completed' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
