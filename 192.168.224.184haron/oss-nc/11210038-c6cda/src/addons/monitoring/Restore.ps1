# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Restores monitoring configuration/resources

.DESCRIPTION
Applies previously exported Kubernetes resources from a staging folder.
The addon is enabled by the CLI before running this restore.

This restore is config-only:
- Secret manifests are skipped.
- Persistent volume data is not restored.

.PARAMETER BackupDir
Directory containing backup.json and the referenced files.

.EXAMPLE
powershell <installation folder>\addons\monitoring\Restore.ps1 -BackupDir C:\Temp\monitoring-restore
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Directory containing backup.json and referenced files')]
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

function Fail([string]$errMsg, [string]$code = 'addon-restore-failed') {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code $code -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        exit 1
    }

    Write-Log $errMsg -Error
    exit 1
}

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Fail $systemError.Message 'system-not-available'
}

$manifestPath = Join-Path $BackupDir 'backup.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Fail "backup.json not found in '$BackupDir'" 'addon-restore-failed'
}

$manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json

Write-Log "[MonitoringRestore] Restoring addon 'monitoring'" -Console

$activeIngress = 'none'
if (Test-NginxIngressControllerAvailability) {
    $activeIngress = 'nginx'
}
elseif (Test-TraefikIngressControllerAvailability) {
    $activeIngress = 'traefik'
}
elseif (Test-NginxGatewayAvailability) {
    $activeIngress = 'nginx-gw'
}
Write-Log "[MonitoringRestore] Detected active ingress mode: $activeIngress" -Console

if (-not $manifest.files -or $manifest.files.Count -eq 0) {
    Write-Log "[MonitoringRestore] backup.json contains no files; nothing to apply. Monitoring restore is reinstall/repair-only (handled by the CLI enable step)." -Console
    Write-Log "[MonitoringRestore] Restore completed" -Console

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
    }
    return
}

function Test-IsSecretManifest {
    param([Parameter(Mandatory = $true)][string] $Path)

    try {
        $content = Get-Content -Raw -Path $Path -ErrorAction Stop
        return ($content -match "(?mi)^\\s*kind:\\s*Secret\\s*$")
    }
    catch {
        return $false
    }
}

function Test-IsHelmManagedManifest {
    param([Parameter(Mandatory = $true)][string] $Path)

    try {
        $content = Get-Content -Raw -Path $Path -ErrorAction Stop

        # Heuristic checks for Helm ownership. We intentionally keep this as a text scan
        # to avoid YAML parsing dependencies.
        if ($content -match "(?mi)^\\s*app\\.kubernetes\\.io/managed-by:\\s*Helm\\s*$") {
            return $true
        }
        if ($content -match "(?mi)^\\s*helm\\.sh/chart:\\s*.+$") {
            return $true
        }
        if ($content -match "(?mi)^\\s*meta\\.helm\\.sh/release-name:\\s*.+$") {
            return $true
        }
        if ($content -match "(?mi)^\\s*meta\\.helm\\.sh/release-namespace:\\s*.+$") {
            return $true
        }

        return $false
    }
    catch {
        return $false
    }
}

