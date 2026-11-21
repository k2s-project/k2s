# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Remove a registry

.DESCRIPTION
Remove a registry

.PARAMETER RegistryName
The name of the registry to be removed

.PARAMETER Nodes
Comma-separated node names to target. If omitted, removes global registry configuration.

.EXAMPLE
# Add registry
PS> .\Remove-Registry.ps1 -RegistryName "ghcr.io"
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Name of the registry')]
    [string] $RegistryName,
    [parameter(Mandatory = $false, HelpMessage = 'Comma-separated node names to target')]
    [string] $Nodes = '',
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$imageCommonModule = "$PSScriptRoot/../Image-Common.module.psm1"
Import-Module $clusterModule, $infraModule, $nodeModule, $imageCommonModule

function Send-RegistryError {
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

function Remove-RegistryOnLinuxTarget {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$NodeInfo,
        [Parameter(Mandatory = $true)]
        [string]$Registry
    )

    $fileName = $Registry -replace ':', ''
    $removeRegistryCmd = "sudo rm -rf /etc/containers/registries.conf.d/$fileName.conf"
    $logoutBuildahCmd = "sudo buildah logout --authfile /root/.config/containers/auth.json '$Registry'"

    if ($NodeInfo.Kind -eq 'ControlPlane') {
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $removeRegistryCmd).Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $logoutBuildahCmd -NoLog -IgnoreErrors).Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl daemon-reload').Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl restart crio').Output | Write-Log
        return
    }

    if ($NodeInfo.Kind -eq 'LinuxWorker') {
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute $removeRegistryCmd -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog -IgnoreErrors).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute $logoutBuildahCmd -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog -IgnoreErrors).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl daemon-reload' -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl restart crio' -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog).Output | Write-Log
    }
}

function Remove-RegistryOnWindowsTarget {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$NodeInfo,
        [Parameter(Mandatory = $true)]
        [string]$Registry
    )

    $folderName = $Registry -replace ':', ''

    if ($NodeInfo.Kind -eq 'LocalWindows') {
        Disconnect-Nerdctl -registry $Registry

        $registryPath = "$(Get-SystemDriveLetter):\etc\containerd\certs.d\$folderName"
        Remove-Item -Force $registryPath -Recurse -Confirm:$False -ErrorAction SilentlyContinue

        Write-Log 'Restarting Windows container runtime' -Console
        Stop-NssmService('kubeproxy')
        Stop-NssmService('kubelet')
        Restart-NssmService('containerd')
        Start-NssmService('kubelet')
        Start-NssmService('kubeproxy')
        return
    }

    if ($NodeInfo.Kind -eq 'WindowsWorker') {
        $session = $null
        try {
            $session = Open-RemoteSession -VmName $NodeInfo.Name -VmPwd (Get-DefaultTempPwd) -NoLog

            Invoke-Command -Session $session -ArgumentList $Registry, $folderName -ScriptBlock {
                param($registryName, $registryFolderName)

                $targetFolder = "$($env:SystemDrive)\etc\containerd\certs.d\$registryFolderName"
                Remove-Item -Force $targetFolder -Recurse -Confirm:$false -ErrorAction SilentlyContinue

                $nerdctlCmd = Get-Command nerdctl.exe -ErrorAction SilentlyContinue
                $nerdctlExe = if ($nerdctlCmd) { $nerdctlCmd.Path } else { 'nerdctl.exe' }
                & $nerdctlExe -n='k8s.io' logout $registryName 2>$null | Out-Null

                Restart-Service -Name 'containerd' -ErrorAction Stop
            } | Write-Log
        }
        finally {
            if ($null -ne $session) {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            }
        }
    }
}

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

$nodeList = Resolve-NodeList -Nodes $Nodes

if ($nodeList.Count -eq 0) {
    $registries = $(Get-RegistriesFromSetupJson)

    if ($registries) {
        $registryExists = $registries | Where-Object { $_ -eq $RegistryName }
        if ($registryExists.Count -eq 0) {
            Send-RegistryError -Code 'registry-not-configured' -Message "Registry '$RegistryName' is not configured."
            return
        }
    }
    else {
        Send-RegistryError -Code 'registry-not-configured' -Message "Registry '$RegistryName' is not configured."
        return
    }

    Write-Log "Removing registry '$RegistryName'" -Console

    $authJson = (Invoke-CmdOnControlPlaneViaSSHKey 'sudo cat /root/.config/containers/auth.json' -NoLog).Output | Out-String
    Remove-RegistryAuthToContainerdConfigToml -RegistryName $RegistryName -authJson $authJson

    Disconnect-Nerdctl -registry $RegistryName
    Disconnect-Buildah -registry $RegistryName

    Remove-Registry -Name $RegistryName
    Remove-RegistryFromSetupJson -Name $RegistryName
}
else {
    $targetNodeInfos = @()
    foreach ($nodeName in $nodeList) {
        $nodeInfo = Resolve-ImageNode -NodeName $nodeName
        if ($null -eq $nodeInfo) {
            Write-Log "[Registry] Node '$nodeName' could not be resolved, skipping" -Console
            continue
        }
        # Check if node is Ready before adding to target list
        if (-not (Test-NodeReady -NodeName $nodeName -Kind $nodeInfo.Kind)) {
            Write-Log "[Registry] Node '$nodeName' is not in Ready state - start the node with 'k2s start --node $nodeName' first" -Console
            continue
        }
        $targetNodeInfos += $nodeInfo
    }

    if ($targetNodeInfos.Count -eq 0) {
        Send-RegistryError -Code 'nodes-not-found' -Message 'None of the selected nodes could be resolved or are not Ready.'
        return
    }

    foreach ($nodeInfo in $targetNodeInfos) {
        Write-Log "[Registry] Removing registry '$RegistryName' on '$($nodeInfo.Name)' (kind=$($nodeInfo.Kind), os=$($nodeInfo.OS))" -Console

        if ($nodeInfo.OS -eq 'linux') {
            Remove-RegistryOnLinuxTarget -NodeInfo $nodeInfo -Registry $RegistryName
        }
        elseif ($nodeInfo.OS -eq 'windows') {
            Remove-RegistryOnWindowsTarget -NodeInfo $nodeInfo -Registry $RegistryName
        }
    }
}

Write-Log "Registry '$RegistryName' removed successfully." -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
