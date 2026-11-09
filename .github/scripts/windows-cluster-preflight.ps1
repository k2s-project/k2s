# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run the runner under an elevated local administrator account.'
}
if ($env:SystemDrive -ne 'C:' -or -not [Environment]::Is64BitProcess) {
    throw 'This workflow requires 64-bit Windows PowerShell on a C: system drive.'
}
if ((Get-ExecutionPolicy) -notin @('RemoteSigned', 'Unrestricted', 'Bypass')) {
    throw 'Configure RemoteSigned (or less restrictive) execution policy before starting the runner.'
}
$hostInfo = Get-CimInstance Win32_ComputerSystem
$osInfo = Get-CimInstance Win32_OperatingSystem
$isClient = $osInfo.ProductType -eq 1
if (($isClient -and [int]$osInfo.BuildNumber -lt 22000) -or
    (-not $isClient -and [int]$osInfo.BuildNumber -lt 20348)) {
    throw 'Use Windows 11 with Hyper-V support, or Windows Server 2022 or newer.'
}
if ($hostInfo.NumberOfLogicalProcessors -lt 8 -or $hostInfo.TotalPhysicalMemory -lt 16GB -or
    ($osInfo.FreePhysicalMemory * 1KB) -lt 10GB) {
    throw 'Provide at least 8 logical CPUs, 16 GiB RAM and 10 GiB free RAM (32 GiB RAM recommended).'
}
if ((Get-PSDrive C).Free -lt 100GB) {
    throw 'Provide at least 100 GiB free on C: for source, downloads, VHDX files and container images.'
}
$features = @('Microsoft-Hyper-V', 'Microsoft-Hyper-V-Management-PowerShell',
              'Containers', 'VirtualMachinePlatform')
if ($isClient) {
    $features += 'Microsoft-Hyper-V-All', 'Microsoft-Hyper-V-Tools-All',
        'Microsoft-Hyper-V-Hypervisor', 'Microsoft-Hyper-V-Management-Clients',
        'Microsoft-Hyper-V-Services'
}
foreach ($feature in $features) {
    if ((Get-WindowsOptionalFeature -Online -FeatureName $feature).State -ne 'Enabled') {
        throw "Enable $feature and reboot BEFORE dispatching this workflow."
    }
}
foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
                   'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
    if (Test-Path $key) {
        throw 'A Windows servicing reboot is pending. Reboot before dispatching.'
    }
}
foreach ($service in @('vmms', 'vmcompute', 'hns')) {
    if ((Get-Service $service).Status -ne 'Running') {
        throw "Required service $service is not running."
    }
}
$docker = Get-Service 'com.docker.service' -ErrorAction SilentlyContinue
if (($docker -and $docker.Status -eq 'Running') -or
    (Get-Process 'Docker Desktop', 'dockerd' -ErrorAction SilentlyContinue)) {
    throw 'Stop Docker Desktop and Docker Engine before dispatching.'
}
if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64') -or
    (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64').Installed -ne 1) {
    throw 'Install the Microsoft Visual C++ v14 x64 redistributable before dispatching.'
}
$curlVersion = & curl.exe --version
if ($LASTEXITCODE -ne 0 -or $curlVersion[0] -notmatch '^curl (\d+\.\d+\.\d+)' -or
    [version]$Matches[1] -lt [version]'7.71.0') {
    throw 'curl.exe >= 7.71.0 is required.'
}
# OpenSSH prints its version to stderr; PS 5.1 must not treat that as a terminating error.
try {
    $ErrorActionPreference = 'Continue'
    $sshVersion = & ssh.exe -V 2>&1
    $sshExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = 'Stop'
}
if ($sshExitCode -ne 0 -or "$sshVersion" -notmatch 'OpenSSH(?:_for_Windows)?_(\d+)' -or
    [int]$Matches[1] -lt 8) {
    throw 'OpenSSH >= 8 is required.'
}
foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'ALL_PROXY')) {
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name, 'Machine'))) {
        throw "Remove machine-level $name from the base image; configure the runner process proxy instead."
    }
}
. .\.github\scripts\windows-cluster-proxy.ps1
Initialize-K2sCiProxy -ConfigPath '.\cfg\config.json'
if ((Get-VM) -or (Get-VMSwitch | Where-Object SwitchType -eq 'External') -or
    (Test-Path 'C:\ProgramData\K2s\setup.json') -or (Test-Path 'C:\k2s')) {
    throw 'Runner is not clean. Use a fresh disposable VM without existing VMs, external switches or K2s state.'
}

# A running hypervisor or CPU flag alone does not prove nested VM startup works.
$probe = $null
try {
    $probe = New-VM -Name "k2s-ci-probe-$env:GITHUB_RUN_ID" -Generation 1 -NoVHD -MemoryStartupBytes 512MB
    $probe | Start-VM
    if ((Get-VM -Id $probe.Id).State -ne 'Running') {
        throw 'Hyper-V VM startup failed. Enable nested virtualization on the outer host.'
    }
}
finally {
    if ($null -ne $probe) {
        if ((Get-VM -Id $probe.Id).State -ne 'Off') {
            $probe | Stop-VM -TurnOff -Force
        }
        $probe | Remove-VM -Force
    }
}

New-Item -ItemType Directory -Path 'C:\k2s' | Out-Null
# Preserve HEAD for build version metadata; checkout did not persist its token.
& robocopy.exe "$env:GITHUB_WORKSPACE" 'C:\k2s' /E /R:2 /W:2 /NFL /NDL /NJH /NJS
if ($LASTEXITCODE -ge 8) { throw "Source staging failed: robocopy exit $LASTEXITCODE" }
exit 0
