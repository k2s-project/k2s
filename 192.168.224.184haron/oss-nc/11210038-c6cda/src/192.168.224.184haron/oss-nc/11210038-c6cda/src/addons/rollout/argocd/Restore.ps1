# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Restores rollout argocd configuration/resources.

.DESCRIPTION
Restores ArgoCD state via `argocd admin import -n rollout` from a staging folder.
This restore is intentionally scoped to the rollout namespace only.

The CLI restore flow enables the addon first; this script restores the backed up
ArgoCD export and optional ingress resources afterwards.

.PARAMETER BackupDir
Directory containing backup.json and referenced files.

.EXAMPLE
powershell <installation folder>\addons\rollout\argocd\Restore.ps1 -BackupDir C:\Temp\rollout-argocd-restore
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

Write-Log "[AddonRestore] Restoring addon 'rollout argocd'" -Console

# Sanity-check the backup metadata (best-effort warnings only).
$expectedAddon = 'rollout'
$expectedImplementation = 'argocd'
$expectedScope = 'namespace:rollout'

try {
    if ($null -ne $manifest.addon -and ("$($manifest.addon)" -ne $expectedAddon)) {
        Write-Log "[AddonRestore] Warning: backup.json addon is '$($manifest.addon)' (expected '$expectedAddon')." -Console
    }
    if ($null -ne $manifest.implementation -and ("$($manifest.implementation)" -ne $expectedImplementation)) {
        Write-Log "[AddonRestore] Warning: backup.json implementation is '$($manifest.implementation)' (expected '$expectedImplementation')." -Console
    }
    if ($null -ne $manifest.scope -and ("$($manifest.scope)" -ne $expectedScope)) {
        Write-Log "[AddonRestore] Warning: backup scope is '$($manifest.scope)'. This restore expects '$expectedScope' and will apply/import into namespace 'rollout'." -Console
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

function Remove-ArgoCdExportNoise {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text
    )

    if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) {
        $Text = $Text.Substring(1)
    }

    $lines = @($Text -split "`r?`n")

    # Drop any kubectl preamble before the YAML stream starts.
    $startIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(apiVersion:|kind:|---\s*$)') {
            $startIndex = $i
            break
        }
    }

    if ($startIndex -lt 0) {
        # If we cannot find a YAML marker, return original text.
        return $Text
    }

    $slice = $lines[$startIndex..($lines.Count - 1)]

    # Strip known kubectl exec noise from the end (postamble).
    $endIndex = $slice.Count - 1
    while ($endIndex -ge 0) {
        $line = $slice[$endIndex]
        if ([string]::IsNullOrWhiteSpace($line)) { $endIndex--; continue }
        if ($line -match '^command terminated with exit code') { $endIndex--; continue }
        if ($line -match '^Defaulted container ') { $endIndex--; continue }
        if ($line -match '^(warning:|error:)') { $endIndex--; continue }
        if ($line -match '^W\d{4}\s') { $endIndex--; continue }
        if ($line -match '^time="\d{4}-\d{2}-\d{2}T') { $endIndex--; continue }
        break
    }

    if ($endIndex -lt 0) {
        return ''
    }

    return (($slice[0..$endIndex]) -join "`n")
}

