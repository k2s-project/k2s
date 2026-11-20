# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Backs up ingress nginx-gw configuration/resources.

.DESCRIPTION
Exports selected Kubernetes resources of the ingress nginx-gw addon into a staging folder.
Certificates and other secrets are intentionally NOT backed up; they are regenerated during restore (Enable.ps1).
The CLI wraps the staging folder into a zip archive.

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\ingress\nginx-gw\Backup.ps1 -BackupDir C:\Temp\ingress-nginx-gw-backup
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

Write-Log "[AddonBackup] Backing up addon 'ingress nginx-gw'" -Console

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{ Name = 'ingress'; Implementation = 'nginx-gw' })) -ne $true) {
    $errMsg = "Addon 'ingress nginx-gw' is not enabled. Enable it before running backup."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-not-enabled' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$nsCheck = Invoke-Kubectl -Params 'get', 'ns', 'nginx-gw'
if (-not $nsCheck.Success) {
    $errMsg = "Namespace 'nginx-gw' not found. Is addon 'ingress nginx-gw' installed? Details: $($nsCheck.Output)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'namespace-not-found' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

function Export-MinimalK8sObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Kind,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $false)]
        [string] $Namespace,

        [Parameter(Mandatory = $true)]
        [string] $OutFile
    )

    $params = @('get', $Kind, $Name, '-o', 'json')
    if (-not [string]::IsNullOrWhiteSpace($Namespace)) {
        $params = @('-n', $Namespace) + $params
    }

    $result = Invoke-Kubectl -Params $params
    if (-not $result.Success) {
            $nsSuffix = ''
            if (-not [string]::IsNullOrWhiteSpace($Namespace)) {
                $nsSuffix = " in namespace '$Namespace'"
            }
            throw "Failed to export $Kind/$Name${nsSuffix}: $($result.Output)"
    }

    $obj = $result.Output | ConvertFrom-Json

    $meta = [ordered]@{ name = $obj.metadata.name }
    if (-not [string]::IsNullOrWhiteSpace($Namespace)) {
        $meta.namespace = $Namespace
    }

    if ($obj.metadata.labels) {
        $meta.labels = $obj.metadata.labels
    }

    if ($obj.metadata.annotations) {
        $ann = @{}
        foreach ($prop in $obj.metadata.annotations.PSObject.Properties) {
            if ($prop.Name -ne 'kubectl.kubernetes.io/last-applied-configuration') {
                $ann[$prop.Name] = $prop.Value
            }
        }
        if ($ann.Count -gt 0) {
            $meta.annotations = $ann
        }
    }

    $minimal = [ordered]@{
        apiVersion = $obj.apiVersion
        kind       = $obj.kind
        metadata   = $meta
    }

    if ($null -ne $obj.spec) { $minimal.spec = $obj.spec }
    if ($null -ne $obj.data) { $minimal.data = $obj.data }
    if ($null -ne $obj.type) { $minimal.type = $obj.type }

    $minimal | ConvertTo-Json -Depth 100 | Set-Content -Path $OutFile -Encoding UTF8 -Force
}

$files = @()

try {
    $paths = @{
        Gateway             = (Join-Path $BackupDir 'nginx-gw-gateway.json')
        NginxGateway        = (Join-Path $BackupDir 'nginxgateway.json')
    }

    Export-MinimalK8sObject -Kind 'gateway' -Name 'nginx-cluster-local' -Namespace 'nginx-gw' -OutFile $paths.Gateway
    $files += (Split-Path -Leaf $paths.Gateway)

    Export-MinimalK8sObject -Kind 'nginxgateways.gateway.nginx.org' -Name 'nginx-gw-config' -Namespace 'nginx-gw' -OutFile $paths.NginxGateway
    $files += (Split-Path -Leaf $paths.NginxGateway)
}
catch {
    $errMsg = "Backup of addon 'ingress nginx-gw' failed: $($_.Exception.Message)"

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
    implementation = 'nginx-gw'
    files          = $files
    createdAt      = (Get-Date).ToString('o')
}

$manifestPath = Join-Path $BackupDir 'backup.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8 -Force

Write-Log "[AddonBackup] Backup artifacts prepared ($($files.Count) file(s))" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
