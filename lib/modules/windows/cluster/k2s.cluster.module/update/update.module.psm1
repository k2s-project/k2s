# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.DESCRIPTION
	This module implements delta update functionality for K2s clusters.
	
	EXECUTION CONTEXT DETECTION:
	This module can run in two contexts:
	1. From installed k2s folder (e.g., C:\k\lib\modules\...) - uses relative paths
	2. From extracted delta package - expects modules already loaded by Start-ClusterUpdate.ps1
	
	When running from delta package:
	- Start-ClusterUpdate.ps1 detects delta context and loads modules from target installation
	- This module skips duplicate module loading
	- References target installation via Get-ClusterInstalledFolder for file operations
#>

# Detect if we're running from a delta package (extracted) or from installed k2s
# If delta-manifest.json exists 6 levels up, we're in a delta package.
# The relocated module lives at lib\modules\windows\cluster\k2s.cluster.module\update.
$deltaManifestCheck = Join-Path (Split-Path (Split-Path (Split-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent) -Parent) -Parent) 'delta-manifest.json'
$runningFromDelta = Test-Path -LiteralPath $deltaManifestCheck

if ($runningFromDelta) {
	# Running from delta package - modules should already be loaded by Start-ClusterUpdate.ps1
	# No need to import again, but verify key functions are available
	if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
		Write-Warning "[Update] Running from delta package but Write-Log not available - modules may not be loaded"
	}
	$script:DeferredModuleLoad = $false  # Already loaded by caller
} else {
	# Running from installed k2s - use normal relative paths
	$infraModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
	Import-Module $infraModule
	
	# Import runningstate module for k2s running check
	$runningStateModule = "$PSScriptRoot/../runningstate/runningstate.module.psm1"
	Import-Module $runningStateModule
	$script:DeferredModuleLoad = $false
}

# Helper functions for version validation (from upgrade module)
function Get-ClusterInstalledFolder {
	$installFolder = Get-ConfigInstallFolder
	if ( [string]::IsNullOrEmpty($installFolder) ) {
		# we assume it is the old default
		$installFolder = 'C:\k'
	}
	return $installFolder
}

function Get-UpdateVmModulePath {
	if ($script:runningFromDelta) {
		$installFolder = Get-ClusterInstalledFolder
		return Join-Path $installFolder 'lib\modules\windows\node\k2s.node.module\linuxnode\vm\vm.module.psm1'
	}

	return "$PSScriptRoot\..\..\..\node\k2s.node.module\linuxnode\vm\vm.module.psm1"
}

function Get-ProductVersionGivenKubePath {
	param (
		[Parameter(Mandatory = $false)]
		[string]$KubePathLocal = $(throw 'KubePath not specified')        
	)
	return "$(Get-Content -Raw -Path "$KubePathLocal\VERSION")".Trim()
}

function Test-DeltaUpgradeVersionIsValid {
	param (
		[Parameter(Mandatory = $true)]
		[string] $VersionInstalled,
		[Parameter(Mandatory = $true)]
		[string] $VersionToBeUsed
	)

	$VersionInstalled = $VersionInstalled.Trim()
	$VersionToBeUsed = $VersionToBeUsed.Trim()
	$versionRegex = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'

	if (-not ($VersionInstalled -match $versionRegex)) {
		Write-Log "[Update][Error] The format of the currently installed version is invalid: current='$VersionInstalled', valid='1.22.333'"
		return $false
	}
	if (-not ($VersionToBeUsed -match $versionRegex)) {
		Write-Log "[Update][Error] The format of the delta target version is invalid: target='$VersionToBeUsed', valid='1.22.333'"
		return $false
	}

	$currentVersion = [System.Version]::Parse($VersionInstalled)
	$nextVersion = [System.Version]::Parse($VersionToBeUsed)

	if ($nextVersion -le $currentVersion) {
		Write-Log "[Update][Error] The delta target version must be greater than the current version: current='$VersionInstalled', target='$VersionToBeUsed'"
		return $false
	}

	if ($nextVersion.Major -ne $currentVersion.Major) {
		Write-Log "[Update][Error] Delta upgrade not supported from $VersionInstalled to $VersionToBeUsed. Major version must be the same for delta upgrades." -Console
		return $false
	}

	return $true
}

<#
.SYNOPSIS
	Restores CoreDNS etcd plugin configuration after kubeadm upgrade.
.DESCRIPTION
	kubeadm upgrade may reset CoreDNS customizations. This function restores:
	- etcd TLS secrets (etcd-ca, etcd-client-for-core-dns)
	- CoreDNS ConfigMap etcd plugin block
	- CoreDNS Deployment volume mounts for etcd certificates
	
	This is required because K2s uses CoreDNS with an etcd plugin for external DNS
	resolution (see docs/op-manual/external-dns.md).
.PARAMETER ControlPlaneIp
	IP address of the control plane. Defaults to 172.19.1.100.
.PARAMETER ShowLogs
	Show detailed logs to console.
.OUTPUTS
	[bool] Success indicator.
.NOTES
	Requires Invoke-CmdOnControlPlaneViaSSHKey to be available (vm module).
