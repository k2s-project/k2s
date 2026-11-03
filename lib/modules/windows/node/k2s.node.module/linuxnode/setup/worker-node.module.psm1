# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule =   "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$networkModule = "$PSScriptRoot\..\..\windowsnode\network\network.module.psm1"
$gpuWorkerModule = "$PSScriptRoot\gpu-worker.module.psm1"

Import-Module $infraModule, $clusterModule, $networkModule, $gpuWorkerModule

function Repair-LinuxWorkerNodeRegistriesConfig {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    $duplicateCountOutput = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "if [ -f /etc/containers/registries.conf ]; then grep -c '^[[:space:]]*unqualified-search-registries[[:space:]]*=' /etc/containers/registries.conf 2>/dev/null || echo 0; else echo 0; fi" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output.Trim()
    $duplicateCount = 0
    [void][int]::TryParse($duplicateCountOutput, [ref]$duplicateCount)

    if ($duplicateCount -le 1) {
        Write-Log "[RegistryConfig] registries.conf on node $IpAddress has $duplicateCount unqualified-search-registries entries, no repair needed."
        return
    }

    # Remove all unqualified-search-registries lines and add a single one at the top
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo sh -c 'grep -v \"^[[:space:]]*unqualified-search-registries[[:space:]]*=\" /etc/containers/registries.conf > /tmp/registries.conf.k2s; echo \"unqualified-search-registries = [\\\"docker.io\\\", \\\"quay.io\\\"]\" | cat - /tmp/registries.conf.k2s > /tmp/registries.conf.final; mv /tmp/registries.conf.final /etc/containers/registries.conf; rm -f /tmp/registries.conf.k2s'" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
    Write-Log "[RegistryConfig] Restarting crio after registries.conf normalization on node $IpAddress."
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl restart crio' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
}

