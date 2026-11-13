# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [switch] $Deploy,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy = ''
)

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1
. $PSScriptRoot\..\..\common\GlobalFunctions.ps1

$ErrorActionPreference = 'Stop'

function DownloadYamlArtifacts($baseDirectory) {

    Write-Log "Create folder '$baseDirectory'"
    mkdir $baseDirectory -ErrorAction SilentlyContinue | Out-Null
    Write-Log "Download jq executable"

    $downloadedFile1 = "$baseDirectory\jq.exe"
    DownloadFile "$downloadedFile1" https://github.com/stedolan/jq/releases/download/jq-1.6/jq-win64.exe $true $Proxy
    Move-Item -Path "$downloadedFile1" -Destination $baseDirectory
    Write-Log "Move $downloadedFile1 to $baseDirectory done"

    $downloadedFile2 = "$baseDirectory\yq.exe"
    Write-Log "Download yq executable"
    DownloadFile "$downloadedFile2" https://github.com/mikefarah/yq/releases/download/v4.33.3/yq_windows_amd64.exe $true $Proxy
    Move-Item -Path "$downloadedFile2" -Destination $baseDirectory
    Write-Log "Move $downloadedFile2 to $baseDirectory done"
}

$downloadsBaseDirectory = "$global:WindowsNodeArtifactsDownloadsDirectory"
if (!(Test-Path $downloadsBaseDirectory)) {
    Write-Log "Create folder '$downloadsBaseDirectory'"
    New-Item -Force -Path $downloadsBaseDirectory -ItemType Directory
}

$yamlDownloadsDirectory = "$downloadsBaseDirectory\$global:WindowsNode_YamlDirectory"

DownloadYamlArtifacts($yamlDownloadsDirectory)

if ($Deploy) {
    if (!(Test-Path($global:WindowsNodeArtifactsDirectory))) {
        mkdir $global:WindowsNodeArtifactsDirectory | Out-Null
    } else {
        $yamlArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_YamlDirectory"

        if (Test-Path("$yamlArtifactsDirectory")) {
            Remove-Item -Path "$yamlArtifactsDirectory" -Force -Recurse
        }
    }

    Copy-Item -Path "$yamlDownloadsDirectory" -Destination "$global:WindowsNodeArtifactsDirectory" -Recurse -Force
}




