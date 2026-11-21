# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1

$ErrorActionPreference = 'Stop'

function PublishYamlArtifacts($baseDirectory) {
    if (!(Test-Path "$baseDirectory")) {
        throw "Directory '$baseDirectory' does not exist"
    }
    Write-Log "Publish yaml artifacts from '$baseDirectory' to '$global:BinPath'"
    Copy-Item -Path "$baseDirectory\*" -Destination "$global:BinPath" -Force
}

$yamlDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_YamlDirectory"

PublishYamlArtifacts($yamlDirectory)
