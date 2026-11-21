# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Omit Grafana web UI; deploy only Prometheus, Alertmanager, and exporters')]
    [switch] $OmitGrafana
)

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$monitoringModule = "$PSScriptRoot\monitoring.module.psm1"
$dashboardModule = "$PSScriptRoot\..\dashboard\dashboard.module.psm1"

Import-Module $addonsModule, $monitoringModule

# Check if Grafana was omitted during installation (from config or parameter)
$monitoringConfig = Get-AddonConfig -Name 'monitoring'
$omitGrafana = $OmitGrafana.IsPresent -or ($monitoringConfig.OmitGrafana -eq $true)

# Safe kubectl JSON getter: returns parsed object or $null on transient errors (TLS timeout, etc.)
function Get-KubectlJson {
    param([string[]]$Params)
    $r = Invoke-Kubectl -Params $Params
    if (-not $r.Success) { Write-Log "[Update] kubectl error, will retry: $($r.Output)"; return $null }
    $out = $r.Output
    if ([string]::IsNullOrWhiteSpace($out) -or -not $out.TrimStart().StartsWith('{')) {
        Write-Log "[Update] kubectl returned non-JSON output, will retry: $out"; return $null
    }
    try { return $out | ConvertFrom-Json } catch { Write-Log "[Update] ConvertFrom-Json failed, will retry: $_"; return $null }
}

