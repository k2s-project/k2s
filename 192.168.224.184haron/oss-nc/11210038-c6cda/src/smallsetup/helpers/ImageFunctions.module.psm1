# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$registryFunctionsModule = "$PSScriptRoot\RegistryFunctions.module.psm1"
$setupInfoModule = "$PSScriptRoot\..\..\lib\modules\windows\cluster\k2s.cluster.module\setupinfo\setupinfo.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons\addons.module.psm1"

Import-Module $registryFunctionsModule, $setupInfoModule, $addonsModule -DisableNameChecking

$windowsPauseImageRepository = 'shsk2s.azurecr.io/pause-win'

class ContainerImage {
    [string]$ImageId
    [string]$Repository
    [string]$Tag
    [string]$Node
    [string]$Size
}

class PushedImage {
    [string]$Name
    [string]$Tag
}

$headers = @(
    'application/vnd.oci.image.manifest.v1+json',
    'application/vnd.oci.image.index.v1+json',
    'application/vnd.oci.artifact.manifest.v1+json',
    'application/vnd.docker.distribution.manifest.v2+json',
    'application/vnd.docker.distribution.manifest.list.v2+json',
    'application/vnd.docker.distribution.manifest.v1+prettyjws',
    'application/vnd.docker.distribution.manifest.v1+json'
)
$concatinatedHeadersString = ''
$headers | ForEach-Object { $concatinatedHeadersString += " -H `"Accept: $_`"" } 

function Create-KubernetesImageJsonFileIfNotExists() {
    $fileExists = Test-Path -Path $global:KubernetesImagesJson
    if (!$fileExists) {
        New-Item -Path $global:KubernetesImagesJson | Out-Null

        '[]' | Set-Content -Path "$global:KubernetesImagesJson"
    }
}

function Get-KubernetesImagesFromJson() {
    Create-KubernetesImageJsonFileIfNotExists
    $kubernetesImages = @(Get-Content -Path $global:KubernetesImagesJson -Raw | ConvertFrom-Json)
    return $kubernetesImages
}

<#
.DESCRIPTION
This function is used to collect the kubernetes images present on the nodes.
!!! CAUTION !!! This function must be called only during installation. Otherwise, user's images will also be written into the json file.
User will see an incorrect output on listing images.
#>
function Write-KubernetesImagesIntoJson() {
    Create-KubernetesImageJsonFileIfNotExists
    $kubernetesImages = @()
    $linuxKubernetesImages = Get-ContainerImagesOnLinuxNode
    $windowsKubernetesImages = $(Get-ContainerImagesOnWindowsNode) | Where-Object { $_.Repository -match $windowsPauseImageRepository }
    $kubernetesImages = @($linuxKubernetesImages) + @($windowsKubernetesImages)
    $kubernetesImagesJsonString = $kubernetesImages | ConvertTo-Json -Depth 100
    $kubernetesImagesJsonString | Set-Content -Path $global:KubernetesImagesJson
}

function Filter-Images([ContainerImage[]]$ContainerImages, [ContainerImage[]]$ContainerImagesToBeCleaned) {
    $filteredImages = @()
    #Write-Host ($ContainerImagesToBeCleaned | Format-Table | Out-String)
    foreach ($containerImage in $ContainerImages) {
        $count = ($ContainerImagesToBeCleaned | Where-Object { $_.ImageId -eq $containerImage.ImageId } ).Count
        if ($count -eq 0 ) {
            $filteredImages += $containerImage
        }
    }
    return $filteredImages
}

function Get-ContainerImagesOnLinuxNode([bool]$IncludeK8sImages = $false) {
    $hostname = Get-ControlPlaneNodeHostname
    $KubernetesImages = Get-KubernetesImagesFromJson
    $linuxContainerImages = @()
    $output = ExecCmdMaster 'sudo buildah images' -NoLog
    foreach ($line in $output[1..($output.Count - 1)]) {
        $words = $($line -replace '\s+', ' ').split()
        $containerImage = [ContainerImage]@{
            ImageId    = $words[2]
            Repository = $words[0]
            Tag        = $words[1]
            Node       = "$hostname"
            Size       = $words[$words.Count - 2] + $words[$words.Count - 1]
        }
        $linuxContainerImages += $containerImage
    }
    if ($IncludeK8sImages -eq $false) {
        $linuxContainerImages =
        Filter-Images -ContainerImages $linuxContainerImages -ContainerImagesToBeCleaned $KubernetesImages
    }
    return $linuxContainerImages
}

function Get-ContainerImagesOnWindowsNode([bool]$IncludeK8sImages = $false) {
    $KubernetesImages = Get-KubernetesImagesFromJson
    $kubeBinPath = Get-KubeBinPath
    $output = &$global:BinPath\crictl --config $kubeBinPath\crictl.yaml images 2> $null
    $node = $env:ComputerName.ToLower()

    $windowsContainerImages = @()
    if ($output.Count -gt 1) {
        foreach ( $line in $output[1..($output.Count - 1)]) {
            $words = $($line -replace '\s+', ' ').split()
            $containerImage = [ContainerImage]@{
                ImageId    = $words[2]
                Repository = $words[0]
                Tag        = $words[1]
                Size       = $words[3]
                Node       = $node
            }
            $windowsContainerImages += $containerImage
        }
        if ($IncludeK8sImages -eq $false) {
            $windowsContainerImages =
            Filter-Images -ContainerImages $windowsContainerImages -ContainerImagesToBeCleaned $KubernetesImages
        }
    }
    return $windowsContainerImages
}

function Get-PushedContainerImages() {
    if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'registry' })) -eq $false) {
        return
    }

    $registryName = $(Get-RegistriesFromSetupJson) | Where-Object { $_ -match 'k2s-registry.*' }
    $auth = Get-RegistryAuthToken $registryName
    if (!$auth) {
        Write-Error "Can't find authentication token for $registryName."
        return
    }

    $catalog = $(curl.exe --retry 3 --retry-all-errors -X GET http://$registryName/v2/_catalog -H "Authorization: Basic $auth") 2> $null | Out-String | ConvertFrom-Json

    $images = $catalog.psobject.properties['repositories'].value

    $pushedContainerImages = @()
    foreach ($image in $images) {
        $imageWithTags = curl.exe --retry 3 --retry-all-errors -X GET http://$registryName/v2/$image/tags/list -H "Authorization: Basic $auth" 2> $null | Out-String | ConvertFrom-Json
        $tags = $imageWithTags.psobject.properties['tags'].value

        foreach ($tag in $tags) {
            $pushedimage = [PushedImage]@{
                Name = "$registryName/" + $image
                Tag  = $tag
            }
            $pushedContainerImages += $pushedimage
        }
    }

    return $pushedContainerImages
}

function Remove-Image([ContainerImage]$ContainerImage) {
    $kubeBinPath = Get-KubeBinPath
    $output = ''
    if ($containerImage.Node -eq $env:ComputerName.ToLower()) {
        $output = $(&$global:BinPath\crictl --config $kubeBinPath\crictl.yaml rmi $containerImage.ImageId 2>&1)
    }
    else {
        $imageId = $containerImage.ImageId
        $output = ExecCmdMaster "sudo crictl rmi $imageId" -NoLog
    }

    $errorString = Get-ErrorMessageIfImageDeletionFailed -Output $output

    return $errorString
}

function Remove-PushedImage($name, $tag) {
    $registryName = $(Get-RegistriesFromSetupJson) | Where-Object { $_ -match 'k2s-registry.*' }
    $auth = Get-RegistryAuthToken $registryName
    if (!$auth) {
        Write-Error "Can't find authentication token for $registryName."
        return
    }

    if ($name.Contains("$registryName/")) {
        $name = $name.Replace("$registryName/", '')
    }

    $status = $null
    $statusDescription = $null

    $headRequest = "curl.exe -m 10 --retry 3 --retry-all-errors -I http://$registryName/v2/$name/manifests/$tag -H 'Authorization: Basic $auth' $concatinatedHeadersString -v 2>&1"
    $headResponse = Invoke-Expression $headRequest
    foreach ($line in $headResponse) {
        if ($line -match 'HTTP/1.1 (\d{3}) (.+)') {
            # Extract the HTTP status code and description
            $status = $matches[1]
            $statusDescription = $matches[2]
            break
        }
    }
    $imageName = $name + ':' + $tag
    if ($status -eq '200') {
        Write-Output "Successfully retreived digest for $imageName from $registryName"
    }
    else {
        Write-Error "An error occurred while getting digest. HTTP Status Code: $status $statusDescription"
    }


    $lineWithDigest = $headResponse | Select-String 'Docker-Content-Digest:' | Select-Object -ExpandProperty Line -First 1
    $match = Select-String 'Docker-Content-Digest: (.*)' -InputObject $lineWithDigest
    $digest = $match.Matches.Groups[1].Value
    
    $deleteRequest = "curl.exe -m 10 -I --retry 3 --retry-all-errors -X DELETE http://$registryName/v2/$name/manifests/$digest -H 'Authorization: Basic $auth' $concatinatedHeadersString -v 2>&1"
    $deleteResponse = Invoke-Expression $deleteRequest

    foreach ($line in $deleteResponse) {
        if ($line -match 'HTTP/1.1 (\d{3}) (.+)') {
            # Extract the HTTP status code and description
            $status = $matches[1]
            $statusDescription = $matches[2]
            break
        }
    }

    $imageName = $name + ':' + $tag
    if ($status -eq '202') {
        Write-Output "Successfully deleted image $imageName from $registryName"
    }
    else {
        Write-Error "An error occurred while deleting image. HTTP Status Code: $status $statusDescription"
    }
}

function Get-RegistryAuthToken($registryName) {
    # read auth
    $authJson = ExecCmdMaster 'sudo cat /root/.config/containers/auth.json' -NoLog
    $dockerConfig = $authJson | ConvertFrom-Json
    $dockerAuth = $dockerConfig.psobject.properties['auths'].value
    $authk2s = $dockerAuth.psobject.properties["$registryName"].value
    $auth = $authk2s.psobject.properties['auth'].value
    return $auth
}

function Get-ContainerImagesInk2s([bool]$IncludeK8sImages = $false) {
    $linuxContainerImages = Get-ContainerImagesOnLinuxNode -IncludeK8sImages $IncludeK8sImages
    $windowsContainerImages = Get-ContainerImagesOnWindowsNode -IncludeK8sImages $IncludeK8sImages
    $allContainerImages = @($linuxContainerImages) + @($windowsContainerImages)
    return $allContainerImages
}

function Get-ErrorMessageIfImageDeletionFailed([string]$Output) {
    if ($output.Contains('image is in use by a container')) {
        return 'Unable to delete the image as it is in use by a container.'
    }
    elseif ($output.Contains('context deadline exceeded')) {
        return 'Unable to delete the image as the operation timed-out.'
    }
    elseif ($output.Contains('no such image')) {
        return 'Unable to delete the image as it was not found.'
    }
    else {
        return $null
    }
}

function Show-ImageDeletionStatus([ContainerImage]$ContainerImage, [string]$ErrorMessage) {
    $imageName = $ContainerImage.Repository + ':' + $ContainerImage.Tag
    $node = $ContainerImage.Node
    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
        Write-Host "Successfully deleted image $imageName from $node"
    }
    else {
        Write-Host "Failed to delete image $imageName from $node. Reason: $ErrorMessage"
    }
}

Export-ModuleMember -Function Get-ContainerImagesInk2s,
Remove-Image,
Get-PushedContainerImages,
Remove-PushedImage,
Show-ImageDeletionStatus,
Get-ContainerImagesOnLinuxNode,
Get-ContainerImagesOnWindowsNode,
Write-KubernetesImagesIntoJson
