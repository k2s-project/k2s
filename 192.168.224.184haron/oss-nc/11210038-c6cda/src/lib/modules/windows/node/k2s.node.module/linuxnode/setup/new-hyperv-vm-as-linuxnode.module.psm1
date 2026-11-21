# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$commonDistroModule = "$PSScriptRoot\..\distros\common-setup.module.psm1"
Import-Module $infraModule, $commonDistroModule

$debianDistroModule = "$PSScriptRoot\..\distros\debian\debian.module.psm1"
Import-SpecificDistroSettingsModule -ModulePath $debianDistroModule

function Get-KubemasterBaseFilePath {
    $kubebinPath = Get-KubeBinPath
    return "$kubebinPath\Kubemaster-Base.vhdx"
}

function Get-KubeworkerBaseFilePath {
    $kubebinPath = Get-KubeBinPath
    return "$kubebinPath\Kubeworker-Base.vhdx"
}

function New-LinuxVmAsControlPlaneNode {
    param (
        [string]$Hostname,
        [string]$IpAddress,
        [string]$GatewayIpAddress,
        [string]$DnsServers,
        [string]$VmName,
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Minimum Memory for Dynamic Memory')]
        [long]$VMMemoryMinBytes = 0,
        [parameter(Mandatory = $false, HelpMessage = 'Maximum Memory for Dynamic Memory')]
        [long]$VMMemoryMaxBytes = 0,
        [parameter(Mandatory = $false, HelpMessage = 'Enable Dynamic Memory')]
        [switch]$EnableDynamicMemory = $false,
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
    $outputPath = Get-KubemasterBaseFilePath

    $isKubemasterBaseImageAlreadyAvailable = (Test-Path $outputPath)
    $isOnlineInstallation = (!$isKubemasterBaseImageAlreadyAvailable -or $ForceOnlineInstallation)

    if ($isOnlineInstallation -and $isKubemasterBaseImageAlreadyAvailable) {
        Remove-Item -Path $outputPath -Force
    }

    if (!(Test-Path -Path $outputPath)) {
        $controlPlaneNodeCreationParams = @{
            Hostname=$Hostname
            IpAddress=$IpAddress
            GatewayIpAddress=$GatewayIpAddress
            DnsServers=$DnsServers
            VmImageOutputPath=$outputPath
            Proxy=$Proxy
            VMDiskSize = $VMDiskSize
            VMMemoryStartupBytes = $VMMemoryStartupBytes
            VMProcessorCount = $VMProcessorCount
            EnableDynamicMemory = $EnableDynamicMemory
            ForceOnlineInstallation = $ForceOnlineInstallation
        }
        New-VmImageForControlPlaneNode @controlPlaneNodeCreationParams
    }

    $vmmsSettings = Get-CimInstance -namespace root\virtualization\v2 Msvm_VirtualSystemManagementServiceSettingData
    $vhdxPath = Join-Path $vmmsSettings.DefaultVirtualHardDiskPath "$VmName.vhdx"
    Write-Log "Remove '$vhdxPath' if existing"
    if (Test-Path $vhdxPath) {
        Remove-Item $vhdxPath -Force
    }
    Copy-Item -Path $outputPath -Destination $vhdxPath -Force

    if ($DeleteFilesForOfflineInstallation) {
        Remove-Item -Path $outputPath -Force
    }

    New-VmFromIso -VMName $VmName `
            -VhdxPath $vhdxPath `
            -VHDXSizeBytes $VMDiskSize `
            -MemoryStartupBytes $VMMemoryStartupBytes `
            -MemoryMinimumBytes $VMMemoryMinBytes `
            -MemoryMaximumBytes $VMMemoryMaxBytes `
            -EnableDynamicMemory:$EnableDynamicMemory `
            -ProcessorCount $VMProcessorCount `
            -UseGeneration1

}

function New-LinuxVmAsWorkerNode {
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
    
    $outputPath = Get-KubeworkerBaseFilePath

    $isKubeworkerBaseImageAlreadyAvailable = (Test-Path $outputPath)
    if ($isKubeworkerBaseImageAlreadyAvailable) {
        Remove-Item -Path $outputPath -Force
    }

    $workerNodeCreationParams = @{
        Hostname=$Hostname
        IpAddress=$IpAddress
        GatewayIpAddress=$GatewayIpAddress
        DnsServers=$DnsServers
        VmImageOutputPath=$outputPath
        Proxy=$Proxy
        VMDiskSize = $VMDiskSize
        VMMemoryStartupBytes = $VMMemoryStartupBytes
        VMProcessorCount = $VMProcessorCount
        ForceOnlineInstallation = $ForceOnlineInstallation
    }
    New-LinuxVmImageForWorkerNode @workerNodeCreationParams

    $vmmsSettings = Get-CimInstance -namespace root\virtualization\v2 Msvm_VirtualSystemManagementServiceSettingData
    $vhdxPath = Join-Path $vmmsSettings.DefaultVirtualHardDiskPath "$VmName.vhdx"
    Write-Log "Remove '$vhdxPath' if existing"
    if (Test-Path $vhdxPath) {
        Remove-Item $vhdxPath -Force
    }
    Copy-Item -Path $outputPath -Destination $vhdxPath -Force

    Remove-Item -Path $outputPath -Force

    New-VmFromIso -VMName $VmName `
            -VhdxPath $vhdxPath `
            -VHDXSizeBytes $VMDiskSize `
            -MemoryStartupBytes $VMMemoryStartupBytes `
            -ProcessorCount $VMProcessorCount `
            -UseGeneration1

    $switchName = Get-ControlPlaneNodeDefaultSwitchName
    Connect-VMNetworkAdapter -VmName $VmName -SwitchName $switchName -ErrorAction Stop
}

function New-VmFromIso {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        [Parameter(Mandatory = $true)]
        [string]$VhdxPath,
        [uint64]$VHDXSizeBytes,
        [int64]$MemoryStartupBytes = 1GB,
        [int64]$MemoryMinimumBytes = 0,
        [int64]$MemoryMaximumBytes = 0,
        [switch]$EnableDynamicMemory = $false,
        [int64]$ProcessorCount = 2,
        [switch]$UseGeneration1
    )

    if ($VHDXSizeBytes) {
        Resize-VHD -Path $VhdxPath -SizeBytes $VHDXSizeBytes
    }

    # Create VM
    $generation = 2
    if ($UseGeneration1) {
        $generation = 1
    }
    Write-Log "Creating VM: $VMName"
    Write-Log "             - Vhdx: $VhdxPath"
    Write-Log "             - MemoryStartupBytes: $MemoryStartupBytes"
    if ($EnableDynamicMemory) {
        Write-Log "             - Dynamic Memory: Enabled"
        $minMemory = if ($MemoryMinimumBytes -gt 0) { $MemoryMinimumBytes } else { $MemoryStartupBytes }
        $maxMemory = if ($MemoryMaximumBytes -gt 0) { $MemoryMaximumBytes } else { $MemoryStartupBytes }
        Write-Log "             - MemoryMinimumBytes: $minMemory"
        Write-Log "             - MemoryMaximumBytes: $maxMemory"
    }
    Write-Log "             - VM Generation: $generation"
    $vm = New-VM -Name $VMName -Generation $generation -MemoryStartupBytes $MemoryStartupBytes -VHDPath $VhdxPath
    $vm | Set-VMProcessor -Count $ProcessorCount

    <#
    Avoid using VM Service name as it is not culture neutral, use the ID instead.
    Name: Guest Service Interface; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\6C09BB55-D683-4DA0-8931-C9BF705F6480
    Name: Heartbeat; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47
    Name: Key-Value Pair Exchange; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\2A34B1C2-FD73-4043-8A5B-DD2159BC743F
    Name: Shutdown; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\9F8233AC-BE49-4C79-8EE3-E7E1985B2077
    Name: Time Synchronization; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\2497F4DE-E9FA-4204-80E4-4B75C46419C0
    Name: VSS; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\5CED1297-4598-4915-A5FC-AD21BB4D02A4
    #>

    $GuestServiceInterfaceID = '6C09BB55-D683-4DA0-8931-C9BF705F6480'
    Get-VMIntegrationService -VM $vm | Where-Object { $_.Id -match $GuestServiceInterfaceID } | Enable-VMIntegrationService

    # Configure dynamic memory if enabled
    if ($EnableDynamicMemory) {
        Write-Log 'Configuring Hyper-V Dynamic Memory'

        $minMemory = if ($MemoryMinimumBytes -gt 0) {
            $MemoryMinimumBytes
        } else {
            $calculatedMin = [Math]::Floor($MemoryStartupBytes * 0.3)
            [Math]::Max(2GB, $calculatedMin)
        }

        $maxMemory = if ($MemoryMaximumBytes -gt 0) {
            $MemoryMaximumBytes
        } else {
            $hostTotalRAM = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
            $calculatedMax = [Math]::Floor($hostTotalRAM * 0.5)
            $maxMemory = [Math]::Max(8GB, [Math]::Min($calculatedMax, 32GB))

            Write-Log "Auto-calculated maximum memory (50% of host RAM): $([Math]::Round($maxMemory/1GB, 2))GB"
            $maxMemory
        }

        if ($MemoryMinimumBytes -eq 0) {
            Write-Log "Auto-calculated minimum memory (30% of startup): $([Math]::Round($minMemory/1GB, 2))GB"
        }

        # Validate memory range
        if ($minMemory -gt $MemoryStartupBytes) {
            Write-Log "Warning: Minimum memory ($minMemory) is greater than startup memory ($MemoryStartupBytes). Using startup as minimum."
            $minMemory = $MemoryStartupBytes
        }
        if ($maxMemory -lt $MemoryStartupBytes) {
            Write-Log "Warning: Maximum memory ($maxMemory) is less than startup memory ($MemoryStartupBytes). Using startup as maximum."
            $maxMemory = $MemoryStartupBytes
        }

        $vm | Set-VMMemory -DynamicMemoryEnabled $true -MinimumBytes $minMemory -MaximumBytes $maxMemory -StartupBytes $MemoryStartupBytes
        Write-Log "Dynamic Memory configured: Startup=$MemoryStartupBytes, Min=$minMemory, Max=$maxMemory"
    } else {
        $vm | Set-VMMemory -DynamicMemoryEnabled $false -StartupBytes $MemoryStartupBytes
        Write-Log "Static Memory configured: $MemoryStartupBytes"
    }

    # Sets Secure Boot Template.
    #   Set-VMFirmware -SecureBootTemplate 'MicrosoftUEFICertificateAuthority' doesn't work anymore (!?).
    if ( $generation -eq 2 ) {
        $vm | Set-VMFirmware -SecureBootTemplateId ([guid]'272e7447-90a4-4563-a4b9-8e4ab00526ce')
    }

    # Enable nested virtualization (if processor supports it)
    $virt = Get-CimInstance Win32_Processor | Where-Object { ($_.Name -like 'Intel*') }
    if ( $virt ) {
        Write-Log 'Enable nested virtualization'
        $vm | Set-VMProcessor -ExposeVirtualizationExtensions $true
    }

    # Disable Automatic Checkpoints. Check if command is available since it doesn't exist in Server 2016.
    $command = Get-Command Set-VM
    if ($command.Parameters.AutomaticCheckpointsEnabled) {
        $vm | Set-VM -AutomaticCheckpointsEnabled $false
    }

    Write-Log "Starting VM $VMName"
    Start-VirtualMachineAndWaitForHeartbeat -Name $VMName

    Write-Log 'VM started ok'
}

Export-ModuleMember -Function New-LinuxVmAsControlPlaneNode, New-LinuxVmAsWorkerNode, Get-KubemasterBaseFilePath
