# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Pre-uninstall hook to remove SMB share.

.DESCRIPTION
Pre-uninstall hook to remove SMB share.
#>

$logModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/log/log.module.psm1"
$smbShareModule = "$PSScriptRoot\..\storage\smb\module\Smb-share.module.psm1"

Import-Module $logModule, $smbShareModule

$script = $MyInvocation.MyCommand.Name

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "[$script] Removing SMB share before cluster deinstallation.." -Console

# no need to cleanup the node VMs, they get deleted anyways
$err = (Disable-SmbShare -SkipNodesCleanup).Error
if ($err) {
    Write-Log $err.Message -Console
    exit 1
}

Write-Log "[$script] SMB share removed before cluster deinstallation." -Console
