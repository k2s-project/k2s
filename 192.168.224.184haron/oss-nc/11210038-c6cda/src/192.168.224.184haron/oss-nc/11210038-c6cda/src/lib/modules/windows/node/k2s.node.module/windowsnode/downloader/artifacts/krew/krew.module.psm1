# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule

$kubeToolsPath = Get-KubeToolsPath

# krew (kubectl plugin manager - https://krew.sigs.k8s.io/)
$windowsNode_KrewDirectory = 'krew'
# The plugin executable must be named 'kubectl-krew.exe' so that kubectl discovers it on PATH
# and exposes it as the 'kubectl krew' subcommand.
$windowsNode_KrewExe = 'kubectl-krew.exe'
# Name of the executable inside the upstream release archive.
$windowsNode_KrewReleaseExe = 'krew-windows_amd64.exe'
# Pinned krew version (follows the same version-pinning pattern as helm).
$windowsNode_KrewVersion = 'v0.5.0'

function Invoke-DownloadKrewArtifacts($downloadsBaseDirectory, $Proxy, $windowsNodeArtifactsDirectory) {
    $krewDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_KrewDirectory"
    Write-Log "Create folder '$krewDownloadsDirectory'"
    mkdir $krewDownloadsDirectory -ErrorAction SilentlyContinue | Out-Null

    $compressedFile = "$krewDownloadsDirectory\krew.tar.gz"
    $url = "https://github.com/kubernetes-sigs/krew/releases/download/$windowsNode_KrewVersion/krew-windows_amd64.tar.gz"
    Write-Log "Download krew executable to $compressedFile"
    Write-Log "Fetching $url ...."
    Invoke-DownloadFile "$compressedFile" $url $true $Proxy
    Write-Log '  ...done'

    Write-Log "Extract downloaded file '$compressedFile'"
    # Capture tar output and exit code so a failed extraction (missing tar.exe, corrupt archive,
    # changed archive structure) is surfaced in the log instead of being silently swallowed.
    $ErrorActionPreference = 'SilentlyContinue'
    $tarOutput = tar C `"$krewDownloadsDirectory`" -xvf `"$compressedFile`" $windowsNode_KrewReleaseExe 2>&1 | % { "$_" }
    $tarExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($tarExitCode -ne 0) {
        Write-Log "tar extraction of '$compressedFile' failed (exit code $tarExitCode): $tarOutput"
        throw "Extraction of krew archive '$compressedFile' failed (tar exit code $tarExitCode). See log for details."
    }
    Write-Log '  ...done'
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue

    # Rename the upstream executable to 'kubectl-krew.exe' so kubectl can discover it as a plugin.
    $extractedExe = "$krewDownloadsDirectory\$windowsNode_KrewReleaseExe"
    if (!(Test-Path "$extractedExe")) {
        throw "The expected krew executable '$extractedExe' was not found after extraction"
    }
    Move-Item -Path "$extractedExe" -Destination "$krewDownloadsDirectory\$windowsNode_KrewExe" -Force

    $krewArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_KrewDirectory"
    if (Test-Path("$krewArtifactsDirectory")) {
        Remove-Item -Path "$krewArtifactsDirectory" -Force -Recurse
    }
    Copy-Item -Path "$krewDownloadsDirectory" -Destination "$windowsNodeArtifactsDirectory" -Recurse -Force
}

function Invoke-DeployKrewArtifacts($windowsNodeArtifactsDirectory) {
    $krewDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_KrewDirectory"
    $krewExe = "$kubeToolsPath\$windowsNode_KrewExe"
    if (Test-Path $krewExe) {
        Write-Log 'krew already published.'
    }
    else {
        if (!(Test-Path "$krewDirectory")) {
            throw "Directory '$krewDirectory' does not exist"
        }

        Write-Log 'Publishing krew ...'
        # bin\kube is created on demand (it holds downloaded binaries, not committed ones) and krew may be
        # deployed before kube-tools creates it, so ensure the target directory exists first.
        if (!(Test-Path -Path $kubeToolsPath)) {
            New-Item -Path $kubeToolsPath -ItemType Directory | Out-Null
        }
        Copy-Item -Path "$krewDirectory\$windowsNode_KrewExe" -Destination "$kubeToolsPath" -Force

        Write-Log 'done.'
    }
}

Export-ModuleMember Invoke-DownloadKrewArtifacts, Invoke-DeployKrewArtifacts

