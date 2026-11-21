# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$baseImageModule = "$PSScriptRoot\base-image.module.psm1"
$vmModule = "$PSScriptRoot\..\vm\vm.module.psm1"
Import-Module $infraModule, $baseImageModule, $vmModule

$kubeBinPath = Get-KubeBinPath

$downloadsDirectory = "$kubeBinPath\downloads"
$provisioningTargetDirectory = "$kubeBinPath\provisioning"
$kubenodeBaseFileName = 'Kubenode-Base.vhdx'
$kubeNodeBaseImagePath = "$kubeBinPath\$kubenodeBaseFileName"

$KubemasterVmProvisioningVmName = 'KUBEMASTER_IN_PROVISIONING'
$RawBaseImageInProvisioningForKubemasterImageName = 'Debian-13-Base-In-Provisioning-For-Kubemaster.vhdx'
$VmProvisioningNatName = 'KubemasterVmProvisioningNat'
$VmProvisioningSwitchName = 'KubemasterVmProvisioningSwitch'

$KubeworkerVmProvisioningVmName = 'KUBEWORKER_IN_PROVISIONING'
$RawBaseImageInProvisioningForKubeworkerImageName = 'Debian-13-Base-In-Provisioning-For-Kubeworker.vhdx'
$KubeworkerVmProvisioningNatName = 'KubeworkerVmProvisioningNat'
$KubeworkerVmProvisioningSwitchName = 'KubeworkerVmProvisioningSwitch'

$KubenodeVmProvisioningVmName = 'KUBENODE_IN_PROVISIONING'
$RawBaseImageInProvisioningForKubenodeImageName = 'Debian-13-Base-In-Provisioning-For-Kubenode.vhdx'
$KubenodeVmProvisioningNatName = 'KubenodeVmProvisioningNat'
$KubenodeVmProvisioningSwitchName = 'KubenodeVmProvisioningSwitch'

$RootfsWslProvisioningVmName = 'ROOTFS_FOR_WSL_IN_CREATION'

class VmParameters {
    [string]$VmName
    [long]  $MemoryStartupBytes
    [long]  $ProcessorCount
    [uint64]$DiskSize
    [string]$IsoFileName
    [string]$InProvisioningVhdxFileName
    [string]$ProvisionedVhdxFileName
}

class GuestOsParameters {
    [string]$UserName
    [string]$UserPwd
    [string]$NetworkInterfaceName
    [string]$Hostname
}

class NetworkParameters {
    [string]$HostIpAddress
    [string]$GuestIpAddress
    [string]$NatName
    [string]$NatIpAddress
    [string]$SwitchName
    [string]$HostNetworkPrefixLength
    [string]$DnsIpAddresses
}

function New-KubenodeBaseImage {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize,
        [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
        [string]$Proxy = '',
        [string]$DnsIpAddresses = $(throw 'Argument missing: DnsIpAddresses'),
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [ValidateScript({ Assert-Pattern -Path $_ -Pattern '.*\.vhdx$' })]
        [parameter(Mandatory = $false, HelpMessage = 'The path to save the provisioned base image.')]
        [string] $OutputPath = $(throw 'Argument missing: OutputPath'),
        [parameter(Mandatory = $false, HelpMessage = 'Keep artifacts used on provisioning')]
        [bool] $KeepArtifactsUsedOnProvisioning = $false,
        [scriptblock]$Hook = $(throw "Argument missing: Hook")
    )

    Assert-Path -Path (Split-Path $OutputPath) -PathType 'Container' -ShallExist $true | Out-Null

    if (Test-Path $OutputPath) {
        Remove-Item -Path $OutputPath -Force
        Write-Log "Deleted already existing provisioned image '$OutputPath'"
    }
    else {
        Write-Log "Provisioned image '$OutputPath' does not exist. Nothing to delete."
    }

    [VmParameters]$vmParameters = [VmParameters]::new() 
    $vmParameters.DiskSize = $VMDiskSize
    $vmParameters.InProvisioningVhdxFileName = $RawBaseImageInProvisioningForKubenodeImageName
    $vmParameters.IsoFileName = 'cloud-init-kubenode-provisioning.iso'
    $vmParameters.MemoryStartupBytes = $VMMemoryStartupBytes
    $vmParameters.ProcessorCount = $VMProcessorCount
    $vmParameters.ProvisionedVhdxFileName = 'Debian-13-Base-Provisioned-For-Kubenode.vhdx'
    $vmParameters.VmName = $KubenodeVmProvisioningVmName

    [GuestOsParameters]$guestOsParameters = [GuestOsParameters]::new() 
    $guestOsParameters.Hostname = Get-HostnameForProvisioningKubeNode
    $guestOsParameters.NetworkInterfaceName = Get-NetworkInterfaceName
    $guestOsParameters.UserName = Get-DefaultUserNameKubeNode
    $guestOsParameters.UserPwd = Get-DefaultUserPwdKubeNode

    [NetworkParameters]$networkParameters = [NetworkParameters]::new() 
    $networkParameters.GuestIpAddress = Get-VmIpForProvisioningKubeNode
    $networkParameters.HostIpAddress = Get-HostIpForProvisioningKubeNode
    $networkParameters.HostNetworkPrefixLength = Get-NetworkPrefixLengthForProvisioningKubeNode
    $networkParameters.NatIpAddress = Get-NatIpForProvisioningKubeNode
    $networkParameters.NatName = $KubenodeVmProvisioningNatName
    $networkParameters.SwitchName = $KubenodeVmProvisioningSwitchName
    $networkParameters.DnsIpAddresses = $DnsIpAddresses

    $baseImageCreationParameters = @{
        VmParameters                      = $vmParameters
        GuestOsParameters                 = $guestOsParameters
        NetworkParameters                 = $networkParameters
        Proxy                             = $Proxy
        InstallationHook                  = $Hook
        AfterProvisioningFinishedHook     = { }
        OutputPath                        = $OutputPath
        KeepArtifactsUsedOnProvisioning   = $KeepArtifactsUsedOnProvisioning
    }

    New-ProvisionedBaseImage @baseImageCreationParameters
}

