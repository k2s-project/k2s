# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$k8sApiModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k8s-api/k8s-api.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\lib\modules\windows\node\k2s.node.module\k2s.node.module.psm1"

Import-Module $infraModule, $k8sApiModule, $nodeModule

function Restart-Services() {
    Write-Log 'Restarting services' -Console
    Stop-NssmService('kubeproxy')
    Stop-NssmService('kubelet')
    Restart-NssmService('containerd')
    Start-NssmService('kubelet')
    Start-NssmService('kubeproxy')
}


<#
.DESCRIPTION
Writes the usage notes for registry for the user.
#>
function Write-RegistryUsageForUser {
    @"
                        REGISTRY ADDON - USAGE NOTES
To access the local registry, please use one of the options:

Option 1: Access via ingress
Please install either ingress nginx or ingress traefik addon from k2s.
or you can install them on your own. 
Enable ingress controller via k2s cli
eg. k2s addons enable ingress nginx
Once the ingress controller is running in the cluster, run the command to enable registry 
k2s addons enable registry
The local registry will be accessible on the following URL: k2s.registry.local
In order to push your images to the private registry you have to tag your images as in the following example:
k2s.registry.local/<yourImageName>:<yourImageTag>

Option 2: Access via Nodeport
If no ingress controller is enabled the local registry is exposed via Nodeport (30500).

In this case, the local registry will be accessible on the following URL: k2s.registry.local:30500
In order to push your images to the private registry you have to tag your images as in the following example:
k2s.registry.local:30500/<yourImageName>:<yourImageTag>
"@ -split "`r`n" | ForEach-Object { Write-Log $_ }
}

function Update-NodePort {
    Write-Log "  Applying nodeport service manifest for registry..." -Console
    (Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\registry\service-nodeport.yaml").Output | Write-Log
}

function Remove-NodePort {
    Write-Log "  Removing nodeport service manifest for registry..." -Console
    (Invoke-Kubectl -Params 'delete', '-f', "$PSScriptRoot\manifests\registry\service-nodeport.yaml", "--ignore-not-found").Output | Write-Log
}
