# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Remove all container images in K2s

.DESCRIPTION
Remove all container images in K2s
#>

param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Comma-separated node names to target')]
    [string] $Nodes = '',
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

$imageSelection = Get-ImagesByNodeSelection -Nodes $Nodes -IncludeK8sImages $false -LogPrefix 'Clean'
$allContainerImages = @($imageSelection.AllImages)
# Dedup key is 'ImageId::Node' so the same image ID on different nodes is
# each removed independently, but duplicate entries for the same ID+node are skipped.
$deletedImageKeys = @()

if ($allContainerImages.Count -eq 0) {
    $errMsg = 'Nothing to delete. '
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'no-images' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

$deletionfailed = $false
foreach ($containerImage in $allContainerImages) {
    $dedupKey = "$($containerImage.ImageId)::$($containerImage.Node)"
    $alreadyDeleted = $deletedImageKeys | Where-Object { $_ -eq $dedupKey }
    if ($alreadyDeleted.Count -eq 0) {
        $errorString = Remove-Image -ContainerImage $containerImage
        if ($null -eq $errorString) {
            $deletedImageKeys += $dedupKey
        }
        $deletionExitCode = Show-ImageDeletionStatus -ContainerImage $containerImage -ErrorMessage $errorString
        if($deletionExitCode -eq 1) {
            $deletionfailed = $true
        }
    }
    else {
        $image = $containerImage.Repository + ':' + $containerImage.Tag
        $imageId = $containerImage.ImageId
        $message = "No Action required for $image (id=$imageId) on node '$($containerImage.Node)' - already deleted."
        Write-Log $message -Console
    }
}

if ($deletionfailed) {
    if ($EncodeStructuredOutput -eq $true) {
        $errMsg = "Not all images could be deleted!"
        $err = New-Error -Severity Warning -Code 'image-clean-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}


if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