function New-KubemasterBaseImage {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize,
        [string]$Hostname,
        [string]$IpAddress,
        [string]$GatewayIpAddress,
        [string]$InterfaceName,
        [string]$DnsServers = '',
        [parameter(Mandatory = $false, HelpMessage = 'The path to take the kubenode base image.')]
        [string] $InputPath = $(throw "Argument missing: InputPath"),
        [parameter(Mandatory = $false, HelpMessage = 'The path to save the prepared base image.')]
        [string] $OutputPath = $(throw "Argument missing: OutputPath"),
        [scriptblock]$Hook = $(throw "Argument missing: Hook")
        )

        if (!(Test-Path -Path $InputPath)) {
            throw "The specified input path '$InputPath' does not exist"
        }
        if (Test-Path -Path $OutputPath) {
            Remove-Item -Path $OutputPath -Force
        }

        if (Test-Path -Path $provisioningTargetDirectory) {
            Remove-Item -Path $provisioningTargetDirectory -Recurse -Force
        }
        New-Item -Path $provisioningTargetDirectory -Type Directory 

        $kubemasterInPreparationName = "kubemaster-in-preparation.vhdx"

        $inPreparationVhdxPath = "$provisioningTargetDirectory\$kubemasterInPreparationName"
        $preparedVhdxPath = "$provisioningTargetDirectory\kubemaster-prepared.vhdx"

        $sourcePath = $InputPath

        Copy-Item -Path $sourcePath -Destination $inPreparationVhdxPath

        $vmName = $KubemasterVmProvisioningVmName
        $switchName = $KubenodeVmProvisioningSwitchName
        $natName = $KubenodeVmProvisioningNatName

        $vm = Get-VM | Where-Object Name -Like $vmName
        Write-Log "Ensure not existence of VM $vmName"
        if ($null -ne $vm) {
            Stop-VirtualMachine -VmName $vm -Wait
            $vm | Remove-VM -Force
        }

        $vmParams = @{
            "VmName"=$vmName
            "VhdxFilePath"=$inPreparationVhdxPath
            "IsoFilePath"=""
            "VMMemoryStartupBytes"=$VMMemoryStartupBytes
            "VMProcessorCount"=$VMProcessorCount
            "VMDiskSize"=$VMDiskSize
        }
        New-VirtualMachineForBaseImageProvisioning @vmParams

        $networkParams1 = @{
            "SwitchName"=$switchName
            "HostIpAddress"=Get-HostIpForProvisioningKubeNode
            "HostIpPrefixLength"=Get-NetworkPrefixLengthForProvisioningKubeNode
            "NatName"=$natName
            "NatIpAddress"=Get-NatIpForProvisioningKubeNode
        }
        New-NetworkForProvisioning @networkParams1

        Connect-VMNetworkAdapter -VmName $vmName -SwitchName $switchName -ErrorAction Stop

        Start-VirtualMachineAndWaitForHeartbeat -Name $vmName


        $remoteUser1 = "$(Get-DefaultUserNameKubeNode)@$(Get-VmIpForProvisioningKubeNode)"
        Wait-ForSshPossible -User $remoteUser1 -UserPwd $(Get-DefaultUserPwdKubeNode) -SshTestCommand 'which ls' -ExpectedSshTestCommandResult '/usr/bin/ls'

        # hostname
        $hostnameKubemaster = $Hostname
        (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo hostnamectl set-hostname $hostnameKubemaster" -RemoteUser $remoteUser1).Output | Write-Log
        (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo sed -i `"s/$(Get-HostnameForProvisioningKubeNode)/$hostnameKubemaster/g`" /etc/hosts" -RemoteUser $remoteUser1).Output | Write-Log

        # IP
        $interfaceConfigurationPath = '/etc/netplan/10-k2s.yaml'
        $configPath = "$PSScriptRoot\NetplanK2s.yaml"
        $netplanConfigurationTemplate = Get-Content $configPath
        $netplanConfiguration = $netplanConfigurationTemplate.Replace("__NETWORK_INTERFACE_NAME__",$InterfaceName).Replace("__NETWORK_ADDRESSES__","$IpAddress/24").Replace("__IP_GATEWAY__", $GatewayIpAddress).Replace("__DNS_IP_ADDRESSES__",$DnsServers)
        (Invoke-CmdOnControlPlaneViaUserAndPwd "echo '' | sudo tee $interfaceConfigurationPath" -RemoteUser $remoteUser1).Output | Write-Log
        foreach ($line in $netplanConfiguration) {
            (Invoke-CmdOnControlPlaneViaUserAndPwd "echo '$line' | sudo tee -a $interfaceConfigurationPath" -RemoteUser $remoteUser1).Output | Write-Log
        }
        (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo chmod 600 $interfaceConfigurationPath" -RemoteUser $remoteUser1).Output | Write-Log
        (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo rm -f /etc/netplan/50-cloud-init.yaml" -RemoteUser $remoteUser1).Output | Write-Log

        # ssh keys
        (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo rm -f /etc/ssh/ssh_host_*; sudo ssh-keygen -A; sudo systemctl restart ssh" -RemoteUser $remoteUser1).Output | Write-Log

        Stop-VirtualMachineForBaseImageProvisioning -Name $vmName
        Disconnect-VMNetworkAdapter -VmName $vmName
        Remove-NetworkForProvisioning -SwitchName $switchName -NatName $natName

        $networkParams2 = @{
            "SwitchName"=$VmProvisioningSwitchName
            "HostIpAddress"=$GatewayIpAddress
            "HostIpPrefixLength"="24"
            "NatName"=$VmProvisioningNatName
            "NatIpAddress"="172.19.1.0"
        }
        New-NetworkForProvisioning @networkParams2

        Write-Log "Attach the VM to a network switch"
        Connect-VMNetworkAdapter -VmName $vmName -SwitchName $networkParams2.SwitchName -ErrorAction Stop

        Start-VirtualMachineAndWaitForHeartbeat -Name $vmName

        $remoteUser2 = "$(Get-DefaultUserNameKubeNode)@$IpAddress"

        Wait-ForSshPossible -User $remoteUser2 -UserPwd $(Get-DefaultUserPwdKubeNode) -SshTestCommand 'which ls' -ExpectedSshTestCommandResult '/usr/bin/ls'
        
        &$Hook

        Stop-VirtualMachineForBaseImageProvisioning -Name $vmName
        Rename-Item $inPreparationVhdxPath $preparedVhdxPath
        Copy-Item $preparedVhdxPath $OutputPath -Force

        Remove-VM -Name $vmName -Force

        Remove-NetworkForProvisioning -SwitchName $VmProvisioningSwitchName -NatName $VmProvisioningNatName

        Remove-Item -Path $provisioningTargetDirectory -Recurse -Force
}

function New-KubeworkerBaseImage {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize,
        [string]$Hostname,
        [string]$IpAddress,
        [string]$GatewayIpAddress,
        [string]$InterfaceName,
        [string]$DnsServers = '',
        [parameter(Mandatory = $false, HelpMessage = 'The path to take the kubenode base image.')]
        [string] $InputPath = $(throw "Argument missing: InputPath"),
        [parameter(Mandatory = $false, HelpMessage = 'The path to save the prepared base image.')]
        [string] $OutputPath = $(throw "Argument missing: OutputPath"),
        [scriptblock]$Hook = $(throw "Argument missing: Hook")
        )

    if (!(Test-Path -Path $InputPath)) {
        throw "The specified input path '$InputPath' does not exist"
    }
    if (Test-Path -Path $OutputPath) {
        Remove-Item -Path $OutputPath -Force
    }

    if (Test-Path -Path $provisioningTargetDirectory) {
        Remove-Item -Path $provisioningTargetDirectory -Recurse -Force
    }
    New-Item -Path $provisioningTargetDirectory -Type Directory | Write-Log

    $kubeworkerInPreparationName = "$Hostname-in-preparation.vhdx"

    $inPreparationVhdxPath = "$provisioningTargetDirectory\$kubeworkerInPreparationName"
    $preparedVhdxPath = "$provisioningTargetDirectory\$Hostname-prepared.vhdx"

    $sourcePath = $InputPath

    Copy-Item -Path $sourcePath -Destination $inPreparationVhdxPath

    $vmName = $KubeworkerVmProvisioningVmName
    $switchName = $KubenodeVmProvisioningSwitchName
    $natName = $KubenodeVmProvisioningNatName

    $vm = Get-VM | Where-Object Name -Like $vmName
    Write-Log "Ensure not existence of VM $vmName"
    if ($null -ne $vm) {
        Stop-VirtualMachine -VmName $vm -Wait
        $vm | Remove-VM -Force
    }

    $vmParams = @{
        "VmName"=$vmName
        "VhdxFilePath"=$inPreparationVhdxPath
        "IsoFilePath"=""
        "VMMemoryStartupBytes"=$VMMemoryStartupBytes
        "VMProcessorCount"=$VMProcessorCount
        "VMDiskSize"=$VMDiskSize
    }
    New-VirtualMachineForBaseImageProvisioning @vmParams

    $networkParams1 = @{
        "SwitchName"=$switchName
        "HostIpAddress"=Get-HostIpForProvisioningKubeNode
        "HostIpPrefixLength"=Get-NetworkPrefixLengthForProvisioningKubeNode
        "NatName"=$natName
        "NatIpAddress"=Get-NatIpForProvisioningKubeNode
    }
    New-NetworkForProvisioning @networkParams1

    Connect-VMNetworkAdapter -VmName $vmName -SwitchName $switchName -ErrorAction Stop

    Start-VirtualMachineAndWaitForHeartbeat -Name $vmName


    $remoteUser1 = "$(Get-DefaultUserNameKubeNode)@$(Get-VmIpForProvisioningKubeNode)"
    Wait-ForSshPossible -User $remoteUser1 -UserPwd $(Get-DefaultUserPwdKubeNode) -SshTestCommand 'which ls' -ExpectedSshTestCommandResult '/usr/bin/ls'

    # hostname
    (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo hostnamectl set-hostname $Hostname" -RemoteUser $remoteUser1).Output | Write-Log
    (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo sed -i `"s/$(Get-HostnameForProvisioningKubeNode)/$Hostname/g`" /etc/hosts" -RemoteUser $remoteUser1).Output | Write-Log

    # IP
    $interfaceConfigurationPath = '/etc/netplan/10-k2s.yaml'
    $configPath = "$PSScriptRoot\NetplanK2s.yaml"
    $netplanConfigurationTemplate = Get-Content $configPath
    $netplanConfiguration = $netplanConfigurationTemplate.Replace("__NETWORK_INTERFACE_NAME__",$InterfaceName).Replace("__NETWORK_ADDRESSES__","$IpAddress/24").Replace("__IP_GATEWAY__", $GatewayIpAddress).Replace("__DNS_IP_ADDRESSES__",$DnsServers)
    (Invoke-CmdOnControlPlaneViaUserAndPwd "echo '' | sudo tee $interfaceConfigurationPath" -RemoteUser $remoteUser1).Output | Write-Log
    foreach ($line in $netplanConfiguration) {
        (Invoke-CmdOnControlPlaneViaUserAndPwd "echo '$line' | sudo tee -a $interfaceConfigurationPath" -RemoteUser $remoteUser1).Output | Write-Log
    }
    (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo chmod 600 $interfaceConfigurationPath" -RemoteUser $remoteUser1).Output | Write-Log
    (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo rm -f /etc/netplan/50-cloud-init.yaml" -RemoteUser $remoteUser1).Output | Write-Log

    # ssh keys
    (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo rm -f /etc/ssh/ssh_host_*; sudo ssh-keygen -A; sudo systemctl restart ssh" -RemoteUser $remoteUser1).Output | Write-Log

    Stop-VirtualMachineForBaseImageProvisioning -Name $vmName
    Disconnect-VMNetworkAdapter -VmName $vmName
    Remove-NetworkForProvisioning -SwitchName $switchName -NatName $natName

    Write-Log "Attach the VM to the existing network switch"
    $switchName = Get-ControlPlaneNodeDefaultSwitchName
    Connect-VMNetworkAdapter -VmName $vmName -SwitchName $switchName -ErrorAction Stop

    Start-VirtualMachineAndWaitForHeartbeat -Name $vmName

    $remoteUser2 = "$(Get-DefaultUserNameKubeNode)@$IpAddress"

    Wait-ForSshPossible -User $remoteUser2 -UserPwd $(Get-DefaultUserPwdKubeNode) -SshTestCommand 'which ls' -ExpectedSshTestCommandResult '/usr/bin/ls'
    
    &$Hook

    Stop-VirtualMachineForBaseImageProvisioning -Name $vmName
    Rename-Item $inPreparationVhdxPath $preparedVhdxPath
    Copy-Item $preparedVhdxPath $OutputPath -Force

    Remove-VM -Name $vmName -Force

    Remove-Item -Path $provisioningTargetDirectory -Recurse -Force
}

function Start-VmBasedOnKubenodeBaseImage {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize,
        [parameter(Mandatory = $false, HelpMessage = 'The path to take the kubenode base image.')]
        [string] $VhdxPath = $(throw "Argument missing: InPreparationVhdxPath"),
        [string] $VmName,
        [scriptblock]$Hook = $(throw "Argument missing: Hook")
        )

        if (!(Test-Path -Path $VhdxPath)) {
            throw "The specified path '$VhdxPath' does not exist"
        }
    

    $switchName = $KubenodeVmProvisioningSwitchName
    $natName = $KubenodeVmProvisioningNatName

    $vm = Get-VM | Where-Object Name -Like $VmName
    Write-Log "Ensure not existence of VM $VmName"
    if ($null -ne $vm) {
        Stop-VirtualMachine -VmName $vm -Wait
        $vm | Remove-VM -Force
    }

    $vmParams = @{
        "VmName"=$VmName
        "VhdxFilePath"=$VhdxPath
        "IsoFilePath"=""
        "VMMemoryStartupBytes"=$VMMemoryStartupBytes
        "VMProcessorCount"=$VMProcessorCount
        "VMDiskSize"=$VMDiskSize
    }
    New-VirtualMachineForBaseImageProvisioning @vmParams

    $networkParams = @{
        "SwitchName"=$switchName
        "HostIpAddress"=Get-HostIpForProvisioningKubeNode
        "HostIpPrefixLength"=Get-NetworkPrefixLengthForProvisioningKubeNode
        "NatName"=$natName
        "NatIpAddress"=Get-NatIpForProvisioningKubeNode
    }
    New-NetworkForProvisioning @networkParams

    Connect-VMNetworkAdapter -VmName $VmName -SwitchName $switchName -ErrorAction Stop

    Start-VirtualMachineAndWaitForHeartbeat -Name $VmName

    $remoteUser = "$(Get-DefaultUserNameKubeNode)@$(Get-VmIpForProvisioningKubeNode)"
    Wait-ForSshPossible -User $remoteUser -UserPwd $(Get-DefaultUserPwdKubeNode) -SshTestCommand 'which ls' -ExpectedSshTestCommandResult '/usr/bin/ls'

    &$Hook
}

function Stop-AndRemoveVmBasedOnKubenodeBaseImage {
    param (
        [string] $VmName
        )

    $switchName = $KubenodeVmProvisioningSwitchName
    $natName = $KubenodeVmProvisioningNatName

    Stop-VirtualMachineForBaseImageProvisioning -Name $VmName
    Disconnect-VMNetworkAdapter -VmName $VmName
    Remove-NetworkForProvisioning -SwitchName $switchName -NatName $natName
    Remove-VM -Name $vmName -Force
}

function New-ProvisionedBaseImage {
    param (
        [VmParameters]$VmParameters = $(throw "Argument missing: VmParameters"),
        [GuestOsParameters]$GuestOsParameters = $(throw "Argument missing: GuestOsParameters"),
        [NetworkParameters]$NetworkParameters = $(throw "Argument missing: NetworkParameters"),
        [string] $Proxy = $(throw "Argument missing: Proxy"),
        [scriptblock] $InstallationHook = $(throw "Argument missing: InstallationHook"),
        [scriptblock] $AfterProvisioningFinishedHook = $(throw "Argument missing: AfterProvisioningFinishedHook"),
        [string] $OutputPath = $(throw 'Argument missing: OutputPath'),
        [bool] $KeepArtifactsUsedOnProvisioning = $(throw "Argument missing: KeepArtifactsUsedOnProvisioning")
    )

    $vmIP = $NetworkParameters.GuestIpAddress
    $userName = $GuestOsParameters.UserName
    $userPwd =  $GuestOsParameters.UserPwd

    Write-Log "Remove eventually existing key for IP $vmIP from 'known_hosts' file"
    Remove-SshKeyFromKnownHostsFile -IpAddress $vmIP

    $inProvisioningVhdxName = $VmParameters.InProvisioningVhdxFileName
    $provisionedVhdxName = $VmParameters.ProvisionedVhdxFileName
    $vmName = $VmParameters.VmName

    $IsoFileCreatorTool = 'cloudinitisobuilder.exe'

    $VirtualMachineParams = @{
        VmName               = $vmName
        VhdxName             = $inProvisioningVhdxName
        VMMemoryStartupBytes = $VmParameters.MemoryStartupBytes
        VMProcessorCount     = $VmParameters.ProcessorCount
        VMDiskSize           = $VmParameters.DiskSize
    }
    $NetworkParams = @{
        Proxy              = $Proxy
        SwitchName         = $NetworkParameters.SwitchName
        HostIpAddress      = $NetworkParameters.HostIpAddress
        HostIpPrefixLength = $NetworkParameters.HostNetworkPrefixLength
        NatName            = $NetworkParameters.NatName
        NatIpAddress       = $NetworkParameters.NatIpAddress
        DnsIpAddresses     = $NetworkParameters.DnsIpAddresses
    }
    $IsoFileParams = @{
        IsoFileCreatorToolPath = "$kubeBinPath\$IsoFileCreatorTool"
        IsoFileName            = $VmParameters.IsoFileName
        SourcePath             = "$PSScriptRoot\cloud-init-templates"
        Hostname               = $GuestOsParameters.Hostname
        NetworkInterfaceName   = $GuestOsParameters.NetworkInterfaceName
        IPAddressVM            = $vmIP
        IPAddressGateway       = $NetworkParameters.HostIpAddress
        UserName               = $userName
        UserPwd                = $userPwd
    }

    $WorkingDirectoriesParams = @{
        DownloadsDirectory    = $downloadsDirectory
        ProvisioningDirectory = $provisioningTargetDirectory
    }

    New-LinuxCloudBasedVirtualMachine -VirtualMachineParams $VirtualMachineParams -NetworkParams $NetworkParams -IsoFileParams $IsoFileParams -WorkingDirectoriesParams $WorkingDirectoriesParams

    Write-Log "Start the VM $vmName"
    Start-VirtualMachineAndWaitForHeartbeat -Name $vmName
    
    $user = "$userName@$vmIP"
    # let's check if the connection to the remote computer is possible
    Write-Log "Checking if an SSH login into remote computer '$vmIP' with user '$user' is possible"
    Wait-ForSshPossible -User "$user" -UserPwd "$userPwd" -SshTestCommand 'which ls' -ExpectedSshTestCommandResult '/usr/bin/ls'

    Write-Log "Run role assignment hook"
    &$InstallationHook
    Write-Log "Role assignment finished"

    Write-Log "[Proxy] Remove proxy settings from base image before sealing"
    Remove-ProxySettingsOnKubenode -IpAddress $vmIP -UserName $userName -UserPwd $userPwd -CommandExecutionTimeoutSeconds 30

    Write-Log "Stop the VM $vmName"
    Stop-VirtualMachineForBaseImageProvisioning -Name $vmName

    $inProvisioningVhdxPath = "$provisioningTargetDirectory\$inProvisioningVhdxName"
    $provisionedVhdxPath = "$provisioningTargetDirectory\$provisionedVhdxName"
    Copy-VhdxFile -SourceFilePath $inProvisioningVhdxPath -TargetPath $provisionedVhdxPath
    Write-Log "Provisioned image available as $provisionedVhdxPath"

    Write-Log "Run WSL support creation hook"
    &$AfterProvisioningFinishedHook
    Write-Log "WSL support creation finished"

    Write-Log 'Detach the image from Hyper-V'
    Remove-VirtualMachineForBaseImageProvisioning -VhdxFilePath $inProvisioningVhdxPath -VmName $vmName
    Write-Log 'Remove the network for provisioning the image'
    Remove-NetworkForProvisioning -NatName $NetworkParameters.NatName -SwitchName $NetworkParameters.SwitchName

    Copy-Item -Path $provisionedVhdxPath -Destination $OutputPath
    Write-Log "Provisioned image '$provisionedVhdxPath' available as '$OutputPath'"

    if (!$KeepArtifactsUsedOnProvisioning) {
        $provisioningFolder = $WorkingDirectoriesParams.ProvisioningDirectory
        $downloadsFolder = $WorkingDirectoriesParams.DownloadsDirectory
        Write-Log "Flag 'KeepArtifactsUsedOnProvisioning' == $KeepArtifactsUsedOnProvisioning -> Delete artifacts used on provisioning: "
        Write-Log "  - deleting folder '$provisioningFolder'"
        Remove-Item -Path $provisioningFolder -Recurse -Force
        Write-Log "  - deleting folder '$downloadsFolder'"
        Remove-Item -Path $downloadsFolder -Recurse -Force
    }
}

function Convert-VhdxToRootfs {
    param (
        [string] $KubenodeBaseImagePath = $(throw "Argument missing: KubenodeBaseImagePath"),
        [string] $SourceVhdxPath = $(throw "Argument missing: SourceVhdxPath"),
        [string] $TargetRootfsFilePath = $(throw "Argument missing: TargetRootfsFilePath"),
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize
    )
    
    if (Test-Path -Path $TargetRootfsFilePath) {
        Remove-Item -Path $TargetRootfsFilePath -Force
    }

    if (Test-Path -Path $provisioningTargetDirectory) {
        Remove-Item -Path $provisioningTargetDirectory -Recurse -Force
    }
    New-Item -Path $provisioningTargetDirectory -Type Directory 

    $rootfsCreatorHostVhdxPath = "$provisioningTargetDirectory\rootfs-for-wsl-in-creation.vhdx"

    Copy-Item -Path $KubenodeBaseImagePath -Destination $rootfsCreatorHostVhdxPath

    $vmName = $RootfsWslProvisioningVmName

    $Hook = {
        New-RootfsForWSL -IpAddress $(Get-VmIpForProvisioningKubeNode) -UserName $(Get-DefaultUserNameKubeNode) -UserPwd $(Get-DefaultUserPwdKubeNode) -VhdxFile $SourceVhdxPath -TargetFilePath $TargetRootfsFilePath
    }

    $vmBasedOnKubenodeBaseImageStartParams = @{
        VhdxPath=$rootfsCreatorHostVhdxPath
        VmName=$vmName
        Hook = $Hook
        VMDiskSize = $VMDiskSize
        VMMemoryStartupBytes = $VMMemoryStartupBytes
        VMProcessorCount = $VMProcessorCount
    }
    Start-VmBasedOnKubenodeBaseImage @vmBasedOnKubenodeBaseImageStartParams
    Stop-AndRemoveVmBasedOnKubenodeBaseImage -VmName $vmName

    Remove-Item -Path $provisioningTargetDirectory -Recurse -Force
}

<#
.SYNOPSIS
Creates a root filesystem to be used with WSL
.DESCRIPTION
A vhdx file is copied from the Windows host to the running VM
and a filesystem file is created inside the running VM out of the vhdx file's content.
The filesystem file is then compressed an sent to the Windows host.
.PARAMETER IpAddress
The IP address of the VM.
.PARAMETER UserName
The user name to log in into the VM.
.PARAMETER UserPwd
The password to use to log in into the VM.
.PARAMETER VhdxFile
The full path of the vhdx file that will be used to create the filesystem.
.PARAMETER RootfsName
The full path for the output filesystem file.
.PARAMETER TargetPath
The path to a directory where the filesystem file will saved after compression and before being sent to the Windows host
#>
Function New-RootfsForWSL {
    param (
        [string] $IpAddress = $(throw "Argument missing: IpAddress"),
        [string] $UserName = $(throw "Argument missing: UserName"),
        [string] $UserPwd = $(throw "Argument missing: UserPwd"),
        [string] $VhdxFile = $(throw "Argument missing: VhdxFile"),
        [string] $TargetFilePath = $(throw "Argument missing: TargetFilePath")
    )
    $user = "$UserName@$IpAddress"
    $userPwd = $UserPwd

    $executeRemoteCommand = {
        param(
            $command = $(throw "Argument missing: Command"),
            [switch]$IgnoreErrors = $false
            )
        if ($IgnoreErrors) {
            (Invoke-CmdOnControlPlaneViaUserAndPwd $command -RemoteUser "$user" -RemoteUserPwd "$userPwd" -IgnoreErrors).Output | Write-Log
        } else {
            (Invoke-CmdOnControlPlaneViaUserAndPwd $command -RemoteUser "$user" -RemoteUserPwd "$userPwd").Output | Write-Log
        }
    }

    $TargetPath = Split-Path -Path $TargetFilePath
    $RootfsName = Split-Path -Path $TargetFilePath -Leaf
    
    Write-Log "Creating $RootfsName for WSL2"

    Write-Log "Remove file '$TargetFilePath' if existing"
    if (Test-Path $TargetFilePath) {
        Remove-Item $TargetFilePath -Force
    }

    # Stage the conversion on the disk-backed root filesystem (/var/tmp), NOT /tmp.
    # On these VMs /tmp is a tmpfs (RAM-backed, ~half of RAM) and cannot hold the copied vhdx
    # plus the fully extracted rootfs plus the tarball, which causes 'No space left on device'.
    &$executeRemoteCommand "sudo mkdir -p /var/tmp/rootfs"
    &$executeRemoteCommand "sudo chmod 755 /var/tmp/rootfs"
    &$executeRemoteCommand "sudo chown $UserName /var/tmp/rootfs"

    Write-Log "Available space on rootfs creation VM (staging dir /var/tmp) before copying the vhdx:"
    &$executeRemoteCommand "df -h /var/tmp"

    $target = '/var/tmp/rootfs/'
    $filename = Split-Path $VhdxFile -Leaf
    # Allow a couple of retries for the large VHDX file transfer (3GB+) to tolerate transient SCP failures.
    Copy-ToRemoteComputerViaUserAndPwd -Source $VhdxFile -Target $target -IpAddress $IpAddress -Retries 2

    &$executeRemoteCommand "cd /var/tmp/rootfs && sudo mkdir mntfs"
    &$executeRemoteCommand "cd /var/tmp/rootfs && sudo modprobe nbd"
    &$executeRemoteCommand "cd /var/tmp/rootfs && sudo qemu-nbd -c /dev/nbd0 ./$filename"

    $waitFile = @'
#!/bin/bash \n

waitFile() { \n
    local START=$(cut -d '.' -f 1 /proc/uptime) \n
    local MODE=${2:-"a"} \n
    until [[ "${MODE}" = "a" && -e "$1" ]] || [[ "${MODE}" = "d" && ( ! -e "$1" ) ]]; do \n
        sleep 1s \n
        if [ -n "$3" ]; then \n
        local NOW=$(cut -d '.' -f 1 /proc/uptime) \n
        local ELAPSED=$(( NOW - START )) \n
        if [ $ELAPSED -ge "$3" ]; then break; fi \n
        fi \n
    done \n
} \n

$@ \n
'@

    &$executeRemoteCommand "sudo touch /var/tmp/rootfs/waitfile.sh"
    &$executeRemoteCommand "sudo chmod +x /var/tmp/rootfs/waitfile.sh"
    &$executeRemoteCommand "echo -e '$waitFile' | sudo tee -a /var/tmp/rootfs/waitfile.sh" | Out-Null
    &$executeRemoteCommand "cd /var/tmp/rootfs && sed -i 's/\r//g' waitfile.sh"
    &$executeRemoteCommand "cd /var/tmp/rootfs && ./waitfile.sh waitFile /dev/nbd0p1 'a' 30"

    &$executeRemoteCommand "cd /var/tmp/rootfs && sudo mount /dev/nbd0p1 mntfs"

    &$executeRemoteCommand "cd /var/tmp/rootfs && sudo cp -a mntfs rootfs"

    # WSL-specific fixes: The rootfs is from Hyper-V and has PARTUUID entries in fstab
    # that don't exist in WSL, causing systemd to hang waiting for non-existent devices
    Write-Log "Applying WSL-specific fixes to rootfs (fstab, boot-efi.mount)..."
    # Fix fstab - replace PARTUUID entries with /dev/sdb (WSL standard)
    &$executeRemoteCommand 'cd /var/tmp/rootfs && echo "/dev/sdb / ext4 rw,discard,errors=remount-ro 0 1" | sudo tee rootfs/etc/fstab'
    # Mask boot-efi.mount - prevents waiting for non-existent EFI partition
    &$executeRemoteCommand "cd /var/tmp/rootfs && sudo ln -sf /dev/null rootfs/etc/systemd/system/boot-efi.mount"
    # Configure systemd for cgroups v1 compatibility (WSL2 kernel uses cgroups v1)
    &$executeRemoteCommand "cd /var/tmp/rootfs && sudo mkdir -p rootfs/etc/systemd/system/user@.service.d"
    &$executeRemoteCommand 'cd /var/tmp/rootfs && echo -e "[Service]\nDelegate=yes" | sudo tee rootfs/etc/systemd/system/user@.service.d/delegate.conf'
    &$executeRemoteCommand "cd /var/tmp/rootfs && sudo mkdir -p rootfs/etc/systemd/logind.conf.d"
    &$executeRemoteCommand 'cd /var/tmp/rootfs && echo -e "[Login]\nKillUserProcesses=no" | sudo tee rootfs/etc/systemd/logind.conf.d/wsl.conf'

    &$executeRemoteCommand "cd /var/tmp/rootfs && sudo umount mntfs"
    &$executeRemoteCommand "cd /var/tmp/rootfs && sudo qemu-nbd -d /dev/nbd0"
    &$executeRemoteCommand "cd /var/tmp/rootfs && ./waitfile.sh waitFile /dev/nbd0p1 'd' 30"
    &$executeRemoteCommand "cd /var/tmp/rootfs && sudo rmmod nbd"
    &$executeRemoteCommand "cd /var/tmp/rootfs && sudo rmdir mntfs"

    &$executeRemoteCommand "cd /var/tmp/rootfs && sudo rm $filename"

    &$executeRemoteCommand "cd /var/tmp/rootfs && sudo tar -zcpf rootfs.tar.gz -C ./rootfs ."  -IgnoreErrors
    &$executeRemoteCommand 'cd /var/tmp/rootfs && sudo chown "$(id -un)" rootfs.tar.gz'

    Copy-FromRemoteComputerViaUserAndPwd -Source "/var/tmp/rootfs/rootfs.tar.gz" -Target "$TargetPath" -IpAddress $IpAddress
    Rename-Item -Path "$TargetPath\rootfs.tar.gz" -NewName $RootfsName -Force -ErrorAction SilentlyContinue
    Remove-Item "$TargetPath\rootfs.tar.gz" -Force -ErrorAction SilentlyContinue
    &$executeRemoteCommand "sudo rm -rf /var/tmp/rootfs"

    if (!(Test-Path $TargetFilePath)) {
        throw "The provisioned base image is not available as $TargetFilePath for WSL2"
    }
    Write-Log "Provisioned base image available as $TargetFilePath for WSL2"
}

function Get-VmIpForProvisioningKubeNode {
    return "172.18.12.22"
}

function Get-HostIpForProvisioningKubeNode {
    return "172.18.12.1"
}

function Get-NatIpForProvisioningKubeNode {
    return "172.18.12.0"
}

function Get-NetworkPrefixLengthForProvisioningKubeNode {
    return "24"
}

function Get-DefaultUserNameKubeNode {
    return Get-DefaultUserNameControlPlane
}

function Get-DefaultUserPwdKubeNode {
    return Get-DefaultUserPwdControlPlane
}


function Get-HostnameForProvisioningKubeNode {
    return "kubenodebase"
}


function Get-NetworkInterfaceName {
    return 'eth0'
}

function Remove-KubeNodeBaseImage {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [boolean] $DeleteFilesForOfflineInstallation = $false
    )

    if ($DeleteFilesForOfflineInstallation) {
        Write-Log "Deleting file '$kubeNodeBaseImagePath' if existing"
        if (Test-Path $kubeNodeBaseImagePath) {
            Remove-Item $kubeNodeBaseImagePath -Force
        }
    }
}

function Clear-ProvisioningArtifacts {
    $kubenodeVmName = $KubenodeVmProvisioningVmName
    $kubemasterVmName = $KubemasterVmProvisioningVmName
    $kubeworkerVmName = $KubeworkerVmProvisioningVmName
    $rootfsWslVmName = $RootfsWslProvisioningVmName

    $stopVm = { 
        param(
            [string]$VmName = $(throw "Argument missing: VmName")
            ) 

            $vm = Get-VM | Where-Object Name -Like $VmName
            Write-Log "Ensure VM $VmName is stopped"
            if ($null -ne $vm) {
                Stop-VirtualMachineForBaseImageProvisioning -Name $VmName
            }
    }
    &$stopVm -VmName $kubenodeVmName
    &$stopVm -VmName $kubemasterVmName
    &$stopVm -VmName $kubeworkerVmName
    &$stopVm -VmName $rootfsWslVmName

    $removeVm = {
        param(
            [string]$VmName = $(throw "Argument missing: VmName"),
            [string]$NatName = $(throw "Argument missing: NatName"),
            [string]$SwitchName = $(throw "Argument missing: SwitchName"),
            [string]$VhdxFilePath = $(throw "Argument missing: VhdxFilePath")
            ) 

        Write-Log "Detach the image '$VhdxFilePath' from the VM '$VmName'"
        Remove-VirtualMachineForBaseImageProvisioning -VmName $VmName -VhdxFilePath $VhdxFilePath
        Write-Log "Remove the switch '$SwitchName' and nat '$NatName' for provisioning the image"
        Remove-NetworkForProvisioning -NatName $NatName -SwitchName $SwitchName
    }

    $kubenodeInProvisioningImagePath = "$provisioningTargetDirectory\$RawBaseImageInProvisioningForKubenodeImageName"
    $kubemasterInProvisioningImagePath = "$provisioningTargetDirectory\$RawBaseImageInProvisioningForKubemasterImageName"
    $kubeworkerInProvisioningImagePath = "$provisioningTargetDirectory\$RawBaseImageInProvisioningForKubeworkerImageName"

    &$removeVm -VmName $kubenodeVmName -NatName $KubenodeVmProvisioningNatName -SwitchName $KubenodeVmProvisioningSwitchName -VhdxFilePath $kubenodeInProvisioningImagePath 
    &$removeVm -VmName $kubemasterVmName -NatName $VmProvisioningNatName -SwitchName $VmProvisioningSwitchName -VhdxFilePath $kubemasterInProvisioningImagePath 
    &$removeVm -VmName $kubeworkerVmName -NatName $KubeworkerVmProvisioningNatName -SwitchName $KubeworkerVmProvisioningSwitchName -VhdxFilePath $kubeworkerInProvisioningImagePath 
    &$removeVm -VmName $rootfsWslVmName -NatName $KubenodeVmProvisioningNatName -SwitchName $KubenodeVmProvisioningSwitchName -VhdxFilePath $kubenodeInProvisioningImagePath 

    if (Test-Path $provisioningTargetDirectory) {
        Write-Log "Deleting folder '$provisioningTargetDirectory'" -Console
        Remove-Item -Path $provisioningTargetDirectory -Recurse -Force
    }

    if (Test-Path $downloadsDirectory) {
        Write-Log "Deleting folder '$downloadsDirectory'" -Console
        Remove-Item -Path $downloadsDirectory -Recurse -Force
    }
}

Export-ModuleMember Clear-ProvisioningArtifacts, 
Get-NetworkInterfaceName, 
Get-DefaultUserNameKubeNode, 
Get-DefaultUserPwdKubeNode, 
Get-VmIpForProvisioningKubeNode,
Get-HostIpForProvisioningKubeNode,
Get-NatIpForProvisioningKubeNode,
Get-NetworkPrefixLengthForProvisioningKubeNode,
Remove-KubeNodeBaseImage,
New-KubenodeBaseImage, 
New-KubemasterBaseImage, 
New-KubeworkerBaseImage,
Convert-VhdxToRootfs
