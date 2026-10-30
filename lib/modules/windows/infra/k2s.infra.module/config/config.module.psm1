# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$pathModule = "$PSScriptRoot\..\path\path.module.psm1"
Import-Module $pathModule

# Read cluster configuration json
$kubePath = Get-KubePath
$controlPlaneSwitchName = 'KubeSwitch'
$configFile = "$kubePath\cfg\config.json"
$rootConfig = Get-Content $configFile | Out-String | ConvertFrom-Json
$smallsetup = $rootConfig.psobject.properties['smallsetup'].value

function Expand-Path {
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

$configDir = $rootConfig.psobject.properties['configDir'].value
$configuredStorageLocalDriveLetter = $smallsetup.psobject.properties['storageLocalDriveLetter'].value
$configuredstorageLocalDriveFolder = $smallsetup.psobject.properties['storageLocalDriveFolder'].value

$kubeConfigDir = Expand-Path $configDir.psobject.properties['kube'].value
$script:sshConfigDir = Expand-Path $configDir.psobject.properties['ssh'].value
$dockerConfigDir = Expand-Path $configDir.psobject.properties['docker'].value

# Resolves the K2s setup config directory ('configDir.k2s').
#
# Fallback chain (first hit wins):
#   1. Environment variable K2S_SETUP_CONFIG_DIR
#   2. cfg/config.json -> configDir.k2s
#
# The environment variable is set by the K2s CLI during 'k2s system upgrade' when the
# already installed K2s uses a different (customized) setup config directory than the
# currently running package. It exists solely to discover, analyze and uninstall the OLD
# installation and is cleared again before the NEW version is installed, so that the new
# installation always uses the setup config dir of its own package.
function Resolve-K2sSetupConfigDir {
    if ($env:K2S_SETUP_CONFIG_DIR) {
        return Expand-Path $env:K2S_SETUP_CONFIG_DIR
    }
    return Expand-Path $configDir.psobject.properties['k2s'].value
}

$script:k2sConfigDir = Resolve-K2sSetupConfigDir

$script:sshKeyFileName = 'id_rsa'
$script:kubernetesImagesJsonFile = "$script:k2sConfigDir\kubernetes_images.json"
$script:sshKeyControlPlane = "$script:sshConfigDir\k2s\$script:sshKeyFileName"

#NETWORKING
$ipControlPlane = $smallsetup.psobject.properties['masterIP'].value
$ipNextHop = $smallsetup.psobject.properties['kubeSwitch'].value
$ipControlPlaneCIDR = $smallsetup.psobject.properties['masterNetworkCIDR'].value

# Cluster CIDR
$clusterCIDR = $smallsetup.psobject.properties['podNetworkCIDR'].value
$clusterCIDRServices = $smallsetup.psobject.properties['servicesCIDR'].value

# DNS service IP address
$kubeDnsServiceIP = $smallsetup.psobject.properties['kubeDnsServiceIP'].value

# Master network cni interface IP address
$masterNetworkInterfaceCni0IP = $smallsetup.psobject.properties['masterNetworkInterfaceCni0IP'].value

$legacyClusterName = 'kubernetes'
$clusterName = $rootConfig.psobject.properties['clusterName'].value

#CONSTANTS
# NOTE: intentionally NOT '-Option Constant': 'k2s system upgrade' clears the
# K2S_SETUP_CONFIG_DIR override once the old cluster has been uninstalled and re-resolves
# the setup config dir via 'Update-SetupConfigDir' before the new version is installed.
$script:SetupJsonFile = "$script:k2sConfigDir\setup.json"


# PUBLIC FUNCTIONS

<#
.SYNOPSIS
Re-resolves the K2s setup config directory and all paths derived from it.

.DESCRIPTION
'k2s system upgrade' temporarily sets K2S_SETUP_CONFIG_DIR to the setup config dir of the
OLD installation in order to analyze and uninstall it. Once the old cluster is gone, the
override is removed and this function switches the module back to the setup config dir of
the current package, so the new installation is tracked at its own location.

.OUTPUTS
The re-resolved setup config directory.
#>
function Update-SetupConfigDir {
    $script:k2sConfigDir = Resolve-K2sSetupConfigDir
    $script:SetupJsonFile = "$script:k2sConfigDir\setup.json"
    $script:kubernetesImagesJsonFile = "$script:k2sConfigDir\kubernetes_images.json"

    return $script:k2sConfigDir
}

function Get-RootConfig {
    return $rootConfig
}

function Get-SshConfigDir {
    if (Test-Path $script:sshConfigDir) {
        return $script:sshConfigDir
    }

    $keyPath = Get-SSHKeyControlPlane
    if ($keyPath -and (Test-Path $keyPath)) {
        return (Split-Path -Parent (Split-Path -Parent $keyPath))
    }

    $usersDir = "$env:SystemDrive\Users"
    if (Test-Path $usersDir) {
        $userProfiles = Get-ChildItem -Path $usersDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^(systemprofile|LocalService|NetworkService|Public|Default|Default User)$' }

        foreach ($profile in $userProfiles) {
            $userSshDir = Join-Path $profile.FullName '.ssh'
            if (Test-Path $userSshDir) {
                return $userSshDir
            }
        }
    }

    return $script:sshConfigDir
}

function Get-ConfiguredKubeConfigDir {
    return $kubeConfigDir
}

function Get-KubernetesImagesFilePath {
    return $kubernetesImagesJsonFile
}

function Get-k2sConfigFilePath {
    return $configFile
}

function Get-K2sConfigDir {
    return $k2sConfigDir
}

function Get-SetupConfigFilePath {
    return $SetupJsonFile
}

function Get-ProductVersion {
    return "$(Get-Content -Raw -Path "$kubePath\VERSION")".Trim()
}

function Get-SSHKeyControlPlane {
    if (Test-Path $script:sshKeyControlPlane) {
        return $script:sshKeyControlPlane
    }

    $keyFileName = if ($script:sshKeyFileName) { $script:sshKeyFileName } else { 'id_rsa' }
    $usersDir = "$env:SystemDrive\Users"

    if (Test-Path $usersDir) {
        $userProfiles = Get-ChildItem -Path $usersDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^(systemprofile|LocalService|NetworkService|Public|Default|Default User)$' }

        foreach ($profile in $userProfiles) {
            $candidateKey = Join-Path $profile.FullName ".ssh\k2s\$keyFileName"
            if (Test-Path $candidateKey) {
                return $candidateKey
            }
        }

        if ($script:sshKeyControlPlane -match 'systemprofile') {
            foreach ($profile in $userProfiles) {
                $userSshDir = Join-Path $profile.FullName '.ssh'
                if (Test-Path $userSshDir) {
                    return "$userSshDir\k2s\$keyFileName"
                }
            }
        }
    }

    return $script:sshKeyControlPlane
}

function Get-SSHKeyFileName {
    return $script:sshKeyFileName
}

function Get-ConfiguredIPControlPlane {
    return $ipControlPlane
}

function Get-RootConfigk2s {
    return $smallsetup
}

function Get-ConfiguredStorageLocalDriveLetter {
    return $configuredStorageLocalDriveLetter
}

function Get-ConfiguredstorageLocalDriveFolder {
    return $configuredstorageLocalDriveFolder
}

function Get-ConfiguredDockerConfigDir {
    return $dockerConfigDir
}

function Get-ConfiguredClusterCIDR {
    return $clusterCIDR
}

function Get-ConfiguredClusterCIDRServices {
    return $clusterCIDRServices
}

function Get-ConfiguredKubeDnsServiceIP {
    return $kubeDnsServiceIP
}

function Get-ConfiguredMasterNetworkInterfaceCni0IP {
    return $masterNetworkInterfaceCni0IP
}

function Get-ConfiguredKubeSwitchIP {
    return $ipNextHop
}

function Get-ConfiguredControlPlaneCIDR {
    return $ipControlPlaneCIDR
}

function Get-ControlPlaneNodeDefaultSwitchName {
    return $controlPlaneSwitchName
}

function Get-DefaultTempPwd {
    return 'admin'
}

function Get-ConfiguredClusterNetworkPrefix {
    return $ipControlPlaneCIDR.Substring($ipControlPlaneCIDR.IndexOf('/') + 1)
}

function Get-ClusterName {
    return $clusterName
}

<#
.SYNOPSIS
    Creates a specified directory if not existing.
.DESCRIPTION
    Creates a specified directory if not existing.
.EXAMPLE
    New-DirectoryIfNotExisting -Path 'c:\temp-dir'
    New-DirectoryIfNotExisting 'c:\temp-dir'
    'c:\temp-dir' | New-DirectoryIfNotExisting
.PARAMETER Path
    Directory path
.NOTES
    Function supports pipelines ('Path')
#>
function New-DirectoryIfNotExisting {
    param (
        [Parameter(ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (!(Test-Path $Path)) {
        Write-Log "Directory '$Path' not existing, creating it ..."

        New-Item -Path $Path -ItemType Directory | Out-Null

        Write-Log "Directory '$Path' created."
    }
    else {
        Write-Log "Directory '$Path' already existing."
    }
}


<#
.SYNOPSIS
    Retrieves the specified config value from a given JSON file.
.DESCRIPTION
    Retrieves the specified config value from a given JSON file.
.EXAMPLE
    $version = Get-ConfigValue -Path "config.json" -Key 'version'
.PARAMETER Path
    Path to config JSON file
.PARAMETER Key
    Property key
.OUTPUTS
    The property value if existing; otherwise null
.NOTES
    Config file must contain valid JSON.
    Only top-level properties are read.
    If the property exists with null value, null will be returned (same as if the property did not exist).
    If the config file does not exist, null will be returned.
#>
function Get-ConfigValue {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Path = $(throw 'Please provide the config file path.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Key = $(throw 'Please provide the config key.')
    )

    if (!(Test-Path $Path)) {
        return $null
    }

    return $(Get-Content $Path -Raw | ConvertFrom-Json).$Key
}

<#
.SYNOPSIS
    Writes a key-value pair to a given JSON file.
.DESCRIPTION
    Writes a key-value pair to a given JSON file.
.EXAMPLE
    Set-ConfigValue -Path "config.json" -Key 'version' -Value '123'
.PARAMETER Path
    Path to config JSON file
.PARAMETER Key
    Property key
.PARAMETER Value
    Property value
.NOTES
    Config file must contain valid JSON.
    Only top-level properties are set.
    Existing properties with the same key get overwritten.
    If the config file does not exist, it will be created.
#>
function Set-ConfigValue {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Path = $(throw 'Please provide the config file path.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Key = $(throw 'Please provide the config key.'),
        [Parameter()]
        [object] $Value = $(throw 'Please provide the config value.')
    )

    if (Test-Path $Path) {
        $json = $(Get-Content $Path -Raw | ConvertFrom-Json)
    }
    else {
        Split-Path -parent $Path | New-DirectoryIfNotExisting

        $json = @{ }
    }

    $json | Add-Member -Name $Key -Value $Value -MemberType NoteProperty -Force

    # Atomic write: write to temp file first, then rename to prevent corruption
    # if the process is interrupted mid-write (e.g., VM I/O hiccup during upgrade).
    $tempPath = "$Path.tmp"
    $json | ConvertTo-Json -Depth 32 | Set-Content -Force $tempPath
    Move-Item -Path $tempPath -Destination $Path -Force
}

<#
.SYNOPSIS
    Returns the installed K8s version if present.
.DESCRIPTION
    Returns the installed K8s version if present.
.EXAMPLE
    $version = Get-ConfigInstalledKubernetesVersion
.OUTPUTS
    The installed K8s version if present; otherwise 'unknown'
.NOTES
    Checks the local setup json file for the K8s version
#>
function Get-ConfigInstalledKubernetesVersion {
    $k8sVersion = Get-ConfigValue -Path $SetupJsonFile -Key 'KubernetesVersion'

    if ($k8sVersion) {
        return $k8sVersion
    }

    return 'unknown'
}

function Set-ConfigInstalledKubernetesVersion {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'KubernetesVersion' -Value $Value
}

function Get-ConfigInstallFolder {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'InstallFolder'
}

function Set-ConfigInstallFolder {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'InstallFolder' -Value $Value
}

function Get-ConfigProductVersion {
    $version = Get-ConfigValue -Path $SetupJsonFile -Key 'Version'
    if (-not [string]::IsNullOrEmpty($version)) {
        $version = $version.Trim()
    }
    return $version
}

function Set-ConfigProductVersion {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'Version' -Value $Value
}

function Get-ConfigUsedStorageLocalDriveLetter {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'UsedStorageLocalDriveLetter'
}

function Get-ConfigSetupType {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'SetupType'
}

function Set-ConfigSetupType {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'SetupType' -Value $Value
}

function Get-ConfigWslFlag {
    $wslValue = Get-ConfigValue -Path $SetupJsonFile -Key 'WSL'
    if ($null -eq $wslValue) {
        return $false
    }
    return $wslValue
}

function Set-ConfigWslFlag {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'WSL' -Value $Value
}


# Windows container image build is enabled or disabled. If enabled docker is installed.
function Get-ConfigWinBuildEnabledFlag {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'WinBuildEnabled'
}

function Set-ConfigWinBuildEnabledFlag {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'WinBuildEnabled' -Value $Value
}


function Get-ConfigLinuxOnly {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'LinuxOnly'
}

function Set-ConfigLinuxOnly {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'LinuxOnly' -Value $Value
}

function Set-ConfigUsedStorageLocalDriveLetter {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'UsedStorageLocalDriveLetter' -Value $Value
}

function Get-ConfigHostGW {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'HostGW'
}

function Set-ConfigHostGW {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'HostGW' -Value $Value
}

<#
.SYNOPSIS
    Name of the network adapter the l2 bridge is built on.
.DESCRIPTION
    Empty or absent for the default setup, where K2s creates a dedicated loopback
    adapter so it does not take over the NIC of the Windows host. A node that is a
    dedicated VM, such as the managed Windows worker of a native Linux host, sets
    this to its own Ethernet adapter instead.
#>
function Get-ConfigL2BridgeAdapterName {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'L2BridgeAdapterName'
}

function Set-ConfigL2BridgeAdapterName {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'L2BridgeAdapterName' -Value $Value
}

function Get-ConfigControlPlaneNodeHostname () {
    $hostname = Get-ConfigValue -Path $SetupJsonFile -Key 'ControlPlaneNodeHostname'

    if ($hostname) {
        return $hostname
    }

    return 'kubemaster'
}

function Set-ConfigControlPlaneNodeHostname($hostname) {
    Set-ConfigValue -Path $SetupJsonFile -Key 'ControlPlaneNodeHostname' -Value $hostname
    Write-Log "Saved VM hostname '$hostname' in file '$SetupJsonFile'"
}

<#
.SYNOPSIS
Returns the persisted log root from setup.json (key 'LogRoot') or $null when unset.
#>
function Get-ConfigLogRoot {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'LogRoot'
}

<#
.SYNOPSIS
Persists the resolved log root directory into setup.json under key 'LogRoot'.
.DESCRIPTION
Written at install time so that later script invocations and Go tools resolve the same
configured log directory without re-reading cfg/config.json.
#>
function Set-ConfigLogRoot {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Value
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'LogRoot' -Value $Value
}

function Get-ConfigVMNodeHostname () {
    $hostname = Get-ConfigValue -Path $SetupJsonFile -Key 'VMNodeHostname'

    if ($hostname) {
        return $hostname
    }

    return 'winnode'
}

function Set-ConfigVMNodeHostname($hostname) {
    Set-ConfigValue -Path $SetupJsonFile -Key 'VMNodeHostname' -Value $hostname
    Write-Log "Saved VM hostname '$hostname' in file '$SetupJsonFile'"
}

function Get-DefaultRegistry {
    return Get-ConfigValue -Path $SetupJsonFile -Key 'defaultRegistry'
}

function Get-RegistryToken() {
    # Read the token from the file
    $token = Get-Content -Path "$kubePath\bin\registry.dat" -Raw
    return [string]$token
}

function Get-MinimalProvisioningBaseMemorySize {
    return 2GB
}
function Get-MinimalProvisioningBaseImageDiskSize {
    return 10GB
}
function Get-DefaultK8sVersion {
    return 'v1.37.2'
}

<#
.SYNOPSIS
Gets the configured proxy overrides for the user in windows. Proxy overrides are the hosts for which the requests must not
be forwarded to the proxy. Should be called only when Proxy is enabled.

.DESCRIPTION
When proxy settings are configured for the user in Windows, the proxy overrides are configured in the registry key
HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyOverrides
#>
function Get-ProxyOverrideFromWindowsSettings {
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    return $reg.ProxyOverride
}

function Get-LinuxLocalSharePath {
    return $linuxLocalSharePath
}

function Get-WindowsLocalSharePath {
    return $windowsLocalSharePath
}

function Get-MirrorRegistries {
    $rootConfig = Get-RootConfigk2s
    $mirrorRegistries = $rootConfig.psobject.properties['mirrorRegistries'].value
    return $mirrorRegistries
}

function Get-InstalledClusterName {
    $value = Get-ConfigValue -Path $SetupJsonFile -Key 'ClusterName'
    if ($value) {
        return $value
    }
    return $legacyClusterName
}

function Set-InstalledClusterName {
    param (
        [object] $Value = $(throw 'Please provide the config value.')
    )
    Set-ConfigValue -Path $SetupJsonFile -Key 'ClusterName' -Value $Value
}

<#
.SYNOPSIS
    Returns the cloud image configuration for a supported distribution.
.DESCRIPTION
    Looks up the cloudImage block (urlRoot, urlFile) for the given OS key
    from the supportedWorkerOS array in cfg/config.json.
    Throws if the OS is not listed or has no cloudImage entry.
.PARAMETER OS
    The distribution key (e.g. 'debian12', 'debian13').
#>
function Get-DistributionCloudImage {
    param (
        [string] $OS = $(throw 'Argument missing: OS')
    )
    foreach ($entry in $rootConfig.supportedWorkerOS) {
        if ($entry.os -eq $OS) {
            if (-not $entry.cloudImage) {
                throw "No 'cloudImage' configuration found for OS '$OS' in cfg/config.json"
            }
            return $entry.cloudImage
        }
    }
    $supported = ($rootConfig.supportedWorkerOS | ForEach-Object { $_.os }) -join ', '
    throw "OS '$OS' not found in supportedWorkerOS in cfg/config.json. Supported: $supported"
}

Export-ModuleMember -Function Get-ConfigValue,
Set-ConfigValue,
Get-ConfiguredKubeConfigDir,
Get-k2sConfigFilePath,
Get-SetupConfigFilePath,
Get-K2sConfigDir,
Get-KubernetesImagesFilePath,
Get-ProductVersion,
Get-SSHKeyControlPlane,
Get-ConfiguredIPControlPlane,
Get-ConfigSetupType,
Get-ConfigUsedStorageLocalDriveLetter,
Get-ConfiguredStorageLocalDriveLetter,
Get-ConfiguredstorageLocalDriveFolder,
Get-ConfigInstalledKubernetesVersion,
Get-ConfiguredDockerConfigDir,
Get-ConfiguredClusterCIDR,
Get-ConfiguredKubeSwitchIP,
Get-ConfiguredControlPlaneCIDR,
Get-ConfiguredClusterCIDRServices,
Get-ConfiguredKubeDnsServiceIP,
Get-ConfiguredMasterNetworkInterfaceCni0IP,
Get-ConfigControlPlaneNodeHostname,
Get-SSHKeyFileName,
Set-ConfigSetupType,
Get-ConfigWslFlag,
Set-ConfigWslFlag,
Get-ConfigLinuxOnly,
Set-ConfigLinuxOnly,
Get-RootConfigk2s,
Set-ConfigUsedStorageLocalDriveLetter,
Set-ConfigInstalledKubernetesVersion,
Get-ConfigInstallFolder,
Set-ConfigInstallFolder,
Get-ConfigProductVersion,
Set-ConfigProductVersion,
Get-ConfigHostGW,
Set-ConfigHostGW,
Get-ConfigL2BridgeAdapterName,
Set-ConfigL2BridgeAdapterName,
Set-ConfigControlPlaneNodeHostname,
Get-ConfigLogRoot,
Set-ConfigLogRoot,
Get-ControlPlaneNodeDefaultSwitchName,
Get-ConfigVMNodeHostname,
Set-ConfigVMNodeHostname,
Get-DefaultRegistry,
Get-RegistryToken,
Get-SshConfigDir,
Get-MinimalProvisioningBaseImageDiskSize,
Get-MinimalProvisioningBaseMemorySize,
Get-RootConfig,
Get-DefaultTempPwd,
Get-DefaultK8sVersion,
Get-LinuxLocalSharePath,
Get-WindowsLocalSharePath,
Get-ConfigWinBuildEnabledFlag,
Set-ConfigWinBuildEnabledFlag,
Get-ConfiguredClusterNetworkPrefix,
Get-MirrorRegistries,
Get-ClusterName,
Get-InstalledClusterName,
Set-InstalledClusterName,
Update-SetupConfigDir,
Get-DistributionCloudImage
