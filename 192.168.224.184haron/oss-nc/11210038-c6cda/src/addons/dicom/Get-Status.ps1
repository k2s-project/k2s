# SPDX-FileCopyrightText: © 2023 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=15s', '--for=condition=Available', '-n', 'dicom', 'deployment/dicom').Success

$isOrthancRunningProp = @{Name = 'dicom'; Value = $success; Okay = $success }
if ($isOrthancRunningProp.Value -eq $true) {
    $isOrthancRunningProp.Message = 'The dicom Deployment is working'
}
else {
    $isOrthancRunningProp.Message = "The dicom Deployment is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable dicom' and 'k2s addons enable dicom'"
} 

# $success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'dicom', 'deployment/mysql').Success

# $isDBSQlRunningProp = @{Name = 'mysql'; Value = $success; Okay = $success }
# if ($isDBSQlRunningProp.Value -eq $true) {
#     $isDBSQlRunningProp.Message = "The mysql Deployment is working"
# }
# else {
#     $isDBSQlRunningProp.Message = "The mysql Deployment is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable dicom' and 'k2s addons enable dicom'"
# } 

$success = (Invoke-Kubectl -Params 'wait', '--timeout=15s', '--for=condition=Available', '-n', 'dicom', 'deployment/postgres').Success

$isDBSQlRunningProp = @{Name = 'postgres'; Value = $success; Okay = $success }
if ($isDBSQlRunningProp.Value -eq $true) {
    $isDBSQlRunningProp.Message = 'The postgres Deployment is working'
}
else {
    $isDBSQlRunningProp.Message = "The postgres Deployment is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable dicom' and 'k2s addons enable dicom'"
} 

return $isOrthancRunningProp, $isDBSQlRunningProp
