# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$nginxGateWayModule = "$PSScriptRoot\nginx-gw.module.psm1"
Import-Module $infraModule, $clusterModule, $addonsModule, $nginxGateWayModule

Initialize-Logging -ShowLogs:$false

function Update-LinkerdAnnotation {
	param (
		[string]$AnnotationsPatch,
		[string]$ExpectedValue,
		[bool] $EnhancedSecurityEnabled
	)
     (Invoke-Kubectl -Params 'patch', 'deployment', 'nginx-gw-controller', '-n', 'nginx-gw', '-p', $AnnotationsPatch).Output | Write-Log
	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$deployment = (Invoke-Kubectl -Params 'get', 'deployment', 'nginx-gw-controller', '-n', 'nginx-gw', '-o', 'json').Output | ConvertFrom-Json
		
		if($EnhancedSecurityEnabled) {
		$Annotation = $deployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled'
		}
		else {
		$Annotation= $null -eq $deployment.spec.template.metadata.annotations.'linkerd.io/inject'
		}
		if (-not $Annotation) {
			Write-Log "Waiting for patch to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $Annotation -and $attempt -lt $maxAttempts)

	if (-not $Annotation) {
		throw "Timeout waiting for patch to be applied"
	}
}

$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot
Write-Log "Updating addon with name: $addonName"
$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
$securityAddonEnabled = Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'security' })
if ($EnancedSecurityEnabled -or $securityAddonEnabled) {
	Enable-NginxGatewaySnippetsFilter
}

if ($EnancedSecurityEnabled) {
	Write-Log "Updating nginx gateway fabric addon to be part of service mesh" -Console
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":\"443,8443,9113\",\"config.linkerd.io/skip-outbound-ports\":\"443\",\"linkerd.io/inject\":\"enabled\"}}}}}'
	Update-LinkerdAnnotation -AnnotationsPatch $annotations -ExpectedValue 'enabled' -EnhancedSecurityEnabled $true
	
	# Patch oauth2-proxy to skip outbound port 443 for Keycloak HTTPS communication
	Write-Log "Patching oauth2-proxy for service mesh compatibility" -Console
	$oauth2Annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-outbound-ports\":\"443\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'oauth2-proxy', '-n', 'security', '-p', $oauth2Annotations).Output | Write-Log
} else {
	Write-Log "Updating nginx gateway fabric addon to not be part of service mesh"
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"config.linkerd.io/skip-outbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
	Update-LinkerdAnnotation -AnnotationsPatch $annotations -ExpectedValue $null -EnhancedSecurityEnabled $false
}
$rolloutResult = Invoke-Kubectl -Params 'rollout', 'status', 'deployment', 'nginx-gw-controller', '-n', 'nginx-gw', '--timeout=120s'
$rolloutResult.Output | Write-Log
if (-not $rolloutResult.Success) {
	Write-Log '[NginxGw] WARNING: rollout did not complete within 120s; mTLS identity may not be ready' -Console
}
Write-Log 'Updating nginx gateway fabric addon finished.' -Console
