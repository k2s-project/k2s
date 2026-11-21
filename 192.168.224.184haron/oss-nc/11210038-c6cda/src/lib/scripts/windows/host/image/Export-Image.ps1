# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Export image to filesystem

.DESCRIPTION
Export image to filesystem

.PARAMETER Id
The image id of the image to be exported

.PARAMETER Name
The image name of the image to be exported

.PARAMETER ExportPath
The path where the image should be exported

.PARAMETER DockerArchive
Export as docker archive (default OCI archive)

.PARAMETER ShowLogs
Show all logs in terminal

.EXAMPLE
# Export container image with name "image:v1" to C:\temp\tmp.tar
PS> .\Export-Image.ps1 -Name "image:v1" -ExportPath "C:\temp\tmp.tar"

.EXAMPLE
# Export container image with id f8c20f8bbcb6 as Docker archive to C:\temp\tmp.tar
PS> .\Export-Image.ps1 -Id "f8c20f8bbcb6" -DockerArchive -ExportPath "C:\temp\tmp.tar"
#>

Param (
    [parameter(Mandatory = $false)]
    [string] $Id,
    [parameter(Mandatory = $false)]
    [string] $Name,
    [parameter(Mandatory = $false)]
    [string] $ExportPath,
    [parameter(Mandatory = $false)]
    [string] $Nodes = '',
    [parameter(Mandatory = $false)]
    [switch] $DockerArchive = $false,
    [parameter(Mandatory = $false)]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'Optional path to crictl.exe; overrides the module-scope default (use during upgrade to supply the installed cluster path)')]
    [string] $CrictlExePath = '',
    [parameter(Mandatory = $false, HelpMessage = 'Optional path to crictl.yaml config; overrides the module-scope default (use during upgrade to supply the installed cluster path)')]
    [string] $CrictlConfigPath = '',
    [parameter(Mandatory = $false, HelpMessage = 'Optional path to nerdctl.exe; overrides the module-scope default (use during upgrade)')]
    [string] $NerdctlExePath = '',
    [parameter(Mandatory = $false, HelpMessage = 'Optional path to ctr.exe; overrides the module-scope default (use during upgrade)')]
    [string] $CtrExePath = ''
)
$imageCommonModule = "$PSScriptRoot/Image-Common.module.psm1"
Import-Module $imageCommonModule

if (-not (Initialize-ImageScriptContext -ShowLogs:$ShowLogs -EncodeStructuredOutput:$EncodeStructuredOutput -MessageType $MessageType)) {
    return
}

Write-Log "[ImageExport] Looking for image with Id='$Id' Name='$Name'"

$imageSelection = Get-ImagesByNodeSelection -Nodes $Nodes -IncludeK8sImages $true -LogPrefix 'ImageExport' -CrictlExePath $CrictlExePath -CrictlConfigPath $CrictlConfigPath
$linuxContainerImages = @($imageSelection.LinuxImages)
$windowsContainerImages = @($imageSelection.WindowsImages)

Write-Log "[ImageExport] Found $($linuxContainerImages.Count) linux container images"
$foundLinuxImages = @()
if ($Id -ne '') {
    Write-Log "[ImageExport] Searching by ImageId='$Id'"
    $foundLinuxImages = @($linuxContainerImages | Where-Object { $_.ImageId -eq $Id })
    Write-Log "[ImageExport] Found $($foundLinuxImages.Count) matching images by Id"
    # If multiple images match the same ID (e.g., one with tag and one with <none>),
    # prefer the one with an actual tag
    if ($foundLinuxImages.Count -gt 1) {
        $taggedImages = @($foundLinuxImages | Where-Object { $_.Tag -ne '<none>' })
        if ($taggedImages.Count -ge 1) {
            Write-Log "[ImageExport] Filtering to $($taggedImages.Count) tagged image(s) (excluding <none>)"
            $foundLinuxImages = @($taggedImages[0])
        } else {
            # All have <none> tag, just take the first one
            Write-Log "[ImageExport] All images have <none> tag, using first one"
            $foundLinuxImages = @($foundLinuxImages[0])
        }
    }
}
else {
    if ($Name -eq '') {
        Write-Error 'Image Name or ImageId is not provided. Cannot export image.'
    }
    else {
        $foundLinuxImages = @($linuxContainerImages | Where-Object {
                $imageName = $_.Repository + ':' + $_.Tag
                return ($imageName -eq $Name)
            })
    }
}

