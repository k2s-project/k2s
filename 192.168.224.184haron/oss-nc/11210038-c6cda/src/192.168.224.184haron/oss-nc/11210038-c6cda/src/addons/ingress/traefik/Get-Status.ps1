# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$k8sApiModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k8s-api/k8s-api.module.psm1"
$configModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/config/config.module.psm1"

Import-Module $k8sApiModule, $configModule

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'ingress-traefik', 'deployment/traefik').Success

$isTraefikRunningProp = @{Name = 'IsTraefikRunning'; Value = $success; Okay = $success }
if ($isTraefikRunningProp.Value -eq $true) {
    $isTraefikRunningProp.Message = 'The traefik ingress controller is working'
}
else {
    $isTraefikRunningProp.Message = "The traefik ingress controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable ingress traefik' and 'k2s addons enable ingress traefik'"
} 

$externalIp = (Invoke-Kubectl -Params 'get', 'service', 'traefik', '-n', 'ingress-traefik', '-o', 'jsonpath="{.spec.externalIPs[0]}"').Output
$controlPlaneIp = Get-ConfiguredIPControlPlane

$isExternalIPSetProp = @{Name = 'IsExternalIPSet'; Value = ($externalIp -eq $controlPlaneIp); Okay = ($externalIp -eq $controlPlaneIp) }
if ($isExternalIPSetProp.Value -eq $true) {
    $isExternalIPSetProp.Message = "The external IP for traefik service is set to $controlPlaneIp"
}
else {
    $isExternalIPSetProp.Message = "The external IP for traefik service is not set properly. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable ingress traefik' and 'k2s addons enable ingress traefik'"
}

$certManagerProp, $caRootCertificateProp = Get-CertManagerStatusProperties

return $isTraefikRunningProp, $isExternalIPSetProp, $certManagerProp, $caRootCertificateProp
