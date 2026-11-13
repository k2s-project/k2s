# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\cluster\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $clusterModule


function Add-WindowsWorkerNodeOnWindowsHost {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [switch] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
        [switch] $ForceOnlineInstallation = $false,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber'),
        [string] $JoinCommand = $(throw 'Argument missing: JoinCommand'),
        [parameter(Mandatory = $false, HelpMessage = 'The path to local builds of Kubernetes binaries')]
        [string] $K8sBinsPath = '',
        [parameter(Mandatory = $true, HelpMessage = 'Internal normalized effective install configuration path')]
        [string] $EffectiveInstallConfigPath
    )
    Stop-InstallIfNoMandatoryServiceIsRunning

    Write-Log 'Starting installation of K2s worker node on Windows host.'

    # Install loopback adapter for l2bridge
    New-DefaultLoopbackAdapter

    Write-Log 'Add vfp rules'
    $rootConfiguration = Get-RootConfigk2s
    $vfpRoutingRules = $rootConfiguration.psobject.properties['vfprules-k2s'].value | ConvertTo-Json
    Add-VfpRulesToWindowsNode -VfpRulesInJsonFormat $vfpRoutingRules

    $kubernetesVersion = Get-DefaultK8sVersion

    Initialize-WinNode -KubernetesVersion $kubernetesVersion `
        -HostGW:$true `
        -Proxy:"$Proxy" `
        -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation `
        -ForceOnlineInstallation $ForceOnlineInstallation `
        -PodSubnetworkNumber $PodSubnetworkNumber `
        -K8sBinsPath $K8sBinsPath

    Set-K2sWindowsKubeletOverride -EffectiveInstallConfigPath $EffectiveInstallConfigPath | Out-Null

    # join the cluster
    Write-Log "Preparing Kubernetes $KubernetesVersion by joining nodes" -Console

    Initialize-KubernetesCluster -AdditionalHooksDir $AdditionalHooksDir -PodSubnetworkNumber $PodSubnetworkNumber -JoinCommand $JoinCommand
}

function Start-WindowsWorkerNodeOnWindowsHost {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Do a full reset of the HNS network at start')]
        [switch] $ResetHns = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Use cached vSwitches')]
        [switch] $UseCachedK2sVSwitches,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber'),
        [string] $DnsServers = $(throw 'Argument missing: DnsServers')
    )

    $smallsetup = Get-RootConfigk2s
    $vfpRoutingRules = $smallsetup.psobject.properties['vfprules-k2s'].value | ConvertTo-Json
    Add-VfpRulesToWindowsNode -VfpRulesInJsonFormat $vfpRoutingRules

    Set-RoutesToWindowsWorkloads

    Start-WindowsWorkerNode -DnsServers $DnsServers -ResetHns:$ResetHns -AdditionalHooksDir $AdditionalHooksDir -UseCachedK2sVSwitches:$UseCachedK2sVSwitches -SkipHeaderDisplay:$SkipHeaderDisplay -PodSubnetworkNumber $PodSubnetworkNumber

    $clusterCIDRNextHop = Get-ConfiguredClusterCIDRNextHop -PodSubnetworkNumber $PodSubnetworkNumber
    Add-WinDnsProxyListenAddress -IpAddress $clusterCIDRNextHop

    Update-NodeLabelsAndTaints -WorkerMachineName $env:computername

    Set-KubeSwitchToPrivate
}

function Stop-WindowsWorkerNodeOnWindowsHost {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Cache vSwitches on stop')]
        [switch] $CacheK2sVSwitches,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing stop header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'Stopping K2s worker node on Windows host'
    }

    $clusterCIDRNextHop = Get-ConfiguredClusterCIDRNextHop -PodSubnetworkNumber $PodSubnetworkNumber
    Remove-WinDnsProxyListenAddress -IpAddress $clusterCIDRNextHop

    Stop-WindowsWorkerNode -PodSubnetworkNumber $PodSubnetworkNumber -AdditionalHooksDir $AdditionalHooksDir -CacheK2sVSwitches:$CacheK2sVSwitches -SkipHeaderDisplay:$SkipHeaderDisplay

    # Remove routes
    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRServicesWindows = $setupConfigRoot.psobject.properties['servicesCIDRWindows'].value
    route delete $clusterCIDRServicesWindows >$null 2>&1

    Remove-VfpRulesFromWindowsNode

    Write-Log 'K2s worker node on Windows host stopped.'
}

