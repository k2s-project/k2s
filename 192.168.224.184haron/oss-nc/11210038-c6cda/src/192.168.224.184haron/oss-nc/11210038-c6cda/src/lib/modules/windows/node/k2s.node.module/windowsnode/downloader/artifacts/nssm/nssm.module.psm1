# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule

$kubeBinPath = Get-KubeBinPath

$windowsNode_NssmDirectory = 'nssm'
$nssmInstallDirectory = "$kubeBinPath"
$nssmInstallDirectoryLegacy = "$env:ProgramFiles\nssm"
$nssmExe = "$nssmInstallDirectory\nssm.exe"

function Invoke-DownloadNssmArtifacts($downloadsBaseDirectory, $Proxy, $windowsNodeArtifactsDirectory) {
    $nssmDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_NssmDirectory"
    $compressedNssmFile = 'nssm.zip'
    $compressedFile = "$nssmDownloadsDirectory\$compressedNssmFile"

    $arch = 'win32'
    if ([Environment]::Is64BitOperatingSystem) {
        $arch = 'win64'
    }

    Write-Log "Create folder '$nssmDownloadsDirectory'"
    mkdir $nssmDownloadsDirectory | Out-Null
    Write-Log 'Download nssm'
    Invoke-DownloadFile "$compressedFile" 'https://k8stestinfrabinaries.blob.core.windows.net/nssm-mirror/nssm-2.24.zip' $true $Proxy
    $ErrorActionPreference = 'SilentlyContinue'
    cmd /c tar C `"$nssmDownloadsDirectory`" -xvf `"$compressedFile`" --strip-components 2 */$arch/*.exe 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = 'Stop'
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue

    $nssmArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_NssmDirectory"

    if (Test-Path("$nssmArtifactsDirectory")) {
        Remove-Item -Path "$nssmArtifactsDirectory" -Force -Recurse
    }

    Copy-Item -Path "$nssmDownloadsDirectory" -Destination "$windowsNodeArtifactsDirectory" -Recurse -Force
}

function Invoke-DeployNssmArtifacts($windowsNodeArtifactsDirectory) {
    $nssmDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_NssmDirectory"
    if (Test-Path $nssmExe) {
        Write-Log 'nssm already published.'
    }
    else {
        if (!(Test-Path "$nssmDirectory")) {
            throw "Directory '$nssmDirectory' does not exist"
        }

        Write-Log 'Publishing nssm ...'
        mkdir -Force $nssmInstallDirectory | Out-Null
        Copy-Item -Path "$nssmDirectory\*" -Destination "$nssmInstallDirectory" -Recurse -Force

        Write-Log 'done.'
    }
}

function Remove-ServiceIfExists($serviceName) {
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        $nssm = $nssmExe
        if (!(Test-Path $nssm)) {
            $nssm = "$nssmInstallDirectoryLegacy\nssm.exe"
        }
        Write-Log "Stopping service '$serviceName'.."
        Stop-Service -Force -Name $serviceName | Out-Null

        Write-Log "Removing service '$serviceName'.."
        &$nssm remove $serviceName confirm
    }
    else {
        Write-Log "Service '$serviceName' not found."
    } 
}

function Remove-Nssm {
    if (Test-Path $nssmExe) {
        Write-Log 'Removing nssm.exe'
        Remove-Item -Path $nssmExe -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $nssmInstallDirectoryLegacy) {
        Remove-Item -Path $nssmInstallDirectoryLegacy -Force -Recurse -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Starts a specified service and sets it to auto-start.
.DESCRIPTION
    Starts a specified service and sets it to auto-start.
.PARAMETER Name
    Name of the service
.EXAMPLE
    Start-ServiceAndSetToAutoStart -Name 'kubelet'
.NOTES
    Does nothing if the service was not found.
#>
function Start-ServiceAndSetToAutoStart {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Name = $(throw 'Please provide the name of the service.'),
        [Parameter(Mandatory = $false)]
        [switch]$IgnoreErrors = $false
    )
    $svc = $(Get-Service -Name $Name -ErrorAction SilentlyContinue).Status
    if ($svc) {
        $nssm = $nssmExe
        if (!(Test-Path $nssm)) {
            $nssm = "$nssmInstallDirectoryLegacy\nssm.exe"
        }
        Write-Log "Changing service '$Name' to auto-start and starting.." 

        Set-ServiceProperty -Name $Name -PropertyName 'Start' -Value 'SERVICE_AUTO_START' -Nssm $nssm

        if ($IgnoreErrors) {
            # Start-Service sometimes says "service cannot be started" e.g. flanneld but service is running after start 
            # (-ErrorAction SilentlyContinue and checking afterwards if service is running)
            Start-Service $Name -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        } else {
            Start-Service $Name -WarningAction SilentlyContinue
        }

        Write-Log "Service '$Name' started"
    }
    else {
        Write-Log "Service '$Name' not found"
    } 
}

function Stop-ServiceAndSetToManualStart($serviceName) {
    $svc = $(Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status
    if (($svc)) {
        $nssm = $nssmExe
        if (!(Test-Path $nssm)) {
            $nssm = "$nssmInstallDirectoryLegacy\nssm.exe"
        }
        Write-Log "Stopping service '$serviceName' and changing to manual start.."

        Stop-Service $serviceName
        Set-ServiceProperty -Name $serviceName -PropertyName 'Start' -Value 'SERVICE_DEMAND_START' -Nssm $nssm

        Write-Log "Service '$serviceName' stopped"
    }
    else {
        Write-Log "Service '$serviceName' not found"
    } 
}

function Install-Service {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = $(throw 'Name not specified'),
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string] $ExePath = $(throw 'ExePath not specified')
    )   
    &$nssmExe install $Name $ExePath | Write-Log
}

function Set-ServiceProperty {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = $(throw 'Name not specified'),
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string] $PropertyName = $(throw 'PropertyName not specified'),
        [Parameter(Mandatory = $false)]
        [object] $Value,
        [Parameter(Mandatory = $false)]
        [string] $Nssm
    )
    $nssmToUse = $nssmExe
    if ($Nssm) {
        $nssmToUse = $Nssm
    }
    &$nssmToUse set $Name $PropertyName $Value 2>&1 | Out-Null
}

Export-ModuleMember Invoke-DownloadNssmArtifacts,
Invoke-DeployNssmArtifacts,
Remove-ServiceIfExists,
Start-ServiceAndSetToAutoStart,
Remove-Nssm,
Stop-ServiceAndSetToManualStart,
Install-Service,
Set-ServiceProperty
