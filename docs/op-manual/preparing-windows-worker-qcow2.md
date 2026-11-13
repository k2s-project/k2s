<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Preparing a Windows Worker QCOW2

The native Linux K2s host creates a new SSH key for every managed Windows
worker. During temporary password-bootstrap operation, K2s authenticates once
as `remote`, installs that generated public key, then continues with key-only
SSH authentication. No config-drive CD-ROM is attached to the worker.

## Prepare the Hyper-V VM

Create and fully update a Windows 11 Hyper-V VM. Open an elevated PowerShell
session inside the guest and run the following script once:

```powershell
$ErrorActionPreference = 'Stop'

$password = ConvertTo-SecureString -String 'admin' -AsPlainText -Force
if (-not (Get-LocalUser -Name remote -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name remote -Password $password -PasswordNeverExpires | Out-Null
}
Set-LocalUser -Name remote -Password $password
if (-not (Get-LocalGroupMember -Group 'Administrators' | Where-Object Name -Match '(^|\\)remote$')) {
    Add-LocalGroupMember -Group 'Administrators' -Member remote
}

# Required by the Windows Kubernetes worker: HNS and Host Compute Service.
$features = @('Containers', 'Microsoft-Hyper-V-All', 'VirtualMachinePlatform')
Enable-WindowsOptionalFeature -Online -FeatureName $features -All -NoRestart | Out-Null

$openSshCapability = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
if ($openSshCapability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    $openSshCapability = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
}
if ($openSshCapability.State -ne 'Installed') {
    throw "OpenSSH Server capability is not installed. Current state: $($openSshCapability.State)"
}

if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
    $installSshd = Join-Path $env:WINDIR 'System32\OpenSSH\install-sshd.ps1'
    $sshdExe = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
    if (Test-Path $installSshd) {
        & $installSshd
    }
    elseif (Test-Path $sshdExe) {
        & (Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe') -A
        New-Service -Name sshd -BinaryPathName "`"$sshdExe`"" -DisplayName 'OpenSSH SSH Server' -StartupType Automatic | Out-Null
    }
    else {
        throw "OpenSSH Server capability is marked Installed but sshd.exe is missing: $sshdExe. Remove and reinstall the capability before continuing."
    }
}
if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
    throw 'OpenSSH Server did not register the sshd service.'
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
New-NetFirewallRule -DisplayName 'K2s Windows worker SSH' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -ErrorAction SilentlyContinue | Out-Null

# Keep the worker stable. Apply Windows updates only during planned image maintenance.
$windowsUpdatePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $windowsUpdatePolicy -Force | Out-Null
New-ItemProperty -Path $windowsUpdatePolicy -Name NoAutoUpdate -PropertyType DWord -Value 1 -Force | Out-Null
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Set-Service -Name wuauserv -StartupType Disabled

```

Restart the source VM once after enabling the Windows features, then rerun the
verification commands below before converting its VHDX.

Shut down the VM. Preserve its partition style: K2s automatically boots an MBR
image with BIOS and a GPT image with UEFI. Do not generalize the image after
configuring OpenSSH, because its service and the `remote` account must remain in
the base image.

## Convert to QCOW2

K2s does not bundle a QCOW2 conversion utility. Install the QEMU `qemu-img`
utility on the Hyper-V host, shut down the source VM, and locate its VHDX with
`Get-VMHardDiskDrive`. Convert that VHDX from an elevated PowerShell session:

```powershell
$vhdx = (Get-VMHardDiskDrive -VMName '<Hyper-V VM name>').Path
qemu-img.exe convert -p -f vhdx -O qcow2 -o compat=1.1 $vhdx 'E:\Images\WindowsWorker-Base.qcow2'
qemu-img.exe check 'E:\Images\WindowsWorker-Base.qcow2'
```

Use the resulting image with `--windows-qcow2-path`. Before publishing it,
verify the image source VM has the required components:

```powershell
Get-Service sshd
Get-LocalUser remote
Get-LocalGroupMember -Group 'Administrators' | Where-Object Name -Match '(^|\\)remote$'
Get-Service hns, vmcompute
```

## Temporary Password Bootstrap

For the current bootstrap workflow, K2s uses the temporary `remote` password
`admin`. An alternative password can be supplied only through the process
environment; do not add it to an install configuration file or command-line
flag:

```console
sudo env K2S_WINDOWS_WORKER_PASSWORD=admin ./k2s install --windows-qcow2-path /path/to/WindowsWorker-Base.qcow2
```

K2s uses this password once to install its generated public key for `remote`;
all subsequent worker actions use the generated key. Remove this password
bootstrap after the worker onboarding path has been finalized.

After key authentication succeeds, K2s copies its required runtime files to
`C:\k2s` before initializing the Windows worker: `VERSION`, `cfg`, `lib`,
`smallsetup`, `bin`, and `LocalHooks` when present. The QCOW2 therefore does
not need a preinstalled K2s directory.

Because `remote` is a local administrator, Windows OpenSSH applies its
`Match Group administrators` rule. K2s installs the generated key in
`C:\ProgramData\ssh\administrators_authorized_keys` with the ACL required by
that rule; it does not use `C:\Users\remote\.ssh\authorized_keys`.