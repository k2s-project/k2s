# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Backs up viewer configuration/resources.

.DESCRIPTION
Exports selected Kubernetes resources of the viewer addon into a staging folder.
The backup adapts to the active ingress setup:
- Always exports ConfigMap and Service
- Exports ingress-nginx, ingress-traefik and/or nginx-gw HTTPRoute resources if present
- Exports Traefik Middleware (secure mode) if present

The CLI wraps the staging folder into a zip archive.

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\viewer\Backup.ps1 -BackupDir C:\Temp\viewer-backup
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

Write-Log "[AddonBackup] Backing up addon 'viewer'" -Console

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{ Name = 'viewer' })) -ne $true) {
    $errMsg = "Addon 'viewer' is not enabled. Enable it before running backup."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-not-enabled' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$nsCheck = Invoke-Kubectl -Params 'get', 'ns', 'viewer'
if (-not $nsCheck.Success) {
    $errMsg = "Namespace 'viewer' not found. Is addon 'viewer' installed? Details: $($nsCheck.Output)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'namespace-not-found' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

function Export-K8sYamlIfExists {
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

    $result = Invoke-Kubectl -Params 'get', $Kind, $Name, '-n', $Namespace, '-o', 'yaml', '--ignore-not-found'
    if (-not $result.Success) {
        $outText = "$($result.Output)"
        if ($outText -match '(the server doesn\x27t have a resource type|no matches for kind|not found)') {
            Write-Log "[AddonBackup] Optional resource $Kind/$Name not available; skipping." -Console
            return $false
        }
        throw "Failed to export $Kind/$Name in namespace '$Namespace': $outText"
    }

    if ([string]::IsNullOrWhiteSpace("$($result.Output)")) {
        Write-Log "[AddonBackup] Optional resource $Kind/$Name not found; skipping." -Console
        return $false
    }

    $result.Output | Set-Content -Path $OutFile -Encoding UTF8 -Force
    return $true
}

$files = @()

try {
    $cmPath = Join-Path $BackupDir 'viewer-configmap.yaml'
    $cm = Invoke-Kubectl -Params 'get', 'configmap', 'config-json', '-n', 'viewer', '-o', 'yaml'
    if (-not $cm.Success) {
        throw "Failed to export ConfigMap 'config-json': $($cm.Output)"
    }
    $cm.Output | Set-Content -Path $cmPath -Encoding UTF8 -Force
    $files += (Split-Path -Leaf $cmPath)

    $svcPath = Join-Path $BackupDir 'viewer-service.yaml'
    $svc = Invoke-Kubectl -Params 'get', 'service', 'viewerwebapp', '-n', 'viewer', '-o', 'yaml'
    if (-not $svc.Success) {
        throw "Failed to export Service 'viewerwebapp': $($svc.Output)"
    }
    $svc.Output | Set-Content -Path $svcPath -Encoding UTF8 -Force
    $files += (Split-Path -Leaf $svcPath)

    $nginxIngressPath = Join-Path $BackupDir 'viewer-ingress-nginx.yaml'
    if (Export-K8sYamlIfExists -Kind 'ingress' -Name 'viewer-nginx-cluster-local' -Namespace 'viewer' -OutFile $nginxIngressPath) {
        $files += (Split-Path -Leaf $nginxIngressPath)
    }

    $traefikIngressPath = Join-Path $BackupDir 'viewer-ingress-traefik.yaml'
    if (Export-K8sYamlIfExists -Kind 'ingress' -Name 'viewer-traefik-cluster-local' -Namespace 'viewer' -OutFile $traefikIngressPath) {
        $files += (Split-Path -Leaf $traefikIngressPath)
    }

    $nginxGwHttpPath = Join-Path $BackupDir 'viewer-ingress-nginx-gw-httproute-http.yaml'
    if (Export-K8sYamlIfExists -Kind 'httproute' -Name 'viewer-nginx-gw-http' -Namespace 'viewer' -OutFile $nginxGwHttpPath) {
        $files += (Split-Path -Leaf $nginxGwHttpPath)
    }

    $nginxGwHttpsPath = Join-Path $BackupDir 'viewer-ingress-nginx-gw-httproute-https.yaml'
    if (Export-K8sYamlIfExists -Kind 'httproute' -Name 'viewer-nginx-gw-https' -Namespace 'viewer' -OutFile $nginxGwHttpsPath) {
        $files += (Split-Path -Leaf $nginxGwHttpsPath)
    }

    # Traefik secure mode uses a Middleware in the viewer namespace.
    $mwPath = Join-Path $BackupDir 'viewer-traefik-middleware.yaml'
    if (Export-K8sYamlIfExists -Kind 'middlewares.traefik.io' -Name 'oauth2-proxy-auth' -Namespace 'viewer' -OutFile $mwPath) {
        $files += (Split-Path -Leaf $mwPath)
    }
}
catch {
    $errMsg = "Backup of addon 'viewer' failed: $($_.Exception.Message)"

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
    k2sVersion = $version
    addon      = 'viewer'
    files      = $files
    createdAt  = (Get-Date).ToString('o')
}

$manifestPath = Join-Path $BackupDir 'backup.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8 -Force

Write-Log "[AddonBackup] Backup artifacts prepared ($($files.Count) file(s))" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
