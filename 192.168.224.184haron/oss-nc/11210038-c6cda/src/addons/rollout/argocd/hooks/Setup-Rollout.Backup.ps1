# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Hook to back-up the data of the rollout addon.

.DESCRIPTION
Hook to back-up the data of the rollout addon.
#>
param (
    [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to write data to.')]
    [string]$BackupDir = $(throw 'Please specify the back-up directory.')
)
$logModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/log/log.module.psm1"
$rolloutModule = "$PSScriptRoot\..\rollout\argocd\rollout.module.psm1"

Import-Module $logModule, $rolloutModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Backing-up data of rollout addon..' -Console

Backup-AddonData -BackupDir $BackupDir

Write-Log 'rollout addons data backed-up.' -Console
