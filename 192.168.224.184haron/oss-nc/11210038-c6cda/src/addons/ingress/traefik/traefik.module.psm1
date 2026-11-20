# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Contains common methods for installing and uninstalling Traefik Ingress Controller in Kubernetes.
#>

$k8sApiModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k8s-api/k8s-api.module.psm1"
Import-Module $k8sApiModule

function Get-TraefikYamlDir {
    return "$PSScriptRoot\manifests"
}

function Get-ExternalDnsConfigDir {
    return "$PSScriptRoot\..\..\common\manifests\external-dns"
}

<#
.DESCRIPTION
Determines if the security service is deployed in the cluster
#>
function Test-SecurityAddonAvailability {
    $existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'security', '-o', 'yaml').Output
    if ("$existingServices" -match '.* keycloak .*') {
        return $true
    }
    return $false
}
