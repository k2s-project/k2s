# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$commonDistroModule = "$PSScriptRoot\..\distros\common-setup.module.psm1"

Import-Module $infraModule, $clusterModule, $commonDistroModule

function New-ControlPlaneNodeOnNewVM {
    Param(
        # Main parameters
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of master VM (Linux)')]
        [long] $MasterVMMemory = 8GB,
        [parameter(Mandatory = $false, HelpMessage = 'Minimum Memory for Dynamic Memory (Linux)')]
        [long] $MasterVMMemoryMin = 0,
        [parameter(Mandatory = $false, HelpMessage = 'Maximum Memory for Dynamic Memory (Linux)')]
        [long] $MasterVMMemoryMax = 0,
        [parameter(Mandatory = $false, HelpMessage = 'Enable Hyper-V Dynamic Memory')]
        [switch] $EnableDynamicMemory = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for master VM (Linux)')]
        [long] $MasterVMProcessorCount = 6,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of master VM (Linux)')]
        [uint64] $MasterDiskSize = 10GB,
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [parameter(Mandatory = $false, HelpMessage = 'DNS Addresses if available')]
        [string]$DnsServers = $(throw 'Argument missing: DnsServers'),
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [switch] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
        [switch] $ForceOnlineInstallation = $false,

        # These are specific developer options
        [parameter(Mandatory = $false, HelpMessage = 'Exit after initial checks')]
        [switch] $CheckOnly = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
        [switch] $WSL = $false,
        [parameter(Mandatory = $true, HelpMessage = 'Internal normalized effective install configuration path')]
        [string] $EffectiveInstallConfigPath
    )

    Write-Log 'Prerequisites checks before installation' -Console

    Test-PathPrerequisites
    Test-WindowsPrerequisites -WSL:$WSL
    Test-ControlPlanePrerequisites -MasterVMProcessorCount $MasterVMProcessorCount -MasterVMMemory $MasterVMMemory -MasterDiskSize $MasterDiskSize -WSL:$WSL -ForceOnlineInstallation:$ForceOnlineInstallation
    Stop-InstallationIfRequiredCurlVersionNotInstalled
    Write-WarningIfRequiredSshVersionNotInstalled

    if ($CheckOnly) {
        Write-Log 'Early exit (CheckOnly)'
        return
    }

    Write-Log 'Starting installation...'

    Set-ConfigWslFlag -Value $([bool]$WSL)

    $controlPlaneParams = @{
        Hostname                          = Get-ConfigControlPlaneNodeHostname
        IpAddress                         = Get-ConfiguredIPControlPlane
        GatewayIpAddress                  = Get-ConfiguredKubeSwitchIP
        DnsServers                        = $DnsServers
        VmName                            = 'KubeMaster'
        VMMemoryStartupBytes              = $MasterVMMemory
        VMMemoryMinBytes                  = $MasterVMMemoryMin
        VMMemoryMaxBytes                  = $MasterVMMemoryMax
        EnableDynamicMemory               = $EnableDynamicMemory
        VMProcessorCount                  = $MasterVMProcessorCount
        VMDiskSize                        = $MasterDiskSize
        Proxy                             = $Proxy
        DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
        ForceOnlineInstallation           = $ForceOnlineInstallation
    }

    if ($WSL) {
        Write-Log "Setting up $($controlPlaneParams.VmName) Distro" -Console
        Write-Log 'vEthernet (WSL) switch will be reconfigured! Your existing WSL distros will not work properly until you stop the cluster.'
        Write-Log 'Configuring WSL2'
        Set-WSL -MasterVMMemory $MasterVMMemory -MasterVMProcessorCount $MasterVMProcessorCount

        # WSL2 doesn't support Hyper-V dynamic memory - it has its own memory management
        # Remove dynamic memory parameters before calling WSL function
        $wslParams = $controlPlaneParams.Clone()
        $wslParams.Remove('VMMemoryMinBytes')
        $wslParams.Remove('VMMemoryMaxBytes')
        $wslParams.Remove('EnableDynamicMemory')

        New-WslLinuxVmAsControlPlaneNode @wslParams
        Start-WSL
        Set-WSLSwitch -IpAddress $($controlPlaneParams.GatewayIpAddress)
    }
    else {
        Write-Log "Setting up $($controlPlaneParams.VmName) VM" -Console
        New-LinuxVmAsControlPlaneNode @controlPlaneParams
        New-KubeSwitch
        Connect-KubeSwitch
    }

    Wait-ForSSHConnectionToLinuxVMViaPwd

    $controlPlaneUserName = Get-DefaultUserNameControlPlane
    $controlPlaneUserPwd = Get-DefaultUserPwdControlPlane
    $controlPlaneIpAddress = $($controlPlaneParams.IpAddress)

    New-SshKey -IpAddress $controlPlaneIpAddress
    Copy-LocalPublicSshKeyToRemoteComputer -UserName $controlPlaneUserName -UserPwd $controlPlaneUserPwd -IpAddress $controlPlaneIpAddress
    Wait-ForSSHConnectionToLinuxVMViaSshKey

    Remove-ControlPlaneAccessViaUserAndPwd

    $addToControlPlane = {
        Write-Host ''
    }

    # Configure transparent proxy on control plane VM before kubeadm init
    # so that CRI-O can pull images through the Windows host proxy.
    # This also clears any stale proxy settings baked into the base VHDX.
    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
    $transparentProxy = "http://$($windowsHostIpAddress):8181"
    Write-Log "[Proxy] Configuring transparent proxy ($transparentProxy) on control plane before kubeadm init" -Console
    Set-ProxySettingsOnKubenode -ProxySettings $transparentProxy -UserName $controlPlaneUserName -IpAddress $controlPlaneIpAddress

    $clusterName = Get-ClusterName
    Set-InstalledClusterName -Value $clusterName

    $masterNodeParams = @{
        NodeName             = $(Get-ConfigControlPlaneNodeHostname)
        IpAddress            = $controlPlaneIpAddress
        UserName             = $controlPlaneUserName
        K8sVersion           = $(Get-DefaultK8sVersion)
        ClusterCIDR          = $(Get-ConfiguredClusterCIDR)
        ClusterCIDR_Services = $(Get-ConfiguredClusterCIDRServices)
        KubeDnsServiceIP     = $(Get-ConfiguredKubeDnsServiceIP)
        IP_NextHop           = $windowsHostIpAddress
        NetworkInterfaceName = $(Get-NetworkInterfaceName)
        Hook                 = $addToControlPlane
        ClusterName          = $clusterName
        ForceOnlineInstallation = $ForceOnlineInstallation
        EffectiveInstallConfigPath = $EffectiveInstallConfigPath
    }
    Set-UpMasterNode @masterNodeParams

    # add kubectl to Windows host
    Install-KubectlTool
    # copy kubectl config file into Windows host
    Copy-KubeConfigFromControlPlaneNode
    Add-K8sContext

    $hostname = (Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'hostname' -NoLog).Output
    Set-ConfigControlPlaneNodeHostname($hostname)

    # add to Path variable
    Set-EnvVars

    Update-NodeLabelsAndTaints

    # correct coredns config
    Update-CoreDNSConfigurationviaSSH 
}

