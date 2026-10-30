# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs secure communication

.DESCRIPTION
Enables secure communication into and inside the cluster. This includes:
- certificate provisioning and renewal, for TLS termination and service meshes

.EXAMPLE
Enable security in k2s
powershell <installation folder>\addons\security\Enable.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true)]
Param (
	[parameter(Mandatory = $false, HelpMessage = 'Enable ingress addon')]
	[ValidateSet('nginx', 'traefik','nginx-gw')]
	[string] $Ingress = 'nginx',
	[parameter(Mandatory = $false, HelpMessage = 'Security type setting')]
	[ValidateSet('basic', 'enhanced')]
	[string] $Type = 'basic',
	[parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
	[switch] $ShowLogs = $false,
	[parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
	[pscustomobject] $Config,
	[parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
	[switch] $EncodeStructuredOutput,
	[parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
	[string] $MessageType,
	[parameter(Mandatory = $false, HelpMessage = 'Omit hydra and login implementation')]
	[switch] $OmitHydra,
	[parameter(Mandatory = $false, HelpMessage = 'Omit keycloak and use external oauth2 provider')]
	[switch] $OmitKeycloak,
	[parameter(Mandatory = $false, HelpMessage = 'Omit OAuth2 proxy deployment')]
	[switch] $OmitOAuth2Proxy,
	[parameter(Mandatory = $false, HelpMessage = 'Omit Kyverno policy enforcement engine')]
	[switch] $OmitPolicyEnf
)
$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\lib\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$securityModule = "$PSScriptRoot\security.module.psm1"
$dashboardModule = "$PSScriptRoot\..\dashboard\dashboard.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule, $securityModule
Import-Module PKI;

Initialize-Logging -ShowLogs:$ShowLogs

$windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
$Proxy = "http://$($windowsHostIpAddress):8181"

Write-Log 'Checking cluster status' -Console

# get addon name from folder path
$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
	if ($EncodeStructuredOutput -eq $true) {
		Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
		return
	}

	Write-Log $systemError.Message -Error
	exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'security' })) -eq $true) {
	$errMsg = "Addon 'security' is already enabled, nothing to do."

	if ($EncodeStructuredOutput -eq $true) {
		$err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
		Send-ToCli -MessageType $MessageType -Message @{Error = $err }
		return
	}

	Write-Log $errMsg -Error
	exit 1
}

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
	$err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'security' can only be enabled for 'k2s' setup type."
	Send-ToCli -MessageType $MessageType -Message @{Error = $err }
	return
}

if (Confirm-EnhancedSecurityOn($Type)) {
	$ReleaseId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
	if ($ReleaseId -lt 20348 ) {
		Write-Log "enhanced security needs at the moment minimal Windows Version 20348, you have $ReleaseId"
		throw "[PREREQ-FAILED] Windows release $ReleaseId is not usable for enhanced for now, please use basic security instead."
	}
}

