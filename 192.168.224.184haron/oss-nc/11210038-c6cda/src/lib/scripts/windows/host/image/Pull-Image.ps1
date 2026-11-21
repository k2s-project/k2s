# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Pull container images in K2s

.DESCRIPTION
Pull container images in K2s

.PARAMETER ImageName
The image name of the image to be pulled

.PARAMETER Windows
Indicates that it is a windows image

.EXAMPLE
# Pull linux container image with name "image:v1" in K2s
PS> .\Pull-Image.ps1 -ImageName "image:v1"

.EXAMPLE
# Pull windows container image with name "image:v1" in K2s
PS> .\Pull-Image.ps1 -ImageName "image:v1" -Windows
#>

Param (
    [parameter(Mandatory = $true, HelpMessage = 'Name of the image to be pulled.')]
    [string] $ImageName,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, the image will be pulled for windows 10 node.')]
    [switch] $Windows,
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

function Send-PullError {
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

function Get-LinuxPullFallbackImage {
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

    return "$registryHostIp`:30500/$imagePath"
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

function Invoke-PullOnLinuxControlPlane {
    param([Parameter(Mandatory = $true)][string]$Image)

    $kubeSwitchIp = Get-ConfiguredKubeSwitchIP
    $WSL = Get-ConfigWslFlag
    $tunnelProc = $null
    $sshErrFile = $null
    $proxyAddr = "${kubeSwitchIp}:8181"

    if ($WSL) {
        Write-Log '[image-pull] Releasing port 8181 in VM if held by a stale sshd tunnel'
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute `
            'pid=$(sudo ss -tlnp | grep '':8181'' | grep -o ''pid=[0-9][0-9]*'' | head -1 | cut -d= -f2); if [ -n "$pid" ] && [ "$(cat /proc/$pid/comm 2>/dev/null)" = "sshd" ]; then sudo kill "$pid" 2>/dev/null; fi; true' `
            -IgnoreErrors).Output | Write-Log
        Start-Sleep -Seconds 1

        Write-Log '[image-pull] Establishing SSH reverse proxy tunnel' -Console
        $sshKey = Get-SSHKeyControlPlane
        $ipControlPlane = Get-ConfiguredIPControlPlane
        $tunnelArgs = '-N', '-o', 'StrictHostKeyChecking=no', '-o', 'ExitOnForwardFailure=yes', `
            '-o', 'ServerAliveInterval=10', '-i', $sshKey, `
            '-R', "8181:${kubeSwitchIp}:8181", "remote@${ipControlPlane}"
        $sshErrFile = [System.IO.Path]::GetTempFileName()
        $tunnelProc = Start-Process -FilePath 'ssh.exe' -ArgumentList $tunnelArgs -PassThru -WindowStyle Hidden `
            -RedirectStandardError $sshErrFile
        Start-Sleep -Seconds 2
        if ($tunnelProc.HasExited) {
            $sshErrText = if (Test-Path $sshErrFile) { (Get-Content $sshErrFile -Raw).Trim() } else { '' }
            Write-Log "[image-pull] WARNING: SSH reverse tunnel exited (code $($tunnelProc.ExitCode)) - pull may fail" -Console
            if ($sshErrText) { Write-Log "[image-pull] SSH error: $sshErrText" -Console }
            $tunnelProc = $null
        }
        else {
            Write-Log "[image-pull] SSH reverse tunnel started (PID $($tunnelProc.Id))"
            $proxyAddr = '127.0.0.1:8181'
        }
    }

    $success = $false
    try {
        $success = (Invoke-CmdOnControlPlaneViaSSHKey "sudo HTTPS_PROXY=http://${proxyAddr} HTTP_PROXY=http://${proxyAddr} buildah pull $Image 2>&1" -Retries 5 -Timeout 600).Success
    }
    finally {
        if ($null -ne $tunnelProc) {
            if (!$tunnelProc.HasExited) {
                Write-Log "[image-pull] Stopping SSH reverse proxy tunnel (PID $($tunnelProc.Id))"
                Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
            }
            $tunnelProc = $null
        }
        if ($null -ne $sshErrFile -and (Test-Path $sshErrFile)) {
            Remove-Item $sshErrFile -Force -ErrorAction SilentlyContinue
        }
    }

    return $success
}

function Invoke-PullOnNode {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$NodeInfo,
        [Parameter(Mandatory = $true)]
        [string]$Image
    )

    if ($NodeInfo.OS -eq 'linux') {
        Write-Log "Pulling Linux image $Image on '$($NodeInfo.Name)'" -Console

        if ($Image -match '^k2s\.registry\.local(:\d+)?/') {
            if ($NodeInfo.Kind -eq 'LinuxWorker') {
                Write-Log "[Pull] Ensuring '$($NodeInfo.Name)' can resolve k2s.registry.local via control-plane IP" -Console
                Ensure-LinuxRegistryHostResolution -NodeInfo $NodeInfo -RegistryHost 'k2s.registry.local'
            }

            $primaryCmd = "sudo buildah pull --tls-verify=false $Image 2>&1"
            if ($NodeInfo.Kind -eq 'ControlPlane') {
                $result = Invoke-CmdOnControlPlaneViaSSHKey $primaryCmd -IgnoreErrors -Timeout 600 -Retries 5
            }
            else {
                $result = Invoke-CmdOnVmViaSSHKey -CmdToExecute $primaryCmd -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog -IgnoreErrors -Timeout 600
            }

            if (-not $result.Success) {
                $resultOutput = ($result.Output | Out-String)
                Write-Log "[Pull] buildah pull failed on '$($NodeInfo.Name)': $resultOutput"
                $fallbackImage = Get-LinuxPullFallbackImage -Image $Image
                if (-not [string]::IsNullOrWhiteSpace($fallbackImage) -and $resultOutput -match 'lookup k2s\.registry\.local|Temporary failure in name resolution|invalid status code from registry 404|x509|connection refused|dial tcp .*:80: connect: connection refused') {
                    Write-Log "[Pull] Retrying Linux pull on '$($NodeInfo.Name)' via control-plane NodePort image '$fallbackImage'" -Console
                    $fallbackCmd = "sudo buildah pull --tls-verify=false $fallbackImage 2>&1"
                    if ($NodeInfo.Kind -eq 'ControlPlane') {
                        $result = Invoke-CmdOnControlPlaneViaSSHKey $fallbackCmd -IgnoreErrors -Timeout 600 -Retries 5
                    }
                    else {
                        $result = Invoke-CmdOnVmViaSSHKey -CmdToExecute $fallbackCmd -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog -IgnoreErrors -Timeout 600
                    }
                    if (-not $result.Success) {
                        $fallbackOutput = ($result.Output | Out-String)
                        Write-Log "[Pull] Fallback buildah pull also failed on '$($NodeInfo.Name)': $fallbackOutput"
                    }
                }
            }

            return [bool]$result.Success
        }

        if ($NodeInfo.Kind -eq 'ControlPlane') {
            return (Invoke-PullOnLinuxControlPlane -Image $Image)
        }

        if ($NodeInfo.Kind -eq 'LinuxWorker') {
            $proxyCmd = Get-LinuxTransparentProxyPrefix -LogPrefix 'Pull' -NodeName $NodeInfo.Name -Reference $Image
            return (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ${proxyCmd}buildah pull $Image 2>&1" -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog -IgnoreErrors).Success
        }
    }

    if ($NodeInfo.OS -eq 'windows') {
        Write-Log "Pulling Windows image $Image on '$($NodeInfo.Name)'" -Console
        if ($NodeInfo.Kind -eq 'LocalWindows') {
            $kubeBinPath = Get-KubeBinPath
            $retries = 5
            while ($retries -gt 0) {
                $retries--
                &$kubeBinPath\crictl --config $kubeBinPath\crictl.yaml pull $Image
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
                $remoteResult = Invoke-Command -Session $session -ArgumentList $Image -ScriptBlock {
                    param($imageName)

                    $crictlCmd = Get-Command crictl.exe -ErrorAction SilentlyContinue
                    $crictlExe = if ($crictlCmd) { $crictlCmd.Path } else { 'crictl.exe' }

                    $retries = 5
                    while ($retries -gt 0) {
                        $retries--
                        & $crictlExe pull $imageName 2>$null | Out-Null
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

$nodeList = Resolve-NodeList -Nodes $Nodes
$targetNodeInfos = @()

if ($nodeList.Count -eq 0) {
    if ($Windows) {
        $targetNodeInfos = @((Resolve-ImageNode -NodeName $env:ComputerName))
    }
    else {
        $setupFilePath = Get-SetupConfigFilePath
        $controlPlaneHostname = Get-ConfigValue -Path $setupFilePath -Key 'ControlPlaneNodeHostname'
        if ([string]::IsNullOrWhiteSpace($controlPlaneHostname)) {
            $controlPlaneHostname = 'kubemaster'
        }
        $targetNodeInfos = @((Resolve-ImageNode -NodeName $controlPlaneHostname))
    }
}
else {
    foreach ($nodeName in $nodeList) {
        $nodeInfo = Resolve-ImageNode -NodeName $nodeName
        if ($null -eq $nodeInfo) {
            Write-Log "[Pull] Node '$nodeName' could not be resolved, skipping" -Console
            continue
        }

        # Check if node is Ready before adding to target list
        if (-not (Test-NodeReady -NodeName $nodeName -Kind $nodeInfo.Kind)) {
            Write-Log "[Pull] Node '$nodeName' is not in Ready state - start the node with 'k2s start --node $nodeName' first" -Console
            continue
        }

        if ($Windows -and $nodeInfo.OS -ne 'windows') {
            Write-Log "[Pull] Node '$nodeName' is not a Windows node, skipping" -Console
            continue
        }

        if (-not $Windows -and $nodeInfo.OS -ne 'linux') {
            Write-Log "[Pull] Node '$nodeName' is not a Linux node, skipping" -Console
            continue
        }

        $targetNodeInfos += $nodeInfo
    }
}

$targetNodeInfos = @($targetNodeInfos | Where-Object { $null -ne $_ })
if ($targetNodeInfos.Count -eq 0) {
    if ($Windows) {
        Send-PullError -Code 'nodes-not-found' -Message 'No valid Windows target nodes resolved for image pull.'
    }
    else {
        Send-PullError -Code 'nodes-not-found' -Message 'No valid Linux target nodes resolved for image pull.'
    }
    return
}

foreach ($nodeInfo in $targetNodeInfos) {
    $success = Invoke-PullOnNode -NodeInfo $nodeInfo -Image $ImageName
    if (-not $success) {
        Send-PullError -Code 'image-pull-failed' -Message "Error pulling image '$ImageName' on node '$($nodeInfo.Name)'"
        return
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
