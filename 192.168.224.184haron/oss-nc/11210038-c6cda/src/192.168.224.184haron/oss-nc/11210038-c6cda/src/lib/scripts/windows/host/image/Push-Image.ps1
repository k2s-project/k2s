# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Push container images in K2s

.DESCRIPTION
Push container images in K2s

.PARAMETER ImageName
The image name of the image to be pushed

.EXAMPLE
# Push container image with name "image:v1" in K2s
PS> .\Push-Image.ps1 -ImageName "image:v1"
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Id of the image to be pushed.')]
    [string] $Id,
    [parameter(Mandatory = $false, HelpMessage = 'Name of the image to be pushed.')]
    [string] $ImageName,
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

function Send-PushError {
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

function Normalize-ImageNameForLocalRegistryAlias {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Image
    )

    # Support local alias k2s.local/<repo>:<tag> by normalizing to canonical host.
    if ($Image -match '^k2s\.local(:\d+)?/(.+)$') {
        $aliasPort = $Matches[1]
        $imagePath = $Matches[2]
        $canonicalHost = if ([string]::IsNullOrWhiteSpace($aliasPort)) { 'k2s.registry.local' } else { "k2s.registry.local$aliasPort" }
        $normalizedImage = "$canonicalHost/$imagePath"
        Write-Log "[Push] Normalized local registry alias '$Image' to '$normalizedImage'" -Console
        return $normalizedImage
    }

    return $Image
}

function Get-PushFailureSummary {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Output = ''
    )

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return ''
    }

    $lines = @($Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0) {
        return ''
    }

    $preferred = @($lines | Where-Object { $_ -match '(?i)error:|failed|invalid|denied|unauthorized|x509|timeout' } | Select-Object -First 1)
    if ($preferred.Count -gt 0) {
        return $preferred[0]
    }

    return $lines[0]
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

function Get-LinuxPushCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Image
    )

    if ($Image -match '^k2s\.registry\.local(:\d+)?/') {
        return "sudo buildah push --tls-verify=false $Image 2>&1"
    }

    return "sudo buildah push $Image 2>&1"
}

function Get-LinuxPushFallbackDestination {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Image
    )

    if ($Image -notmatch '^k2s\.registry\.local(:\d+)?/(.+)$') {
        return ''
    }

    $imagePath = $Matches[2]
    $registryHostIp = Get-RegistryHostIp
    if ([string]::IsNullOrWhiteSpace($registryHostIp)) {
        return ''
    }

    return "docker://$registryHostIp`:30500/$imagePath"
}

function Ensure-LinuxRegistryHostResolution {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$NodeInfo,
        [Parameter(Mandatory = $true)]
        [string]$RegistryHost
    )

    $registryHostIp = Get-RegistryHostIp
    if ([string]::IsNullOrWhiteSpace($registryHostIp)) {
        return
    }

    $ensureCmd = "if ! getent hosts $RegistryHost >/dev/null 2>&1; then echo '$registryHostIp $RegistryHost' | sudo tee -a /etc/hosts >/dev/null; fi"

    if ($NodeInfo.Kind -eq 'ControlPlane') {
        (Invoke-CmdOnControlPlaneViaSSHKey $ensureCmd -IgnoreErrors -Timeout 30).Output | Out-Null
        return
    }

    if ($NodeInfo.Kind -eq 'LinuxWorker') {
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute $ensureCmd -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog -IgnoreErrors -Timeout 30).Output | Out-Null
    }
}