$foundWindowsImages = @()
if ($Id -ne '') {
    $foundWindowsImages = @($windowsContainerImages | Where-Object { $_.ImageId -eq $Id })
    # If multiple images match the same ID (e.g., one with tag and one with <none>),
    # prefer the one with an actual tag
    if ($foundWindowsImages.Count -gt 1) {
        $taggedImages = @($foundWindowsImages | Where-Object { $_.Tag -ne '<none>' })
        if ($taggedImages.Count -ge 1) {
            Write-Log "[ImageExport] Filtering Windows to $($taggedImages.Count) tagged image(s) (excluding <none>)"
            $foundWindowsImages = @($taggedImages[0])
        } else {
            Write-Log "[ImageExport] All Windows images have <none> tag, using first one"
            $foundWindowsImages = @($foundWindowsImages[0])
        }
    }
}
else {
    if ($Name -eq '') {
        Write-Error 'Image Name or ImageId is not provided. Cannot export image.'
    }
    else {
        $foundWindowsImages = @($windowsContainerImages | Where-Object {
                $imageName = $_.Repository + ':' + $_.Tag
                return ($imageName -eq $Name)
            })
    }
}

if ($foundLinuxImages.Count -eq 0 -and $foundWindowsImages.Count -eq 0) {
    if ($Id -ne '') {
        $errMsg = "Image with Id ${Id} not found!"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'image-not-found' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    if ($Name -ne '') {
        $errMsg = "Image ${Name} not found!"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'image-not-found' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
}

$windowsAndLinux = $($foundLinuxImages.Count -eq 1 -and $foundWindowsImages.Count -eq 1)

if ($foundLinuxImages.Count -eq 1) {
    Write-Log 'Linux image found!'
    $image = $foundLinuxImages[0]
    $imageId = $image.ImageId
    $imageName = $image.Repository
    $imageTag = $image.Tag
    $imageFullName = ''
    if ($imageTag -eq '<none>') {
        $imageFullName = $imageName
    }
    else {
        $imageFullName = "${imageName}:${imageTag}"
    }

    Write-Log "Exporting image ${imageFullName}. This can take some time..."

    $finalExportPath = $ExportPath

    if ($windowsAndLinux) {
        $filename = Split-Path -Path $ExportPath -Leaf
        $newFileName = $($filename -split '\.')[0] + '_linux.tar'
        $path = Split-Path -Path $ExportPath
        $finalExportPath = $path + '\' + $newFileName
    }

    $linuxNodeName = "$($image.Node)"
    if ([string]::IsNullOrWhiteSpace($linuxNodeName)) {
        Write-Log '[ImageExport] Linux image does not have node information. Falling back to control-plane.'
        $linuxNodeName = (Get-ConfigValue -Path (Get-SetupConfigFilePath) -Key 'ControlPlaneNodeHostname')
    }

    $linuxNodeInfo = Resolve-ImageNode -NodeName $linuxNodeName
    if ($null -eq $linuxNodeInfo -or $linuxNodeInfo.OS -ne 'linux') {
        $errMsg = "Unable to resolve linux node '$linuxNodeName' for image export."
        Write-Log $errMsg -Error
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'image-export-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        exit 1
    }

    $archiveFormat = if ($DockerArchive) { 'docker-archive' } else { 'oci-archive' }
    $remoteTarPath = "/tmp/${imageId}.tar"
    $exportCmd = "sudo buildah push ${imageId} ${archiveFormat}:${remoteTarPath}:${imageFullName} 2>&1"

    if ($linuxNodeInfo.Kind -eq 'ControlPlane') {
        $pushResult = Invoke-CmdOnControlPlaneViaSSHKey $exportCmd -NoLog -IgnoreErrors
    }
    else {
        $pushResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $exportCmd -IpAddress $linuxNodeInfo.IpAddress -UserName $linuxNodeInfo.Username -NoLog -IgnoreErrors
    }
    $pushResult.Output | Write-Log

    if (-not $pushResult.Success) {
        $errMsg = "Failed to export Linux image '${imageFullName}' on node '$($linuxNodeInfo.Name)'."
        Write-Log $errMsg -Error
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'image-export-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        exit 1
    }

    if ($linuxNodeInfo.Kind -eq 'ControlPlane') {
        Copy-FromControlPlaneViaSSHKey $remoteTarPath $finalExportPath
    }
    else {
        Copy-FromRemoteComputerViaSSHKey -Source $remoteTarPath -Target $finalExportPath -IpAddress $linuxNodeInfo.IpAddress -UserName $linuxNodeInfo.Username
    }

    Write-Log "Image ${imageFullName} exported successfully to ${finalExportPath}."

    if ($linuxNodeInfo.Kind -eq 'ControlPlane') {
        (Invoke-CmdOnControlPlaneViaSSHKey "cd /tmp && sudo rm -rf ${imageId}.tar" -NoLog -IgnoreErrors).Output | Write-Log
    }
    else {
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute "cd /tmp && sudo rm -rf ${imageId}.tar" -IpAddress $linuxNodeInfo.IpAddress -UserName $linuxNodeInfo.Username -NoLog -IgnoreErrors).Output | Write-Log
    }
}

if ($foundWindowsImages.Count -gt 1) {
    $errMsg = "Please specify the name and tag instead of id since there are more than one image with id $Id"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'image-not-found' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

if ($foundWindowsImages.Count -eq 1) {
    Write-Log 'Windows image found!'
    $image = $foundWindowsImages[0]
    $imageId = $image.ImageId
    $imageName = $image.Repository
    $imageTag = $image.Tag
    $imageFullName = ''
    if ($imageTag -eq '<none>') {
        $imageFullName = $imageName
    }
    else {
        $imageFullName = "${imageName}:${imageTag}"
    }
    Write-Log "Exporting image ${imageFullName}. This can take some time..."

    $finalExportPath = $ExportPath

    if ($windowsAndLinux) {
        $filename = Split-Path -Path $ExportPath -Leaf
        $newFileName = $($filename -split '\.')[0] + '_windows.tar'
        $path = Split-Path -Path $ExportPath
        $finalExportPath = $path + '\' + $newFileName
    }

    $nerdctlExe = if ($NerdctlExePath -ne '') { $NerdctlExePath } else { "$((Get-KubeBinPath))\nerdctl.exe" }
    $resolvedCtrExe = if ($CtrExePath -ne '') { $CtrExePath } else { "$((Get-KubeBinPath))\containerd\ctr.exe" }

    # Set up proxy env vars so nerdctl can reach the registry (mirrors addons/Export.ps1 pattern)
    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
    $proxyUrl = "http://$($windowsHostIpAddress):8181"
    $previousHttpProxy = $env:http_proxy
    $previousHttpsProxy = $env:https_proxy

    try {
        $env:http_proxy = $proxyUrl
        $env:https_proxy = $proxyUrl

        Write-Log "Trying to pull all platform layers for image '$imageFullName'" -Console
        $pullOutput = &$nerdctlExe -n 'k8s.io' pull $imageFullName --all-platforms 2>&1 | Out-String
        $pullExitCode = $LASTEXITCODE

        if ($pullExitCode -ne 0) {
            Write-Log "Not able to pull all platform layers for image '$imageFullName' (exit code: $pullExitCode)" -Console
            Write-Log "Exporting image '$imageFullName' only for current platform" -Console
            $exportSuccess = Invoke-Ctr -Arguments '-n', 'k8s.io', 'images', 'export', $finalExportPath, $imageFullName -CtrExePath $resolvedCtrExe
        }
        else {
            Write-Log "Exporting image '$imageFullName' for all platforms" -Console
            $exportSuccess = Invoke-Ctr -Arguments '-n', 'k8s.io', 'images', 'export', '--all-platforms', $finalExportPath, $imageFullName -CtrExePath $resolvedCtrExe
        }

        if ($exportSuccess) {
            Write-Log "Image ${imageFullName} exported successfully to ${finalExportPath}."
        }
        else {
            $errMsg = "Failed to export image '${imageFullName}'"
            Write-Log $errMsg -Error
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Severity Warning -Code 'image-export-failed' -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }
        }
    }
    finally {
        $env:http_proxy = $previousHttpProxy
        $env:https_proxy = $previousHttpsProxy
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
