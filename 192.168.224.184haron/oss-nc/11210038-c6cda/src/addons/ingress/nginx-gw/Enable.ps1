# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs nginx-gw - kubernetes gateway api controller(gateway controller)

.DESCRIPTION
NA

.EXAMPLE
# For k2sSetup.
powershell <installation folder>\addons\ingress\nginx-gw\Enable.ps1
#>

Param (
    [string] $InfraNodeSelector = '',
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'Omit cert-manager installation (TLS certificates must be provided manually)')]
    [switch] $OmitCertMgr = $false
)
$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$gatewayModule = "$PSScriptRoot\nginx-gw.module.psm1"
$dashboardModule = "$PSScriptRoot\..\..\dashboard\dashboard.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $gatewayModule

Initialize-Logging -ShowLogs:$ShowLogs
trap { if ($EncodeStructuredOutput) { Send-ToCli -MessageType $MessageType -Message @{Error = (New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $_.Exception.Message)}; return }; throw }
$ownerOptions = Get-AddonPlacementOwnerOptions -Name 'ingress' -Implementation 'nginx-gw' -BoundParameters $PSBoundParameters -Defaults @{OmitCertMgr = $OmitCertMgr.IsPresent}
$OmitCertMgr = [switch]$ownerOptions.OmitCertMgr
$InfraNodeSelector = Get-AddonEffectiveInfrastructureSelector -Name 'ingress' -Implementation 'nginx-gw' -Selector $InfraNodeSelector

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

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'ingress nginx-gw' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx-gw' })) -eq $true) {
    $errMsg = "Addon 'ingress nginx-gw' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx' })) -eq $true) {
    $errMsg = "Addon 'ingress nginx' is enabled. Disable it first to avoid port conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}


