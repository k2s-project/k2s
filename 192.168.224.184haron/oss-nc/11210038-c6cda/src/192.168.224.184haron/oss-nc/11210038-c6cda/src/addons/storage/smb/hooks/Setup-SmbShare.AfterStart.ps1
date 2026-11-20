# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Post-start hook to re-establish SMB share.

.DESCRIPTION
Post-start hook to re-establish SMB share.
#>

$logModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/log/log.module.psm1"
$smbShareModule = "$PSScriptRoot\..\storage\smb\module\Smb-share.module.psm1"

Import-Module $logModule, $smbShareModule

$script = $MyInvocation.MyCommand.Name

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "[$script] Re-establishing SMB share after cluster start.." -Console

$smbHostType = Get-SmbHostType
$storageConfig = Get-StorageConfig

$attempted = 0
$restored = 0
foreach ($storageEntry in $storageConfig) {
    $attempted++
    # Harden against a single bad entry: a restore failure must not abort cluster start nor surface a raw console error - log full detail and continue.
    try {
        Restore-SmbShareAndFolder -SmbHostType $smbHostType -Config $storageEntry
        $restored++
    }
    catch {
        Write-Log "[$script] Could not re-establish an SMB share entry after start; continuing. See log for details." -Console
        Write-Log "[$script] Restore-SmbShareAndFolder failed: $_"
    }
}

if ($attempted -eq 0) {
    Write-Log "[$script] No SMB share entries to re-establish after cluster start." -Console
}
elseif ($restored -eq $attempted) {
    Write-Log "[$script] SMB share re-established after cluster start." -Console
}
elseif ($restored -gt 0) {
    Write-Log "[$script] SMB share restore after cluster start completed with errors: $restored of $attempted entries re-established. See log for details." -Console
}
else {
    Write-Log "[$script] SMB share restore after cluster start failed for all $attempted entries. See log for details." -Console
}
