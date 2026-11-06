# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule

$kubeBinPath = Get-KubeBinPath
# helm
$windowsNode_HelmDirectory = "helm"

function Invoke-DownloadHelmArtifacts($downloadsBaseDirectory, $Proxy, $windowsNodeArtifactsDirectory) {
    $helmDownloadsDirectory= "$downloadsBaseDirectory\$windowsNode_HelmDirectory"
    Write-Log "Create folder '$helmDownloadsDirectory'"
    mkdir $helmDownloadsDirectory -ErrorAction SilentlyContinue | Out-Null
    $compressedFile = "$helmDownloadsDirectory\helm.zip"
    Write-Log "Download helm executable to $compressedFile"
    Invoke-DownloadFile "$compressedFile" https://get.helm.sh/helm-v4.3.1-windows-amd64.zip $true $Proxy
    Write-Log '  ...done'
    Write-Log "Extract downloaded file '$compressedFile'"
    $ErrorActionPreference = 'SilentlyContinue'
    tar C `"$helmDownloadsDirectory`" -xvf `"$compressedFile`" --strip-components 1 windows-amd64/*.exe 2>&1 | % { "$_" }
    $ErrorActionPreference = 'Stop'
    Write-Log '  ...done'
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue

    $helmArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_HelmDirectory"
    if (Test-Path("$helmArtifactsDirectory")) {
        Remove-Item -Path "$helmArtifactsDirectory" -Force -Recurse
    }
    Copy-Item -Path "$helmDownloadsDirectory" -Destination "$windowsNodeArtifactsDirectory" -Recurse -Force
}

function Invoke-DeployHelmArtifacts($windowsNodeArtifactsDirectory) {
    $helmDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_HelmDirectory"
    if (!(Test-Path "$helmDirectory")) {
        throw "Directory '$helmDirectory' does not exist"
    }
    Write-Log "Publish helm artifacts"
    Copy-Item -Path "$helmDirectory\*" -Destination "$kubeBinPath" -Recurse -Force
}

function Invoke-DeployHelmArtifacts($windowsNodeArtifactsDirectory) {
    $helmDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_HelmDirectory"
    $helmExe = "$kubeBinPath\helm.exe"
    if (Test-Path $helmExe) {
        Write-Log 'helm already published.'
    }
    else {
        if (!(Test-Path "$helmDirectory ")) {
            throw "Directory '$helmDirectory' does not exist"
        }

        Write-Log 'Publishing helm ...'
        Copy-Item -Path "$helmDirectory\*" -Destination "$kubeBinPath" -Recurse -Force

        Write-Log 'done.'
    }
}
