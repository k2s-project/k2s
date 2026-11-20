# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Backs up logging configuration

.DESCRIPTION
Exports selected ConfigMaps in a minimal JSON form to keep restore stable.

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\logging\Backup.ps1 -BackupDir C:\Temp\logging-backup
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Directory where backup files will be written')]
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

$namespace = 'logging'

function Fail([string]$errMsg) {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-backup-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        exit 1
    }

    Write-Log $errMsg -Error
    exit 1
}

function Try-ExportMinimalConfigMap {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $Namespace,
        [Parameter(Mandatory = $true)]
        [string] $OutPath
    )

    $cmResult = Invoke-Kubectl -Params 'get', 'configmap', $Name, '-n', $Namespace, '-o', 'json'
    if (-not $cmResult.Success) {
        Write-Log "[LoggingBackup] Note: ConfigMap '$Name' not found; skipping." -Console
        return $false
    }

    try {
        $cm = $cmResult.Output | ConvertFrom-Json
        $minimal = [pscustomobject]@{
            apiVersion = 'v1'
            kind       = 'ConfigMap'
            metadata   = [pscustomobject]@{ name = $Name; namespace = $Namespace }
            data       = $cm.data
        }

        $minimal | ConvertTo-Json -Depth 50 | Set-Content -Path $OutPath -Encoding UTF8 -Force
        return $true
    }
    catch {
        Write-Log "[LoggingBackup] Failed to export ConfigMap '$Name': $($_.Exception.Message)" -Console
        return $false
    }
}

Write-Log "[LoggingBackup] Backing up addon 'logging'" -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Fail $systemError.Message
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{ Name = 'logging' })) -ne $true) {
    Fail "Addon 'logging' is not enabled. Enable it before running backup."
}

$nsCheck = Invoke-Kubectl -Params 'get', 'ns', $namespace
if (-not $nsCheck.Success) {
    Fail "Namespace '$namespace' not found. Is addon 'logging' installed? Details: $($nsCheck.Output)"
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

$files = @()

try {
    # Export ConfigMaps in a minimal JSON format.
    #
    # NOTE: The Fluent Bit ConfigMaps (fluent-bit, fluent-bit-win-parsers, fluent-bit-win-config)
    # are intentionally NOT backed up. They are generated artifacts produced by Enable.ps1 and the
    # Windows config now contains host-specific, resolved log paths (the __LOG_ROOT__ placeholder is
    # substituted at addon enable time). Capturing the live ConfigMap and re-applying it during restore
    # would overwrite the freshly generated, restore-host-correct config with stale paths from the
    # backup host (e.g. D:\Temp\k2s-logs vs C:\var\log). During restore, Enable.ps1 runs first and
    # regenerates these ConfigMaps correctly for the target host, so re-applying a snapshot is both
    # unnecessary and unsafe. Only genuinely stateful config (OpenSearch) is backed up here.
    $cm1 = Join-Path $BackupDir 'opensearch-config.json'
    if (Try-ExportMinimalConfigMap -Name 'opensearch-cluster-master-config' -Namespace $namespace -OutPath $cm1) {
        $files += (Split-Path -Leaf $cm1)
    }
}
catch {
    Fail "Backup of addon 'logging' failed: $($_.Exception.Message)"
}

$version = 'unknown'
try { $version = Get-ConfigProductVersion } catch { }

$manifest = [pscustomobject]@{
    k2sVersion = $version
    addon      = 'logging'
    files      = $files
    createdAt  = (Get-Date).ToString('o')
}

$manifestPath = Join-Path $BackupDir 'backup.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8 -Force

Write-Log "[LoggingBackup] Backup artifacts prepared ($($files.Count) file(s))" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
