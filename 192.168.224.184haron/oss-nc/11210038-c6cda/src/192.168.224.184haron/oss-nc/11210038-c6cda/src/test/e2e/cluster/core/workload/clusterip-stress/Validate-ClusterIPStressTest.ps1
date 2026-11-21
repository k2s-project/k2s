# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
Validates ClusterIP allocation after stress test deployment.

.DESCRIPTION
This script verifies:
1. All ClusterIP services received unique, non-duplicate IPs
2. All headless services correctly have ClusterIP = None
3. No service is stuck without a ClusterIP assignment
4. The clusterip-webhook pod is healthy

Deploy the stress test manifests first:
    kubectl apply -k test/e2e/cluster/core/workload/clusterip-stress/

Cleanup after testing:
  kubectl delete namespace clusterip-stress-test

.EXAMPLE
kubectl apply -k test/e2e/cluster/core/workload/clusterip-stress/
powershell -File Validate-ClusterIPStressTest.ps1
kubectl delete namespace clusterip-stress-test
#>

param(
    [string]$Namespace = 'clusterip-stress-test',
    [int]$ExpectedClusterIPServices = 20,
    [int]$ExpectedHeadlessServices = 6
)

$ErrorActionPreference = 'Stop'

function Invoke-Kubectl {
    param([string[]]$Arguments)
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $output = & kubectl @Arguments 2>$errFile
        if ($LASTEXITCODE -ne 0) {
            $errContent = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
            Write-Host "FAIL: kubectl $($Arguments -join ' ') failed (exit code $LASTEXITCODE):" -ForegroundColor Red
            if ($errContent) { Write-Host $errContent -ForegroundColor Red }
            exit 1
        }
        return $output
    } finally {
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "======================================"
Write-Host " ClusterIP Stress Test Validation"
Write-Host "======================================"
Write-Host ""

# 1. Check webhook pod health (with retry for pod restarts during startup)
Write-Host "[1/4] Checking clusterip-webhook pod health..."
$webhookReady = $false
for ($i = 1; $i -le 12; $i++) {
    $raw = Invoke-Kubectl -Arguments @('get', 'pods', '-n', 'k2s-webhook', '-l', 'app.kubernetes.io/name=clusterip-webhook', '-o', 'json')
    $webhookPod = $raw | ConvertFrom-Json
    # Exclude pods being terminated during rolling updates
    $activePods = @($webhookPod.items | Where-Object { $null -eq $_.metadata.deletionTimestamp })
    if ($activePods.Count -eq 0) {
        if ($i -lt 12) {
            Write-Host "  Waiting for webhook pod (attempt $i/12)..."
            Start-Sleep -Seconds 5
            continue
        }
        Write-Host "FAIL: No clusterip-webhook pod found in k2s-webhook namespace" -ForegroundColor Red
        exit 1
    }
    $notReady = @($activePods | Where-Object {
        $_.status.phase -ne 'Running' -or
        ($_.status.conditions | Where-Object { $_.type -eq 'Ready' }).status -ne 'True'
    })
    if ($notReady.Count -eq 0) {
        $webhookReady = $true
        break
    }
    if ($i -lt 12) {
        Write-Host "  Waiting for webhook pod readiness (attempt $i/12)..."
        Start-Sleep -Seconds 5
    }
}
if (-not $webhookReady) {
    Write-Host "FAIL: Webhook pod(s) not Ready after $(($i - 1) * 5)s:" -ForegroundColor Red
    $notReady | ForEach-Object { Write-Host "  - $($_.metadata.name): phase=$($_.status.phase)" -ForegroundColor Red }
    exit 1
}
Write-Host "  OK: All $($activePods.Count) webhook pod(s) Running and Ready"

# 2. Get all services in the stress test namespace (with readiness wait)
Write-Host ""
Write-Host "[2/4] Collecting services in namespace '$Namespace'..."

$maxAttempts = 12
$waitSeconds = 5
$allServices = @()
$pendingSvcs = @()
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    # Inline kubectl call (not Invoke-Kubectl) to allow retry on transient failures
    # like namespace-not-found, instead of hard-exiting on first error.
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $output = & kubectl get svc -n $Namespace -o json 2>$errFile
        if ($LASTEXITCODE -ne 0) {
            $errContent = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
            if ($attempt -lt $maxAttempts) {
                Write-Host "  Waiting for namespace/services (attempt $attempt/$maxAttempts): kubectl returned exit code $LASTEXITCODE"
                Start-Sleep -Seconds $waitSeconds
                continue
            }
            Write-Host "FAIL: kubectl get svc -n $Namespace failed after $maxAttempts attempts:" -ForegroundColor Red
            if ($errContent) { Write-Host $errContent -ForegroundColor Red }
            exit 1
        }
    } finally {
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }

    $services = $output | ConvertFrom-Json
    $allServices = $services.items

    $nonHeadlessSvcs = @($allServices | Where-Object { $_.spec.clusterIP -ne 'None' })
    $pendingSvcs = @($nonHeadlessSvcs | Where-Object { [string]::IsNullOrEmpty($_.spec.clusterIP) })

    if ($allServices.Count -ge ($ExpectedClusterIPServices + $ExpectedHeadlessServices) -and $pendingSvcs.Count -eq 0) {
        break
    }

    if ($attempt -lt $maxAttempts) {
        Write-Host "  Waiting for services to be ready (attempt $attempt/$maxAttempts, found $($allServices.Count) services, $($pendingSvcs.Count) pending IP)..."
        Start-Sleep -Seconds $waitSeconds
    }
}

