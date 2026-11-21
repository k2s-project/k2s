# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Hook to back-up storage ceph configuration.

.DESCRIPTION
Hook to back-up storage ceph configuration for 'k2s system backup' and cluster upgrade.

Ceph connects to an EXTERNAL Ceph cluster, so there is no addon-owned persistent data on the
cluster. The only state required to re-enable the addon after a restore/upgrade is its connection
configuration stored in ceph-config.json.
This hook copies that file into the backup directory.
#>
param (
    [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to write data to.')]
    [string]$BackupDir = $(throw 'Please specify the back-up directory.'),
    [Parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch]$ShowLogs = $false
)
$script = $MyInvocation.MyCommand.Name
$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "[$script] Backing-up storage ceph configuration.." -Console

$configPath = "$(Get-KubePath)\addons\storage\ceph\config\ceph-config.json"

if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Log "[$script] Storage ceph config file not found at '$configPath'; nothing to back up." -Console
    return
}

if (-not (Test-Path -LiteralPath $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

$targetPath = Join-Path $BackupDir 'ceph-config.json'
Copy-Item -LiteralPath $configPath -Destination $targetPath -Force

Write-Log "[$script] Storage ceph configuration backed-up to '$targetPath'." -Console
