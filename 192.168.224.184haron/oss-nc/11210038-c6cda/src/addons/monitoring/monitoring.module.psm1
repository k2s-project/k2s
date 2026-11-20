# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$logModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/log/log.module.psm1"
$k8sApiModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

Import-Module $logModule, $k8sApiModule

<#
.DESCRIPTION
Returns the path to the shared Windows Exporter manifests directory.
#>
function Get-WindowsExporterManifestDir {
    return "$PSScriptRoot\..\common\manifests\windows-exporter"
}

<#
.DESCRIPTION
Writes the usage notes for dashboard for the user.
#>
function Write-UsageForUser {
    @'
                                        USAGE NOTES
 To open Grafana dashboard, please use one of the options:

 Option 1: Access via ingress
 Please install either ingress nginx addon or ingress traefik addon from k2s,
 or you can install them on your own.
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress nginx
 Once the ingress controller is running in the cluster, run the command to enable monitoring
 k2s addons enable monitoring
 The Grafana dashboard will be accessible on the following URL:
 https://k2s.cluster.local/monitoring

 Option 2: Port-forwarding
 Use port-forwarding to the Grafana dashboard using the command below:
 kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

 In this case, the Grafana dashboard will be accessible on the following URL:
 http://localhost:3000/monitoring
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}
