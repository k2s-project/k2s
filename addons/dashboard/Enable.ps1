# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs Headlamp - Kubernetes Dashboard UI

.EXAMPLE
k2s addons enable dashboard
k2s addons enable dashboard --ingress nginx --enable-metrics
#>

[CmdletBinding(SupportsShouldProcess = $true)]
Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Enable ingress addon')]
    [ValidateSet('nginx', 'nginx-gw', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'Enable metrics addon')]
    [switch] $EnableMetricsServer = $false,
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
$dashboardModule = "$PSScriptRoot\dashboard.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $dashboardModule

Initialize-Logging -ShowLogs:$ShowLogs

trap { if ($EncodeStructuredOutput) { Send-ToCli -MessageType $MessageType -Message @{Error = (New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $_.Exception.Message)}; return }; throw }
if (-not [string]::IsNullOrWhiteSpace($InfraNodeSelector) -and ($EnableMetricsServer -or $Ingress -ne 'none')) {
    throw 'Enable the requested ingress and metrics addons separately before enabling dashboard with infrastructure placement.'
}

Write-Log '[Dashboard] Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'dashboard' can only be enabled for 'k2s' setup type."
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'dashboard' })) -eq $true) {
    $errMsg = Get-AddonPlacementSelectorConflictMessage -Name 'dashboard' -RequestedSelector $InfraNodeSelector
    if ([string]::IsNullOrWhiteSpace($errMsg)) { $errMsg = "Addon 'dashboard' is already enabled, nothing to do." }

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$preflightValues = $null
if (-not [string]::IsNullOrWhiteSpace($InfraNodeSelector)) {
    try {
        $preflightValues = New-AddonPlacementManifest -AddonName 'dashboard' -ManifestDirectory (Get-HeadlampChartDirectory) -Selector $InfraNodeSelector
    }
    finally {
        if ($preflightValues) { Remove-Item -LiteralPath $preflightValues -Force -ErrorAction SilentlyContinue }
    }
}

if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

if ($EnableMetricsServer) {
    Enable-MetricsServer
}

# Enabling ingress can run nested scripts that force-reload dashboard.module in a
# child scope; ensure dashboard commands are present in the current scope.
if (-not (Get-Command Install-HeadlampViaHelm -ErrorAction SilentlyContinue)) {
    Write-Log '[Dashboard] Re-importing dashboard module after nested addon execution' -Console
    Import-Module $dashboardModule -Force
}

Write-Log '[Dashboard] Installing Headlamp via Helm' -Console

try {
    $addonConfig = [pscustomobject]@{ Name = 'dashboard' }
    $hasMatchingNodes = $true
    if (-not [string]::IsNullOrWhiteSpace($InfraNodeSelector)) {
        $addonConfig | Add-Member -NotePropertyName InfraNodeSelector -NotePropertyValue $InfraNodeSelector
        $hasMatchingNodes = Test-AddonInfrastructureSelectorOnCluster -Name 'dashboard' -Selector $InfraNodeSelector
    }
    $apply = {
        Install-HeadlampViaHelm -InfraNodeSelector $InfraNodeSelector
        return [pscustomobject]@{ Success = $true; Output = '' }
    }
    $wait = { Wait-ForHeadlampAvailable }
    $update = { & "$PSScriptRoot\Update.ps1" -InfraNodeSelector $InfraNodeSelector -PreferredIngress $(if ($Ingress -eq 'none') { 'auto' } else { $Ingress }) }
    $configurePending = { & "$PSScriptRoot\Update.ps1" -InfraNodeSelector $InfraNodeSelector -PreferredIngress $(if ($Ingress -eq 'none') { 'auto' } else { $Ingress }) -SkipReadiness }
    $rollback = { Invoke-Kubectl -Params 'delete', 'deployment', 'headlamp', '-n', 'dashboard', '--ignore-not-found' }
    Invoke-AddonEnableTransaction -Addon $addonConfig -Selector $InfraNodeSelector -HasMatchingNodes $hasMatchingNodes -Apply $apply -Wait $wait -Update $update -ConfigurePending $configurePending -Rollback $rollback
}
catch {
    $errMsg = "Failed to install Headlamp via Helm: $($_.Exception.Message)"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

Write-Log '[Dashboard] Syncing Headlamp plugins' -Console
# Plugin activation is an optional, capability-driven enhancement layered on top of an
# already-enabled dashboard (Helm release installed + addon registered in setup.json).
# A transient sync failure (e.g. a kubectl patch error) must NOT leave the dashboard in
# a registered-but-failed state: the plugin reconciliation is idempotent and re-runs on
# every Update.ps1 and subsequent enable, so degrade gracefully with a warning instead.
try {
    Sync-HeadlampPlugins -SkipReadiness:(!$hasMatchingNodes)
}
catch {
    Write-Log "[Dashboard] Headlamp plugin sync failed (dashboard remains enabled; plugins will reconcile on the next 'k2s addons enable dashboard' or update): $($_.Exception.Message)" -Console
}

Write-HeadlampUsageForUser
Write-BrowserWarningForUser

Write-Log '[Dashboard] Installation of Headlamp dashboard finished.' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
