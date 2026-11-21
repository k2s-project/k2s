# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'rollout', 'deployment/source-controller').Success

$isFluxSourceControllerRunningProp = @{Name = 'IsFluxSourceControllerRunning'; Value = $success; Okay = $success }
if ($isFluxSourceControllerRunningProp.Value -eq $true) {
    $isFluxSourceControllerRunningProp.Message = 'Flux Source Controller is working'
}
else {
    $isFluxSourceControllerRunningProp.Message = "Flux Source Controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable rollout fluxcd' and 'k2s addons enable rollout fluxcd'"
}

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'rollout', 'deployment/kustomize-controller').Success

$isFluxKustomizeControllerRunningProp = @{Name = 'IsFluxKustomizeControllerRunning'; Value = $success; Okay = $success }
if ($isFluxKustomizeControllerRunningProp.Value -eq $true) {
    $isFluxKustomizeControllerRunningProp.Message = 'Flux Kustomize Controller is working'
}
else {
    $isFluxKustomizeControllerRunningProp.Message = "Flux Kustomize Controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable rollout fluxcd' and 'k2s addons enable rollout fluxcd'"
}

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'rollout', 'deployment/helm-controller').Success

$isFluxHelmControllerRunningProp = @{Name = 'IsFluxHelmControllerRunning'; Value = $success; Okay = $success }
if ($isFluxHelmControllerRunningProp.Value -eq $true) {
    $isFluxHelmControllerRunningProp.Message = 'Flux Helm Controller is working'
}
else {
    $isFluxHelmControllerRunningProp.Message = "Flux Helm Controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable rollout fluxcd' and 'k2s addons enable rollout fluxcd'"
}

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'rollout', 'deployment/notification-controller').Success

$isFluxNotificationControllerRunningProp = @{Name = 'IsFluxNotificationControllerRunning'; Value = $success; Okay = $success }
if ($isFluxNotificationControllerRunningProp.Value -eq $true) {
    $isFluxNotificationControllerRunningProp.Message = 'Flux Notification Controller is working'
}
else {
    $isFluxNotificationControllerRunningProp.Message = "Flux Notification Controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable rollout fluxcd' and 'k2s addons enable rollout fluxcd'"
}

return $isFluxSourceControllerRunningProp, $isFluxKustomizeControllerRunningProp, $isFluxHelmControllerRunningProp, $isFluxNotificationControllerRunningProp