function Initialize-Cni0Interface {
    param (
        [string] $VmName = $(throw 'Argument missing: VmName'),
        [bool] $WSL = $(throw 'Argument missing: WSL')
    )
    Write-Log "cni0 interface in $VmName is created ?"
    $startTime = Get-Date
    $i = 0
    while ($true) {
        $controlPlaneCni0IpAddr = Get-Cni0IpAddressInControlPlaneUsingSshWithRetries -Retries 30 -RetryTimeoutInSeconds 5
        $expectedControlPlaneCni0IpAddr = Get-ConfiguredMasterNetworkInterfaceCni0IP

        if ($controlPlaneCni0IpAddr -ne $expectedControlPlaneCni0IpAddr) {
            Write-Log "cni0 interface in $controlPlaneVMHostName is not correctly initialized."
            Write-Log "           Expected:$expectedControlPlaneCni0IpAddr"
            Write-Log "           Actual:$controlPlaneCni0IpAddr"

            if ($i -eq 3) {
                throw "cni0 interface in $controlPlaneVMHostName is not correctly initialized after $i retries."
            }
        }
        else {
            Write-Log "cni0 interface in $controlPlaneVMHostName correctly initialized."
            break
        }
        if (!$WSL) {
            Stop-VirtualMachine -VmName $VmName -Wait
            Start-VirtualMachine -VmName $VmName -Wait
        }
        else {
            wsl --shutdown
            Start-WSL
        }
        Wait-ForSSHConnectionToLinuxVMViaSshKey
        $i++
    }
    $endTime = Get-Date
    $durationSeconds = Get-DurationInSeconds -StartTime $startTime -EndTime $endTime
    Write-Log "cni0 interface in $VmName is created, total duration: $durationSeconds seconds"
}

