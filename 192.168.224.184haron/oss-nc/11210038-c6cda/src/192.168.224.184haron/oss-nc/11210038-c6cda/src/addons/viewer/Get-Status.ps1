# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'viewer', 'deployment/viewerwebapp').Success

$isViewerRunningProp = @{Name = 'IsViewerRunning'; Value = $success; Okay = $success }
if ($isViewerRunningProp.Value -eq $true) {
    $isViewerRunningProp.Message = 'The viewer is working'
}
else {
    $isViewerRunningProp.Message = "The viewer is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable viewer' and 'k2s addons enable viewer'"
} 
return $isViewerRunningProp,$isViewerRunningProp
