# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Import image from filesystem

.DESCRIPTION
Import image from filesystem

.PARAMETER ImagePath
The image path of the image to be imported

.PARAMETER ImageDir
The directory of the images to be imported

.PARAMETER Windows
Image to import is a Windows image

.PARAMETER DockerArchive
Import a docker archive (default OCI archive)

.PARAMETER ShowLogs
Show all logs in terminal

.EXAMPLE
# Import windows container image from C:\temp\tmp.tar
PS> .\Import-Image.ps1 -ImagePath "C:\temp\tmp.tar" -Windows

.EXAMPLE
# Import all container image from directory C:\temp
PS> .\Import-Image.ps1 -ImageDir "C:\temp"
#>

Param (
    [parameter(Mandatory = $false)]
    [string] $ImagePath,
    [parameter(Mandatory = $false)]
    [string] $ImageDir,
    [parameter(Mandatory = $false)]
    [string] $Nodes = '',
    [parameter(Mandatory = $false)]
    [switch] $Windows = $false,
    [parameter(Mandatory = $false)]
    [switch] $DockerArchive = $false,
    [parameter(Mandatory = $false)]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'Return a boolean result to the calling addon import script instead of exiting on failure')]
    [switch] $ReturnStatus
)
$imageCommonModule = "$PSScriptRoot/Image-Common.module.psm1"
Import-Module $imageCommonModule

if (-not (Initialize-ImageScriptContext -ShowLogs:$ShowLogs -EncodeStructuredOutput:$EncodeStructuredOutput -ReturnStatus:$ReturnStatus -MessageType $MessageType)) {
    if ($ReturnStatus) {
        return $false
    }
    return
}

$hasFailures = $false

$images = @()
if ($ImagePath -ne '') {
    $images += $ImagePath
    Write-Log "Importing image $ImagePath. This can take some time..."
}
elseif ($ImageDir -ne '') {
    $files = Get-Childitem -recurse $ImageDir | Where-Object { $_.Name -match '.*.tar' } | ForEach-Object { $_.Fullname }
    $images += $files
    Write-Log "Importing images from $ImageDir. This can take some time..."
}

$nodeList = Resolve-NodeList -Nodes $Nodes

if ($nodeList.Count -eq 0) {
    # Default routing: Windows local host or Linux control-plane
    if ($Windows) {
        foreach ($image in $images) {
            if (-not (Invoke-LocalWindowsImageImport -ImagePath $image)) {
                $hasFailures = $true
            }
        }
    }
    else {
        foreach ($image in $images) {
            $nodeInfo = @{ Kind = 'ControlPlane'; Name = 'control-plane' }
            if (-not (Invoke-LinuxNodeImageImport -ImagePath $image -NodeInfo $nodeInfo -DockerArchive:$DockerArchive)) {
                $hasFailures = $true
            }
        }
    }
}
else {
    # Node-specific routing
    foreach ($nodeName in $nodeList) {
        $nodeInfo = Resolve-ImageNode -NodeName $nodeName
        if ($null -eq $nodeInfo) {
            Write-Log "[Import] Node '$nodeName' could not be resolved, skipping" -Console
            $hasFailures = $true
            continue
        }

        # Check if node is Ready before processing
        if (-not (Test-NodeReady -NodeName $nodeName -Kind $nodeInfo.Kind)) {
            Write-Log "[Import] Node '$nodeName' is not in Ready state - start the node with 'k2s start --node $nodeName' first" -Console
            $hasFailures = $true
            continue
        }

        Write-Log "[Import] Targeting node '$nodeName' (kind=$($nodeInfo.Kind), os=$($nodeInfo.OS))" -Console

        foreach ($image in $images) {
            Write-Log "[Import] Importing '$image' on '$nodeName'"

            switch ($nodeInfo.Kind) {
                'ControlPlane' {
                    if (-not (Invoke-LinuxNodeImageImport -ImagePath $image -NodeInfo $nodeInfo -DockerArchive:$DockerArchive)) {
                        $hasFailures = $true
                    }
                }
                'LinuxWorker' {
                    if (-not (Invoke-LinuxNodeImageImport -ImagePath $image -NodeInfo $nodeInfo -DockerArchive:$DockerArchive)) {
                        $hasFailures = $true
                    }
                }
                'LocalWindows' {
                    if (-not (Invoke-LocalWindowsImageImport -ImagePath $image)) {
                        $hasFailures = $true
                    }
                }
                'WindowsWorker' {
                    Write-Log "[Import] Importing Windows image on VM worker '$nodeName'" -Console
                    if (-not (Invoke-WindowsWorkerImageImport -ImagePath $image -NodeName $nodeName)) {
                        $hasFailures = $true
                    }
                }
                default {
                    Write-Log "[Import] Unknown node kind '$($nodeInfo.Kind)' for '$nodeName', skipping" -Console
                    $hasFailures = $true
                }
            }
        }
    }
}

if ($hasFailures) {
    $importError = New-Error -Code 'image-import-failed' -Message 'One or more container image imports failed - check the log for details'
    if ($ReturnStatus) {
        return $false
    }
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $importError }
    }
    else {
        Write-Log $importError.Message -Error
        exit 1
    }
}
elseif ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}

if ($ReturnStatus) {
    return $true
}