#>
function Restore-CoreDnsEtcdConfiguration {
	[CmdletBinding()]
	param(
		[string]$ControlPlaneIp = '172.19.1.100',
		[switch]$ShowLogs
	)
	
	$consoleSwitch = $ShowLogs
	
	try {
		Write-Log "[CoreDNS] Restoring etcd plugin configuration..." -Console:$consoleSwitch
		Write-Log "[CoreDNS] Using control plane IP: $ControlPlaneIp" -Console:$consoleSwitch
		
		# Verify SSH helper is available
		if (-not (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
			$vmModule = Get-UpdateVmModulePath
			if (Test-Path -LiteralPath $vmModule) { 
				Import-Module $vmModule -Force -ErrorAction SilentlyContinue
			} else {
				$installFolder = Get-ClusterInstalledFolder
				$vmModule = Join-Path $installFolder 'lib/modules/windows/node/k2s.node.module/linuxnode/vm/vm.module.psm1'
				if (Test-Path -LiteralPath $vmModule) {
					Import-Module $vmModule -Force -ErrorAction SilentlyContinue
				}
			}
		}
		if (-not (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
			Write-Log "[CoreDNS][Error] SSH helper not available - vm module not found at $vmModule" -Console:$consoleSwitch
			return $false
		}
		
		# Step 1: Recreate etcd secrets for CoreDNS
		Write-Log "[CoreDNS] Recreating etcd secrets..." -Console:$consoleSwitch
		$certCopyResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'sudo mkdir -p /tmp/etcd-certs && sudo cp /etc/kubernetes/pki/etcd/* /tmp/etcd-certs/ && sudo chmod 444 /tmp/etcd-certs/*' -Timeout 30
		if (-not $certCopyResult.Success) {
			Write-Log "[CoreDNS][Error] Failed to copy etcd certificates: $($certCopyResult.Output)" -Console:$consoleSwitch
			return $false
		}
		
		$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete secret -n kube-system etcd-ca --ignore-not-found=true' -Timeout 30
		Write-Log "[CoreDNS] Delete old etcd-ca secret: Success=$($result.Success)" -Console:$consoleSwitch
		
		$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete secret -n kube-system etcd-client-for-core-dns --ignore-not-found=true' -Timeout 30
		Write-Log "[CoreDNS] Delete old etcd-client secret: Success=$($result.Success)" -Console:$consoleSwitch
		
		$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl create secret -n kube-system tls etcd-ca --cert=/tmp/etcd-certs/ca.crt --key=/tmp/etcd-certs/ca.key' -Timeout 30
		if (-not $result.Success) {
			Write-Log "[CoreDNS][Error] Failed to create etcd-ca secret: $($result.Output)" -Console:$consoleSwitch
			Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'sudo rm -rf /tmp/etcd-certs' -Timeout 10 -IgnoreErrors:$true | Out-Null
			return $false
		}
		Write-Log "[CoreDNS] Created etcd-ca secret" -Console:$consoleSwitch
		
		$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl create secret -n kube-system tls etcd-client-for-core-dns --cert=/tmp/etcd-certs/healthcheck-client.crt --key=/tmp/etcd-certs/healthcheck-client.key' -Timeout 30
		if (-not $result.Success) {
			Write-Log "[CoreDNS][Error] Failed to create etcd-client secret: $($result.Output)" -Console:$consoleSwitch
			Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'sudo rm -rf /tmp/etcd-certs' -Timeout 10 -IgnoreErrors:$true | Out-Null
			return $false
		}
		Write-Log "[CoreDNS] Created etcd-client-for-core-dns secret" -Console:$consoleSwitch
		
		Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'sudo rm -rf /tmp/etcd-certs' -Timeout 10 -IgnoreErrors:$true | Out-Null
		Write-Log "[CoreDNS] etcd secrets recreated" -Console:$consoleSwitch
		
		# Step 2: Update CoreDNS configmap to add etcd plugin if missing
		Write-Log "[CoreDNS] Checking CoreDNS configmap for etcd plugin..." -Console:$consoleSwitch
		$etcdPluginCheck = (Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl get configmap coredns -n kube-system -o yaml | grep -c "etcd cluster.local" || echo 0' -Timeout 30).Output
		if ($etcdPluginCheck -match '^0') {
			Write-Log "[CoreDNS] Adding etcd plugin to configmap..." -Console:$consoleSwitch
			$addEtcdPlugin = "kubectl get configmap coredns -n kube-system -o yaml | sed '/^\s*prometheus :9153/i\        etcd cluster.local {\n            path /skydns\n            endpoint https://${ControlPlaneIp}:2379\n            tls /etc/kubernetes/pki/etcd-client/tls.crt /etc/kubernetes/pki/etcd-client/tls.key /etc/kubernetes/pki/etcd-ca/tls.crt\n        }' | kubectl apply -f -"
			$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $addEtcdPlugin -Timeout 30
			if (-not $result.Success) {
				Write-Log "[CoreDNS][Error] Failed to update configmap: $($result.Output)" -Console:$consoleSwitch
				return $false
			}
			Write-Log "[CoreDNS] etcd plugin added to configmap" -Console:$consoleSwitch
		} else {
			Write-Log "[CoreDNS] etcd plugin already present in configmap" -Console:$consoleSwitch
		}
		
		# Step 3: Update CoreDNS deployment to mount etcd certificate volumes if missing
		# Uses a single atomic kubectl patch to add both volumes AND mounts together,
		# avoiding the broken intermediate state where volumes exist without mounts.
		Write-Log "[CoreDNS] Checking CoreDNS deployment for etcd volume mounts..." -Console:$consoleSwitch
		$volumeCheck = (Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl get deployment coredns -n kube-system -o yaml | grep -c "etcd-ca-cert" || echo 0' -Timeout 30).Output
		if ($volumeCheck -match '^0') {
			Write-Log "[CoreDNS] Adding etcd volumes and mounts atomically via kubectl patch..." -Console:$consoleSwitch
			$patchJson = '[' +
				'{"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"etcd-ca-cert","secret":{"secretName":"etcd-ca"}}},' +
				'{"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"etcd-client-cert","secret":{"secretName":"etcd-client-for-core-dns"}}},' +
				'{"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"mountPath":"/etc/kubernetes/pki/etcd-ca","name":"etcd-ca-cert"}},' +
				'{"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"mountPath":"/etc/kubernetes/pki/etcd-client","name":"etcd-client-cert"}}' +
				']'
			# Base64-encode JSON to avoid double-quote stripping during PowerShell->ssh.exe transport
			$base64Json = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patchJson))
			$patchCmd = "echo $base64Json | base64 -d | kubectl patch deployment coredns -n kube-system --type=json --patch-file=/dev/stdin"
			$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $patchCmd -Timeout 30 -Retries 2
			if (-not $result.Success) {
				Write-Log "[CoreDNS][Error] Failed to patch deployment: $($result.Output)" -Console:$consoleSwitch
				return $false
			}
			Write-Log "[CoreDNS] Deployment patched with etcd volumes and mounts" -Console:$consoleSwitch
		} else {
			Write-Log "[CoreDNS] etcd volume mounts already present in deployment" -Console:$consoleSwitch
		}
		
		# Step 4: Restart CoreDNS and wait for it to become available
		Write-Log "[CoreDNS] Restarting CoreDNS deployment..." -Console:$consoleSwitch
		$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl rollout restart deployment/coredns -n kube-system' -Timeout 30
		if (-not $result.Success) {
			Write-Log "[CoreDNS][Warn] Rollout restart command failed: $($result.Output)" -Console:$consoleSwitch
		}
		
		$result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl rollout status deployment/coredns -n kube-system --timeout=120s' -Timeout 150
		if (-not $result.Success) {
			Write-Log "[CoreDNS][Warn] Rollout did not complete within timeout: $($result.Output)" -Console:$consoleSwitch
		}
		
		# Step 5: Verify CoreDNS pods are actually running (not CrashLoopBackOff)
		Write-Log "[CoreDNS] Verifying CoreDNS pod health..." -Console:$consoleSwitch
		Start-Sleep -Seconds 10
		$podStatus = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath=''{range .items[*]}{.status.phase} {.status.containerStatuses[0].ready}{"\n"}{end}''' -Timeout 30
		if ($podStatus.Success) {
			$statusLines = ($podStatus.Output -split "`n") | Where-Object { $_ -match '\S' }
			$allHealthy = $true
			foreach ($line in $statusLines) {
				if ($line -notmatch 'Running true') {
					$allHealthy = $false
					break
				}
			}
			if ($allHealthy -and $statusLines.Count -gt 0) {
				Write-Log "[CoreDNS] All CoreDNS pods healthy ($($statusLines.Count) pods running)" -Console:$consoleSwitch
			} else {
				Write-Log "[CoreDNS][Warn] Some CoreDNS pods may not be healthy:" -Console:$consoleSwitch
				$diagResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide' -Timeout 30
				Write-Log "[CoreDNS][Diag] $($diagResult.Output)" -Console:$consoleSwitch
				$logsResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl logs -n kube-system -l k8s-app=kube-dns --tail=20 --all-containers 2>&1' -Timeout 30
				Write-Log "[CoreDNS][Diag] Recent logs: $($logsResult.Output)" -Console:$consoleSwitch
			}
		} else {
			Write-Log "[CoreDNS][Warn] Could not verify pod health: $($podStatus.Output)" -Console:$consoleSwitch
		}
		
		Write-Log "[CoreDNS] Configuration restored successfully" -Console:$consoleSwitch
		return $true
	} catch {
		Write-Log ("[CoreDNS][Error] Restoration failed: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
		Write-Log "[CoreDNS][Error] Manual restoration may be required - see docs/op-manual/external-dns.md" -Console:$consoleSwitch
		return $false
	}
}

<#
.SYNOPSIS
	Restores the ClusterIP mutating webhook after kubeadm upgrade.
.DESCRIPTION
	kubeadm upgrade apply may regenerate API server certificates and restart
	kube-apiserver. This can invalidate the webhook's TLS certificate chain
	(the caBundle in the MutatingWebhookConfiguration no longer matches the
	webhook's self-signed cert) or leave the webhook pod in a broken state.

	Because the webhook uses failurePolicy: Ignore, a broken webhook is
	silently skipped and Services get random ClusterIPs from the full /16
	service CIDR instead of the /24 subnets enforced by the webhook.

	The webhook Deployment uses an init container that generates a fresh TLS
	certificate on each Pod start. This function:
	1. Copies webhook manifests from the target installation to the control plane
	2. Re-applies namespace, RBAC and webhook configuration
	3. Applies the Deployment (with init-cert init container)
	4. Triggers a rollout restart to generate a fresh certificate
	5. Validates the webhook caBundle is set
.PARAMETER TargetInstallPath
	Path to the target K2s installation (e.g. C:\k).
.PARAMETER ShowLogs
	Show detailed logs to console.
.OUTPUTS
	[bool] Success indicator.
.NOTES
	Requires Invoke-CmdOnControlPlaneViaSSHKey and Copy-ToControlPlaneViaSSHKey
	to be available (vm module).
#>
function Restore-ClusterIPWebhook {
	[CmdletBinding()]
	param(
		[string]$TargetInstallPath = $(throw 'Argument missing: TargetInstallPath'),
		[switch]$ShowLogs
	)

	$consoleSwitch = $ShowLogs

	try {
		Write-Log '[Webhook] Restoring ClusterIP webhook after update...' -Console:$consoleSwitch

		# Verify SSH helpers are available
		if (-not (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
			$vmModule = Get-UpdateVmModulePath
			if (Test-Path -LiteralPath $vmModule) {
				Import-Module $vmModule -Force -ErrorAction SilentlyContinue
			} else {
				$vmModule = Join-Path $TargetInstallPath 'lib/modules/windows/node/k2s.node.module/linuxnode/vm/vm.module.psm1'
				if (Test-Path -LiteralPath $vmModule) {
					Import-Module $vmModule -Force -ErrorAction SilentlyContinue
				}
			}
		}
		if (-not (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
			Write-Log '[Webhook][Error] SSH helper not available - vm module not found' -Console:$consoleSwitch
			return $false
		}

		# Locate webhook manifests in the target installation
		$manifestDir = Join-Path $TargetInstallPath 'lib\manifests\clusterip-webhook'
		if (-not (Test-Path -LiteralPath $manifestDir)) {
			Write-Log "[Webhook][Warn] Webhook manifests not found at $manifestDir - skipping" -Console:$consoleSwitch
			return $true
		}

		$remoteDir = '/tmp/clusterip-webhook-update'
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "mkdir -p $remoteDir" -Timeout 30 -IgnoreErrors:$true).Output | Out-Null

		# Copy manifest files to control plane
		$manifestFiles = @(
			'namespace.yaml',
			'rbac.yaml',
			'webhook-config.yaml',
			'deployment.yaml'
		)

		foreach ($file in $manifestFiles) {
			$localPath = Join-Path $manifestDir $file
			if (Test-Path -LiteralPath $localPath) {
				Copy-ToControlPlaneViaSSHKey -Source $localPath -Target "$remoteDir/" -IgnoreErrors:$false
			} else {
				Write-Log "[Webhook][Warn] Manifest file not found: $file" -Console:$consoleSwitch
			}
		}

		# Step 1: Apply namespace and RBAC
		Write-Log '[Webhook] Applying namespace and RBAC...' -Console:$consoleSwitch
		$nsResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "kubectl apply -f $remoteDir/namespace.yaml" -Timeout 30 -Retries 3 -IgnoreErrors:$true
		Write-Log ('[Webhook] namespace apply: success={0} output={1}' -f $nsResult.Success, ($nsResult.Output | Out-String).Trim()) -Console:$consoleSwitch
		$rbacResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "kubectl apply -f $remoteDir/rbac.yaml" -Timeout 30 -Retries 3 -IgnoreErrors:$true
		Write-Log ('[Webhook] rbac apply: success={0} output={1}' -f $rbacResult.Success, ($rbacResult.Output | Out-String).Trim()) -Console:$consoleSwitch

		# Step 2: Apply webhook configuration only if it doesn't exist yet.
		# Re-applying would reset caBundle to "" causing a TLS race condition until the init
		# container re-patches it. The init container handles caBundle patching on every pod restart.
		$webhookExists = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl get mutatingwebhookconfiguration k2s-webhook' -Timeout 30 -IgnoreErrors:$true
		if (-not $webhookExists.Success) {
			Write-Log '[Webhook] Creating MutatingWebhookConfiguration...' -Console:$consoleSwitch
			(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "kubectl apply -f $remoteDir/webhook-config.yaml" -Timeout 30 -Retries 3 -IgnoreErrors:$true).Output | Out-Null
		} else {
			Write-Log '[Webhook] MutatingWebhookConfiguration already exists — skipping to preserve caBundle' -Console:$consoleSwitch
		}

		# Step 3: Clean up legacy certgen resources from previous versions
		Write-Log '[Webhook] Cleaning up legacy certgen resources...' -Console:$consoleSwitch
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete job clusterip-webhook-certgen-create -n k2s-webhook --ignore-not-found=true' -Timeout 30 -IgnoreErrors:$true).Output | Out-Null
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete job clusterip-webhook-certgen-patch -n k2s-webhook --ignore-not-found=true' -Timeout 30 -IgnoreErrors:$true).Output | Out-Null
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete secret clusterip-webhook-tls -n k2s-webhook --ignore-not-found=true' -Timeout 30 -IgnoreErrors:$true).Output | Out-Null
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete serviceaccount clusterip-webhook-certgen -n k2s-webhook --ignore-not-found=true' -Timeout 30 -IgnoreErrors:$true).Output | Out-Null
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete role clusterip-webhook-certgen -n k2s-webhook --ignore-not-found=true' -Timeout 30 -IgnoreErrors:$true).Output | Out-Null
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl delete rolebinding clusterip-webhook-certgen -n k2s-webhook --ignore-not-found=true' -Timeout 30 -IgnoreErrors:$true).Output | Out-Null

		# Step 4: Apply deployment (with init-cert init container)
		Write-Log '[Webhook] Applying deployment and service...' -Console:$consoleSwitch
		$deployResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "kubectl apply -f $remoteDir/deployment.yaml" -Timeout 30 -Retries 3 -IgnoreErrors:$true
		$deployOutput = ($deployResult.Output | Out-String).Trim()
		Write-Log ('[Webhook] deployment apply: success={0} output={1}' -f $deployResult.Success, $deployOutput) -Console:$consoleSwitch

		# Step 5: Ensure the webhook pod is running with a fresh certificate.
		# If the apply changed the deployment spec (e.g., new image/init container), it already
		# triggered a rollout — no restart needed. Only restart if unchanged (to regenerate cert).
		if ($deployOutput -match 'unchanged') {
			Write-Log '[Webhook] Deployment unchanged — restarting to regenerate certificate...' -Console:$consoleSwitch
			(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl rollout restart deployment/clusterip-webhook -n k2s-webhook' -Timeout 30 -IgnoreErrors:$true).Output | Out-Null
		} else {
			Write-Log '[Webhook] Deployment updated — rollout already in progress' -Console:$consoleSwitch
		}
		$rolloutResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl rollout status deployment/clusterip-webhook -n k2s-webhook --timeout=120s' -Timeout 150 -Retries 2 -IgnoreErrors:$true
		if (-not $rolloutResult.Success) {
			Write-Log '[Webhook][Error] Webhook deployment did not become ready after restart' -Console:$consoleSwitch
			return $false
		}

		# Step 6: Validate webhook is operational
		Write-Log '[Webhook] Validating webhook caBundle is set...' -Console:$consoleSwitch
		$caBundleCheck = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "kubectl get mutatingwebhookconfiguration k2s-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}'" -Timeout 30 -IgnoreErrors:$true
		$caBundle = ($caBundleCheck.Output | Out-String).Trim()
		if ([string]::IsNullOrWhiteSpace($caBundle)) {
			Write-Log '[Webhook][Error] MutatingWebhookConfiguration has empty caBundle - webhook will not intercept service creation' -Console:$consoleSwitch
			return $false
		}
		Write-Log '[Webhook] Webhook caBundle validated successfully' -Console:$consoleSwitch

		# Cleanup
		(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "rm -rf $remoteDir" -Timeout 30 -IgnoreErrors:$true).Output | Out-Null

		Write-Log '[Webhook] ClusterIP webhook restored successfully' -Console:$consoleSwitch
		return $true
	} catch {
		Write-Log ("[Webhook][Error] Webhook restoration failed: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
		return $false
	}
}

# region: installation relocation (delta update re-home)

<#
.SYNOPSIS
	Names of Windows services whose nssm configuration may embed the K2s installation path.
.DESCRIPTION
	These services are registered via nssm during installation with absolute paths pointing
	to executables and configuration files inside the installation folder. When the
	installation is relocated (delta update re-home), each of these must be re-pointed.
.OUTPUTS
	[string[]] Service names.
#>
function Get-K2sManagedServiceName {
	return @('containerd', 'flanneld', 'kubelet', 'kubeproxy', 'dnsproxy', 'httpproxy', 'windows_exporter', 'docker')
}

<#
.SYNOPSIS
	Filters a delta manifest 'Removed' list to entries that are safe to delete during an update.
.DESCRIPTION
	The manifest 'Removed' list (files present in the old package but not the new) can contain
	false positives for content under the 'bin' directory. Those binaries are owned wholesale by
	the new package - via wholesale directories (bin\kube, bin\docker, bin\containerd, bin\cni)
	and the loose tools extracted from bin\WindowsNodeArtifacts.zip at install/start time - not by
	the per-file delta. The package-vs-package diff can wrongly classify them as 'Removed' because
	the wholesale list is finalized only after the diff runs during creation, and because the
	loose tools live inside the ZIP in a package but loose in an installation. Deleting them would
	remove essential executables (e.g. nssm.exe, ctr.exe, containerd.exe) and break the cluster.

	Therefore this excludes any entry under 'bin/' and any entry under an explicit wholesale
	directory. Genuine removals elsewhere (manifests, scripts, lib, cfg, ...) are still pruned.
.PARAMETER RemovedFiles
	The manifest 'Removed' relative paths.
.PARAMETER WholesaleDirs
	Relative wholesale directory paths from the delta manifest.
.OUTPUTS
	[string[]] The subset of RemovedFiles that may be safely deleted.
#>
function Select-PrunableRemovedFile {
	param(
		[string[]] $RemovedFiles = @(),
		[string[]] $WholesaleDirs = @()
	)
	$normalizedWholesale = @()
	foreach ($wd in $WholesaleDirs) {
		if ([string]::IsNullOrWhiteSpace($wd)) { continue }
		$normalizedWholesale += (($wd -replace '\\', '/').Trim('/'))
	}
	$result = @()
	foreach ($rel in $RemovedFiles) {
		if ([string]::IsNullOrWhiteSpace($rel)) { continue }
		$norm = ($rel -replace '\\', '/').TrimStart('/')
		# bin/ is owned wholesale by the new package (wholesale dirs + WindowsNodeArtifacts.zip);
		# never prune individual files under it.
		if ($norm -like 'bin/*') { continue }
		# Skip anything under an explicit wholesale directory (replaced as a unit).
		$inWholesale = $false
		foreach ($wd in $normalizedWholesale) {
			if ($norm -like "$wd/*") { $inWholesale = $true; break }
		}
		if ($inWholesale) { continue }
		$result += $rel
	}
	return , $result
}

<#
.SYNOPSIS
	Seeds the new installation folder with files that did not change between versions.
.DESCRIPTION
	The new installation folder (the extracted delta package directory) already contains the
	Added and Changed files from the delta. To become a complete, self-contained installation
	it additionally needs every file from the previous installation that did not change.

	This function copies only files that are MISSING in the new folder (robocopy /XC /XN /XO),
	so the newer delta files are never overwritten. Wholesale directories are NOT excluded from
	seeding: because an offline delta only stages CHANGED binaries (the new versions live in
	WindowsNodeArtifacts.zip), a wholesale directory in the new folder is frequently empty or
	partial. robocopy's "only copy missing" semantics correctly fill in the unchanged binaries
	(e.g. containerd.exe) from the previous installation without clobbering the delta's newer files.
.PARAMETER OldInstallPath
	The previous (current) installation folder, left untouched and used as the seed source.
.PARAMETER NewInstallPath
	The new installation folder (delta package root) being completed.
.PARAMETER WholesaleDirs
	Relative wholesale directory paths from the delta manifest. Retained for signature compatibility;
	no longer used to exclude directories from seeding (see description).
.OUTPUTS
	[bool] success indicator.
#>
function Copy-UnchangedInstallationFiles {
	param(
		[Parameter(Mandatory = $true)][string] $OldInstallPath,
		[Parameter(Mandatory = $true)][string] $NewInstallPath,
		[string[]] $WholesaleDirs = @(),
		[switch] $ShowLogs
	)
	$consoleSwitch = $ShowLogs

	# Seed every file missing in the new folder from the previous installation. /XC /XN /XO make
	# robocopy copy ONLY files that do not already exist in the destination, so the delta's newer
	# (changed/added) files are never overwritten. Wholesale directories are intentionally NOT
	# excluded: an offline delta stages only changed binaries, so a wholesale directory can be empty
	# or partial in the new folder and its unchanged binaries (e.g. bin\containerd\containerd.exe)
	# must be seeded here or the corresponding services would fail to start.
	$robocopyArgs = @($OldInstallPath, $NewInstallPath, '/E', '/XC', '/XN', '/XO', '/R:2', '/W:2', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')

	Write-Log ("[Update] Seeding unchanged files from '{0}' into '{1}'" -f $OldInstallPath, $NewInstallPath) -Console:$consoleSwitch
	& robocopy.exe @robocopyArgs | Out-Null
	$rc = $LASTEXITCODE
	# robocopy exit codes < 8 indicate success (files copied / nothing to do / extras)
	if ($rc -ge 8) {
		Write-Log ("[Update][Error] robocopy seeding failed with exit code {0}" -f $rc) -Console
		return $false
	}
	Write-Log ("[Update] Seeding complete (robocopy exit code {0})" -f $rc) -Console:$consoleSwitch
	return $true
}

function Confirm-UpdateInstallationHome {
	param(
		[Parameter(Mandatory = $true)][string] $SetupConfigPath,
		[Parameter(Mandatory = $true)][string] $ExpectedInstallPath
	)

	$setup = Get-Content -LiteralPath $SetupConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
	if ([string]::IsNullOrWhiteSpace($setup.InstallFolder) -or
		$setup.InstallFolder.TrimEnd('\') -ne $ExpectedInstallPath.TrimEnd('\')) {
		throw "[Update] Installation folder verification failed in '$SetupConfigPath': expected '$ExpectedInstallPath', found '$($setup.InstallFolder)'."
	}
}

function Set-UpdateSetupConfigValue {
	param(
		[Parameter(Mandatory = $true)][string] $SetupConfigPath,
		[Parameter(Mandatory = $true)][string] $Key,
		[Parameter(Mandatory = $true)][object] $Value
	)

	Set-ConfigValue -Path $SetupConfigPath -Key $Key -Value $Value

	$setup = Get-Content -LiteralPath $SetupConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
	$persistedValue = $setup.psobject.Properties[$Key].Value
	if ([string]$persistedValue -ne [string]$Value) {
		throw "[Update] setup.json verification failed for '$Key': expected '$Value', found '$persistedValue'."
	}
}

function Confirm-DeltaKubernetesVersion {
	param(
		[Parameter(Mandatory = $true)][string] $ExpectedVersion,
		[Parameter(Mandatory = $true)][string] $InstallPath
	)

	# The imported k8s-api module still resolves kubectl relative to the old installation.
	$kubectlPath = Join-Path $InstallPath 'bin\kube\kubectl.exe'
	$kubeconfigPath = Join-Path $InstallPath 'config'
	foreach ($path in @($kubectlPath, $kubeconfigPath)) {
		if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
			throw "[Update] Kubernetes version verification requires '$path'."
		}
	}
	Write-Log "[Update] Verifying Kubernetes version using '$kubectlPath' with kubeconfig '$kubeconfigPath'."
	$stderrPath = [System.IO.Path]::GetTempFileName()
	try {
		$output = & $kubectlPath --kubeconfig $kubeconfigPath --request-timeout=30s version -o json 2> $stderrPath
		$queryExitCode = $LASTEXITCODE
		$stderr = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction Stop
		if (-not [string]::IsNullOrWhiteSpace($stderr)) {
			Write-Log "[Update] kubectl version stderr: $stderr"
		}
		if ($queryExitCode -ne 0) {
			throw "[Update] Kubernetes version query failed using '$kubectlPath' (exit code $queryExitCode): $output $stderr"
		}
	} finally {
		Remove-Item -LiteralPath $stderrPath -Force -ErrorAction Stop
	}
	$versionInfo = $output | Out-String | ConvertFrom-Json -ErrorAction Stop
	$clientVersion = $versionInfo.clientVersion.gitVersion
	$serverVersion = $versionInfo.serverVersion.gitVersion
	if ($serverVersion -ne $ExpectedVersion -or $clientVersion -ne $ExpectedVersion) {
		throw "[Update] Kubernetes version verification failed: expected client and server '$ExpectedVersion', got client '$clientVersion' and server '$serverVersion'."
	}
}

function Get-DeltaTargetKubernetesVersion {
	param(
		[Parameter(Mandatory = $true)] $Manifest,
		[Parameter(Mandatory = $true)][string] $DeltaRoot
	)

	$targetVersion = [string]$Manifest.TargetKubernetesVersion
	if (-not [string]::IsNullOrWhiteSpace($targetVersion)) {
		if ($targetVersion -notmatch '^v') {
			$targetVersion = "v$targetVersion"
		}
		return $targetVersion
	}

	if ($Manifest.DebianDeltaRelativePath) {
		$expectedVersionFile = Join-Path (Join-Path $DeltaRoot $Manifest.DebianDeltaRelativePath) 'expected-k8s-version'
		if (Test-Path -LiteralPath $expectedVersionFile) {
			$targetVersion = (Get-Content -LiteralPath $expectedVersionFile -Raw).Trim()
			if (-not [string]::IsNullOrWhiteSpace($targetVersion)) {
				if ($targetVersion -notmatch '^v') {
					$targetVersion = "v$targetVersion"
				}
				return $targetVersion
			}
		}
	}

	return $null
}

<#
.SYNOPSIS
	Re-points the K2s installation from one folder to another (delta update re-home).
.DESCRIPTION
	Updates every place that has the installation path baked in so that the cluster runs from
	the new installation folder:
	  - nssm service configuration (Application / AppDirectory / AppParameters)
	  - StartKubelet.ps1 (contains literal installation paths)
	  - containerd config.toml (regenerated from template with the new path)
	  - machine PATH entries (install root + bin, bin\kube, bin\docker, bin\containerd), mirroring
	    Set-EnvVars in path.module which adds them during installation
	  - kubeconfig file copied into the new installation folder (the active install folder always carries
	    its own 'config'; the machine KUBECONFIG environment variable is intentionally left untouched)
	  - setup.json InstallFolder

	This function is symmetric: calling it with swapped FromPath/ToPath reverses the re-home,
	which is used by the rollback path.
.PARAMETER FromPath
	The installation path currently baked into the services/config.
.PARAMETER ToPath
	The installation path to switch to.
.OUTPUTS
	[bool] success indicator.
#>
function Set-K2sInstallationHome {
	param(
		[Parameter(Mandatory = $true)][string] $FromPath,
		[Parameter(Mandatory = $true)][string] $ToPath,
		[switch] $ShowLogs
	)
	$consoleSwitch = $ShowLogs
	$FromPath = $FromPath.TrimEnd('\')
	$ToPath = $ToPath.TrimEnd('\')
	# Keep the authoritative path before destination imports can change config command bindings.
	$setupConfigPath = Get-SetupConfigFilePath

	Write-Log ("[Update] Re-homing installation from '{0}' to '{1}'" -f $FromPath, $ToPath) -Console:$consoleSwitch

	# Import service helpers from the destination installation (consistent with how the update
	# module imports other node modules by absolute path during delta updates).
	$servicesModule = Join-Path $ToPath 'lib\modules\windows\node\k2s.node.module\windowsnode\services\services.module.psm1'
	if (-not (Test-Path -LiteralPath $servicesModule)) {
		Write-Log ("[Update][Error] services module not found at {0}; cannot re-point services" -f $servicesModule) -Console
		return $false
	}
	Import-Module $servicesModule -Force

	$nssmPath = Join-Path $ToPath 'bin\nssm.exe'
	if (-not (Test-Path -LiteralPath $nssmPath)) {
		Write-Log ("[Update][Error] nssm.exe not found at {0}; cannot re-point services" -f $nssmPath) -Console
		return $false
	}

	# 1. Re-point nssm services
	# Track which service parameters were actually re-pointed so a partial failure (e.g. a later step
	# throws) leaves an audit trail in the log for manual recovery rather than silently discarding it.
	#
	# Update-NssmServiceInstallPath is provided by the destination ($ToPath) services module. On the
	# very first relocating upgrade, a ROLLBACK re-homes back to the PREVIOUS installation whose older
	# services module pre-dates this feature and does not export the function. Detect that and fall back
	# to a direct nssm.exe registry substitution so the rollback still fully re-points the services.
	$repointedCount = 0
	$haveUpdateFn = [bool](Get-Command -Name Update-NssmServiceInstallPath -ErrorAction SilentlyContinue)
	if (-not $haveUpdateFn) {
		Write-Log '[Update][Warn] Update-NssmServiceInstallPath not available in the target installation module; using direct nssm fallback to re-point services.' -Console
	}
	$fromTrim = $FromPath.TrimEnd('\')
	$toTrim = $ToPath.TrimEnd('\')
	$fromPattern = [regex]::Escape($fromTrim)
	foreach ($svc in (Get-K2sManagedServiceName)) {
		try {
			if ($haveUpdateFn) {
				$changed = Update-NssmServiceInstallPath -Name $svc -OldPath $FromPath -NewPath $ToPath -NssmPath $nssmPath
				if ($changed -and $changed.Count -gt 0) {
					$repointedCount += $changed.Count
					Write-Log ("[Update] Re-pointed service '{0}' parameter(s): {1}" -f $svc, (($changed.Keys | Sort-Object) -join ', ')) -Console:$consoleSwitch
				}
			} else {
				# Direct fallback: read the nssm registry parameters and substitute FromPath->ToPath.
				if (-not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) { continue }
				$regKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc\Parameters"
				if (-not (Test-Path -LiteralPath $regKey)) { continue }
				$props = Get-ItemProperty -Path $regKey -ErrorAction SilentlyContinue
				foreach ($parameter in @('Application', 'AppDirectory', 'AppParameters')) {
					$current = $props.$parameter
					if ($null -eq $current) { continue }
					if ($current -is [Array]) { $current = ($current -join ' ') }
					if ($current.IndexOf($fromTrim, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
					$newValue = [regex]::Replace($current, $fromPattern, $toTrim, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
					# Write directly to the registry (see Update-NssmServiceInstallPath) instead of 'nssm.exe set'
					# to avoid the native-command quoting bug for installation paths that contain spaces.
					try {
						Set-ItemProperty -Path $regKey -Name $parameter -Value $newValue -ErrorAction Stop
					} catch {
						Write-Log ("[Update][Warn] nssm fallback failed re-pointing service '{0}' parameter '{1}': {2}" -f $svc, $parameter, $_.Exception.Message) -Console
						continue
					}
					$repointedCount++
					Write-Log ("[Update] Re-pointed service '{0}' parameter '{1}' (fallback)" -f $svc, $parameter) -Console:$consoleSwitch
				}
			}
		} catch {
			Write-Log ("[Update][Warn] Failed to re-point service '{0}': {1}" -f $svc, $_.Exception.Message) -Console:$consoleSwitch
		}
	}
	Write-Log ("[Update] Re-pointed {0} nssm service parameter(s) from '{1}' to '{2}'" -f $repointedCount, $FromPath, $ToPath) -Console:$consoleSwitch

	# 2. Fix StartKubelet.ps1 (contains literal installation paths)
	$startKubeletScript = Join-Path $ToPath 'smallsetup\common\StartKubelet.ps1'
	if (Test-Path -LiteralPath $startKubeletScript) {
		try {
			$content = Get-Content -LiteralPath $startKubeletScript -Raw
			$updated = [regex]::Replace($content, [regex]::Escape($FromPath), $ToPath, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
			if ($updated -ne $content) {
				Set-Content -LiteralPath $startKubeletScript -Value $updated -NoNewline
				Write-Log '[Update] Updated StartKubelet.ps1 with new installation path' -Console:$consoleSwitch
			}
		} catch {
			Write-Log ("[Update][Warn] Failed to update StartKubelet.ps1: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
		}
	}

	# 3. Regenerate containerd config.toml from template with the new installation path.
	# Ordering/independence invariant: the containerd regen helpers derive the installation path from
	# the module-level '$kubePath = Get-KubePath' captured when containerd.module is imported, which
	# resolves from the path module's own $PSScriptRoot. To guarantee that resolves to $ToPath (and not
	# a path.module copy cached from the previous installation), force-reimport the path module from
	# $ToPath FIRST, then import containerd.module from $ToPath. Both are independent of setup.json, so
	# regeneration always targets $ToPath regardless of step 5 below. This also makes the rollback path
	# correct: re-homing back to the previous folder reimports both modules from that folder.
	$pathModule = Join-Path $ToPath 'lib\modules\windows\infra\k2s.infra.module\path\path.module.psm1'
	$containerdModule = Join-Path $ToPath 'lib\modules\windows\node\k2s.node.module\windowsnode\downloader\artifacts\containerd\containerd.module.psm1'
	$containerdTomlPath = Join-Path $ToPath 'cfg\containerd\config.toml'
	if (-not (Test-Path -LiteralPath $containerdModule)) {
		# A missing containerd module means config.toml cannot be regenerated for $ToPath. The toml was
		# seeded from the source installation and still contains the source path, which is a broken
		# state (containerd would fail to start from $ToPath). Treat this as fatal so the caller rolls back.
		Write-Log ("[Update][Error] containerd module not found at {0}; cannot regenerate config.toml for the new installation path" -f $containerdModule) -Console
		return $false
	}
	try {
		if (Test-Path -LiteralPath $pathModule) { Import-Module $pathModule -Force }
		Import-Module $containerdModule -Force
		Set-RootPathForImagesInConfig $containerdTomlPath | Out-Null
		Set-InstallationDirectory $containerdTomlPath | Out-Null
		Set-UserTokenForRegistryInConfig $containerdTomlPath | Out-Null
		Write-Log '[Update] Regenerated containerd config.toml for new installation path' -Console:$consoleSwitch
	} catch {
		# A containerd config.toml left pointing at the source path is a broken state, so fail hard.
		Write-Log ("[Update][Error] Failed to regenerate containerd config.toml: {0}" -f $_.Exception.Message) -Console
		return $false
	}

	# 4. Update the machine PATH environment variable. Install adds five entries (the install root and
	# bin, bin\kube, bin\docker, bin\containerd under it) via Set-EnvVars in path.module; mirror that here.
	# Removal additionally clears the legacy '\containerd' (no '\bin') entry that older installations may
	# still carry, matching Reset-EnvVars, so re-homing never leaves a stale entry pointing at FromPath.
	# path.module (force-reimported from $ToPath in step 3) exposes Update-SystemPath. This is symmetric:
	# the rollback (swapped paths) restores the previous entries (the extra legacy removal is a no-op when
	# the entry is absent).
	try {
		$pathAddSubDirs = @('', '\bin', '\bin\kube', '\bin\docker', '\bin\containerd')
		$pathRemoveSubDirs = $pathAddSubDirs + '\containerd'  # include legacy entry for cleanup
		foreach ($sub in $pathRemoveSubDirs) { Update-SystemPath -Action 'remove' "$FromPath$sub" }
		foreach ($sub in $pathAddSubDirs) { Update-SystemPath -Action 'add' "$ToPath$sub" }
		Write-Log ("[Update] Updated machine PATH entries from '{0}' to '{1}'" -f $FromPath, $ToPath) -Console:$consoleSwitch
	} catch {
		Write-Log ("[Update][Warn] Failed to update machine PATH: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
	}

	# 5. Copy the kubeconfig file into the new installation folder.
	# k2s resolves the kubeconfig relative to the ACTIVE installation folder (setup.json InstallFolder,
	# updated in step 6) and all of its own services pass --kubeconfig explicitly, so the delta update
	# does NOT touch the machine KUBECONFIG environment variable. We only make sure the new folder owns a
	# valid 'config' by copying it from the previous installation folder. The previous folder remains on
	# disk, so any pre-existing machine KUBECONFIG (set by install for the HostVM variant) keeps resolving.
	# This is symmetric: the rollback (swapped paths) copies the kubeconfig back.
	try {
		$fromKubeconfig = Join-Path $FromPath 'config'
		$toKubeconfig = Join-Path $ToPath 'config'
		if (Test-Path -LiteralPath $fromKubeconfig) {
			Copy-Item -LiteralPath $fromKubeconfig -Destination $toKubeconfig -Force -ErrorAction Stop
			Write-Log ("[Update] Copied kubeconfig from '{0}' to '{1}'" -f $fromKubeconfig, $toKubeconfig) -Console:$consoleSwitch
		} else {
			Write-Log ("[Update][Warn] kubeconfig not found at '{0}'; nothing to copy" -f $fromKubeconfig) -Console:$consoleSwitch
		}
	} catch {
		Write-Log ("[Update][Warn] Failed to copy kubeconfig: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
	}

	# 6. Update setup.json InstallFolder
	try {
		Set-ConfigInstallFolder -Value $ToPath
		Confirm-UpdateInstallationHome -SetupConfigPath $setupConfigPath -ExpectedInstallPath $ToPath
		Write-Log ("[Update] setup.json InstallFolder set to '{0}'" -f $ToPath) -Console:$consoleSwitch
	} catch {
		Write-Log ("[Update][Error] Failed to update setup.json InstallFolder: {0}" -f $_.Exception.Message) -Console
		return $false
	}

	return $true
}

<#
.SYNOPSIS
	Removes delta-package-only artifacts from a completed installation folder.
.DESCRIPTION
	After a delta package directory has been promoted to a full installation, files that only
	belong to a delta package (the manifest and staged image/Debian deltas) are removed so the
	folder is indistinguishable from a normal installation and is not misdetected as a delta
	package on a subsequent upgrade.
.PARAMETER InstallPath
	The installation folder to clean.
#>
function Remove-DeltaPackageArtifact {
	param(
		[Parameter(Mandatory = $true)][string] $InstallPath,
		[switch] $ShowLogs
	)
	$consoleSwitch = $ShowLogs
	$artifacts = @('delta-manifest.json', 'image-delta', 'debian-delta')
	foreach ($a in $artifacts) {
		$p = Join-Path $InstallPath $a
		if (Test-Path -LiteralPath $p) {
			try {
				Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
				Write-Log ("[Update] Removed delta artifact from installation: {0}" -f $a) -Console:$consoleSwitch
			} catch {
				Write-Log ("[Update][Warn] Failed to remove delta artifact '{0}': {1}" -f $a, $_.Exception.Message) -Console:$consoleSwitch
			}
		}
	}
}

# endregion

function PerformClusterUpdate {
	<#
	.SYNOPSIS
		Applies a delta package to perform an in-place K2s cluster update.
	.DESCRIPTION
		Implements update flow using a previously extracted delta package.
		This function MUST be executed from the extracted delta package directory, NOT from
		the installed k2s directory. The delta package directory is identified by the presence
		of delta-manifest.json in the current working directory.
		
		The update handles running clusters automatically:
		- If cluster is running: Applies Debian packages first, then stops cluster, applies Windows artifacts, restarts cluster
		- If cluster is not running: Skips Debian packages, applies Windows artifacts only
		
		High-level phases:
		  1. Detect delta root (current directory with delta-manifest.json)
		  2. Detect target installation folder (from setup.json/config)
		  3. Load delta-manifest.json (file lists + optional debian-delta metadata)
		  4. Version compatibility validation
		  5. Apply Debian package delta (if cluster is running)
		  6. Apply Linux guest-config host tools (helm/yq) to the control plane VM, air-gapped (if cluster is running)
		  7. Stop cluster automatically (if it was running)
		  8. Apply updated Windows artifacts (add/update files, remove obsolete files) from delta to target installation
		  9. Restart cluster automatically (if it was running before)
		  10. Import container images from image-delta (Windows via nerdctl, Linux via SCP + buildah)
		  11. Run optional hooks (pre/post) [placeholder]
		  12. Basic health checks (API server reachable, node Ready) if cluster is running
		  13. Restore CoreDNS etcd plugin configuration (kubeadm upgrade may reset customizations)
		  14. Restore ClusterIP webhook TLS certificates (kubeadm upgrade may invalidate certs)
		  15. Final ClusterIP webhook pod restart to re-sync TLS cert/caBundle before workloads start
		  16. Update VERSION file and setup.json (product version + Kubernetes version) to reflect successful update
	.PARAMETER ExecuteHooks
		Execute lifecycle hooks (currently placeholder; no hooks executed yet).
	.PARAMETER ShowProgress
		Emit coarse progress via Write-Progress at phase boundaries.
	.PARAMETER ShowLogs
		Mirror logs to console.
	.OUTPUTS
		[bool] success indicator.
	.NOTES
		Keeps offline guarantees (no network pulls).
		IMPORTANT: Execute this function from the extracted delta package directory.
		The user must:
		  1. Extract the delta package zip: Expand-Archive k2s-delta-xxx.zip -Destination .\delta
		  2. Navigate to the extracted directory: cd .\delta
		  3. Run the update: .\k2s.exe system update
		The cluster will be automatically stopped and restarted if it was running before the update.
	#>
	[CmdletBinding()]
	param(
		[switch] $ExecuteHooks,
		[switch] $ShowProgress,
		[switch] $ShowLogs
	)

	$consoleSwitch = $ShowLogs
	Write-Log '#####################################################################' -Console:$consoleSwitch
	Write-Log '[DeltaUpdate] Delta update starting' -Console:$consoleSwitch
	Write-Log '#####################################################################' -Console:$consoleSwitch
	Write-Log ("[Update] Parameters: ExecuteHooks={0} ShowProgress={1} ShowLogs={2}" -f $ExecuteHooks, $ShowProgress, $ShowLogs) -Console:$consoleSwitch

	# Detect delta root - current directory must contain delta-manifest.json
	$deltaRoot = $PWD.Path
	$manifestPath = Join-Path $deltaRoot 'delta-manifest.json'
	
	if (-not (Test-Path -LiteralPath $manifestPath)) {
		$errorMsg = @"
[Update][Error] delta-manifest.json not found in current directory.

This command must be run from the extracted delta package directory.

Usage:
  1. Extract the delta package: Expand-Archive k2s-delta-xxx.zip -Destination .\delta
  2. Navigate to extracted directory: cd .\delta
  3. Run update: .\k2s.exe system update

Current directory: $deltaRoot
"@
		Write-Log $errorMsg -Console
		return $false
	}
	
	Write-Log ("[Update] Delta package root detected: {0}" -f $deltaRoot) -Console:$consoleSwitch
	$setupConfigPath = Get-SetupConfigFilePath

	# Check if k2s is currently running - we'll handle stopping/starting automatically
	$setupInfo = Get-SetupInfo
	$wasRunning = $false
	if ($setupInfo.Name) {
		$clusterState = Get-RunningState -SetupName $setupInfo.Name
		$wasRunning = ($clusterState.IsRunning -eq $true)
		if ($wasRunning) {
			Write-Log '[Update] K2s is currently running - will stop after applying Debian packages' -Console:$consoleSwitch
		} else {
			Write-Log '[Update] K2s is not running' -Console:$consoleSwitch
		}
	}

	if (-not $wasRunning) {
		Write-Log '[Update][Error] Delta upgrade requires a running cluster. Run k2s start from the current installation and retry. No update changes have been applied.' -Console
		return $false
	}

	$script:phaseId = 0
	$script:totalPhases = 16
	function _phase { 
		param($name) 
		$script:phaseId++
		if ($ShowProgress) { 
			Write-Progress -Activity 'Cluster delta update' -Id 1 -Status ("{0}/{1}: {2}" -f $script:phaseId, $script:totalPhases, $name) -PercentComplete (($script:phaseId) * 100 / $script:totalPhases) 
		} 
		Write-Log ("[Update] Phase {0}/{1}: {2}" -f $script:phaseId, $script:totalPhases, $name) -Console:$consoleSwitch 
	}

	# 1. Load manifest from delta root
	_phase 'Manifest'
	$manifestRaw = Get-Content -LiteralPath $manifestPath -Raw
	try { $manifest = $manifestRaw | ConvertFrom-Json } catch { Write-Log ("[Update][Error] Manifest parse failed: {0}" -f $_.Exception.Message) -Console; return $false }
	Write-Log ("[Update] Manifest loaded: Added={0} Changed={1} Removed={2}" -f $manifest.AddedCount, $manifest.ChangedCount, $manifest.RemovedCount) -Console:$consoleSwitch

	# 2. Get target installation folder
	_phase 'DetectTarget'
	try {
		$targetInstallPath = Get-ClusterInstalledFolder
		Write-Log ("[Update] Target installation folder: {0}" -f $targetInstallPath) -Console:$consoleSwitch
		
		if (-not (Test-Path -LiteralPath $targetInstallPath)) {
			Write-Log ("[Update][Error] Target installation folder does not exist: {0}" -f $targetInstallPath) -Console
			return $false
		}
	} catch {
		Write-Log ("[Update][Error] Failed to determine target installation folder: {0}" -f $_.Exception.Message) -Console
		return $false
	}

	# Decide whether this update relocates the installation to a new folder.
	# The new active installation folder is the delta package directory ($deltaRoot). When it
	# differs from the current installation folder, the update re-homes the installation so that
	# the new folder (e.g. C:\k2s\1.9.0) becomes the valid installation recorded in setup.json.
	# When they are identical (delta extracted on top of the installation) the legacy in-place
	# behavior is used so existing setups are not broken.
	$oldInstallPath = $targetInstallPath.TrimEnd('\')
	$newInstallPath = $deltaRoot.TrimEnd('\')
	$relocate = ($oldInstallPath -ine $newInstallPath)
	$relocationDone = $false
	# Tracks whether the relocation branch stopped the K2s-managed services before the re-home
	# completed. Used by the catch block to restart the still-valid previous installation when a
	# failure occurs after services were stopped but before the re-home took effect.
	$relocateServicesStopped = $false
	# Tracks whether the cluster was actually (re)started from the new installation folder in phase 7.
	# Used by the rollback path to only issue 'k2s stop' against the new folder when something is
	# actually running there, avoiding unnecessary latency when the start itself failed.
	$clusterStartedFromNew = $false
	if ($relocate) {
		Write-Log ("[Update] Installation will be relocated from '{0}' to '{1}'" -f $oldInstallPath, $newInstallPath) -Console:$consoleSwitch
	} else {
		Write-Log '[Update] Delta package directory equals the installation folder; applying update in place.' -Console:$consoleSwitch
	}

	# 3. Validate version compatibility
	_phase 'VersionValidation'
	
	# Get the currently installed cluster version from the target installation folder
	try {
		$currentVersion = Get-ProductVersionGivenKubePath -KubePathLocal $targetInstallPath
		Write-Log ("[Update] Current installed version: {0} (from {1})" -f $currentVersion, $targetInstallPath) -Console:$consoleSwitch
	} catch {
		Write-Log ("[Update][Error] Failed to get current installed version: {0}" -f $_.Exception.Message) -Console
		return $false
	}
	
	$deltaBasePackage = [string]$manifest.BasePackage
	$deltaTargetPackage = [string]$manifest.TargetPackage
	
	# Use version fields directly from manifest (populated from VERSION files during delta generation)
	# Fall back to parsing package name for backward compatibility with older manifests
	function _ExtractVersionFromPackage([string]$packageName) {
		if ([string]::IsNullOrWhiteSpace($packageName)) { return $null }
		# Match patterns like k2s-v1.6.0, k2s-1.6.0, or just 1.6.0
		if ($packageName -match 'k2s-?v?(\d+\.\d+\.\d+)') { return $matches[1] }
		# Fallback: try to find version pattern anywhere in the name
		if ($packageName -match '(\d+\.\d+\.\d+)') { return $matches[1] }
		return $null
	}
	
	# Prefer explicit version fields from manifest; fall back to filename parsing for older manifests
	$deltaBaseVersion = if (-not [string]::IsNullOrWhiteSpace($manifest.BaseVersion)) { 
		$manifest.BaseVersion.Trim() 
	} else { 
		_ExtractVersionFromPackage $deltaBasePackage 
	}
	$deltaTargetVersion = if (-not [string]::IsNullOrWhiteSpace($manifest.TargetVersion)) { 
		$manifest.TargetVersion.Trim() 
	} else { 
		_ExtractVersionFromPackage $deltaTargetPackage 
	}
	
	Write-Log ("[Update] Version Check: Current={0}, DeltaBase={1}, DeltaTarget={2}" -f $currentVersion, $deltaBaseVersion, $deltaTargetVersion) -Console:$consoleSwitch
	
	# Validate that current system version matches delta base version
	if ($deltaBaseVersion -and $currentVersion -ne $deltaBaseVersion) {
		$errorMsg = "[Update][Error] Version mismatch: Current system version '{0}' does not match delta base version '{1}'. Delta package '{2}' cannot be applied to this system." -f $currentVersion, $deltaBaseVersion, $deltaBasePackage
		Write-Log $errorMsg -Console
		return $false
	}
	
	if (-not $deltaBaseVersion) {
		Write-Log ("[Update][Warn] Could not extract base version from package name '{0}'. Proceeding without version validation." -f $deltaBasePackage) -Console:$consoleSwitch
	} else {
		Write-Log ("[Update] Version validation passed: Delta base version '{0}' matches current system version '{1}'" -f $deltaBaseVersion, $currentVersion) -Console:$consoleSwitch
	}
	
	if ($deltaTargetVersion) {
		if (-not (Test-DeltaUpgradeVersionIsValid -VersionInstalled $currentVersion -VersionToBeUsed $deltaTargetVersion)) {
			return $false
		}
		Write-Log ("[Update] Target version after update: {0}" -f $deltaTargetVersion) -Console:$consoleSwitch
	}

	# 4. Debian package delta (apply while cluster is running if needed)
	_phase 'DebianPackages'
	if ($manifest.DebianDeltaRelativePath) {
		$debDir = Join-Path $deltaRoot $manifest.DebianDeltaRelativePath
		$applyScript = Join-Path $debDir 'apply-debian-delta.sh'
		if (Test-Path -LiteralPath $applyScript) {
			if ($wasRunning) {
				Write-Log '[Update] Applying Debian delta while cluster is running...' -Console:$consoleSwitch
				try {
					# Direct invocation; module now provides Invoke-CommandInMasterVM
					Invoke-CommandInMasterVM -ScriptPath $applyScript -WorkingDirectory $debDir -ShowLogs:$ShowLogs
					Write-Log '[Update] Debian delta applied successfully.' -Console:$consoleSwitch
				} catch { 
					Write-Log ("[Update][Error] Debian delta execution failed: {0}" -f $_.Exception.Message) -Console
					throw
				}
			} else {
				Write-Log '[Update][Warn] Cluster not running - cannot apply Debian delta. Will skip Debian updates.' -Console:$consoleSwitch
			}
		} else {
			Write-Log '[Update][Info] No Debian delta apply script found; skipping' -Console:$consoleSwitch
		}
	} else { Write-Log '[Update] No Debian delta in manifest' -Console:$consoleSwitch }

	# 4b. Apply Linux guest-config host tools (helm/yq) to the kubemaster VM.
	# These binaries live in /usr/local/bin on the control plane and are NOT dpkg packages, so the Debian
	# delta above does not touch them. Delta creation captures their changed/added versions via the
	# GuestConfig diff and bundles them under 'guest-config/' inside the package, so this is fully
	# air-gapped (no internet at apply). Applied here while the control plane VM is confirmed running
	# (before StopCluster). Allowlisted to /usr/local/bin and warn-only - a transient failure must not
	# fail an otherwise-successful upgrade.
	_phase 'GuestConfigApply'
	if ($wasRunning) {
		if ($manifest.GuestConfigRelativePath) {
			try {
				$guestApply = Invoke-GuestConfigDeltaApply -DeltaRoot $deltaRoot -Manifest $manifest -ShowLogs:$ShowLogs
				if (-not $guestApply.Success) {
					Write-Log '[Update][Warn] Guest-config apply reported issues; Linux helm/yq may be stale until re-applied.' -Console:$consoleSwitch
				}
			} catch {
				Write-Log ("[Update][Warn] Guest-config apply encountered an error: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
			}
		} else {
			Write-Log '[Update] No guest-config payload in manifest; skipping Linux host tool update.' -Console:$consoleSwitch
		}
	} else {
		Write-Log '[Update] Skipping guest-config apply (cluster not running)' -Console:$consoleSwitch
	}

	# 5. Stop cluster if it was running
	_phase 'StopCluster'
	if ($wasRunning) {
		Write-Log '[Update] Stopping K2s cluster to apply Windows artifacts...' -Console
		try {
			if (Get-Command -Name Stop-ClusterNode -ErrorAction SilentlyContinue) {
				Stop-ClusterNode -SetupName $setupInfo.Name -ShowLogs:$ShowLogs
				Write-Log '[Update] K2s cluster stopped successfully.' -Console:$consoleSwitch
			} else {
				Write-Log '[Update][Warn] Stop-ClusterNode not available; attempting k2s.exe stop from target folder...' -Console:$consoleSwitch
				$k2sExe = Join-Path $targetInstallPath 'k2s.exe'
				if (Test-Path -LiteralPath $k2sExe) {
					& $k2sExe stop
					if ($LASTEXITCODE -ne 0) { throw "k2s.exe stop returned exit code $LASTEXITCODE" }
					Write-Log '[Update] K2s cluster stopped successfully.' -Console:$consoleSwitch
				} else {
					throw "k2s.exe not found at $k2sExe"
				}
			}
		} catch {
			Write-Log ("[Update][Error] Failed to stop K2s cluster: {0}" -f $_.Exception.Message) -Console
			throw
		}
	} else {
		Write-Log '[Update] Cluster was not running; skipping stop phase.' -Console:$consoleSwitch
	}

	# 6. Apply Windows artifacts (Added + Changed) from delta root to target install path
	_phase 'WindowsArtifacts'
	Write-Log ("[Update] Applying artifacts from delta root '{0}' to target '{1}'" -f $deltaRoot, $targetInstallPath) -Console:$consoleSwitch

	# Wrap the mutating phases so a failure after re-homing can roll the Windows-side
	# installation back to the previous folder (see catch block before UpdateVersion).
	try {

	if ($relocate) {
		# --- Relocation branch: the new installation folder is the delta package directory. ---
		# It already contains the delta's Added/Changed/wholesale files; it must additionally be
		# seeded with the unchanged files from the previous installation and then become the
		# active installation (re-home).
		Write-Log ("[Update][Relocate] New installation folder will be: {0}" -f $newInstallPath) -Console:$consoleSwitch
		Write-Log ("[Update][Relocate] Previous installation retained for rollback: {0}" -f $oldInstallPath) -Console:$consoleSwitch

		# Defensively ensure K2s-managed Windows services are stopped so file handles are released
		# before seeding/re-homing. Phase 2 (Stop) already issued 'k2s stop'; this per-service stop is
		# idempotent (skips services already Stopped) and guards against any service still holding the
		# old folder before the cluster is cleanly restarted from the new folder.
		foreach ($svcName in (Get-K2sManagedServiceName)) {
			$svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
			if ($svc -and $svc.Status -ne 'Stopped') {
				try {
					Stop-Service -Name $svcName -Force -ErrorAction Stop
					Write-Log ("[Update][Relocate] Stopped service '{0}'" -f $svcName) -Console:$consoleSwitch
				} catch {
					Write-Log ("[Update][Relocate][Warn] Could not stop service '{0}': {1}" -f $svcName, $_.Exception.Message) -Console:$consoleSwitch
				}
			}
		}
		# Kill only the K2s-owned containerd / shim processes (those whose executable lives under the
		# previous installation folder) so file handles on the old folder are released. Killing by name
		# alone would also terminate unrelated containerd instances (e.g. Docker/Rancher Desktop).
		foreach ($procName in @('containerd-shim-runhcs-v1', 'containerd')) {
			Get-Process -Name $procName -ErrorAction SilentlyContinue | Where-Object {
				$_.Path -and $_.Path.StartsWith($oldInstallPath, [System.StringComparison]::OrdinalIgnoreCase)
			} | ForEach-Object {
				try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch { }
			}
		}
		Start-Sleep -Seconds 2
		# From this point the previous installation's services are down. If seeding or the re-home
		# fails before $relocationDone is set, the catch block must restart the previous installation.
		$relocateServicesStopped = $true

		# Seed unchanged files from the previous installation into the new folder.
		$wholesaleDirs = @($manifest.WholeDirectories) | Where-Object { $_ -and ($_ -ne '') }
		if (-not (Copy-UnchangedInstallationFiles -OldInstallPath $oldInstallPath -NewInstallPath $newInstallPath -WholesaleDirs $wholesaleDirs -ShowLogs:$ShowLogs)) {
			throw 'Failed to seed new installation folder from previous installation'
		}

		# Remove obsolete files (manifest.Removed) that may have been seeded from the previous installation.
		# Filter out false positives under bin/ and wholesale directories so essential binaries
		# (nssm.exe, ctr.exe, ...) that the new package owns wholesale are never deleted.
		$removedFiles = Select-PrunableRemovedFile -RemovedFiles @($manifest.Removed) -WholesaleDirs $wholesaleDirs
		foreach ($rel in $removedFiles) {
			$obsolete = Join-Path $newInstallPath ($rel -replace '/', '\')
			if (Test-Path -LiteralPath $obsolete) {
				try {
					Remove-Item -LiteralPath $obsolete -Force -ErrorAction Stop
					Write-Log ("[Update][Relocate] Removed obsolete file: {0}" -f $rel) -Console:$consoleSwitch
				} catch {
					Write-Log ("[Update][Relocate][Warn] Failed to remove '{0}': {1}" -f $rel, $_.Exception.Message) -Console:$consoleSwitch
				}
			}
		}

		# Re-home: re-point services, fix StartKubelet.ps1, regenerate containerd config.toml,
		# copy the kubeconfig and update setup.json InstallFolder to the new folder.
		if (-not (Set-K2sInstallationHome -FromPath $oldInstallPath -ToPath $newInstallPath -ShowLogs:$ShowLogs)) {
			throw 'Failed to re-home installation to the new folder'
		}
		$relocationDone = $true

		# All subsequent phases operate on the new installation folder.
		$targetInstallPath = $newInstallPath
		Write-Log ("[Update][Relocate] Active installation folder is now: {0}" -f $targetInstallPath) -Console:$consoleSwitch
	} else {

	# 6a. Apply wholesale directories first - these are replaced entirely (e.g., bin/kube, bin/docker)
	# Wholesale directories contain binaries that must be completely replaced, not merged
	$wholesaleDirs = @($manifest.WholeDirectories) | Where-Object { $_ -and ($_ -ne '') }
	if ($wholesaleDirs.Count -gt 0) {
		# Stop Windows services whose executables reside inside wholesale directories.
		# Even when the cluster is not running (flanneld/kubelet/kubeproxy are down),
		# containerd or other services may still be active and lock their binaries,
		# causing sporadic "Access is denied" / "being used by another process" errors.
		$servicesToDirMap = @{
			'containerd' = 'bin/containerd'
			'docker'     = 'bin/docker'
		}
		$stoppedServices = @()
		foreach ($svcName in $servicesToDirMap.Keys) {
			$svcDir = $servicesToDirMap[$svcName] -replace '/', '\'
			$matchesWholesale = $wholesaleDirs | Where-Object { ($_ -replace '/', '\') -ieq $svcDir }
			if (-not $matchesWholesale) { continue }

			$svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
			if ($svc -and $svc.Status -ne 'Stopped') {
				Write-Log ("[Update] Stopping service '{0}' (status: {1}) to unlock files in wholesale directory '{2}'" -f $svcName, $svc.Status, $svcDir) -Console:$consoleSwitch
				try {
					Stop-Service -Name $svcName -Force -ErrorAction Stop
					# Wait briefly for the process to fully release file handles
					Start-Sleep -Seconds 2
					$stoppedServices += $svcName
					Write-Log ("[Update] Service '{0}' stopped successfully" -f $svcName) -Console:$consoleSwitch
				} catch {
					Write-Log ("[Update][Warn] Could not stop service '{0}': {1}" -f $svcName, $_.Exception.Message) -Console:$consoleSwitch
				}
			}
		}
		# Also stop any leftover containerd-shim processes that may hold handles
		Stop-Process -Name 'containerd-shim-runhcs-v1' -Force -ErrorAction SilentlyContinue
		Stop-Process -Name 'containerd' -Force -ErrorAction SilentlyContinue

		Write-Log ("[Update] Applying {0} wholesale directories" -f $wholesaleDirs.Count) -Console:$consoleSwitch
		foreach ($wd in $wholesaleDirs) {
			$srcDir = Join-Path $deltaRoot $wd
			if (-not (Test-Path -LiteralPath $srcDir)) {
				Write-Log ("[Update][Warn] Wholesale directory not found in delta: {0}" -f $wd) -Console:$consoleSwitch
				continue
			}
			$dstDir = Join-Path $targetInstallPath $wd
			
			# Remove existing directory completely for clean replacement.
			# Retry with back-off in case file handles are still being released.
			if (Test-Path -LiteralPath $dstDir) {
				Write-Log ("[Update] Removing existing directory for replacement: {0}" -f $wd) -Console:$consoleSwitch
				$maxRetries = 5
				$retryDelay = 2
				$removed = $false
				for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
					try {
						Remove-Item -LiteralPath $dstDir -Recurse -Force -ErrorAction Stop
						$removed = $true
						break
					} catch {
						if ($attempt -lt $maxRetries) {
							Write-Log ("[Update][Warn] Attempt {0}/{1} to remove '{2}' failed: {3} - retrying in {4}s" -f $attempt, $maxRetries, $wd, $_.Exception.Message, $retryDelay) -Console:$consoleSwitch
							Start-Sleep -Seconds $retryDelay
							$retryDelay = [Math]::Min($retryDelay * 2, 10)
						} else {
							Write-Log ("[Update][Error] Failed to remove directory '{0}' after {1} attempts: {2}" -f $wd, $maxRetries, $_.Exception.Message) -Console
						}
					}
				}
				if (-not $removed) {
					Write-Log ("[Update][Warn] Continuing despite failure to fully remove '{0}' - copy will attempt force-overwrite" -f $wd) -Console:$consoleSwitch
				}
			}
			
			# Create parent directory if needed and copy wholesale directory
			$dstParent = Split-Path $dstDir -Parent
			if (-not (Test-Path -LiteralPath $dstParent)) {
				New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
			}
			
			try {
				# Copy the entire directory (not contents) since we removed the target
				Copy-Item -LiteralPath $srcDir -Destination $dstDir -Recurse -Force
				Write-Log ("[Update] Replaced wholesale directory: {0}" -f $wd) -Console:$consoleSwitch
			} catch {
				Write-Log ("[Update][Error] Failed to copy wholesale directory '{0}': {1}" -f $wd, $_.Exception.Message) -Console
			}
		}
	} else {
		Write-Log '[Update] No wholesale directories to apply' -Console:$consoleSwitch
	}
	
	# 6b. Apply individual file changes (Added + Changed)
	# Safety check: Define cluster-specific files that must NEVER be overwritten during updates.
	# These files are generated during kubeadm init and contain cluster-specific certificates and configuration.
	# Overwriting them would break the running cluster.
	$clusterConfigProtectedFiles = @(
		'config'  # Main kubeconfig at $kubePath\config
	)
	$clusterConfigProtectedPaths = @(
		'etc/kubernetes/bootstrap-kubelet.conf',
		'etc/kubernetes/pki/*',
		'var/lib/kubelet/config.yaml',
		'var/lib/kubelet/pki/*'
	)
	
	# Helper function to check if a path should be protected
	function Test-ProtectedClusterFile {
		param([string]$RelPath)
		$normalizedPath = $RelPath -replace '\\', '/'
		$leaf = [IO.Path]::GetFileName($normalizedPath)
		
		# Check exact filename matches
		foreach ($f in $clusterConfigProtectedFiles) {
			if ($leaf -ieq $f) { return $true }
		}
		
		# Check path patterns
		foreach ($pattern in $clusterConfigProtectedPaths) {
			$normalizedPattern = $pattern -replace '\\', '/'
			if ($normalizedPath -like $normalizedPattern) { return $true }
		}
		return $false
	}
	
	$addedFiles   = @($manifest.Added)
	$changedFiles = @($manifest.Changed)
	$filesToApply = @($addedFiles + $changedFiles) | Where-Object { $_ -and ($_ -ne '') }
	$appliedCount = 0
	$skippedCount = 0
	
	foreach ($rel in $filesToApply) {
		# Safety check: Never overwrite cluster-specific configuration files
		if (Test-ProtectedClusterFile -RelPath $rel) {
			Write-Log ("[Update][Skip] Protected cluster config file skipped: {0}" -f $rel) -Console:$consoleSwitch
			$skippedCount++
			continue
		}
		
		$src = Join-Path $deltaRoot $rel
		if (-not (Test-Path -LiteralPath $src)) { Write-Log ("[Update][Warn] Source missing in delta: {0}" -f $rel) -Console:$consoleSwitch; continue }
		$dest = Join-Path $targetInstallPath $rel
		$destDir = Split-Path $dest -Parent
		if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
		
		try { 
			Copy-Item -LiteralPath $src -Destination $dest -Force 
			Write-Log ("[Update] Applied: {0}" -f $rel) -Console:$consoleSwitch
			$appliedCount++
		} catch { 
			Write-Log ("[Update][Error] Copy failed '{0}' -> '{1}': {2}" -f $src, $dest, $_.Exception.Message) -Console 
		}
	}
	Write-Log ("[Update] Applied {0} Windows artifacts (skipped {1} protected cluster config files)" -f $appliedCount, $skippedCount) -Console:$consoleSwitch

	# 6b. Regenerate containerd config.toml from updated template if the template changed.
	# The live config.toml is generated at install time from config.toml.template by replacing
	# %BEST-DRIVE%, %INSTALLATION_DIRECTORY%, and %CONTAINERD_TOKEN% placeholders.
	# The template is diffed and staged in the delta package, but the generated config.toml
	# does not exist in packages, so it must be regenerated after the template is updated.
	# Without this, containerd keeps using the old sandbox_image (pause-win) version.
	$containerdTemplatePath = 'cfg/containerd/config.toml.template'
	$templateWasUpdated = $filesToApply | Where-Object { ($_ -replace '\\', '/') -ieq $containerdTemplatePath }
	if ($templateWasUpdated) {
		Write-Log '[Update] Containerd config.toml.template was updated - regenerating config.toml...' -Console:$consoleSwitch
		$containerdTomlPath = Join-Path $targetInstallPath 'cfg\containerd\config.toml'
		try {
			# Import the containerd module from the target installation so that Get-KubePath
			# (resolved via PSScriptRoot) points to the correct install directory and all
			# dependent modules (system, config, path) are loaded from the same tree.
			$containerdModule = Join-Path $targetInstallPath 'lib\modules\windows\node\k2s.node.module\windowsnode\downloader\artifacts\containerd\containerd.module.psm1'
			if (-not (Test-Path -LiteralPath $containerdModule)) {
				throw "Containerd module not found at $containerdModule"
			}
			Import-Module $containerdModule -Force

			# 1. Generate config.toml from template (replaces %BEST-DRIVE%)
			Set-RootPathForImagesInConfig $containerdTomlPath
			# 2. Replace %INSTALLATION_DIRECTORY% with escaped kubePath
			Set-InstallationDirectory $containerdTomlPath
			# 3. Replace %CONTAINERD_TOKEN% with registry auth token
			Set-UserTokenForRegistryInConfig $containerdTomlPath

			if (Test-Path -LiteralPath $containerdTomlPath) {
				Write-Log "[Update] Containerd config.toml regenerated successfully at $containerdTomlPath" -Console:$consoleSwitch
			} else {
				throw "config.toml was not created at $containerdTomlPath after template substitution"
			}
		} catch {
			Write-Log ("[Update][Error] Failed to regenerate containerd config.toml: {0}" -f $_.Exception.Message) -Console
			throw
		}
	} else {
		Write-Log '[Update] Containerd config.toml.template not changed - skipping config.toml regeneration' -Console:$consoleSwitch
	}

	# 6c. Remove obsolete files (Removed) from target installation
	# Filter out false positives under bin/ and wholesale directories so essential binaries owned
	# wholesale by the new package (nssm.exe, ctr.exe, containerd.exe, ...) are never deleted.
	$removedFiles = Select-PrunableRemovedFile -RemovedFiles @($manifest.Removed) -WholesaleDirs $wholesaleDirs
	if ($removedFiles.Count -gt 0) {
		Write-Log ("[Update] Removing {0} obsolete files from target installation" -f $removedFiles.Count) -Console:$consoleSwitch
		$removedCount = 0
		foreach ($rel in $removedFiles) {
			$target = Join-Path $targetInstallPath $rel
			if (Test-Path -LiteralPath $target) {
				try {
					Remove-Item -LiteralPath $target -Force
					Write-Log ("[Update] Removed: {0}" -f $rel) -Console:$consoleSwitch
					$removedCount++
				} catch {
					Write-Log ("[Update][Warn] Failed to remove '{0}': {1}" -f $rel, $_.Exception.Message) -Console:$consoleSwitch
				}
			} else {
				Write-Log ("[Update][Info] Already absent: {0}" -f $rel) -Console:$consoleSwitch
			}
		}
		Write-Log ("[Update] Removed {0} of {1} obsolete files" -f $removedCount, $removedFiles.Count) -Console:$consoleSwitch
	} else {
		Write-Log '[Update] No files to remove' -Console:$consoleSwitch
	}

	} # end in-place artifact application (the relocation branch above seeds + re-homes instead)

	# 6d. Clean deprecated kubelet flags from Windows kubeadm-flags.env
	# The --pod-infra-container-image flag was deprecated in K8s 1.27 and removed in 1.34
	# This matches the Linux fix in apply-debian-delta.sh
	_phase 'CleanKubeletFlags'
	$kubeletFlagsFile = "$($env:SystemDrive)\var\lib\kubelet\kubeadm-flags.env"
	if (Test-Path -LiteralPath $kubeletFlagsFile) {
		Write-Log "[Update] Cleaning deprecated kubelet flags from $kubeletFlagsFile" -Console:$consoleSwitch
		try {
			$content = Get-Content -LiteralPath $kubeletFlagsFile -Raw
			$originalContent = $content
			
			# Remove --pod-infra-container-image flag (deprecated in 1.27, removed in 1.34)
			$content = $content -replace '--pod-infra-container-image=[^\s"]*\s*', ''
			
			# Clean up any double spaces left behind
			$content = $content -replace '\s+', ' '
			$content = $content -replace '"\s+"', '""'
			
			if ($content -ne $originalContent) {
				Set-Content -LiteralPath $kubeletFlagsFile -Value $content.Trim() -NoNewline
				Write-Log "[Update] Removed deprecated --pod-infra-container-image flag" -Console:$consoleSwitch
				Write-Log "[Update] Kubelet flags after cleanup: $($content.Trim())" -Console:$consoleSwitch
			} else {
				Write-Log "[Update] No deprecated kubelet flags to remove" -Console:$consoleSwitch
			}
		} catch {
			Write-Log ("[Update][Warn] Failed to clean kubelet flags: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
		}
	} else {
		Write-Log "[Update] Kubelet flags file not found at $kubeletFlagsFile (may be normal for some setups)" -Console:$consoleSwitch
	}

	# 7. Restart cluster if it was running before
	# NOTE: For a relocating update this restart runs after the re-home completed ($relocationDone),
	# from inside the rollback try-block. A start failure here therefore triggers the full Windows-side
	# home-revert in the catch block even though the file/config changes themselves were applied
	# cleanly. That is intentional: a cluster that cannot start from the new folder is reverted to the
	# previous, known-good installation rather than left half-migrated.
	_phase 'RestartCluster'
	if ($wasRunning) {
		Write-Log '[Update] Restarting K2s cluster...' -Console
		try {
			# IMPORTANT: a relocating update ($relocate=$true) must ALWAYS take the k2s.exe-start
			# else-branch below, because that is the only place $clusterStartedFromNew is set (the
			# rollback path relies on it to decide whether to stop the new-folder cluster). The
			# condition is written so '-not $relocate' short-circuits the '-and' for relocations,
			# guaranteeing the else-branch. Do not refactor this without preserving that guarantee.
			if (-not $relocate -and (Get-Command -Name Start-ClusterNode -ErrorAction SilentlyContinue)) {
				Start-ClusterNode -SetupName $setupInfo.Name -ShowLogs:$ShowLogs
				Write-Log '[Update] K2s cluster restarted successfully.' -Console:$consoleSwitch
			} else {
				if ($relocate) {
					Write-Log '[Update] Starting cluster from the new installation folder...' -Console:$consoleSwitch
				} else {
					Write-Log '[Update][Warn] Start-ClusterNode not available; attempting k2s.exe start from target folder...' -Console:$consoleSwitch
				}
				$k2sExe = Join-Path $targetInstallPath 'k2s.exe'
				if (Test-Path -LiteralPath $k2sExe) {
					& $k2sExe start
					if ($LASTEXITCODE -ne 0) { throw "k2s.exe start returned exit code $LASTEXITCODE" }
					if ($relocate) { $clusterStartedFromNew = $true }
					Write-Log '[Update] K2s cluster restarted successfully.' -Console:$consoleSwitch
				} else {
					throw "k2s.exe not found at $k2sExe"
				}
			}
		} catch {
			Write-Log ("[Update][Error] Failed to restart K2s cluster: {0}" -f $_.Exception.Message) -Console
			Write-Log '[Update][Error] You may need to manually start the cluster: k2s start' -Console
			throw
		}
	} else {
		Write-Log '[Update] Cluster was not running before update; not restarting.' -Console:$consoleSwitch
	}

	# 8. Import container images from delta package.
	#    Delta packaging stages images into image-delta/windows/images/*.tar and image-delta/linux/images/*.tar.
	#    Linux images may already have been imported by Phase 4 (Invoke-CommandInMasterVM → apply-debian-delta.sh
	#    → buildah pull). Phase 8 re-imports them as a safety net and also covers the case where
	#    Phase 4 was skipped because the cluster was not running at the time.
	#    Windows images use ctr to import into the containerd k8s.io namespace — the same pattern used by
	#    Invoke-DeployWindowsImages in downloader.module.psm1 and ImportImage.ps1.
	_phase 'ContainerImages'

	# --- 8a. Windows images ---
	# Collect Windows image tar files: primary path from delta packaging, then fallback
	$windowsImagesDirs = @(
		(Join-Path $deltaRoot 'image-delta\windows\images'),
		(Join-Path $deltaRoot 'images')
	)
	$winImageFiles = @()
	foreach ($winImgDir in $windowsImagesDirs) {
		if ((Test-Path -LiteralPath $winImgDir) -and $winImageFiles.Count -eq 0) {
			$found = Get-ChildItem -LiteralPath $winImgDir -File -Filter '*.tar' -ErrorAction SilentlyContinue
			if ($found -and $found.Count -gt 0) {
				$winImageFiles = @($found)
				Write-Log ("[Update] Found {0} Windows image archives in {1}" -f $winImageFiles.Count, $winImgDir) -Console:$consoleSwitch
			}
		}
	}
	if ($winImageFiles.Count -gt 0) {
		# Resolve ctr from the target installation (containerd must be running after Phase 7 restart)
		$ctrExe = if ($relocate) { Join-Path $targetInstallPath 'bin\containerd\ctr.exe' } else { Join-Path (Get-KubeBinPath) 'containerd\ctr.exe' }
		if (-not (Test-Path -LiteralPath $ctrExe)) {
			Write-Log ("[Update][Warn] ctr.exe not found at {0}; cannot import Windows images" -f $ctrExe) -Console:$consoleSwitch
		} else {
			Write-Log ("[Update] Loading {0} Windows container image archives via ctr" -f $winImageFiles.Count) -Console:$consoleSwitch
			$imageLoadedCount = 0
			foreach ($img in $winImageFiles) {
				Write-Log ("[Update] Loading Windows image: {0}" -f $img.Name) -Console:$consoleSwitch
				$maxRetries = 3
				$retryDelay = 2
				$success = $false
				for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
					try {
						$importSuccess = Invoke-Ctr -Arguments '-n', 'k8s.io', 'images', 'import', $img.FullName -CtrExePath $ctrExe
						if ($importSuccess) {
							$success = $true
							break
						}
						if ($attempt -lt $maxRetries) {
							# Invoke-Ctr logs the underlying ctr error internally; it returns a bool, so do
							# not reference $LASTEXITCODE here (it would reflect an unrelated command).
							Write-Log ("[Update]   Attempt {0} failed, retrying after {1}s..." -f $attempt, $retryDelay) -Console:$consoleSwitch
							Start-Sleep -Seconds $retryDelay
						}
					} catch {
						if ($attempt -lt $maxRetries) {
							Write-Log ("[Update]   Attempt {0} error: {1}, retrying after {2}s..." -f $attempt, $_.Exception.Message, $retryDelay) -Console:$consoleSwitch
							Start-Sleep -Seconds $retryDelay
						}
					}
				}
				if ($success) {
					$imageLoadedCount++
					Write-Log ("[Update] Image loaded successfully: {0}" -f $img.Name) -Console:$consoleSwitch
				} else {
					Write-Log ("[Update][Warn] Failed to load image after {0} attempts: {1}" -f $maxRetries, $img.Name) -Console:$consoleSwitch
				}
			}
			Write-Log ("[Update] Loaded {0} of {1} Windows container images" -f $imageLoadedCount, $winImageFiles.Count) -Console:$consoleSwitch
		}
	} else {
		Write-Log '[Update] No Windows image archives found in delta package; skipping Windows image load' -Console:$consoleSwitch
	}

	# --- 8b. Linux images ---
	# Import Linux images into the control-plane VM via SCP + buildah.
	# Phase 4 (DebianPackages) imports these as part of apply-debian-delta.sh when the cluster was running.
	# This step acts as a safety net and also covers the scenario where the cluster was not running during Phase 4.
	$linuxImagesDir = Join-Path $deltaRoot 'image-delta\linux\images'
	if (Test-Path -LiteralPath $linuxImagesDir) {
		$linuxTarFiles = Get-ChildItem -LiteralPath $linuxImagesDir -File -Filter '*.tar' -ErrorAction SilentlyContinue
		if ($linuxTarFiles -and $linuxTarFiles.Count -gt 0) {
			if ($wasRunning) {
				# Cluster is running (restarted in Phase 7) — VM is reachable via SSH
				if (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue) {
					Write-Log ("[Update] Importing {0} Linux container images into control-plane VM" -f $linuxTarFiles.Count) -Console:$consoleSwitch
					try {
						$remoteImgDir = '/tmp/k2s-delta-images'
						(Invoke-CmdOnControlPlaneViaSSHKey "sudo mkdir -p $remoteImgDir && sudo chown `$(whoami) $remoteImgDir" -Retries 2 -Timeout 2).Output | Out-Null
						Copy-ToControlPlaneViaSSHKey -Source $linuxImagesDir -Target $remoteImgDir -IgnoreErrors:$false
						$linuxLoadedCount = 0
						foreach ($ltar in $linuxTarFiles) {
							$remoteTar = "$remoteImgDir/images/$($ltar.Name)"
							Write-Log ("[Update] Loading Linux image: {0}" -f $ltar.Name) -Console:$consoleSwitch
							$importResult = Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah pull oci-archive:$remoteTar 2>&1" -Retries 2 -Timeout 120
							if ($importResult.Output -notmatch 'error') {
								$linuxLoadedCount++
								Write-Log ("[Update] Linux image loaded successfully: {0}" -f $ltar.Name) -Console:$consoleSwitch
							} else {
								Write-Log ("[Update][Warn] Linux image import may have failed for {0}: {1}" -f $ltar.Name, $importResult.Output) -Console:$consoleSwitch
							}
						}
						# Clean up temporary images directory
						(Invoke-CmdOnControlPlaneViaSSHKey "sudo rm -rf $remoteImgDir" -Retries 1 -Timeout 2 -IgnoreErrors:$true).Output | Out-Null
						Write-Log ("[Update] Loaded {0} of {1} Linux container images" -f $linuxLoadedCount, $linuxTarFiles.Count) -Console:$consoleSwitch
					} catch {
						Write-Log ("[Update][Warn] Failed to import Linux images: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
					}
				} else {
					Write-Log '[Update][Warn] SSH helper not available; cannot import Linux images into VM' -Console:$consoleSwitch
				}
			} else {
				Write-Log ("[Update][Warn] Cluster not running; {0} Linux images in delta package will need to be imported after cluster start" -f $linuxTarFiles.Count) -Console:$consoleSwitch
			}
		}
	} else {
		Write-Log '[Update] No Linux image archives found in delta package; skipping Linux image load' -Console:$consoleSwitch
	}

	# --- 8c. CRI-O offline image retention (issue #3284) ---
	# Disable CRI-O internal repair and install the pre-start storage check so an unclean
	# shutdown does not wipe the image store. Applied only when the control plane is reachable.
	if ($wasRunning) {
		try {
			if (-not (Get-Command -Name Set-CrioOfflineImageRetention -ErrorAction SilentlyContinue)) {
				$commonSetupModule = Join-Path (Get-ClusterInstalledFolder) 'lib\modules\windows\node\k2s.node.module\linuxnode\distros\common-setup.module.psm1'
				if (Test-Path -LiteralPath $commonSetupModule) { Import-Module $commonSetupModule -Force -ErrorAction Stop }
			}
			if ((Get-Command -Name Set-CrioOfflineImageRetention -ErrorAction SilentlyContinue) -and (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
				$crioRemoteCommand = { param([string] $Command) (Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $Command -Timeout 30 -Retries 2).Output | Write-Log }
				Set-CrioOfflineImageRetention -ExecuteRemoteCommand $crioRemoteCommand
				Write-Log '[Update] CRI-O offline image retention configured (active on next CRI-O start)' -Console:$consoleSwitch
				if (Get-Command -Name Export-SystemImageArchivesToWindowsHost -ErrorAction SilentlyContinue) {
					try {
						Export-SystemImageArchivesToWindowsHost -TargetPath (Get-DirectoryOfKubenodeImagesOnWindowsHost)
						Write-Log '[Update] System image archives refreshed' -Console:$consoleSwitch
					} catch {
						Write-Log ("[Update][Warn] Failed to export system image archives: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
					}
				}
			} else {
				Write-Log '[Update][Warn] CRI-O image retention helpers not available; skipping' -Console:$consoleSwitch
			}
		} catch {
			Write-Log ("[Update][Warn] Failed to configure CRI-O image retention: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
		}
	} else {
		Write-Log '[Update][Warn] Cluster not running; CRI-O image retention not applied (re-run update with cluster running)' -Console:$consoleSwitch
	}

	# 9. Hooks placeholder
	_phase 'Hooks'
	if ($ExecuteHooks) { Write-Log '[Update][Info] Hooks execution placeholder (none implemented).' -Console:$consoleSwitch } else { Write-Log '[Update] Hooks disabled.' -Console:$consoleSwitch }

	# 10. Health check
	_phase 'Health'
	try {
		if ($wasRunning) {
			Write-Log '[Update] Performing health check on restarted cluster...' -Console:$consoleSwitch
			if (Get-Command -Name Wait-ForAPIServer -ErrorAction SilentlyContinue) { Wait-ForAPIServer -TimeoutSeconds 60 }
			if (Get-Command -Name Get-NodeReadySummary -ErrorAction SilentlyContinue) { $summary = Get-NodeReadySummary; Write-Log ("[Update] Node readiness: {0}" -f $summary) -Console:$consoleSwitch }
		} else {
			Write-Log '[Update] Skipping health check (cluster not running)' -Console:$consoleSwitch
		}
	} catch { Write-Log ("[Update][Warn] Health check encountered issues: {0}" -f $_.Exception.Message) -Console:$consoleSwitch }

	# 11. Restore CoreDNS configuration (kubeadm upgrade may reset customizations)
	_phase 'CoreDnsRestore'
	if ($wasRunning) {
		# Get control plane IP from setup info
		$controlPlaneIp = $null
		if ($setupInfo -and $setupInfo.ControlPlaneNodeHostname) {
			$controlPlaneIp = (Get-ConfiguredIPControlPlane)
		}
		if (-not $controlPlaneIp) {
			$controlPlaneIp = '172.19.1.100'  # Default K2s control plane IP
		}
		
		$coreDnsResult = Restore-CoreDnsEtcdConfiguration -ControlPlaneIp $controlPlaneIp -ShowLogs:$ShowLogs
		if (-not $coreDnsResult) {
			Write-Log '[Update][Warn] CoreDNS restoration may have encountered issues' -Console:$consoleSwitch
		}
	} else {
		Write-Log '[Update] Skipping CoreDNS restoration (cluster not running)' -Console:$consoleSwitch
	}

	# 12. Restore ClusterIP webhook (kubeadm upgrade may invalidate TLS certs/caBundle)
	_phase 'WebhookRestore'
	if ($wasRunning) {
		$webhookResult = Restore-ClusterIPWebhook -TargetInstallPath $targetInstallPath -ShowLogs:$ShowLogs
		if (-not $webhookResult) {
			throw '[Update] ClusterIP webhook restoration failed - services created after this point may get incorrect ClusterIPs. Aborting upgrade.'
		}
	} else {
		Write-Log '[Update] Skipping webhook restoration (cluster not running)' -Console:$consoleSwitch
	}

	# 12b. Final ClusterIP webhook pod restart (last cluster-side action).
	# kubeadm upgrade restarts kube-apiserver and may leave the webhook pod serving a TLS cert that no
	# longer matches the caBundle trusted by the API server, producing "tls: bad certificate" handshake
	# errors. Because the webhook uses failurePolicy: Ignore, those failures are silent and Services then
	# get random ClusterIPs from the full /16 instead of the enforced /24 subnets. The webhook's init-cert
	# container regenerates the serving cert AND patches the MutatingWebhookConfiguration caBundle on every
	# pod start, so a single restart re-syncs both. Do this as the very last cluster action so the webhook
	# is guaranteed healthy before any test workloads create Services. Warn-only: the upgrade itself has
	# already succeeded at this point, so a transient restart issue must not trigger a rollback.
	_phase 'WebhookFinalRestart'
	if ($wasRunning) {
		try {
			Write-Log '[Update] Restarting ClusterIP webhook pod to re-sync TLS cert/caBundle before workloads start...' -Console:$consoleSwitch
			(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl rollout restart deployment/clusterip-webhook -n k2s-webhook' -Timeout 30 -Retries 2 -IgnoreErrors:$true).Output | Out-Null
			$finalRollout = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'kubectl rollout status deployment/clusterip-webhook -n k2s-webhook --timeout=120s' -Timeout 150 -Retries 2 -IgnoreErrors:$true
			if (-not $finalRollout.Success) {
				Write-Log '[Update][Warn] ClusterIP webhook did not become ready after final restart; service IP assignment may be unreliable until it recovers.' -Console:$consoleSwitch
			} else {
				# Only trust the caBundle value when the retrieval itself succeeded. With -IgnoreErrors the
				# command never throws, so a failed 'kubectl get' would otherwise place its error text in
				# .Output (a non-empty string) and be misread as a populated caBundle / false success.
				$caBundleResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "kubectl get mutatingwebhookconfiguration k2s-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}'" -Timeout 30 -IgnoreErrors:$true
				$finalCaBundle = ($caBundleResult.Output | Out-String).Trim()
				if (-not $caBundleResult.Success) {
					Write-Log '[Update][Warn] Could not read ClusterIP webhook caBundle after final restart; service IP assignment reliability is unverified.' -Console:$consoleSwitch
				} elseif ([string]::IsNullOrWhiteSpace($finalCaBundle)) {
					Write-Log '[Update][Warn] ClusterIP webhook caBundle is empty after final restart; service IP assignment may be unreliable.' -Console:$consoleSwitch
				} else {
					Write-Log '[Update] ClusterIP webhook restarted and caBundle re-synced successfully.' -Console:$consoleSwitch
				}
			}
		} catch {
			Write-Log ("[Update][Warn] Final ClusterIP webhook restart encountered an issue: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
		}
	} else {
		Write-Log '[Update] Skipping final webhook restart (cluster not running)' -Console:$consoleSwitch
	}

	} catch {
		Write-Log ("[Update][Error] Delta update failed: {0}" -f $_.Exception.Message) -Console
		if ($relocate -and $relocationDone) {
			Write-Log '[Update][Rollback] Reverting installation home to the previous folder...' -Console
			try {
				# The cluster may still be running from the new folder (phase 7 restarted it there).
				# Only stop it when phase 7 actually confirmed a start from the new folder; if the start
				# itself failed there is nothing to stop and issuing 'k2s stop' just adds latency.
				if ($wasRunning -and $clusterStartedFromNew) {
					$newK2sExe = Join-Path $newInstallPath 'k2s.exe'
					if (Test-Path -LiteralPath $newK2sExe) {
						& $newK2sExe stop 2>&1 | Out-Null
						if ($LASTEXITCODE -ne 0) {
							# A failed/partial stop is non-fatal here: Set-K2sInstallationHome re-points the
							# nssm registry parameters, which does not require the services to be stopped. The
							# old folder is restored regardless; any service still running from the new folder
							# is corrected on the next start/stop cycle.
							Write-Log ("[Update][Rollback][Warn] k2s stop (new folder) returned exit code {0}" -f $LASTEXITCODE) -Console
						}
					}
				}
				$rollbackOk = Set-K2sInstallationHome -FromPath $newInstallPath -ToPath $oldInstallPath -ShowLogs:$ShowLogs
				if (-not $rollbackOk) {
					Write-Log '[Update][Rollback][Error] Set-K2sInstallationHome returned false; installation state may be inconsistent (services/setup.json may still point at the new folder). Manual recovery may be required.' -Console
				}
				if ($wasRunning) {
					$oldK2sExe = Join-Path $oldInstallPath 'k2s.exe'
					if (Test-Path -LiteralPath $oldK2sExe) {
						& $oldK2sExe start 2>&1 | Out-Null
						if ($LASTEXITCODE -ne 0) {
							Write-Log ("[Update][Rollback][Warn] k2s start (previous folder) returned exit code {0}; manual recovery may be required." -f $LASTEXITCODE) -Console
						}
					}
				}
				Write-Log '[Update][Rollback] Windows-side installation reverted to the previous folder.' -Console
				Write-Log '[Update][Rollback][Warn] Cluster/Linux-side changes (kubeadm upgrade, Debian packages) are NOT reverted, consistent with full upgrade behavior.' -Console
			} catch {
				Write-Log ("[Update][Rollback][Error] Rollback failed: {0}. Manual recovery may be required." -f $_.Exception.Message) -Console
			}
		}
		elseif ($relocate -and $relocateServicesStopped) {
			# The failure happened after the relocation branch stopped the previous installation's
			# services but before the re-home was confirmed complete ($relocationDone = $false). The
			# forward re-home may have been PARTIALLY applied (e.g. nssm services already re-pointed to
			# the new folder before a later step threw). Revert by re-homing back to the previous folder.
			#
			# This revert targets $ToPath = $oldInstallPath, which is the REAL previous installation and
			# therefore always contains the services + containerd + path modules. So Set-K2sInstallationHome
			# runs all of steps 1-6 to completion here (it does not early-return on a missing-module guard,
			# unlike the forward direction into a possibly-incomplete delta folder). Re-pointing is also
			# idempotent: services whose nssm value does not contain the source path are skipped, so this is
			# a harmless no-op when seeding failed before any re-home was applied. A $false return here
			# therefore signals a GENUINE problem (e.g. nssm/setup.json write failed) worth manual attention.
			Write-Log '[Update][Recovery] Reverting any partially-applied re-home to the previous folder...' -Console
			try {
				$revertOk = Set-K2sInstallationHome -FromPath $newInstallPath -ToPath $oldInstallPath -ShowLogs:$ShowLogs
				if (-not $revertOk) {
					Write-Log '[Update][Recovery][Error] Set-K2sInstallationHome returned false; installation state may be inconsistent (services/setup.json may still point at the new folder). Manual recovery may be required.' -Console
				}
				if ($wasRunning) {
					$oldK2sExe = Join-Path $oldInstallPath 'k2s.exe'
					if (Test-Path -LiteralPath $oldK2sExe) {
						& $oldK2sExe start 2>&1 | Out-Null
						if ($LASTEXITCODE -ne 0) {
							Write-Log ("[Update][Recovery][Warn] k2s start (previous folder) returned exit code {0}; manual recovery may be required." -f $LASTEXITCODE) -Console
						}
					}
					Write-Log '[Update][Recovery] Previous installation restarted.' -Console
				} else {
					Write-Log '[Update][Recovery] Cluster was not running before the update; leaving services stopped.' -Console
				}
			} catch {
				Write-Log ("[Update][Recovery][Error] Failed to recover the previous installation: {0}. Manual recovery may be required." -f $_.Exception.Message) -Console
			}
		}
		throw
	}

	# 13. Update VERSION file to reflect successful delta update
	_phase 'UpdateVersion'
	if ($deltaTargetVersion) {
		try {
			# Update VERSION file in the target installation
			$versionFile = Join-Path $targetInstallPath 'VERSION'
			
			if (Test-Path -LiteralPath $versionFile) {
				Write-Log ("[Update] Updating VERSION file from {0} to {1}" -f $currentVersion, $deltaTargetVersion) -Console:$consoleSwitch
				$deltaTargetVersion | Out-File -FilePath $versionFile -Encoding ASCII -Force -NoNewline
				Write-Log ("[Update] VERSION file updated successfully: {0}" -f $versionFile) -Console:$consoleSwitch
			} else {
				Write-Log ("[Update][Warn] VERSION file not found at expected location: {0}" -f $versionFile) -Console:$consoleSwitch
			}
			
			# Update setup.json configuration to reflect the new version
			Write-Log ("[Update] Updating setup.json product version from {0} to {1}" -f $currentVersion, $deltaTargetVersion) -Console:$consoleSwitch
			Set-UpdateSetupConfigValue -SetupConfigPath $setupConfigPath -Key 'Version' -Value $deltaTargetVersion
			Write-Log '[Update] Setup configuration updated successfully' -Console:$consoleSwitch
		} catch {
			Write-Log ("[Update][Warn] Failed to update version information: {0}" -f $_.Exception.Message) -Console:$consoleSwitch
		}
	} else {
		Write-Log '[Update][Info] Target version not determined; version information not updated' -Console:$consoleSwitch
	}

	# 13b. Verify and persist the target Kubernetes version declared by the target package.
	# Older delta packages do not have TargetKubernetesVersion in their manifest; retain the
	# expected-k8s-version marker as a compatibility fallback.
	try {
		$newK8sVersion = Get-DeltaTargetKubernetesVersion -Manifest $manifest -DeltaRoot $deltaRoot
		if ($newK8sVersion) {
			Confirm-DeltaKubernetesVersion -ExpectedVersion $newK8sVersion -InstallPath $targetInstallPath
			$currentK8sVersion = Get-ConfigValue -Path $setupConfigPath -Key 'KubernetesVersion'
			Write-Log ("[Update] Updating setup.json KubernetesVersion from {0} to {1}" -f $currentK8sVersion, $newK8sVersion) -Console:$consoleSwitch
			Set-UpdateSetupConfigValue -SetupConfigPath $setupConfigPath -Key 'KubernetesVersion' -Value $newK8sVersion
		} else {
			Write-Log '[Update][Info] Target Kubernetes version not declared by delta; setup.json KubernetesVersion unchanged' -Console:$consoleSwitch
		}
	} catch {
		Write-Log ("[Update][Error] Failed to verify or update setup.json KubernetesVersion: {0}" -f $_.Exception.Message) -Console
		throw
	}

	Confirm-UpdateInstallationHome -SetupConfigPath $setupConfigPath -ExpectedInstallPath $targetInstallPath

	# Clean delta-package-only artifacts so the new installation folder is a clean installation
	# and is not misdetected as a delta package on a subsequent upgrade.
	if ($relocate) {
		Remove-DeltaPackageArtifact -InstallPath $targetInstallPath -ShowLogs:$ShowLogs
	}

	Write-Log '[Update] Delta update complete.' -Console:$consoleSwitch
	Write-Log ("Upgraded successfully to K2s version: {0} (delta update)" -f $deltaTargetVersion) -Console:$consoleSwitch
	if ($relocate) {
		Write-Log ("[Update] Active installation folder is now: {0}" -f $targetInstallPath) -Console:$consoleSwitch
		Write-Log ("[Update] Previous installation retained for rollback: {0}" -f $oldInstallPath) -Console:$consoleSwitch
		Write-Log '[Update] You may delete the previous installation folder after verifying the update.' -Console:$consoleSwitch
	} else {
		Write-Log ("[Update] Delta artifacts remain in: {0}" -f $deltaRoot) -Console:$consoleSwitch
		Write-Log '[Update] You may safely delete the extracted delta package directory after verifying the update.' -Console:$consoleSwitch
	}

	if ($ShowProgress) { Write-Progress -Activity 'Cluster delta update' -Id 1 -Completed }
	
	return $true
}

Export-ModuleMember -Function PerformClusterUpdate
Export-ModuleMember -Function Restore-CoreDnsEtcdConfiguration
Export-ModuleMember -Function Restore-ClusterIPWebhook
Export-ModuleMember -Function Copy-UnchangedInstallationFiles
Export-ModuleMember -Function Set-K2sInstallationHome
Export-ModuleMember -Function Remove-DeltaPackageArtifact
Export-ModuleMember -Function Get-K2sManagedServiceName
Export-ModuleMember -Function Select-PrunableRemovedFile

# region: guest-config (Linux control plane host tools) delta application
<#
.SYNOPSIS
	Returns the allowlist of guest (Linux control plane) absolute path prefixes that a delta update is
	permitted to re-apply to the kubemaster VM.
.DESCRIPTION
	Delta creation captures changed/added control plane host files via the GuestConfig diff (see
	New-K2sDelta.GuestConfig.ps1) and bundles them under the package's 'guest-config/' folder so the
	update is fully air-gapped. Only host TOOL binaries are re-applied during a delta update - currently
	the Linux helm, yq and kubectl-krew executables under /usr/local/bin. Cluster-identity files (PKI, kubeconfigs,
	static pod manifests, kubelet config) are intentionally NOT applied even though delta creation already
	excludes them from the payload - this allowlist is a second, independent safety boundary.
.OUTPUTS
	[string[]] Absolute path prefixes (each ending with '/').
#>
function Get-GuestConfigApplyAllowlist {
	return @('/usr/local/bin/')
}

<#
.SYNOPSIS
	Tests whether a guest-config payload entry is permitted to be applied to the control plane VM.
.DESCRIPTION
	Accepts either a staging-relative path (e.g. 'usr/local/bin/helm', forward or back slashes) or an
	absolute guest path (e.g. '/usr/local/bin/helm') and returns $true only when the corresponding
	absolute path falls under one of the Get-GuestConfigApplyAllowlist prefixes.
.PARAMETER Path
	The relative or absolute path to test.
.OUTPUTS
	[bool]
#>
function Test-GuestConfigApplyAllowed {
	param([string] $Path)
	if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
	# Normalize to an absolute, forward-slash guest path.
	$abs = '/' + (($Path -replace '\\', '/').TrimStart('/'))
	foreach ($prefix in (Get-GuestConfigApplyAllowlist)) {
		if ($abs.StartsWith($prefix, [System.StringComparison]::Ordinal)) { return $true }
	}
	return $false
}

<#
.SYNOPSIS
	Applies the air-gapped guest-config payload (Linux host tools, e.g. helm/yq) from a delta package to
	the running kubemaster VM.
.DESCRIPTION
	The delta package bundles changed/added control plane host files under 'guest-config/<absolute-path>'
	(no leading slash), recorded in the manifest as GuestConfigRelativePath plus GuestConfigDiff.CopiedFiles.
	This function copies each ALLOWLISTED file (see Test-GuestConfigApplyAllowed - only /usr/local/bin/* by
	default) onto the control plane VM via the existing SSH helpers and installs it in place (root-owned,
	0755). No internet access is used - the binaries already ride inside the delta package, satisfying the
	air-gapped requirement. The function is warn-only: failures are logged but never thrown, so a transient
	issue applying helm/yq does not fail an otherwise-successful upgrade.
.PARAMETER DeltaRoot
	Absolute path to the extracted delta package root (the directory containing delta-manifest.json).
.PARAMETER Manifest
	The parsed delta manifest object (must expose GuestConfigRelativePath and, optionally,
	GuestConfigDiff.CopiedFiles).
.PARAMETER ShowLogs
	Mirror logs to console.
.OUTPUTS
	PSCustomObject { Applied[]; Skipped[]; Failed[]; Success }
#>
function Invoke-GuestConfigDeltaApply {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string] $DeltaRoot,
		[Parameter(Mandatory = $true)] $Manifest,
		[switch] $ShowLogs
	)
	$consoleSwitch = $ShowLogs
	$result = [pscustomobject]@{ Applied = @(); Skipped = @(); Failed = @(); Success = $true }

	$relRoot = $Manifest.GuestConfigRelativePath
	if ([string]::IsNullOrWhiteSpace($relRoot)) {
		Write-Log '[GuestConfigApply] No guest-config payload in manifest; nothing to apply.' -Console:$consoleSwitch
		return $result
	}
	$guestConfigDir = Join-Path $DeltaRoot $relRoot
	if (-not (Test-Path -LiteralPath $guestConfigDir)) {
		Write-Log ("[GuestConfigApply][Warn] guest-config directory not found: {0}" -f $guestConfigDir) -Console:$consoleSwitch
		return $result
	}

	# Determine candidate files: prefer the manifest's CopiedFiles list; otherwise enumerate the payload.
	$candidates = @()
	if ($Manifest.GuestConfigDiff -and $Manifest.GuestConfigDiff.CopiedFiles) {
		$candidates = @($Manifest.GuestConfigDiff.CopiedFiles)
	} else {
		$candidates = Get-ChildItem -LiteralPath $guestConfigDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
			($_.FullName.Substring($guestConfigDir.Length).TrimStart('\', '/')) -replace '\\', '/'
		}
	}
	$candidates = @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

	# Apply allowlist filtering (defense in depth - only host tools under /usr/local/bin are applied).
	$allowed = @($candidates | Where-Object { Test-GuestConfigApplyAllowed $_ })
	foreach ($blocked in @($candidates | Where-Object { -not (Test-GuestConfigApplyAllowed $_) })) {
		$result.Skipped += $blocked
		Write-Log ("[GuestConfigApply] Skipping non-allowlisted guest file: {0}" -f $blocked) -Console:$consoleSwitch
	}
	if ($allowed.Count -eq 0) {
		Write-Log '[GuestConfigApply] No allowlisted guest-config files to apply (only /usr/local/bin/* is applied).' -Console:$consoleSwitch
		return $result
	}

	# Import vm module + verify control plane reachability (mirror Invoke-CommandInMasterVM).
	$vmModule = Get-UpdateVmModulePath
	if (Test-Path -LiteralPath $vmModule) { Import-Module $vmModule -Force -ErrorAction SilentlyContinue }
	if (-not (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue) -or
		-not (Get-Command -Name Copy-ToControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
		Write-Log '[GuestConfigApply][Warn] SSH helpers not available; skipping guest-config apply.' -Console:$consoleSwitch
		$result.Success = $false
		return $result
	}
	$cpRunning = $false
	if (Get-Command -Name Get-IsControlPlaneRunning -ErrorAction SilentlyContinue) {
		try { $cpRunning = Get-IsControlPlaneRunning } catch { $cpRunning = $false }
	}
	if (-not $cpRunning) {
		Write-Log '[GuestConfigApply][Warn] Control plane VM not running; cannot apply guest-config (helm/yq/krew).' -Console:$consoleSwitch
		$result.Success = $false
		return $result
	}

	$remoteBase = '/tmp/k2s-guest-config'
	(Invoke-CmdOnControlPlaneViaSSHKey "sudo rm -rf $remoteBase && mkdir -p $remoteBase && sudo chown `$(whoami) $remoteBase" -Timeout 5 -IgnoreErrors:$true).Output | Out-Null

	foreach ($rel in $allowed) {
		$relForward = (($rel -replace '\\', '/').TrimStart('/'))
		$localPath = Join-Path $guestConfigDir ($relForward -replace '/', '\')
		if (-not (Test-Path -LiteralPath $localPath)) {
			# Resilience: tolerate packages whose payload is nested differently (e.g. an older
			# double-nested 'guest-config/guest-config/...' layout). Search the payload tree for a
			# file whose path ends with this candidate's relative path.
			$leafRel = ($relForward -replace '/', '\')
			$found = Get-ChildItem -LiteralPath $guestConfigDir -Recurse -File -ErrorAction SilentlyContinue |
				Where-Object { $_.FullName.EndsWith('\' + $leafRel, [System.StringComparison]::OrdinalIgnoreCase) } |
				Select-Object -First 1
			if ($found) {
				$localPath = $found.FullName
				Write-Log ("[GuestConfigApply] Resolved staged file via recursive search: {0}" -f $localPath) -Console:$consoleSwitch
			} else {
				Write-Log ("[GuestConfigApply][Warn] Staged file missing, cannot apply: {0}" -f $relForward) -Console:$consoleSwitch
				$result.Failed += $relForward
				$result.Success = $false
				continue
			}
		}
		$remoteAbs = '/' + $relForward
		$remoteDir = ($remoteAbs -replace '/[^/]+$', '')
		$remoteTmp = "$remoteBase/" + (Split-Path -Leaf $relForward)
		try {
			Copy-ToControlPlaneViaSSHKey -Source $localPath -Target $remoteTmp -IgnoreErrors:$false
			# Install in place: ensure parent dir, root-owned, 0755 (executable). 'install' is atomic.
			$installCmd = "sudo mkdir -p '$remoteDir' && sudo install -m 0755 -o root -g root '$remoteTmp' '$remoteAbs'"
			(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $installCmd -Timeout 10 -IgnoreErrors:$true).Output | Out-Null
			$verify = (Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "test -x '$remoteAbs' && echo OK || echo MISSING" -Timeout 5 -IgnoreErrors:$true).Output | Out-String
			if ($verify -match 'OK') {
				$result.Applied += $remoteAbs
				Write-Log ("[GuestConfigApply] Applied {0}" -f $remoteAbs) -Console:$consoleSwitch
			} else {
				$result.Failed += $remoteAbs
				$result.Success = $false
				Write-Log ("[GuestConfigApply][Warn] Verification failed for {0}" -f $remoteAbs) -Console:$consoleSwitch
			}
		} catch {
			$result.Failed += $remoteAbs
			$result.Success = $false
			Write-Log ("[GuestConfigApply][Warn] Failed to apply {0}: {1}" -f $remoteAbs, $_.Exception.Message) -Console:$consoleSwitch
		}
	}

	# Cleanup staging.
	(Invoke-CmdOnControlPlaneViaSSHKey "sudo rm -rf $remoteBase" -Timeout 5 -IgnoreErrors:$true).Output | Out-Null

	Write-Log ("[GuestConfigApply] Done. Applied={0} Skipped={1} Failed={2}" -f $result.Applied.Count, $result.Skipped.Count, $result.Failed.Count) -Console:$consoleSwitch
	return $result
}

Export-ModuleMember -Function Get-GuestConfigApplyAllowlist -ErrorAction SilentlyContinue
Export-ModuleMember -Function Test-GuestConfigApplyAllowed -ErrorAction SilentlyContinue
Export-ModuleMember -Function Invoke-GuestConfigDeltaApply -ErrorAction SilentlyContinue

# region: VM execution helper (Debian delta application)
function Invoke-CommandInMasterVM {
	<#
	.SYNOPSIS
		Copies a host-staged script into the running Hyper-V control plane VM (kubemaster) and executes it.
	.DESCRIPTION
		Reuses existing SSH/key infrastructure exposed by linuxnode vm module (Invoke-CmdOnControlPlaneViaSSHKey,
		Copy-ToControlPlaneViaSSHKey). Assumes Hyper-V (not WSL) environment. Designed primarily for applying the
		Debian delta script generated in a delta package. Provides timing, optional log streaming, and structured
		result object.
	.PARAMETER ScriptPath
		Absolute path on the Windows host to the script to execute (e.g. apply-debian-delta.sh).
	.PARAMETER WorkingDirectory
		Optional host directory containing related assets; copied recursively if provided (only the script is
		required). Defaults to the script's parent directory. Directory contents are placed under /tmp/k2s-delta-deb.
	.PARAMETER ShowLogs
		If set, echo remote stdout/stderr lines (underlying helpers already log; we add phase headers).
	.PARAMETER TimeoutSeconds
		Overall timeout for the remote execution attempt. Does not forcibly kill remote process beyond plink exit.
	.PARAMETER RetryCount
		Number of SSH retries for transient failures (mapped to existing helper retry semantics).
	.PARAMETER NoThrow
		Return result object even if exit code != 0 (caller handles).
	.OUTPUTS
		PSCustomObject { ExitCode; DurationSeconds; RemotePath; Success; }
	.NOTES
		May evolve to include cleanup logic or hash verification of script.
	#>
	[CmdletBinding()] param(
		[Parameter(Mandatory=$true)][string] $ScriptPath,
		[string] $WorkingDirectory = '',
		[switch] $ShowLogs,
		[int] $TimeoutSeconds = 900,
		[int] $RetryCount = 0,
		[switch] $NoThrow
	)

	$consoleSwitch = $ShowLogs
	if ([string]::IsNullOrWhiteSpace($ScriptPath)) { throw 'ScriptPath is required.' }
	if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "ScriptPath not found: $ScriptPath" }

	# Import vm module to access SSH helpers (idempotent import)
	$vmModule = Get-UpdateVmModulePath
	if (-not (Test-Path -LiteralPath $vmModule)) {
		throw "VM module not found: $vmModule"
	}
	Import-Module $vmModule -Force -ErrorAction Stop
	if (-not (Get-Command -Name Invoke-CmdOnControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
		throw 'Invoke-CmdOnControlPlaneViaSSHKey not available (vm module not imported)'
	}
	if (-not (Get-Command -Name Copy-ToControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
		throw 'Copy-ToControlPlaneViaSSHKey not available (vm module not imported)'
	}
	# Ensure control plane VM is running (Hyper-V path). If WSL is enabled, skip Hyper-V start logic.
	$wslEnabled = $false
	if (Get-Command -Name Get-ConfigWslFlag -ErrorAction SilentlyContinue) {
		try { $wslEnabled = (Get-ConfigWslFlag) } catch { $wslEnabled = $false }
	}
	if (-not $wslEnabled) {
		# Import vm module for Get-IsControlPlaneRunning / Wait-ForSSHConnectionToLinuxVMViaSshKey
		$vmModule = Get-UpdateVmModulePath
		if (Test-Path -LiteralPath $vmModule) { Import-Module $vmModule -Force -ErrorAction SilentlyContinue }
		$cpRunning = $false
		if (Get-Command -Name Get-IsControlPlaneRunning -ErrorAction SilentlyContinue) {
			try { $cpRunning = Get-IsControlPlaneRunning } catch { $cpRunning = $false }
		}
		if (-not $cpRunning) {
			if (-not $NoThrow) { throw 'Control plane VM not running; cannot apply Debian delta.' }
			return [pscustomobject]@{ ExitCode = 100; DurationSeconds = 0; RemotePath = $null; Success = $false }
		}
		if ($cpRunning -and (Get-Command -Name Wait-ForSSHConnectionToLinuxVMViaSshKey -ErrorAction SilentlyContinue)) {
			Write-Log '[DebPkg][VM] Waiting for SSH availability' -Console:$consoleSwitch
			# Skip SSH wait during delta update - the control plane is already verified running
			# and calling Wait-ForSSHConnectionToLinuxVMViaSshKey can hang in CI environments
			# where the outer SSH session uses -n (stdin from /dev/null), causing nested ssh.exe
			# calls to behave unexpectedly on Windows
			Write-Log '[DebPkg][VM] Skipping SSH wait (control plane already verified running)' -Console:$consoleSwitch
		}
	}

	$scriptDir = Split-Path -Parent $ScriptPath
	if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = $scriptDir }
	if (-not (Test-Path -LiteralPath $WorkingDirectory)) { throw "WorkingDirectory not found: $WorkingDirectory" }

	$remoteBase = '/tmp/k2s-delta-deb'
	$remoteScriptName = Split-Path -Leaf $ScriptPath
	$remoteScriptPath = "$remoteBase/$remoteScriptName"

	function Invoke-RequiredControlPlaneCommand {
		param(
			[Parameter(Mandatory = $true)][string] $Command,
			[Parameter(Mandatory = $true)][string] $Operation
		)

		$result = Invoke-CmdOnControlPlaneViaSSHKey $Command -Retries $RetryCount -Timeout 2
		if ($null -eq $result -or -not $result.Success) {
			throw "$Operation failed on the control plane"
		}
		return $result.Output
	}

	Write-Log "[DebPkg][VM] Staging Debian delta script '$remoteScriptName'" -Console:$consoleSwitch
	try {
		# Ensure remote directory and make it writable by the user
		# Note: Do NOT use -Nested:$true as it removes -n flag from SSH which causes hangs
		# in CI environments where outer SSH uses stdin from /dev/null
		Invoke-RequiredControlPlaneCommand `
			-Command "sudo mkdir -p $remoteBase && sudo chown `$(whoami) $remoteBase" `
			-Operation 'Creating the Debian delta staging directory' | Out-Null

		# Copy only the script (avoid large recursive transfers unless needed)
		Copy-ToControlPlaneViaSSHKey -Source $ScriptPath -Target $remoteBase -IgnoreErrors:$false
		
		# Convert Windows CRLF line endings to Unix LF (scripts may have been corrupted by Windows zip extraction)
		# This prevents "bash\r: No such file or directory" errors
		(Invoke-CmdOnControlPlaneViaSSHKey "sed -i 's/\r$//' $remoteScriptPath" -Retries $RetryCount -Timeout 2 -IgnoreErrors:$true).Output | Out-Null
		
		# If ancillary assets exist (packages/, etc.) we copy directory selectively
		$packagesDir = Join-Path $WorkingDirectory 'packages'
		if (Test-Path -LiteralPath $packagesDir) {
			Write-Log '[DebPkg][VM] Copying packages/ directory' -Console:$consoleSwitch
			Copy-ToControlPlaneViaSSHKey -Source $packagesDir -Target $remoteBase -IgnoreErrors:$false
		}
		
		# Copy Linux container images for air-gapped kubeadm upgrade
		# Images are required by kubeadm upgrade apply to pull control plane components
		# Check both delta root level and image-delta subdirectory for Linux images
		$deltaRoot = Split-Path -Parent $WorkingDirectory
		$imagesDirs = @(
			(Join-Path $deltaRoot 'image-delta/linux/images'),
			(Join-Path $deltaRoot 'images')
		)
		$imagesCopied = $false
		foreach ($imagesDir in $imagesDirs) {
			if ((Test-Path -LiteralPath $imagesDir) -and -not $imagesCopied) {
				$tarFiles = Get-ChildItem -LiteralPath $imagesDir -Filter '*.tar' -File -ErrorAction SilentlyContinue
				if ($tarFiles.Count -gt 0) {
					Write-Log "[DebPkg][VM] Copying $($tarFiles.Count) container images for offline kubeadm upgrade" -Console:$consoleSwitch
					Invoke-RequiredControlPlaneCommand `
						-Command "mkdir -p $remoteBase/images" `
						-Operation 'Creating the Debian delta image directory' | Out-Null
					Copy-ToControlPlaneViaSSHKey -Source $imagesDir -Target $remoteBase -IgnoreErrors:$false
					$imagesCopied = $true
					Write-Log '[DebPkg][VM] Container images copied successfully' -Console:$consoleSwitch
				}
			}
		}
		
		# Make executable
		Invoke-RequiredControlPlaneCommand `
			-Command "sudo chmod +x $remoteScriptPath" `
			-Operation 'Making the Debian delta script executable' | Out-Null
	} catch {
		throw "Failed to stage script in master VM: $($_.Exception.Message)"
	}

	Write-Log '[DebPkg][VM] Executing Debian delta script inside control plane VM' -Console:$consoleSwitch
	$start = Get-Date
	
	# Use background execution with polling to avoid stdin/stdout blocking in nested SSH environments
	# The script runs with nohup and writes output to a log file; we poll for completion via exit code file
	$remoteLogFile = "$remoteBase/deb-delta.log"
	$remoteExitFile = "$remoteBase/deb-delta.exit"
	
	# Cleanup any previous run artifacts
	$cleanupCmd = "sudo rm -f $remoteLogFile $remoteExitFile </dev/null 2>&1"
	(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $cleanupCmd -IgnoreErrors:$true -NoLog:$true).Output | Out-Null
	
	# Launch script in background with nohup, redirect all I/O, capture exit code to file
	$bgCmd = "nohup sudo $remoteScriptPath >$remoteLogFile 2>&1 </dev/null; echo `$? >$remoteExitFile &"
	# Use sh -c to ensure proper background handling
	$launchCmd = "sh -c '$bgCmd' </dev/null >/dev/null 2>&1"
	
	Write-Log '[DebPkg][VM] Launching script in background...' -Console:$consoleSwitch
	Invoke-RequiredControlPlaneCommand `
		-Command $launchCmd `
		-Operation 'Launching the Debian delta script' | Out-Null
	
	# Brief wait to let the script start
	Start-Sleep -Seconds 2
	
	# Poll for exit code file with timeout
	$elapsed = $null
	$exitCode = -1
	$success = $false
	$outputAggregate = @()
	$pollInterval = 5
	$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
	
	Write-Log "[DebPkg][VM] Polling for completion (timeout=${TimeoutSeconds}s)..." -Console:$consoleSwitch
	while ((Get-Date) -lt $deadline) {
		Start-Sleep -Seconds $pollInterval
		
		# Check if exit file exists (indicates script finished)
		$checkCmd = "test -f $remoteExitFile && cat $remoteExitFile || echo 'RUNNING'"
		$checkResult = (Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $checkCmd -IgnoreErrors:$true -NoLog:$true).Output
		
		if ($null -ne $checkResult -and $checkResult -ne 'RUNNING' -and $checkResult -match '^\d+$') {
			$exitCode = [int]$checkResult
			$success = ($exitCode -eq 0)
			break
		}
		
		Write-Log '[DebPkg][VM] Script still running...' -Console:$consoleSwitch
	}
	
	$elapsed = (Get-Date) - $start
	
	# Retrieve log output
	$logCmd = "cat $remoteLogFile 2>/dev/null || echo '(no output)'"
	$logOutput = (Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $logCmd -IgnoreErrors:$true -NoLog:$true).Output
	if ($logOutput) {
		$outputAggregate += $logOutput
		Write-Log "[DebPkg][VM] Script output: $logOutput" -Console:$consoleSwitch
	}
	
	# Cleanup remote artifacts
	$cleanupCmd = "sudo rm -f $remoteLogFile $remoteExitFile </dev/null 2>&1"
	(Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $cleanupCmd -IgnoreErrors:$true -NoLog:$true).Output | Out-Null
	
	if ($exitCode -eq -1) {
		# Script didn't finish within timeout
		Write-Log "[DebPkg][VM] Script execution timed out after $TimeoutSeconds seconds" -Console
		if (-not $NoThrow) { throw "Debian delta script timed out after $TimeoutSeconds seconds" }
	}
	
	$durationSec = [Math]::Round($elapsed.TotalSeconds,2)
	
	# Log the output from the Debian delta script execution
	if ($outputAggregate.Count -gt 0) {
		Write-Log "[DebPkg][VM] Script output:" -Console:$consoleSwitch
		foreach ($line in $outputAggregate) {
			if (-not [string]::IsNullOrWhiteSpace($line)) {
				Write-Log ("[DebPkg][VM]   {0}" -f $line) -Console:$consoleSwitch
			}
		}
	}
	
	Write-Log ("[DebPkg][VM] Script completed exit={0} duration={1}s" -f $exitCode, $durationSec) -Console:$consoleSwitch
	if (-not $success -and -not $NoThrow) { throw "Debian delta script returned non-zero exit code: $exitCode" }

	return [pscustomobject]@{ ExitCode = $exitCode; DurationSeconds = $durationSec; RemotePath = $remoteScriptPath; Success = $success }
}

Export-ModuleMember -Function Invoke-CommandInMasterVM -ErrorAction SilentlyContinue
# endregion
