# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=30s', '--for=condition=Available', '-n', 'dashboard', 'deployment/headlamp').Success

$isHeadlampRunningProp = @{Name = 'IsHeadlampRunning'; Value = $success; Okay = $success }
if ($isHeadlampRunningProp.Value -eq $true) {
    $isHeadlampRunningProp.Message = 'The Headlamp dashboard is working'
}
else {
    $isHeadlampRunningProp.Message = "The Headlamp dashboard is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable dashboard' and 'k2s addons enable dashboard'"
}

Import-Module "$PSScriptRoot\..\addons.module.psm1"
return , (@($isHeadlampRunningProp) + @(Get-AddonInfrastructurePlacementStatus -Name 'dashboard'))
