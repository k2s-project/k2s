# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Remove container image in K2s

.DESCRIPTION
Remove container image in K2s

.PARAMETER ImageId
The image id of the image to be removed

.PARAMETER ImageName
The image name of the image to be removed

.PARAMETER FromRegistry
Remove image from local storage as well as from local container registry

.EXAMPLE
# Remove image with image name
PS> .\Remove-Image.ps1 -ImageName "image:v1"

.EXAMPLE
# Remove image with image id and from registry as well
PS> .\Remove-Image.ps1 -ImageId "f8c20f8bbcb6" -FromRegistry
#>

Param (
    [parameter(Mandatory = $false)]
    [string] $ImageId = '',
    [parameter(Mandatory = $false)]
    [string] $ImageName = '',
    [parameter(Mandatory = $false)]
    [string] $Nodes = '',
    [parameter(Mandatory = $false)]
    [switch] $FromRegistry,
    [parameter(Mandatory = $false, HelpMessage = 'Force removal by first removing any containers using the image')]
    [switch] $Force,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$imageCommonModule = "$PSScriptRoot/Image-Common.module.psm1"
Import-Module $imageCommonModule

if (-not (Initialize-ImageScriptContext -ShowLogs:$ShowLogs -EncodeStructuredOutput:$EncodeStructuredOutput -MessageType $MessageType)) {
    return
}

if ($FromRegistry) {
    $kubeToolsPath = Get-KubeToolsPath
    &"$kubeToolsPath\kubectl.exe" get namespace registry 2> $null | Out-Null
    if (!$?) {
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'registry-not-running' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    $imageSelection = Get-ImagesByNodeSelection -Nodes '' -IncludeK8sImages $false -LogPrefix 'ImageRm'
    $pushedimages = Get-PushedContainerImages
    if ($ImageName -eq '') {
        $errMsg = 'ImageName incl. Tag is needed to remove image from registry. Cannot remove image.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'image-remove-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    foreach ($image in $pushedimages ) {
        if ($($image.Name + ':' + $image.Tag) -eq $ImageName) {
            Remove-PushedImage $image.Name $image.Tag
            if ($EncodeStructuredOutput -eq $true) {
                Send-ToCli -MessageType $MessageType -Message @{Error = $null }
            }
            return
        }
    }

    $errMsg = "$ImageName could not be found."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'image-not-found' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

$imageSelection = Get-ImagesByNodeSelection -Nodes $Nodes -IncludeK8sImages $false -LogPrefix 'ImageRm'
$allContainerImages = @($imageSelection.AllImages)
$foundImages = @()
if ($ImageId -ne '') {
    $foundImages = @($allContainerImages | Where-Object { $_.ImageId -eq $ImageId })
}
else {
    if ($ImageName -eq '') {
        $errMsg = 'Image Name or ImageId is not provided. Cannot remove image.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'image-remove-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
    else {
        $foundImages = @($allContainerImages | Where-Object {
                $calculatedName = $_.Repository + ':' + $_.Tag
                return ($calculatedName -eq $ImageName)
            })

    }
}

$deletionfailed = $false
$deletionFailureMessages = @()
if ($foundImages.Count -eq 0) {
    $errMsg = 'Image was not found. Please ensure that you have specified the right image details to be deleted'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'image-not-found' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}
else {
    # Dedup key is 'ImageId::Node' so the same image ID on different nodes is
    # each removed independently, but duplicate entries for the same ID+node are skipped.
    $deletedImageKeys = @()
    foreach ($imageToBeDeleted in $foundImages) {
        $dedupKey = "$($imageToBeDeleted.ImageId)::$($imageToBeDeleted.Node)"
        $alreadyDeleted = $deletedImageKeys | Where-Object { $_ -eq $dedupKey }
        if ($alreadyDeleted.Count -eq 0) {
            $errorString = Remove-Image -ContainerImage $imageToBeDeleted -Force:$Force
            if ($null -eq $errorString) {
                $deletedImageKeys += $dedupKey
            }
            $deletionExitCode = Show-ImageDeletionStatus -ContainerImage $imageToBeDeleted -ErrorMessage $errorString
            if($deletionExitCode -eq 1) {
                $deletionfailed = $true
                $imageRef = $imageToBeDeleted.Repository + ':' + $imageToBeDeleted.Tag
                $nodeRef = $imageToBeDeleted.Node
                if ([string]::IsNullOrWhiteSpace($errorString)) {
                    $deletionFailureMessages += "Failed to delete image $imageRef from $nodeRef"
                }
                else {
                    $deletionFailureMessages += "Failed to delete image $imageRef from $nodeRef. Reason: $errorString"
                }
            }
        }
        else {
            $image = $imageToBeDeleted.Repository + ':' + $imageToBeDeleted.Tag
            $imageId = $imageToBeDeleted.ImageId
            $message = "No Action required for $image (id=$imageId) on node '$($imageToBeDeleted.Node)' - already deleted."
            Write-Log $message
        }
    }
}

if ($deletionfailed) {
    $errMsg = "Image couldn't be deleted!"
    if ($deletionFailureMessages.Count -gt 0) {
        $errMsg = $deletionFailureMessages[0]
        if (-not $Force -and $errMsg -match 'in use by a container') {
            $errMsg += ' Use --force to stop/remove dependent containers first.'
        }
    }

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'image-rm-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
