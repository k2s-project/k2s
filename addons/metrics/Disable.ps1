# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls Kubernetes Metrics Server

.DESCRIPTION
NA

.EXAMPLE
# For k2s setup
powershell <installation folder>\addons\metrics\Disable.ps1
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
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

$hasIncompleteIntent = Test-AddonHasIncompleteInstallationIntent -Name 'metrics'
if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'metrics' })) -ne $true -and -not $hasIncompleteIntent) {
    $errMsg = "Addon 'metrics' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ($hasIncompleteIntent) {
    Write-Log "Addon 'metrics' has an incomplete installation intent; cleaning up any partial resources" -Console
}

Write-Log 'Uninstalling Kubernetes Metrics Server' -Console
(Invoke-Kubectl -Params 'delete', '-f', (Get-MetricsServerConfig), '--ignore-not-found').Output | Write-Log

# Check if Windows Exporter is still needed by other addons
$monitoringEnabled = Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'monitoring' })

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'metrics' })

if (-not $monitoringEnabled) {
    Write-Log 'Removing Windows Exporter (no longer needed by any addon)' -Console
    $windowsExporterManifest = Get-WindowsExporterManifestDir
    (Invoke-Kubectl -Params 'delete', '-k', $windowsExporterManifest, '--ignore-not-found').Output | Write-Log
} else {
    Write-Log 'Windows Exporter kept (still needed by monitoring addon)' -Console
}

Write-Log 'Uninstallation of Kubernetes Metrics Server finished' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