try {

	# Install cert-manager first (required for TLS certificate generation)
	Write-Log 'Checking if cert-manager is already installed' -Console
	$manifestPath = "$PSScriptRoot\addon.manifest.yaml"
    $k2sRoot = "$PSScriptRoot\..\.."
    Install-CmctlCli -ManifestPath $manifestPath -K2sRoot $k2sRoot -Proxy $Proxy
	if (Wait-ForCertManagerAvailable -WaitTimeout '30s') {
		Write-Log 'cert-manager is already installed and ready' -Console
	} else {
		Write-Log 'Installing cert-manager' -Console
		Enable-CertManager -Proxy $Proxy -EncodeStructuredOutput:$EncodeStructuredOutput -MessageType $MessageType
	}

	# Check for existing ingress controller or enable one
	if (Test-NginxIngressControllerAvailability) {
		# Ensure certificate exists
	
		Assert-IngressTlsCertificate -IngressType 'nginx' -CertificateManifestPath "$PSScriptRoot\..\ingress\nginx\manifests\cluster-local-ingress.yaml"
	}
	elseif (Test-TraefikIngressControllerAvailability) {
		Assert-IngressTlsCertificate -IngressType 'traefik' -CertificateManifestPath "$PSScriptRoot\..\ingress\traefik\manifests\cluster-local-ingress.yaml"
	}
	elseif (Test-NginxGatewayAvailability) {
		Assert-IngressTlsCertificate -IngressType 'nginx-gw' -CertificateManifestPath "$PSScriptRoot\..\ingress\nginx-gw\manifests\k2s-cluster-local-tls-certificate.yaml"
	}
	else {
		# Enable required ingress addon
		Write-Log "No Ingress controller found in the cluster, enabling $Ingress controller" -Console
		Enable-IngressAddon -Ingress:$Ingress
		Assert-IngressTlsCertificate -IngressType $Ingress -CertificateManifestPath "$PSScriptRoot\..\ingress\$Ingress\manifests\cluster-local-ingress.yaml"
	}

	# Keycloak and Hydra setup (conditional)
	if (-not $OmitKeycloak) {
		Write-Log 'Installing keycloak and db' -Console
		$keyCloakPostgresYaml = Get-KeyCloakPostgresConfig
		(Invoke-Kubectl -Params 'apply', '-f', $keyCloakPostgresYaml).Output | Write-Log
		$keyCloakYaml = Get-KeyCloakConfig
		(Invoke-Kubectl -Params 'apply', '-f', $keyCloakYaml).Output | Write-Log
		Write-Log 'Waiting for postgresql pods to be available' -Console
		Wait-ForKeyCloakPostgresqlAvailable
		Write-Log 'Waiting for keycloak pods to be available' -Console
		$keycloakPodStatus = Wait-ForKeyCloakAvailable
		Write-Log 'Waiting after keycloak pod is available' -Console

		if (-not $OmitOAuth2Proxy) {
			$oauth2ProxyYaml = Get-OAuth2ProxyConfig
			(Invoke-Kubectl -Params 'apply', '-f', $oauth2ProxyYaml).Output | Write-Log
			Write-Log 'Waiting for oauth2-proxy pods to be available' -Console
			$oauth2ProxyPodStatus = Wait-ForOauth2ProxyAvailable
			# Update must be invoked AFTER oauth2-proxy is deployed so the deployment-based ingress
			# gating in Enable-IngressForSecurity sees the oauth2-proxy deployment and creates both
			# the Keycloak and OAuth2 Proxy ingress resources.
			&"$PSScriptRoot\Update.ps1"
		} else {
			Write-Log 'Omitting OAuth2 proxy setup as per flag.' -Console
			$oauth2ProxyPodStatus = $true
		}
		if (-not $OmitHydra) {
			Write-Log 'Hydra and login implementation is set up (not omitted).' -Console
			# Enable Windows Users for Keycloak
			$winSecurityStatus = $true
			if ($keycloakPodStatus -eq $true -and $oauth2ProxyPodStatus -eq $true) {
				if ($setupInfo.LinuxOnly -eq $false) {
					$winSecurityStatus = Enable-WindowsSecurityDeployments
				} else {
					Write-Log 'Skipping Windows security deployment because of Linux only setup'
				}
			}
		}
	} else {
		Write-Log 'Omitting Keycloak setup as per flag.' -Console
		$keycloakPodStatus = $true
		if (-not $OmitHydra ) {
			Write-Log 'Using Hydra as OIDC provider for oauth2-proxy' -Console
			$winSecurityStatus = $true
				if ($keycloakPodStatus -eq $true) {
					if ($setupInfo.LinuxOnly -eq $false) {
						$winSecurityStatus = Enable-WindowsSecurityDeployments	
						if (-not $OmitOAuth2Proxy) {
							$oauth2ProxyYaml = Get-OAuth2ProxyHydraConfig
							(Invoke-Kubectl -Params 'apply', '-f', $oauth2ProxyYaml).Output | Write-Log
							Write-Log 'Waiting for oauth2-proxy pods to be available' -Console
							$oauth2ProxyPodStatus = Wait-ForOauth2ProxyAvailable
							# Update must be invoked AFTER oauth2-proxy is deployed so the deployment-based
							# ingress gating in Enable-IngressForSecurity sees the oauth2-proxy deployment.
							&"$PSScriptRoot\Update.ps1"
						} else {
							Write-Log 'Omitting OAuth2 proxy setup as per flag.' -Console
							$oauth2ProxyPodStatus = $true
						}
				} else {
					Write-Log 'Skipping Windows security deployment because of Linux only setup'
					if (-not $OmitOAuth2Proxy) {
						$oauth2ProxyYaml = Get-OAuth2ProxyHydraConfig
						(Invoke-Kubectl -Params 'apply', '-f', $oauth2ProxyYaml).Output | Write-Log
						Write-Log 'Waiting for oauth2-proxy pods to be available' -Console
						$oauth2ProxyPodStatus = Wait-ForOauth2ProxyAvailable
						# Update must be invoked AFTER oauth2-proxy is deployed so the deployment-based
						# ingress gating in Enable-IngressForSecurity sees the oauth2-proxy deployment.
						&"$PSScriptRoot\Update.ps1"
					} else {
						Write-Log 'Omitting OAuth2 proxy setup as per flag.' -Console
						$oauth2ProxyPodStatus = $true
					}
				}
			}
		} else {
			$oauth2ProxyPodStatus = $true
			Write-Log 'Omitting keycloak and hydra. Please be aware that no identity provider is running' -Console
			Write-Log 'ALL calls will be forwarded to the server without authentication and/or authorization!!!' -Console
		}
	}

	# Hydra/login setup (conditional)
	if (-not $OmitHydra) {
		# Check if all security pods are available
		if ($keycloakPodStatus -ne $true -or $oauth2ProxyPodStatus -ne $true -or $winSecurityStatus -ne $true) {
			$errMsg = "All security pods could not become ready. Please use kubectl describe for more details.`nInstallation of security addon failed."
			if ($EncodeStructuredOutput -eq $true) {
				$err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
				Send-ToCli -MessageType $MessageType -Message @{Error = $err }
				return
			}
			Write-Log $errMsg -Error
			throw $errMsg
		}
	} else {
		Write-Log 'Omitting hydra and login implementation as per flag.' -Console
	}

	# Enhanced Security is on
	if (Confirm-EnhancedSecurityOn($Type)) {

		Install-LinkerdCli -ManifestPath $manifestPath -K2sRoot $k2sRoot -Proxy $Proxy

		# generate linkerd config
		Write-Log 'Creating linkerd config files' -Console
		$clinkerdExe = "$(Get-KubeBinPath)\linkerd.exe"
		$linkerdYaml = Get-LinkerdConfigDirectory

		Invoke-LinkerdCliRender `
			-LinkerdExe $clinkerdExe `
			-Arguments @('install', '--ignore-cluster', '--crds') `
			-OutputFile "$linkerdYaml\linkerd-crds.yaml" `
			-Description 'CRD manifest generation'

		# create linkerd namespace
		Write-Log 'Creating linkerd namespace' -Console
		(Invoke-Kubectl -Params 'create', 'namespace', 'linkerd').Output | Write-Log

		# create cni config for access, these needs to be created before installing linkerd
		Write-Log 'Creating client config file for CNI access' -Console
		$linkerdYamlCNI = Get-LinkerdConfigCNI
		(Invoke-Kubectl -Params 'apply', '-f', $linkerdYamlCNI).Output | Write-Log
		Write-Log 'Generate kubeconfig for CNI plugin based on service account' -Console
		Initialize-ConfigFileForCNI

		# install trust manager (includes Bundle CRD)
		Write-Log 'Install trust manager' -Console
		$linkerdYamlTrustManager = Get-LinkerdConfigTrustManager
		(Invoke-Kubectl -Params 'apply', '--server-side', '-f', $linkerdYamlTrustManager).Output | Write-Log
		Write-Log 'Waiting for trust manager pods to be available' -Console
		$trustManagerPodStatus = Wait-ForTrustManagerAvailable
		if ($trustManagerPodStatus -ne $true) {
			$errMsg = "All trust manager pods could not become ready. Please use kubectl describe for more details.`nInstallation of security addon failed."
			if ($EncodeStructuredOutput -eq $true) {
				$err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
				Send-ToCli -MessageType $MessageType -Message @{Error = $err }
				return
			}

			Write-Log $errMsg -Error
			throw $errMsg
		}

		# Wait for trust manager webhook to be ready before creating resources that require validation
		Write-Log 'Waiting for trust manager webhook to be ready' -Console
		$webhookStatus = Wait-ForTrustManagerWebhookReady
		if ($webhookStatus -ne $true) {
			$errMsg = "Trust manager webhook did not become ready. The webhook endpoint may not be accepting connections.`nInstallation of security addon failed."
			if ($EncodeStructuredOutput -eq $true) {
				$err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
				Send-ToCli -MessageType $MessageType -Message @{Error = $err }
				return
			}

			Write-Log $errMsg -Error
			throw $errMsg
		}

		# Clean up stale linkerd PKI resources to prevent cert-manager key mismatch race condition.
		# When re-enabling after a prior disable, leftover secrets/certificates can cause
		# ErrorKeyMatch ("CSR not signed by referenced private key") because cert-manager
		# finds an existing private key that doesn't match the new CSR.
		Write-Log 'Cleaning up stale linkerd PKI resources' -Console
		(Invoke-Kubectl -Params 'delete', 'certificate', 'linkerd-trust-anchor', '-n', 'cert-manager', '--ignore-not-found').Output | Write-Log
		(Invoke-Kubectl -Params 'delete', 'certificate', 'linkerd-identity-issuer', '-n', 'linkerd', '--ignore-not-found').Output | Write-Log
		(Invoke-Kubectl -Params 'delete', 'secret', 'linkerd-trust-anchor', '-n', 'cert-manager', '--ignore-not-found').Output | Write-Log
		(Invoke-Kubectl -Params 'delete', 'secret', 'linkerd-identity-issuer', '-n', 'linkerd', '--ignore-not-found').Output | Write-Log
		(Invoke-Kubectl -Params 'delete', 'secret', 'linkerd-previous-anchor', '-n', 'cert-manager', '--ignore-not-found').Output | Write-Log

		# install cert-manager addons
		Write-Log 'Install trust manager and cert-manager resources, creating bundle' -Console
		Clear-KubectlDiscoveryCache
		$linkerdYamlCertManager = Get-LinkerdConfigCertManager
		(Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '-f', $linkerdYamlCertManager).Output | Write-Log

		# Wait for the self-signed Issuer to be Ready before expecting Certificate issuance.
		# cert-manager must reconcile the Issuer first; without this, the Certificate stays
		# in an empty status state because its Issuer is not yet available.
		Write-Log 'Waiting for linkerd-trust-root-issuer to be Ready' -Console
		$issuerReady = Wait-ForIssuerReady -IssuerName 'linkerd-trust-root-issuer' -Namespace 'cert-manager' -TimeoutSeconds 60 -KubeToolsPath (Get-KubeToolsPath)
		if ($issuerReady -ne $true) {
			Write-Log 'WARNING: Issuer linkerd-trust-root-issuer not Ready yet, Certificate issuance may be delayed' -Console
		}

		# wait for secret linkerd-trust-anchor to be available
		Write-Log 'Waiting for secret linkerd-trust-anchor to be available' -Console
		$secretStatus = Wait-ForK8sSecret -SecretName 'linkerd-trust-anchor' -Namespace 'cert-manager' -TimeoutSeconds 120
		if ($secretStatus -ne $true) {
			$errMsg = "Secret linkerd-trust-anchor not available. Please use kubectl describe for more details.`nInstallation of security addon failed."
			if ($EncodeStructuredOutput -eq $true) {
				$err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
				Send-ToCli -MessageType $MessageType -Message @{Error = $err }
				return
			}

			Write-Log $errMsg -Error
			throw $errMsg
		}
		# create previous anchor secret
		Write-Log 'Create previous anchor secret' -Console
        $kubeToolsPath = Get-KubeToolsPath

		# Verify the Certificate resource is Ready (not just that the secret exists).
		# This prevents using a stale or partially-issued certificate that could cause
		# x509 verification failures in linkerd-identity.
		Write-Log 'Verifying linkerd-trust-anchor certificate is Ready' -Console
		$certReady = Wait-ForCertificateReady -CertificateName 'linkerd-trust-anchor' -Namespace 'cert-manager' -TimeoutSeconds 300 -KubeToolsPath $kubeToolsPath
		if ($certReady -ne $true) {
			$errMsg = "Certificate linkerd-trust-anchor did not reach Ready state. Check cert-manager logs for details.`nInstallation of security addon failed."
			if ($EncodeStructuredOutput -eq $true) {
				$err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
				Send-ToCli -MessageType $MessageType -Message @{Error = $err }
				return
			}

			Write-Log $errMsg -Error
			throw $errMsg
		}

		$secretYaml = &"$kubeToolsPath\kubectl.exe" get secret -n cert-manager linkerd-trust-anchor -o yaml | Out-String
		$modifiedYaml = $secretYaml -replace 'linkerd-trust-anchor', 'linkerd-previous-anchor'
		$filteredYamlLines = $modifiedYaml.Split("`n") | Where-Object {
			$_ -notmatch '^\s*(resourceVersion|uid):'
		}
		$filteredYaml = $filteredYamlLines -join "`n"
		$filteredYaml | &"$kubeToolsPath\kubectl.exe" apply -f -

		# Wait for trust-manager to propagate certificates to linkerd namespace
		Write-Log 'Waiting for linkerd namespace secrets to be ready' -Console
		Start-Sleep -Seconds 10

		Write-Log 'Applying Linkerd CRDs to cluster' -Console
		$crdApplyResult = Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '-f', (Get-LinkerdConfigCRDs)
		$crdApplyResult.Output | Write-Log
		if ($crdApplyResult.Success -ne $true) {
			throw "Failed to apply Linkerd CRDs: $($crdApplyResult.Output)"
		}

		Write-Log 'Waiting for Linkerd CRDs to become Established' -Console
		$linkerdCrds = @(
			'authorizationpolicies.policy.linkerd.io',
			'egressnetworks.policy.linkerd.io',
			'httplocalratelimitpolicies.policy.linkerd.io',
			'httproutes.policy.linkerd.io',
			'meshtlsauthentications.policy.linkerd.io',
			'networkauthentications.policy.linkerd.io',
			'serverauthorizations.policy.linkerd.io',
			'servers.policy.linkerd.io',
			'serviceprofiles.linkerd.io',
			'externalworkloads.workload.linkerd.io'
		)
		$linkerdCrdResources = $linkerdCrds | ForEach-Object { "crd/$_" }
		$crdWaitResult = Invoke-Kubectl -Params (@('wait', '--for=condition=Established') + $linkerdCrdResources + '--timeout=120s')
		$crdWaitResult.Output | Write-Log
		if ($crdWaitResult.Success -ne $true) {
			throw "Linkerd CRDs did not become Established within 120s: $($crdWaitResult.Output)"
		}
		Clear-KubectlDiscoveryCache

		Write-Log 'Creating linkerd control plane manifest' -Console
		$controlPlaneArguments = @(
			'install',
			'--disable-heartbeat',
			'--proxy-memory-limit', '100Mi',
			'--proxy-cpu-request', '100m',
			'--proxy-cpu-limit', '100m',
			'--default-inbound-policy', 'all-authenticated',
			'--set', 'identity.externalCA=true',
			'--set', 'identity.issuer.scheme=kubernetes.io/tls',
			'--set', 'proxy.await=false',
			'--set', 'proxy.image.name=shsk2s.azurecr.io/linkerd/proxy'
		)
		Invoke-LinkerdCliRender `
			-LinkerdExe $clinkerdExe `
			-Arguments $controlPlaneArguments `
			-OutputFile "$linkerdYaml\linkerd.yaml" `
			-Description 'control plane manifest generation'

		# install linkerd
		# Clear kubectl discovery cache before applying Linkerd kustomization
		# which bundles CRDs and CRD instances together
		Clear-KubectlDiscoveryCache
		$linkerdYamlCRDs = Get-LinkerdConfigDirectory
		(Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '-k', $linkerdYamlCRDs).Output | Write-Log
		Write-Log 'Waiting for linkerd pods to be available' -Console
		$linkerdPodStatus = Wait-ForLinkerdAvailable
		if ($linkerdPodStatus -ne $true) {
			$errMsg = "All linkerd pods could not become ready. Please use kubectl describe for more details.`nInstallation of security addon failed."
			if ($EncodeStructuredOutput -eq $true) {
				$err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
				Send-ToCli -MessageType $MessageType -Message @{Error = $err }
				return
			}

			Write-Log $errMsg -Error
			throw $errMsg
		}

	if (-not $OmitKeycloak -and -not $OmitOAuth2Proxy) {
			if (-not (Test-NginxGwServerAuthorizationExists)) {
				Write-Log 'Applying Linkerd ServerAuthorization policies for nginx-gw ingress' -Console
				&"$PSScriptRoot\Update.ps1"
			} else {
				Write-Log 'Linkerd ServerAuthorization policies for nginx-gw already exist, skipping update' -Console
			}
		}
		if (-not $OmitKeycloak) {
			# update basic security pods: redis, oauth2-proxy, keycloak to be part of the service mesh
			Write-Log "Updating redis to be part of service mesh" -Console
			$annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/opaque-ports\":\"6379\"}}}}}'
			(Invoke-Kubectl -Params 'patch', 'deployment', 'redis', '-n', 'security', '-p', $annotations1).Output | Write-Log
			if (-not $OmitOAuth2Proxy) {
				$annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/opaque-ports\":\"6379\"}}}}}'
				(Invoke-Kubectl -Params 'patch', 'deployment', 'oauth2-proxy', '-n', 'security', '-p', $annotations2).Output | Write-Log
			}
			$annotations3 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-outbound-ports\":\"4444\"}}}}}'
			(Invoke-Kubectl -Params 'patch', 'deployment', 'keycloak', '-n', 'security', '-p', $annotations3).Output | Write-Log
			$annotations4 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/opaque-ports\":\"5432\",\"config.linkerd.io/proxy-await\":\"enabled\"}}}}}'
			(Invoke-Kubectl -Params 'patch', 'deployment', 'postgresql', '-n', 'security', '-p', $annotations4).Output | Write-Log
			# wait for pods to be ready
			Write-Log 'Waiting for security pods to be ready' -Console
			(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'security', '--timeout', '360s').Output | Write-Log
		} else {
			if (-not $OmitHydra -and -not $OmitOAuth2Proxy) {
				$annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/opaque-ports\":\"6379\"}}}}}'
				(Invoke-Kubectl -Params 'patch', 'deployment', 'oauth2-proxy', '-n', 'security', '-p', $annotations2).Output | Write-Log
			}
			else {
				Write-Log 'Skipping security pods linker update because of OmitKeycloak and OmitHydra flags' -Console
			}
		}
	}

	# Kyverno policy enforcement
	if (-not $OmitPolicyEnf) {
		Write-Log 'Installing Kyverno policy enforcement engine' -Console
		Install-KyvernoCli -ManifestPath $manifestPath -K2sRoot $k2sRoot -Proxy $Proxy
		Install-Kyverno -Proxy $Proxy -EnhancedSecurity:(Confirm-EnhancedSecurityOn($Type))
		Write-Log 'Kyverno policy enforcement engine installed successfully' -Console
	} else {
		Write-Log 'Omitting Kyverno policy enforcement engine as per flag.' -Console
	}

	Write-Log '[Security] Waiting for security-stack deployments to reach Available state...' -Console
	$stabilizationNamespaces = [System.Collections.Generic.List[string]]@('security', 'cert-manager')
	if (Confirm-EnhancedSecurityOn($Type)) { $stabilizationNamespaces.Add('linkerd') }

	foreach ($ns in $stabilizationNamespaces) {
		Write-Log "[Security] Waiting for deployments in namespace '$ns' to be Available..." -Console
		$waitResult = Invoke-Kubectl -Params 'wait', '--for=condition=Available', 'deployment', '--all', '-n', $ns, '--timeout=120s'
		$waitResult.Output | Write-Log
		if ($waitResult.Success -ne $true) {
			Write-Log "[Security] Warning: some deployments in '$ns' did not reach Available state within 120s. Continuing." -Console
		}
	}
	Write-Log '[Security] Security-stack stabilisation complete.' -Console
}
catch {
	Write-Log 'Exception happened during enable of addon' -Console
	$errMsg = $_.Exception.Message
	if ($EncodeStructuredOutput -eq $true) {
		$err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
		Send-ToCli -MessageType $MessageType -Message @{Error = $err }
	}
	Write-Log 'Please run the k2s addons disable ... cmd and start again' -Console
	exit 1
}
finally {
	# write marker for enhanced security
	if (Confirm-EnhancedSecurityOn($Type)) {
		Save-LinkerdMarkerConfig
	}
}

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'security' })

# sync Headlamp plugins - cert-manager is now running
if (Test-Path $dashboardModule) {
    Import-Module $dashboardModule -Force
    if (Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue) {
        Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins after security enable' -Console
        try {
            Sync-HeadlampPlugins
        }
        catch {
            # Plugin sync is best-effort: a failure here must not fail the primary addon operation.
            Write-Log "[Dashboard][Plugin] Headlamp plugin sync failed (security enable continues): $($_.Exception.Message)" -Console
        }
    }
}

# if security addon is enabled, than adapt other addons
# Important is that update is called at the end because addons check state of security addon
Update-Addons -AddonName $addonName

Write-Log 'Installation of security finished.' -Console

Write-SecurityUsageForUser
Write-SecurityWarningForUser

if ($EncodeStructuredOutput -eq $true) {
	Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
