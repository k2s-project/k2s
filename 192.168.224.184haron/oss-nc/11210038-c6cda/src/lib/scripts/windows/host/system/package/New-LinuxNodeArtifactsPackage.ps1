# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

param (
        [parameter(Mandatory = $false, HelpMessage = 'Delete the sources used to create the package')]
	[switch] $DeleteSourcesAfterCreation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
        [switch] $ShowLogs = $false
	)

$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$controlPlaneUserName = Get-DefaultUserNameControlPlane
$controlPlaneIpAddress = Get-ConfiguredIPControlPlane

$installedDistributionOnControlPlane = Get-InstalledDistribution -UserName $controlPlaneUserName -IpAddress $controlPlaneIpAddress
$baseDirectoryOfDebPackagesOnWindowsHost = Get-BaseDirectoryOfKubenodeDebPackagesOnWindowsHost
$directoryOfDistributionDebPackagesOnWindowsHost = "$baseDirectoryOfDebPackagesOnWindowsHost\$installedDistributionOnControlPlane"

Copy-DebPackagesFromControlPlaneToWindowsHost -TargetPath $directoryOfDistributionDebPackagesOnWindowsHost

$imagesDirectory = Get-DirectoryOfKubenodeImagesOnWindowsHost
Copy-KubernetesImagesFromControlPlaneNodeToWindowsHost -TargetPath $imagesDirectory

$sourceDirectory = Get-DirectoryOfLinuxNodeArtifactsOnWindowsHost
$targetPath = Get-PathOfLinuxNodeArtifactsPackageOnWindowsHost

if (Test-Path($targetPath)) {
        Write-Log "Remove already existing file '$targetPath'"
        Remove-Item $targetPath -Force
}

Write-Log "Create compressed file '$targetPath' with artifacts for a Linux node..."
Compress-Archive -Path "$sourceDirectory\*" -DestinationPath "$targetPath" -Force
Write-Log "  done"

if ($DeleteSourcesAfterCreation) {
    Write-Log "Remove directory '$sourceDirectory'"
    Remove-Item "$sourceDirectory" -Recurse -Force
}
