# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
Import-Module $logModule, $configModule

$controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
$kubeSwitchIp = Get-ConfiguredKubeSwitchIP
$controlPlaneSwitchName = Get-ControlPlaneNodeDefaultSwitchName
$ipControlPlane = Get-ConfiguredIPControlPlane
$wslSwitchName = 'WSL'

function Get-WslSwitchName {
    return $wslSwitchName
}

function Add-DnsServer($switchname) {
    # add DNS proxy for cluster searches
    $ipindex = Get-NetIPInterface | ? InterfaceAlias -Like "*$switchname*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'

    Write-Log "Setting DNSProxy(3) IP address '$ipControlPlane' as main DNS server for network interface '$switchname'"
    Set-DnsClientServerAddress -InterfaceIndex $ipindex -ServerAddresses $ipControlPlane | Out-Null
    Set-DnsClient -InterfaceIndex $ipindex -ResetConnectionSpecificSuffix -RegisterThisConnectionsAddress $false | Out-Null
}

<#
.SYNOPSIS
    Create switch to KubeMaster VM.
.DESCRIPTION
    Create switch to KubeMaster VM.
#>
function New-KubeSwitch() {
    $maxRetries = 3
    $retryDelaySeconds = 5
    $switchAlias = "vEthernet ($controlPlaneSwitchName)"

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            Write-Log "[KubeSwitch] Create internal switch $controlPlaneSwitchName (attempt $attempt of $maxRetries)"
            New-VMSwitch -Name $controlPlaneSwitchName -SwitchType Internal -MinimumBandwidthMode Weight | Out-Null

            # allow Windows networking stack to register the virtual adapter
            Start-Sleep -Seconds 2

            Wait-ForNetIpInterface -SwitchName $switchAlias

            # switch is available, proceed with configuration
            break
        }
        catch {
            Write-Log "[KubeSwitch] Attempt $attempt failed: $_"

            # clean up partially-created switch before retrying
            $sw = Get-VMSwitch -Name $controlPlaneSwitchName -ErrorAction SilentlyContinue
            if ($sw) {
                Write-Log "[KubeSwitch] Removing partially-created switch before retry ..."
                Remove-VMSwitch -Name $controlPlaneSwitchName -Force
            }

            if ($attempt -ge $maxRetries) {
                throw "[KubeSwitch] Failed to create switch '$controlPlaneSwitchName' after $maxRetries attempts. Last error: $_"
            }

            Write-Log "[KubeSwitch] Retrying in $retryDelaySeconds seconds ..."
            Start-Sleep -Seconds $retryDelaySeconds
        }
    }

    New-NetIPAddress -IPAddress $kubeSwitchIp -PrefixLength 24 -InterfaceAlias $switchAlias | Out-Null
    # set connection to private because of firewall rules
    Set-NetConnectionProfile -InterfaceAlias $switchAlias -NetworkCategory Private -ErrorAction SilentlyContinue
    # enable forwarding
    netsh int ipv4 set int $switchAlias forwarding=enabled | Out-Null
    # change index in order to have the Ethernet card as first card (also for much better DNS queries)
    $ipindex1 = Get-NetIPInterface | Where-Object InterfaceAlias -Like "*$controlPlaneSwitchName*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
    Write-Log "[KubeSwitch] Index for interface $controlPlaneSwitchName : ($ipindex1) -> metric 100"
    Set-NetIPInterface -InterfaceIndex $ipindex1 -InterfaceMetric 100
}

<#
.SYNOPSIS
    Connect switch to control plane VM.
.DESCRIPTION
    Connect switch to control plane VM.
#>
function Connect-KubeSwitch() {
    Write-Log 'Connect KubeSwitch to VM'
    # connect VM to switch
    $ad = Get-VMNetworkAdapter -VMName $controlPlaneVMHostName
    if ( !($ad) ) {
        Write-Log "Adding network adapter to VM '$controlPlaneVMHostName' ..."
        Add-VMNetworkAdapter -VMName $controlPlaneVMHostName -Name 'Network Adapter'
    }
    Connect-VMNetworkAdapter -VMName $controlPlaneVMHostName -SwitchName $controlPlaneSwitchName
}

<#
.SYNOPSIS
    Connect a VM's network adapter to a switch.
.DESCRIPTION
    Ensures the VM has a network adapter and connects it to the specified switch.
.PARAMETER VmName
    The name of the VM to connect.
.PARAMETER SwitchName
    The name of the switch to connect the VM to.
