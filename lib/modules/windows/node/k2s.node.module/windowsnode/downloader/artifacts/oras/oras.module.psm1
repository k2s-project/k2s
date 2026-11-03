# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
Import-Module $logModule, $configModule, $pathModule

$kubePath = Get-KubePath
$kubeBinPath = Get-KubeBinPath

$windowsNode_OrasDirectory = 'oras'

function Invoke-DownloadOrasArtifacts($downloadsBaseDirectory, $Proxy, $windowsNodeArtifactsDirectory, $OrasVersion = '1.3.6') {
    $orasDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_OrasDirectory"
    $compressedOrasFile = "oras_${OrasVersion}_windows_amd64.zip"
    $compressedFile = "$orasDownloadsDirectory\$compressedOrasFile"

    $url = "https://github.com/oras-project/oras/releases/download/v$OrasVersion/$compressedOrasFile"

    Write-Log "Create folder '$orasDownloadsDirectory'"
    mkdir $orasDownloadsDirectory | Out-Null
    Write-Log "Download oras"
    Write-Log "Fetching $url ...."
    Invoke-DownloadFile "$compressedFile" $url $true $Proxy
    Expand-Archive "$compressedFile" -DestinationPath "$orasDownloadsDirectory" -Force
    Write-Log "  ...done"
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue

    $orasArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_OrasDirectory"

    if (Test-Path("$orasArtifactsDirectory")) {
        Remove-Item -Path "$orasArtifactsDirectory" -Force -Recurse
    }

    Copy-Item -Path "$orasDownloadsDirectory" -Destination "$windowsNodeArtifactsDirectory" -Recurse -Force
}

function Invoke-DeployOrasArtifacts($windowsNodeArtifactsDirectory) {
    $orasDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_OrasDirectory"
    if (!(Test-Path "$orasDirectory")) {
        throw "Directory '$orasDirectory' does not exist"
    }
    Write-Log "Publish oras artifacts"
    Copy-Item -Path "$orasDirectory\oras.exe" -Destination "$kubeBinPath" -Force
}

Export-ModuleMember Invoke-DownloadOrasArtifacts, Invoke-DeployOrasArtifacts
