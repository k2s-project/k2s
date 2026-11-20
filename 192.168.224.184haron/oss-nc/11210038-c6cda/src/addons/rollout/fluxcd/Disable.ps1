# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Removes the rollout addon (Flux CD) from the cluster

.DESCRIPTION
Uninstalls Flux CD controllers and removes the rollout namespace

.EXAMPLE
Disable rollout with Flux
powershell <installation folder>\addons\rollout\fluxcd\Disable.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true)]
Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure')]
    [string] $MessageType
)

$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$rolloutModule = "$PSScriptRoot\rollout.module.psm1"
$dashboardModule = "$PSScriptRoot\..\..\dashboard\dashboard.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $rolloutModule

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

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'rollout' can only be disabled for 'k2s' setup type."
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if (-not (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'fluxcd'}))) {
    $errMsg = 'Addon rollout with Flux implementation is already disabled, nothing to do.'

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling Flux addon' -Console

# Clean up addon-sync infrastructure (if deployed)
Write-Log 'Cleaning up addon-sync infrastructure' -Console
(Invoke-Kubectl -Params 'delete', 'namespace', 'k2s-addon-sync', '--ignore-not-found', '--timeout=60s').Output | Write-Log

# Remove optional ingress manifests (silently skips if not present)
Remove-IngressForTraefik -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'fluxcd' })
Remove-IngressForNginx -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'fluxcd' })

Write-Log 'Removing FluxCD resources before stopping controllers...' -Console
(Invoke-Kubectl -Params 'delete', 'gitrepositories.source.toolkit.fluxcd.io', '--all', '-A', '--ignore-not-found', '--timeout=60s').Output | Write-Log
(Invoke-Kubectl -Params 'delete', 'ocirepositories.source.toolkit.fluxcd.io', '--all', '-A', '--ignore-not-found', '--timeout=60s').Output | Write-Log
(Invoke-Kubectl -Params 'delete', 'kustomizations.kustomize.toolkit.fluxcd.io', '--all', '-A', '--ignore-not-found', '--timeout=60s').Output | Write-Log
(Invoke-Kubectl -Params 'delete', 'helmreleases.helm.toolkit.fluxcd.io', '--all', '-A', '--ignore-not-found', '--timeout=60s').Output | Write-Log

Write-Log 'Uninstalling Flux resources...' -Console
$kustomizationDir = Get-FluxConfig
(Invoke-Kubectl -Params 'delete', '-k', $kustomizationDir).Output | Write-Log

Write-Log 'Deleting rollout namespace...' -Console
(Invoke-Kubectl -Params 'delete', 'namespace', 'rollout','--timeout', '60s').Output | Write-Log

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'fluxcd' })

if (Test-Path $dashboardModule) {
    Import-Module $dashboardModule -Force
    if (Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue) {
        Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins after Flux disable' -Console
        try {
            Sync-HeadlampPlugins
        }
        catch {
            # Plugin sync is best-effort: a failure here must not fail the primary addon operation.
            Write-Log "[Dashboard][Plugin] Headlamp plugin sync failed (Flux disable continues): $($_.Exception.Message)" -Console
        }
    }
}

Write-Log 'Uninstallation of rollout addon with Flux finished' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
