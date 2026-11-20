# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Re-enables the security addon during restore.

.DESCRIPTION
Restore-specific enable hook for the security addon.
Reads enableParams from backup.json (written by Backup.ps1) to reconstruct
the original enable flags (--type, --ingress, --omitHydra, --omitKeycloak,
--omitOAuth2Proxy) and delegates to Enable.ps1.

The CLI calls this script instead of Enable.ps1 during 'k2s addons restore security'.

.PARAMETER BackupDir
Directory containing backup.json with the enableParams section.

.EXAMPLE
powershell <installation folder>\addons\security\EnableForRestore.ps1 -BackupDir C:\Temp\security-restore
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing backup.json with enable parameters')]
    [string] $BackupDir,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
Import-Module $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

# Locate backup.json
$backupJson = $null
if ($BackupDir -and (Test-Path -LiteralPath (Join-Path $BackupDir 'backup.json'))) {
    $backupJson = Join-Path $BackupDir 'backup.json'
}

# Build parameter splat from backup.json enableParams (if available)
$enableArgs = @{
    ShowLogs              = $ShowLogs
    EncodeStructuredOutput = $EncodeStructuredOutput.IsPresent
    MessageType           = $MessageType
}

if ($backupJson) {
    Write-Log "[SecurityRestore] Reading enable parameters from '$backupJson'" -Console
    try {
        $manifest = Get-Content -Raw -Path $backupJson | ConvertFrom-Json
        $params = $manifest.enableParams

        if ($params) {
            if ($params.ingress) {
                $enableArgs['Ingress'] = "$($params.ingress)"
                Write-Log "[SecurityRestore] Using ingress: $($params.ingress)" -Console
            }
            if ($params.type) {
                $enableArgs['Type'] = "$($params.type)"
                Write-Log "[SecurityRestore] Using type: $($params.type)" -Console
            }
            if ($params.omitKeycloak -eq $true) {
                $enableArgs['OmitKeycloak'] = $true
                Write-Log '[SecurityRestore] OmitKeycloak: true' -Console
            }
            if ($params.omitHydra -eq $true) {
                $enableArgs['OmitHydra'] = $true
                Write-Log '[SecurityRestore] OmitHydra: true' -Console
            }
            if ($params.omitOAuth2Proxy -eq $true) {
                $enableArgs['OmitOAuth2Proxy'] = $true
                Write-Log '[SecurityRestore] OmitOAuth2Proxy: true' -Console
            }
            if ($params.omitPolicyEnf -eq $true) {
                $enableArgs['OmitPolicyEnf'] = $true
                Write-Log '[SecurityRestore] OmitPolicyEnf: true' -Console
            }
        }
    }
    catch {
        Write-Log "[SecurityRestore] Warning: Failed to read enableParams from backup.json: $($_.Exception.Message). Using defaults." -Console
    }
}
else {
    Write-Log '[SecurityRestore] No backup.json found, enabling with default parameters' -Console
}

Write-Log '[SecurityRestore] Delegating to Enable.ps1 with detected parameters' -Console

$enableScript = Join-Path $PSScriptRoot 'Enable.ps1'
& $enableScript @enableArgs
