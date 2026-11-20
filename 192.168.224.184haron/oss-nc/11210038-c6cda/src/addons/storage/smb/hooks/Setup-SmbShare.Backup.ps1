# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Hook to back-up SMB share data.

.DESCRIPTION
Hook to back-up SMB share data.
#>
param (
    [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to write data to.')]
    [string]$BackupDir = $(throw 'Please specify the back-up directory.')
)
$script = $MyInvocation.MyCommand.Name
$logModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/log/log.module.psm1"
$smbShareModule = "$PSScriptRoot\..\storage\smb\module\Smb-share.module.psm1"

Import-Module $logModule, $smbShareModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "[$script] Backing-up SMB share data.." -Console

Backup-AddonData -BackupDir $BackupDir

Write-Log "[$script] SMB share data backed-up." -Console
