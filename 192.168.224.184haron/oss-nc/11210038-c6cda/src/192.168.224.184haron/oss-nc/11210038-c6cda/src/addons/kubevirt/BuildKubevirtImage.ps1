# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Build a new Linux image based on a qcow2 image

.DESCRIPTION
Builds a Linux docker image using k2s on the Linux VM.
Optionally pushes the created image to the repository (only with -Push)

.EXAMPLE
PS> .\BuildKubevirtImage.ps1 -InputQCOW2Image E:\QCOW2\windows20h2.qcow2 -ImageName virt-win20h2
PS> .\BuildKubevirtImage.ps1 -ImageName testserver -ImageTag 76 -Push

#>

Param(
    [Alias('d')]
    [parameter(Mandatory = $true, HelpMessage = 'Directory with the image file')]
    [string] $InputQCOW2Image,

    [parameter(Mandatory = $true, HelpMessage = 'Name of the created image')]
    [string] $ImageName,

    [Alias('t', 'Tag')]
    [parameter(Mandatory = $false, HelpMessage = 'Tag in registry')]
    [string] $ImageTag = 'local',

    [Alias('p')]
    [parameter(Mandatory = $false, HelpMessage = 'Push image to repository')]
    [switch] $Push = $false
)
Import-Module "$PSScriptRoot\..\..\lib\modules\windows\node\k2s.node.module\windowsnode\system\system.module.psm1"

<#
.SYNOPSIS
Log Error Message and Throw Exception.

.DESCRIPTION
Based on ErrorActionPreference, error is logged and thrown to the caller
#>
function Write-ErrorAndThrow ([string]$ErrorMessage) {
    if ($ErrorActionPreference -eq 'Stop') {
        #If Stop is the ErrorActionPreference from the caller then Write-Error throws an exception which is not logged in k2s.log file.
        #So we need to write a warning to capture error message.
        Write-Warning "$ErrorMessage"
    }
    else {
        Write-Error "$ErrorMessage"
    }
    throw $ErrorMessage
}

$mainStopwatch = [system.diagnostics.stopwatch]::StartNew()

if (! (Test-Path "$InputQCOW2Image")) { Write-ErrorAndThrow "Missing QCOW2 image file: $InputQCOW2Image" }
if (($ImageTag -eq 'local') -and $Push) { Write-ErrorAndThrow 'Unable to push without valid tag, use -ImageTag' }
if ($ImageName -eq '') { Write-ErrorAndThrow 'Missing image name' }

Write-Output "[$(Get-Date -Format HH:mm:ss)] Creating linux container: $ImageName from QCOW2 image: $InputQCOW2Image"

$storageLocalDrive = Get-StorageLocalDrive
$storagePath = "$storageLocalDrive\kubevirt"
Write-Output "[$(Get-Date -Format HH:mm:ss)] Creating directory $storagePath"
mkdir -force $storagePath | Out-Null

# filter out drive and file name
$fileqcow2 = Split-Path -Path $InputQCOW2Image -leaf
$driveqcow2 = Split-Path -Path $InputQCOW2Image -Qualifier

# check file existence
if (! (Test-Path "$storagePath\$fileqcow2")) {
    if ( $driveqcow2 -eq $storageLocalDrive) {
        # make link if drive the same
        Write-Output "[$(Get-Date -Format HH:mm:ss)] Make link $storagePath\$fileqcow2 -> $InputQCOW2Image"
        New-Item -Path $storagePath\$fileqcow2 -ItemType SymbolicLink -Value $InputQCOW2Image
    }
    else {
        # else copy file
        Write-Output "[$(Get-Date -Format HH:mm:ss)] Copy file 2 $InputQCOW2Image -> $storagePath\$fileqcow"
        Copy-Item -Path $InputQCOW2Image -Destination $storagePath
    }
}
else {
    Write-Output "[$(Get-Date -Format HH:mm:ss)] File already available, reusing that: $storagePath\$fileqcow2"
}

# build container file
$containerfile = "$storagePath\Dockerfile";
Remove-Item -Path "$storagePath\Dockerfile" -Force -ErrorAction SilentlyContinue
Write-Output "[$(Get-Date -Format HH:mm:ss)] Build $containerfile"
Add-Content -Path $containerfile -Value 'FROM scratch' -Force
Add-Content -Path $containerfile -Value "ADD $fileqcow2 /disk/" -Force

$buildScript = "$PSScriptRoot\..\..\lib\scripts\windows\host\image\Build-Image.ps1"

# build container
if ( $Push ) {
    &$buildScript -InputFolder $storagePath -ImageName $ImageName -ImageTag $ImageTag -Push -ShowLogs
}
else {
    &$buildScript -InputFolder $storagePath -ImageName $ImageName -ImageTag $ImageTag -ShowLogs
}

Write-Host "Total duration: $('{0:hh\:mm\:ss}' -f $mainStopwatch.Elapsed )"