function Invoke-PushOnNode {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$NodeInfo,
        [Parameter(Mandatory = $true)]
        [string]$Image
    )

    if ($NodeInfo.OS -eq 'linux') {
        if ($NodeInfo.Kind -eq 'LinuxWorker' -and $Image -match '^k2s\.registry\.local(:\d+)?/') {
            Write-Log "[Push] Ensuring '$($NodeInfo.Name)' can resolve k2s.registry.local via control-plane IP" -Console
            Ensure-LinuxRegistryHostResolution -NodeInfo $NodeInfo -RegistryHost 'k2s.registry.local'
        }

        $linuxPushCmd = Get-LinuxPushCommand -Image $Image
        $proxyCmd = Get-LinuxTransparentProxyPrefix -LogPrefix 'Push' -NodeName $NodeInfo.Name -Reference $Image
        $pushCmdWithProxy = if ([string]::IsNullOrWhiteSpace($proxyCmd)) { $linuxPushCmd } else { $linuxPushCmd -replace '^sudo ', "sudo ${proxyCmd}" }

        if ($NodeInfo.Kind -eq 'ControlPlane') {
            $result = Invoke-CmdOnControlPlaneViaSSHKey $pushCmdWithProxy -Retries 5 -Timeout 600 -IgnoreErrors
            if (-not $result.Success) {
                $resultOutput = ($result.Output | Out-String)
                $fallbackDestination = Get-LinuxPushFallbackDestination -Image $Image
                if (-not [string]::IsNullOrWhiteSpace($fallbackDestination) -and $resultOutput -match 'lookup k2s\.registry\.local|Temporary failure in name resolution|invalid status code from registry 404|x509|connection refused|dial tcp .*:80: connect: connection refused') {
                    Write-Log "[Push] Retrying Linux push via control-plane NodePort destination '$fallbackDestination'" -Console
                    $fallbackCmd = "sudo buildah push --tls-verify=false $Image $fallbackDestination 2>&1"
                    $result = Invoke-CmdOnControlPlaneViaSSHKey $fallbackCmd -Retries 5 -Timeout 600 -IgnoreErrors
                }
            }

            return @{
                Success = [bool]$result.Success
                Output  = ($result.Output | Out-String)
            }
        }

        if ($NodeInfo.Kind -eq 'LinuxWorker') {
            $result = Invoke-CmdOnVmViaSSHKey -CmdToExecute $pushCmdWithProxy -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog -IgnoreErrors -Timeout 600
            if (-not $result.Success) {
                $resultOutput = ($result.Output | Out-String)
                $fallbackDestination = Get-LinuxPushFallbackDestination -Image $Image
                if (-not [string]::IsNullOrWhiteSpace($fallbackDestination) -and $resultOutput -match 'lookup k2s\.registry\.local|Temporary failure in name resolution|invalid status code from registry 404|x509|connection refused|dial tcp .*:80: connect: connection refused') {
                    Write-Log "[Push] Retrying Linux push from '$($NodeInfo.Name)' via control-plane NodePort destination '$fallbackDestination'" -Console
                    # The fallback destination is an internal cluster NodePort IP; do NOT route it through the corporate proxy.
                    $fallbackCmd = "sudo buildah push --tls-verify=false $Image $fallbackDestination 2>&1"
                    $result = Invoke-CmdOnVmViaSSHKey -CmdToExecute $fallbackCmd -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog -IgnoreErrors -Timeout 600
                }
            }

            return @{
                Success = [bool]$result.Success
                Output  = ($result.Output | Out-String)
            }
        }
    }

    if ($NodeInfo.OS -eq 'windows') {
        if ($NodeInfo.Kind -eq 'LocalWindows') {
            $kubeBinPath = Get-KubeBinPath
            $nerdctlExe = "$kubeBinPath\nerdctl.exe"
            $retries = 5
            $lastOutput = ''

            while ($retries -gt 0) {
                $retries--
                $currentOutput = (&$nerdctlExe -n="k8s.io" --insecure-registry image push $Image --allow-nondistributable-artifacts --quiet 2>&1) | Out-String
                $lastOutput = $currentOutput
                if ($LASTEXITCODE -eq 0) {
                    return @{
                        Success = $true
                        Output  = $currentOutput
                    }
                }
                Start-Sleep 1
            }

            return @{
                Success = $false
                Output  = $lastOutput
            }
        }

        if ($NodeInfo.Kind -eq 'WindowsWorker') {
            $session = $null
            try {
                $session = Open-RemoteSession -VmName $NodeInfo.Name -VmPwd (Get-DefaultTempPwd) -NoLog
                $remoteResult = Invoke-Command -Session $session -ArgumentList $Image -ScriptBlock {
                    param($imageName)

                    $nerdctlCmd = Get-Command nerdctl.exe -ErrorAction SilentlyContinue
                    $nerdctlExe = if ($nerdctlCmd) { $nerdctlCmd.Path } else { 'nerdctl.exe' }
                    $retries = 5
                    $lastErr = ''

                    while ($retries -gt 0) {
                        $retries--
                        $pushOutput = (& $nerdctlExe -n='k8s.io' --insecure-registry image push $imageName --allow-nondistributable-artifacts --quiet 2>&1) | Out-String
                        $lastErr = $pushOutput
                        if ($LASTEXITCODE -eq 0) {
                            return @{
                                Success = $true
                                Output  = $pushOutput
                            }
                        }
                        Start-Sleep 1
                    }

                    return @{
                        Success = $false
                        Output  = $lastErr
                    }
                }

                return @{
                    Success = [bool]$remoteResult.Success
                    Output  = [string]$remoteResult.Output
                }
            }
            finally {
                if ($null -ne $session) {
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                }
            }
        }
    }

    return @{
        Success = $false
        Output  = "Unsupported node kind '$($NodeInfo.Kind)' for OS '$($NodeInfo.OS)'"
    }
}

$selectionResult = Get-ImagesByNodeSelection -Nodes $Nodes -IncludeK8sImages $true -LogPrefix 'Push'
$targetNodeInfos = @($selectionResult.NodeInfos)
$linuxContainerImages = @($selectionResult.LinuxImages)
$windowsContainerImages = @($selectionResult.WindowsImages)

if (-not [string]::IsNullOrWhiteSpace($ImageName)) {
    $ImageName = Normalize-ImageNameForLocalRegistryAlias -Image $ImageName
}

$foundLinuxImages = @()
if ($Id -ne '') {
    $foundLinuxImages = @($linuxContainerImages | Where-Object { $_.ImageId -eq $Id })
}
else {
    if ($ImageName -eq '') {
        Write-Error 'Image Name or ImageId is not provided. Cannot push the image.'
    }
    else {
        $foundLinuxImages = @($linuxContainerImages | Where-Object {
                $retrievedName = $_.Repository + ':' + $_.Tag
                return ($retrievedName -eq $ImageName)
            })
    }
}

