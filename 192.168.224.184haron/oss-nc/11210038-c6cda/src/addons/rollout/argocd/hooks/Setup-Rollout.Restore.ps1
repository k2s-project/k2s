# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Hook to restore the data of rollout addon.

.DESCRIPTION
Hook to restore the data of rollout addon.
#>
param (
    [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to restore data from.')]
    [string]$BackupDir = $(throw 'Please specify the back-up directory.')
)
$logModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/log/log.module.psm1"
$rolloutModule = "$PSScriptRoot\..\rollout\argocd\rollout.module.psm1"

Import-Module $logModule, $rolloutModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "Restoring the data of rollout addon from '$BackupDir'.." -Console

Restore-AddonData -BackupDir $BackupDir

Write-Log "Rollout addons data restored from '$BackupDir'." -Console