function Remove-WindowsWorkerNodeOnWindowsHost {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Do not purge all files')]
        [switch] $SkipPurge = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing uninstall header display')]
        [switch] $SkipHeaderDisplay = $false
    )

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'Removing K2s worker node on Windows host from cluster'
    }

    Write-Log 'Remove external switch'
    Remove-HostBridgeIpReservation -PodSubnetworkNumber '0'
    Remove-ExternalSwitch

    Write-Log 'Uninstall the worker node artifacts from the Windows host'
    Uninstall-WinNode -ShallowUninstallation $SkipPurge

    Write-Log 'Uninstall the loopback adapter'
    Uninstall-LoopbackAdapter

    Write-Log 'Remove vfp rules'
    Remove-VfpRulesFromWindowsNode

    Write-Log 'Uninstalling K2s worker node on Windows host done.'
}

function Start-WindowsWorkerNode {
    param (
        [string]$VfpRules,
        [string]$NetworkAdapterName,
        [string] $DnsServers = $(throw 'Argument missing: DnsServers'),
        [string]$PodNetworkGatewayIpAddress,
        [parameter(Mandatory = $false, HelpMessage = 'Do a full reset of the HNS network at start')]
        [switch] $ResetHns = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Use cached vSwitches')]
        [switch] $UseCachedK2sVSwitches,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )

    function Get-NeedsStopFirst () {
        if ((Get-Process 'flanneld' -ErrorAction SilentlyContinue) -or
                (Get-Process 'kubelet' -ErrorAction SilentlyContinue) -or
                (Get-Process 'kube-proxy' -ErrorAction SilentlyContinue)) {
            return $true
        }
        return $false
    }

    $startTime = Get-Date

    Write-Log 'Ensuring service log directories exists'
    $logRoot = Get-ConfiguredLogDirectory
    foreach ($sub in @('containerd', 'dnsproxy', 'dockerd', 'flanneld', 'httpproxy', 'kubelet', 'containers', 'pods', 'bridge', 'vfprules')) {
        EnsureDirectoryPathExists -DirPath (Join-Path -Path $logRoot -ChildPath $sub)
    }

    $kubePath = Get-KubePath
    Import-Module "$kubePath\smallsetup\hns.v2.psm1" -WarningAction:SilentlyContinue -Force

    if (Get-NeedsStopFirst) {
        Write-Log 'Stopping existing K8s system...'
        Stop-WindowsWorkerNode -PodSubnetworkNumber $PodSubnetworkNumber -AdditionalHooksDir $AdditionalHooksDir -CacheK2sVSwitches:$UseCachedK2sVSwitches -SkipHeaderDisplay:$SkipHeaderDisplay
        Start-Sleep 10
    }

    if ($ResetHns) {
        Write-Log 'Doing a full reset of the HNS network'
        Get-HNSNetwork | Remove-HNSNetwork
    }

    Test-ExistingExternalSwitch

    $adapterName = Get-L2BridgeName
    Write-Log "Using network adapter '$adapterName'"
    Enable-LoopbackAdapter

    Write-Log 'Starting windows services' -Console
    Start-Service -Name 'vmcompute'
    Start-Service -Name 'hns'

    New-ExternalSwitch -adapterName $adapterName -PodSubnetworkNumber $PodSubnetworkNumber

    Invoke-Hook -HookName 'BeforeStartK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

    Set-LoopbackAdapterExtendedProperties -AdapterName $adapterName -DnsServers $DnsServers
    
    Write-Log 'Starting Kubernetes services on the Windows node' -Console
    Start-ServiceAndSetToAutoStart -Name 'containerd'
    Start-ServiceAndSetToAutoStart -Name 'httpproxy'
    Confirm-LoopbackAdapterIP

    # Remove broken flannel routes on Loopbackk2s BEFORE starting flanneld.
    # Must run first because flanneld's host-gw backend actively maintains routes
    # and would re-add them if already running when we try to remove.
    Remove-FlannelConflictingRoutesOnLoopback

    # Flanneld must remain SERVICE_DEMAND_START. It creates cbr0 L2Bridge when it
    # doesn't find one, which races with Start-System.ps1 after unclean reboots.
    # Start it explicitly here (after cbr0 is created) without changing the start type.
    Start-Service 'flanneld' -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    Write-Log "Service 'flanneld' started"
    Start-ServiceAndSetToAutoStart -Name 'kubelet'
    Start-ServiceAndSetToAutoStart -Name 'kubeproxy'

    Wait-NetworkL2BridgeReady -PodSubnetworkNumber $PodSubnetworkNumber

    Add-HostBridgeIpReservation -PodSubnetworkNumber $PodSubnetworkNumber

    CheckFlannelConfig

    $endTime = Get-Date
    $durationSeconds = Get-DurationInSeconds -StartTime $startTime -EndTime $endTime
    Write-Log "K8s services started on the Windows node after $iteration attempts, total duration: ${durationSeconds} seconds"

    Invoke-Hook -HookName 'AfterStartK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir
}

