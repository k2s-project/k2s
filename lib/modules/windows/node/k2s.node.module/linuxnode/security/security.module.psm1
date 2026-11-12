# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$vmModule = "$PSScriptRoot\..\vm\vm.module.psm1"
Import-Module $infraModule, $vmModule

$sshKeyControlPlane = Get-SSHKeyControlPlane
$sshConfigDir = Get-SshConfigDir


function New-SshKey {
    param (
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    # remove previous VM key from known hosts
    $file = $sshConfigDir + '\known_hosts'
    if (Test-Path $file) {
        Write-Log 'Remove previous VM key from known_hosts file'

        Remove-SshKnownHostEntry -HostName $IpAddress
    }


    # Create SSH keypair, if not yet available
    $sshDir = Split-Path -parent $sshKeyControlPlane
    if (!(Test-Path $sshDir)) {
        mkdir $sshDir | Out-Null
    }
    if (!(Test-Path $sshKeyControlPlane)) {
        Write-Log "creating SSH key $sshKeyControlPlane"
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            echo y | ssh-keygen.exe -t rsa -b 2048 -f $sshKeyControlPlane -N ''
        }
        else {
            echo y | ssh-keygen.exe -t rsa -b 2048 -f $sshKeyControlPlane -N '""'  # strange powershell syntax for empty passphrase...
        }
    }
    if (!(Test-Path $sshKeyControlPlane)) {
        throw "unable to generate SSH keys ($sshKeyControlPlane)"
    }
    Set-SshPrivateKeyPermissions -Path $sshKeyControlPlane
    return "$sshKeyControlPlane.pub"
}

function Remove-SshKey {
    param (
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    Write-Log 'Remove control plane ssh keys from host'
    Remove-SshKnownHostEntry -HostName $IpAddress
    Remove-Item -Path ($sshConfigDir + '\k2s') -Force -Recurse -ErrorAction SilentlyContinue

    # remove old folder where the ssh key was located
    Remove-Item -Path ($sshConfigDir + '\kubemaster') -Force -Recurse -ErrorAction SilentlyContinue
}

function Copy-LocalPublicSshKeyToRemoteComputer {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )

    $user = "$UserName@$IpAddress"
    $userPwd = $UserPwd

    $localSourcePath = "$sshKeyControlPlane.pub"
    $publicKeyFileName = Split-Path -Path $localSourcePath -Leaf
    $targetPath = "/tmp/$publicKeyFileName"
    $remoteTargetPath = "$targetPath"
    Copy-ToRemoteComputerViaUserAndPwd -Source $localSourcePath -Target $remoteTargetPath -IpAddress $IpAddress
    (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo mkdir -p ~/.ssh" -RemoteUser "$user" -RemoteUserPwd "$userPwd").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo cat $targetPath | sudo tee ~/.ssh/authorized_keys" -RemoteUser "$user" -RemoteUserPwd "$userPwd").Output | Write-Log
}

function Remove-ControlPlaneAccessViaUserAndPwd {
    $ipControlPlane = Get-ConfiguredIPControlPlane
    Remove-VmAccessViaUserAndPwd -IpAddress $ipControlPlane
}

function Remove-VmAccessViaUserAndPwd {
    param (
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    # remove password for remote user and disable password login
    (Invoke-CmdOnVmViaSSHKey 'sudo passwd -d remote' -IpAddress $IpAddress).Output | Write-Log

    (Invoke-CmdOnVmViaSSHKey "sudo sed -i 's/.*NAutoVTs.*/NAutoVTs=0/' /etc/systemd/logind.conf" -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey "sudo sed -i 's/.*ReserveVT.*/ReserveVT=0/' /etc/systemd/logind.conf" -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey 'sudo systemctl disable getty@tty1.service 2>&1' -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey 'sudo systemctl stop "getty@tty*.service"' -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey 'sudo systemctl restart systemd-logind.service' -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey 'echo Include /etc/ssh/sshd_config.d/*.conf | sudo tee -a /etc/ssh/sshd_config' -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey 'sudo touch /etc/ssh/sshd_config.d/disable_pwd_login.conf' -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey 'echo ChallengeResponseAuthentication no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf' -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey 'echo PasswordAuthentication no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf' -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey 'echo UsePAM no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf' -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey 'echo PermitRootLogin no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf' -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey 'sudo systemctl reload ssh' -IpAddress $IpAddress).Output | Write-Log
}

Export-ModuleMember New-SshKey, 
Remove-SshKey, 
Copy-LocalPublicSshKeyToRemoteComputer, 
Remove-ControlPlaneAccessViaUserAndPwd,
Remove-VmAccessViaUserAndPwd
