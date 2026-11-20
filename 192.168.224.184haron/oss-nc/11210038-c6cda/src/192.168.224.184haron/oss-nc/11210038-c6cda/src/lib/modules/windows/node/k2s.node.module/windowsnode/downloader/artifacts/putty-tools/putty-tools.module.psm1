# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule

$kubeBinPath = Get-KubeBinPath
# Putty tools
$windowsNode_PuttytoolsDirectory = "puttytools"
$windowsNode_Plink = "plink.exe"
$windowsNode_Pscp = "pscp.exe"

function Invoke-DownloadPuttyArtifacts($downloadsBaseDirectory, $Proxy) {
    $puttytoolsDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_PuttytoolsDirectory"
    Write-Log "Create folder '$puttytoolsDownloadsDirectory'"
    mkdir $puttytoolsDownloadsDirectory | Out-Null

    Write-Log "Download plink"
    Invoke-DownloadPlink -Destination "$puttytoolsDownloadsDirectory\$windowsNode_Plink" -Proxy "$Proxy"
    Write-Log "Download pscp"
    Invoke-DownloadPscp -Destination "$puttytoolsDownloadsDirectory\$windowsNode_Pscp" -Proxy "$Proxy"
}

function Invoke-DeployPuttytoolsArtifacts($windowsNodeArtifactsDirectory) {
    $puttytoolsArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_PuttytoolsDirectory"
    if (!(Test-Path "$puttytoolsArtifactsDirectory")) {
        throw "Directory '$puttytoolsArtifactsDirectory' does not exist"
    }
    Write-Log "Publish plink"
    Copy-Item -Path "$puttytoolsArtifactsDirectory\$windowsNode_Plink" -Destination "$kubeBinPath" -Force
    Write-Log "Publish pscp"
    Copy-Item -Path "$puttytoolsArtifactsDirectory\$windowsNode_Pscp" -Destination "$kubeBinPath" -Force
}

function Invoke-DownloadPlink {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Destination,
        [Parameter(Mandatory = $false)]
        [string]$Proxy
    )

    Invoke-DownloadFile $Destination https://the.earth.li/~sgtatham/putty/0.83/w64/$windowsNode_Plink $true $Proxy
}

function Invoke-DownloadPscp {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [Parameter(Mandatory = $false)]
        [string]$Proxy
    )

    Invoke-DownloadFile $Destination https://the.earth.li/~sgtatham/putty/0.83/w64/$windowsNode_Pscp $true $Proxy
}

Export-ModuleMember Invoke-DownloadPuttyArtifacts, Invoke-DeployPuttytoolsArtifacts,
Invoke-DownloadPlink, Invoke-DownloadPscp
