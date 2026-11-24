# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$rolloutModule = "$PSScriptRoot\rollout.module.psm1"

Import-Module $addonsModule, $rolloutModule

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'argocd' })

Update-RolloutServiceMesh -Namespace 'rollout'

if (Test-NginxGatewayAvailability) {
    Write-Log 'Creating ArgoCD CA certificate ConfigMap for nginx-gw BackendTLSPolicy' -Console
    Start-Sleep -Seconds 20 
    New-BackendCACertConfigMap -Namespace 'rollout' -PodLabel 'app.kubernetes.io/name=argocd-server' -Port 8080 -ConfigMapName 'argocd-ca-cert'
}
