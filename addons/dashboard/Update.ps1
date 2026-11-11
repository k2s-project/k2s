# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
	[parameter(Mandatory = $false, HelpMessage = 'Preferred ingress integration to apply (auto/nginx/traefik/nginx-gw/none)')]
	[ValidateSet('auto', 'nginx', 'traefik', 'nginx-gw', 'none')]
	[string] $PreferredIngress = 'auto',
	[string] $InfraNodeSelector = '',
	[switch] $SkipReadiness
)

$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dashboardModule = "$PSScriptRoot\dashboard.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $dashboardModule

$InfraNodeSelector = Get-AddonEffectiveInfrastructureSelector -Name 'dashboard' -Selector $InfraNodeSelector
$hasMatchingNodes = -not $SkipReadiness
if (-not [string]::IsNullOrWhiteSpace($InfraNodeSelector)) {
	$hasMatchingNodes = $hasMatchingNodes -and (Test-AddonInfrastructureSelectorOnCluster -Name 'dashboard' -Selector $InfraNodeSelector)
}
$addonObj = [pscustomobject] @{ Name = 'dashboard' }

if ($PreferredIngress -eq 'auto') {
	Update-IngressForAddon -Addon $addonObj
}
elseif ($PreferredIngress -eq 'none') {
	Remove-IngressForTraefik -Addon $addonObj
	Remove-IngressForNginx -Addon $addonObj
	Remove-IngressForNginxGateway -Addon $addonObj
}
elseif ($PreferredIngress -eq 'nginx') {
	Remove-IngressForTraefik -Addon $addonObj
	Remove-IngressForNginxGateway -Addon $addonObj
	Update-IngressForNginx -Addon $addonObj
}
elseif ($PreferredIngress -eq 'traefik') {
	Remove-IngressForNginx -Addon $addonObj
	Remove-IngressForNginxGateway -Addon $addonObj
	Update-IngressForTraefik -Addon $addonObj
}
elseif ($PreferredIngress -eq 'nginx-gw') {
	Remove-IngressForTraefik -Addon $addonObj
	Remove-IngressForNginx -Addon $addonObj
	Update-IngressForNginxGateway -Addon $addonObj
}

$linkerdEnabled = Test-LinkerdServiceAvailability
$patchApplied = $false
if ($linkerdEnabled) {
	Write-Log '[Dashboard] Updating Headlamp addon to be part of service mesh' -Console
	$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
	(Invoke-Kubectl -Params 'patch', 'deployment', 'headlamp', '-n', 'dashboard', '-p', $annotations).Output | Write-Log

	$maxAttempts = 30
	$attempt = 0
	$hasAnnotation = $false
	do {
		$attempt++
		$headlampDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'headlamp', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json
		$linkerdAnnotation = $null
		if ($null -ne $headlampDeployment.spec.template.metadata.annotations) {
			$linkerdAnnotation = $headlampDeployment.spec.template.metadata.annotations.'linkerd.io/inject'
		}
		$hasAnnotation = ($linkerdAnnotation -eq 'enabled')
		if (-not $hasAnnotation) {
			Write-Log "[Dashboard] Waiting for Linkerd patch to be applied (attempt $attempt of $maxAttempts)..."
			Start-Sleep -Seconds 2
		}
	} while (-not $hasAnnotation -and $attempt -lt $maxAttempts)

	if (-not $hasAnnotation) {
		throw '[Dashboard] Timeout waiting for Linkerd patch to be applied to headlamp deployment'
	}
	$patchApplied = $true
}
else {
	$currentDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'headlamp', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json
	$currentAnnotation = $null
	if ($null -ne $currentDeployment.spec.template.metadata.annotations) {
		$currentAnnotation = $currentDeployment.spec.template.metadata.annotations.'linkerd.io/inject'
	}

	if ($null -ne $currentAnnotation) {
		Write-Log '[Dashboard] Removing Headlamp from service mesh (Linkerd not running)' -Console
		$annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":null}}}}}'
		(Invoke-Kubectl -Params 'patch', 'deployment', 'headlamp', '-n', 'dashboard', '-p', $annotations).Output | Write-Log

		$maxAttempts = 30
		$attempt = 0
		$hasNoAnnotation = $false
		do {
			$attempt++
			$headlampDeployment = (Invoke-Kubectl -Params 'get', 'deployment', 'headlamp', '-n', 'dashboard', '-o', 'json').Output | ConvertFrom-Json
			$linkerdAnnotation = $null
			if ($null -ne $headlampDeployment.spec.template.metadata.annotations) {
				$linkerdAnnotation = $headlampDeployment.spec.template.metadata.annotations.'linkerd.io/inject'
			}
			$hasNoAnnotation = ($null -eq $linkerdAnnotation)
			if (-not $hasNoAnnotation) {
				Write-Log "[Dashboard] Waiting for Linkerd patch removal (attempt $attempt of $maxAttempts)..."
				Start-Sleep -Seconds 2
			}
		} while (-not $hasNoAnnotation -and $attempt -lt $maxAttempts)

		if (-not $hasNoAnnotation) {
			throw '[Dashboard] Timeout waiting for Linkerd patch removal from headlamp deployment'
		}
		$patchApplied = $true
	}
	else {
		Write-Log '[Dashboard] Headlamp is already not part of service mesh, no patch required' -Console
	}
}

