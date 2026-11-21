# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Backs up the local container registry data

.DESCRIPTION
Creates a tar.gz of the registry repository directory on the control plane VM and copies it to the staging folder.
The CLI wraps the staging folder into a zip archive.

The registry data lives on the control plane at: /registry/repository

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\registry\Backup.ps1 -BackupDir C:\Temp\registry-backup
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
$nodeModule = "$PSScriptRoot/../../lib/modules/windows/node/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule

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

Write-Log "[RegistryBackup] Backing up addon 'registry'" -Console

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{ Name = 'registry' })) -ne $true) {
    $errMsg = "Addon 'registry' is not enabled. Enable it before running backup."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-not-enabled' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

$files = @()

$remoteRepoDir = '/registry/repository'
$remoteTarPath = '/tmp/registry-repository.tar.gz'
$tarFileName = 'registry-repository.tar.gz'
$localTarPath = Join-Path $BackupDir $tarFileName

try {
    if (-not (Get-Command -Name Copy-FromControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
        throw 'Copy-FromControlPlaneViaSSHKey not available (vm module not imported)'
    }

    $checkCmd = "sudo test -d '$remoteRepoDir'"
    $checkResult = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 5 -CmdToExecute $checkCmd -NoLog
    if (-not $checkResult.Success) {
        throw "Registry repository directory not found on control plane: $remoteRepoDir"
    }

    Write-Log "[RegistryBackup] Creating archive on control plane" -Console
    $tarCmd = "sudo tar -czf '$remoteTarPath' -C /registry repository"
    $tarResult = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 600 -CmdToExecute $tarCmd -NoLog
    if (-not $tarResult.Success) {
        throw "Failed to create archive on control plane: $($tarResult.Output)"
    }

    Write-Log "[RegistryBackup] Copying archive from control plane" -Console
    Copy-FromControlPlaneViaSSHKey -Source $remoteTarPath -Target $BackupDir

    if (-not (Test-Path -LiteralPath $localTarPath)) {
        throw "Archive was not copied to staging directory: $localTarPath"
    }
    $files += $tarFileName

    # Optional: capture current registry ConfigMap in a minimal JSON form (no resourceVersion/managedFields)
    # to keep restore stable.
    $cmPath = Join-Path $BackupDir 'registry-config.json'
    $cmResult = Invoke-Kubectl -Params 'get', 'configmap', 'registry-config', '-n', 'registry', '-o', 'json'
    if ($cmResult.Success) {
        $cm = $cmResult.Output | ConvertFrom-Json

        $cmMinimal = [pscustomobject]@{
            apiVersion = 'v1'
            kind       = 'ConfigMap'
            metadata   = [pscustomobject]@{
                name      = 'registry-config'
                namespace = 'registry'
            }
            data       = $cm.data
        }

        $cmMinimal | ConvertTo-Json -Depth 20 | Set-Content -Path $cmPath -Encoding UTF8 -Force
        $files += (Split-Path -Leaf $cmPath)
    }
    else {
        Write-Log "[RegistryBackup] Note: registry-config ConfigMap not found. Backup will include data archive only." -Console
    }
}
catch {
    $errMsg = "Backup of addon 'registry' failed: $($_.Exception.Message)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-backup-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}
finally {
    try {
        Invoke-CmdOnControlPlaneViaSSHKey -Timeout 5 -CmdToExecute "sudo rm -f '$remoteTarPath'" -NoLog | Out-Null
    }
    catch {
        # best-effort cleanup only
    }
}

$version = 'unknown'
try {
    $version = Get-ConfigProductVersion
}
catch {
    # best-effort only
}

$manifest = [pscustomobject]@{
    k2sVersion = $version
    addon      = 'registry'
    files      = $files
    createdAt  = (Get-Date).ToString('o')
}

$manifestPath = Join-Path $BackupDir 'backup.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8 -Force

Write-Log "[RegistryBackup] Backup artifacts prepared ($($files.Count) file(s))" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
