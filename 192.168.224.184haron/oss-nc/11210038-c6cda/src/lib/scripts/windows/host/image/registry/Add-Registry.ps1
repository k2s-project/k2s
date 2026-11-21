# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Add access to a registry

.DESCRIPTION
Add access to a registry

.PARAMETER RegistryName
The name of the registry to be added

.PARAMETER Username
The username for the registry

.PARAMETER Password
The password for the registry

.PARAMETER ShowLogs
Show all logs in terminal

.EXAMPLE
# Add registry
PS> .\Add-Registry.ps1 -RegistryName "ghcr.io"

.EXAMPLE
# Add registry with username and password
PS> .\Add-Registry.ps1 -RegistryName "ghcr.io" -Username "user" -Password "passwd"
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Name of the registry')]
    [string] $RegistryName,
    [parameter(Mandatory = $false, HelpMessage = 'Comma-separated node names to target')]
    [string] $Nodes = '',
    [parameter(Mandatory = $false, HelpMessage = 'Single node name to target')]
    [string] $Node = '',
    [parameter(Mandatory = $false, HelpMessage = 'Username')]
    [string] $Username,
    [parameter(Mandatory = $false, HelpMessage = 'Password')]
    [string] $Password,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'Skips verifying HTTPS certs')]
    [switch] $SkipVerify = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Plain http')]
    [switch] $PlainHttp = $false
)

$imageCommonModule = "$PSScriptRoot/../Image-Common.module.psm1"
Import-Module $imageCommonModule

function ConvertTo-LinuxSingleQuoteEscaped {
    param([string]$Value)
    if ($null -eq $Value) {
        return ''
    }

    return $Value -replace "'", "'`"'`"'"
}

