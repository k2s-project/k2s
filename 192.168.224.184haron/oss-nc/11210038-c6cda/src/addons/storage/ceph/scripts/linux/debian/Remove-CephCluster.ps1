# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Tears down a Ceph cluster previously provisioned on a Debian Linux target node.

.DESCRIPTION
Invoked by the storage/ceph addon Disable.ps1 when the addon had provisioned a NEW
Ceph cluster (ceph-config.json 'clusterMode' != 'existing' and 'clusterDistribution'
resolves to 'debian12' or 'debian13'). Copies remove-ceph-cluster.sh to the node identified by -NodeIp
and executes it remotely to remove the cephadm cluster and the artifacts that
create-ceph-cluster.sh installed (cephadm binary, Ceph apt repo/packages, container images).

.PARAMETER NodeIp
IP address of the node that hosts the Ceph cluster (ceph-config.json 'clusterHostNodeIp').

.PARAMETER Config
The parsed ceph-config.json object (provides 'clusterHost.node').

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

Write-Log "[Ceph] Removing Ceph cluster from node '$NodeIp'" -Console

<#
.SYNOPSIS
Runs the Debian Ceph cluster teardown script on the target node.

.DESCRIPTION
Copies remove-ceph-cluster.sh to the target node and executes it remotely. The script removes
every Ceph cluster found on the node along with the cephadm binary, apt repo/packages and
container images that create-ceph-cluster.sh installed.
#>
Function Remove-CephClusterOnNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [string]$InstalledDistribution = 'debian'
    )

    Write-Log '[Ceph] Tearing down Ceph cluster'

    $scriptSourcePath = "$PSScriptRoot\remove-ceph-cluster.sh"

    $scriptOutput = Invoke-RemoteScript -LocalScriptPath $scriptSourcePath `
                        -UserName $UserName `
                        -IpAddress $IpAddress `
                        -UserPwd $UserPwd `
                        -CleanupAfterExecution `
                        -Retries 2 -DetailedLogging

    Write-Log '[Ceph] Finished Ceph cluster teardown'

    return $scriptOutput
}

$clusterHostNode = Get-CephClusterHostNodeName -Config $Config
$controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
if (-not [string]::IsNullOrWhiteSpace($clusterHostNode) -and $clusterHostNode -eq $controlPlaneNodeName) {
    # The K2s control plane node (e.g. 'kubemaster') is NOT stored in cluster.json, so its SSH user
    # comes from the control-plane configuration rather than from Get-NodeConfig.
    $nodeUserName = "$(Get-DefaultUserNameControlPlane)".Trim()
    if ([string]::IsNullOrWhiteSpace($nodeUserName)) { $nodeUserName = 'remote' }
    Write-Log "[Ceph] Resolved control plane node connection: UserName='$nodeUserName', IpAddress='$NodeIp'" -Console
}
else {
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
}

Remove-CephClusterOnNode -UserName $nodeUserName `
                         -UserPwd '' `
                         -IpAddress $NodeIp `
                         -InstalledDistribution 'debian'