# Deploy Windows Exporter as HostProcess container (shared resource, idempotent)
Write-Log 'Deploying Windows Exporter (shared resource for metrics collection)' -Console
$windowsExporterManifest = Get-WindowsExporterManifestDir
(Invoke-Kubectl -Params 'apply', '-k', $windowsExporterManifest).Output | Write-Log

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'monitoring' })

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
	Write-Log "Updating monitoring addon to be part of service mesh"  
	$annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"10250\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-operator', '-n', 'monitoring', '-p', $annotations1).Output | Write-Log
	if (-not $omitGrafana) {
		$annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-outbound-ports\":\"9100\"}}}}}'
		(Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-grafana', '-n', 'monitoring', '-p', $annotations2).Output | Write-Log
	}
	$annotations3 = '{\"spec\":{\"podMetadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}'
	(Invoke-Kubectl -Params 'patch', 'prometheus', 'kube-prometheus-stack-prometheus', '-n', 'monitoring', '-p', $annotations3, '--type=merge').Output | Write-Log
	$annotations4 = '{\"spec\":{\"podMetadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}'
	(Invoke-Kubectl -Params 'patch', 'alertmanager', 'kube-prometheus-stack-alertmanager', '-n', 'monitoring', '-p', $annotations4, '--type=merge').Output | Write-Log
	$annotations5 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-kube-state-metrics', '-n', 'monitoring', '-p', $annotations5).Output | Write-Log

	# Patch Windows Exporter DaemonSet for service mesh
	Write-Log "Updating Windows Exporter to be part of service mesh"
	$winExporterExists = (Invoke-Kubectl -Params 'get', 'daemonset', 'windows-exporter', '-n', 'kube-system', '--ignore-not-found', '-o', 'name').Output
	if ($winExporterExists) {
		$annotations6 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
		(Invoke-Kubectl -Params 'patch', 'daemonset', 'windows-exporter', '-n', 'kube-system', '-p', $annotations6).Output | Write-Log
	} else {
		Write-Log "windows-exporter DaemonSet not found in kube-system, skipping linkerd injection patch"
	}

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$operatorDeployment = Get-KubectlJson -Params 'get', 'deployment', 'kube-prometheus-stack-operator', '-n', 'monitoring', '-o', 'json'
		if (-not $omitGrafana) {
			$grafanaDeployment = Get-KubectlJson -Params 'get', 'deployment', 'kube-prometheus-stack-grafana', '-n', 'monitoring', '-o', 'json'
		}
		$metricsDeployment = Get-KubectlJson -Params 'get', 'deployment', 'kube-prometheus-stack-kube-state-metrics', '-n', 'monitoring', '-o', 'json'
		$prometheus = Get-KubectlJson -Params 'get', 'prometheus', 'kube-prometheus-stack-prometheus', '-n', 'monitoring', '-o', 'json'
		$alertmanager = Get-KubectlJson -Params 'get', 'alertmanager', 'kube-prometheus-stack-alertmanager', '-n', 'monitoring', '-o', 'json'

		$requiredResourcesMissing = (-not $operatorDeployment) -or (-not $metricsDeployment) -or (-not $prometheus) -or (-not $alertmanager)
		if (-not $omitGrafana) {
			$requiredResourcesMissing = $requiredResourcesMissing -or (-not $grafanaDeployment)
		}
		if ($requiredResourcesMissing) {
			Write-Log "Waiting for kubectl to respond (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
			continue
		}

		$hasAnnotations = ($operatorDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
				($metricsDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
				($prometheus.spec.podMetadata.annotations.'linkerd.io/inject' -eq 'enabled') -and
				($alertmanager.spec.podMetadata.annotations.'linkerd.io/inject' -eq 'enabled')
		if (-not $omitGrafana) {
			$hasAnnotations = $hasAnnotations -and ($grafanaDeployment.spec.template.metadata.annotations.'linkerd.io/inject' -eq 'enabled')
		}
		if (-not $hasAnnotations) {
			Write-Log "Waiting for patches to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasAnnotations -and $attempt -lt $maxAttempts)

	if (-not $hasAnnotations) {
		throw "Timeout waiting for patches to be applied"
	}
} else {
	Write-Log "Updating monitoring addon to not be part of service mesh"
	$annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/skip-inbound-ports\":null,\"config.linkerd.io/skip-outbound-ports\":null,\"linkerd.io/inject\":null}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-operator', '-n', 'monitoring', '-p', $annotations1).Output | Write-Log
	if (-not $omitGrafana) {
		(Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-grafana', '-n', 'monitoring', '-p', $annotations1).Output | Write-Log
	}
	(Invoke-Kubectl -Params 'patch', 'deployment', 'kube-prometheus-stack-kube-state-metrics', '-n', 'monitoring', '-p', $annotations1).Output | Write-Log
	$annotations2 = '{\"spec\":{\"podMetadata\":{\"annotations\":{\"linkerd.io/inject\":null}}}}'
	(Invoke-Kubectl -Params 'patch', 'prometheus', 'kube-prometheus-stack-prometheus', '-n', 'monitoring', '-p', $annotations2, '--type=merge').Output | Write-Log
	(Invoke-Kubectl -Params 'patch', 'alertmanager', 'kube-prometheus-stack-alertmanager', '-n', 'monitoring', '-p', $annotations2, '--type=merge').Output | Write-Log

	# Remove Linkerd injection from Windows Exporter
	Write-Log "Updating Windows Exporter to not be part of service mesh"
	$winExporterExists = (Invoke-Kubectl -Params 'get', 'daemonset', 'windows-exporter', '-n', 'kube-system', '--ignore-not-found', '-o', 'name').Output
	if ($winExporterExists) {
		$annotations3 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":null}}}}}'
		(Invoke-Kubectl -Params 'patch', 'daemonset', 'windows-exporter', '-n', 'kube-system', '-p', $annotations3).Output | Write-Log
	} else {
		Write-Log "windows-exporter DaemonSet not found in kube-system, skipping linkerd removal patch"
	}

	$maxAttempts = 30
	$attempt = 0
	do {
		$attempt++
		$operatorDeployment = Get-KubectlJson -Params 'get', 'deployment', 'kube-prometheus-stack-operator', '-n', 'monitoring', '-o', 'json'
		if (-not $omitGrafana) {
			$grafanaDeployment = Get-KubectlJson -Params 'get', 'deployment', 'kube-prometheus-stack-grafana', '-n', 'monitoring', '-o', 'json'
		}
		$metricsDeployment = Get-KubectlJson -Params 'get', 'deployment', 'kube-prometheus-stack-kube-state-metrics', '-n', 'monitoring', '-o', 'json'
		$prometheus = Get-KubectlJson -Params 'get', 'prometheus', 'kube-prometheus-stack-prometheus', '-n', 'monitoring', '-o', 'json'
		$alertmanager = Get-KubectlJson -Params 'get', 'alertmanager', 'kube-prometheus-stack-alertmanager', '-n', 'monitoring', '-o', 'json'

		$requiredResourcesMissing = (-not $operatorDeployment) -or (-not $metricsDeployment) -or (-not $prometheus) -or (-not $alertmanager)
		if (-not $omitGrafana) {
			$requiredResourcesMissing = $requiredResourcesMissing -or (-not $grafanaDeployment)
		}
		if ($requiredResourcesMissing) {
			Write-Log "Waiting for kubectl to respond (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
			continue
		}

		$hasNoAnnotations = ($null -eq $operatorDeployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
				($null -eq $metricsDeployment.spec.template.metadata.annotations.'linkerd.io/inject') -and
				($null -eq $prometheus.spec.podMetadata.annotations.'linkerd.io/inject') -and
				($null -eq $alertmanager.spec.podMetadata.annotations.'linkerd.io/inject')
		if (-not $omitGrafana) {
			$hasNoAnnotations = $hasNoAnnotations -and ($null -eq $grafanaDeployment.spec.template.metadata.annotations.'linkerd.io/inject')
		}
		if (-not $hasNoAnnotations) {
			Write-Log "Waiting for patches to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasNoAnnotations -and $attempt -lt $maxAttempts)

	if (-not $hasNoAnnotations) {
		throw "Timeout waiting for patches to be applied"
	}
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'monitoring', '--timeout', '300s').Output | Write-Log
(Invoke-Kubectl -Params 'rollout', 'status', 'statefulset', '-n', 'monitoring', '--timeout', '300s').Output | Write-Log

if (Test-Path $dashboardModule) {
    Import-Module $dashboardModule -Force
    if (Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue) {
        Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins after monitoring update' -Console
        try {
            Sync-HeadlampPlugins
        }
        catch {
            # Plugin sync is best-effort: a failure here must not fail the primary addon operation.
            Write-Log "[Dashboard][Plugin] Headlamp plugin sync failed (monitoring update continues): $($_.Exception.Message)" -Console
        }
    }
}

Write-Log 'Updating monitoring addon finished.' -Console
