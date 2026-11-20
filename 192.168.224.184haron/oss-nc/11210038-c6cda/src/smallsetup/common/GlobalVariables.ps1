# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# GlobalVariables.ps1
#   set some global variables used in multiple scripts (avoid duplication of data)

$global:KubernetesPath = (Get-Item $PSScriptRoot).Parent.Parent.FullName
$global:InstallationDriveLetter = ($global:KubernetesPath).Split(':')[0]
# TODO: remove, when migrating to new PS modules code structure
# new modules should use <root>\k2sSetup\lib\modules\windows\infra\k2s.infra.module\path\path.module.psm1::Get-SystemDriveLetter function instead
$global:SystemDriveLetter = 'C'

if (! $(Test-Path $global:KubernetesPath)) {
    throw "Basic setup failed, script path not found: $global:KubernetesPath"
}

# Resolving paths from config file if path contains environment variables etc.
function Force-Resolve-Path {
    <#
    .SYNOPSIS
        Calls Resolve-Path but works for files that don't exist.
    #>
    param (
        [string] $FileName
    )

    $FileName = Resolve-Path $FileName -ErrorAction SilentlyContinue -ErrorVariable _frperror
    if (-not($FileName)) {
        $FileName = $_frperror[0].TargetObject
    }

    return $FileName
}

# Read cluster configuration json
$global:JsonConfigFile = "$global:KubernetesPath\cfg\config.json"
$clusterConfig = Get-Content $global:JsonConfigFile | Out-String | ConvertFrom-Json
$smallsetup = $clusterConfig.psobject.properties['smallsetup'].value

$global:VMName = 'KubeMaster'
$global:SwitchName = 'KubeSwitch'

$global:BinPath = "$global:KubernetesPath\bin"
$global:ExecutableFolderPath = "$global:KubernetesPath\bin\exe"
$global:DockerDir = "$global:KubernetesPath\bin\docker"
$global:DockerExe = "$global:DockerDir\docker.exe"

$global:SshExe = "$global:BinPath\plink.exe"
$global:ScpExe = "$global:BinPath\pscp.exe"
$global:DevconExe = "$global:BinPath\devgon.exe"
$global:NerdctlExe = "$global:BinPath\nerdctl.exe"
$global:KubectlExe = "$global:ExecutableFolderPath\kubectl.exe"

# Add ExecutableFolderPath to current path at beginning, so we can get sure that our executables are used
# (And e.g. no old kubectl from another location)

if (($null -eq $env:Path) -or !$env:Path.StartsWith($global:ExecutableFolderPath)) {
    $env:Path = $global:ExecutableFolderPath + [IO.Path]::PathSeparator + $env:Path
}

# Host VM network
$global:IP_Master = $smallsetup.psobject.properties['masterIP'].value
$global:IP_NextHop = $smallsetup.psobject.properties['kubeSwitch'].value
$global:IP_CIDR = $smallsetup.psobject.properties['masterNetworkCIDR'].value
$global:RemoteUserName_Master = 'remote'
$global:Remote_Master = "$global:RemoteUserName_Master@$global:IP_Master"

# Password for Linux/Windows VMs during installation
$global:VMPwd = 'admin'

# key for accessing VMs over SSH
$configDir = $clusterConfig.psobject.properties['configDir'].value

$global:SshConfigDir = Force-Resolve-Path $configDir.psobject.properties['ssh'].value
$sshKeyConfig = $clusterConfig.psobject.properties['sshKey'].value
$global:keyFileName = $sshKeyConfig.psobject.properties['fileName'].value.psobject.properties['windows'].value
$global:LinuxVMKey = $global:SshConfigDir + "\" + $sshKeyConfig.psobject.properties['subDir'].value + "\$global:keyFileName"
$global:WindowsVMKey = $global:SshConfigDir + "\windowsvm\$global:keyFileName"

$global:K2sConfigDir = Force-Resolve-Path $configDir.psobject.properties['k2s'].value

# NSSM for controlling services
$global:NssmInstallDirectory = "$global:KubernetesPath\bin"

# Cluster CIDR
$global:ClusterCIDR = $smallsetup.psobject.properties['podNetworkCIDR'].value
$global:ClusterCIDR_Master = $smallsetup.psobject.properties['podNetworkMasterCIDR'].value
$global:ClusterCIDR_Host = $smallsetup.psobject.properties['podNetworkWorkerCIDR'].value
$global:ClusterCIDR_Gateway = $smallsetup.psobject.properties['cbr0Gateway'].value
$global:ClusterCIDR_NextHop = $smallsetup.psobject.properties['cbr0'].value
$global:ClusterCIDR_Services = $smallsetup.psobject.properties['servicesCIDR'].value

$global:ClusterCIDR_NatExceptions = $smallsetup.psobject.properties['clusterCIDRNatExceptions'].value

$global:IP_LoopbackAdapter = $smallsetup.psobject.properties['loopback'].value
$global:Gateway_LoopbackAdapter = $smallsetup.psobject.properties['loopbackGateway'].value

# storage
$global:ConfiguredStorageLocalDriveLetter = $smallsetup.psobject.properties['storageLocalDriveLetter'].value

$global:L2BridgeSwitchName = 'cbr0'

# setup config file
$global:SetupJsonFile = "$global:K2sConfigDir\setup.json"
$global:KubernetesImagesJson = "$global:K2sConfigDir\kubernetes_images.json"
$global:SetupType_k2s = 'k2s'
$global:SetupType_BuildOnlyEnv = 'BuildOnlyEnv'
$global:ConfigKey_LoggedInRegistry = 'LoggedInRegistry'
$global:ConfigKey_UsedStorageLocalDriveLetter = 'UsedStorageLocalDriveLetter'
$global:ConfigKey_ControlPlaneNodeHostname = 'ControlPlaneNodeHostname'

$global:LoopbackAdapter = 'Loopbackk2s'

# provisioned base image
$global:SourcesDirectory = "$global:KubernetesPath"
$global:BinDirectory = "$global:SourcesDirectory\bin"

# download
$global:DownloadsDirectory = "$global:BinDirectory\downloads"

# windows node artifacts
$global:WindowsNodeArtifactsDownloadsDirectory = "$global:DownloadsDirectory\windowsnode"
$global:WindowsNodeArtifactsDirectory = "$global:BinDirectory\windowsnode"

