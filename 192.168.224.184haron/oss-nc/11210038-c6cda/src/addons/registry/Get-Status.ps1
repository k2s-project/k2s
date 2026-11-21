# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"

$success = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', 'registry', '--timeout=60s').Success

$isRegistryPodRunningProp = @{Name = 'IsRegistryPodRunning'; Value = $success; Okay = $success }
if ($isRegistryPodRunningProp.Value -eq $true) {
    $isRegistryPodRunningProp.Message = 'The registry pod is working'
}
else {
    $isRegistryPodRunningProp.Message = "The registry pod is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable registry' and 'k2s addons enable registry'"
} 

$registries = Get-RegistriesFromSetupJson

$success = $false
if ($registries) {
    $registry = $registries | Where-Object { $_.Contains('k2s.registry.local') }

    if ($registry -match ':') {
        # Nodeport
        $statusCode = curl.exe "http://$registry/v2/" -i -m 15 --retry 5 --retry-delay 5 --fail 2>&1 | Out-String
    }
    else {
        # Ingress
        $statusCode = curl.exe "https://$registry/v2/" -k -i -m 15 --retry 5 --retry-delay 5 --fail 2>&1 | Out-String
    }
    
    $success = ($statusCode -match 200)
}

$isRegistryReachableProp = @{Name = 'IsRegistryReachable'; Value = $success; Okay = $success }
if ($isRegistryReachableProp.Value -eq $true) {
    $isRegistryReachableProp.Message = "The registry '$registry' is reachable"
}
else {
    $isRegistryReachableProp.Message = "The registry is not reachable. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable registry' and 'k2s addons enable registry'"
} 

return $isRegistryPodRunningProp, $isRegistryReachableProp
