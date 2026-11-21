# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Restores metrics addon configuration

.DESCRIPTION
Applies previously exported Kubernetes objects (Deployment/APIService and Windows exporter resources) from the staging folder.
After applying configuration it triggers rollout restarts to ensure pods pick up changes.

.PARAMETER BackupDir
Directory containing extracted backup artifacts (staging folder).

.EXAMPLE
powershell <installation folder>\addons\metrics\Restore.ps1 -BackupDir C:\Temp\metrics-restore
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Back-up directory to restore data from.')]
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

function Fail([string]$errMsg) {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        exit 1
    }

    Write-Log $errMsg -Error
    exit 1
}

function Try-ApplyFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $leaf = Split-Path -Leaf $Path
    Write-Log "[MetricsRestore] Applying '$leaf'" -Console

    $result = Invoke-Kubectl -Params 'apply', '-f', $Path
    if (-not $result.Success) {
        Write-Log "[MetricsRestore] Warning: failed to apply '$leaf': $($result.Output)" -Console
        return $false
    }

    return $true
}

function Try-RolloutRestart {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Kind,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $false)]
        [string] $Namespace
    )

    $checkParams = @('get', $Kind, $Name)
    if ($Namespace) { $checkParams += @('-n', $Namespace) }
    $check = Invoke-Kubectl -Params $checkParams
    if (-not $check.Success) {
        return
    }

    $restartParams = @('rollout', 'restart', $Kind, $Name)
    if ($Namespace) { $restartParams += @('-n', $Namespace) }
    $restart = Invoke-Kubectl -Params $restartParams
    if (-not $restart.Success) {
        Write-Log "[MetricsRestore] Warning: rollout restart failed for ${Kind}/${Name}: $($restart.Output)" -Console
    }
}

function Try-RolloutStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Kind,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $false)]
        [string] $Namespace
    )

    $checkParams = @('get', $Kind, $Name)
    if ($Namespace) { $checkParams += @('-n', $Namespace) }
    $check = Invoke-Kubectl -Params $checkParams
    if (-not $check.Success) {
        return
    }

    $statusParams = @('rollout', 'status', $Kind, $Name, '--timeout=600s')
    if ($Namespace) { $statusParams += @('-n', $Namespace) }
    $status = Invoke-Kubectl -Params $statusParams
    if (-not $status.Success) {
        Write-Log "[MetricsRestore] Warning: rollout status failed for ${Kind}/${Name}: $($status.Output)" -Console
    }
}

Write-Log "[MetricsRestore] Restoring addon 'metrics'" -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Fail $systemError.Message
}

if (-not (Test-Path -LiteralPath $BackupDir)) {
    Fail "BackupDir not found: $BackupDir"
}

$filesToApply = @(
    (Join-Path $BackupDir 'metrics-server-deployment.json'),
    (Join-Path $BackupDir 'metrics-apiservice.json'),
    (Join-Path $BackupDir 'windows-exporter-config.json'),
    (Join-Path $BackupDir 'windows-exporter-daemonset.json'),
    (Join-Path $BackupDir 'windows-exporter-service.json'),
    (Join-Path $BackupDir 'windows-exporter-servicemonitor.json')
)

if (($filesToApply | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) {
    Write-Log "[MetricsRestore] No config files found in backup; nothing to restore (enable-only restore)." -Console
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
    }
    return
}

try {
    foreach ($f in $filesToApply) {
        [void](Try-ApplyFile -Path $f)
    }

    Try-RolloutRestart -Kind 'deployment' -Name 'metrics-server' -Namespace 'metrics'
    Try-RolloutRestart -Kind 'daemonset' -Name 'windows-exporter' -Namespace 'kube-system'

    Write-Log "[MetricsRestore] Waiting for workloads to be ready" -Console
    Try-RolloutStatus -Kind 'deployment' -Name 'metrics-server' -Namespace 'metrics'
    Try-RolloutStatus -Kind 'daemonset' -Name 'windows-exporter' -Namespace 'kube-system'

    Write-Log "[MetricsRestore] Restore completed" -Console
}
catch {
    Fail "Restore of addon 'metrics' failed: $($_.Exception.Message)"
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
