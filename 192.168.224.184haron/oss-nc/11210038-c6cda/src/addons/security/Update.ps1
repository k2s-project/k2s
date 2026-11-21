# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$securityModule = "$PSScriptRoot\security.module.psm1"
$dashboardModule = "$PSScriptRoot\..\dashboard\dashboard.module.psm1"

Import-Module $addonsModule, $securityModule

Remove-IngressForSecurity
if (Test-NginxIngressControllerAvailability) {
    Enable-IngressForSecurity -Ingress 'nginx'
}
elseif (Test-TraefikIngressControllerAvailability) {
    Enable-IngressForSecurity -Ingress 'traefik'
}
elseif (Test-NginxGatewayAvailability) {
    Enable-IngressForSecurity -Ingress 'nginx-gw'
}

Write-Log 'Updating security addon finished.' -Console

if (Test-Path $dashboardModule) {
    Import-Module $dashboardModule -Force
    if (Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue) {
        Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins after security update' -Console
        try {
            Sync-HeadlampPlugins
        }
        catch {
            # Plugin sync is best-effort: a failure here must not fail the primary addon operation.
            Write-Log "[Dashboard][Plugin] Headlamp plugin sync failed (security update continues): $($_.Exception.Message)" -Console
        }
    }
}
