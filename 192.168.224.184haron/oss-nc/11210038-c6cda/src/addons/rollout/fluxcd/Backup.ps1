# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Backs up rollout fluxcd configuration/resources.

.DESCRIPTION
Exports FluxCD user configuration from the rollout namespace into a staging folder.
This backup is intentionally scoped to the rollout namespace only and is config-only:
- Flux controllers/CRDs are not backed up (they are re-installed by Enable.ps1)
- Flux custom resources in namespace rollout are backed up (GitRepository, Kustomization, HelmRelease, ...)
- Secrets referenced by those Flux resources in namespace rollout are backed up
- Optional webhook Ingress resources in namespace rollout are backed up (nginx/traefik/nginx-gw)

The CLI wraps the staging folder into a zip archive.

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\rollout\fluxcd\Backup.ps1 -BackupDir C:\Temp\rollout-fluxcd-backup
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

Write-Log "[AddonBackup] Backing up addon 'rollout fluxcd' (namespace: rollout)" -Console

$addon = [pscustomobject] @{ Name = 'rollout'; Implementation = 'fluxcd' }
if ((Test-IsAddonEnabled -Addon $addon) -ne $true) {
    $errMsg = "Addon 'rollout fluxcd' is not enabled. Enable it before running backup."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-not-enabled' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$nsCheck = Invoke-Kubectl -Params 'get', 'ns', 'rollout'
if (-not $nsCheck.Success) {
    $errMsg = "Namespace 'rollout' not found. Is addon 'rollout fluxcd' installed? Details: $($nsCheck.Output)"

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
    if ($null -ne $Object.stringData) { $minimal.stringData = $Object.stringData }

    return $minimal
}

function Get-SecretRefNames {
    param(
        [Parameter(Mandatory = $true)]
        $Node,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]] $Names
    )

    if ($null -eq $Node) {
        return
    }

    if ($Node -is [string]) {
        return
    }

    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) {
            Get-SecretRefNames -Node $item -Names $Names
        }
        return
    }

    foreach ($prop in $Node.PSObject.Properties) {
        if ($null -eq $prop) { continue }

        if ($prop.Name -eq 'secretRef' -and $null -ne $prop.Value) {
            $candidate = $null
            try {
                $candidate = $prop.Value.name
            }
            catch {
                $candidate = $null
            }

            if (-not [string]::IsNullOrWhiteSpace("$candidate")) {
                $Names.Add("$candidate") | Out-Null
            }

            Get-SecretRefNames -Node $prop.Value -Names $Names
            continue
        }

        Get-SecretRefNames -Node $prop.Value -Names $Names
    }
}