if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'traefik' })) -eq $true) {
    $errMsg = "Addon 'ingress traefik' is enabled. Disable it first to avoid port conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'gateway-api' })) -eq $true) {
    $errMsg = "Addon 'gateway-api' is enabled. Disable it first to avoid port conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'nginx-gw-controller', '-o', 'yaml').Output
if ("$existingServices" -match '.*nginx-gw.*') {
    $errMsg = 'It seems as if ingress nginx gateway is already installed in the namespace nginx-gw. Disable it before enabling it again.'
    
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Assert-SharedInfrastructurePlacement -Name 'external-dns' -Selector $InfraNodeSelector -Namespace 'external-dns' -Deployment 'external-dns'
if (-not $OmitCertMgr) { Assert-SharedInfrastructurePlacement -Name 'cert-manager' -Selector $InfraNodeSelector -Namespace 'cert-manager' -Deployment 'cert-manager' }
if ($InfraNodeSelector) {
    Assert-AddonPlacementHost -Selector $InfraNodeSelector -NodeName (Get-ConfigControlPlaneNodeHostname) -Reason 'NGINX gateway external IP and local traffic policy'
    $preflight = New-AddonPlacementInput -AddonName 'ingress' -Path "$PSScriptRoot\manifests" -Selector $InfraNodeSelector -Kustomize
    Remove-Item -LiteralPath $preflight.Path -Force -ErrorAction SilentlyContinue
    $proxyPreflight = New-AddonPlacementInput -AddonName 'ingress' -Path "$PSScriptRoot\manifests\nginxproxy.yaml" -Selector $InfraNodeSelector
    Remove-Item -LiteralPath $proxyPreflight.Path -Force -ErrorAction SilentlyContinue
    Set-AddonPlacementIntent -Addon ([pscustomobject]@{Name = 'ingress'; Implementation = 'nginx-gw'; InfraNodeSelector = $InfraNodeSelector; OmitCertMgr = $OmitCertMgr.IsPresent})
}
Install-GatewayApiCrds

Write-Log 'Installing ExternalDNS' -Console
$externalDnsConfig = Get-ExternalDnsConfigDir
(Invoke-AddonOwnedApply -AddonName 'externaldns' -Path $externalDnsConfig -Selector $InfraNodeSelector -Kustomize).Output | Write-Log
if ($InfraNodeSelector) { Set-SharedInfrastructurePlacement -Name 'external-dns' -Selector $InfraNodeSelector }

$kustomization = @"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../manifests
"@

if (-not $OmitCertMgr) {
    Write-Log 'Installing cert-manager' -Console
    Enable-CertManager -Proxy $Proxy -EncodeStructuredOutput:$EncodeStructuredOutput -MessageType:$MessageType -InfraNodeSelector $InfraNodeSelector
}
else {
    Write-Log '[ingress nginx-gw] WARNING: cert-manager omitted. TLS certificates must be provided manually for HTTPS to function.' -Console
}

#create a temporary directory to store the kustomization file
$kustomizationDir = "$PSScriptRoot/kustomizationDir"
New-Item -Path $kustomizationDir -ItemType 'directory' -ErrorAction SilentlyContinue
$kustomizationFile = "$kustomizationDir\kustomization.yaml"
$kustomization | Out-File $kustomizationFile

Write-Log 'Installing nginx gateway' -Console
$ingressNginxGatewayNamespace = 'nginx-gw'

# Apply NGF CRDs first using server-side apply to avoid oversized
# last-applied annotations on large CRDs
$CrdsDirectory = Get-NginxGatewayCrdsDir
(Invoke-Kubectl -Params 'apply', '--server-side', '-f', $CrdsDirectory).Output | Write-Log

# Wait for NGF CRDs to be fully established before proceeding
Write-Log '[nginx-gw] Waiting for NGF CRDs to be fully established' -Console
$ngfCrdWait = Invoke-Kubectl -Params 'wait', '--for=condition=Established', 'crd/nginxproxies.gateway.nginx.org', '--timeout=120s'
if ($ngfCrdWait.Success -ne $true) {
    Write-Log "[nginx-gw] CRD wait output: $($ngfCrdWait.Output)" -Console
    Write-Log '[nginx-gw] WARNING: NGF CRDs may not be fully established' -Console
}
Write-Log '[nginx-gw] NGF CRDs are established' -Console

# Clear stale kubectl discovery cache and verify NginxProxy type is visible
Clear-KubectlDiscoveryCache
Write-Log '[nginx-gw] Waiting for kubectl discovery cache to include NginxProxy CRD' -Console
$ngfDiscoveryReady = $false
for ($d = 1; $d -le 30; $d++) {
    $probe = Invoke-Kubectl -Params 'get', 'nginxproxies', '--no-headers', '--ignore-not-found'
    if ($probe.Success -eq $true) {
        Write-Log '[nginx-gw] kubectl discovery cache is up-to-date' -Console
        $ngfDiscoveryReady = $true
        break
    }
    Write-Log "[nginx-gw] Discovery probe attempt $d/30 failed, retrying in 2s..." -Console
    Start-Sleep -Seconds 2
}
if (-not $ngfDiscoveryReady) {
    Write-Log '[nginx-gw] WARNING: kubectl discovery cache did not refresh within 60s' -Console
}

if ($InfraNodeSelector -and (-not $ngfDiscoveryReady -or -not $ngfCrdWait.Success)) { throw 'NGINX gateway CRDs must be established before applying infrastructure owners.' }
(Invoke-AddonOwnedApply -AddonName 'ingress' -Path $kustomizationDir -Selector $InfraNodeSelector -Kustomize -ServerSide:([bool]$InfraNodeSelector)).Output | Write-Log

# # delete the temporary directory
Remove-Item -Path $kustomizationDir -Recurse

$controlPlaneIp = Get-ConfiguredIPControlPlane

# Apply NginxProxy resource with the control plane IP configured
# External IP is required to make the nginx gateway accessible from the Windows host
# and external clients, enabling ingress traffic to reach services running in the cluster
Write-Log "Preparing NginxProxy resource and nginx-gw-controller service with external IP $controlPlaneIp" -Console
$nginxProxyTemplate = Get-Content "$PSScriptRoot\manifests\nginxproxy.yaml" -Raw
$nginxProxyYaml = $nginxProxyTemplate.Replace('__CONTROL_PLANE_IP__', $controlPlaneIp)
if ($InfraNodeSelector) {
    $proxyInputPath = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $proxyInputPath -Value $nginxProxyYaml -Encoding UTF8
        (Invoke-AddonOwnedApply -AddonName 'ingress' -Path $proxyInputPath -Selector $InfraNodeSelector -ServerSide).Output | Write-Log
    }
    finally { Remove-Item -LiteralPath $proxyInputPath -Force -ErrorAction SilentlyContinue }
} else { $nginxProxyYaml | & kubectl apply --server-side --force-conflicts -f - }

$allPodsAreUp = (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=nginx-gw' -Namespace 'nginx-gw' -TimeoutSeconds 300)

 if ($allPodsAreUp -ne $true) {
    $errMsg = "All ingress nginx pods could not become ready. Please use kubectl describe for more details.`nInstallation of ingress nginx failed."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

if (-not $OmitCertMgr) {
    Write-Log 'creating self-signed certificate using cert-manager' -Console
    $certCreated = New-TlsCertificateWithCertManager -Namespace $ingressNginxGatewayNamespace -SecretName 'k2s-cluster-local-tls' -DnsName 'k2s.cluster.local'
    
    if (-not $certCreated) {
        $errMsg = "Failed to create TLS certificate. HTTPS functionality may not work. Check logs for details."
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
}

# Now create the Gateway resource which will use the patched NginxProxy configuration
# Use --server-side to bypass kubectl discovery cache which may not yet include Gateway API CRDs
Write-Log 'Creating Gateway resource' -Console
$clusterIngressConfig = "$PSScriptRoot\manifests\cluster-local-nginx-gw.yaml"
(Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '-f', $clusterIngressConfig).Output | Write-Log

# Wait for controller to reconcile and create data plane service with external IP
Write-Log 'Waiting for data plane service to be created with external IP...' -Console
Start-Sleep -Seconds 5

Write-Log 'All nginx gateway pods are up and ready.'

$addonConfig = [pscustomobject] @{Name = 'ingress'; Implementation = 'nginx-gw' }
if ($InfraNodeSelector) { $addonConfig | Add-Member -NotePropertyName OmitCertMgr -NotePropertyValue $OmitCertMgr.IsPresent }
Add-AddonToSetupJson -Addon $addonConfig

&"$PSScriptRoot\Update.ps1"

if (-not $OmitCertMgr) {
    Assert-IngressTlsCertificate -IngressType 'nginx-gw' -CertificateManifestPath "$PSScriptRoot\manifests\k2s-cluster-local-tls-certificate.yaml"
}

# adapt other addons
Update-Addons -AddonName $addonName

if (Test-Path $dashboardModule) {
    Import-Module $dashboardModule -Force
    if (Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue) {
        Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins after ingress nginx-gw enable' -Console
        try {
            Sync-HeadlampPlugins
        }
        catch {
            # Plugin sync is best-effort: a failure here must not fail the primary addon operation.
            Write-Log "[Dashboard][Plugin] Headlamp plugin sync failed (ingress nginx-gw enable continues): $($_.Exception.Message)" -Console
        }
    }
}

Write-Log 'nginx-gw installed successfully' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
