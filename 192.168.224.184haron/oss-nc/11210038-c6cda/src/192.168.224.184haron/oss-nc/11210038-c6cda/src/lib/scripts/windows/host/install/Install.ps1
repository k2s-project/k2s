# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    # Main parameters
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Control Plane VM (Linux)')]
    [long] $MasterVMMemory = 8GB,
    [parameter(Mandatory = $false, HelpMessage = 'Minimum Memory Size for Control Plane VM when Dynamic Memory is enabled')]
    [long] $MasterVMMemoryMin = 0,
    [parameter(Mandatory = $false, HelpMessage = 'Maximum Memory Size for Control Plane VM when Dynamic Memory is enabled')]
    [long] $MasterVMMemoryMax = 0,
    [parameter(Mandatory = $false, HelpMessage = 'Enable Dynamic Memory for Control Plane VM (Hyper-V only)')]
    [switch] $EnableDynamicMemory = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for Control Plane VM (Linux)')]
    [long] $MasterVMProcessorCount = 6,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of Control Plane VM (Linux)')]
    [uint64] $MasterDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'No proxy hosts/domains (comma-separated list or array)')]
    [string[]] $NoProxy,
    [parameter(Mandatory = $false, HelpMessage = 'DNS Addresses if available')]
    [string[]]$DnsAddresses,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,

    # These are specific developer options
    [parameter(Mandatory = $false, HelpMessage = 'Exit after initial checks')]
    [switch] $CheckOnly = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Do not call the StartK8s at end')]
    [switch] $SkipStart = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Restart N number of times after Install')]
    [long] $RestartAfterInstallCount = 0,
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting Control Plane VM')]
    [switch] $WSL = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Append to log file (do not start from scratch)')]
    [switch] $AppendLogFile = $false,
    [parameter(Mandatory = $false, HelpMessage = 'The path to local builds of Kubernetes binaries')]
    [string] $K8sBinsPath = '',
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
$script:SetupType = 'k2s'
Set-ConfigSetupType -Value $script:SetupType

Write-Log '[Precheck] Running control-plane prerequisites at install start'
Test-ControlPlanePrerequisites `
    -MasterVMProcessorCount $MasterVMProcessorCount `
    -MasterVMMemory $MasterVMMemory `
    -MasterDiskSize $MasterDiskSize `
    -WSL:$WSL `
    -ForceOnlineInstallation:$ForceOnlineInstallation

# Initialize the proxy settings before starting installation.
Test-ProxyEnvVarsConfiguration

$Proxy = New-ProxyConfig -Proxy:$Proxy -NoProxy:$NoProxy
Add-K2sHostsToNoProxyEnvVar

$dnsServers = $DnsAddresses -join ','
if ([string]::IsNullOrWhiteSpace($dnsServers)) {
    $loopbackAdapter = Get-L2BridgeName
    $dnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
    if ([string]::IsNullOrWhiteSpace($dnsServers)) {
        $dnsServers = '8.8.8.8,8.8.4.4'
    }
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
    AdditionalHooksDir = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation = $ForceOnlineInstallation
    CheckOnly = $CheckOnly
    ShowLogs = $ShowLogs
    WSL = $WSL
    EffectiveInstallConfigPath = $EffectiveInstallConfigPath
}
& "$PSScriptRoot\..\..\..\control-plane\Install.ps1" @controlPlaneNodeParams

$workerNodeParams = @{
    ShowLogs = $ShowLogs
    AdditionalHooksDir = $AdditionalHooksDir
    Proxy = $Proxy
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation = $ForceOnlineInstallation
    DnsAddresses = $dnsServers
    K8sBinsPath = $K8sBinsPath
    EffectiveInstallConfigPath = $EffectiveInstallConfigPath
}
& "$PSScriptRoot\..\..\..\windows\worker\windows-host\Install.ps1" @workerNodeParams

# show results
Write-Log "Current state of kubernetes nodes:`n"
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide

Invoke-Hook -HookName 'AfterBaseInstall' -AdditionalHooksDir $AdditionalHooksDir

if (-not $SkipStart) {
    Write-Log 'Starting K2s'
    & "$PSScriptRoot\..\start\Start.ps1" -ShowLogs:$ShowLogs -SkipHeaderDisplay:$true

    if ($RestartAfterInstallCount -gt 0) {
        $restartCount = 0;

        while ($true) {
            $restartCount++
            Write-Log "Restarting k2s (iteration #$restartCount):"

            & "$PSScriptRoot\..\stop\Stop.ps1" -ShowLogs:$ShowLogs -SkipHeaderDisplay:$true
            Start-Sleep 10

            & "$PSScriptRoot\..\start\Start.ps1" -ShowLogs:$ShowLogs -SkipHeaderDisplay:$true
            Start-Sleep -s 5

            if ($restartCount -eq $RestartAfterInstallCount) {
                Write-Log 'Restarting k2s Completed'
                break;
            }
        }
    }
} else {
    Write-Log 'Skipping start of K2s as requested.'
    & "$PSScriptRoot\..\stop\Stop.ps1" -ShowLogs:$ShowLogs -SkipHeaderDisplay:$true
}

Write-Log '---------------------------------------------------------------'
Write-Log "K2s setup finished.   Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

Write-RefreshEnvVariables