function Add-LinuxWorkerNodeRegistryMirrors {
    <#
    .SYNOPSIS
        Configures CRI-O registry mirrors on an external Linux worker node.
    .DESCRIPTION
        External (bare-metal / existing-VM) worker nodes are not built from the K2s node
        base image, so 'AddRegistryMirrors' (which runs during New-VmImageForKubernetesNode)
        never configures their CRI-O. Without the mirror entries, CRI-O resolves images such
        as quay.io/* and registry.k8s.io/* against the public internet instead of the local
        K2s mirror, causing offline enablement (e.g. Ceph CSI) to attempt network pulls.

        This writes the same /etc/containers/registries.conf.d/*.conf mirror entries that the
        managed node receives, using the mirrorRegistries block from cfg/config.json, and
        restarts crio. Idempotent: re-running overwrites the per-registry drop-in files.
    #>
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    $mirrorRegistries = Get-MirrorRegistries
    if ($null -eq $mirrorRegistries -or @($mirrorRegistries).Count -eq 0) {
        Write-Log "[RegistryMirror] No mirrorRegistries configured in config.json, skipping mirror setup on node $IpAddress."
        return
    }

    Write-Log "[RegistryMirror] Configuring CRI-O registry mirrors on node $IpAddress" -Console

    $executeRemoteCommand = { param($Command = $(throw 'Argument missing: Command'))
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute $Command -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
    }

    &$executeRemoteCommand 'sudo mkdir -p /etc/containers/registries.conf.d'
    foreach ($registry in $mirrorRegistries) {
        $Name = $registry.registry
        $Mirror = $registry.mirror
        $fileName = $Name -replace ':', ''
        Write-Log "[RegistryMirror] Mapping registry '$Name' to mirror '$Mirror' on node $IpAddress."
        &$executeRemoteCommand "echo -e `'[[registry]]\nlocation=\""$Name\""\ninsecure=true`' | sudo tee /etc/containers/registries.conf.d/$fileName.conf"
        &$executeRemoteCommand "echo -e `'[[registry.mirror]]\nlocation=\""$Mirror\""\ninsecure=true`' | sudo tee -a /etc/containers/registries.conf.d/$fileName.conf"
    }
    &$executeRemoteCommand 'sudo systemctl daemon-reload'
    Write-Log "[RegistryMirror] Restarting crio after mirror configuration on node $IpAddress."
    &$executeRemoteCommand 'sudo systemctl restart crio'
}

function Clear-LinuxWorkerNodeRoutes {
    <#
    .SYNOPSIS
        Cleans only Kubernetes-related routes on a Linux worker node.
    .DESCRIPTION
        Removes control plane CIDR route, pod-network routes (e.g. /24 and /16),
        and cni0 interface if present. Safe to call multiple times.
    #>
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    Write-Log "[RouteCleanup] Cleaning Kubernetes-related routes on node $IpAddress" -Console

    # Control plane route (e.g. 172.19.1.0/24)
    # Keep kernel-connected route (proto kernel scope link), delete only manually-added route.
    $controlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
    $controlPlaneRoute = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "ip route show $controlPlaneCIDR | head -1" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output.Trim()
    if (-not [string]::IsNullOrWhiteSpace($controlPlaneRoute)) {
        if ($controlPlaneRoute -match 'proto kernel|scope link') {
            Write-Log "[RouteCleanup] Keeping connected route: $controlPlaneRoute"
        } else {
            Write-Log "[RouteCleanup] Deleting route: $controlPlaneCIDR"
            (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route delete $controlPlaneCIDR" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
        }
    } else {
        Write-Log "[RouteCleanup] Route $controlPlaneCIDR not found, skipping."
    }

    # Pod routes (e.g. 172.20.0.0/24 via 172.19.1.100 and 172.20.0.0/16 via 172.19.1.1)
    $podNetworkCIDR = Get-ConfiguredClusterCIDR
    $podNetworkPrefix = (($podNetworkCIDR -split '/')[0] -split '\.')[0..1] -join '\.'
    $podRoutes = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "ip route | grep -E '^$podNetworkPrefix\.'" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output
    if (-not [string]::IsNullOrWhiteSpace($podRoutes)) {
        $podRoutes -split "`n" | ForEach-Object {
            $routeLine = $_.Trim()
            $route = ($routeLine -split '\s')[0]
            if (-not [string]::IsNullOrWhiteSpace($route)) {
                if ($routeLine -match 'proto kernel|scope link') {
                    Write-Log "[RouteCleanup] Keeping connected route: $routeLine"
                } else {
                    Write-Log "[RouteCleanup] Deleting route: $route"
                    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route delete $route" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
                }
            }
        }
    } else {
        Write-Log "[RouteCleanup] No pod routes matching $podNetworkPrefix.* found, skipping."
    }

    # cni0 interface (created by flannel)
    $cni0Exists = -not [string]::IsNullOrWhiteSpace((Invoke-CmdOnVmViaSSHKey -CmdToExecute "ip link show cni0 2>/dev/null" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output)
    if ($cni0Exists) {
        Write-Log "[RouteCleanup] Deleting interface: cni0"
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip link delete cni0" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
    } else {
        Write-Log "[RouteCleanup] cni0 not found, skipping."
    }

    Write-Log "[RouteCleanup] Kubernetes route cleanup completed" -Console
}

function Restore-LinuxWorkerNodeRoutes {
    <#
    .SYNOPSIS
        Restores Kubernetes-related routes on a Linux bare-metal worker node.
    .DESCRIPTION
        Re-adds control plane CIDR route and pod-network route via Windows host.
        These routes may be lost after node reboot or network restart.
        Used during Start-LinuxWorkerNode for bare-metal (HOST) nodes.
    #>
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $NodeName = $(throw 'Argument missing: NodeName')
    )

    Write-Log "[RouteRestore] Restoring Kubernetes routes on bare-metal node $NodeName ($IpAddress)" -Console

    # Get Windows host IP that can reach this node
    $loopbackAdapter = Get-L2BridgeName
    $windowsHostIpAddress = Get-HostIpAddressForRemoteIp -RemoteIpAddress $IpAddress -ExcludeNetworkInterfaceName $loopbackAdapter

    if ([string]::IsNullOrWhiteSpace($windowsHostIpAddress)) {
        Write-Log "[RouteRestore] WARNING: Could not determine Windows host IP for node $IpAddress, skipping route restoration"
        return
    }

    Write-Log "[RouteRestore] Using Windows host IP: $windowsHostIpAddress"

    # Restore route to control plane network
    $controlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
    $controlPlaneRouteExists = -not [string]::IsNullOrWhiteSpace((Invoke-CmdOnVmViaSSHKey -CmdToExecute "ip route show $controlPlaneCIDR | grep -v 'proto kernel'" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output)
    if ($controlPlaneRouteExists) {
        Write-Log "[RouteRestore] Route to $controlPlaneCIDR already exists, skipping."
    } else {
        Write-Log "[RouteRestore] Adding route to control plane: $controlPlaneCIDR via $windowsHostIpAddress"
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route add $controlPlaneCIDR via $windowsHostIpAddress" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
    }

    # Restore route to pod network
    $podNetworkCIDR = Get-ConfiguredClusterCIDR
    $podNetworkRouteExists = -not [string]::IsNullOrWhiteSpace((Invoke-CmdOnVmViaSSHKey -CmdToExecute "ip route show $podNetworkCIDR | grep -v 'proto kernel'" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output)
    if ($podNetworkRouteExists) {
        Write-Log "[RouteRestore] Route to $podNetworkCIDR already exists, skipping."
    } else {
        Write-Log "[RouteRestore] Adding route to pod network: $podNetworkCIDR via $windowsHostIpAddress"
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route add $podNetworkCIDR via $windowsHostIpAddress" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
    }

    # Ensure IP forwarding is enabled on Windows host interface
    $networkInterfaceName = (Get-NetIPAddress | Where-Object { $_.AddressFamily -eq "IPv4" -and ($_.IPAddress -match [regex]::Escape($windowsHostIpAddress))} | Select-Object -ExpandProperty InterfaceAlias)
    if (-not [string]::IsNullOrWhiteSpace($networkInterfaceName)) {
        netsh int ipv4 set int $networkInterfaceName forwarding=enabled | Out-Null
        Write-Log "[RouteRestore] Enabled IP forwarding on interface '$networkInterfaceName'"
    }

    Write-Log "[RouteRestore] Route restoration completed" -Console
}

<#
.SYNOPSIS
    Creates persistent routes on a Linux bare-metal worker node.
.DESCRIPTION
    Creates a systemd service that adds K2s routes at boot time.
    This ensures routes survive reboots, DHCP renewals, and network restarts.
#>
function Add-PersistentLinuxWorkerNodeRoutes {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $WindowsHostIpAddress = $(throw 'Argument missing: WindowsHostIpAddress')
    )

    $controlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
    $podNetworkCIDR = Get-ConfiguredClusterCIDR

    Write-Log "[PersistentRoutes] Creating persistent routes on bare-metal node $IpAddress" -Console

    # Key design decisions:
    # - PartOf=systemd-networkd.service: Ensures this service restarts when networkd restarts
    #   (networkd flushes manually-added routes on restart, so we must re-add them)
    # - After=systemd-networkd.service: Ensures routes are added after network is configured
    # - No ExecStop that deletes routes: Avoids accidental route deletion on service stop/restart
    # - Retry loop: DHCP may not be fully ready when network-online.target is reached
    $serviceLines = @(
        "[Unit]"
        "Description=K2s Kubernetes Routes"
        "After=network-online.target systemd-networkd.service"
        "Wants=network-online.target"
        "PartOf=systemd-networkd.service"
        ""
        "[Service]"
        "Type=oneshot"
        "RemainAfterExit=yes"
        "ExecStart=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do ping -c 1 -W 2 $WindowsHostIpAddress >/dev/null 2>&1 && break; sleep 2; done; ip route replace $controlPlaneCIDR via $WindowsHostIpAddress; ip route replace $podNetworkCIDR via $WindowsHostIpAddress'"
        ""
        "[Install]"
        "WantedBy=multi-user.target"
    )
    # Join with LF and encode as base64 to avoid line-ending/escaping issues over SSH
    $serviceContent = $serviceLines -join "`n"
    $base64Content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($serviceContent))

    # Decode on Linux side and write to file using sudo tee
    $createServiceCmd = "echo '$base64Content' | base64 -d | sudo tee /etc/systemd/system/k2s-routes.service > /dev/null"
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute $createServiceCmd -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

    # Enable and start the service
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo systemctl daemon-reload && sudo systemctl enable k2s-routes.service && sudo systemctl start k2s-routes.service" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

    Write-Log "[PersistentRoutes] Persistent routes service created and enabled" -Console
}

<#
.SYNOPSIS
    Removes persistent routes service from a Linux bare-metal worker node.
#>
function Remove-PersistentLinuxWorkerNodeRoutes {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    Write-Log "[PersistentRoutes] Removing persistent routes service from node $IpAddress" -Console
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo systemctl stop k2s-routes.service 2>/dev/null; sudo systemctl disable k2s-routes.service 2>/dev/null; sudo rm -f /etc/systemd/system/k2s-routes.service; sudo systemctl daemon-reload" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
}

function Add-LinuxWorkerNode {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $WindowsHostIpAddress = $(throw 'Argument missing: WindowsHostIpAddress'),
        [string] $Proxy = '',
        [string] $AdditionalHooksDir = '',
        [string] $installedDistributionOnRemoteComputer = $(throw 'Argument missing: installedDistributionOnRemoteComputer'),
        [string] $NodePackagePath = '',
        [ValidateSet('HOST', 'VM-EXISTING')]
        [string] $NodeType = 'HOST',
        [string] $VmName = ''  # Hyper-V VM name (for VM-EXISTING nodes)
    )

    $nodeParams = @{
        Name = $NodeName
        IpAddress = $IpAddress
        UserName = $UserName
        Proxy = $Proxy
        NodeType = $NodeType
        Role = 'worker'
        OS = 'linux'
        PodCIDR = '' # will be filled during start of node
    }
    
    # Add VmName for VM-EXISTING nodes (needed to find VM during cluster start)
    if ($VmName) {
        $nodeParams.VmName = $VmName
    }
    
    Add-NodeConfig @nodeParams

    # Config entry is preserved on failure; see 'k2s node remove' (#2789).
    try {
        Write-Log "Installing node essentials" -Console

        Write-Log "Prepare the computer $IpAddress for provisioning"

        Invoke-Debian13NodeHardening -Stage prepare -InstalledDistribution $installedDistributionOnRemoteComputer -UserName $UserName -IpAddress $IpAddress

        Set-UpComputerBeforeProvisioning -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy -InstalledDistribution $installedDistributionOnRemoteComputer

        # GPU detection: Check if NVIDIA GPU is present on the node (for both online and offline modes)
        # This determines whether to copy/install GPU packages and images
        $gpuDetected = $false
        try {
            $findNvidiaSmiCmd = 'for p in nvidia-smi /usr/lib/wsl/lib/nvidia-smi /usr/bin/nvidia-smi /usr/local/bin/nvidia-smi; do command -v "$p" >/dev/null 2>&1 && "$p" -L 2>/dev/null && exit 0; done; exit 1'
            $nvidiaSmiCheck = Invoke-CmdOnVmViaSSHKey -CmdToExecute $findNvidiaSmiCmd -UserName $UserName -IpAddress $IpAddress -Timeout 10 -IgnoreErrors
            if ($nvidiaSmiCheck.Success -and $nvidiaSmiCheck.Output -match 'GPU \d+:') {
                $gpuInfo = $nvidiaSmiCheck.Output.Trim()
                Write-Log "[GPU] NVIDIA GPU detected on node ${IpAddress}: $gpuInfo" -Console
                $gpuDetected = $true
            } else {
                Write-Log "[GPU] No NVIDIA GPU detected on node $IpAddress - GPU packages will be skipped" -Console
            }
        } catch {
            Write-Log "[GPU] GPU detection failed: $_ - GPU packages will be skipped" -Console
        }

        Install-LinuxPackagesAndAddContainerImagesIntoRemoteComputer -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy -InstalledDistribution $installedDistributionOnRemoteComputer -NodePackagePath $NodePackagePath -SkipGpuPackages:(!$gpuDetected)

        Invoke-Debian13NodeHardening -Stage cleanup -InstalledDistribution $installedDistributionOnRemoteComputer -UserName $UserName -IpAddress $IpAddress

        Repair-LinuxWorkerNodeRegistriesConfig -UserName $UserName -IpAddress $IpAddress

        # Configure CRI-O registry mirrors so this external node resolves images (e.g.
        # quay.io/*, registry.k8s.io/*) against the local K2s mirror instead of the
        # public internet. Managed nodes get this via AddRegistryMirrors during base
        # image build; external nodes must have it applied here during join.
        Add-LinuxWorkerNodeRegistryMirrors -UserName $UserName -IpAddress $IpAddress

        # Cleanup Kubernetes-related routes before add/join flow
        Clear-LinuxWorkerNodeRoutes -UserName $UserName -IpAddress $IpAddress

        $doBeforeJoining = {
            Write-Log "Configuring networking for adding the node" -Console
            # add a route to the cluster network over the Windows host IP address
            $controlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
            $controlPlaneRouteExists = -not [string]::IsNullOrWhiteSpace((Invoke-CmdOnVmViaSSHKey -CmdToExecute "ip route show $controlPlaneCIDR" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output)
            if ($controlPlaneRouteExists) {
                Write-Log "[Route] Route $controlPlaneCIDR already exists, skipping add."
            } else {
                (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route add $controlPlaneCIDR via $WindowsHostIpAddress" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
            }

            $podNetworkCIDR = Get-ConfiguredClusterCIDR
            $podNetworkRouteExists = -not [string]::IsNullOrWhiteSpace((Invoke-CmdOnVmViaSSHKey -CmdToExecute "ip route show $podNetworkCIDR" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output)
            if ($podNetworkRouteExists) {
                Write-Log "[Route] Route $podNetworkCIDR already exists, skipping add."
            } else {
                (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route add $podNetworkCIDR via $WindowsHostIpAddress" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
            }

            $networkInterfaceName = (Get-NetIPAddress | Where-Object { $_.AddressFamily -eq "IPv4" -and ($_.IPAddress -match $WindowsHostIpAddress)} | Select-Object -ExpandProperty InterfaceAlias)
            if ([string]::IsNullOrWhiteSpace($networkInterfaceName)) {
                throw "Cannot find the network interface belonging to the IP address '$WindowsHostIpAddress'"
            }

            netsh int ipv4 set int $networkInterfaceName forwarding=enabled | Out-Null
        }

        Write-Log "Joining new node to the cluster" -Console
        $k8sFormattedNodeName = $NodeName.ToLower()
        Join-LinuxNode -NodeName $k8sFormattedNodeName.ToLower() -NodeUserName $UserName -NodeIpAddress $IpAddress -PreStepHook $doBeforeJoining

        # For bare-metal (HOST) nodes, create persistent routes so they survive reboots
        if ($NodeType -eq 'HOST') {
            Add-PersistentLinuxWorkerNodeRoutes -UserName $UserName -IpAddress $IpAddress -WindowsHostIpAddress $WindowsHostIpAddress
        }

        # GPU support: initialize if GPU was detected earlier
        if ($gpuDetected) {
            try {
                $offline = ![string]::IsNullOrWhiteSpace($NodePackagePath)
                if ($offline) {
                    Write-Log "[GPU] Initializing GPU support (offline mode) for node $k8sFormattedNodeName" -Console
                    Initialize-GpuWorkerNode -UserName $UserName -IpAddress $IpAddress -NodeName $k8sFormattedNodeName -Proxy $Proxy -Offline -OsName $installedDistributionOnRemoteComputer
                } else {
                    Write-Log "[GPU] Initializing GPU support (online mode) for node $k8sFormattedNodeName" -Console
                    Initialize-GpuWorkerNode -UserName $UserName -IpAddress $IpAddress -NodeName $k8sFormattedNodeName -Proxy $Proxy
                }
            } catch {
                Write-Log "[GPU] GPU initialization failed: $_ - node will be added without GPU support" -Console
            }
        }

        Write-Log "Node '$NodeName' was added successfully to the cluster." -Console
    }
    catch {
        Write-Log "Adding node '$NodeName' failed ($_) - node config entry for '$NodeName' is preserved in cluster.json for upgrade/restore; use 'k2s node remove' to clean it up" -Console
        throw
    }
}

function Remove-LinuxWorkerNode {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $AdditionalHooksDir = '',
        [switch] $SkipRemoteCleanup
    )
    Write-Log "Removing K2s worker node '$NodeName'"

    # Remove persistent routes service only for bare-metal (HOST) nodes.
    # Skipped when the node/VM is unreachable (SkipRemoteCleanup).
    $nodeConfig = Get-NodeConfig -NodeName $NodeName
    if (-not $SkipRemoteCleanup -and $null -ne $nodeConfig -and $nodeConfig.NodeType -eq 'HOST') {
        Remove-PersistentLinuxWorkerNodeRoutes -UserName $UserName -IpAddress $IpAddress
    }

    $doAfterRemoving = {
        Clear-LinuxWorkerNodeRoutes -UserName $UserName -IpAddress $IpAddress
    }

    $k8sFormattedNodeName = $NodeName.ToLower()
    # Best-effort: an orphaned/unreachable node must not block config removal (#2789).
    if ($SkipRemoteCleanup) {
        Write-Log "SkipRemoteCleanup set (node/VM unreachable) - performing cluster-side config cleanup only for '$NodeName'" -Console
    }
    else {
        try {
            $clusterState = (Invoke-Kubectl -Params @('get', 'nodes', '-o', 'wide')).Output
            if ($clusterState -match $k8sFormattedNodeName) {
                Remove-LinuxNode -NodeName $k8sFormattedNodeName -NodeUserName $UserName -NodeIpAddress $IpAddress -PostStepHook $doAfterRemoving
                Write-Log "Removed node from the cluster" -Console
            } else {
                Write-Log "Node '$k8sFormattedNodeName' is not part of the cluster - skipping cluster removal" -Console
            }
        }
        catch {
            Write-Log "Removing node '$NodeName' from the cluster failed ($_) - node config entry for '$NodeName' is preserved so 'k2s node remove' can be retried" -Console
            throw
        }

        try {
            Remove-KubernetesArtifacts -UserName $UserName -IpAddress $IpAddress
            Write-Log "Removed node essentials from the remote machine" -Console
        }
        catch {
            Write-Log "Remote artifact cleanup for node '$NodeName' did not complete ($_) - continuing to remove node config" -Console
        }
    }

    Remove-NodeConfig -Name $NodeName

    Write-Log "Removing K2s worker node '$NodeName' complete."
}

function Start-LinuxWorkerNode {
    Param(
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $AdditionalHooksDir = '',
        [switch] $ObtainCIDR = $false
    )

    # Ensure KubeSwitch network profile is Private (Windows can reset it to Public)
    $switchName = Get-ControlPlaneNodeDefaultSwitchName
    $switchAlias = "vEthernet ($switchName)"
    Set-InterfacePrivate -InterfaceAlias $switchAlias

    # For bare-metal (HOST) nodes, restore routes on the Linux side so kubelet can reach the API server
    $nodeConfig = Get-NodeConfig -NodeName $NodeName
    if ($null -ne $nodeConfig -and $nodeConfig.NodeType -eq 'HOST') {
        $userName = $nodeConfig.UserName
        if (-not [string]::IsNullOrWhiteSpace($userName)) {
            Write-Log "[Start] Restoring routes on bare-metal node '$NodeName'" -Console
            Restore-LinuxWorkerNodeRoutes -UserName $userName -IpAddress $IpAddress -NodeName $NodeName
        } else {
            Write-Log "[Start] WARNING: Cannot restore routes on bare-metal node '$NodeName' - UserName not found in config"
        }
    }

    $clusterCIDRWorker = Get-ClusterCIDRWorker -NodeName $NodeName -ObtainCIDR:$ObtainCIDR
    Add-RouteToLinuxWorkerNode -NodeName $NodeName -IpAddress $IpAddress -ClusterCIDRWorker $clusterCIDRWorker
    Add-WorkerVFPRoute -NodeName $NodeName -ClusterCIDRWorker $clusterCIDRWorker

    Write-Log "K2s worker node '$NodeName' started" -Console
}

function Add-WorkerVFPRoute {
    Param(
        [string] $NodeName = $(throw 'Argument missing: Hostname'),
        [string] $ClusterCIDRWorker = $(throw 'Argument missing: Hostname')
    )

    $setupConfigRoot = Get-RootConfigk2s
    $defaultGateway = $setupConfigRoot.psobject.properties['cbr0'].value
    Add-VfpRoute -Name $NodeName -Subnet $ClusterCIDRWorker -Gateway $defaultGateway
}

function Stop-LinuxWorkerNode {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $AdditionalHooksDir = '',
        [switch] $SkipHeaderDisplay = $false

    )

    $clusterCIDRWorker = Get-ClusterCIDRWorker -NodeName $NodeName
    Remove-RouteToLinuxWorkerNode -NodeName $NodeName -ClusterCIDRWorker $clusterCIDRWorker
    Remove-VfpRoute -Name $NodeName

    Write-Log "K2s worker node '$NodeName' stopped" -Console
}

function Get-ClusterCIDRWorker {
    Param (
        [string] $NodeName = $(throw 'Argument missing: Hostname'),
        [switch] $ObtainCIDR = $false
    )

    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRWorkerTemplate = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR_2'].value

    $clusterCIDRWorker = ''
    if (!$ObtainCIDR) {
        Write-Log 'Getting Node CIDR from config'
        $node = Get-NodeConfig -NodeName $NodeName
        if ($null -ne $node) {
            $clusterCIDRWorker = $node.PodCIDR
        }
    }

    if ($clusterCIDRWorker -eq '' -or $ObtainCIDR) {
        $output = Get-AssignedPodSubnetworkNumber -NodeName $NodeName
        if ($output.Success) {
            $assignedPodSubnetworkNumber = $output.PodSubnetworkNumber
            $clusterCIDRWorker = $clusterCIDRWorkerTemplate.Replace('X', $assignedPodSubnetworkNumber)

            Update-NodeConfig -Name $NodeName -Updates @{
                PodCIDR = $clusterCIDRWorker
            }
        } else {
            throw "Cannot obtain pod network information from node '$NodeName'"
        }
    }

    return $clusterCIDRWorker
}

function Add-RouteToLinuxWorkerNode {
    Param(
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $NodeName = $(throw 'Argument missing: Hostname'),
        [string] $ClusterCIDRWorker = $(throw 'Argument missing: ClusterCIDRWorker')
    )

    # routes for Linux pods to external nodes
    Write-Log "Remove obsolete route to $ClusterCIDRWorker"
    route delete $ClusterCIDRWorker >$null 2>&1
    Write-Log "Add route to Pods for node:$NodeName CIDR:$ClusterCIDRWorker"
    route -p add $ClusterCIDRWorker $IpAddress METRIC 4 | Out-Null
}

function Remove-RouteToLinuxWorkerNode {
    Param(
        [string] $NodeName = $(throw 'Argument missing: Hostname'),
        [string] $ClusterCIDRWorker = $(throw 'Argument missing: ClusterCIDRWorker')
    )

    # routes for Linux pods
    Write-Log "Remove obsolete route to $ClusterCIDRWorker"
    route delete $ClusterCIDRWorker >$null 2>&1
}

function Install-LinuxPackagesAndAddContainerImagesIntoRemoteComputer {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $Proxy = '',
        [string] $installedDistributionOnRemoteComputer = $(throw 'Argument missing: InstalledDistribution'),
        [string] $NodePackagePath = '',
        [switch] $SkipGpuPackages = $false
    )

    # ---------------------------------------------------------------------------
    # Offline path: node package zip supplied → extract into 'linuxnode' folder
    # ---------------------------------------------------------------------------
    if (![string]::IsNullOrWhiteSpace($NodePackagePath)) {
        if (!(Test-Path $NodePackagePath)) {
            throw "[NodeAdd] Node package not found: '$NodePackagePath'"
        }

        Write-Log "[NodeAdd] --node-package supplied: '$NodePackagePath'. Using offline installation." -Console
        if ($SkipGpuPackages) {
            Write-Log "[NodeAdd] Skipping GPU packages (no NVIDIA GPU detected on node)" -Console
        }

        # Extract zip to a temp staging area
        $extractTempPath = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-node-pkg-extract-$([guid]::NewGuid().ToString().Substring(0, 8))"
        New-Item -Path $extractTempPath -ItemType Directory -Force | Out-Null
        Write-Log "[NodeAdd] Extracting node package to staging: '$extractTempPath'" -Console
        Expand-Archive -LiteralPath $NodePackagePath -DestinationPath $extractTempPath -Force
        Write-Log "[NodeAdd] Node package extracted." -Console

        # Validate expected content
        $zipPackagesPath = Join-Path $extractTempPath 'packages'
        $zipPackagesPathWithOs = Join-Path $zipPackagesPath $installedDistributionOnRemoteComputer
        $zipImagesPath   = Join-Path $extractTempPath 'images'
        if (!(Test-Path $zipPackagesPath)) {
            throw "[NodeAdd] Expected 'packages' folder not found in node package: '$zipPackagesPath'"
        }

        $zipPackagesPathToUse = $zipPackagesPath
        if (Test-Path $zipPackagesPathWithOs) {
            $zipPackagesPathToUse = $zipPackagesPathWithOs
        } else {
            Write-Log "[NodeAdd] WARNING: OS-specific packages path '$zipPackagesPathWithOs' not found. Falling back to '$zipPackagesPath'." -Console
        }

        # Prepare the 'linuxnode' artifacts directory: keep folder, overwrite contents
        $linuxNodeDir = Get-DirectoryOfLinuxNodeArtifactsOnWindowsHost
        if (!(Test-Path $linuxNodeDir)) {
            New-Item -Path $linuxNodeDir -ItemType Directory -Force | Out-Null
            Write-Log "[NodeAdd] Created 'linuxnode' directory: '$linuxNodeDir'" -Console
        } else {
            Write-Log "[NodeAdd] Using existing 'linuxnode' directory: '$linuxNodeDir'" -Console
        }

        $linuxNodePackagesPath = Join-Path $linuxNodeDir 'packages'
        $linuxNodePackagesByOsPath = Join-Path $linuxNodePackagesPath $installedDistributionOnRemoteComputer
        $linuxNodeImagesPath = Join-Path $linuxNodeDir 'images'

        if (Test-Path $linuxNodePackagesByOsPath) {
            Write-Log "[NodeAdd] Overwriting existing packages content in '$linuxNodePackagesByOsPath'" -Console
            Remove-Item -Path $linuxNodePackagesByOsPath -Recurse -Force
        }
        if (Test-Path $linuxNodeImagesPath) {
            Write-Log "[NodeAdd] Overwriting existing images content in '$linuxNodeImagesPath'" -Console
            Remove-Item -Path $linuxNodeImagesPath -Recurse -Force
        }

        # Copy packages from extracted zip into linuxnode
        # If SkipGpuPackages is set, exclude nvidia-gpu folder
        New-Item -Path $linuxNodePackagesByOsPath -ItemType Directory -Force | Out-Null
        if ($SkipGpuPackages) {
            # Check if nvidia-gpu folder exists in the source
            $nvidiaGpuFolder = Join-Path $zipPackagesPathToUse 'nvidia-gpu'
            $hasNvidiaGpuFolder = Test-Path $nvidiaGpuFolder

            # Copy packages excluding nvidia-gpu folder
            $itemsToCopy = Get-ChildItem -Path $zipPackagesPathToUse | Where-Object { $_.Name -ne 'nvidia-gpu' }
            foreach ($item in $itemsToCopy) {
                Copy-Item -Path $item.FullName -Destination $linuxNodePackagesByOsPath -Recurse -Force
            }
            if ($hasNvidiaGpuFolder) {
                Write-Log "[NodeAdd] Copied packages (excluding nvidia-gpu) from node package into '$linuxNodePackagesByOsPath'" -Console
            } else {
                Write-Log "[NodeAdd] Copied packages from node package into '$linuxNodePackagesByOsPath'" -Console
            }
        } else {
            Write-Log "[NodeAdd] Copying packages from node package into '$linuxNodePackagesByOsPath'" -Console
            Copy-Item -Path "$zipPackagesPathToUse\*" -Destination $linuxNodePackagesByOsPath -Recurse -Force
        }

        # Copy images from extracted zip into linuxnode
        # If SkipGpuPackages is set, exclude GPU-related images (device-plugin, dcgm-exporter)
        if (Test-Path $zipImagesPath) {
            if ($SkipGpuPackages) {
                # Check if GPU images exist in the source
                $gpuImagePatterns = @('*device-plugin*', '*dcgm*')
                $allImages = Get-ChildItem -Path $zipImagesPath -File
                $gpuImagesFound = $allImages | Where-Object {
                    $fileName = $_.Name
                    foreach ($pattern in $gpuImagePatterns) {
                        if ($fileName -like $pattern) { return $true }
                    }
                    return $false
                }
                $hasGpuImages = ($gpuImagesFound | Measure-Object).Count -gt 0

                # Copy images excluding GPU-related tar files
                $imagesToCopy = $allImages | Where-Object {
                    $fileName = $_.Name
                    $isGpuImage = $false
                    foreach ($pattern in $gpuImagePatterns) {
                        if ($fileName -like $pattern) {
                            $isGpuImage = $true
                            break
                        }
                    }
                    -not $isGpuImage
                }
                New-Item -Path $linuxNodeImagesPath -ItemType Directory -Force | Out-Null
                foreach ($image in $imagesToCopy) {
                    Copy-Item -Path $image.FullName -Destination $linuxNodeImagesPath -Force
                }
                if ($hasGpuImages) {
                    Write-Log "[NodeAdd] Copied images (excluding GPU images) from node package into '$linuxNodeImagesPath'" -Console
                } else {
                    Write-Log "[NodeAdd] Copied images from node package into '$linuxNodeImagesPath'" -Console
                }
            } else {
                Write-Log "[NodeAdd] Copying images from node package into '$linuxNodeDir\images'" -Console
                Copy-Item -Path $zipImagesPath -Destination $linuxNodeDir -Recurse -Force
            }
        } else {
            Write-Log "[NodeAdd] WARNING: 'images' folder not found in node package. Skipping image copy." -Console
        }

        # Cleanup temp staging
        Remove-Item -Path $extractTempPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ---------------------------------------------------------------------------
    # Online path: discover packages from control plane or download from internet
    # ---------------------------------------------------------------------------
    $controlPlaneUserName = Get-DefaultUserNameControlPlane
    $controlPlaneIpAddress = Get-ConfiguredIPControlPlane
    $installedDistributionOnControlPlane = Get-InstalledDistribution -UserName $controlPlaneUserName -IpAddress $controlPlaneIpAddress
    Write-Log "Installed distribution in the control plane: $installedDistributionOnControlPlane"
    Write-Log "Installed distribution in the machine with IP '$IpAddress': $installedDistributionOnRemoteComputer"
   
    $baseDirectoryOfKubenodeDebPackagesOnWindowsHost = Get-BaseDirectoryOfKubenodeDebPackagesOnWindowsHost
    $windowsHostDebPackagesSourcePath = "$baseDirectoryOfKubenodeDebPackagesOnWindowsHost\$installedDistributionOnRemoteComputer"

    $linuxNodeArtifactsPackagePath = Get-PathOfLinuxNodeArtifactsPackageOnWindowsHost
    $linuxNodeArtifactsPath = Get-DirectoryOfLinuxNodeArtifactsOnWindowsHost

    $packagePathExists = $(Test-Path -Path $linuxNodeArtifactsPackagePath)
    $linuxNodeArtifactsPathExists = $(Test-Path -Path $linuxNodeArtifactsPath)

    Write-Log "Zip file '$linuxNodeArtifactsPackagePath' with Linux node artifacts exists?: $packagePathExists"
    Write-Log "Folder '$linuxNodeArtifactsPath' with Linux node artifacts exists?: $linuxNodeArtifactsPathExists"

    if (!($linuxNodeArtifactsPathExists) -and ($packagePathExists) -and [string]::IsNullOrWhiteSpace($NodePackagePath)) {
        Write-Log "Create folder '$linuxNodeArtifactsPath'"
        New-Item -Path $linuxNodeArtifactsPath -ItemType Directory -Force | Out-Null
        Write-Log "Extracting content of file '$linuxNodeArtifactsPackagePath' into '$linuxNodeArtifactsPath'"
        Expand-Archive -LiteralPath $linuxNodeArtifactsPackagePath -DestinationPath $linuxNodeArtifactsPath
    } 

    $distributionDebPackagesSourcePathExists = $(Test-Path -Path $windowsHostDebPackagesSourcePath)
    Write-Log "Folder with deb packages '$windowsHostDebPackagesSourcePath' exists?: $distributionDebPackagesSourcePathExists"
    if ($distributionDebPackagesSourcePathExists) {
        Write-Log "The content of the folder '$windowsHostDebPackagesSourcePath' will be used"
    } 
    
    $kubernetesDebPackagesTargetPath = Get-KubernetesDebPackagesPath -UserName $UserName
    Add-KubernetesArtifactsToRemoteComputer -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy -SourcePath $windowsHostDebPackagesSourcePath -TargetPath $kubernetesDebPackagesTargetPath -InstalledDistribution $installedDistributionOnRemoteComputer
    Install-KubernetesArtifacts -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy -SourcePath $kubernetesDebPackagesTargetPath -InstalledDistribution $installedDistributionOnRemoteComputer

    $buildahDebPackagesTargetPath = Get-BuildahDebPackagesPath -UserName $UserName
    Add-BuildahArtifactsToRemoteComputer -UserName $UserName -IpAddress $IpAddress -SourcePath $windowsHostDebPackagesSourcePath -TargetPath $buildahDebPackagesTargetPath -InstalledDistribution $installedDistributionOnRemoteComputer
    Install-BuildahDebPackages -UserName $UserName -IpAddress $IpAddress -SourcePath $buildahDebPackagesTargetPath -InstalledDistribution $installedDistributionOnRemoteComputer

    Copy-KubernetesImagesFromControlPlaneToRemoteComputer -UserName $UserName -IpAddress $IpAddress
}

function Test-SupportedWorkerOS {
    <#
    .SYNOPSIS
        Validates that the given OS key is listed in supportedWorkerOS in cfg/config.json.
    .PARAMETER OS
        The combined OS+version key to validate (e.g. 'debian12', 'debian13').
    .PARAMETER InstallationPath
        The K2s installation root. Defaults to Get-KubePath when not specified.
    #>
    param(
        [string] $OS = $(throw 'Argument missing: OS'),
        [string] $InstallationPath = ''
    )

    if ($InstallationPath -eq '') {
        $InstallationPath = Get-KubePath
    }

    $configPath = Join-Path $InstallationPath 'cfg\config.json'
    if (!(Test-Path $configPath)) {
        throw "Configuration file not found: $configPath"
    }

    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $supportedOS = $config.supportedWorkerOS
    if (!$supportedOS) {
        throw 'No supported OS configurations found in cfg/config.json'
    }

    foreach ($supported in $supportedOS) {
        if ($supported.os -eq $OS) {
            Write-Log "[WorkerOS] OS '$OS' is supported" -Console
            return
        }
    }

    $supportedList = ($supportedOS | ForEach-Object { $_.os }) -join ', '
    throw "OS '$OS' is not supported. Supported: $supportedList"
}

Export-ModuleMember -Function Add-LinuxWorkerNode,
Add-LinuxWorkerNodeRegistryMirrors,
Remove-LinuxWorkerNode,
Clear-LinuxWorkerNodeRoutes,
Restore-LinuxWorkerNodeRoutes,
Add-PersistentLinuxWorkerNodeRoutes,
Remove-PersistentLinuxWorkerNodeRoutes,
Start-LinuxWorkerNode,
Stop-LinuxWorkerNode,
Test-SupportedWorkerOS