function Set-RegistryOnLinuxTarget {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$NodeInfo,
        [Parameter(Mandatory = $true)]
        [string]$Registry,
        [Parameter(Mandatory = $false)]
        [bool]$Insecure = $false,
        [Parameter(Mandatory = $false)]
        [string]$User = '',
        [Parameter(Mandatory = $false)]
        [string]$Pwd = ''
    )

    $fileName = $Registry -replace ':', ''
    $insecureValue = $Insecure.ToString().ToLower()
    $registryConfigContent = "[[registry]]`nlocation=`"$Registry`"`ninsecure=$insecureValue`n"
    $registryConfigBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($registryConfigContent))
    $registryConfigCmd = "echo '$registryConfigBase64' | base64 -d | sudo tee /etc/containers/registries.conf.d/$fileName.conf > /dev/null"

    if ($NodeInfo.Kind -eq 'ControlPlane') {
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo mkdir -p /etc/containers/registries.conf.d').Output | Write-Log
        $writeConfigResult = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $registryConfigCmd -IgnoreErrors)
        $writeConfigResult.Output | Write-Log
        if (-not $writeConfigResult.Success) {
            throw "Failed to write registry config for '$Registry' on Linux control-plane '$($NodeInfo.Name)'"
        }

        if ($User -or $Pwd) {
            $escapedUser = ConvertTo-LinuxSingleQuoteEscaped -Value $User
            $escapedPwd = ConvertTo-LinuxSingleQuoteEscaped -Value $Pwd
            $escapedRegistry = ConvertTo-LinuxSingleQuoteEscaped -Value $Registry
            $proxyCmd = Get-LinuxTransparentProxyPrefix -LogPrefix 'Registry' -NodeName $NodeInfo.Name -Reference $Registry
            $loginSuccess = (Invoke-CmdOnControlPlaneViaSSHKey "sudo ${proxyCmd}buildah login --authfile /root/.config/containers/auth.json -u '$escapedUser' -p '$escapedPwd' '$escapedRegistry' > /dev/null 2>&1" -NoLog -IgnoreErrors).Success
            if (-not $loginSuccess) {
                throw "Login to registry '$Registry' failed on Linux control-plane '$($NodeInfo.Name)'"
            }
        }
        else {
            Write-Log "[Registry] No credentials provided for '$Registry' on Linux control-plane '$($NodeInfo.Name)'; skipping login" -Console
        }

        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl daemon-reload').Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl restart crio').Output | Write-Log
        return
    }

    if ($NodeInfo.Kind -eq 'LinuxWorker') {
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo mkdir -p /etc/containers/registries.conf.d' -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog).Output | Write-Log
        $writeConfigResult = (Invoke-CmdOnVmViaSSHKey -CmdToExecute $registryConfigCmd -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog -IgnoreErrors)
        $writeConfigResult.Output | Write-Log
        if (-not $writeConfigResult.Success) {
            throw "Failed to write registry config for '$Registry' on Linux worker '$($NodeInfo.Name)'"
        }

        if ($User -or $Pwd) {
            $escapedUser = ConvertTo-LinuxSingleQuoteEscaped -Value $User
            $escapedPwd = ConvertTo-LinuxSingleQuoteEscaped -Value $Pwd
            $escapedRegistry = ConvertTo-LinuxSingleQuoteEscaped -Value $Registry

            (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo mkdir -p /root/.config/containers' -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog).Output | Write-Log

            $proxyCmd = Get-LinuxTransparentProxyPrefix -LogPrefix 'Registry' -NodeName $NodeInfo.Name -Reference $Registry

            $loginResult = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ${proxyCmd}buildah login --authfile /root/.config/containers/auth.json -u '$escapedUser' -p '$escapedPwd' '$escapedRegistry' 2>&1" -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog -IgnoreErrors)
            $loginResult.Output | Write-Log

            if (-not $loginResult.Success) {
                throw "Login to registry '$Registry' failed on Linux worker '$($NodeInfo.Name)'"
            }
        }
        else {
            Write-Log "[Registry] No credentials provided for '$Registry' on Linux worker '$($NodeInfo.Name)'; skipping login" -Console
        }

        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl daemon-reload' -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl restart crio' -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog).Output | Write-Log
    }
}

function Set-RegistryOnWindowsTarget {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$NodeInfo,
        [Parameter(Mandatory = $true)]
        [string]$Registry,
        [Parameter(Mandatory = $true)]
        [bool]$UseHttps,
        [Parameter(Mandatory = $false)]
        [bool]$SkipVerifyFlag = $false,
        [Parameter(Mandatory = $false)]
        [string]$User = '',
        [Parameter(Mandatory = $false)]
        [string]$Pwd = ''
    )

    $protocol = if ($UseHttps) { 'https' } else { 'http' }
    $skipVerifyValue = $SkipVerifyFlag.ToString().ToLower()
    $plainHttpValue = $(!$UseHttps).ToString().ToLower()
    $folderName = $Registry -replace ':', ''

    if ($NodeInfo.Kind -eq 'LocalWindows') {
        $targetFolder = "$(Get-SystemDriveLetter):\etc\containerd\certs.d\$folderName"
        New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null

        $content = "`n[host.`"${protocol}://$Registry`"]`n  capabilities = [`"pull`", `"resolve`", `"push`"]`n  skip_verify = $skipVerifyValue`n  plain_http = $plainHttpValue"
        $content | Set-Content -Path "$targetFolder\hosts.toml"

        if ($User -or $Pwd) {
            Connect-Nerdctl -username $User -password $Pwd -registry $Registry

            $authJson = (Invoke-CmdOnControlPlaneViaSSHKey 'sudo cat /root/.config/containers/auth.json' -NoLog).Output | Out-String
            Add-RegistryAuthToContainerdConfigToml -RegistryName $Registry -authJson $authJson
        }
        else {
            Write-Log "[Registry] No credentials provided for '$Registry' on local Windows host; skipping login" -Console
        }

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

            $hostsTomlContent = "`n[host.`"${protocol}://${Registry}`"]`n  capabilities = [`"pull`", `"resolve`", `"push`"]`n  skip_verify = ${skipVerifyValue}`n  plain_http = ${plainHttpValue}"
            $remoteResult = Invoke-Command -Session $session -ArgumentList $Registry, $hostsTomlContent, $User, $Pwd, $folderName -ScriptBlock {
                param($registryName, $hostsToml, $username, $password, $registryFolderName)

                $targetFolder = "$($env:SystemDrive)\etc\containerd\certs.d\$registryFolderName"
                New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null
                $hostsToml | Set-Content -Path "$targetFolder\hosts.toml"

                $nerdctlCmd = Get-Command nerdctl.exe -ErrorAction SilentlyContinue
                $nerdctlExe = if ($nerdctlCmd) { $nerdctlCmd.Path } else { 'nerdctl.exe' }

                if ($username -or $password) {
                    & $nerdctlExe -n='k8s.io' --insecure-registry login -u $username -p $password $registryName 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        throw "nerdctl login failed on Windows worker"
                    }
                }

                Restart-Service -Name 'containerd' -ErrorAction Stop
            }

            if ($null -ne $remoteResult) {
                $remoteResult | Write-Log
            }
        }
        finally {
            if ($null -ne $session) {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            }
        }
    }
}

