# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Backs up metrics addon configuration

.DESCRIPTION
Exports selected Kubernetes objects (Deployment/APIService and Windows exporter resources) as minimal JSON manifests.

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\metrics\Backup.ps1 -BackupDir C:\Temp\metrics-backup
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

function Fail([string]$errMsg) {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-backup-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        exit 1
    }

    Write-Log $errMsg -Error
    exit 1
}

function Try-ExportMinimalK8sObject {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Kind,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $false)]
        [string] $Namespace,
        [Parameter(Mandatory = $true)]
        [string] $OutPath
    )

    $params = @('get', $Kind, $Name)
    if ($Namespace) {
        $params += @('-n', $Namespace)
    }
    $params += @('-o', 'json')

    $get = Invoke-Kubectl -Params $params
    if (-not $get.Success) {
        Write-Log "[MetricsBackup] Note: $Kind/$Name not found; skipping." -Console
        return $false
    }

    try {
        $obj = $get.Output | ConvertFrom-Json

        $minimal = [ordered]@{
            apiVersion = $obj.apiVersion
            kind       = $obj.kind
            metadata   = [ordered]@{
                name = $obj.metadata.name
            }
        }

        if ($obj.metadata.namespace) {
            $minimal.metadata.namespace = $obj.metadata.namespace
        }

        if ($obj.spec) {
            $minimal.spec = $obj.spec
        }
        if ($obj.data) {
            $minimal.data = $obj.data
        }
        if ($obj.rules) {
            $minimal.rules = $obj.rules
        }
        if ($obj.roleRef) {
            $minimal.roleRef = $obj.roleRef
        }
        if ($obj.subjects) {
            $minimal.subjects = $obj.subjects
        }

        ([pscustomobject]$minimal) | ConvertTo-Json -Depth 80 | Set-Content -Path $OutPath -Encoding UTF8 -Force
        return $true
    }
    catch {
        Write-Log "[MetricsBackup] Failed to export ${Kind}/${Name}: $($_.Exception.Message)" -Console
        return $false
    }
}

Write-Log "[MetricsBackup] Backing up addon 'metrics'" -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Fail $systemError.Message
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{ Name = 'metrics' })) -ne $true) {
    Fail "Addon 'metrics' is not enabled. Enable it before running backup."
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

$files = @()

try {
    $out1 = Join-Path $BackupDir 'metrics-server-deployment.json'
    if (Try-ExportMinimalK8sObject -Kind 'deployment' -Name 'metrics-server' -Namespace 'metrics' -OutPath $out1) {
        $files += (Split-Path -Leaf $out1)
    }

    $out2 = Join-Path $BackupDir 'metrics-apiservice.json'
    if (Try-ExportMinimalK8sObject -Kind 'apiservice' -Name 'v1beta1.metrics.k8s.io' -OutPath $out2) {
        $files += (Split-Path -Leaf $out2)
    }

    $out3 = Join-Path $BackupDir 'windows-exporter-config.json'
    if (Try-ExportMinimalK8sObject -Kind 'configmap' -Name 'windows-exporter-config' -Namespace 'kube-system' -OutPath $out3) {
        $files += (Split-Path -Leaf $out3)
    }

    $out4 = Join-Path $BackupDir 'windows-exporter-daemonset.json'
    if (Try-ExportMinimalK8sObject -Kind 'daemonset' -Name 'windows-exporter' -Namespace 'kube-system' -OutPath $out4) {
        $files += (Split-Path -Leaf $out4)
    }

    $out5 = Join-Path $BackupDir 'windows-exporter-service.json'
    if (Try-ExportMinimalK8sObject -Kind 'service' -Name 'windows-exporter' -Namespace 'kube-system' -OutPath $out5) {
        $files += (Split-Path -Leaf $out5)
    }

    $out6 = Join-Path $BackupDir 'windows-exporter-servicemonitor.json'
    if (Try-ExportMinimalK8sObject -Kind 'servicemonitor' -Name 'windows-exporter' -Namespace 'monitoring' -OutPath $out6) {
        $files += (Split-Path -Leaf $out6)
    }
}
catch {
    Fail "Backup of addon 'metrics' failed: $($_.Exception.Message)"
}

$version = 'unknown'
try { $version = Get-ConfigProductVersion } catch { }

$manifest = [pscustomobject]@{
    k2sVersion = $version
    addon      = 'metrics'
    files      = $files
    createdAt  = (Get-Date).ToString('o')
}
$addonConfig = Get-AddonConfig -Name 'metrics'
if ($null -ne $addonConfig -and -not [string]::IsNullOrWhiteSpace([string]$addonConfig.InfraNodeSelector)) {
    $manifest | Add-Member -NotePropertyName infraNodeSelector -NotePropertyValue ([string]$addonConfig.InfraNodeSelector)
}

$manifestPath = Join-Path $BackupDir 'backup.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8 -Force

Write-Log "[MetricsBackup] Backup artifacts prepared ($($files.Count) file(s))" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