function CheckKubeSwitchInExpectedState() {
    $controlPlaneNodeDefaultSwitchName = Get-ControlPlaneNodeDefaultSwitchName
    $if = Get-NetConnectionProfile -InterfaceAlias "vEthernet ($controlPlaneNodeDefaultSwitchName)" -ErrorAction SilentlyContinue
    if (!$if) {
        Write-Log "vEthernet ($controlPlaneNodeDefaultSwitchName) not found."
        return $false
    }
    if ($if.NetworkCategory -ne 'Private') {
        Write-Log "vEthernet ($controlPlaneNodeDefaultSwitchName) not set to private."
        return $false
    }
    $if = Get-NetIPAddress -InterfaceAlias "vEthernet ($controlPlaneNodeDefaultSwitchName)" -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if (!$if) {
        Write-Log "Unable get IP Address for host on vEthernet ($controlPlaneNodeDefaultSwitchName) interface..."
        return $false
    }
    if ($if.IPAddress -ne $windowsHostIpAddress) {
        Write-Log "IP Address of Host on vEthernet ($controlPlaneNodeDefaultSwitchName) is not $windowsHostIpAddress ..."
        return $false
    }
    return $true
}

<#
.SYNOPSIS
    Reconnects all configured Hyper-V worker node VMs to the KubeSwitch.
.DESCRIPTION
    Reads the cluster configuration and reconnects all Hyper-V based worker nodes
    to the KubeSwitch. Skips the control plane node and bare-metal nodes.
    Uses the VmName field stored in cluster.json to find the Hyper-V VM.
.PARAMETER ControlPlaneVMHostName
    The hostname of the control plane VM to skip.
.PARAMETER SwitchName
    The name of the KubeSwitch to connect worker nodes to.
#>
function Connect-WorkerNodesToKubeSwitch {
    param (
        [string] $ControlPlaneVMHostName = $(throw 'Argument missing: ControlPlaneVMHostName'),
        [string] $SwitchName = $(throw 'Argument missing: SwitchName')
    )
    
    Write-Log '[KubeSwitch] Reconnecting configured worker nodes to KubeSwitch'
    
    try {
        $k2sConfigDir = Get-K2sConfigDir
        $clusterDescriptorFile = "$k2sConfigDir\cluster.json"
        
        if (-not (Test-Path $clusterDescriptorFile)) {
            Write-Log '[KubeSwitch] No cluster.json found, no worker nodes to reconnect'
            return
        }
        
        $json = Get-Content -Path $clusterDescriptorFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $json -or -not $json.nodes) {
            Write-Log '[KubeSwitch] No nodes configured in cluster.json'
            return
        }
        
        # Ensure nodes is always an array
        $nodes = @($json.nodes)
        
        foreach ($node in $nodes) {
            # Skip control plane node and bare-metal nodes (only process Hyper-V VMs)
            if ($node.Name -eq $ControlPlaneVMHostName -or $node.NodeType -eq 'HOST' -or $node.NodeType -eq 'HOST-EXISTING') {
                Write-Log "[KubeSwitch] Skipping node '$($node.Name)' (type: $($node.NodeType))"
                continue
            }
            
            $vm = $null
            
            # Use VmName field if available (stored during node add)
            if ($node.VmName) {
                Write-Log "[KubeSwitch] Looking for VM '$($node.VmName)' for node '$($node.Name)'"
                $vm = Get-VM -Name $node.VmName -ErrorAction SilentlyContinue
            }
            
            # Fallback: try by node Name
            if (-not $vm) {
                $vm = Get-VM -Name $node.Name -ErrorAction SilentlyContinue
            }
            
            if ($vm) {
                Write-Log "[KubeSwitch] Reconnecting worker node VM '$($vm.Name)' to switch '$SwitchName'"
                Connect-NetworkAdapterToVm -VmName $vm.Name -SwitchName $SwitchName
                
                # Start the VM if it's not running
                if ($vm.State -ne 'Running') {
                    Write-Log "[KubeSwitch] Starting worker node VM '$($vm.Name)'" -Console
                    Start-VM -Name $vm.Name -ErrorAction SilentlyContinue
                }
            }
            else {
                Write-Log "[KubeSwitch] Worker node VM for '$($node.Name)' (VmName: $($node.VmName)) not found, skipping"
            }
        }
    }
    catch {
        Write-Log "[KubeSwitch] Warning: Failed to reconnect worker nodes: $_"
    }
}

