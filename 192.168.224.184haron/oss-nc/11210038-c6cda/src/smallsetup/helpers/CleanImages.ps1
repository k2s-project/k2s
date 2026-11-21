# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# CleanImages.ps1

<#
.Description
Removes all container images present in K2s
#>

param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$imageModule = "$PSScriptRoot\ImageFunctions.module.psm1"
$statusModule = "$PSScriptRoot\..\..\lib\modules\windows\cluster\k2s.cluster.module\status\status.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $imageModule, $statusModule, $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$allContainerImages = Get-ContainerImagesInk2s -IncludeK8sImages $false
$deletedImages = @()

if ($allContainerImages.Count -eq 0) {
    $errMsg = 'Nothing to delete.'    
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'no-images' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

foreach ($containerImage in $allContainerImages) {
    $alreadyDeleted = $deletedImages | Where-Object { $containerImage.ImageId -eq $_ }
    if ($alreadyDeleted.Count -eq 0) {
        $errorString = Remove-Image -ContainerImage $containerImage
        if ($null -eq $errorString) {
            $deletedImages += $imageToBeDeleted.ImageId
        }
        Show-ImageDeletionStatus -ContainerImage $containerImage -ErrorMessage $errorString
    }
    else {
        $image = $containerImage.Repository + ':' + $containerImage.Tag
        $imageId = $containerImage.ImageId
        $message = "No Action required for $image as Image Id $imageId is already deleted."
        Write-Log $message -Console
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
