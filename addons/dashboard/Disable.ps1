# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls Headlamp - Kubernetes Dashboard UI
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
$dashboardModule = "$PSScriptRoot\dashboard.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $dashboardModule

Initialize-Logging -ShowLogs:$ShowLogs

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

$hasIncompleteIntent = Test-AddonHasIncompleteInstallationIntent -Name 'dashboard'
if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'dashboard' })) -ne $true -and -not $hasIncompleteIntent) {
    $errMsg = "Addon 'dashboard' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($hasIncompleteIntent) {
    Write-Log "[Dashboard] Addon 'dashboard' has an incomplete installation intent; cleaning up any partial resources" -Console
}

Write-Log '[Dashboard] Uninstalling Headlamp dashboard' -Console
Remove-IngressForTraefik -Addon ([pscustomobject] @{Name = 'dashboard' })
Remove-IngressForNginx -Addon ([pscustomobject] @{Name = 'dashboard' })
Remove-IngressForNginxGateway -Addon ([pscustomobject] @{Name = 'dashboard' })

# Note: the Headlamp plugin init-containers are NOT explicitly removed here.
# Uninstall-HeadlampViaHelm deletes the entire headlamp Deployment, so patching it
# first would only trigger a rollout that Helm immediately cancels, and a transient
# kubectl patch failure could otherwise block the uninstall below.
Write-Log '[Dashboard] Uninstalling Headlamp workloads via Helm, please wait ...' -Console
Uninstall-HeadlampViaHelm

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'dashboard' })
Write-Log '[Dashboard] Uninstallation of Headlamp dashboard finished' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
