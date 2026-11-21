# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Restores viewer configuration/resources.

.DESCRIPTION
Applies previously exported Kubernetes resources from a staging folder.
The addon is enabled first by the CLI restore flow; this script restores
the backed up configuration afterwards.

.PARAMETER BackupDir
Directory containing backup.json and the referenced files.

.EXAMPLE
powershell <installation folder>\addons\viewer\Restore.ps1 -BackupDir C:\Temp\viewer-backup
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

Write-Log "[AddonRestore] Restoring addon 'viewer'" -Console

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

Write-Log "[AddonRestore] Waiting for viewer deployment to be Available" -Console
Invoke-Kubectl -Params 'wait', '--timeout=120s', '--for=condition=Available', '-n', 'viewer', 'deployment/viewerwebapp' | Out-Null

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

    # Traefik CRDs may not exist (e.g., nginx ingress). If a backed-up Middleware cannot be applied,
    # treat it as optional so restore remains usable.
    if ($outputText -match '(the server doesn\x27t have a resource type|no matches for kind)') {
        Write-Log "[AddonRestore] Resource type not available for '$FilePath'; skipping." -Console
        return
    }

    throw "Failed to apply '$FilePath': $outputText"
}

try {
    foreach ($file in $manifest.files) {
        # Ingress resources are controller-specific. If the cluster now uses a different
        # ingress implementation than at backup time, skip mismatching ingress artifacts.
        if ($file -eq 'viewer-ingress-nginx.yaml' -and $activeIngress -ne 'nginx') {
            Write-Log "[AddonRestore] Skipping nginx ingress from backup (active: $activeIngress)" -Console
            continue
        }
        if ($file -eq 'viewer-ingress-traefik.yaml' -and $activeIngress -ne 'traefik') {
            Write-Log "[AddonRestore] Skipping traefik ingress from backup (active: $activeIngress)" -Console
            continue
        }
        if ($file -eq 'viewer-traefik-middleware.yaml' -and $activeIngress -ne 'traefik') {
            Write-Log "[AddonRestore] Skipping traefik middleware from backup (active: $activeIngress)" -Console
            continue
        }
        if ($file -match '^viewer-ingress-nginx-gw-' -and $activeIngress -ne 'nginx-gw') {
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
        Write-Log "[AddonRestore] Running viewer Update.ps1" -Console
        &"$PSScriptRoot\Update.ps1"
    }
}
catch {
    $errMsg = "Restore of addon 'viewer' failed: $($_.Exception.Message)"

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