function Start-ControlPlaneNodeOnNewVM {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Number of processors for VM')]
        [string] $VmProcessors,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Use cached vSwitches')]
        [switch] $UseCachedK2sVSwitches,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $DnsServers = $(throw 'Argument missing: DnsServers')
    )

    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'Starting K2s control plane'
    }

    $WSL = Get-ConfigWslFlag
    if ($WSL) {
        Write-Log 'Using WSL2 as hosting environment for the control plane node'
    }
    else {
        Write-Log 'Using Hyper-V as hosting environment for the control plane node'
    }


    $NumOfProcessors = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    if ([int]$NumOfProcessors -lt 4) {
        throw 'Your Windows host needs at least 4 logical processors'
    }

    if ($VmProcessors -ne '') {
        # Do not reset VMProcessorCount with default value unless supplied from the user
        if ([int]$VmProcessors -ge [int]$NumOfProcessors) {
            Write-Log "Amount of logical processors on Windows host: $NumOfProcessors. Specified amount of processors for the VM: $VmProcessors."
            $VmProcessors = [int]$NumOfProcessors
            Write-Log "Cannot use a greater value of processors than the available logical ones. The VM will have $VmProcessors processors."
        }
    }

    $switchname = ''
    if ($WSL) {
        $switchname = Get-WslSwitchName
    }
    else {
        $switchname = Get-ControlPlaneNodeDefaultSwitchName
    }

    Set-IndexForDefaultSwitch

    $controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname

    if (!$WSL) {
        # Because of stability issues network settings are recreated every time we start the machine
        # or we restart the service !!!!! (StopServices.ps1 also cleans up the entire network setup)
        # stop VM
        Write-Log 'Reconfiguring VM'
        Write-Log "Configuring $controlPlaneVMHostName VM" -Console
        Stop-VirtualMachine -VmName $controlPlaneVMHostName -Wait

        if ($VmProcessors -ne '') {
            # change cores
            Set-VMProcessor $controlPlaneVMHostName -Count $VmProcessors
        }
       $kubeSwitchInExpectedState = CheckKubeSwitchInExpectedState
        if (!$UseCachedK2sVSwitches -or !$kubeSwitchInExpectedState) {
            # Remove old switch
            Write-Log 'Updating VM networking...'
            Remove-KubeSwitch

            # create switch for VM
            New-KubeSwitch
            Set-InterfacePrivate -InterfaceAlias "vEthernet ($switchname)"

            # connect VM to switch
            Connect-KubeSwitch
        }
        
        # Reconnect all configured Hyper-V worker nodes to KubeSwitch
        Connect-WorkerNodesToKubeSwitch -ControlPlaneVMHostName $controlPlaneVMHostName -SwitchName $switchname

        Start-VirtualMachine -VmName $controlPlaneVMHostName -Wait
    }
    else {
        Write-Log 'Configuring KubeMaster Distro' -Console
        wsl --shutdown
        Start-WSL
        Set-WSLSwitch -IpAddress $windowsHostIpAddress

        $interfaceAlias = Get-NetAdapter -Name 'vEthernet (WSL*)' -ErrorAction SilentlyContinue -IncludeHidden | Select-Object -expandproperty name
        New-NetFirewallRule -DisplayName 'WSL Inbound' -Group 'k2s' -Direction Inbound -InterfaceAlias $interfaceAlias -Action Allow
        New-NetFirewallRule -DisplayName 'WSL Outbound'-Group 'k2s' -Direction Outbound -InterfaceAlias $interfaceAlias -Action Allow
    }

    # add DNS proxy for cluster searches
    Add-DnsServer $switchname

    Set-RoutesToKubemaster

    $sshWaitParams = @{}
    if (-not $WSL) {
        $sshWaitParams.LocalIPAddress = $windowsHostIpAddress
    }
    Wait-ForSSHConnectionToLinuxVMViaSshKey @sshWaitParams

    # Ensure the control plane has a route to the Windows loopback adapter subnet
    # so that flannel's host-gw backend can install pod subnet routes via the
    # Windows node's public-ip (on the loopback adapter). Without this route,
    # flannel fails with "network is unreachable" when the loopback subnet is
    # not directly connected to the control plane's L2 segment.
    $loopbackCIDR = Get-LoopbackAdapterCIDR
    $kubeSwitchIP = Get-ConfiguredKubeSwitchIP
    if (-not [string]::IsNullOrWhiteSpace($loopbackCIDR) -and -not [string]::IsNullOrWhiteSpace($kubeSwitchIP)) {
        Write-Log "Adding transit route to $loopbackCIDR via $kubeSwitchIP on control plane" -Console
        $addRouteResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "sudo ip route replace $loopbackCIDR via $kubeSwitchIP" -IgnoreErrors
        if ($addRouteResult.Success) {
            Write-Log "Transit route to $loopbackCIDR via $kubeSwitchIP added successfully on control plane"
        } else {
            $routeOutput = ($addRouteResult.Output | Out-String).Trim()
            Write-Log "WARNING: Failed to add transit route to $loopbackCIDR via $kubeSwitchIP on control plane - $routeOutput"
        }
    }

    # Initialize-Cni0Interface -VmName $controlPlaneVMHostName -WSL:$WSL

    $ipindex = Get-NetIPInterface | Where-Object InterfaceAlias -Like "*$switchname*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
    Write-Log "Index for interface $switchname : ($ipindex) -> metric 100"
    Set-NetIPInterface -InterfaceIndex $ipindex -InterfaceMetric 100

    Invoke-TimeSync

    Set-RoutesToLinuxWorkloads

    # get the real switch name
    $switchRealName = Get-VirtualSwitchName($switchname)

    # enable ip forwarding
    netsh int ipv4 set int $switchRealName forwarding=enabled | Out-Null
    netsh int ipv4 set int 'vEthernet (Ethernet)' forwarding=enabled | Out-Null

    # Double check for KubeSwitch is in expected Private state
    Set-InterfacePrivate -InterfaceAlias $switchRealName

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'K2s control plane started'
    }
}

