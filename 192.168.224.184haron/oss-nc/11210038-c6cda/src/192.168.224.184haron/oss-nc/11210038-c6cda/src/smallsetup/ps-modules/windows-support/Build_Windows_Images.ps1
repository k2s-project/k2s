# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Builds the Windows-based images of a given 3rd-party tooling

.DESCRIPTION
Builds the Windows-based images of a given 3rd-party tooling with supporting manifests for all supported Windows versions.

.PARAMETER Registry
Registry to push to, e.g. 'k2s-registry.local'

.PARAMETER Name
Name of the image including paths, e.g. '/sig-storage/livenessprobe'

.PARAMETER Tag
Image tag, e.g. 'v1.2.3'

.PARAMETER Dockerfile
Dockerfile path

.PARAMETER RegUser
User for registry login

.PARAMETER RegPw
Password for registry login

.PARAMETER AllowInsecureRegistries
If set to true, insecure registries like local registries are allowed.

.PARAMETER CertPw
Password for certificate

.PARAMETER WorkDir
WorkDir path

.PARAMETER CertPath
Path to certificate

.PARAMETER ToolsImage
Image to use from which the executable are extracted
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = "Registry to push to, e.g. 'k2s-registry.local'")]
    [string] $Registry = '',
    [parameter(Mandatory = $true, HelpMessage = "Name of the image including paths, e.g. '/sig-storage/livenessprobe' or 'livenessprobe'")]
    [string] $Name,
    [parameter(Mandatory = $true, HelpMessage = "Image tag, e.g. 'v1.2.3'")]
    [string] $Tag,
    [parameter(Mandatory = $true, HelpMessage = 'Dockerfile path')]
    [string] $Dockerfile,
    [parameter(Mandatory = $true, HelpMessage = 'WorkDir path')]
    [string] $WorkDir,
    [parameter(Mandatory = $false, HelpMessage = 'User for registry login')]
    [string] $RegUser = '',
    [parameter(Mandatory = $false, HelpMessage = 'Password for registry login')]
    [string] $RegPw = '',
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, insecure registries like local registries are allowed.')]
    [switch] $AllowInsecureRegistries,
    [parameter(Mandatory = $false, HelpMessage = 'Password for certificate')]
    [string] $CertPw = '',
    [parameter(Mandatory = $false, HelpMessage = 'Path to certificate')]
    [string] $CertPath = '',
    [parameter(Mandatory = $false, HelpMessage = 'Image to use from which the executable are extracted')]
    [string] $ToolsImage = ''
)
Write-Output 'Windows images build started:'
Write-Output " - registry: $Registry"
Write-Output " - name: $Name"
Write-Output " - tag: $Tag"
Write-Output " - dockerfile: $Dockerfile"
Write-Output " - allow insecure registries: $AllowInsecureRegistries"
Write-Output " - workdir: $WorkDir"
Write-Output " - registry user: $RegUser"
Write-Output " - certificate path: $CertPath"
Write-Output " - tools image: $ToolsImage"

Import-Module "$PSScriptRoot\..\docker\docker.module.psm1", "$PSScriptRoot\windows-support.module.psm1"
Import-Module "$PSScriptRoot\..\..\..\lib\modules\windows\node\k2s.node.module\windowsnode\downloader\artifacts\docker\docker.module.psm1"

Install-WinDocker

Start-Service docker

Set-DockerToExperimental

# login only if registry is specified
if ($Registry -ne '') {
    Start-DockerLogin -Registry $Registry -RegUser $RegUser -RegPw $RegPw
}

$currentLocation = Get-Location

Set-Location $PSScriptRoot

try {
    if ($Registry -ne '' -And $Name.StartsWith('/') -ne $true) {
        $Name = "/$($Name)"
    }

    # extract executable names from dockerfile
    $Executables = Get-DockerfileExecutables -DockerfilePath $Dockerfile
    Write-Output "Extracted executables from Dockerfile '$Dockerfile': $Executables"

    if( $ToolsImage -ne '' ) {            
        # extract executables from dockerfile (only if tools image is specified)
        Copy-ExecutablesFromImage -ToolImage $ToolsImage -Executables $Executables -OutputDir $WorkDir 
    }

    if ($CertPath -ne '') {
        # sign all executables
        foreach ($exe in $Executables) {
            Write-SignatureExecutable -ExecutablePath "$WorkDir\$exe" -CertPath $CertPath -CertPw $CertPw
        }
    }

    $aggregateTag = "$($Registry)$($Name):$($Tag)"

    Write-Output "Creating images and manifest for tag '$aggregateTag'.."

    $versions = Get-WindowsImageVersions

    foreach ($version in $versions) {
        $targetTag = "$aggregateTag-$($version.TagSuffix)"

        Write-Output "  Building image for tag '$targetTag' based on Windows version '$($version.BaseVersion)'.."

        Start-BuildDockerImage -Tag $targetTag -Dockerfile $Dockerfile -ToolVersion $Tag -WindowsBaseVersion $($version.BaseVersion) -WorkDir $WorkDir

        # push only if registry is specified
        if ($Registry -ne '') {
            Write-Output "  Pushing image '$targetTag' to '$Registry'.."

            Push-DockerImage -Tag $targetTag

            Write-Output "  Creating manifest for '$aggregateTag' with '$targetTag'.."

            New-DockerManifest -Tag $aggregateTag -AmendTag $targetTag -AllowInsecureRegistries:$AllowInsecureRegistries

            Write-Output "  Annotating manifest '$aggregateTag' with '$targetTag', OS '$($version.OS)', arch '$($version.Arch)' and OS version '$($version.OSVersion)'.."

            New-DockerManifestAnnotation -Tag $aggregateTag -AmendTag $targetTag -OS $version.OS -Arch $version.Arch -OSVersion $version.OSVersion
        }
    }

    if ($Registry -ne '') {
        Write-Output "  Pushing manifest for '$aggregateTag' to '$Registry'.."

        Push-DockerManifest -Tag $aggregateTag -AllowInsecureRegistries:$AllowInsecureRegistries

        Write-Output "Images and manifest for tag '$aggregateTag' created."
    } else {
        Write-Output "Images for tag '$aggregateTag' created."
    }
}
finally {
    Set-Location $currentLocation
}



