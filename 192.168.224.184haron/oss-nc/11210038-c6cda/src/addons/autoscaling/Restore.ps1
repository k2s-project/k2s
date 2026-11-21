# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Restores autoscaling (KEDA) configuration/resources

.DESCRIPTION
Applies previously exported Kubernetes resources from a staging folder.
The addon is enabled by the CLI before running this restore.

.PARAMETER BackupDir
Directory containing backup.json and the referenced files.

.EXAMPLE
powershell <installation folder>\addons\autoscaling\Restore.ps1 -BackupDir C:\Temp\autoscaling-backup
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

Write-Log "[AddonRestore] Restoring addon 'autoscaling'" -Console

if (-not $manifest.files -or $manifest.files.Count -eq 0) {
    Write-Log "[AddonRestore] backup.json contains no files; nothing to apply. Autoscaling restore is reinstall/repair-only (handled by the CLI enable step)." -Console

    Write-Log "[AddonRestore] Restore completed" -Console
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
    }
    return
}

$namespace = 'autoscaling'

function Get-NamespaceInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $nsResult = Invoke-Kubectl -Params 'get', 'namespace', $Name, '-o', 'json'
    if (-not $nsResult.Success) {
        return [pscustomobject]@{ Exists = $false; Terminating = $false; DeletionTimestamp = $null }
    }

    try {
        $ns = $nsResult.Output | ConvertFrom-Json
        $deletionTimestamp = $ns.metadata.deletionTimestamp
        return [pscustomobject]@{
            Exists            = $true
            Terminating       = -not [string]::IsNullOrWhiteSpace("$deletionTimestamp")
            DeletionTimestamp = $deletionTimestamp
        }
    }
    catch {
        return [pscustomobject]@{ Exists = $true; Terminating = $false; DeletionTimestamp = $null }
    }
}

$nsInfo = Get-NamespaceInfo -Name $namespace
if ($nsInfo.Exists -and $nsInfo.Terminating) {
    $errMsg = "Namespace '$namespace' is terminating (deletionTimestamp=$($nsInfo.DeletionTimestamp)). Wait for it to be deleted (or remove finalizers) and re-run restore."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

# Best-effort readiness wait (do not hard-fail if KEDA operator is unhealthy)
try {
    Write-Log "[AddonRestore] Waiting for core KEDA pods to be Ready (best-effort)" -Console

    $admissionOk = Wait-ForPodCondition -Condition Ready -Label 'app=keda-admission-webhooks' -Namespace $namespace -TimeoutSeconds 120
    if ($admissionOk -ne $true) {
        Write-Log "[AddonRestore] Warning: keda-admission-webhooks pod(s) did not become Ready in time" -Console
    }

    $metricsOk = Wait-ForPodCondition -Condition Ready -Label 'app=keda-metrics-apiserver' -Namespace $namespace -TimeoutSeconds 120
    if ($metricsOk -ne $true) {
        Write-Log "[AddonRestore] Warning: keda-metrics-apiserver pod(s) did not become Ready in time" -Console
    }

    $operatorOk = Wait-ForPodCondition -Condition Ready -Label 'app=keda-operator' -Namespace $namespace -TimeoutSeconds 120
    if ($operatorOk -ne $true) {
        Write-Log "[AddonRestore] Warning: keda-operator pod(s) did not become Ready in time" -Console
    }
}
catch {
    Write-Log "[AddonRestore] Warning: readiness check failed: $($_.Exception.Message)" -Console
}

function Invoke-ApplyWithConflictFallback {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath
    )

    function Test-IsNamespaceManifest {
        param([Parameter(Mandatory = $true)][string] $Path)

        try {
            $content = Get-Content -Raw -Path $Path -ErrorAction Stop
            return ($content -match "(?mi)^\\s*kind:\\s*Namespace\\s*$")
        }
        catch {
            return $false
        }
    }

    if (Test-IsNamespaceManifest -Path $FilePath) {
        # The autoscaling namespace is managed by the addon manifests; restoring a captured Namespace object is not required
        # and can cause conflicts/termination issues.
        Write-Log "[AddonRestore] Skipping Namespace manifest '$FilePath' (managed by addon)" -Console
        return
    }

    $applyResult = Invoke-Kubectl -Params 'apply', '--request-timeout=60s', '-f', $FilePath
    if ($applyResult.Success) {
        if (-not [string]::IsNullOrWhiteSpace($applyResult.Output)) {
            $applyResult.Output | Write-Log
        }
        return
    }

    $outputText = "$($applyResult.Output)"
    if ($outputText -match '(the object has been modified|Error from server \(Conflict\)|conflict)') {
        Write-Log "[AddonRestore] Detected conflict during apply; retrying with server-side apply --force-conflicts for '$FilePath'" -Console

        $ssaResult = Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '--field-manager=k2s-addon-restore', '--request-timeout=60s', '-f', $FilePath
        if (-not $ssaResult.Success) {
            throw "Failed to apply '$FilePath' (conflict) and server-side apply also failed: $($ssaResult.Output)"
        }

        if (-not [string]::IsNullOrWhiteSpace($ssaResult.Output)) {
            $ssaResult.Output | Write-Log
        }
        return
    }

    throw "Failed to apply '$FilePath': $outputText"
}

try {
    foreach ($file in $manifest.files) {
        $filePath = Join-Path $BackupDir $file
        if (-not (Test-Path -LiteralPath $filePath)) {
            throw "Backup file not found: $file"
        }

        if ((Split-Path -Leaf $filePath) -like '*namespace*.y*ml') {
            Write-Log "[AddonRestore] Skipping Namespace backup file '$file'" -Console
            continue
        }

        Invoke-ApplyWithConflictFallback -FilePath $filePath
    }
}
catch {
    $errMsg = "Restore of addon 'autoscaling' failed: $($_.Exception.Message)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log "[AddonRestore] Restore completed" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
