# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Contains common methods for installing and uninstalling Metrics server for Kubernetes.
#>

function Get-MetricsServerConfig {
    return "$PSScriptRoot\manifests\metrics-server.yaml"
}

<#
.DESCRIPTION
Returns the path to the shared Windows Exporter manifests directory.
#>
function Get-WindowsExporterManifestDir {
    return "$PSScriptRoot\..\common\manifests\windows-exporter"
}
