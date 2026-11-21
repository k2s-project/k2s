# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls the rollout addons (ArgoCD) in the cluster

.DESCRIPTION
The rollout addons utilizes ArgoCD to provide the user with the possibility 
to automate the deployment of application based on Git repositories. The addon can 
either be used by directly accessing the argocd cli or using the exposed web interface.

.EXAMPLE
Disable rollout addon in k2s
powershell <installation folder>\addons\rollout\argocd\Disable.ps1
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$rolloutModule = "$PSScriptRoot\rollout.module.psm1"

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

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'rollout', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'argocd'})) -ne $true) {
    $errMsg = "Addon 'rollout' with ArgoCD implementation is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling rollout addon' -Console
$rolloutConfig = Get-RolloutConfig

# Clean up addon-sync infrastructure (if deployed)
Write-Log 'Cleaning up addon-sync infrastructure' -Console
(Invoke-Kubectl -Params 'delete', 'namespace', 'k2s-addon-sync', '--ignore-not-found', '--timeout=60s').Output | Write-Log

Remove-IngressForTraefik -Addon ([pscustomobject] @{Name = 'rollout' })
Remove-IngressForNginx -Addon ([pscustomobject] @{Name = 'rollout' })

Write-Log 'Uninstalling rollout addon resources, please wait it can take longer ...' -Console
(Invoke-Kubectl -Params 'delete', '-n', 'rollout', '-k', $rolloutConfig, '--timeout', '120s').Output | Write-Log
Write-Log 'Deleting rollout namespace, please wait it can take longer ...' -Console
# Avoid errors if people have forgotten to delete the applications
# $resourceExists = (Invoke-Kubectl -Params 'get', 'crd/applications.argoproj.io', '--ignore-not-found=true', '-o', 'name', '2>$null').Output
# Write-Log $resourceExists
# if ($resourceExists) {
#     (Invoke-Kubectl -Params 'patch', 'crd/applications.argoproj.io', '-p', '{\"metadata\":{\"finalizers\":null}}').Output | Write-Log
# }
(Invoke-Kubectl -Params 'delete', 'namespace', 'rollout','--timeout', '60s').Output | Write-Log

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'argocd' })
Write-Log 'Uninstallation of rollout addon finished' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