function Wait-NetworkL2BridgeReady {
    Param(
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )
    $setupConfigRoot = Get-RootConfigk2s
    # loop to check the state of the services for Kubernetes
    $i = 0;
    $cbr0Stopwatch = [system.diagnostics.stopwatch]::StartNew()

    $SleepInLoop = 2
    $lastShownFlannelPid = 0
    $FlannelStartDetected = 0

    while ($true) {
        $i++

        # check flanneld
        $currentFlannelPid = (Get-Process flanneld -ErrorAction SilentlyContinue).Id
        Write-NodeServiceStatus -Iteration $i
        if ($null -ne $currentFlannelPid -and $currentFlannelPid -ne $lastShownFlannelPid) {
            $FlannelStartDetected++
            if ($FlannelStartDetected -gt 1) {
                Write-Output "           PID for flanneld service: $currentFlannelPid  (restarted after failure)"
            }
            else {
                Write-Output "           PID for flanneld service: $currentFlannelPid"
            }
            $lastShownFlannelPid = $currentFlannelPid
        }

        if (Test-NetworkL2BridgeReady -PodSubnetworkNumber $PodSubnetworkNumber) {
            $l2BridgeSwitchName = Get-L2BridgeSwitchName
            $endpointInterfaceAlias = "vEthernet ($($l2BridgeSwitchName)_ep)"
            $l2BridgeInterfaceIndex = (Get-NetAdapter -Name $endpointInterfaceAlias -IncludeHidden -ErrorAction Stop).ifIndex
            Write-Output "           OK: $endpointInterfaceAlias is ready"
            Write-Output "`nOK: $endpointInterfaceAlias is ready"

            Set-NetIPInterface -InterfaceIndex $l2BridgeInterfaceIndex -InterfaceMetric 101
            Write-Output "Index for interface $l2BridgeSwitchName : ($l2BridgeInterfaceIndex) -> metric 101"

            Set-RoutesToWindowsWorkloads

            Write-Output "Routing entries added.`n"

            # remove routes to non existent gateways
            $cbr0Gateway = $setupConfigRoot.psobject.properties['cbr0Gateway'].value
            Write-Log "Remove obsolete route to $cbr0Gateway"
            Remove-NetRoute -DestinationPrefix 0.0.0.0/0 -NextHop $cbr0Gateway -Confirm:$false -ErrorAction SilentlyContinue
            $loopbackGateway = $setupConfigRoot.psobject.properties['loopbackGateway'].value
            Write-Log "Remove obsolete route to $loopbackGateway"
            Remove-NetRoute -DestinationPrefix 0.0.0.0/0 -NextHop $loopbackGateway -Confirm:$false -ErrorAction SilentlyContinue

            Write-Output "Networking setup done.`n"
            break;
        }
        elseif ($cbr0Stopwatch.Elapsed.TotalSeconds -gt 150) {
            Stop-Service flanneld -ErrorAction SilentlyContinue
            Write-NetworkL2BridgeDiagnostics -PodSubnetworkNumber $PodSubnetworkNumber
            Write-Output "FAIL: cbr0 endpoint did not become ready, timeout. Aborting.`n"
            $flannelLogHint = Join-Path -Path (Get-ConfiguredLogDirectory) -ChildPath 'flanneld'
            Write-Output "For troubleshooting look into the log file $flannelLogHint"
            Write-Output ''
            throw 'Timeout: flanneld failed to create a healthy cbr0 endpoint and route'
        }

        Start-Sleep -s $SleepInLoop
    }
}

