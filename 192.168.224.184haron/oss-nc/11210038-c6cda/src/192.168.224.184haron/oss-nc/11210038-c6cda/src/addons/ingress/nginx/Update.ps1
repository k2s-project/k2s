# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$nginxModule = "$PSScriptRoot\nginx.module.psm1"
Import-Module $addonsModule, $nginxModule

$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot
Write-Log "Updating addon with name: $addonName"

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
	Write-Log "Updating nginx ingress addon to be part of service mesh"  
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":\"443,8443,10254\",\"config.linkerd.io/skip-outbound-ports\":\"443\",\"linkerd.io/inject\":\"enabled\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'ingress-nginx-controller', '-n', 'ingress-nginx', '-p', $annotations).Output | Write-Log
	
	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'ingress-nginx-controller', '-n', 'ingress-nginx', '-o', 'json').Output | ConvertFrom-Json
		$hasAnnotation = $deployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled'
		if (-not $hasAnnotation) {
			Write-Log "Waiting for patch to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasAnnotation -and $attempt -lt $maxAttempts)

	if (-not $hasAnnotation) {
		throw "Timeout waiting for patch to be applied"
	}

	Write-Log "Waiting for ingress-nginx-controller rollout to complete (webhook readiness)..." -Console
	$rolloutResult = Invoke-Kubectl -Params 'rollout', 'status', 'deployment', 'ingress-nginx-controller', '-n', 'ingress-nginx', '--timeout=120s'
	$rolloutResult.Output | Write-Log
	if (-not $rolloutResult.Success) {
		Write-Log "[ingress-nginx] WARNING: rollout did not complete within 120s; webhook may not be ready" -Console
	}

	Write-Log '[ingress-nginx] Waiting for admission webhook endpoint to have ready IPs...' -Console
	$webhookMaxWait = 60
	$webhookWaited = 0
	do {
		$endpointResult = Invoke-Kubectl -Params 'get', 'endpoints', 'ingress-nginx-controller-admission', '-n', 'ingress-nginx', '-o', 'jsonpath={.subsets[*].addresses[*].ip}'
		$webhookEndpoints = $endpointResult.Output
		if ($endpointResult.Success -and $webhookEndpoints) { break }
		Start-Sleep -Seconds 3
		$webhookWaited += 3
	} while ($webhookWaited -lt $webhookMaxWait)
	if ($webhookEndpoints) {
		Write-Log "[ingress-nginx] Admission webhook ready (IPs: $webhookEndpoints)" -Console
	} else {
		Write-Log '[ingress-nginx] WARNING: admission webhook endpoint has no ready IPs after 60s; Ingress applies may fail' -Console
	}
} else {
	Write-Log "Updating nginx ingress addon to not be part of service mesh"
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"config.linkerd.io/skip-outbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'ingress-nginx-controller', '-n', 'ingress-nginx', '-p', $annotations).Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'ingress-nginx-controller', '-n', 'ingress-nginx', '-o', 'json').Output | ConvertFrom-Json
		$hasNoAnnotation = $null -eq $deployment.spec.template.metadata.annotations.'linkerd.io/inject'
		if (-not $hasNoAnnotation) {
			Write-Log "Waiting for patch to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasNoAnnotation -and $attempt -lt $maxAttempts)

	if (-not $hasNoAnnotation) {
		throw "Timeout waiting for patch to be applied"
	}
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'ingress-nginx', '--timeout', '60s').Output | Write-Log
Write-Log 'Updating ingress nginx addon finished.' -Console
