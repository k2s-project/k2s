# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'rollout', 'deployment/argocd-applicationset-controller').Success

$isArgoCDApplicationsetControllerRunningProp = @{Name = 'IsArgoCDApplicationsetControllerRunning'; Value = $success; Okay = $success }
if ($isArgoCDApplicationsetControllerRunningProp.Value -eq $true) {
    $isArgoCDApplicationsetControllerRunningProp.Message = 'ArgoCD Application Set Controller is working'
}
else {
    $isArgoCDApplicationsetControllerRunningProp.Message = "ArgoCD Application Set Controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable rollout' and 'k2s addons enable rollout'"
} 

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'rollout', 'deployment/argocd-dex-server').Success

$isArgoCDDexServerRunningProp = @{Name = 'IsArgoCDDexServerRunning'; Value = $success; Okay = $success }
if ($isArgoCDDexServerRunningProp.Value -eq $true) {
    $isArgoCDDexServerRunningProp.Message = 'ArgoCD Dex Server is working'
}
else {
    $isArgoCDDexServerRunningProp.Message = "ArgoCD Dex Server is working is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable rollout' and 'k2s addons enable rollout'"
} 

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'rollout', 'deployment/argocd-notifications-controller').Success

$IsArgoCDNotificationControllerRunningProp = @{Name = 'IsArgoCDNotificationControllerRunning'; Value = $success; Okay = $success }
if ($IsArgoCDNotificationControllerRunningProp.Value -eq $true) {
    $IsArgoCDNotificationControllerRunningProp.Message = 'ArgoCD Notification Controller is working'
}
else {
    $IsArgoCDNotificationControllerRunningProp.Message = "ArgoCD Notification Controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable rollout' and 'k2s addons enable rollout'"
} 

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'rollout', 'deployment/argocd-redis').Success

$isArgoCDRedisDBRunningProp = @{Name = 'IsArgoCDRedisRunning'; Value = $success; Okay = $success }
if ($isArgoCDRedisDBRunningProp.Value -eq $true) {
    $isArgoCDRedisDBRunningProp.Message = 'ArgoCD Redis DB is working'
}
else {
    $isArgoCDRedisDBRunningProp.Message = "ArgoCD Redis DB is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable rollout' and 'k2s addons enable rollout'"
} 

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'rollout', 'deployment/argocd-repo-server').Success

$isArgoCDRepoServerRunningProp = @{Name = 'IsArgoCDRepoServerRunning'; Value = $success; Okay = $success }
if ($isArgoCDRepoServerRunningProp.Value -eq $true) {
    $isArgoCDRepoServerRunningProp.Message = 'ArgoCD Repo Server is working'
}
else {
    $isArgoCDRepoServerRunningProp.Message = "ArgoCD Repo Server is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable rollout' and 'k2s addons enable rollout'"
} 

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'rollout', 'deployment/argocd-server').Success

$isArgoCDServerRunningProp = @{Name = 'IsArgoCDServerRunning'; Value = $success; Okay = $success }
if ($isArgoCDServerRunningProp.Value -eq $true) {
    $isArgoCDServerRunningProp.Message = 'ArgoCD Server is working'
}
else {
    $isArgoCDServerRunningProp.Message = "ArgoCD Server is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable rollout' and 'k2s addons enable rollout'"
} 

$success = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', 'rollout', '--timeout=5s').Success

$areStatefulsetsRunningProp = @{Name = 'AreStatefulsetsRunning'; Value = $success; Okay = $success }
if ($areStatefulsetsRunningProp.Value -eq $true) {
    $areStatefulsetsRunningProp.Message = 'ArgoCD Application Server is working'
}
else {
    $areStatefulsetsRunningProp.Message = "ArgoCD Application Server is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable rollout' and 'k2s addons enable rollout'"
} 

return $isArgoCDApplicationsetControllerRunningProp,$isArgoCDDexServerRunningProp ,$IsArgoCDNotificationControllerRunningProp, $isArgoCDRedisDBRunningProp, $isArgoCDRepoServerRunningProp, $isArgoCDServerRunningProp ,$areStatefulsetsRunningProp