function Test-NetworkL2BridgeReady {
    Param(
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )

    $l2BridgeSwitchName = Get-L2BridgeSwitchName
    $endpointInterfaceAlias = "vEthernet ($($l2BridgeSwitchName)_ep)"
    $adapter = Get-NetAdapter -Name $endpointInterfaceAlias -IncludeHidden -ErrorAction SilentlyContinue
    if ($null -eq $adapter) {
        return $false
    }

    if ($adapter.Status -eq 'Disabled') {
        Write-Log "[Network] Enabling disabled cbr0 endpoint adapter '$endpointInterfaceAlias'"
        Enable-NetAdapter -Name $endpointInterfaceAlias -Confirm:$false -ErrorAction SilentlyContinue
        $adapter = Get-NetAdapter -Name $endpointInterfaceAlias -IncludeHidden -ErrorAction SilentlyContinue
    }
    if ($null -eq $adapter -or $adapter.Status -notin @('Up', 'Disconnected')) {
        return $false
    }

    $expectedIpAddress = Get-ConfiguredClusterCIDRNextHop -PodSubnetworkNumber $PodSubnetworkNumber
    $endpointAddress = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $expectedIpAddress } |
        Select-Object -First 1
    if ($null -eq $endpointAddress) {
        return $false
    }

    $podSubnet = Get-ConfiguredClusterCIDRHost -PodSubnetworkNumber $PodSubnetworkNumber
    $connectedRoute = Get-NetRoute -DestinationPrefix $podSubnet -InterfaceIndex $adapter.ifIndex `
        -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -eq '0.0.0.0' } |
        Select-Object -First 1
    if ($null -eq $connectedRoute) {
        Write-Log "[Network] Restoring missing on-link route '$podSubnet' on '$endpointInterfaceAlias'"
        try {
            New-NetRoute -DestinationPrefix $podSubnet -InterfaceIndex $adapter.ifIndex -NextHop '0.0.0.0' `
                -RouteMetric 5 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Log "[Network] Failed to restore route '$podSubnet' on '$endpointInterfaceAlias': $($_.Exception.Message)"
            return $false
        }
    }

    return $true
}

function Write-NetworkL2BridgeDiagnostics {
    Param(
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )

    $l2BridgeSwitchName = Get-L2BridgeSwitchName
    $endpointInterfaceAlias = "vEthernet ($($l2BridgeSwitchName)_ep)"
    $podSubnet = Get-ConfiguredClusterCIDRHost -PodSubnetworkNumber $PodSubnetworkNumber
    Write-Log "[Network] cbr0 endpoint diagnostics for '$endpointInterfaceAlias' and '$podSubnet'"
    Get-NetAdapter -Name $endpointInterfaceAlias -IncludeHidden -ErrorAction SilentlyContinue | Format-List * | Out-String | Write-Log
    Get-NetIPAddress -InterfaceAlias $endpointInterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Format-List * | Out-String | Write-Log
    Get-NetRoute -DestinationPrefix $podSubnet -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Format-List * | Out-String | Write-Log
}


