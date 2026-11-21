# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Tag container images in K2s

.DESCRIPTION
Tag container images in K2s

.PARAMETER Id
The image id of the image to be exported

.PARAMETER ImageName
The image name of the image to be tagged

.PARAMETER TargetImageName
The new image name

.EXAMPLE
# Tag container image "image:v1" with new name "image:v2" in K2s
PS> .\Tag-Image.ps1 -ImageName "image:v1" -TargetImageName "image:v2"
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Id of the image to be tagged with a new name')]
    [string] $Id,
    [parameter(Mandatory = $false, HelpMessage = 'Name of the image to be tagged with a new name.')]
    [string] $ImageName,
    [parameter(Mandatory = $true, HelpMessage = 'New image name')]
    [string] $TargetImageName,
    [parameter(Mandatory = $false, HelpMessage = 'Comma-separated node names to target')]
    [string] $Nodes = '',
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

function Send-TagError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $false)]
        [string]$Severity = 'Warning'
    )

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity $Severity -Code $Code -Message $Message
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $Message -Error
    exit 1
}

function Get-NodeInfoByName {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable[]]$NodeInfos,
        [Parameter(Mandatory = $true)]
        [string]$NodeName
    )

    $nodeNameLower = $NodeName.ToLower()
    return @($NodeInfos | Where-Object { $_.Name -eq $nodeNameLower } | Select-Object -First 1)[0]
}

function Invoke-TagOnNode {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$NodeInfo,
        [Parameter(Mandatory = $true)]
        [string]$SourceImage,
        [Parameter(Mandatory = $true)]
        [string]$TargetImage
    )

    if ($NodeInfo.OS -eq 'linux') {
        if ($NodeInfo.Kind -eq 'ControlPlane') {
            return (Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah tag $SourceImage $TargetImage 2>&1" -Retries 5).Success
        }
        if ($NodeInfo.Kind -eq 'LinuxWorker') {
            return (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo buildah tag $SourceImage $TargetImage 2>&1" -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog -IgnoreErrors).Success
        }
    }

    if ($NodeInfo.OS -eq 'windows') {
        if ($NodeInfo.Kind -eq 'LocalWindows') {
            $kubeBinPath = Get-KubeBinPath
            $nerdctlExe = "$kubeBinPath\nerdctl.exe"
            $retries = 5
            while ($retries -gt 0) {
                $retries--
                &$nerdctlExe -n="k8s.io" tag $SourceImage $TargetImage
                if ($?) {
                    return $true
                }
                Start-Sleep 1
            }
            return $false
        }

        if ($NodeInfo.Kind -eq 'WindowsWorker') {
            $session = $null
            try {
                $session = Open-RemoteSession -VmName $NodeInfo.Name -VmPwd (Get-DefaultTempPwd) -NoLog
                $remoteResult = Invoke-Command -Session $session -ArgumentList $SourceImage, $TargetImage -ScriptBlock {
                    param($sourceImage, $targetImage)

                    $nerdctlCmd = Get-Command nerdctl.exe -ErrorAction SilentlyContinue
                    $nerdctlExe = if ($nerdctlCmd) { $nerdctlCmd.Path } else { 'nerdctl.exe' }

                    $retries = 5
                    while ($retries -gt 0) {
                        $retries--
                        & $nerdctlExe -n='k8s.io' tag $sourceImage $targetImage 2>$null | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            return $true
                        }
                        Start-Sleep 1
                    }

                    return $false
                }

                return [bool]$remoteResult
            }
            finally {
                if ($null -ne $session) {
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                }
            }
        }
    }

    return $false
}

function Get-MatchingTagImages {
    param(
        [Parameter(Mandatory = $true)]
        $Images,
        [Parameter(Mandatory = $false)]
        [string]$SearchId = '',
        [Parameter(Mandatory = $false)]
        [string]$SearchName = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($SearchId)) {
        return @($Images | Where-Object { $_.ImageId -eq $SearchId })
    }

    if ([string]::IsNullOrWhiteSpace($SearchName)) {
        return @()
    }

    $searchNameHasTag = $SearchName.Contains(':')

    return @($Images | Where-Object {
            $retrievedName = $_.Repository + ':' + $_.Tag
            if ($searchNameHasTag) {
                return $retrievedName -eq $SearchName
            }

            return $_.Repository -eq $SearchName
        })
}

function Select-PreferredTagImages {
    param(
        [Parameter(Mandatory = $true)]
        $Images
    )

    if ($null -eq $Images -or $Images.Count -eq 0) {
        return @()
    }

    $selectedImages = @()
    $imageGroupsByNode = $Images | Group-Object -Property Node
    foreach ($group in $imageGroupsByNode) {
        $taggedImages = @($group.Group | Where-Object { $_.Tag -ne '<none>' -and $_.Repository -ne '<none>' })
        if ($taggedImages.Count -ge 1) {
            $selectedImages += $taggedImages[0]
        }
        elseif ($group.Group.Count -ge 1) {
            $selectedImages += $group.Group[0]
        }
    }

    return @($selectedImages)
}

$selectionResult = Get-ImagesByNodeSelection -Nodes $Nodes -IncludeK8sImages $true -LogPrefix 'Tag'
$targetNodeInfos = @($selectionResult.NodeInfos)
$linuxContainerImages = @($selectionResult.LinuxImages)
$windowsContainerImages = @($selectionResult.WindowsImages)

if ([string]::IsNullOrWhiteSpace($Id) -and [string]::IsNullOrWhiteSpace($ImageName)) {
    Send-TagError -Code 'image-tag-failed' -Message 'Image Name or ImageId is not provided. Cannot tag image.'
    return
}