$foundWindowsImages = @()
if ($Id -ne '') {
    $foundWindowsImages = @($windowsContainerImages | Where-Object { $_.ImageId -eq $Id })
}
else {
    if ($ImageName -eq '') {
        Write-Error 'Image Name or ImageId is not provided. Cannot push the image.'
    }
    else {
        $foundWindowsImages = @($windowsContainerImages | Where-Object {
                $retrievedName = $_.Repository + ':' + $_.Tag
                return ($retrievedName -eq $ImageName)
            })
    }
}

if ($foundLinuxImages.Count -eq 0 -and $foundWindowsImages.Count -eq 0) {
    If ($Id -ne '') {
        Send-PushError -Code 'image-not-found' -Message "Image with Id ${Id} not found!"
        return
    }

    If ($ImageName -ne '') {
        Send-PushError -Code 'image-push-failed' -Message "Image '$ImageName' not found"
        return
    }
}

$pushLinuxImage = $false
$pushWindowsImage = $false
$linuxAndWindowsImageFound = $false

if ($foundLinuxImages.Count -gt 1 -or $foundWindowsImages.Count -gt 1) {
    Send-PushError -Code 'two-images-found' -Message "More than one image has the id: $Id. Please use --name to identify the image instead or delete the other image/s"
    return
}

if ($foundLinuxImages.Count -eq 1 -and $foundWindowsImages.Count -eq 1) {
    Write-Log 'Linux and Windows image found'
    $linuxAndWindowsImageFound = $true
    $answer = Read-Host 'WARNING: Linux and Windows image found. Which image should be pushed? (l/w) [Linux or Windows]'
    if ($answer -ne 'l' -and $answer -ne 'w') {
        $errMsg = 'Push image cancelled.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeUserCancellation) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    if ($answer -eq 'l') {
        $pushLinuxImage = $true
    }

    if ($answer -eq 'w') {
        $pushWindowsImage = $true
    }
}

if ((($foundLinuxImages.Count -eq 1) -and !$linuxAndWindowsImageFound) -or $pushLinuxImage) {
    $image = $foundLinuxImages[0]
    $imageTag = $image.Tag
    $imageName = $image.Repository
    $ImageName = "${imageName}:${imageTag}"
    $targetNode = Get-NodeInfoByName -NodeInfos $targetNodeInfos -NodeName $image.Node
    if ($null -eq $targetNode) {
        Send-PushError -Code 'nodes-not-found' -Message "Unable to resolve target node '$($image.Node)' for image '$ImageName'"
        return
    }

    Write-Log "Pushing Linux image $ImageName on node '$($targetNode.Name)'" -Console
    $pushResult = Invoke-PushOnNode -NodeInfo $targetNode -Image $ImageName
    if (-not $pushResult.Success) {
        $failureSummary = Get-PushFailureSummary -Output $pushResult.Output
        if (-not [string]::IsNullOrWhiteSpace($pushResult.Output)) {
            Write-Log "[Push] Linux push command output on '$($targetNode.Name)': $($pushResult.Output.Trim())" -Console
        }

        $errMsg = "Error pushing image '$ImageName' on node '$($targetNode.Name)'"
        if (-not [string]::IsNullOrWhiteSpace($failureSummary)) {
            $errMsg = "$errMsg. Reason: $failureSummary"
        }

        Send-PushError -Code 'image-push-failed' -Message $errMsg
        return
    }

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }

    exit 0
}

if ((($foundWindowsImages.Count -eq 1) -and !$linuxAndWindowsImageFound) -or $pushWindowsImage) {
    $image = $foundWindowsImages[0]
    $imageTag = $image.Tag
    $imageName = $image.Repository
    $ImageName = "${imageName}:${imageTag}"
    $targetNode = Get-NodeInfoByName -NodeInfos $targetNodeInfos -NodeName $image.Node
    if ($null -eq $targetNode) {
        Send-PushError -Code 'nodes-not-found' -Message "Unable to resolve target node '$($image.Node)' for image '$ImageName'"
        return
    }

    Write-Log "Pushing Windows image $ImageName on node '$($targetNode.Name)'" -Console
    $pushResult = Invoke-PushOnNode -NodeInfo $targetNode -Image $ImageName

    if (-not $pushResult.Success) {
        $failureSummary = Get-PushFailureSummary -Output $pushResult.Output
        if (-not [string]::IsNullOrWhiteSpace($pushResult.Output)) {
            Write-Log "[Push] Windows push command output on '$($targetNode.Name)': $($pushResult.Output.Trim())" -Console
        }

        $errMsg = "Error pushing image '$ImageName' on node '$($targetNode.Name)'"
        if (-not [string]::IsNullOrWhiteSpace($failureSummary)) {
            $errMsg = "$errMsg. Reason: $failureSummary"
        }

        Send-PushError -Code 'image-push-failed' -Message $errMsg
        return
    }

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }

    exit 0
}