function Stop-WindowsWorkerNode {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Cache vSwitches on stop')]
        [switch] $CacheK2sVSwitches,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing stop header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )

    Write-Log 'Stopping Kubernetes services on the Windows node' -Console

    Stop-ServiceAndSetToManualStart 'kubeproxy'
    Stop-ServiceAndSetToManualStart 'kubelet'
    Stop-ServiceAndSetToManualStart 'flanneld'
    Stop-ServiceAndSetToManualStart 'httpproxy'
    Stop-ServiceAndSetToManualStart 'containerd'

    $shallRestartDocker = $false
    if ($(Get-Service -Name 'docker' -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Stop-ServiceProcess 'docker' 'dockerd'
        $shallRestartDocker = $true
    }

    Write-Log 'Stopping K8s network' -Console

    Remove-HostBridgeIpReservation -PodSubnetworkNumber $PodSubnetworkNumber

    Restart-WinService 'hns'

    Invoke-Hook -HookName 'BeforeStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

    if (!$CacheK2sVSwitches) {
        # Remove the external switch
        Remove-ExternalSwitch

        Write-Log 'Delete network policies'
        Get-HnsPolicyList | Remove-HnsPolicyList -ErrorAction SilentlyContinue
        Write-Log 'Cleaning up registry for NicList'
        Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\VMSMP\Parameters\NicList' | Remove-Item -ErrorAction SilentlyContinue | Out-Null
    }

    Write-Log 'Removing old logfiles'
    $logRoot = Get-ConfiguredLogDirectory
    Remove-Item -Force (Join-Path -Path $logRoot -ChildPath 'flanneld\flannel*.*') -Recurse -Confirm:$False -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path -Path $logRoot -ChildPath 'kubelet\*.*') -Recurse -Confirm:$False -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path -Path $logRoot -ChildPath 'kubeproxy\*.*') -Recurse -Confirm:$False -ErrorAction SilentlyContinue

    if ($shallRestartDocker) {
        Start-ServiceProcess 'docker'
    }

    $podNetworkCIDR = Get-ConfiguredClusterCIDRHost -PodSubnetworkNumber $PodSubnetworkNumber
    # Remove routes
    route delete $podNetworkCIDR >$null 2>&1

    Invoke-Hook -HookName 'AfterStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

    Disable-LoopbackAdapter

    Write-Log 'K2s worker node on Windows host stopped.'
}

function CheckFlannelConfig {
    $flannelFile = "$(Get-InstallationDriveLetter):\run\flannel\subnet.env"
    $existsFlannelFile = Test-Path -Path $flannelFile
    if ( $existsFlannelFile ) {
        Write-Log "Flannel file $flannelFile exists"
        return
    }
    # only in case that we used another drive than C for the installation
    if ( ($(Get-InstallationDriveLetter) -ne $(Get-SystemDriveLetter))) {
        $i = 0
        $flannelFileSource = "$(Get-SystemDriveLetter):\run\flannel\subnet.env"
        Write-Log "Check $flannelFileSource file creation, this can take minutes depending on your network setup ..."
        while ($true) {
            $i++
            Write-Log "flannel handling loop (iteration #$i):"
            if ( Test-Path -Path $flannelFileSource ) {
                $targetPath = "$(Get-InstallationDriveLetter):\run\flannel"
                New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                Copy-Item -Path $flannelFileSource -Destination $targetPath -Force | Out-Null
                break
            }
            Start-Sleep -s 5

            # End the loop
            if ($i -eq 100) {
                throw "Fatal: Flannel failed to create file: $flannelFileSource for target drive $(Get-InstallationDriveLetter):\run\flannel\subnet.env !"
            }
        }
    }
}

function EnsureDirectoryPathExists(
    [string]$DirPath
) {
    if (-not (Test-Path $DirPath)) {
        New-Item -Path $DirPath -ItemType Directory -Force | Out-Null
    }
}

