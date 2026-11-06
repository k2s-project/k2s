# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$downloaderModule = "$PSScriptRoot\..\downloader\downloader.module.psm1"
$networkModule = "$PSScriptRoot\..\network\network.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $downloaderModule, $networkModule

$kubePath = Get-KubePath
$kubeBinPath = Get-KubeBinPath
$kubeToolsPath = Get-KubeToolsPath


function Initialize-Networking {
    Param(
        [parameter(Mandatory = $true, HelpMessage = 'Host machine is a VM: true, Host machine is not a VM')]
        [bool] $HostVM,
        [parameter(Mandatory = $true, HelpMessage = 'Host-GW or VXLAN, Host-GW: true, false for vxlan')]
        [bool] $HostGW,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )

    # copy flannel files
    Write-Log 'Copy flannel files to right directory'
    mkdir -force "$(Get-SystemDriveLetter):\etc\cni" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\etc\cni\net.d" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\etc\kube-flannel" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\opt" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\opt\cni" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\opt\cni\bin" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\run" | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\run\flannel" | Out-Null
    mkdir -force (Join-Path -Path (Get-ConfiguredLogDirectory) -ChildPath 'flanneld') | Out-Null
    mkdir -force "$(Get-SystemDriveLetter):\var\lib" | Out-Null

    $r = Get-NetFirewallRule -DisplayName 'kubelet' 2> $null;
    if ( $r ) {
        Remove-NetFirewallRule -DisplayName 'kubelet'
    }

    if (!($HostVM)) {
        $kubeVMFirewallRuleName = 'KubeMaster VM'
        $r = Get-NetFirewallRule -DisplayName $kubeVMFirewallRuleName -ErrorAction SilentlyContinue
        if ( $r ) {
            Remove-NetFirewallRule -DisplayName $kubeVMFirewallRuleName -ErrorAction SilentlyContinue
        }
        $ipControlPlane = Get-ConfiguredIPControlPlane
        New-NetFirewallRule -DisplayName $kubeVMFirewallRuleName -Group 'k2s' -Description 'Allow inbound traffic from the Linux VM on ports above 8000' -RemoteAddress $ipControlPlane -RemotePort '8000-32000' -Enabled True -Direction Inbound -Protocol TCP -Action Allow | Out-Null
    }

    $adapterName = Get-L2BridgeName
    Write-Log "Using network adapter '$adapterName'"
    $ipaddresses = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $adapterName)
    if (!$ipaddresses) {
        throw 'No IP address found which can be used for setting up K2s Setup !'
    }
    $ipaddress = $ipaddresses[0] | Select-Object -ExpandProperty IPAddress
    Write-Log "Using local IP $ipaddress for setup of CNI"

    $clusterCIDRHost = Get-ConfiguredClusterCIDRHost -PodSubnetworkNumber $PodSubnetworkNumber
    $NetworkAddress = "  ""Network"": ""$clusterCIDRHost"","


    $targetFilePath = "$(Get-SystemDriveLetter):\etc\kube-flannel\net-conf.json"
    if ( $HostGW) {
        Write-Log "Writing $targetFilePath for HostGW mode"
        Copy-Item -force "$kubePath\cfg\cni\net-conf.json.template" $targetFilePath

        $lineNetworkAddress = Get-Content $targetFilePath | Select-String NETWORK.ADDRESS | Select-Object -ExpandProperty Line
        if ( $lineNetworkAddress ) {
            $content = Get-Content $targetFilePath
            $content | ForEach-Object { $_ -replace $lineNetworkAddress, $NetworkAddress } | Set-Content $targetFilePath
        }
    }
    else {
        Write-Log "Writing $targetFilePath for VXLAN mode"
        Copy-Item -force "$kubePath\cfg\cni\net-conf-vxlan.json.template" $targetFilePath

        $lineNetworkAddress = Get-Content $targetFilePath | Select-String NETWORK.ADDRESS | Select-Object -ExpandProperty Line
        if ( $lineNetworkAddress ) {
            $content = Get-Content $targetFilePath
            $content | ForEach-Object { $_ -replace $lineNetworkAddress, $NetworkAddress } | Set-Content $targetFilePath
        }
    }

    if (!($HostVM)) {
        # save the current IP address to make a later check possible
        Set-ConfigHostGW -Value $HostGW
    }

    Copy-Item -Path "$kubeBinPath\cni\*" -Destination "$(Get-SystemDriveLetter):\opt\cni\bin" -Recurse
}

function Reset-WinServices {
    &"$kubeBinPath\nssm" set kubeproxy Start SERVICE_DEMAND_START | Out-Null
    &"$kubeBinPath\nssm" set kubelet Start SERVICE_DEMAND_START | Out-Null
    &"$kubeBinPath\nssm" set httpproxy Start SERVICE_DEMAND_START | Out-Null
    &"$kubeBinPath\nssm" set flanneld Start SERVICE_DEMAND_START | Out-Null
}

