# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Contains common methods for installing and uninstalling ingress nginx
#>

function Get-IngressNginxConfig {
    return "$PSScriptRoot\manifests\ingress-nginx.yaml"
}

function Get-ExternalDnsConfigDir {
    return "$PSScriptRoot\..\..\common\manifests\external-dns"
}
