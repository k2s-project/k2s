# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$traefikModule = "$PSScriptRoot\traefik.module.psm1"
Import-Module $addonsModule, $traefikModule

$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot
Write-Log "Updating addon with name: $addonName"

$clusterIngressConfig = "$PSScriptRoot\manifests\cluster-local-ingress.yaml"
(Invoke-Kubectl -Params 'apply' , '-f', $clusterIngressConfig).Output | Write-Log

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
	Write-Log "Updating traefik ingress addon to be part of service mesh"  
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":\"8443,9000,9001\",\"config.linkerd.io/skip-outbound-ports\":\"443\",\"linkerd.io/inject\":\"enabled\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'traefik', '-n', 'ingress-traefik', '-p', $annotations).Output | Write-Log
	
	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'traefik', '-n', 'ingress-traefik', '-o', 'json').Output | ConvertFrom-Json
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
	Write-Log "Updating traefik ingress addon to not be part of service mesh"
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"config.linkerd.io/skip-outbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'traefik', '-n', 'ingress-traefik', '-p', $annotations).Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'traefik', '-n', 'ingress-traefik', '-o', 'json').Output | ConvertFrom-Json
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
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'ingress-traefik', '--timeout', '60s').Output | Write-Log
Write-Log 'Updating ingress traefik addon finished.' -Console

