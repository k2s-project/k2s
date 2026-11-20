# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$metricsModule = "$PSScriptRoot\metrics.module.psm1"
Import-Module $addonsModule, $metricsModule

# Deploy Windows Exporter as HostProcess container (shared resource, idempotent)
Write-Log 'Deploying Windows Exporter (shared resource for metrics collection)' -Console
$windowsExporterManifest = Get-WindowsExporterManifestDir
(Invoke-Kubectl -Params 'apply', '-k', $windowsExporterManifest).Output | Write-Log

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
	Write-Log "Updating metrics addon to be part of service mesh"  
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"4443\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'metrics-server', '-n', 'metrics', '-p', $annotations).Output | Write-Log

	# Patch Windows Exporter DaemonSet for service mesh
	Write-Log "Updating Windows Exporter to be part of service mesh"
	$annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'daemonset', 'windows-exporter', '-n', 'kube-system', '-p', $annotations2, '--ignore-not-found').Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'metrics-server', '-n', 'metrics', '-o', 'json').Output | ConvertFrom-Json
		$hasAnnotation = $deployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled'
		if (-not $hasAnnotation) {
			Write-Log "Waiting for patch to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasAnnotation -and $attempt -lt $maxAttempts)

	if (-not $hasAnnotation) {
		throw "Timeout waiting for patch to be applied"
	}
} else {
	Write-Log "Updating metrics addon to not be part of service mesh"
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'metrics-server', '-n', 'metrics', '-p', $annotations).Output | Write-Log

	# Remove Linkerd injection from Windows Exporter
	Write-Log "Updating Windows Exporter to not be part of service mesh"
	$annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":null}}}}}'
	(Invoke-Kubectl -Params 'patch', 'daemonset', 'windows-exporter', '-n', 'kube-system', '-p', $annotations2, '--ignore-not-found').Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'metrics-server', '-n', 'metrics', '-o', 'json').Output | ConvertFrom-Json
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
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'metrics', '--timeout', '60s').Output | Write-Log

Write-Log 'Updating metrics addon finished.' -Console
