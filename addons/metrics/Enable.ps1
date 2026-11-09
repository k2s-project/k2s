# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs Kubernetes Metrics Server

.DESCRIPTION
NA

.EXAMPLE
# For k2s setup
powershell <installation folder>\addons\metrics\Enable.ps1
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Hard node selector for the metrics-server Pod')]
    [string] $InfraNodeSelector = '',
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
$metricsModule = "$PSScriptRoot\metrics.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $metricsModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'metrics' })) -eq $true) {
    $errMsg = Get-AddonPlacementSelectorConflictMessage -Name 'metrics' -RequestedSelector $InfraNodeSelector
    if ([string]::IsNullOrWhiteSpace($errMsg)) {
        $errMsg = "Addon 'metrics' is already enabled, nothing to do."
    }

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

$InfraNodeSelector = Get-AddonEffectiveInfrastructureSelector -Name 'metrics' -Selector $InfraNodeSelector
Write-Log 'Installing Kubernetes Metrics Server' -Console
$metricsManifest = Get-MetricsServerConfig
$renderedPlacementManifest = $null
$hasMatchingNodes = $true
$addonConfig = [pscustomobject] @{Name = 'metrics' }
if (-not [string]::IsNullOrWhiteSpace($InfraNodeSelector)) {
    $renderedPlacementManifest = New-AddonPlacementManifest -AddonName 'metrics' -ManifestDirectory "$PSScriptRoot\manifests" -Selector $InfraNodeSelector
    $metricsManifest = $renderedPlacementManifest
    $addonConfig | Add-Member -NotePropertyName InfraNodeSelector -NotePropertyValue $InfraNodeSelector
    $hasMatchingNodes = Test-AddonInfrastructureSelectorOnCluster -Name 'metrics' -Selector $InfraNodeSelector
}

$apply = {
    $metricsApplyResult = Invoke-Kubectl -Params 'apply', '-f', $metricsManifest
    $metricsApplyResult.Output | Write-Log
    if (-not $metricsApplyResult.Success) {
        return $metricsApplyResult
    }

    Write-Log 'Deploying Windows Exporter for Windows node metrics' -Console
    $windowsExporterPath = "$PSScriptRoot\..\common\manifests\windows-exporter"
    (Invoke-Kubectl -Params 'apply', '-k', $windowsExporterPath).Output | Write-Log
    return $metricsApplyResult
}
$wait = { Wait-ForPodCondition -Condition Ready -Label 'k8s-app=metrics-server' -Namespace 'metrics' -TimeoutSeconds 900 }
$update = { & "$PSScriptRoot\Update.ps1" }
$rollback = { Invoke-Kubectl -Params 'delete', 'deployment', 'metrics-server', '-n', 'metrics', '--ignore-not-found' }

try {
    Invoke-AddonEnableTransaction -Addon $addonConfig -Selector $InfraNodeSelector -HasMatchingNodes $hasMatchingNodes -Apply $apply -Wait $wait -Update $update -Rollback $rollback
}
catch {
    $errMsg = "Installation of metrics-server failed: $($_.Exception.Message)"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}
finally {
    if ($renderedPlacementManifest) {
        Remove-Item -LiteralPath $renderedPlacementManifest -Force -ErrorAction SilentlyContinue
    }
}

Write-Log 'All metric server pods are up and ready.' -Console

Write-Log 'Installation of Kubernetes Metrics Server finished.' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
