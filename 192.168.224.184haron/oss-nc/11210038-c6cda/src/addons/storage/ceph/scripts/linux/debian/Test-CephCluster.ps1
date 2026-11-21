# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Verifies that an existing Ceph cluster is reachable over SSH and that its live identity matches
the values in ceph-config.json.

.DESCRIPTION
Invoked by the storage/ceph addon Enable.ps1 when ceph-config.json 'clusterMode' is 'existing'
(and 'clusterHostNodeIp' is set). Copies verify-ceph-cluster.sh to the node identified by -NodeIp,
executes it remotely to read the live cluster fsid, CephFS filesystems and pools, and compares them
against the configured 'clusterId', 'cephfsFilesystem' and 'cephfsPool'.

Exits 0 when the node is reachable and the cluster identity matches; exits 1 (with logged details)
when SSH fails, the cluster cannot be queried, or the identity does not match the configuration.

.PARAMETER NodeIp
IP address of the node that hosts the Ceph cluster (ceph-config.json 'clusterHostNodeIp').

.PARAMETER Config
The parsed ceph-config.json object (provides 'clusterHost.node', 'clusterId', 'cephfsFilesystem',
'cephfsPool').

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'IP address of the Ceph host node')]
    [string] $NodeIp,
    [parameter(Mandatory = $false, HelpMessage = 'Parsed ceph-config.json object')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot/../../../../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../../../lib/modules/windows/node/k2s.node.module/k2s.node.module.psm1"
$clusterConfigModule = "$PSScriptRoot/../../../../../../lib/modules/windows/infra/k2s.infra.module/config/cluster.config.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterConfigModule
Initialize-Logging -ShowLogs:$ShowLogs

function Get-CephClusterHostNodeName {
    param(
        [pscustomobject]$Config
    )

    if ($null -eq $Config) {
        return ''
    }

    if (($Config.PSObject.Properties.Name -contains 'clusterHost') -and $null -ne $Config.clusterHost -and ($Config.clusterHost.PSObject.Properties.Name -contains 'node')) {
        return "$($Config.clusterHost.node)".Trim()
    }

    return ''
}

Write-Log "[Ceph] Verifying connectivity to existing Ceph cluster on node '$NodeIp'" -Console

# Resolve the SSH user for the node from cluster.json (falls back to 'remote' when the node is
# not a registered K2s node).
$clusterHostNode = Get-CephClusterHostNodeName -Config $Config
$nodeConfig = $null
if (-not [string]::IsNullOrWhiteSpace($clusterHostNode)) {
    $nodeConfig = Get-NodeConfig -NodeName $clusterHostNode
}

if ($null -eq $nodeConfig) {
    Write-Log "[Ceph] WARNING: Node '$clusterHostNode' not found in cluster.json; falling back to NodeIp='$NodeIp' and userName='remote'" -Console
    $nodeUserName = 'remote'
} else {
    $nodeUserName = $nodeConfig.Username
    Write-Log "[Ceph] Resolved node connection from cluster.json: UserName='$nodeUserName', IpAddress='$($nodeConfig.IpAddress)'" -Console
}

$scriptSourcePath = "$PSScriptRoot\verify-ceph-cluster.sh"

$scriptOutput = $null
try {
    $scriptOutput = Invoke-RemoteScript -LocalScriptPath $scriptSourcePath `
                        -UserName $nodeUserName `
                        -IpAddress $NodeIp `
                        -UserPwd '' `
                        -CleanupAfterExecution `
                        -Retries 2 -DetailedLogging
}
catch {
    Write-Log "[Ceph] ERROR: SSH connection to node '$NodeIp' failed: $($_.Exception.Message)" -Console -Error
    exit 1
}

$outputText = ($scriptOutput | Out-String)

# Parse the K2S_CEPH_* markers emitted by verify-ceph-cluster.sh.
$liveFsid = $null
$liveFsList = ''
$livePoolList = ''
foreach ($line in ($outputText -split "`r?`n")) {
    if ($line -match '^K2S_CEPH_FSID=(.+)$') { $liveFsid = $Matches[1].Trim() }
    elseif ($line -match '^K2S_CEPH_FS_LIST=(.*)$') { $liveFsList = $Matches[1].Trim() }
    elseif ($line -match '^K2S_CEPH_POOL_LIST=(.*)$') { $livePoolList = $Matches[1].Trim() }
}

if ([string]::IsNullOrWhiteSpace($liveFsid)) {
    Write-Log "[Ceph] ERROR: Could not retrieve Ceph cluster identity from node '$NodeIp' (cluster unreachable, admin keyring missing, or 'ceph' not available)." -Console -Error
    exit 1
}

Write-Log "[Ceph] Live cluster identity: fsid='$liveFsid', filesystems='$liveFsList', pools='$livePoolList'"

# Compare the live identity against the configured values.
$expectedFsid = if ($Config) { "$($Config.clusterId)".Trim() } else { '' }
$expectedFs = if ($Config) { "$($Config.cephfsFilesystem)".Trim() } else { '' }
$expectedPool = if ($Config) { "$($Config.cephfsPool)".Trim() } else { '' }

$mismatch = $false

if (-not [string]::IsNullOrWhiteSpace($expectedFsid) -and ($liveFsid -ne $expectedFsid)) {
    Write-Log "[Ceph] ERROR: Cluster ID mismatch. ceph-config.json clusterId='$expectedFsid' but the live cluster fsid='$liveFsid'." -Console -Error
    $mismatch = $true
}

if (-not [string]::IsNullOrWhiteSpace($expectedFs)) {
    $fsNames = @($liveFsList -split '\s+' | Where-Object { $_ })
    if ($fsNames -notcontains $expectedFs) {
        Write-Log "[Ceph] ERROR: CephFS filesystem '$expectedFs' not found on the cluster (available: '$liveFsList')." -Console -Error
        $mismatch = $true
    }
}

if (-not [string]::IsNullOrWhiteSpace($expectedPool)) {
    $poolNames = @($livePoolList -split '\s+' | Where-Object { $_ })
    if ($poolNames -notcontains $expectedPool) {
        Write-Log "[Ceph] ERROR: CephFS pool '$expectedPool' not found on the cluster (available: '$livePoolList')." -Console -Error
        $mismatch = $true
    }
}

if ($mismatch) {
    exit 1
}

Write-Log "[Ceph] Existing Ceph cluster is reachable and its identity matches ceph-config.json" -Console
exit 0
