# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Backs up security addon state.

.DESCRIPTION
Exports the following security addon artifacts:
- CA root certificate and key (Secret ca-issuer-root-secret from cert-manager namespace)
- Keycloak PostgreSQL database dump (pg_dump)
- Enhanced security marker file (if present)
- Metadata including detected enable flags for correct restore

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\security\Backup.ps1 -BackupDir C:\Temp\security-backup
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
$securityModule = "$PSScriptRoot\security.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $securityModule

Initialize-Logging -ShowLogs:$ShowLogs

function Fail([string]$errMsg, [string]$code = 'addon-backup-failed') {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code $code -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Fail $systemError.Message 'system-not-available'
    return
}

Write-Log "[SecurityBackup] Backing up addon 'security'" -Console

$addon = [pscustomobject] @{ Name = 'security' }
if ((Test-IsAddonEnabled -Addon $addon) -ne $true) {
    Fail "Addon 'security' is not enabled. Enable it before running backup." 'addon-not-enabled'
    return
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

$script:files = @()

# 1. Detect enable flags from live cluster state

Write-Log '[SecurityBackup] Detecting security addon configuration' -Console

# Detect security type (basic vs enhanced)
$enhancedMarkerPath = Get-EnhancedSecurityFileLocation
$securityType = 'basic'
if (Test-Path $enhancedMarkerPath) {
    $securityType = 'enhanced'
    # Also back up the marker file
    $markerDest = Join-Path $BackupDir 'enhancedsecurity.json'
    Copy-Item -Path $enhancedMarkerPath -Destination $markerDest -Force
    $script:files += 'enhancedsecurity.json'
    Write-Log "[SecurityBackup] Enhanced security marker backed up" -Console
}

# Detect ingress type from the running ingress controller.
# We use the same availability functions that Enable.ps1 uses so that
# nginx-gw (Gateway API — no Ingress resources) is detected correctly.
$ingressType = 'nginx'
if (Test-NginxGatewayAvailability) {
    $ingressType = 'nginx-gw'
}
elseif (Test-TraefikIngressControllerAvailability) {
    $ingressType = 'traefik'
}
elseif (Test-NginxIngressControllerAvailability) {
    $ingressType = 'nginx'
}

# Detect which optional components are deployed
$hasKeycloak = $false
$keycloakDeploy = Invoke-Kubectl -Params 'get', 'deployment', 'keycloak', '-n', 'security', '--no-headers'
if ($keycloakDeploy.Success -and -not [string]::IsNullOrWhiteSpace("$($keycloakDeploy.Output)")) {
    $hasKeycloak = $true
}

$hasHydra = $false
$hydraDeploy = Invoke-Kubectl -Params 'get', 'deployment', 'hydra', '-n', 'security', '--no-headers'
if ($hydraDeploy.Success -and -not [string]::IsNullOrWhiteSpace("$($hydraDeploy.Output)")) {
    $hasHydra = $true
}

$hasOAuth2Proxy = $false
$oauthDeploy = Invoke-Kubectl -Params 'get', 'deployment', 'oauth2-proxy', '-n', 'security', '--no-headers'
if ($oauthDeploy.Success -and -not [string]::IsNullOrWhiteSpace("$($oauthDeploy.Output)")) {
    $hasOAuth2Proxy = $true
}

$hasKyverno = Test-KyvernoServiceAvailability

Write-Log "[SecurityBackup] Detected config: type=$securityType, ingress=$ingressType, keycloak=$hasKeycloak, hydra=$hasHydra, oauth2proxy=$hasOAuth2Proxy, kyverno=$hasKyverno" -Console

# 2. Export CA root Secret

Write-Log '[SecurityBackup] Exporting CA root certificate Secret' -Console

$caSecretResult = Invoke-Kubectl -Params 'get', 'secret', 'ca-issuer-root-secret', '-n', 'cert-manager', '-o', 'yaml'
if ($caSecretResult.Success) {
    $caSecretPath = Join-Path $BackupDir 'ca-issuer-root-secret.yaml'
    $caSecretResult.Output | Set-Content -Path $caSecretPath -Encoding UTF8 -Force
    $script:files += 'ca-issuer-root-secret.yaml'
    Write-Log '[SecurityBackup] CA root Secret exported' -Console
}
else {
    Write-Log "[SecurityBackup] Warning: CA root Secret 'ca-issuer-root-secret' not found in cert-manager namespace. TLS trust chain will not be preserved on restore." -Console
}

# 3. Export Keycloak PostgreSQL dump

if ($hasKeycloak) {
    Write-Log '[SecurityBackup] Exporting Keycloak PostgreSQL database' -Console

    $pgDumpResult = Invoke-Kubectl -Params 'exec', 'deployment/postgresql', '-n', 'security', '--', 'pg_dump', '-U', 'admin', 'keycloak'
    if ($pgDumpResult.Success) {
        $pgDumpPath = Join-Path $BackupDir 'keycloak-db.sql'
        $pgDumpResult.Output | Set-Content -Path $pgDumpPath -Encoding UTF8 -Force
        $script:files += 'keycloak-db.sql'
        Write-Log '[SecurityBackup] Keycloak database dump exported' -Console
    }
    else {
        Write-Log "[SecurityBackup] Warning: pg_dump failed: $($pgDumpResult.Output). Keycloak custom data will not be preserved." -Console
    }
}
else {
    Write-Log '[SecurityBackup] Keycloak not deployed, skipping database dump' -Console
}

# 4. Export Kyverno policies

if ($hasKyverno) {
    Write-Log '[SecurityBackup] Exporting Kyverno policies and exceptions' -Console
    $kyvernoPoliciesResult = Invoke-Kubectl -Params 'get', 'clusterpolicies,policies,policyexceptions', '-A', '-o', 'yaml'
    if ($kyvernoPoliciesResult.Success -and -not [string]::IsNullOrWhiteSpace("$($kyvernoPoliciesResult.Output)")) {
        $kyvernoPoliciesPath = Join-Path $BackupDir 'kyverno-policies.yaml'
        $kyvernoPoliciesResult.Output | Set-Content -Path $kyvernoPoliciesPath -Encoding UTF8 -Force
        $script:files += 'kyverno-policies.yaml'
        Write-Log '[SecurityBackup] Kyverno policies exported' -Console
    }
    else {
        Write-Log '[SecurityBackup] No Kyverno policies found, skipping export' -Console
    }
}
else {
    Write-Log '[SecurityBackup] Kyverno not deployed, skipping policies export' -Console
}

# 5. Write backup manifest

$version = 'unknown'
try { $version = Get-ConfigProductVersion } catch { Write-Log "[SecurityBackup] Could not determine K2s version: $_" }

$backupManifest = [ordered]@{
    k2sVersion   = $version
    addon        = 'security'
    implementation = 'security'
    scope        = 'cluster'
    storageUsage = if ($hasKeycloak) { 'keycloak-db' } else { 'none' }
    files        = $script:files
    createdAt    = (Get-Date -Format 'o')
    enableParams = [ordered]@{
        type           = $securityType
        ingress        = $ingressType
        omitKeycloak   = (-not $hasKeycloak)
        omitHydra      = (-not $hasHydra)
        omitOAuth2Proxy = (-not $hasOAuth2Proxy)
        omitPolicyEnf = (-not $hasKyverno)
    }
}

$manifestPath = Join-Path $BackupDir 'backup.json'
$backupManifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8 -Force

Write-Log "[SecurityBackup] Backup artifacts prepared ($($script:files.Count) file(s))" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
