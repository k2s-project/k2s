# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$logModule = "$PSScriptRoot/../../lib\modules\windows\infra\k2s.infra.module\log\log.module.psm1"
$k8sApiModule = "$PSScriptRoot/../../lib\modules\windows\cluster\k2s.cluster.module\k8s-api\k8s-api.module.psm1"

Import-Module $logModule, $k8sApiModule

<#
.DESCRIPTION
Writes the usage notes for dashboard for the user.
#>
function Write-UsageForUser {
    @'
                                        USAGE NOTES
 To open opensearch dashboard, please use one of the options:
 
 Option 1: Access via ingress
 Please install either ingress nginx or ingress traefik addon from k2s.
 or you can install them on your own.
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress nginx
 Once the ingress controller is running in the cluster, run the command to enable logging 
 k2s addons enable logging
 The opensearch dashboard will be accessible on the following URL: https://k2s.cluster.local/logging

 Option 2: Port-forwading
 Use port-forwarding to the opensearch dashboard using the command below:
 kubectl -n logging port-forward svc/opensearch-dashboards 5601:5601
 
 In this case, the opensearch dashboard will be accessible on the following URL: http://localhost:5601/logging
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}
