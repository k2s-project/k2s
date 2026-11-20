# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls ingress nginx from the cluster

.DESCRIPTION
Ingress nginx is using k8s load balancer and is bound to the IP of the master machine.
It allows applications to register their ingress resources and handles incomming HTTP/HTPPS traffic.

.EXAMPLE
powershell <installation folder>\addons\ingress\nginx\Disable.ps1
#>

Param(
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
$nginxModule = "$PSScriptRoot\nginx.module.psm1"
$dashboardModule = "$PSScriptRoot\..\..\dashboard\dashboard.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $nginxModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

# get addon name from folder path
$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

Write-Log 'Check whether ingress nginx addon is already disabled'

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'ingress-nginx', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx' })) -ne $true) {
    $errMsg = "Addon 'ingress nginx' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling ingress nginx' -Console
$clusterIngressConfig = "$PSScriptRoot\manifests\cluster-local-ingress.yaml"
(Invoke-Kubectl -Params 'delete' , '-f', $clusterIngressConfig).Output | Write-Log
$ingressNginxConfig = Get-IngressNginxConfig
(Invoke-Kubectl -Params 'delete' , '-f', $ingressNginxConfig).Output | Write-Log
(Invoke-Kubectl -Params 'delete', 'ns', 'ingress-nginx').Output | Write-Log

Write-log 'Uninstalling ExternalDNS' -Console
$externalDnsConfigDir = Get-ExternalDnsConfigDir
(Invoke-Kubectl -Params 'delete', '-k', $externalDnsConfigDir).Output | Write-Log

# Check if security addon is NOT enabled
if (-not (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'security' }))) {
    $certManagerNs = (Invoke-Kubectl -Params 'get', 'namespace', 'cert-manager', '--ignore-not-found').Output
    if ([string]::IsNullOrWhiteSpace($certManagerNs)) {
        Write-Log 'cert-manager is not installed, skipping uninstallation.' -Console
    }
    else {
        Write-Log 'Security addon is not enabled. Proceeding with cert-manager uninstallation.' -Console
        Uninstall-CertManager
    }
}


Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx' })

# adapt other addons
Update-Addons -AddonName $addonName

if (Test-Path $dashboardModule) {
    Import-Module $dashboardModule -Force
    if (Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue) {
        Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins after ingress nginx disable' -Console
        try {
            Sync-HeadlampPlugins
        }
        catch {
            # Plugin sync is best-effort: a failure here must not fail the primary addon operation.
            Write-Log "[Dashboard][Plugin] Headlamp plugin sync failed (ingress nginx disable continues): $($_.Exception.Message)" -Console
        }
    }
}


if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
