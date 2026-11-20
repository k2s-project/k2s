# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$rolloutModule = "$PSScriptRoot\rollout.module.psm1"

Import-Module $addonsModule, $rolloutModule

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'argocd' })

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
    Write-Log "Updating rollout addon to be part of service mesh"  
    (Invoke-Kubectl -Params 'annotate', 'namespace', 'rollout', 'linkerd.io/inject=enabled', '--overwrite').Output | Write-Log
    (Invoke-Kubectl -Params 'annotate', 'namespace', 'rollout', 'config.linkerd.io/skip-outbound-ports=8181', '--overwrite').Output | Write-Log
    
    if (Test-NginxGatewayAvailability) {
        Write-Log "Configuring Linkerd to skip inbound port 8080 for nginx-gw BackendTLSPolicy" -Console
        $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"8080\"}}}}}'
        (Invoke-Kubectl -Params 'patch', 'deployment', 'argocd-server', '-n', 'rollout', '-p', $annotations).Output | Write-Log
    }
} else {
    Write-Log "Updating rollout addon to not be part of service mesh"
    (Invoke-Kubectl -Params 'annotate', 'namespace', 'rollout', 'linkerd.io/inject-').Output | Write-Log
    (Invoke-Kubectl -Params 'annotate', 'namespace', 'rollout', 'config.linkerd.io/skip-outbound-ports-').Output | Write-Log
}
(Invoke-Kubectl -Params 'rollout', 'restart', 'deployment', '-n', 'rollout').Output | Write-Log
(Invoke-Kubectl -Params 'rollout', 'restart', 'statefulset', '-n', 'rollout').Output | Write-Log
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'rollout', '--timeout', '60s').Output | Write-Log
(Invoke-Kubectl -Params 'rollout', 'status', 'statefulset', '-n', 'rollout', '--timeout', '60s').Output | Write-Log

if (Test-NginxGatewayAvailability) {
    Write-Log 'Creating ArgoCD CA certificate ConfigMap for nginx-gw BackendTLSPolicy' -Console
    Start-Sleep -Seconds 20 
    New-BackendCACertConfigMap -Namespace 'rollout' -PodLabel 'app.kubernetes.io/name=argocd-server' -Port 8080 -ConfigMapName 'argocd-ca-cert'
}