function Stop-ControlPlaneNodeOnNewVM {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Cache vSwitches on stop')]
        [switch] $CacheK2sVSwitches,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing stop header display')]
        [switch] $SkipHeaderDisplay = $false
    )

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'Stopping K2s control plane'
    }

    # reset default namespace
    $kubeToolsPath = Get-KubeToolsPath
    $kubectlExe = "$kubeToolsPath\kubectl.exe"
    if (Test-Path "$kubectlExe") {
        Write-Log 'Resetting default namespace for kubernetes'
        &"$kubectlExe" config set-context --current --namespace=default | Out-Null
    }

    $WSL = Get-ConfigWslFlag

    $switchname = ''
    if ($WSL) {
        $switchname = Get-WslSwitchName
    }
    else {
        $switchname = Get-ControlPlaneNodeDefaultSwitchName
    }

    if ($WSL) {
        wsl --shutdown
        $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
        Remove-NetIPAddress -IPAddress $windowsHostIpAddress -PrefixLength 24 -Confirm:$False -ErrorAction SilentlyContinue

        $hns = $(Get-HNSNetwork)
        $hns | Where-Object Name -Like ('*' + $switchname + '*') | Remove-HNSNetwork -ErrorAction SilentlyContinue
        Restart-WinService 'WslService'
    }
    else {
        # stop vm
        $controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
        if ($(Get-VM | Where-Object Name -eq $controlPlaneVMHostName | Measure-Object).Count -eq 1 ) {
            Write-Log ('Stopping ' + $controlPlaneVMHostName + ' VM') -Console
            Stop-VM -Name $controlPlaneVMHostName -Force -WarningAction SilentlyContinue
        }
        if (!$CacheK2sVSwitches) {
            Remove-KubeSwitch
        }
    }

    Reset-DnsServer $switchname

    $ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRMaster = $setupConfigRoot.psobject.properties['podNetworkMasterCIDR'].value
    $clusterCIDRServices = $setupConfigRoot.psobject.properties['servicesCIDR'].value
    $clusterCIDRServicesLinux = $setupConfigRoot.psobject.properties['servicesCIDRLinux'].value

    # Remove routes
    Write-Log "Remove route to $ipControlPlaneCIDR"
    route delete $ipControlPlaneCIDR >$null 2>&1
    Write-Log "Remove route to $clusterCIDRMaster"
    route delete $clusterCIDRMaster >$null 2>&1
    Write-Log "Remove route to $clusterCIDRServices"
    route delete $clusterCIDRServices >$null 2>&1
    route delete $clusterCIDRServicesLinux >$null 2>&1

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'K2s control plane stopped'
    }
}