#>
function Connect-NetworkAdapterToVm {
    param (
        [string]$VmName = $(throw 'Argument missing: VmName'),
        [string]$SwitchName = $(throw 'Argument missing: SwitchName')
    )
    Write-Log "[KubeSwitch] Connect switch '$SwitchName' to VM '$VmName'"
    $ad = Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue
    if ( !($ad) ) {
        Write-Log "[KubeSwitch] Adding network adapter to VM '$VmName' ..."
        Add-VMNetworkAdapter -VMName $VmName -Name 'Network Adapter'
    }
    Connect-VMNetworkAdapter -VMName $VmName -SwitchName $SwitchName
}

<#
.SYNOPSIS
    Disconnect a VM's network adapter from its current switch.
.DESCRIPTION
    Disconnects the VM's network adapter if one exists.
.PARAMETER VmName
    The name of the VM to disconnect.
#>
function Disconnect-NetworkAdapterFromVm {
    param (
        [string]$VmName = $(throw 'Argument missing: VmName')
    )
    Write-Log "[KubeSwitch] Disconnect VM '$VmName' from network adapter"
    $networkAdapter = Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue
    if ( $networkAdapter ) {
        Disconnect-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Remove switch to control plane VM.
.DESCRIPTION
    Remove switch to control plane VM.
#>
function Remove-KubeSwitch() {
    Write-Log '[KubeSwitch] Removing KubeSwitch...'
    
    # Get all VMs connected to the KubeSwitch and disconnect them
    $connectedVMs = @(Get-VM -ErrorAction SilentlyContinue | ForEach-Object { 
        Get-VMNetworkAdapter -VMName $_.Name -ErrorAction SilentlyContinue
    } | Where-Object { $_.SwitchName -eq $controlPlaneSwitchName })
    
    if ($connectedVMs.Count -gt 0) {
        $vmNames = ($connectedVMs | Select-Object -ExpandProperty VMName -Unique) -join ', '
        Write-Log "[KubeSwitch] Disconnecting VMs from '$controlPlaneSwitchName': $vmNames"
        foreach ($adapter in $connectedVMs) {
            Disconnect-NetworkAdapterFromVm -VmName $adapter.VMName
        }
    }
    
    $sw = Get-VMSwitch -Name $controlPlaneSwitchName -ErrorAction SilentlyContinue
    if ($sw) {
        Write-Log "[KubeSwitch] Removing switch '$controlPlaneSwitchName'"
        Remove-VMSwitch -Name $controlPlaneSwitchName -Force -ErrorAction SilentlyContinue
    }

    Write-Log "[KubeSwitch] Removing IP address $kubeSwitchIp"
    Remove-NetIPAddress -IPAddress $kubeSwitchIp -PrefixLength 24 -Confirm:$False -ErrorAction SilentlyContinue

    if ($ipControlPlane) {
        Write-Log "[KubeSwitch] Removing routes via control plane IP $ipControlPlane"
        foreach ($store in @('PersistentStore', 'ActiveStore')) {
            Get-NetRoute -AddressFamily IPv4 -PolicyStore $store -ErrorAction SilentlyContinue |
                Where-Object { $_.NextHop -eq $ipControlPlane } |
                Remove-NetRoute -PolicyStore $store -Confirm:$False -ErrorAction SilentlyContinue
        }
    }
}



function Reset-DnsServer($switchname) {
    $ipindex = Get-NetIPInterface | ? InterfaceAlias -Like "*$switchname*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
    if ($ipindex) {
        Write-Log "Setting DNSProxy(4) for network interface '$switchname' with reset"
        Set-DnsClientServerAddress -InterfaceIndex $ipindex -ResetServerAddresses | Out-Null
        Set-DnsClient -InterfaceIndex $ipindex -ResetConnectionSpecificSuffix | Out-Null
    }
}

function Repair-KubeSwitch {
    $WSL = Get-ConfigWslFlag
    if ($WSL) {
        Write-Log 'Repair-KubeSwitch: Using WSL2 as hosting environment for the control plane node'
        Write-Log 'Repair-KubeSwitch: No repair for WSl setup yet !'
    }
    else {
        Write-Log 'Repair-KubeSwitch: Using Hyper-V as hosting environment for the control plane node'
        # check if switch exists
        $sw = Get-VMSwitch -Name $controlPlaneSwitchName -ErrorAction SilentlyContinue
        if ( $sw ) {
            Write-Log "Repair-KubeSwitch: KubeSwitch '$controlPlaneSwitchName' already exists, check ip to repair"
            $ipindex = Get-NetIPAddress -InterfaceAlias "*$controlPlaneSwitchName*" -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($ipindex) {
                Write-Log "Repair-KubeSwitch: KubeSwitch '$controlPlaneSwitchName' with IP '$($ipindex.IPAddress)' already exists, nothing to repair"
            }
            else {
                Write-Log "Repair-KubeSwitch: KubeSwitch '$controlPlaneSwitchName' exists, but has no IP, repair it"
                Remove-KubeSwitch
                New-KubeSwitch
                Connect-KubeSwitch
                Add-DnsServer $controlPlaneSwitchName
            }
        }
        else {
            Write-Log "Repair-KubeSwitch: KubeSwitch '$controlPlaneSwitchName' does not exist, creating it"
            New-KubeSwitch
            Connect-KubeSwitch
            Add-DnsServer $controlPlaneSwitchName
        }
    }
}

function Get-MasterNodeSwitchIndex {
    # check if switch exists
    $sw = Get-VMSwitch -Name "*$controlPlaneSwitchName*" -ErrorAction SilentlyContinue
    if ( -not $sw ) {
        Write-Log "Get-MasterNodeSwitchIndex: KubeSwitch '$controlPlaneSwitchName' does not exist"
        $sw = Get-VMSwitch -Name '*wslSwitchName*' -ErrorAction SilentlyContinue
        if ( -not $sw ) {
            Write-Log 'Get-MasterNodeSwitchIndex: WSL Switch does not exist'
            return $null
        }
        Write-Log "Get-MasterNodeSwitchIndex: WSL Switch '$wslSwitchName' exists, using it as control plane node switch"
        $ipindex = Get-NetIPInterface | ? InterfaceAlias -Like "*$wslSwitchName*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
        if ( -not $ipindex ) {
            Write-Log "Get-MasterNodeSwitchIndex: No index found for control plane node '$wslSwitchName'"
            return $null
        }
        Write-Log "Get-MasterNodeSwitchIndex: Index for control plane node '$wslSwitchName' is $ipindex"
        # return index
        return $ipindex
    }
    else {
        Write-Log "Get-MasterNodeSwitchIndex: KubeSwitch '$controlPlaneSwitchName' exists"
        $ipindex = Get-NetIPInterface | ? InterfaceAlias -Like "*$controlPlaneSwitchName*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
        if ( -not $ipindex ) {
            Write-Log "Get-MasterNodeSwitchIndex: No index found for control plane node '$controlPlaneSwitchName'"
            return $null
        }
        Write-Log "Get-MasterNodeSwitchIndex: Index for control plane node '$controlPlaneSwitchName' is $ipindex"
        # return index
        return $ipindex
    }
    return $null
}

function Wait-ForNetIpInterface {
    param (
        [string]$SwitchName = $(throw 'Argument missing: SwitchName'),
        [int]$MaxWaitTimeSeconds = 60
    )
    $switchName = $SwitchName
    Write-Log "[KubeSwitch] Wait for NetIpInterface '$switchName' to be available (timeout: ${MaxWaitTimeSeconds}s) ..."
    $startTime = Get-Date
    $lastProgressTime = $startTime
    while (!(Get-NetIPInterface -InterfaceAlias $switchName -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        $elapsed = (Get-Date) - $startTime
        if ($elapsed.TotalSeconds -ge $MaxWaitTimeSeconds) {
            $availableInterfaces = (Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InterfaceAlias) -join ', '
            Write-Log "[KubeSwitch] Available IPv4 interfaces: $availableInterfaces"
            throw "Switch '$switchName' not available after $MaxWaitTimeSeconds seconds. Windows may need more time to register the virtual adapter."
        }
        if (((Get-Date) - $lastProgressTime).TotalSeconds -ge 10) {
            Write-Log "[KubeSwitch] Still waiting for '$switchName' ($([int]$elapsed.TotalSeconds)s elapsed) ..."
            $lastProgressTime = Get-Date
        }
        Start-Sleep -Seconds 1
    }
    Write-Log "[KubeSwitch] NetIpInterface '$switchName' is available"
}


Export-ModuleMember Get-ControlPlaneNodeDefaultSwitchName,
Add-DnsServer, 
New-KubeSwitch, 
Connect-KubeSwitch, 
Remove-KubeSwitch, 
Get-WslSwitchName, 
Reset-DnsServer, 
Repair-KubeSwitch,
Get-MasterNodeSwitchIndex,
Wait-ForNetIpInterface,
Connect-NetworkAdapterToVm,
Disconnect-NetworkAdapterFromVm
