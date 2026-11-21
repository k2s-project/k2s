# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$k8sApiModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k8s-api/k8s-api.module.psm1"
$configModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/config/config.module.psm1"

Import-Module $k8sApiModule, $configModule

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'ingress-nginx', 'deployment/ingress-nginx-controller').Success

$isIngressNginxRunningProp = @{Name = 'IsIngressNginxRunning'; Value = $success; Okay = $success }
if ($isIngressNginxRunningProp.Value -eq $true) {
    $isIngressNginxRunningProp.Message = 'The nginx ingress controller is working'
}
else {
    $isIngressNginxRunningProp.Message = "The nginx ingress controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable ingress nginx' and 'k2s addons enable ingress nginx'"
} 

$externalIp = (Invoke-Kubectl -Params 'get', 'service', 'ingress-nginx-controller', '-n', 'ingress-nginx', '-o', 'jsonpath="{.spec.externalIPs[0]}"').Output
$controlPlaneIp = Get-ConfiguredIPControlPlane

$isExternalIPSetProp = @{Name = 'IsExternalIPSet'; Value = ($externalIp -eq $controlPlaneIp); Okay = ($externalIp -eq $controlPlaneIp) }
if ($isExternalIPSetProp.Value -eq $true) {
    $isExternalIPSetProp.Message = "The external IP for ingress-nginx service is set to $controlPlaneIp"
}
else {
    $isExternalIPSetProp.Message = "The external IP for ingress-nginx service is not set properly. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable ingress nginx' and 'k2s addons enable ingress nginx'"
}

$certManagerProp, $caRootCertificateProp = Get-CertManagerStatusProperties

return $isIngressNginxRunningProp, $isExternalIPSetProp, $certManagerProp, $caRootCertificateProp