if ($patchApplied -and $hasMatchingNodes) {
	(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', 'headlamp', '-n', 'dashboard', '--timeout', '120s').Output | Write-Log

	# Wait for the old pod to be fully gone — ignore pods already in a terminal state
	# (Error, Completed, OOMKilled, CrashLoopBackOff) so they don't block this check.
	Write-Log '[Dashboard] Waiting for old headlamp pod to terminate...'
	$terminalPhases = @('Succeeded', 'Failed')
	$terminalReasons = @('Error', 'Completed', 'OOMKilled', 'CrashLoopBackOff', 'CreateContainerConfigError')
	$maxWait = 60
	$waited = 0
	do {
		$podsJson = (Invoke-Kubectl -Params 'get', 'pods', '-n', 'dashboard',
			'-l', 'app.kubernetes.io/name=headlamp', '-o', 'json').Output
		$activePodCount = 0
		if ($podsJson) {
			try {
				$podList = $podsJson | ConvertFrom-Json
				foreach ($pod in @($podList.items)) {
					$phase = $pod.status.phase
					$reason = $pod.status.reason
					$containerReason = $pod.status.containerStatuses | Select-Object -First 1 |
						ForEach-Object { $_.state.waiting.reason; $_.state.terminated.reason } |
						Where-Object { $_ } | Select-Object -First 1
					$isTerminal = ($phase -in $terminalPhases) -or
					              ($reason -in $terminalReasons) -or
					              ($containerReason -in $terminalReasons)
					if (-not $isTerminal) { $activePodCount++ }
				}
			}
			catch { $activePodCount = 1 }
		}
		if ($activePodCount -le 1) { break }
		Write-Log "[Dashboard] $activePodCount active headlamp pods still present (old pod terminating), waiting..."
		Start-Sleep -Seconds 2
		$waited += 2
	} while ($waited -lt $maxWait)

	if ($waited -ge $maxWait) {
		Write-Log '[Dashboard] Warning: old headlamp pod did not terminate within the expected time; continuing anyway.' -Console
	}
}

Write-Log '[Dashboard] Syncing Headlamp plugins' -Console
# Plugin activation is an optional, capability-driven enhancement layered on top of an
# already-updated dashboard. A transient sync failure (e.g. a kubectl patch error) must
# NOT fail the dashboard update: the plugin reconciliation is idempotent and re-runs on
# every enable/update, so degrade gracefully with a warning instead.
try {
    Sync-HeadlampPlugins -SkipReadiness:(!$hasMatchingNodes)
}
catch {
    Write-Log "[Dashboard] Headlamp plugin sync failed (dashboard update continues; plugins will reconcile on the next 'k2s addons enable dashboard' or update): $($_.Exception.Message)" -Console
}

Write-Log '[Dashboard] Updating dashboard addon finished.' -Console