$foundLinuxImages = @(Get-MatchingTagImages -Images $linuxContainerImages -SearchId $Id -SearchName $ImageName)
$foundWindowsImages = @(Get-MatchingTagImages -Images $windowsContainerImages -SearchId $Id -SearchName $ImageName)

$selectedNodes = Resolve-NodeList -Nodes $Nodes
if ($selectedNodes.Count -gt 0) {
    $imagesToTag = @()
    $imagesToTag += @(Select-PreferredTagImages -Images $foundLinuxImages)
    $imagesToTag += @(Select-PreferredTagImages -Images $foundWindowsImages)

    if ($imagesToTag.Count -eq 0) {
        if ($Id -ne '') {
            Send-TagError -Code 'image-not-found' -Message "Image with Id ${Id} not found on selected node(s)!"
            return
        }

        Send-TagError -Code 'image-tag-failed' -Message "Image '$ImageName' not found on selected node(s)"
        return
    }

    $failedNodes = @()
    foreach ($image in $imagesToTag) {
        $sourceImage = "$($image.Repository):$($image.Tag)"
        $targetNode = Get-NodeInfoByName -NodeInfos $targetNodeInfos -NodeName $image.Node
        if ($null -eq $targetNode) {
            $failedNodes += $image.Node
            Write-Log "[Tag] Unable to resolve target node '$($image.Node)'" -Console
            continue
        }

        Write-Log "Tagging image '$sourceImage' as '$TargetImageName' on node '$($targetNode.Name)'" -Console
        $success = Invoke-TagOnNode -NodeInfo $targetNode -SourceImage $sourceImage -TargetImage $TargetImageName
        if (-not $success) {
            $failedNodes += $targetNode.Name
        }
    }

    if ($failedNodes.Count -gt 0) {
        Send-TagError -Code 'image-tag-failed' -Message "Tagging failed on node(s): $($failedNodes -join ', ')"
        return
    }

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }

    return
}

$foundLinuxImages = @(Select-PreferredTagImages -Images $foundLinuxImages)
$foundWindowsImages = @(Select-PreferredTagImages -Images $foundWindowsImages)


if ($foundLinuxImages.Count -eq 0 -and $foundWindowsImages.Count -eq 0) {
    If ($Id -ne '') {
        Send-TagError -Code 'image-not-found' -Message "Image with Id ${Id} not found!"
        return
    }

    If ($ImageName -ne '') {
        Send-TagError -Code 'image-tag-failed' -Message "Image '$ImageName' not found"
        return
    }
}

if ($foundLinuxImages.Count -gt 1 -or $foundWindowsImages.Count -gt 1) {
    Send-TagError -Code 'two-images-found' -Message "More than one image has the id: $Id. Please use --name to identify the image instead or delete the other image/s"
    return
}

$tagLinuxImage = $false
$tagWindowsImage = $false
$linuxAndWindowsImageFound = $false

if ($foundLinuxImages.Count -eq 1 -and $foundWindowsImages.Count -eq 1) {
    Write-Log 'Linux and Windows image found'
    $linuxAndWindowsImageFound = $true
    $answer = Read-Host 'WARNING: Linux and Windows image found. Which image should be tagged? (l/w) [Linux or Windows]'
    if ($answer -ne 'l' -and $answer -ne 'w') {
        $errMsg = 'Tag image cancelled.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeUserCancellation) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    if ($answer -eq 'l') {
        $tagLinuxImage = $true
    }

    if ($answer -eq 'w') {
        $tagWindowsImage = $true
    }
}

if ((($foundLinuxImages.Count -eq 1) -and !$linuxAndWindowsImageFound) -or $tagLinuxImage) {
    $image = $foundLinuxImages[0]
    $imageTag = $image.Tag
    $imageName = $image.Repository
    $ImageName = "${imageName}:${imageTag}"
    $targetNode = Get-NodeInfoByName -NodeInfos $targetNodeInfos -NodeName $image.Node
    if ($null -eq $targetNode) {
        Send-TagError -Code 'nodes-not-found' -Message "Unable to resolve target node '$($image.Node)' for image '$ImageName'"
        return
    }

    Write-Log "Tagging Linux image '$ImageName' as '$TargetImageName' on node '$($targetNode.Name)'" -Console
    $success = Invoke-TagOnNode -NodeInfo $targetNode -SourceImage $ImageName -TargetImage $TargetImageName
    if (!$success) {
        Send-TagError -Code 'image-tag-failed' -Message "Error tagging image '$ImageName' as '$TargetImageName' on node '$($targetNode.Name)'"
        return
    }

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }

    exit 0
}

if ((($foundWindowsImages.Count -eq 1) -and !$linuxAndWindowsImageFound) -or $tagWindowsImage) {
    $image = $foundWindowsImages[0]
    $imageTag = $image.Tag
    $imageName = $image.Repository
    $ImageName = "${imageName}:${imageTag}"
    $targetNode = Get-NodeInfoByName -NodeInfos $targetNodeInfos -NodeName $image.Node
    if ($null -eq $targetNode) {
        Send-TagError -Code 'nodes-not-found' -Message "Unable to resolve target node '$($image.Node)' for image '$ImageName'"
        return
    }

    Write-Log "Tagging Windows image '$ImageName' as '$TargetImageName' on node '$($targetNode.Name)'" -Console
    $success = Invoke-TagOnNode -NodeInfo $targetNode -SourceImage $ImageName -TargetImage $TargetImageName

    if (!$success) {
        Send-TagError -Code 'image-tag-failed' -Message "Error tagging image '$ImageName' as '$TargetImageName' on node '$($targetNode.Name)'"
        return
    }

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }

    exit 0
}