function Set-RoutesToKubemaster {
    $ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP

    $switchAddresses = @(Get-NetIPAddress -IPAddress $windowsHostIpAddress -AddressFamily IPv4 -ErrorAction Stop)
    if ($switchAddresses.Count -ne 1) {
        throw "Cannot identify a unique control-plane switch interface for $windowsHostIpAddress"
    }
    $switchIndex = $switchAddresses[0].InterfaceIndex
    $connectedRoute = Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop |
        Where-Object { $_.DestinationPrefix -eq $ipControlPlaneCIDR -and $_.InterfaceIndex -eq $switchIndex -and $_.NextHop -eq '0.0.0.0' }
    if (-not $connectedRoute) {
        Write-Log "[Routes] Restoring on-link route to $ipControlPlaneCIDR on interface $switchIndex"
        try {
            New-NetRoute -DestinationPrefix $ipControlPlaneCIDR -InterfaceIndex $switchIndex -NextHop '0.0.0.0' `
                -RouteMetric 3 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
        }
        catch {
            if ($_.CategoryInfo.Category -ne [System.Management.Automation.ErrorCategory]::ResourceExists -and
                $_.FullyQualifiedErrorId -notmatch '^Windows System Error (183|5010),') {
                throw
            }
            $connectedRoute = Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop |
                Where-Object { $_.DestinationPrefix -eq $ipControlPlaneCIDR -and $_.InterfaceIndex -eq $switchIndex -and $_.NextHop -eq '0.0.0.0' }
            if (-not $connectedRoute) {
                throw
            }
            Write-Log "[Routes] On-link route to $ipControlPlaneCIDR on interface $switchIndex was created concurrently"
        }
    }

    foreach ($policyStore in @('PersistentStore', 'ActiveStore')) {
        $obsoleteRoutes = Get-NetRoute -PolicyStore $policyStore -ErrorAction Stop |
            Where-Object { $_.DestinationPrefix -eq $ipControlPlaneCIDR -and $_.NextHop -eq $windowsHostIpAddress }
        foreach ($obsoleteRoute in $obsoleteRoutes) {
            Write-Log "[Routes] Removing obsolete route to $ipControlPlaneCIDR via $windowsHostIpAddress from $policyStore"
            $obsoleteRoute | Remove-NetRoute -Confirm:$false -ErrorAction Stop
        }
    }
}

function Set-RoutesToLinuxWorkloads {
    # routes for Linux pods
    $ipControlPlane = Get-ConfiguredIPControlPlane
    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRMaster = $setupConfigRoot.psobject.properties['podNetworkMasterCIDR'].value
    $clusterCIDRServices = $setupConfigRoot.psobject.properties['servicesCIDR'].value
    $clusterCIDRServicesLinux = $setupConfigRoot.psobject.properties['servicesCIDRLinux'].value
    Write-Log "Remove obsolete route to $clusterCIDRMaster"
    route delete $clusterCIDRMaster >$null 2>&1
    Write-Log "Add route to Linux master pods CIDR:$clusterCIDRMaster with metric 4"
    route -p add $clusterCIDRMaster $ipControlPlane METRIC 4 | Out-Null
    # routes for Linux services
    route delete $clusterCIDRServices >$null 2>&1
    Write-Log "Remove obsolete route to $clusterCIDRServicesLinux"
    route delete $clusterCIDRServicesLinux >$null 2>&1
    Write-Log "Add route to Linux Services CIDR:$clusterCIDRServicesLinux with metric 6"
    route -p add $clusterCIDRServicesLinux $ipControlPlane METRIC 6 | Out-Null
}

function Set-RoutesToWindowsWorkloads {
    $ipControlPlane = Get-ConfiguredIPControlPlane
    $setupConfigRoot = Get-RootConfigk2s
    $PodSubnetworkNumber = '1'
    $clusterCIDRWorker = Get-ConfiguredClusterCIDRHost -PodSubnetworkNumber $PodSubnetworkNumber 
    $clusterCIDRNextHop = Get-ConfiguredClusterCIDRNextHop -PodSubnetworkNumber $PodSubnetworkNumber 
    # routes for Windows pods
    Write-Log "Remove obsolete route to $clusterCIDRWorker"
    route delete $clusterCIDRWorker >$null 2>&1
    Write-Log "Add route to Windows Pods on host CIDR:$clusterCIDRWorker with metric 5"
    route -p add $clusterCIDRWorker $clusterCIDRNextHop METRIC 5 | Out-Null
    $clusterCIDRServicesWindows = $setupConfigRoot.psobject.properties['servicesCIDRWindows'].value
    # routes for services
    Write-Log "Remove obsolete route to $clusterCIDRServicesWindows"
    route delete $clusterCIDRServicesWindows >$null 2>&1
    Write-Log "Add route 1 to Windows Services CIDR:$clusterCIDRServicesWindows with metric 7"
    route -p add $clusterCIDRServicesWindows $ipControlPlane METRIC 7 | Out-Null
}

function Repair-K2sRoutes {
    Set-RoutesToKubemaster
    Set-RoutesToLinuxWorkloads
    Set-RoutesToWindowsWorkloads
    # TODO: add routes for additional nodes
}

<#
.SYNOPSIS
    Removes flannel-added routes on the Loopbackk2s interface that conflict with k2s static routes.
.DESCRIPTION
    Flannel's host-gw backend adds routes for remote subnets via the interface specified
    by --iface (Loopbackk2s). When the remote node's gateway IP (e.g. 172.19.1.100) is
    on a different L2 segment (e.g. WSL or KubeSwitch), the route is topologically
    invalid - the gateway is unreachable from Loopbackk2s. This creates a lower-metric
    route that shadows the correct k2s static route, breaking cross-node pod connectivity.
    This function removes such conflicting routes on the Loopbackk2s interface.
#>
function Remove-FlannelConflictingRoutesOnLoopback {
    if (Get-L2BridgeAdapterOverride) {
        # Only the loopback adapter is topologically unable to reach the remote node
        # gateways. On a real NIC flannel's host-gw routes are valid and must stay.
        Write-Log '[FlannelRoutes] L2 bridge is not on a loopback adapter, skipping route cleanup'
        return
    }
    $adapterName = Get-L2BridgeName
    $adapter = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
    if ($null -eq $adapter) {
        Write-Log '[FlannelRoutes] Loopback adapter not found, skipping route cleanup'
        return
    }
    $loopbackIfIndex = $adapter.ifIndex

    $podNetworkCIDR = Get-ConfiguredClusterCIDR
    if ([string]::IsNullOrWhiteSpace($podNetworkCIDR)) {
        Write-Log '[FlannelRoutes] podNetworkCIDR not configured, skipping route cleanup'
        return
    }

    # Parse the cluster-wide pod CIDR (e.g. 172.20.0.0/16) to match all subnets within it
    $cidrParts = $podNetworkCIDR.Split('/')
    $podNetworkAddress = [System.Net.IPAddress]::Parse($cidrParts[0])
    $podNetworkPrefixLength = [int]$cidrParts[1]
    $podNetworkBytes = $podNetworkAddress.GetAddressBytes()

    # Find all routes on the Loopbackk2s interface whose destination falls within the pod CIDR.
    # Flannel's host-gw backend adds per-node subnet routes (e.g. 172.20.0.0/24, 172.20.2.0/24)
    # on this interface, but the gateway IP is on a different L2 segment, making them invalid.
    $allRoutes = Get-NetRoute -InterfaceIndex $loopbackIfIndex -ErrorAction SilentlyContinue
    $conflictingRoutes = $allRoutes | Where-Object {
        if ($_.DestinationPrefix -notmatch '^\d+\.\d+\.\d+\.\d+/\d+$') { return $false }
        $destParts = $_.DestinationPrefix.Split('/')
        $destAddress = [System.Net.IPAddress]::Parse($destParts[0])
        $destBytes = $destAddress.GetAddressBytes()

        # Check if destination address falls within the pod network CIDR
        $fullBytes = [math]::Floor($podNetworkPrefixLength / 8)
        $match = $true
        for ($i = 0; $i -lt $fullBytes; $i++) {
            if ($destBytes[$i] -ne $podNetworkBytes[$i]) { $match = $false; break }
        }
        if ($match -and ($podNetworkPrefixLength % 8) -ne 0) {
            $remainingBits = $podNetworkPrefixLength % 8
            $mask = [byte]((0xFF -shl (8 - $remainingBits)) -band 0xFF)
            if (($destBytes[$fullBytes] -band $mask) -ne ($podNetworkBytes[$fullBytes] -band $mask)) { $match = $false }
        }
        return $match
    }

    if ($null -ne $conflictingRoutes) {
        foreach ($route in $conflictingRoutes) {
            Write-Log "[FlannelRoutes] Removing conflicting route: $($route.DestinationPrefix) via $($route.NextHop) on interface $loopbackIfIndex (metric $($route.RouteMetric))" -Console
            Remove-NetRoute -DestinationPrefix $route.DestinationPrefix -InterfaceIndex $loopbackIfIndex -NextHop $route.NextHop -Confirm:$false -ErrorAction SilentlyContinue
        }
    } else {
        Write-Log '[FlannelRoutes] No conflicting routes found on Loopbackk2s interface'
    }
}

Export-ModuleMember -Function Add-WindowsWorkerNodeOnWindowsHost,
Remove-WindowsWorkerNodeOnWindowsHost,
Start-WindowsWorkerNodeOnWindowsHost,
Stop-WindowsWorkerNodeOnWindowsHost,
Wait-NetworkL2BridgeReady,
Test-NetworkL2BridgeReady,
Write-NetworkL2BridgeDiagnostics,
Repair-K2sRoutes,
Remove-FlannelConflictingRoutesOnLoopback,
Set-RoutesToKubemaster,
Set-RoutesToLinuxWorkloads,
Set-RoutesToWindowsWorkloads
