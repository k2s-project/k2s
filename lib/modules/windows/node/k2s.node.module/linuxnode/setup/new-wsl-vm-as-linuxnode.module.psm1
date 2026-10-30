# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$commonDistroModule = "$PSScriptRoot\..\distros\common-setup.module.psm1"
Import-Module $infraModule, $commonDistroModule

$debianDistroModule = "$PSScriptRoot\..\distros\debian\debian.module.psm1"
Import-SpecificDistroSettingsModule -ModulePath $debianDistroModule

$controlPlaneOnWslRootfsFileName = 'Kubemaster-Base.rootfs.tar.gz'

function Invoke-WslCommand {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$IgnoreErrors
    )

    $executable = Get-Command -Name 'wsl.exe' -CommandType Application -ErrorAction Stop
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        # Native stderr warnings must not escape to the install wrapper as ErrorRecords.
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        $output = @(& $executable.Source @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $global:LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }

    foreach ($line in $output) {
        Write-Log "[WSL] $line" -Console
    }
    if ($null -eq $exitCode) {
        throw "[WSL] wsl.exe did not report an exit code: $($Arguments -join ' ')`n$($output -join "`n")"
    }
    if ($exitCode -ne 0) {
        $message = "[WSL] wsl.exe $($Arguments -join ' ') failed with exit code $exitCode"
        if (-not $IgnoreErrors) {
            throw "$message`n$($output -join "`n")"
        }
        Write-Log "$message; continuing best-effort cleanup." -Console
    }

    return $output
}

function New-WslLinuxVmAsControlPlaneNode {
    param (
        [string]$Hostname,
        [string]$IpAddress,
        [string]$GatewayIpAddress,
        [string]$DnsServers,
        [string]$VmName,
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize,
        [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [Boolean] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Forces the installation online')]
        [Boolean] $ForceOnlineInstallation = $false
    )

    $kubebinPath = Get-KubeBinPath
    $vhdxPath = "$kubebinPath\Kubemaster-Base.vhdx"
    $rootfsPath = Get-ControlPlaneOnWslRootfsFilePath

    $isRootfsFileAlreadyAvailable = (Test-Path $rootfsPath)
    if ($ForceOnlineInstallation -and $isRootfsFileAlreadyAvailable) {
        Remove-Item -Path $rootfsPath -Force
    }

    if (!(Test-Path -Path $rootfsPath)) {
        $controlPlaneNodeCreationParams = @{
                Hostname=$Hostname
                IpAddress=$IpAddress
                GatewayIpAddress=$GatewayIpAddress
                DnsServers=$DnsServers
                VmImageOutputPath=$vhdxPath
                Proxy=$Proxy
                VMDiskSize = $VMDiskSize
                VMMemoryStartupBytes = $VMMemoryStartupBytes
                VMProcessorCount = $VMProcessorCount
                DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
                ForceOnlineInstallation = $ForceOnlineInstallation
            }
        New-VmImageForControlPlaneNode @controlPlaneNodeCreationParams

        $wslRootfsForControlPlaneNodeCreationParams = @{
                VmImageInputPath=$vhdxPath
                RootfsFileOutputPath=$rootfsPath
                Proxy=$Proxy
                VMDiskSize = $VMDiskSize
                VMMemoryStartupBytes = $VMMemoryStartupBytes
                VMProcessorCount = $VMProcessorCount
            }
        New-WslRootfsForControlPlaneNode @wslRootfsForControlPlaneNodeCreationParams

        if (!(Test-Path -Path $rootfsPath)) {
            throw "The file '$rootfsPath' is not available"
        }
    }

    Write-Log 'Remove existing KubeMaster distro if existing'
    Invoke-WslCommand -Arguments @('--unregister', $VmName) -IgnoreErrors | Out-Null
    Write-Log 'Import KubeMaster distro'
    Invoke-WslCommand -Arguments @('--import', $VmName, "$env:SystemDrive\wsl", $rootfsPath) | Out-Null
    Write-Log 'Set KubeMaster as default distro'
    Invoke-WslCommand -Arguments @('-s', $VmName) | Out-Null

    # The rootfs has been pre-configured during creation with:
    # - Fixed fstab (no PARTUUID entries)
    # - Masked boot-efi.mount
    # - Systemd cgroups v1 compatibility settings

    Write-Log 'Starting WSL distro...'
    $null = Invoke-WslCommand -Arguments @('--exec', '/bin/true')

    Write-Log 'Waiting for WSL distro to initialize...'
    $maxRetries = 20
    $retryDelaySeconds = 3
    $systemdReady = $false
    for ($i = 1; $i -le $maxRetries; $i++) {
        Start-Sleep -Seconds $retryDelaySeconds
        try {
            $result = Invoke-WslCommand -Arguments @('--exec', '/bin/bash', '-c', 'systemctl is-system-running 2>/dev/null || echo "unknown"; exit 0')
            $resultStr = ($result | Out-String).Trim()
            if ($resultStr -match 'running|degraded') {
                Write-Log "WSL systemd is ready (status: $resultStr)"
                $systemdReady = $true
                break
            }
            Write-Log "Waiting for WSL systemd to be ready (attempt $i/$maxRetries, status: $resultStr)..."
        }
        catch {
            Write-Log "Waiting for WSL systemd to be ready (attempt $i/$maxRetries, exception: $($_.Exception.Message))..."
        }
    }
    if (-not $systemdReady) {
        Write-Log 'Warning: WSL systemd may not be fully ready, attempting to start sshd directly...'
        $null = Invoke-WslCommand -Arguments @('--exec', '/bin/bash', '-c', 'systemctl start ssh 2>/dev/null || /usr/sbin/sshd 2>/dev/null; exit 0')
    }

    Invoke-WslCommand -Arguments @('--shutdown') | Out-Null

}

function Get-ControlPlaneOnWslRootfsFilePath {
    $kubebinPath = Get-KubeBinPath
    return "$kubebinPath\$controlPlaneOnWslRootfsFileName"
}

function Get-ControlPlaneOnWslRootfsFileName {
    return $controlPlaneOnWslRootfsFileName
}


Export-ModuleMember -Function New-WslLinuxVmAsControlPlaneNode, Get-ControlPlaneOnWslRootfsFilePath, Get-ControlPlaneOnWslRootfsFileName
