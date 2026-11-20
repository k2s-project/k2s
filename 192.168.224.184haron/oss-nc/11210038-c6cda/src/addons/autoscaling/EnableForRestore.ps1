# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Installs KEDA (restore mode)

.DESCRIPTION
Restore-specific enable hook for the autoscaling addon.
It applies the KEDA manifest, but only performs best-effort readiness checks.
This allows `k2s addons restore autoscaling` to proceed even if the keda-operator pod is unhealthy.

.EXAMPLE
powershell <installation folder>\addons\autoscaling\EnableForRestore.ps1
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing backup.json (passed by CLI, unused by this addon)')]
    [string] $BackupDir,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

$kedaManifest = "$PSScriptRoot\manifests\keda.yaml"

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
        # If parsing fails, assume namespace exists and is not terminating.
        return [pscustomobject]@{ Exists = $true; Terminating = $false; DeletionTimestamp = $null }
    }
}

function Wait-ForNamespaceDeleted {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [int] $TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $info = Get-NamespaceInfo -Name $Name
        if (-not $info.Exists) {
            return $true
        }

        Start-Sleep -Seconds 5
    }

    return $false
}

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'autocaling' can only be enabled for 'k2s' setup type."
    Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
    return
}

Write-Log 'Installing KEDA (restore mode)' -Console

$nsName = 'autoscaling'
$nsInfo = Get-NamespaceInfo -Name $nsName
if ($nsInfo.Exists -and $nsInfo.Terminating) {
    $errMsg = "Namespace '$nsName' is terminating (deletionTimestamp=$($nsInfo.DeletionTimestamp)). Waiting for it to be deleted before re-installing KEDA..."
    Write-Log "[EnableForRestore] $errMsg" -Console

    if (-not (Wait-ForNamespaceDeleted -Name $nsName -TimeoutSeconds 300)) {
        $errMsg = "Namespace '$nsName' is still terminating after 300s. Resolve namespace deletion/finalizers and retry restore."
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }
}

$applyResult = (Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '--field-manager=k2s-addon-restore', '-f', $kedaManifest)
if (-not $applyResult.Success) {
    $errMsg = "Failed to apply KEDA manifests: $($applyResult.Output)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$applyResult.Output | Write-Log

# Best-effort readiness checks; do not fail restore enable step.
try {
    $ns = 'autoscaling'

    $okAdmission = Wait-ForPodCondition -Condition Ready -Label 'app=keda-admission-webhooks' -Namespace $ns -TimeoutSeconds 120
    if ($okAdmission -ne $true) { Write-Log "[EnableForRestore] Warning: keda-admission-webhooks not Ready" -Console }

    $okMetrics = Wait-ForPodCondition -Condition Ready -Label 'app=keda-metrics-apiserver' -Namespace $ns -TimeoutSeconds 120
    if ($okMetrics -ne $true) { Write-Log "[EnableForRestore] Warning: keda-metrics-apiserver not Ready" -Console }

    $okOperator = Wait-ForPodCondition -Condition Ready -Label 'app=keda-operator' -Namespace $ns -TimeoutSeconds 120
    if ($okOperator -ne $true) { Write-Log "[EnableForRestore] Warning: keda-operator not Ready" -Console }
}
catch {
    Write-Log "[EnableForRestore] Warning: readiness checks failed: $($_.Exception.Message)" -Console
}

&"$PSScriptRoot\Update.ps1"

Add-AddonToSetupJson -Addon ([pscustomobject] @{ Name = 'autoscaling' })

Write-Log 'Installation of autoscaling addon finished (restore mode).' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
