# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Restores kubevirt addon state (metadata-only).

.DESCRIPTION
The kubevirt addon is an infrastructure-provisioning addon. Re-enabling the addon
via 'k2s addons enable kubevirt' fully restores its functionality (nested
virtualization, QEMU/libvirt packages, KubeVirt operator/CR, virtctl, VirtViewer).

This script validates the backup manifest and succeeds without further action.

.PARAMETER BackupDir
Directory containing backup.json.

.EXAMPLE
powershell <installation folder>\addons\kubevirt\Restore.ps1 -BackupDir C:\Temp\kubevirt-restore
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Directory containing backup.json and referenced files')]
    [string] $BackupDir,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$manifestPath = Join-Path $BackupDir 'backup.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    $errMsg = "backup.json not found in '$BackupDir'"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json

Write-Log "[AddonRestore] Restoring addon 'kubevirt'" -Console

if ($null -ne $manifest.addon -and ("$($manifest.addon)" -ne 'kubevirt')) {
    Write-Log "[AddonRestore] Warning: backup.json addon is '$($manifest.addon)' (expected 'kubevirt')." -Console
}

Write-Log "[AddonRestore] kubevirt is an infrastructure addon. Re-enabling the addon fully restores functionality (nested virtualization, QEMU/libvirt, KubeVirt operator/CR, virtctl, VirtViewer). No additional restore steps required." -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
