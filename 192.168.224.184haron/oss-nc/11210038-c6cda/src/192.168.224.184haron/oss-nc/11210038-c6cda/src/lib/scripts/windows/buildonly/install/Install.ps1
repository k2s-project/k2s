# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Control Plane VM (Linux)')]
    [long] $MasterVMMemory = 6GB,
    [parameter(Mandatory = $false, HelpMessage = 'Minimum Memory for Dynamic Memory (Linux Control Plane VM)')]
    [long] $MasterVMMemoryMin = 0,
    [parameter(Mandatory = $false, HelpMessage = 'Maximum Memory for Dynamic Memory (Linux Control Plane VM)')]
    [long] $MasterVMMemoryMax = 0,
    [parameter(Mandatory = $false, HelpMessage = 'Enable Hyper-V Dynamic Memory for Control Plane VM')]
    [switch] $EnableDynamicMemory = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for Control Plane VM (Linux)')]
    [long] $MasterVMProcessorCount = 6,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of Control Plane VM (Linux)')]
    [uint64] $MasterDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'No proxy hosts/domains (comma-separated list or array)')]
    [string[]] $NoProxy,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting Control Plane VM')]
    [switch] $WSL = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Append to log file (do not start from scratch)')]
    [switch] $AppendLogFile = $false,
    [parameter(Mandatory = $true, HelpMessage = 'Internal normalized effective install configuration path')]
    [string] $EffectiveInstallConfigPath
)

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule =   "$PSScriptRoot\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs
Reset-LogFile -AppendLogFile:$AppendLogFile

$ErrorActionPreference = 'Continue'

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

# set defaults for unset arguments
$script:SetupType = 'BuildOnlyEnv'
Set-ConfigSetupType -Value $script:SetupType

Write-Log '[Precheck] Running control-plane prerequisites at install start'
Test-ControlPlanePrerequisites `
    -MasterVMProcessorCount $MasterVMProcessorCount `
    -MasterVMMemory $MasterVMMemory `
    -MasterDiskSize $MasterDiskSize `
    -WSL:$WSL `
    -ForceOnlineInstallation:$ForceOnlineInstallation

$installationType = 'Build-only'
Write-Log "Installing $installationType setup"

# Initialize the proxy settings before starting installation.
Test-ProxyEnvVarsConfiguration

# Initialize the proxy settings before starting installation.
$Proxy = New-ProxyConfig -Proxy:$Proxy -NoProxy:$NoProxy
Add-K2sHostsToNoProxyEnvVar

$loopbackAdapter = Get-L2BridgeName
$dnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
if ([string]::IsNullOrWhiteSpace($dnsServers)) {
    $dnsServers = '8.8.8.8,8.8.4.4'
}

# Auto-enable dynamic memory if min or max are specified
if ($MasterVMMemoryMin -gt 0 -or $MasterVMMemoryMax -gt 0) {
    $EnableDynamicMemory = $true
    Write-Log "Dynamic memory auto-enabled (min or max specified)"
}

$controlPlaneNodeParams = @{
    MasterVMMemory = $MasterVMMemory
    MasterVMMemoryMin = $MasterVMMemoryMin
    MasterVMMemoryMax = $MasterVMMemoryMax
    EnableDynamicMemory = $EnableDynamicMemory
    MasterVMProcessorCount = $MasterVMProcessorCount
    MasterDiskSize = $MasterDiskSize
    Proxy = $Proxy
    DnsAddresses = $dnsServers
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation = $ForceOnlineInstallation
    CheckOnly = $false
    ShowLogs = $ShowLogs
    WSL = $WSL
    EffectiveInstallConfigPath = $EffectiveInstallConfigPath
}
& "$PSScriptRoot\..\..\..\control-plane\Install.ps1" @controlPlaneNodeParams

Install-WinNodeArtifacts -Proxy $Proxy -SkipClusterSetup $true $PodSubnetworkNumber '1' -HostVM $false

Write-Log '---------------------------------------------------------------'
Write-Log "$installationType setup finished.  Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

Write-RefreshEnvVariables
