# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
Import-Module $addonsModule

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
	Write-Log "Updating autoscaling addon to be part of service mesh"  
	$annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"8081\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'keda-admission', '-n', 'autoscaling', '-p', $annotations1).Output | Write-Log
	$annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"6443\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'keda-metrics-apiserver', '-n', 'autoscaling', '-p', $annotations2).Output | Write-Log
	$annotations3 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"8081\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'keda-operator', '-n', 'autoscaling', '-p', $annotations3).Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$admissionDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'keda-admission', '-n', 'autoscaling', '-o', 'json').Output | ConvertFrom-Json
		$metricsDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'keda-metrics-apiserver', '-n', 'autoscaling', '-o', 'json').Output | ConvertFrom-Json
		$operatorDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'keda-operator', '-n', 'autoscaling', '-o', 'json').Output | ConvertFrom-Json
		$hasAnnotations = ($admissionDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
						 ($metricsDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
						 ($operatorDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled')
		if (-not $hasAnnotations) {
			Write-Log "Waiting for patches to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasAnnotations -and $attempt -lt $maxAttempts)

	if (-not $hasAnnotations) {
		throw "Timeout waiting for patches to be applied"
	}
} else {
	Write-Log "Updating autoscaling addon to not be part of service mesh"
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'keda-admission', '-n', 'autoscaling', '-p', $annotations).Output | Write-Log
	(Invoke-Kubectl -Params 'patch', 'deployment', 'keda-metrics-apiserver', '-n', 'autoscaling', '-p', $annotations).Output | Write-Log
	(Invoke-Kubectl -Params 'patch', 'deployment', 'keda-operator', '-n', 'autoscaling', '-p', $annotations).Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$admissionDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'keda-admission', '-n', 'autoscaling', '-o', 'json').Output | ConvertFrom-Json
		$metricsDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'keda-metrics-apiserver', '-n', 'autoscaling', '-o', 'json').Output | ConvertFrom-Json
		$operatorDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'keda-operator', '-n', 'autoscaling', '-o', 'json').Output | ConvertFrom-Json
		$hasNoAnnotations = ($null -eq $admissionDeployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
						   ($null -eq $metricsDeployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
						   ($null -eq $operatorDeployment.spec.template.metadata.annotations.'linkerd.io/inject')
		if (-not $hasNoAnnotations) {
			Write-Log "Waiting for patches to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasNoAnnotations -and $attempt -lt $maxAttempts)

	if (-not $hasNoAnnotations) {
		throw "Timeout waiting for patches to be applied"
	}
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'autoscaling', '--timeout', '60s').Output | Write-Log

Write-Log 'Updating autoscaling addon finished.' -Console