function Remove-ControlPlaneNodeOnNewVM {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Do not purge all files')]
        [switch] $SkipPurge = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [switch] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing uninstall header display')]
        [switch] $SkipHeaderDisplay = $false
    )

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'Uninstalling K2s control plane'
    }

    $WSL = Get-ConfigWslFlag
    $VmName = Get-ConfigControlPlaneNodeHostname

    if ($WSL) {
        try {
            wsl --shutdown 2>&1 | Out-Null
            wsl --unregister $VmName 2>&1 | Out-Null
        }
        catch {
            Write-Log "[WSL] Warning while stopping/unregistering WSL VM '$VmName': $($_.Exception.Message)"
        }
    }
    else {
        $vm = Get-VM -ErrorAction SilentlyContinue | Where-Object Name -eq $VmName
        $vmCount = ($vm | Measure-Object).Count
        if ($vmCount -eq 0) {
            Write-Log "VM '$VmName' not found in Hyper-V, skipping stop and removal." -Console
        }
        elseif ($vmCount -eq 1) {
            Stop-VirtualMachine -VmName $VmName -Wait
            Remove-VirtualMachine $VmName
        }
        else {
            Write-Log "More than one VM found for name '$VmName' in Hyper-V, skipping automatic removal." -Console
        }
    }

    Write-Log 'Cleaning up' -Console

    Clear-ProvisioningArtifacts

    $linuxnodePath = "$(Get-KubeBinPath)\linuxnode"
    Write-Log "Delete folder '$linuxnodePath' if existing"
    if (Test-Path $linuxnodePath) {
        Write-Log "Deleting folder '$linuxnodePath'"
        Remove-Item -Path $linuxnodePath -Recurse -Force
    }
    
    if ($DeleteFilesForOfflineInstallation) {
        $kubemasterBaseFilePath = Get-KubemasterBaseFilePath
        $kubemasterRootfsPath = Get-ControlPlaneOnWslRootfsFilePath
        $kubenodeBaseFilePath = "$(Split-Path $kubemasterBaseFilePath)\$(Get-KubenodeBaseFileName)"
        Write-Log "Delete file '$kubemasterBaseFilePath' if existing"
        if (Test-Path $kubemasterBaseFilePath) {
            Remove-Item $kubemasterBaseFilePath -Force
        }
        Write-Log "Delete file '$kubemasterRootfsPath' if existing"
        if (Test-Path $kubemasterRootfsPath) {
            Remove-Item $kubemasterRootfsPath -Force
        }
        Write-Log "Delete file '$kubenodeBaseFilePath' if existing"
        if (Test-Path $kubenodeBaseFilePath) {
            Remove-Item $kubenodeBaseFilePath -Force
        }
        $linuxImageFilePath = Get-LinuxImageFilePath
        Write-Log "Delete file '$linuxImageFilePath' if existing"
        if (Test-Path $linuxImageFilePath) {
            Remove-Item $linuxImageFilePath -Force
        }
    }

    Write-Log 'Remove previous VM key from known_hosts file'
    $ipControlPlane = Get-ConfiguredIPControlPlane
    if (Get-Command 'ssh-keygen.exe' -ErrorAction SilentlyContinue) {
        ssh-keygen.exe -R $ipControlPlane 2>&1 | % { "$_" } | Out-Null
    }

    if (!$SkipPurge) {
        Remove-SshKey -IpAddress $ipControlPlane
    }

    Clear-WinNode -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

    Reset-EnvVars

    Write-Log 'Uninstalling K2s control plane done.'
}

Export-ModuleMember -Function New-ControlPlaneNodeOnNewVM,
Start-ControlPlaneNodeOnNewVM,
Stop-ControlPlaneNodeOnNewVM,
Remove-ControlPlaneNodeOnNewVM,
Initialize-Cni0Interface
