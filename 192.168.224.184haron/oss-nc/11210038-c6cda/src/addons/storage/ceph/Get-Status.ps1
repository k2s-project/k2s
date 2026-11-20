# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Get status of Ceph CSI storage addon

.DESCRIPTION
Returns detailed status of Ceph CSI provisioner deployment.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

$storageClassName = 'ceph-cephfs'
$cephConfigPath = "$PSScriptRoot\config\ceph-config.json"
if (Test-Path $cephConfigPath) {
    try {
        $cephConfig = Get-Content -Path $cephConfigPath -Raw | ConvertFrom-Json
        if ($cephConfig -and -not [string]::IsNullOrWhiteSpace($cephConfig.storageClassName)) { $storageClassName = "$($cephConfig.storageClassName)" }
    }
    catch { }
}

Write-Log "[Ceph] Getting Ceph CSI addon status" -Console

# Check if Ceph operator namespace exists
$cephfs_ns = kubectl get namespace ceph-csi-operator-system -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
$legacy_rbd_ns = kubectl get namespace ceph-csi-rbd -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue

$statusObject = @{
    IsEnabled = $null -ne $cephfs_ns
    Namespace = @{
        CephFS = $null -ne $cephfs_ns
        LegacyRBD = $null -ne $legacy_rbd_ns
    }
    StorageClasses = @()
}

# Get StorageClasses
$scs = kubectl get storageclass -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
if ($scs.items) {
    $cephSCs = $scs.items | Where-Object { $_.metadata.name -eq $storageClassName }
    $statusObject.StorageClasses = @($cephSCs | ForEach-Object { $_.metadata.name })
}

Write-Log "[Ceph] Status retrieved" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message $statusObject
}
else {
    Write-Log "IsEnabled: $($statusObject.IsEnabled)" -Console
    Write-Log "CephFS Namespace: $($statusObject.Namespace.CephFS)" -Console
    Write-Log "Legacy RBD Namespace: $($statusObject.Namespace.LegacyRBD)" -Console
    Write-Log "StorageClasses: $($statusObject.StorageClasses -join ', ')" -Console
}