function Try-GetK8sList {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Resource
    )

    $result = Invoke-Kubectl -Params 'get', $Resource, '-n', 'rollout', '-o', 'json'

    if (-not $result.Success) {
        $outText = "$($result.Output)"
        if ($outText -match '(the server doesn\x27t have a resource type|no matches for kind)') {
            Write-Log "[AddonBackup] Optional resource type not available ($Resource); skipping." -Console
            return @()
        }
        throw "Failed to list $Resource in namespace 'rollout': $outText"
    }

    $list = $result.Output | ConvertFrom-Json
    if ($null -eq $list -or $null -eq $list.items) {
        return @()
    }

    return @($list.items)
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
    # 1) Export Flux resources in rollout namespace (config-only)
    $fluxResources = @(
        'gitrepositories.source.toolkit.fluxcd.io',
        'ocirepositories.source.toolkit.fluxcd.io',
        'buckets.source.toolkit.fluxcd.io',
        'helmrepositories.source.toolkit.fluxcd.io',
        'kustomizations.kustomize.toolkit.fluxcd.io',
        'helmreleases.helm.toolkit.fluxcd.io',
        'imagerepositories.image.toolkit.fluxcd.io',
        'imagepolicies.image.toolkit.fluxcd.io',
        'imageupdateautomations.image.toolkit.fluxcd.io',
        'receivers.notification.toolkit.fluxcd.io',
        'alerts.notification.toolkit.fluxcd.io',
        'providers.notification.toolkit.fluxcd.io'
    )

    $allFluxItems = @()
    $secretNames = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($r in $fluxResources) {
        $items = Try-GetK8sList -Resource $r
        if ($items.Count -eq 0) {
            continue
        }

        foreach ($item in $items) {
            $allFluxItems += (ConvertTo-MinimalK8sObject -Object $item)
            Get-SecretRefNames -Node $item -Names $secretNames
        }
    }

    # Write secrets first (so Flux objects can reference them during restore)
    if ($secretNames.Count -gt 0) {
        $secretItems = @()
        foreach ($secretName in $secretNames) {
            $secretResult = Invoke-Kubectl -Params 'get', 'secret', "$secretName", '-n', 'rollout', '-o', 'json', '--ignore-not-found'
            if (-not $secretResult.Success) {
                throw "Failed to export Secret '$secretName' in namespace 'rollout': $($secretResult.Output)"
            }

            if ([string]::IsNullOrWhiteSpace("$($secretResult.Output)")) {
                Write-Log "[AddonBackup] Referenced Secret '$secretName' not found; skipping." -Console
                continue
            }

            $s = $secretResult.Output | ConvertFrom-Json
            if ($null -ne $s.type -and "$($s.type)" -eq 'kubernetes.io/service-account-token') {
                continue
            }

            $secretItems += (ConvertTo-MinimalK8sObject -Object $s)
        }

        if ($secretItems.Count -gt 0) {
            $secretsPath = Join-Path $BackupDir 'fluxcd-secrets.json'
            $listObj = [ordered]@{ apiVersion = 'v1'; kind = 'List'; items = $secretItems }
            $listObj | ConvertTo-Json -Depth 100 | Set-Content -Path $secretsPath -Encoding UTF8 -Force
            $files += (Split-Path -Leaf $secretsPath)
        }
    }

    if ($allFluxItems.Count -gt 0) {
        $resourcesPath = Join-Path $BackupDir 'fluxcd-resources.json'
        $listObj = [ordered]@{ apiVersion = 'v1'; kind = 'List'; items = $allFluxItems }
        $listObj | ConvertTo-Json -Depth 100 | Set-Content -Path $resourcesPath -Encoding UTF8 -Force
        $files += (Split-Path -Leaf $resourcesPath)
    }
    else {
        Write-Log "[AddonBackup] No Flux resources found in namespace 'rollout'." -Console
    }

    # 2) Optional webhook ingress resources (if enabled)
    $nginxIngressPath = Join-Path $BackupDir 'fluxcd-ingress-nginx.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'ingress' -Name 'rollout-nginx-cluster-local' -Namespace 'rollout' -OutFile $nginxIngressPath) {
        $files += (Split-Path -Leaf $nginxIngressPath)
    }

    $traefikIngressPath = Join-Path $BackupDir 'fluxcd-ingress-traefik.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'ingress' -Name 'rollout-traefik-cluster-local' -Namespace 'rollout' -OutFile $traefikIngressPath) {
        $files += (Split-Path -Leaf $traefikIngressPath)
    }

    $nginxGwHttpPath = Join-Path $BackupDir 'fluxcd-ingress-nginx-gw-httproute-http.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'httproute' -Name 'rollout-nginx-gw-http' -Namespace 'rollout' -OutFile $nginxGwHttpPath) {
        $files += (Split-Path -Leaf $nginxGwHttpPath)
    }

    $nginxGwHttpsPath = Join-Path $BackupDir 'fluxcd-ingress-nginx-gw-httproute-https.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'httproute' -Name 'rollout-nginx-gw-https' -Namespace 'rollout' -OutFile $nginxGwHttpsPath) {
        $files += (Split-Path -Leaf $nginxGwHttpsPath)
    }
}
catch {
    $errMsg = "Backup of addon 'rollout fluxcd' failed: $($_.Exception.Message)"

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
    addon          = 'rollout'
    implementation = 'fluxcd'
    scope          = 'namespace:rollout'
    files          = $files
    createdAt      = (Get-Date).ToString('o')
}

$manifestPath = Join-Path $BackupDir 'backup.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8 -Force

Write-Log "[AddonBackup] Backup artifacts prepared ($($files.Count) file(s))" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