if ($pendingSvcs.Count -gt 0 -or $allServices.Count -lt ($ExpectedClusterIPServices + $ExpectedHeadlessServices)) {
    Write-Host "FAIL: Timed out waiting for services to be ready after $(($maxAttempts - 1) * $waitSeconds)s." -ForegroundColor Red
    Write-Host "  Expected $($ExpectedClusterIPServices + $ExpectedHeadlessServices) services, found $($allServices.Count). Pending IPs: $($pendingSvcs.Count)." -ForegroundColor Red
    exit 1
}

Write-Host "  Found $($allServices.Count) services total"

# 3. Validate ClusterIP services have unique IPs
Write-Host ""
Write-Host "[3/4] Validating ClusterIP uniqueness..."
$expectedTotal = $ExpectedClusterIPServices + $ExpectedHeadlessServices

# Filter by expected name patterns to avoid false matches from unrelated services
$stressClusterIPSvcs = @($allServices | Where-Object {
    $_.metadata.name -like 'stress-linux-*' -or $_.metadata.name -like 'stress-win-*'
})
# Check exact total service count
if ($allServices.Count -ne $expectedTotal) {
    Write-Host "FAIL: Expected $expectedTotal total services, got $($allServices.Count)" -ForegroundColor Red
    $unexpected = @($allServices | Where-Object {
        $_.metadata.name -notlike 'stress-linux-*' -and $_.metadata.name -notlike 'stress-win-*' -and $_.metadata.name -notlike 'stress-headless-*'
    })
    if ($unexpected.Count -gt 0) {
        Write-Host "  Unexpected services:" -ForegroundColor Red
        $unexpected | ForEach-Object { Write-Host "    - $($_.metadata.name)" -ForegroundColor Red }
    }
    Write-Host "  Hint: If leftover services exist from a prior run, clean up with: kubectl delete namespace $Namespace" -ForegroundColor Yellow
    exit 1
}

# Check for empty/missing ClusterIPs first (clearer diagnostic before count check)
$missingIP = @($stressClusterIPSvcs | Where-Object { [string]::IsNullOrEmpty($_.spec.clusterIP) -or $_.spec.clusterIP -eq 'None' })
if ($missingIP.Count -gt 0) {
    Write-Host "FAIL: $($missingIP.Count) services have no ClusterIP assigned:" -ForegroundColor Red
    $missingIP | ForEach-Object { Write-Host "  - $($_.metadata.name)" -ForegroundColor Red }
    exit 1
}

Write-Host "  ClusterIP services: $($stressClusterIPSvcs.Count) (expected: $ExpectedClusterIPServices)"

if ($stressClusterIPSvcs.Count -ne $ExpectedClusterIPServices) {
    Write-Host "FAIL: Expected $ExpectedClusterIPServices ClusterIP services, got $($stressClusterIPSvcs.Count)" -ForegroundColor Red
    exit 1
}

$clusterIPServices = $stressClusterIPSvcs

