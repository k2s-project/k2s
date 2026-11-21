# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'kubevirt', 'deployment/virt-api').Success

$isVirtApiRunningProp = @{Name = 'IsVirtApiRunning'; Value = $success; Okay = $success }
if ($isVirtApiRunningProp.Value -eq $true) {
    $isVirtApiRunningProp.Message = 'The virt-api is working'
}
else {
    $isVirtApiRunningProp.Message = "The virt-api is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable kubevirt' and 'k2s addons enable kubevirt'"
} 

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'kubevirt', 'deployment/virt-controller').Success

$isVirtControllerRunningProp = @{Name = 'IsVirtControllerRunning'; Value = $success; Okay = $success }
if ($isVirtControllerRunningProp.Value -eq $true) {
    $isVirtControllerRunningProp.Message = 'The virt-controller is working'
}
else {
    $isVirtControllerRunningProp.Message = "The virt-controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable kubevirt' and 'k2s addons enable kubevirt'"
} 

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'kubevirt', 'deployment/virt-operator').Success

$isVirtOperatorRunningProp = @{Name = 'IsVirtOperatorRunning'; Value = $success; Okay = $success }
if ($isVirtOperatorRunningProp.Value -eq $true) {
    $isVirtOperatorRunningProp.Message = 'The virt-operator is working'
}
else {
    $isVirtOperatorRunningProp.Message = "The virt-operator is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable kubevirt' and 'k2s addons enable kubevirt'"
} 

$success = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonsets', '-n', 'kubevirt', '--timeout=5s').Success

$isVirtHandlerRunningProp = @{Name = 'IsVirtHandlerRunning'; Value = $success; Okay = $success }
if ($isVirtHandlerRunningProp.Value -eq $true) {
    $isVirtHandlerRunningProp.Message = 'The virt-handler is working'
}
else {
    $isVirtHandlerRunningProp.Message = "The virt-handler is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable kubevirt' and 'k2s addons enable kubevirt'"
} 

return $isVirtApiRunningProp, $isVirtControllerRunningProp, $isVirtOperatorRunningProp, $isVirtHandlerRunningProp
