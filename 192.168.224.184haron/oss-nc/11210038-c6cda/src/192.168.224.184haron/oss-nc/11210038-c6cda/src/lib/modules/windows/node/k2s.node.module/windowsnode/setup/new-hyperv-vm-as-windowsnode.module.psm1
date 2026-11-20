# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule =   "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\cluster\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $clusterModule

function New-WindowsVmForWorkerNode {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Windows hostname')]
        [string] $Hostname = $(throw 'Argument missing: Hostname'),
        [string]$VmName = $(throw 'Argument missing: VmName'),
        [parameter(Mandatory = $false, HelpMessage = 'Windows Image to use')]
        [string] $Image = $(throw 'Argument missing: Image'),
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Windows VM')]
        [long] $VMStartUpMemory = $(throw 'Argument missing: VMStartUpMemory'),
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [long] $VMDiskSize = $(throw 'Argument missing: VMDiskSize'),
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors of Windows VM')]
        [long] $VMProcessorCount = $(throw 'Argument missing: VMProcessorCount'),
        [parameter(HelpMessage = 'DNS Addresses')]
        [string] $DnsAddresses = $(throw 'Argument missing: DnsAddresses'),
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [switch] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
        [switch] $ForceOnlineInstallation = $false
    )
    $provisionedFileName = "Windows-Kubeworker-Base.vhdx"
    $outputPath = "$(Get-KubeBinPath)\$provisionedFileName"

    $isWindowsKubeworkerBaseImageAlreadyAvailable = (Test-Path $outputPath)
    $isOnlineInstallation = (!$isWindowsKubeworkerBaseImageAlreadyAvailable -or $ForceOnlineInstallation)

    if ($isOnlineInstallation -and $isWindowsKubeworkerBaseImageAlreadyAvailable) {
        Remove-Item -Path $outputPath -Force
    }
    
    $WSL = Get-ConfigWslFlag
    $switchname = ''
    if ($WSL) {
        $switchname = Get-WslSwitchName
    }
    else {
        $switchname = Get-ControlPlaneNodeDefaultSwitchName
    }
   
    $baseImageCreationParams = @{
        Hostname = $Hostname
        VmName = $VmName
        Image = $Image
        WinVMStartUpMemory = $VMStartUpMemory
        VMDiskSize = $VMDiskSize
        WinVMProcessorCount = $VMProcessorCount
        DnsAddresses = $DnsAddresses
        SwitchName = $switchname
        Proxy = $Proxy
        Generation = 2
        Edition = 'Windows 10 Pro'
        Locale = 'en-US'
        OutputPath = $outputPath
    }
    New-ProvisionedWindowsNodeBaseImage @baseImageCreationParams
   

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

    $vmCreationParams = @{
        VmName = $VmName
        VhdxPath = $vhdxPath
        SwitchName = $switchname
        VMStartUpMemory = $VMStartUpMemory
        VMProcessorCount = $VMProcessorCount
        Generation = 2
    }

    New-VmFromImage @vmCreationParams
}

function New-VmFromImage {
    Param(
        [string]$VmName = $(throw "Argument missing: VmName"),
        [parameter(Mandatory = $false, HelpMessage = 'Windows Image to use')]
        [string] $VhdxPath,
        [parameter(Mandatory = $false, HelpMessage = 'Windows Image to use')]
        [string] $SwitchName,
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Windows VM')]
        [long] $VMStartUpMemory = 4GB,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors of Windows VM')]
        [long] $VMProcessorCount = 4,
        [parameter(Mandatory = $false, HelpMessage = 'Generation of the VM, can be 1 or 2')]
        [int16] $Generation = $(throw "Argument missing: Generation")
    )
    $virtualMachine = New-VM -Name $VmName -Generation $Generation -MemoryStartupBytes $VMStartUpMemory -VHDPath $VhdxPath -SwitchName $SwitchName

    $virtualMachine | Set-VMProcessor -Count $VMProcessorCount
    $virtualMachine | Set-VMMemory -DynamicMemoryEnabled:$false

    $virtualMachine | Get-VMIntegrationService | Where-Object { $_ -is [Microsoft.HyperV.PowerShell.GuestServiceInterfaceComponent] } | Enable-VMIntegrationService -Passthru

    $command = Get-Command Set-VM
    if ($command.Parameters.AutomaticCheckpointsEnabled) {
        # We need to disable automatic checkpoints
        $virtualMachine | Set-VM -AutomaticCheckpointsEnabled $false
    }

    #Start VM and wait for heartbeat
    Write-Log 'Starting VM and waiting for heartbeat...'
    Start-VirtualMachineAndWaitForHeartbeat -Name $VmName
}

Export-ModuleMember -Function New-WindowsVmForWorkerNode