# Check for duplicate ClusterIPs (THE critical check that would have caught the bug)
$ipMap = @{}
$duplicates = @()
foreach ($svc in $clusterIPServices) {
    $ip = $svc.spec.clusterIP
    $name = $svc.metadata.name
    if ($ipMap.ContainsKey($ip)) {
        $ipMap[$ip] += @($name)
    } else {
        $ipMap[$ip] = @($name)
    }
}
foreach ($entry in $ipMap.GetEnumerator()) {
    if ($entry.Value.Count -gt 1) {
        $duplicates += "  DUPLICATE: $($entry.Key) assigned to: $($entry.Value -join ', ')"
    }
}

if ($duplicates.Count -gt 0) {
    Write-Host "FAIL: Duplicate ClusterIP allocations detected!" -ForegroundColor Red
    $duplicates | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Write-Host ""
    Write-Host "All ClusterIP assignments:"
    foreach ($svc in $clusterIPServices) {
        Write-Host "  $($svc.metadata.name) = $($svc.spec.clusterIP)"
    }
    exit 1
}

# Check for duplicate secondary IPs in dual-stack clusters (spec.clusterIPs)
$allClusterIPs = @()
foreach ($svc in $clusterIPServices) {
    if ($svc.spec.clusterIPs) {
        foreach ($ip in $svc.spec.clusterIPs) {
            if (-not [string]::IsNullOrEmpty($ip) -and $ip -ne 'None') {
                $allClusterIPs += [PSCustomObject]@{ IP = $ip; Name = $svc.metadata.name }
            }
        }
    }
}
$dualStackDupes = @()
$dualStackMap = @{}
foreach ($entry in $allClusterIPs) {
    if ($dualStackMap.ContainsKey($entry.IP)) {
        $dualStackMap[$entry.IP] += @($entry.Name)
    } else {
        $dualStackMap[$entry.IP] = @($entry.Name)
    }
}
foreach ($entry in $dualStackMap.GetEnumerator()) {
    if ($entry.Value.Count -gt 1) {
        $dualStackDupes += "  DUPLICATE: $($entry.Key) assigned to: $($entry.Value -join ', ')"
    }
}
if ($dualStackDupes.Count -gt 0) {
    Write-Host "FAIL: Duplicate IPs detected in spec.clusterIPs (dual-stack):" -ForegroundColor Red
    $dualStackDupes | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    exit 1
}

Write-Host "  OK: All $($clusterIPServices.Count) ClusterIPs are unique"
Write-Host ""
Write-Host "  Assigned IPs:"
foreach ($svc in ($clusterIPServices | Sort-Object { $_.spec.clusterIP })) {
    Write-Host "    $($svc.spec.clusterIP) -> $($svc.metadata.name)"
}

# 4. Validate headless services
Write-Host ""
Write-Host "[4/4] Validating headless services..."

# Check services that should be headless (by name) directly from $allServices
$badHeadless = @($allServices | Where-Object {
    $_.metadata.name -like 'stress-headless-*' -and $_.spec.clusterIP -ne 'None'
})
if ($badHeadless.Count -gt 0) {
    Write-Host "FAIL: Headless services incorrectly received a ClusterIP:" -ForegroundColor Red
    $badHeadless | ForEach-Object { Write-Host "  - $($_.metadata.name): $($_.spec.clusterIP)" -ForegroundColor Red }
    exit 1
}

$actualHeadless = @($allServices | Where-Object { $_.metadata.name -like 'stress-headless-*' })
if ($actualHeadless.Count -ne $ExpectedHeadlessServices) {
    Write-Host "FAIL: Expected $ExpectedHeadlessServices headless services, got $($actualHeadless.Count)" -ForegroundColor Red
    exit 1
}
Write-Host "  OK: All $($actualHeadless.Count) headless services have ClusterIP=None"

# Summary
Write-Host ""
Write-Host "======================================"
Write-Host " ALL CHECKS PASSED"
Write-Host "======================================"
Write-Host ""
Write-Host " ClusterIP services: $($clusterIPServices.Count) (all unique)"
Write-Host " Headless services:  $($actualHeadless.Count) (all None)"
Write-Host " Webhook pod:        Running/Ready"
Write-Host ""
exit 0
