# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [string] $UserName = $(throw 'Argument missing: UserName'),
    [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
    [string] $WindowsHostIpAddress = '',
    [string] $Proxy = '',
    [string] $NodePackagePath = '',
    [switch] $ShowLogs = $false
)
$durationStopwatch = [system.diagnostics.stopwatch]::StartNew()

$linuxWorkerCommon = "$PSScriptRoot\..\common\LinuxWorkerNode.Common.ps1"
. $linuxWorkerCommon

Initialize-LinuxWorkerScriptEnvironment -ShowLogs:$ShowLogs -IncludePuttyTools

# Import GPU worker module for GPU detection and configuration
$gpuWorkerModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\linuxnode\setup\gpu-worker.module.psm1"
Import-Module $gpuWorkerModule

$ErrorActionPreference = 'Stop'


Write-Log '[NodeAdd] Detected external node (bare-metal) - using bare-metal provisioning path' -Console
Write-Log '[NodeAdd] Performing pre-requisites check' -Console

Assert-LinuxWorkerPuttyToolsReady -LogPrefix '[NodeAdd]' -Proxy $Proxy


# Validate that the node IP is on a physical network subnet (LAN/WiFi)
$loopbackAdapter = Get-L2BridgeName
$physicalSubnets = Get-PhysicalNetworkSubnets -ExcludeNetworkInterfaceName $loopbackAdapter

Write-Log "[NodeAdd] Available physical network subnets:" -Console
foreach ($subnet in $physicalSubnets) {
    Write-Log "[NodeAdd]   - $($subnet.InterfaceName): $($subnet.CIDR) (IP: $($subnet.IPAddress))" -Console
}

if (!(Test-IpInPhysicalSubnet -IpAddress $IpAddress -ExcludeNetworkInterfaceName $loopbackAdapter)) {
    $subnetList = ($physicalSubnets | ForEach-Object { "$($_.InterfaceName): $($_.CIDR)" }) -join ', '
    throw "[NodeAdd] Precondition not met: IP address '$IpAddress' is not within any physical network subnet. Available subnets: $subnetList"
}

Write-Log "[NodeAdd] IP address '$IpAddress' validated - belongs to a physical network subnet" -Console


Assert-LinuxWorkerNodeSshConnectivity -UserName $UserName -IpAddress $IpAddress -LogPrefix '[NodeAdd]' -TargetDescription 'node'
Assert-LinuxWorkerNodeAuthorizedKey -UserName $UserName -IpAddress $IpAddress -LogPrefix '[NodeAdd]'

$provisioningContext = Get-LinuxWorkerNodeProvisioningContext -UserName $UserName -IpAddress $IpAddress -LogPrefix '[NodeAdd]' -TargetDescription 'computer'
$NodeName = $provisioningContext.ActualHostname
$k8sFormattedNodeName = $provisioningContext.KubernetesNodeName
$installedDistributionOnRemoteComputer = $provisioningContext.InstalledDistribution

Write-Log "Adding node with hostname '$k8sFormattedNodeName'"


Disable-LinuxWorkerNodeSwap -UserName $UserName -IpAddress $IpAddress -LogPrefix '[NodeAdd]'

if ($WindowsHostIpAddress -eq '') {
    $loopbackAdapter = Get-L2BridgeName
    $WindowsHostIpAddress = Get-HostIpAddressForRemoteIp -RemoteIpAddress $IpAddress -ExcludeNetworkInterfaceName $loopbackAdapter
}
Write-Log "Windows Host IP address: $WindowsHostIpAddress"

# If configuration is present, retrieve proxy
if ($Proxy -eq '') {
    $proxyConfig = Get-ProxyConfig
    $Proxy = $proxyConfig.HttpProxy
}

$workerNodeParams = @{
    NodeName = $NodeName
    UserName = $UserName
    IpAddress = $IpAddress
    WindowsHostIpAddress = $WindowsHostIpAddress
    Proxy = $Proxy
    AdditionalHooksDir = $AdditionalHooksDir
    installedDistributionOnRemoteComputer = $installedDistributionOnRemoteComputer
    NodePackagePath = $NodePackagePath
    NodeType = 'HOST'
}

Add-LinuxWorkerNode @workerNodeParams

Write-Log 'Starting worker node' -Console
& "$PSScriptRoot\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay -IpAddress $IpAddress -NodeName $NodeName -ObtainCIDR:$true

Write-Log "Current state of cluster nodes:" -Console
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide 2>&1 | ForEach-Object { "$_" } | Write-Log -Console

Write-Log '---------------------------------------------------------------'
Write-Log "Linux computer with IP '$IpAddress' and hostname '$NodeName' added to the cluster.   Total duration: $('{0:hh\:mm\:ss}' -f $durationStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

# If the storage/ceph addon is enabled and this node is declared as a Ceph OSD host in
# ceph-config.json, prepare it as an OSD host now that it has joined the cluster. The ceph
# Update.ps1 is idempotent and only provisions hosts that are not yet part of the Ceph cluster.
try {
    $cephAddonsModule = "$PSScriptRoot\..\..\..\..\..\..\addons\addons.module.psm1"
    Import-Module $cephAddonsModule -DisableNameChecking
    if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'storage'; Implementation = 'ceph' })) -eq $true) {
        $cephUpdateScript = "$PSScriptRoot\..\..\..\..\..\..\addons\storage\ceph\Update.ps1"
        if (Test-Path $cephUpdateScript) {
            Write-Log '[NodeAdd] storage/ceph addon is enabled; reconciling Ceph OSD hosts for the newly added node...' -Console
            & $cephUpdateScript -ShowLogs:$ShowLogs
            if ($LASTEXITCODE -ne 0) {
                Write-Log "[NodeAdd] WARNING: Ceph OSD host reconciliation reported a failure (exit code $LASTEXITCODE)." -Console
            }
        }
    }
}
catch {
    Write-Log "[NodeAdd] WARNING: Could not reconcile Ceph OSD hosts after adding the node: $($_.Exception.Message)" -Console
}
