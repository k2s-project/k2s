# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Removes Ceph's native SMB (mgr/smb) configuration from an existing Ceph cluster.

.DESCRIPTION
Invoked by the storage/ceph addon Disable.ps1. Copies remove-ceph-cluster-smb.sh to
the Ceph cluster host identified by -NodeIp and runs it remotely to remove the
mgr/smb cluster (and its shares) and drop the cephadm placement label so the managed
Samba daemons are undeployed. The underlying CephFS volume and the Ceph cluster stay
intact.

.PARAMETER NodeIp
IP address of the Ceph cluster host (resolved from ceph-config.json 'clusterHost.node').

.PARAMETER Config
The parsed ceph-config.json object.

.PARAMETER SmbClusterId
mgr/smb cluster identifier to remove.

.PARAMETER PlacementLabel
cephadm host label to drop from the Samba placement.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'IP address of the Ceph cluster host')]
    [string] $NodeIp,
    [parameter(Mandatory = $false, HelpMessage = 'Parsed ceph-config.json object')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'mgr/smb cluster id')]
    [string] $SmbClusterId = 'k2ssmb',
    [parameter(Mandatory = $false, HelpMessage = 'cephadm host placement label for the Samba daemons')]
    [string] $PlacementLabel = 'smb',
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot/../../../../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../../../lib/modules/windows/node/k2s.node.module/k2s.node.module.psm1"
$clusterConfigModule = "$PSScriptRoot/../../../../../../lib/modules/windows/infra/k2s.infra.module/config/cluster.config.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterConfigModule
Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "[CephSMB] Removing Ceph mgr/smb configuration from cluster host '$NodeIp'" -Console

# Resolve the SSH user for the Ceph cluster host, mirroring New-CephCluster.ps1.
$clusterHostConfig = if ($Config -and ($Config.PSObject.Properties.Name -contains 'clusterHost')) { $Config.clusterHost } else { $null }
$clusterHostNode = if ($null -ne $clusterHostConfig -and ($clusterHostConfig.PSObject.Properties.Name -contains 'node')) { "$($clusterHostConfig.node)".Trim() } else { '' }
$controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
if (-not [string]::IsNullOrWhiteSpace($clusterHostNode) -and $clusterHostNode -eq $controlPlaneNodeName) {
    $nodeUserName = "$(Get-DefaultUserNameControlPlane)".Trim()
    if ([string]::IsNullOrWhiteSpace($nodeUserName)) { $nodeUserName = 'remote' }
}
else {
    $nodeConfig = $null
    if (-not [string]::IsNullOrWhiteSpace($clusterHostNode)) {
        $nodeConfig = Get-NodeConfig -NodeName $clusterHostNode
    }
    $nodeUserName = if ($null -eq $nodeConfig) { 'remote' } else { $nodeConfig.Username }
}

$scriptSourcePath = "$PSScriptRoot\remove-ceph-cluster-smb.sh"
if (-not (Test-Path $scriptSourcePath)) {
    Write-Log "[CephSMB] WARNING: Removal script not found at '$scriptSourcePath'; skipping mgr/smb teardown." -Console
    return
}

# Resolve the CephFS volume and shared subvolume so the SMB teardown can also remove the subvolume.
$cephfsVolume = if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.cephfsFilesystem)) { "$($Config.cephfsFilesystem)".Trim() } else { 'cephfs' }
$smbSubvolume = if ($Config -and ($Config.PSObject.Properties.Name -contains 'smb') -and $null -ne $Config.smb -and ($Config.smb.PSObject.Properties.Name -contains 'subvolume') -and -not [string]::IsNullOrWhiteSpace($Config.smb.subvolume)) { "$($Config.smb.subvolume)".Trim() } else { '' }
$smbSubvolumeGroup = if ($Config -and ($Config.PSObject.Properties.Name -contains 'smb') -and $null -ne $Config.smb -and ($Config.smb.PSObject.Properties.Name -contains 'subvolumeGroup') -and -not [string]::IsNullOrWhiteSpace($Config.smb.subvolumeGroup)) { "$($Config.smb.subvolumeGroup)".Trim() } else { '' }

try {
    Invoke-RemoteScript -LocalScriptPath $scriptSourcePath `
        -UserName $nodeUserName `
        -IpAddress $NodeIp `
        -UserPwd '' `
        -Arguments @($SmbClusterId, $PlacementLabel, $cephfsVolume, $smbSubvolume, $smbSubvolumeGroup) `
        -CleanupAfterExecution `
        -Retries 0 -DetailedLogging | Out-Null

    Write-Log "[CephSMB] Ceph mgr/smb configuration removed for cluster '$SmbClusterId'." -Console
}
catch {
    Write-Log "[CephSMB] WARNING: Ceph mgr/smb teardown reported an error (continuing): $($_.Exception.Message)" -Console
}
