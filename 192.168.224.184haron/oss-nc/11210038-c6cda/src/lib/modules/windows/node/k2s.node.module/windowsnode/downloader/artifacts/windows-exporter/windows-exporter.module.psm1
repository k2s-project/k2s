# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule

$kubePath = Get-KubePath
$kubeBinPath = Get-KubeBinPath

# windows exporter
$windowsNode_WindowsExporterDirectory = 'windowsexporter'
$windowsNode_WindowsExporterExe = 'windows_exporter.exe'

function Invoke-DownloadWindowsExporterArtifacts($downloadsBaseDirectory, $Proxy) {
    $windowsExporterDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_WindowsExporterDirectory"
    $file = "$windowsExporterDownloadsDirectory\$windowsNode_WindowsExporterExe"

    Write-Log "Create folder '$windowsExporterDownloadsDirectory'"
    mkdir $windowsExporterDownloadsDirectory | Out-Null
    Write-Log 'Download windows exporter'
    Invoke-DownloadFile "$file" https://github.com/prometheus-community/windows_exporter/releases/download/v0.31.3/windows_exporter-0.31.3-amd64.exe $true $Proxy
}

function Invoke-DeployWindowsExporterArtifacts($windowsNodeArtifactsDirectory) {
    $windowsExporterArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_WindowsExporterDirectory"
    if (!(Test-Path "$windowsExporterArtifactsDirectory")) {
        throw "Directory '$windowsExporterArtifactsDirectory' does not exist"
    }
    Write-Log 'Publish windows exporter artifacts'
    Copy-Item -Path "$windowsExporterArtifactsDirectory\$windowsNode_WindowsExporterExe" -Destination "$kubeBinPath" -Force
}

function Install-WindowsExporter {

    $logDir = Join-Path -Path (Get-ConfiguredLogDirectory) -ChildPath 'windows_exporter'
    if (!(Test-Path($logDir))) {
        mkdir $logDir -Force | Out-Null
    }

    &$kubeBinPath\nssm install windows_exporter "$kubeBinPath\windows_exporter.exe"

    $windowsexporterconfig = "$kubeBinPath\windows_exporter.yaml"

    # possible to add --log.level="debug"
    # old command line setup
    # &$kubeBinPath\nssm set windows_exporter AppParameters --web.listen-address=":9100" --collectors.enabled="cpu,cs,logical_disk,net,os,service,system,cpu_info,thermalzone,container" --collector.service.services-where "`"`"Name='kubelet' OR Name='kubeproxy' OR Name='flanneld' OR Name='windows_exporter' OR Name LIKE '%docker%'`"`"" --collector.logical_disk.volume-blacklist 'HarddiskVolume.*' | Out-Null
    &$kubeBinPath\nssm set windows_exporter AppParameters --config.file=\`"$windowsexporterconfig\`"
    &$kubeBinPath\nssm set windows_exporter AppDirectory $kubePath | Out-Null
    &$kubeBinPath\nssm set windows_exporter AppStdout "${logDir}\windows_exporter_stdout.log" | Out-Null
    &$kubeBinPath\nssm set windows_exporter AppStderr "${logDir}\windows_exporter_stderr.log" | Out-Null
    &$kubeBinPath\nssm set windows_exporter AppStdoutCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set windows_exporter AppStderrCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set windows_exporter AppRotateFiles 1 | Out-Null
    &$kubeBinPath\nssm set windows_exporter AppRotateOnline 1 | Out-Null
    &$kubeBinPath\nssm set windows_exporter AppRotateSeconds 0 | Out-Null
    &$kubeBinPath\nssm set windows_exporter AppRotateBytes 500000 | Out-Null
    &$kubeBinPath\nssm set windows_exporter Start SERVICE_AUTO_START | Out-Null

    Start-Service windows_exporter -WarningAction SilentlyContinue
}
