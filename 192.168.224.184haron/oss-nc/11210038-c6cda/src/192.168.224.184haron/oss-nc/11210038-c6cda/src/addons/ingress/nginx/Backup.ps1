# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Backs up ingress nginx configuration/resources

.DESCRIPTION
Exports selected Kubernetes resources of the ingress nginx addon into a staging folder.
The CLI wraps the staging folder into a zip archive.

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\ingress\nginx\Backup.ps1 -BackupDir C:\Temp\ingress-nginx-backup
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

$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"

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

Write-Log "[AddonBackup] Backing up addon 'ingress nginx'" -Console

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx' })) -ne $true) {
    $errMsg = "Addon 'ingress nginx' is not enabled. Enable it before running backup."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-not-enabled' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$nsCheck = Invoke-Kubectl -Params 'get', 'ns', 'ingress-nginx'
if (-not $nsCheck.Success) {
    $errMsg = "Namespace 'ingress-nginx' not found. Is addon 'ingress nginx' installed? Details: $($nsCheck.Output)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'namespace-not-found' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

$files = @()

try {
    $cmPath = Join-Path $BackupDir 'ingress-nginx-controller-configmap.yaml'
    $cmResult = Invoke-Kubectl -Params 'get', 'configmap', 'ingress-nginx-controller', '-n', 'ingress-nginx', '-o', 'yaml'
    if (-not $cmResult.Success) {
        throw "Failed to export ConfigMap 'ingress-nginx-controller': $($cmResult.Output)"
    }
    $cmResult.Output | Set-Content -Path $cmPath -Encoding UTF8 -Force
    $files += (Split-Path -Leaf $cmPath)

    $ingPath = Join-Path $BackupDir 'nginx-cluster-local-ingress.yaml'
    $ingResult = Invoke-Kubectl -Params 'get', 'ingress', 'nginx-cluster-local', '-n', 'ingress-nginx', '-o', 'yaml'
    if (-not $ingResult.Success) {
        if ("$($ingResult.Output)" -match '(NotFound|not found)') {
            Write-Log "[AddonBackup] Optional resource Ingress 'nginx-cluster-local' not found; skipping." -Console
        }
        else {
            throw "Failed to export Ingress 'nginx-cluster-local': $($ingResult.Output)"
        }
    }
    if ($ingResult.Success) {
        $ingResult.Output | Set-Content -Path $ingPath -Encoding UTF8 -Force
        $files += (Split-Path -Leaf $ingPath)
    }
}
catch {
    $errMsg = "Backup of addon 'ingress nginx' failed: $($_.Exception.Message)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-backup-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$version = 'unknown'
try {
    $version = Get-ConfigProductVersion
}
catch {
    # best-effort only
}

$manifest = [pscustomobject]@{
    k2sVersion     = $version
    addon          = 'ingress'
    implementation = 'nginx'
    files          = $files
    createdAt      = (Get-Date).ToString('o')
}

$manifestPath = Join-Path $BackupDir 'backup.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8 -Force

Write-Log "[AddonBackup] Backup artifacts prepared ($($files.Count) file(s))" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