function Resolve-ArgoCdCli {
    [CmdletBinding()]
    param()

    $candidate1 = Join-Path (Get-ClusterInstalledFolder) 'bin\argocd.exe'
    if (Test-Path -LiteralPath $candidate1) {
        return [pscustomobject]@{ Mode = 'host'; Path = $candidate1 }
    }

    $candidate2 = Join-Path (Get-KubeBinPath) 'argocd.exe'
    if (Test-Path -LiteralPath $candidate2) {
        return [pscustomobject]@{ Mode = 'host'; Path = $candidate2 }
    }

    return [pscustomobject]@{ Mode = 'pod'; Path = $null }
}

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
    # Ensure ArgoCD is ready before import.
    Write-Log "[AddonRestore] Waiting for ArgoCD workloads in namespace 'rollout'" -Console

    $deployWait = Invoke-Kubectl -Params 'rollout', 'status', 'deployments', '-n', 'rollout', '--timeout=300s'
    if (-not $deployWait.Success) {
        throw "ArgoCD deployments not ready: $($deployWait.Output)"
    }

    $stsWait = Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', 'rollout', '--timeout=300s'
    if (-not $stsWait.Success) {
        throw "ArgoCD statefulsets not ready: $($stsWait.Output)"
    }

    # Apply optional k8s resources (ingress/middleware)
    foreach ($file in $manifest.files) {
        if ($file -eq 'argocd-export.yaml') {
            continue
        }

        if ($file -eq 'argocd-ingress-nginx.json' -and $activeIngress -ne 'nginx') {
            Write-Log "[AddonRestore] Skipping nginx ingress from backup (active: $activeIngress)" -Console
            continue
        }
        if ($file -eq 'argocd-ingress-traefik.json' -and $activeIngress -ne 'traefik') {
            Write-Log "[AddonRestore] Skipping traefik ingress from backup (active: $activeIngress)" -Console
            continue
        }
        if ($file -eq 'argocd-traefik-middleware.json' -and $activeIngress -ne 'traefik') {
            Write-Log "[AddonRestore] Skipping traefik middleware from backup (active: $activeIngress)" -Console
            continue
        }
        if ($file -match '^argocd-ingress-nginx-gw-' -and $activeIngress -ne 'nginx-gw') {
            Write-Log "[AddonRestore] Skipping nginx-gw resource from backup (active: $activeIngress)" -Console
            continue
        }

        $filePath = Join-Path $BackupDir $file
        if (-not (Test-Path -LiteralPath $filePath)) {
            throw "Backup file not found: $file"
        }

        Invoke-ApplyWithConflictFallback -FilePath $filePath
    }

    # Import ArgoCD state
    $exportPath = Join-Path $BackupDir 'argocd-export.yaml'
    if (-not (Test-Path -LiteralPath $exportPath)) {
        throw "ArgoCD export file not found: argocd-export.yaml"
    }

    # Sanitize export YAML (some kubectl exec messages can accidentally end up in the file).
    $cleanExportPath = Join-Path $BackupDir 'argocd-export.cleaned.yaml'
    $rawExport = Get-Content -LiteralPath $exportPath -Raw
    $cleanExport = Remove-ArgoCdExportNoise -Text $rawExport
    if ([string]::IsNullOrWhiteSpace($cleanExport)) {
        throw 'Sanitized ArgoCD export content is empty'
    }
    [System.IO.File]::WriteAllText($cleanExportPath, $cleanExport, (New-Object System.Text.UTF8Encoding($false)))

    $argoCli = Resolve-ArgoCdCli

    # Best-effort local YAML parse check before handing it to argocd.
    $kubectlExe = Join-Path (Get-KubeBinPath) 'kubectl.exe'
    if (-not (Test-Path -LiteralPath $kubectlExe)) {
        $kubectlExe = 'kubectl'
    }

    $parseOut = & $kubectlExe apply --dry-run=client --validate=false -f $cleanExportPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "argocd export YAML is not parseable by kubectl: $parseOut"
    }

    Write-Log "[AddonRestore] Importing ArgoCD state via argocd admin import" -Console
    if ($argoCli.Mode -eq 'host') {
        $importOut = Get-Content -Raw -Path $cleanExportPath | & $argoCli.Path admin import -n rollout - 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "argocd admin import failed: $importOut"
        }
    }
    else {
        # Import inside the argocd-server pod. This avoids requiring argocd.exe on the host.
        $importOut = Get-Content -Raw -Path $cleanExportPath | & $kubectlExe -n rollout exec -i deploy/argocd-server -c argocd-server -- argocd admin import -n rollout - 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "argocd admin import (pod) failed: $importOut"
        }
    }

    # Reduce risk of credentials lingering in staging.
    Remove-Item -LiteralPath $exportPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $cleanExportPath -Force -ErrorAction SilentlyContinue

    # Ensure ingress + linkerd integration is consistent with current cluster setup.
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Update.ps1')) {
        Write-Log "[AddonRestore] Running argocd Update.ps1" -Console
        &"$PSScriptRoot\Update.ps1"
    }
}
catch {
    $errMsg = "Restore of addon 'rollout argocd' failed: $($_.Exception.Message)"

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