function Initialize-WinNode {
    Param(
        [parameter(Mandatory = $true, HelpMessage = 'Kubernetes version to use')]
        [string] $KubernetesVersion,
        [parameter(Mandatory = $false, HelpMessage = 'Host machine is a VM: true, Host machine is not a VM')]
        [bool] $HostVM = $false,
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy = '',
        [parameter(Mandatory = $true, HelpMessage = 'Host-GW or VXLAN, Host-GW: true, false for vxlan')]
        [bool] $HostGW,
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [boolean] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
        [boolean] $ForceOnlineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Skips networking setup and installation of cluster dependent tools kubelet, flannel on windows node')]
        [boolean] $SkipClusterSetup = $false,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber'),
        [parameter(Mandatory = $false, HelpMessage = 'The path to local builds of Kubernetes binaries')]
        [string] $K8sBinsPath = ''
    )

    if (!(Test-Path "$kubeToolsPath")) {
        New-Item -ItemType 'directory' -Path "$kubeToolsPath" | Out-Null
    }

    if (! $SkipClusterSetup ) {
        if (!$KubernetesVersion.StartsWith('v')) {
            $KubernetesVersion = 'v' + $KubernetesVersion
        }
        Write-Log "Using Kubernetes version: $KubernetesVersion"

        if ($HostVM) {
            [Environment]::SetEnvironmentVariable('KUBECONFIG', "$kubePath\config", [System.EnvironmentVariableTarget]::Machine)
        }

        $previousKubernetesVersion = Get-ConfigInstalledKubernetesVersion
        Write-Log("Previous K8s version: $previousKubernetesVersion, current K8s version to install: $KubernetesVersion")

        Set-ConfigInstalledKubernetesVersion -Value $KubernetesVersion

        Initialize-Networking -HostVM:$HostVM -HostGW:$HostGW -PodSubnetworkNumber $PodSubnetworkNumber
    }
    else {
        Write-Log 'Skipping networking setup on windows node'
    }

    Install-WinNodeArtifacts -Proxy "$Proxy" -HostVM:$HostVM -SkipClusterSetup:$SkipClusterSetup -PodSubnetworkNumber $PodSubnetworkNumber -K8sBinsPath $K8sBinsPath

    if (! $SkipClusterSetup) {
        Reset-WinServices
    }
}

function Uninstall-WinNode {
    param(
        $ShallowUninstallation = $false
    )
    Remove-ServiceIfExists 'flanneld'
    Remove-ServiceIfExists 'httpproxy'
    Remove-ServiceIfExists 'kubelet'
    Remove-ServiceIfExists 'kubeproxy'
    Remove-ServiceIfExists 'windows_exporter'

    # remove firewall rules
    Remove-NetFirewallRule -Group 'k2s' -ErrorAction SilentlyContinue

    Write-Log 'Uninstall containerd service if existent'
    Uninstall-WinContainerd -ShallowUninstallation $ShallowUninstallation
    Uninstall-WinDocker -ShallowUninstallation $ShallowUninstallation

    Remove-K2sAppLockerRules

    Write-Log 'Remove event log sources of the removed services'
    Remove-K2sEventLogSources -InstallationPath $kubePath
}


function Clear-WinNode {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [Boolean] $DeleteFilesForOfflineInstallation = $false
    )
    $kubeletConfigDir = Get-KubeletConfigDir
    # remove folders from installation folder
    Get-ChildItem -Path $kubeletConfigDir -Force -Recurse -Attributes Reparsepoint -ErrorAction 'silentlycontinue' | % { $n = $_.FullName.Trim('\'); fsutil reparsepoint delete "$n" }
    Remove-Item -Path "$(Get-SystemDriveLetter):\etc" -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path "$(Get-SystemDriveLetter):\run" -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path "$(Get-SystemDriveLetter):\opt" -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path "$(Get-InstallationDriveLetter):\run" -Force -Recurse -ErrorAction SilentlyContinue

    Remove-Item -Path "$(Get-K2sConfigDir)" -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubeBinPath\kube*.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubeBinPath\nerdctl.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubeBinPath\windows_exporter.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubeBinPath\cni\flanneld.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubeBinPath\jq.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubeBinPath\yq.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubeBinPath\helm.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubeBinPath\dnsproxy.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubeBinPath\dnsproxy.yaml" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubeBinPath\cri*.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubeBinPath\crictl.yaml" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubeBinPath\kube" -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\config" -Force -ErrorAction SilentlyContinue
    #Backward compatibility for few versions
    Remove-Item -Path "$kubePath\cni\bin\win*.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\cni\bin\flannel.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\cni\bin\host-local.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\cni\bin\vfprules.json" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\cni\bin" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\cni\conf" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\cni" -Force -ErrorAction SilentlyContinue

    Remove-Item -Path "$kubePath\bin\cni\win*.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\bin\cni\flannel.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\bin\cni\host-local.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\bin\cni\vfprules.json" -Force -ErrorAction SilentlyContinue

    Remove-Item -Path "$kubePath\kubevirt\bin\*.exe" -Force -ErrorAction SilentlyContinue

    Remove-Item -Path "$kubePath\smallsetup\en_windows*business*.iso" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\debian*.qcow2" -Force -ErrorAction SilentlyContinue

    Remove-Item -Path "$kubeBinPath\plink.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubeBinPath\pscp.exe" -Force -ErrorAction SilentlyContinue

    Remove-Nssm

    Invoke-DownloadsCleanup -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

    Remove-Item -Path "~/.kube/cache" -Force -Recurse -ErrorAction SilentlyContinue
}

Export-ModuleMember Initialize-WinNode, Uninstall-WinNode, Clear-WinNode
