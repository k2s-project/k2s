# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Backs up rollout argocd configuration/resources.

.DESCRIPTION
Creates a config-only backup scoped to the rollout namespace:
- Exports ArgoCD state via `argocd admin export -n rollout`
- Optionally exports ingress resources for dashboard exposure (nginx/traefik/nginx-gw)
- Optionally exports Traefik Middleware (secure mode) if present

The ArgoCD export contains credentials (e.g., repository credentials). Handle backups accordingly.

The CLI wraps the staging folder into a zip archive.

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\rollout\argocd\Backup.ps1 -BackupDir C:\Temp\rollout-argocd-backup
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

Write-Log "[AddonBackup] Backing up addon 'rollout argocd' (namespace: rollout)" -Console

$addon = [pscustomobject] @{ Name = 'rollout'; Implementation = 'argocd' }
if ((Test-IsAddonEnabled -Addon $addon) -ne $true) {
    $errMsg = "Addon 'rollout argocd' is not enabled. Enable it before running backup."

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
    $errMsg = "Namespace 'rollout' not found. Is addon 'rollout argocd' installed? Details: $($nsCheck.Output)"

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

function Remove-ArgoCdExportNoise {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text
    )

    if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) {
        $Text = $Text.Substring(1)
    }

    $lines = @($Text -split "`r?`n")

    # Drop any preamble before the YAML stream starts.
    $startIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(apiVersion:|kind:|---\s*$)') {
            $startIndex = $i
            break
        }
    }

    if ($startIndex -lt 0) {
        return $Text
    }

    $slice = $lines[$startIndex..($lines.Count - 1)]

    # Strip known exec/log noise from the end (postamble).
    $endIndex = $slice.Count - 1
    while ($endIndex -ge 0) {
        $line = $slice[$endIndex]
        if ([string]::IsNullOrWhiteSpace($line)) { $endIndex--; continue }
        if ($line -match '^command terminated with exit code') { $endIndex--; continue }
        if ($line -match '^Defaulted container ') { $endIndex--; continue }
        if ($line -match '^(warning:|error:)') { $endIndex--; continue }
        if ($line -match '^W\d{4}\s') { $endIndex--; continue }
        if ($line -match '^time="\d{4}-\d{2}-\d{2}T') { $endIndex--; continue }
        break
    }

    if ($endIndex -lt 0) {
        return ''
    }

    return (($slice[0..$endIndex]) -join "`n")
}

function Resolve-ArgoCdCli {
    [CmdletBinding()]
    param()

    $candidate1 = Join-Path (Get-ClusterInstalledFolder) 'bin\argocd.exe'
    if (Test-Path -LiteralPath $candidate1) {
        return [pscustomobject]@{ Mode = 'host'; Path = $candidate1 }
    }

    $candidate2 = Join-Path (Get-KubeBinPath) 'argocd.exe'
    if (Test-Path -LiteralPath $candidate2) {
        return [pscustomobject]@{ Mode = 'host'; Path = $candidate2 }
    }

    # Fallback: use the argocd binary inside the argocd-server pod.
    return [pscustomobject]@{ Mode = 'pod'; Path = $null }
}

$files = @()

try {
    $argoCli = Resolve-ArgoCdCli

    $exportPath = Join-Path $BackupDir 'argocd-export.yaml'
    Write-Log "[AddonBackup] Exporting ArgoCD state via argocd admin export" -Console

    $exportOut = $null
    if ($argoCli.Mode -eq 'host') {
        $errFile = Join-Path $env:TEMP ('k2s-argocd-export-host-' + [guid]::NewGuid().ToString('n') + '.err')
        try {
            $exportOut = & $argoCli.Path admin export -n rollout 2> $errFile
            $exit = $LASTEXITCODE
            if ($exit -ne 0) {
                $errText = ''
                if (Test-Path -LiteralPath $errFile) { $errText = Get-Content -LiteralPath $errFile -Raw }
                throw "argocd admin export failed (exit $exit): $errText"
            }
        }
        finally {
            Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        # Run export inside the argocd-server pod. Capture stdout only to keep YAML clean.
        $kubectlExe = Join-Path (Get-KubeBinPath) 'kubectl.exe'
        if (-not (Test-Path -LiteralPath $kubectlExe)) {
            $kubectlExe = 'kubectl'
        }

        $errFile = Join-Path $env:TEMP ('k2s-argocd-export-pod-' + [guid]::NewGuid().ToString('n') + '.err')
        try {
            $exportOut = & $kubectlExe -n rollout exec deploy/argocd-server -c argocd-server -- argocd admin export -n rollout 2> $errFile
            $exit = $LASTEXITCODE
            if ($exit -ne 0) {
                $errText = ''
                if (Test-Path -LiteralPath $errFile) { $errText = Get-Content -LiteralPath $errFile -Raw }
                throw "argocd admin export (pod) failed (exit $exit): $errText"
            }
        }
        finally {
            Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
        }
    }

    $exportOutText = $exportOut
    if ($exportOut -is [System.Array]) {
        $exportOutText = ($exportOut -join "`n")
    }

    $exportText = Remove-ArgoCdExportNoise -Text "$exportOutText"
    if ([string]::IsNullOrWhiteSpace($exportText)) {
        throw 'argocd admin export returned empty output'
    }

    # Write UTF-8 without BOM to reduce risk of YAML parsing issues in downstream tools.
    [System.IO.File]::WriteAllText($exportPath, $exportText, (New-Object System.Text.UTF8Encoding($false)))
    $files += (Split-Path -Leaf $exportPath)

    $nginxIngressPath = Join-Path $BackupDir 'argocd-ingress-nginx.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'ingress' -Name 'rollout-nginx-cluster-local' -Namespace 'rollout' -OutFile $nginxIngressPath) {
        $files += (Split-Path -Leaf $nginxIngressPath)
    }

    $traefikIngressPath = Join-Path $BackupDir 'argocd-ingress-traefik.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'ingress' -Name 'rollout-traefik-cluster-local' -Namespace 'rollout' -OutFile $traefikIngressPath) {
        $files += (Split-Path -Leaf $traefikIngressPath)
    }

    $nginxGwHttpPath = Join-Path $BackupDir 'argocd-ingress-nginx-gw-httproute-http.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'httproute' -Name 'rollout-nginx-gw-http' -Namespace 'rollout' -OutFile $nginxGwHttpPath) {
        $files += (Split-Path -Leaf $nginxGwHttpPath)
    }

    $nginxGwHttpsPath = Join-Path $BackupDir 'argocd-ingress-nginx-gw-httproute-https.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'httproute' -Name 'rollout-nginx-gw-https' -Namespace 'rollout' -OutFile $nginxGwHttpsPath) {
        $files += (Split-Path -Leaf $nginxGwHttpsPath)
    }

    $mwPath = Join-Path $BackupDir 'argocd-traefik-middleware.json'
    if (Export-MinimalK8sObjectIfExists -Kind 'middlewares.traefik.io' -Name 'oauth2-proxy-auth' -Namespace 'rollout' -OutFile $mwPath) {
        $files += (Split-Path -Leaf $mwPath)
    }
}
catch {
    $errMsg = "Backup of addon 'rollout argocd' failed: $($_.Exception.Message)"

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
    implementation = 'argocd'
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
