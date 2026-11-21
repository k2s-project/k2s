# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Restores dicom configuration/resources.

.DESCRIPTION
Restores the Orthanc configuration ConfigMap (json-configmap) and optional ingress/middleware
resources from a staging folder.

The CLI restore flow enables the addon first; this script restores the backed up
config-only resources afterwards.

.PARAMETER BackupDir
Directory containing backup.json and referenced files.

.EXAMPLE
powershell <installation folder>\addons\dicom\Restore.ps1 -BackupDir C:\Temp\dicom-restore
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

$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

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

Write-Log "[AddonRestore] Restoring addon 'dicom'" -Console

try {
    if ($null -ne $manifest.addon -and ("$($manifest.addon)" -ne 'dicom')) {
        Write-Log "[AddonRestore] Warning: backup.json addon is '$($manifest.addon)' (expected 'dicom')." -Console
    }
    if ($null -ne $manifest.scope -and ("$($manifest.scope)" -ne 'namespace:dicom')) {
        Write-Log "[AddonRestore] Warning: backup scope is '$($manifest.scope)'. This restore expects 'namespace:dicom'." -Console
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

    # Traefik CRDs may not exist (e.g., nginx ingress). Treat missing resource types as optional.
    if ($outputText -match '(the server doesn\x27t have a resource type|no matches for kind)') {
        Write-Log "[AddonRestore] Resource type not available for '$FilePath'; skipping." -Console
        return
    }

    throw "Failed to apply '$FilePath': $outputText"
}

try {
    Write-Log "[AddonRestore] Waiting for DICOM workloads in namespace 'dicom'" -Console

    $deployWait = Invoke-Kubectl -Params 'rollout', 'status', 'deployments', '-n', 'dicom', '--timeout=300s'
    if (-not $deployWait.Success) {
        throw "DICOM deployments not ready: $($deployWait.Output)"
    }

    $configRestored = $false

    foreach ($file in $manifest.files) {
        $filePath = Join-Path $BackupDir $file
        if (-not (Test-Path -LiteralPath $filePath)) {
            throw "Backup file not found: $file"
        }

        if ($file -eq 'dicom-ingress-nginx.json' -and $activeIngress -ne 'nginx') {
            Write-Log "[AddonRestore] Skipping nginx ingress from backup (active: $activeIngress)" -Console
            continue
        }

        if ($file -match '^dicom-ingress-traefik' -and $activeIngress -ne 'traefik') {
            Write-Log "[AddonRestore] Skipping traefik ingress from backup (active: $activeIngress)" -Console
            continue
        }

        if ($file -match '^dicom-traefik-middleware' -and $activeIngress -ne 'traefik') {
            Write-Log "[AddonRestore] Skipping traefik middleware from backup (active: $activeIngress)" -Console
            continue
        }

        if ($file -match '^dicom-ingress-nginx-gw-' -and $activeIngress -ne 'nginx-gw') {
            Write-Log "[AddonRestore] Skipping nginx-gw resource from backup (active: $activeIngress)" -Console
            continue
        }

        Invoke-ApplyWithConflictFallback -FilePath $filePath

        if ($file -eq 'dicom-json-configmap.json') {
            $configRestored = $true
        }
    }

    if ($configRestored) {
        Write-Log "[AddonRestore] Restarting DICOM deployment to apply configuration changes" -Console
        (Invoke-Kubectl -Params 'rollout', 'restart', 'deployment', 'dicom', '-n', 'dicom').Output | Write-Log
        $rollout = Invoke-Kubectl -Params 'rollout', 'status', 'deployment', 'dicom', '-n', 'dicom', '--timeout=180s'
        if (-not $rollout.Success) {
            throw "DICOM deployment did not become ready after config restore: $($rollout.Output)"
        }
    }

    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Update.ps1')) {
        Write-Log "[AddonRestore] Running dicom Update.ps1" -Console
        &"$PSScriptRoot\Update.ps1"
    }
}
catch {
    $errMsg = "Restore of addon 'dicom' failed: $($_.Exception.Message)"

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
