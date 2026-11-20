# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Configures Ceph's native SMB (mgr/smb) support on an existing Ceph cluster.

.DESCRIPTION
Invoked by the storage/ceph addon Enable.ps1 when the addon is enabled with the
-w / setupWindowsNode flag. Copies create-ceph-cluster-smb.sh to the Ceph cluster
host identified by -NodeIp and runs it remotely to enable the mgr/smb module, label
the host, and create an SMB cluster + share that exports the given CephFS volume
(https://docs.ceph.com/en/latest/mgr/smb/). Returns the SMB user, password and share
name so Enable.ps1 can create the matching smbcreds Secret and StorageClass for the
SMB CSI driver.

.PARAMETER NodeIp
IP address of the Ceph cluster host (resolved from ceph-config.json 'clusterHost.node').

.PARAMETER Config
The parsed ceph-config.json object.

.PARAMETER CephfsVolume
Name of the existing CephFS volume to export over SMB.

.PARAMETER SmbClusterId
mgr/smb cluster identifier to create.

.PARAMETER SmbShareId
mgr/smb share identifier to create.

.PARAMETER SmbShareName
SMB share name presented to clients.

.PARAMETER PlacementLabel
cephadm host label used to place the Samba daemons.

.PARAMETER CephfsSubvolume
Name of the shared CephFS subvolume to create and export over SMB. Both operating systems address
the same physical storage; the SMB CSI StorageClass places each PVC in an isolated
'<namespace>/<name>' sub-directory inside it. When empty, the CephFS root path is exported instead.

.PARAMETER CephfsSubvolumeSizeInGb
Size of the shared CephFS subvolume in GiB (quota). Ignored when CephfsSubvolume is empty.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'IP address of the Ceph cluster host')]
    [string] $NodeIp,
    [parameter(Mandatory = $false, HelpMessage = 'Parsed ceph-config.json object')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $true, HelpMessage = 'Existing CephFS volume to export over SMB')]
    [string] $CephfsVolume,
    [parameter(Mandatory = $false, HelpMessage = 'mgr/smb cluster id')]
    [string] $SmbClusterId = 'k2ssmb',
    [parameter(Mandatory = $false, HelpMessage = 'mgr/smb share id')]
    [string] $SmbShareId = 'cephfs',
    [parameter(Mandatory = $false, HelpMessage = 'SMB share name presented to clients')]
    [string] $SmbShareName = 'cephfs',
    [parameter(Mandatory = $false, HelpMessage = 'cephadm host placement label for the Samba daemons')]
    [string] $PlacementLabel = 'smb',
    [parameter(Mandatory = $false, HelpMessage = 'Shared CephFS subvolume to create and export over SMB')]
    [string] $CephfsSubvolume = '',
    [parameter(Mandatory = $false, HelpMessage = 'Size of the shared CephFS subvolume in GiB')]
    [int] $CephfsSubvolumeSizeInGb = 0,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot/../../../../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../../../lib/modules/windows/node/k2s.node.module/k2s.node.module.psm1"
$clusterConfigModule = "$PSScriptRoot/../../../../../../lib/modules/windows/infra/k2s.infra.module/config/cluster.config.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterConfigModule
Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "[CephSMB] Configuring Ceph mgr/smb on cluster host '$NodeIp'" -Console

<#
.SYNOPSIS
Reads the Ceph image reference from the storage addon manifest.
#>
function Get-CephImageFromStorageManifest {
    $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\addon.manifest.yaml'
    $manifestPath = [System.IO.Path]::GetFullPath($manifestPath)

    if (!(Test-Path -Path $manifestPath)) {
        throw "[CephSMB] Storage addon manifest not found at '$manifestPath'"
    }

    $imageRef = Get-Content -Path $manifestPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -like '- quay.io/ceph/ceph:*' } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($imageRef)) {
        throw "[CephSMB] No quay.io/ceph/ceph:<tag> image found in storage addon additionalImages in '$manifestPath'"
    }

    return ($imageRef -replace '^-\s*', '')
}

<#
.SYNOPSIS
Generates a random alphanumeric password safe for SMB and shell/argument passing.

.DESCRIPTION
Excludes the '%' character (the mgr/smb user/pass delimiter) and any shell-special
characters by using only [A-Za-z0-9].
#>
function New-CephSmbPassword {
    param([int]$Length = 24)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'.ToCharArray()
    $bytes = New-Object 'System.Byte[]' $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

Function Set-CephSmbClusterOnNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$CephImage = $(throw 'Argument missing: CephImage'),
        [string]$CephfsVolume = $(throw 'Argument missing: CephfsVolume'),
        [string]$SmbClusterId = 'k2ssmb',
        [string]$SmbShareId = 'cephfs',
        [string]$SmbShareName = 'cephfs',
        [string]$SmbUser = $(throw 'Argument missing: SmbUser'),
        [string]$SmbPwd = $(throw 'Argument missing: SmbPwd'),
        [string]$SmbPath = '/',
        [string]$PlacementLabel = 'smb',
        [string]$Subvolume = '',
        [string]$SubvolumeSizeBytes = '',
        [string]$SubvolumeGroup = ''
    )

    Write-Log '[CephSMB] Running remote Ceph mgr/smb configuration'

    $scriptSourcePath = "$PSScriptRoot\create-ceph-cluster-smb.sh"

    $scriptOutput = Invoke-RemoteScript -LocalScriptPath $scriptSourcePath `
                        -UserName $UserName `
                        -IpAddress $IpAddress `
                        -UserPwd $UserPwd `
                        -Arguments @($CephImage, $CephfsVolume, $SmbClusterId, $SmbShareId, $SmbShareName, $SmbUser, $SmbPwd, $SmbPath, $PlacementLabel, $Subvolume, $SubvolumeSizeBytes, $SubvolumeGroup) `
                        -CleanupAfterExecution `
                        -Retries 0 -DetailedLogging

    Write-Log '[CephSMB] Finished remote Ceph mgr/smb configuration'

    return $scriptOutput
}