function Invoke-ApplyWithConflictFallback {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath
    )

    function Get-KubectlOutputText([object]$output) {
        if ($null -eq $output) {
            return ''
        }
        if ($output -is [array]) {
            return ($output | ForEach-Object { "$($_)" }) -join "`n"
        }
        return "$output"
    }

    function Remove-ServerManagedFields([pscustomobject]$obj) {
        if ($null -eq $obj) {
            return
        }

        # Strip server-managed fields that frequently cause update/apply conflicts when restoring.
        $obj.PSObject.Properties.Remove('status') | Out-Null

        if ($obj.metadata) {
            $obj.metadata.PSObject.Properties.Remove('resourceVersion') | Out-Null
            $obj.metadata.PSObject.Properties.Remove('uid') | Out-Null
            $obj.metadata.PSObject.Properties.Remove('generation') | Out-Null
            $obj.metadata.PSObject.Properties.Remove('creationTimestamp') | Out-Null
            $obj.metadata.PSObject.Properties.Remove('managedFields') | Out-Null
            $obj.metadata.PSObject.Properties.Remove('selfLink') | Out-Null

            if ($obj.metadata.annotations) {
                $obj.metadata.annotations.PSObject.Properties.Remove('kubectl.kubernetes.io/last-applied-configuration') | Out-Null
            }
        }
    }

    # Convert manifest into normalized JSON on the client side (no server contact) so we can sanitize fields.
    $dryRun = Invoke-Kubectl -Params 'apply', '--dry-run=client', '-o', 'json', '-f', $FilePath
    if (-not $dryRun.Success) {
        throw "Failed to parse manifest '$FilePath' via kubectl: $(Get-KubectlOutputText -output $dryRun.Output)"
    }

    $obj = $null
    try {
        $obj = (Get-KubectlOutputText -output $dryRun.Output) | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse kubectl JSON for '$FilePath': $($_.Exception.Message)"
    }

    Remove-ServerManagedFields -obj $obj

    $tmp = Join-Path $env:TEMP ("k2s-monitoring-restore-{0}.json" -f ([System.Guid]::NewGuid().ToString('n')))
    try {
        $obj | ConvertTo-Json -Depth 100 | Set-Content -Path $tmp -Encoding UTF8 -Force

        # Always use server-side apply for restore; it is more resilient to live reconciliations.
        $ssaResult = Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '--field-manager=k2s-addon-restore', '--request-timeout=60s', '-f', $tmp
        if (-not $ssaResult.Success) {
            # Retry once for transient "object has been modified" races.
            $out = (Get-KubectlOutputText -output $ssaResult.Output)
            if ($out -match 'the object has been modified') {
                Write-Log "[MonitoringRestore] Detected concurrent modification; retrying server-side apply for '$FilePath'" -Console
                Start-Sleep -Seconds 1
                $ssaResult = Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '--field-manager=k2s-addon-restore', '--request-timeout=60s', '-f', $tmp
            }
        }

        if (-not $ssaResult.Success) {
            throw "Failed to apply '$FilePath' with server-side apply: $(Get-KubectlOutputText -output $ssaResult.Output)"
        }

        $outOk = (Get-KubectlOutputText -output $ssaResult.Output)
        if (-not [string]::IsNullOrWhiteSpace($outOk)) {
            $outOk | Write-Log
        }
    }
    finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

try {
    foreach ($file in $manifest.files) {
        $filePath = Join-Path $BackupDir $file
        if (-not (Test-Path -LiteralPath $filePath)) {
            throw "Backup file not found: $file"
        }

        if (Test-IsSecretManifest -Path $filePath) {
            Write-Log "[MonitoringRestore] Skipping Secret manifest '$file' (config-only restore)" -Console
            continue
        }

        if (Test-IsHelmManagedManifest -Path $filePath) {
            Write-Log "[MonitoringRestore] Skipping Helm-managed manifest '$file' (will be recreated/managed by addon enable)" -Console
            continue
        }

        # Skip ingress resources that don't match the currently active ingress controller.
        if ($file -match '^ingress_' -and $activeIngress -ne 'nginx') {
            Write-Log "[MonitoringRestore] Skipping nginx ingress manifest '$file' (active: $activeIngress)" -Console
            continue
        }
        if ($file -match '^httproute_' -and $activeIngress -ne 'nginx-gw') {
            Write-Log "[MonitoringRestore] Skipping nginx-gw httproute manifest '$file' (active: $activeIngress)" -Console
            continue
        }
        if ($file -match '^ingressroute_' -and $activeIngress -ne 'traefik') {
            Write-Log "[MonitoringRestore] Skipping traefik ingressroute manifest '$file' (active: $activeIngress)" -Console
            continue
        }
        if ($file -match '^middleware_' -and $activeIngress -ne 'traefik') {
            Write-Log "[MonitoringRestore] Skipping traefik middleware manifest '$file' (active: $activeIngress)" -Console
            continue
        }

        Invoke-ApplyWithConflictFallback -FilePath $filePath
    }
}
catch {
    Fail "Restore of addon 'monitoring' failed: $($_.Exception.Message)" 'addon-restore-failed'
}

# Best-effort rollouts
try {
    Write-Log "[MonitoringRestore] Waiting for monitoring workloads (best-effort)" -Console

    $kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'deployments', '-n', 'monitoring', '--timeout=180s')
    Write-Log $kubectlCmd.Output

    $kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonsets', '-n', 'monitoring', '--timeout=180s')
    Write-Log $kubectlCmd.Output

    $kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', 'monitoring', '--timeout=180s')
    Write-Log $kubectlCmd.Output
}
catch {
    Write-Log "[MonitoringRestore] Warning: rollout checks failed: $($_.Exception.Message)" -Console
}

Write-Log "[MonitoringRestore] Restore completed" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
