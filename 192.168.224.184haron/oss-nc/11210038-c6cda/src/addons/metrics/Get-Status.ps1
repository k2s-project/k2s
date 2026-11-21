# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib\modules\windows\cluster\k2s.cluster.module\k8s-api\k8s-api.module.psm1"
Import-Module "$PSScriptRoot\..\addons.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'metrics', 'deployment/metrics-server').Success

$isMetricsServerRunningProp = @{Name = 'IsMetricsServerRunning'; Value = $success; Okay = $success }
if ($isMetricsServerRunningProp.Value -eq $true) {
    $isMetricsServerRunningProp.Message = 'The metrics server is working'
}
else {
    $isMetricsServerRunningProp.Message = "The metrics server is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable metrics' and 'k2s addons enable metrics'"
} 

$placementProps = Get-AddonInfrastructurePlacementStatus -Name 'metrics'
return , (@($isMetricsServerRunningProp) + @($placementProps))