# Resolve the SSH user for the Ceph cluster host, mirroring New-CephCluster.ps1.
$clusterHostConfig = if ($Config -and ($Config.PSObject.Properties.Name -contains 'clusterHost')) { $Config.clusterHost } else { $null }
$clusterHostNode = if ($null -ne $clusterHostConfig -and ($clusterHostConfig.PSObject.Properties.Name -contains 'node')) { "$($clusterHostConfig.node)".Trim() } else { '' }
$controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
if (-not [string]::IsNullOrWhiteSpace($clusterHostNode) -and $clusterHostNode -eq $controlPlaneNodeName) {
    $nodeUserName = "$(Get-DefaultUserNameControlPlane)".Trim()
    if ([string]::IsNullOrWhiteSpace($nodeUserName)) { $nodeUserName = 'remote' }
    Write-Log "[CephSMB] Resolved control plane node connection: UserName='$nodeUserName', IpAddress='$NodeIp'" -Console
}
else {
    $nodeConfig = $null
    if (-not [string]::IsNullOrWhiteSpace($clusterHostNode)) {
        $nodeConfig = Get-NodeConfig -NodeName $clusterHostNode
    }

    if ($null -eq $nodeConfig) {
        Write-Log "[CephSMB] WARNING: Node '$clusterHostNode' not found in cluster.json; falling back to NodeIp='$NodeIp' and userName='remote'" -Console
        $nodeUserName = 'remote'
    }
    else {
        $nodeUserName = $nodeConfig.Username
        Write-Log "[CephSMB] Resolved node connection from cluster.json: UserName='$nodeUserName', IpAddress='$($nodeConfig.IpAddress)'" -Console
    }
}

# Resolve the SMB user (optionally overridable via ceph-config.json 'smb.userName') and a fresh password.
$smbUser = if ($Config -and ($Config.PSObject.Properties.Name -contains 'smb') -and $null -ne $Config.smb -and ($Config.smb.PSObject.Properties.Name -contains 'userName') -and -not [string]::IsNullOrWhiteSpace($Config.smb.userName)) { "$($Config.smb.userName)".Trim() } else { 'smbuser' }
$smbPath = if ($Config -and ($Config.PSObject.Properties.Name -contains 'smb') -and $null -ne $Config.smb -and ($Config.smb.PSObject.Properties.Name -contains 'path') -and -not [string]::IsNullOrWhiteSpace($Config.smb.path)) { "$($Config.smb.path)".Trim() } else { '/' }
$smbPassword = New-CephSmbPassword

# Convert the requested subvolume size (GiB) to bytes for 'ceph fs subvolume create --size='.
$subvolumeSizeBytes = ''
if ($CephfsSubvolumeSizeInGb -gt 0) {
    $subvolumeSizeBytes = "$([int64]$CephfsSubvolumeSizeInGb * 1024 * 1024 * 1024)"
}

$cephImage = Get-CephImageFromStorageManifest
Write-Log "[CephSMB] Using Ceph image from addon manifest: $cephImage" -Console

$smbOutput = Set-CephSmbClusterOnNode -UserName $nodeUserName `
                -UserPwd '' `
                -IpAddress $NodeIp `
                -CephImage $cephImage `
                -CephfsVolume $CephfsVolume `
                -SmbClusterId $SmbClusterId `
                -SmbShareId $SmbShareId `
                -SmbShareName $SmbShareName `
                -SmbUser $smbUser `
                -SmbPwd $smbPassword `
                -SmbPath $smbPath `
                -PlacementLabel $PlacementLabel `
                -Subvolume $CephfsSubvolume `
                -SubvolumeSizeBytes $subvolumeSizeBytes

$smbOutputText = ($smbOutput | Out-String)
if ($smbOutputText -notmatch 'K2S_CEPH_SMB_SHARE=') {
    Write-Log '[CephSMB] ERROR: Remote Ceph mgr/smb configuration did not report success (missing K2S_CEPH_SMB_SHARE marker).' -Console -Error
    Write-Log "[CephSMB] Remote output:`n$smbOutputText" -Console
    exit 1
}

Write-Log "[CephSMB] Ceph mgr/smb configured: share '$SmbShareName' (cluster '$SmbClusterId') exporting CephFS volume '$CephfsVolume'." -Console

return [pscustomobject]@{
    SmbUser         = $smbUser
    SmbPassword     = $smbPassword
    SmbShareName    = $SmbShareName
    SmbClusterId    = $SmbClusterId
    CephfsSubvolume = $CephfsSubvolume
}