if (-not (Initialize-ImageScriptContext -ShowLogs:$ShowLogs -EncodeStructuredOutput:$EncodeStructuredOutput -MessageType $MessageType)) {
    return
}

$nodeList = Resolve-NodeList -Nodes $Nodes -Node $Node
$isDefaultScope = ($nodeList.Count -eq 0)

$registries = @(Get-RegistriesFromSetupJson)
if ($isDefaultScope -and $registries -and ($registries | Where-Object { $_ -eq $RegistryName })) {
    $errMsg = "Registry '$RegistryName' is already configured."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'registry-already-configured' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log "Adding registry '$RegistryName'" -Console

if ($Username -and $Password) {
    $username = $Username
    $password = $Password
}
else {
    Write-Log 'Please enter credentials for registry access:' -Console
    $username = Read-Host 'Enter username'
    $passwordSecured = Read-Host 'Enter password' -AsSecureString
    $cred = New-Object System.Management.Automation.PSCredential ($username, $passwordSecured)
    $password = $cred.GetNetworkCredential().Password
}

Write-Log 'Trying to login to container registry' -Console

if ($isDefaultScope) {
    Set-Registry -Name $RegistryName -Https:$(!$PlainHttp) -SkipVerify:$SkipVerify

    if ($username -or $password) {
        Connect-Buildah -username $username -password $password -registry $RegistryName
        if (!$?) {
            Remove-Registry -Name $RegistryName
            $errMsg = 'Login to private registry not possible, please check credentials.'
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code 'registry-login-impossible' -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
                return
            }
            Write-Log $errMsg -Error
            exit 1
        }
    }
    else {
        Write-Log "[Registry] No credentials provided for '$RegistryName'; skipping login/auth configuration" -Console
    }

    Write-Log 'Restarting Linux container runtime' -Console
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl daemon-reload').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl restart crio').Output | Write-Log

    Start-Sleep 2

    if ($username -or $password) {
        Connect-Nerdctl -username $username -password $password -registry $RegistryName
        $authJson = (Invoke-CmdOnControlPlaneViaSSHKey 'sudo cat /root/.config/containers/auth.json' -NoLog).Output | Out-String
        Add-RegistryAuthToContainerdConfigToml -RegistryName $RegistryName -authJson $authJson
    }

    Write-Log 'Restarting Windows container runtime' -Console
    Stop-NssmService('kubeproxy')
    Stop-NssmService('kubelet')
    Restart-NssmService('containerd')
    Start-NssmService('kubelet')
    Start-NssmService('kubeproxy')

    Add-RegistryToSetupJson -Name $RegistryName
    Write-Log "Registry '$RegistryName' added successfully." -Console
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
        $errMsg = 'None of the selected nodes could be resolved or are not Ready.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'nodes-not-found' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    foreach ($nodeInfo in $targetNodeInfos) {
        Write-Log "[Registry] Applying registry '$RegistryName' on '$($nodeInfo.Name)' (kind=$($nodeInfo.Kind), os=$($nodeInfo.OS))" -Console
        if ($nodeInfo.OS -eq 'linux') {
            Set-RegistryOnLinuxTarget -NodeInfo $nodeInfo -Registry $RegistryName -Insecure:$SkipVerify -User $username -Pwd $password
        }
        elseif ($nodeInfo.OS -eq 'windows') {
            Set-RegistryOnWindowsTarget -NodeInfo $nodeInfo -Registry $RegistryName -UseHttps:(!$PlainHttp) -SkipVerifyFlag:$SkipVerify -User $username -Pwd $password
        }
    }

    Write-Log "Registry '$RegistryName' added successfully on selected node(s): $($nodeList -join ', ')." -Console
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
