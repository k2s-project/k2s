# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Backs up dicom configuration/resources.

.DESCRIPTION
Creates a config-only backup scoped to the dicom namespace:
- Exports Orthanc configuration ConfigMap (json-configmap)
- Optionally exports ingress resources (nginx / traefik / nginx-gw) and Traefik Middleware resources, if present

The CLI wraps the staging folder into a zip archive.

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\dicom\Backup.ps1 -BackupDir C:\Temp\dicom-backup
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

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

Write-Log "[AddonBackup] Backing up addon 'dicom'" -Console

# DICOM is enabled/disabled by addon name only.
$addon = [pscustomobject] @{ Name = 'dicom' }
if ((Test-IsAddonEnabled -Addon $addon) -ne $true) {
    $errMsg = "Addon 'dicom' is not enabled. Enable it before running backup."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-not-enabled' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$nsCheck = Invoke-Kubectl -Params 'get', 'ns', 'dicom'
if (-not $nsCheck.Success) {
    $errMsg = "Namespace 'dicom' not found. Is addon 'dicom' installed? Details: $($nsCheck.Output)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'namespace-not-found' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

function ConvertTo-MinimalK8sObject {
    param(
        [Parameter(Mandatory = $true)]
        $Object
    )

    $meta = [ordered]@{
        name      = $Object.metadata.name
        namespace = $Object.metadata.namespace
    }

    if ($Object.metadata.labels) {
        $meta.labels = $Object.metadata.labels
    }

    if ($Object.metadata.annotations) {
        $ann = @{}
        foreach ($prop in $Object.metadata.annotations.PSObject.Properties) {
            if ($prop.Name -ne 'kubectl.kubernetes.io/last-applied-configuration') {
                $ann[$prop.Name] = $prop.Value
            }
        }
        if ($ann.Count -gt 0) {
            $meta.annotations = $ann
        }
    }

    $minimal = [ordered]@{
        apiVersion = $Object.apiVersion
        kind       = $Object.kind
        metadata   = $meta
    }

    if ($null -ne $Object.spec) { $minimal.spec = $Object.spec }
    if ($null -ne $Object.data) { $minimal.data = $Object.data }
    if ($null -ne $Object.type) { $minimal.type = $Object.type }

    return $minimal
}

function Export-MinimalK8sObjectIfExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Kind,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Namespace,

        [Parameter(Mandatory = $true)]
        [string] $OutFile
    )

    $result = Invoke-Kubectl -Params 'get', $Kind, $Name, '-n', $Namespace, '-o', 'json', '--ignore-not-found'
    if (-not $result.Success) {
        $outText = "$($result.Output)"
        if ($outText -match '(the server doesn\x27t have a resource type|no matches for kind|not found)') {
            Write-Log "[AddonBackup] Optional resource $Kind/$Name not available; skipping." -Console
            return $false
        }
        throw "Failed to export $Kind/$Name in namespace '$Namespace': $outText"
    }

    if ([string]::IsNullOrWhiteSpace("$($result.Output)")) {
        return $false
    }

    $obj = $result.Output | ConvertFrom-Json
    $minimal = ConvertTo-MinimalK8sObject -Object $obj
    $minimal | ConvertTo-Json -Depth 100 | Set-Content -Path $OutFile -Encoding UTF8 -Force
    return $true
}

$files = @()

try {
    $configMapPath = Join-Path $BackupDir 'dicom-json-configmap.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'configmap' -Name 'json-configmap' -Namespace 'dicom' -OutFile $configMapPath) {
        $files += (Split-Path -Leaf $configMapPath)
    }
    else {
        throw "Required resource not found: ConfigMap/json-configmap in namespace 'dicom'"
    }

    $nginxIngressPath = Join-Path $BackupDir 'dicom-ingress-nginx.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'ingress' -Name 'dicom-nginx-cluster-local' -Namespace 'dicom' -OutFile $nginxIngressPath) {
        $files += (Split-Path -Leaf $nginxIngressPath)
    }

    $traefikIngressPath = Join-Path $BackupDir 'dicom-ingress-traefik.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'ingress' -Name 'dicom-traefik-cluster-local' -Namespace 'dicom' -OutFile $traefikIngressPath) {
        $files += (Split-Path -Leaf $traefikIngressPath)
    }

    $nginxGwHttpsPath = Join-Path $BackupDir 'dicom-ingress-nginx-gw-httproute-https.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'httproute' -Name 'dicom-nginx-gw-cluster-local-https' -Namespace 'dicom' -OutFile $nginxGwHttpsPath) {
        $files += (Split-Path -Leaf $nginxGwHttpsPath)
    }

    $nginxGwHttpPath = Join-Path $BackupDir 'dicom-ingress-nginx-gw-httproute-http.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'httproute' -Name 'dicom-nginx-gw-cluster-local-http' -Namespace 'dicom' -OutFile $nginxGwHttpPath) {
        $files += (Split-Path -Leaf $nginxGwHttpPath)
    }

    $traefikIngressCorrect1Path = Join-Path $BackupDir 'dicom-ingress-traefik-correct1.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'ingress' -Name 'dicom-traefik-cluster-local-correct1' -Namespace 'dicom' -OutFile $traefikIngressCorrect1Path) {
        $files += (Split-Path -Leaf $traefikIngressCorrect1Path)
    }

    $traefikIngressCorrect2Path = Join-Path $BackupDir 'dicom-ingress-traefik-correct2.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'ingress' -Name 'dicom-traefik-cluster-local-correct2' -Namespace 'dicom' -OutFile $traefikIngressCorrect2Path) {
        $files += (Split-Path -Leaf $traefikIngressCorrect2Path)
    }

    $mwStripPrefixPath = Join-Path $BackupDir 'dicom-traefik-middleware-strip-prefix.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'middlewares.traefik.io' -Name 'strip-prefix' -Namespace 'dicom' -OutFile $mwStripPrefixPath) {
        $files += (Split-Path -Leaf $mwStripPrefixPath)
    }

    $mwCorsHeaderPath = Join-Path $BackupDir 'dicom-traefik-middleware-cors-header.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'middlewares.traefik.io' -Name 'cors-header' -Namespace 'dicom' -OutFile $mwCorsHeaderPath) {
        $files += (Split-Path -Leaf $mwCorsHeaderPath)
    }

    $mwOauth2ProxyAuthPath = Join-Path $BackupDir 'dicom-traefik-middleware-oauth2-proxy-auth.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'middlewares.traefik.io' -Name 'oauth2-proxy-auth' -Namespace 'dicom' -OutFile $mwOauth2ProxyAuthPath) {
        $files += (Split-Path -Leaf $mwOauth2ProxyAuthPath)
    }
}
catch {
    $errMsg = "Backup of addon 'dicom' failed: $($_.Exception.Message)"

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

$storageUsage = $null
try {
    $attrs = Get-AddonConfig -Name 'dicom'
    if ($null -ne $attrs -and $null -ne $attrs.StorageUsage) {
        $storageUsage = "$($attrs.StorageUsage)"
    }
}
catch {
    # best-effort only
}

$manifest = [pscustomobject]@{
    k2sVersion     = $version
    addon          = 'dicom'
    implementation = 'dicom'
    scope          = 'namespace:dicom'
    storageUsage   = $storageUsage
    files          = $files
    createdAt      = (Get-Date).ToString('o')
}

$manifestPath = Join-Path $BackupDir 'backup.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8 -Force

Write-Log "[AddonBackup] Backup artifacts prepared ($($files.Count) file(s))" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
