# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$k8sApiModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

Import-Module $infraModule, $k8sApiModule

function Get-KeyCloakConfig {
    return "$PSScriptRoot\manifests\keycloak\keycloak.yaml"
}

function Get-KeyCloakPostgresConfig {
    return "$PSScriptRoot\manifests\keycloak\keycloak-postgres.yaml"
}

function Get-OAuth2ProxyConfig {
    return "$PSScriptRoot\manifests\keycloak\oauth2-proxy.yaml"
}

function Get-OAuth2ProxyHydraConfig {
    return "$PSScriptRoot\manifests\hydra\oauth2-proxy-hydra.yaml"
}

function Get-SecurityData {
    return "$PSScriptRoot\data"
}

function Invoke-WindowsSecurityYaml {
    param (
        [string]$yamlPath,
        [string]$updatedYamlPath
    )

    $securityData = Get-SecurityData

    if (Test-Path $updatedYamlPath) {
        Remove-Item -Path $updatedYamlPath -Force
    }

    $yamlContent = Get-Content -Path $yamlPath -Raw
    $updatedYamlContent = $yamlContent -replace '<%K2S-SECURITY-DATA%>', $securityData
    $updatedYamlContent | Set-Content -Path $updatedYamlPath -Force

    (Invoke-Kubectl -Params 'apply', '-f', $updatedYamlPath).Output | Write-Log
    Remove-Item -Path $updatedYamlPath -Force
}

function Wait-ForHydraAvailable {
    param (
        [string]$url,
        [int]$timeoutSeconds = 120,
        [int]$retryIntervalSeconds = 10
    )

    $endTime = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $endTime) {
        try {
            Write-Log "Checking Hydra availability at $url" -Console
            $response = & curl.exe -s -o /dev/null -w '%{http_code}' $url --insecure
            if ($response -eq 200) {
                Write-Log "Hydra is available at $url" -Console
                return $true
            }
        }
        catch {
            Write-Log "Hydra is not available yet. Retrying in $retryIntervalSeconds seconds..." -Console
        }
        Start-Sleep -Seconds $retryIntervalSeconds
    }
    Write-Log "Hydra did not become available within the timeout period of $timeoutSeconds seconds." -Console
    return $false
}

function Invoke-HydraClient {
    param (
        [string]$url,
        [string]$jsonFilePath
    )

    if (-Not (Test-Path $jsonFilePath)) {
        Write-Log "JSON file not found at $jsonFilePath" -Console
        return $false
    }

    $jsonContent = Get-Content -Path $jsonFilePath -Raw
    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body $jsonContent
        Write-Log "POST request to $url was successful." -Console
        return $response
    }
    catch {
        Write-Log "POST request to $url failed: $_" -Console
        return $false
    }
}

function Enable-WindowsSecurityDeployments {
    $securityData = Get-SecurityData
    if (-Not (Test-Path $securityData)) {
        New-Item -ItemType Directory -Path $securityData -Force | Out-Null
    }

    $sqlitePath = "$securityData\db.sqlite"
    if (Test-Path $sqlitePath) {
        Remove-Item -Path $sqlitePath -Force
    }


    Write-Log 'Applying windows security deployments..' -Console
    $hydraYamlPath = "$PSScriptRoot\manifests\keycloak\windowsprovider\hydra.yaml"
    $updatedHydraYamlPath = "$PSScriptRoot\manifests\keycloak\windowsprovider\hydra-updated.yaml"
    Invoke-WindowsSecurityYaml -yamlPath $hydraYamlPath -updatedYamlPath $updatedHydraYamlPath

    $winLoginYamlPath = "$PSScriptRoot\manifests\keycloak\windowsprovider\windows-login.yaml"
    $updatedWinLoginYamlPath = "$PSScriptRoot\manifests\keycloak\windowsprovider\windows-login-updated.yaml"
    Invoke-WindowsSecurityYaml -yamlPath $winLoginYamlPath -updatedYamlPath $updatedWinLoginYamlPath

    Write-Log 'Waiting for windows security deployments..' -Console
    $hydraStatus = (Wait-ForPodCondition -Condition Ready -Label 'app=hydra' -Namespace 'security' -TimeoutSeconds 300)
    $winLoginStatus = (Wait-ForPodCondition -Condition Ready -Label 'app=windows-login' -Namespace 'security' -TimeoutSeconds 300)

    Write-Log 'Waiting for windows security api to be available..' -Console
    $hydraUrl = 'http://172.19.1.1:4445/admin/clients'
    $hydraApiStatus = Wait-ForHydraAvailable -url $hydraUrl

    if ($hydraApiStatus -eq $true) {
        Write-Log 'Creating client in windows security' -Console
        $response = Invoke-HydraClient -url $hydraUrl -jsonFilePath "$PSScriptRoot\manifests\keycloak\windowsprovider\client.json"
    }    

    return ($hydraStatus -eq $true -and $winLoginStatus -eq $true -and $hydraApiStatus -eq $true)
}

function Remove-WindowsSecurityDeployments {
    $hydraYamlPath = "$PSScriptRoot\manifests\keycloak\windowsprovider\hydra.yaml"
    (Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f', $hydraYamlPath).Output | Write-Log

    $winLoginYamlPath = "$PSScriptRoot\manifests\keycloak\windowsprovider\windows-login.yaml"
    (Invoke-Kubectl -Params 'delete', '--ignore-not-found', '-f', $winLoginYamlPath).Output | Write-Log
}

<#
.DESCRIPTION
Writes the usage notes for security for the user.
#>
function Write-SecurityUsageForUser {
    @'
                SECURITY ADDON

The following features are available:
1. cert-manager: The CA Issuer named 'k2s-ca-issuer' has beed created and can 
   be used for signing. Example usage:
   ---
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
   annotations:
       ...
       cert-manager.io/cluster-issuer: k2s-ca-issuer
       cert-manager.io/common-name: your-ingress-host.domain
   ...
   spec:
   ...
   tls:
   - hosts:
       - your-ingress-host.domain
       secretName: your-secret-name
   ---
2. keycloak: Authentication support is enabled. Dummy users are also created for development.
   user: demo-user
   password: password
   Add below annotations in ingress to enable authentication support.
    nginx.ingress.kubernetes.io/auth-url: "https://k2s.cluster.local/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "https://k2s.cluster.local/oauth2/start?rd=$escaped_request_uri"
    nginx.ingress.kubernetes.io/auth-response-headers: "Authorization"
   To access keycloak admin ui: https://k2s.cluster.local/keycloak/
        user: admin
        password: admin
   Refer https://www.keycloak.org/guides for more information about keycloak
3. linkerd (only for enhanced security type): Linkerd is a service mesh implementation. It adds security, observability, and reliability to any Kubernetes cluster.
   If you have choosen the enhanced security mode, than linkerd is enabled.
   Add below annotations in your workload to enable linkerd support.
    linkerd.io/inject: "enabled"
   For more information on how to use linkerd please check: https://linkerd.io/2-edge/overview/
   To start the linkerd dashboard please run 'linkerd viz install | kubectl apply -f -' and the afterwards pods are running run 'linkerd viz dashboard --port 60888 &'
This addon is documented in <installation folder>\addons\security\README.md
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

function Write-SecurityWarningForUser {
    @'

                ATTENTION:
If you disable this add-on, the sites protected by cert-manager certificates 
will become untrusted. Delete the HSTS settings for your site (e.g. 'k2s.cluster.local')
here (works in Chrome and Edge):
chrome://net-internals/#hsts
  
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

<#
.DESCRIPTION
Waits for the keycloak pods to be available.
#>
function Wait-ForKeyCloakAvailable($waiTime = 900) {
    return (Wait-ForPodCondition -Condition Ready -Label 'app=keycloak' -Namespace 'security' -TimeoutSeconds $waiTime)
}

<#
.DESCRIPTION
Waits for the keycloak postgresqlpods to be available.
#>
function Wait-ForKeyCloakPostgresqlAvailable($waiTime = 360) {
    return (Wait-ForPodCondition -Condition Ready -Label 'app=postgresql' -Namespace 'security' -TimeoutSeconds $waiTime)
}

<#
.DESCRIPTION
Waits for the oauth2-proxy pods to be available.
#>
function Wait-ForOauth2ProxyAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'k8s-app=oauth2-proxy' -Namespace 'security' -TimeoutSeconds 120)
}

<#
.DESCRIPTION
Tests if the OAuth2 proxy service is available.
#>
function Test-OAuth2ProxyServiceAvailability {
    $deployment = (Invoke-Kubectl -Params '-n', 'security', 'get', 'deployment', 'oauth2-proxy', '--ignore-not-found').Output
    return $deployment -and $deployment -notmatch 'NotFound'
}

<#
.DESCRIPTION
Tests if the Keycloak service is available in the 'security' namespace.
#>
function Test-KeycloakServiceAvailability {
    $deployment = (Invoke-Kubectl -Params '-n', 'security', 'get', 'deployment', 'keycloak', '--ignore-not-found').Output
    return $deployment -and $deployment -notmatch 'NotFound'
}

function Enable-IngressForSecurity {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Ingress
    )

    # The keycloak and oauth2-proxy ingress resources (Ingress, Middleware, HTTPRoute,
    # Server/ServerAuthorization, SnippetsFilter) reference backend services
    # (oauth2-proxy:4180, keycloak:8080) that only exist when the corresponding OAuth
    # component is deployed. To support independently optional Keycloak and OAuth2 Proxy
    # (--omit-keycloak / --omit-oauth2-proxy / --omit-hydra), the manifests are split per
    # component and applied only when their backend is present. This avoids dangling
    # resources that flood the ingress controller logs with 'service not found' errors.
    $oauth2ProxyAvailable = Test-OAuth2ProxyServiceAvailability
    $keycloakAvailable = Test-KeycloakServiceAvailability
    if (-not $oauth2ProxyAvailable -and -not $keycloakAvailable) {
        Write-Log '[Security] Skipping security ingress creation: neither oauth2-proxy nor keycloak service is deployed (OAuth components omitted).' -Console
        return
    }

    $manifestDir = "$PSScriptRoot\manifests\keycloak"

    switch ($Ingress) {
        'nginx' {
            if ($oauth2ProxyAvailable) {
                Write-Log '[Security] Applying nginx ingress for oauth2-proxy' -Console
                (Invoke-Kubectl -Params 'apply', '-f', "$manifestDir\nginx-ingress-oauth2-proxy.yaml").Output | Write-Log
            }
            if ($keycloakAvailable) {
                Write-Log '[Security] Applying nginx ingress for keycloak' -Console
                (Invoke-Kubectl -Params 'apply', '-f', "$manifestDir\nginx-ingress-keycloak.yaml").Output | Write-Log
            }
            break
        }
        'traefik' {
            if ($oauth2ProxyAvailable) {
                Write-Log '[Security] Applying traefik ingress and middleware for oauth2-proxy' -Console
                (Invoke-Kubectl -Params 'apply', '-f', "$manifestDir\traefik-ingress-oauth2-proxy.yaml").Output | Write-Log
            }
            if ($keycloakAvailable) {
                Write-Log '[Security] Applying traefik ingress for keycloak' -Console
                (Invoke-Kubectl -Params 'apply', '-f', "$manifestDir\traefik-ingress-keycloak.yaml").Output | Write-Log
            }
            break
        }
        'nginx-gw' {
            # ReferenceGrant is shared infrastructure required by any security HTTPRoute,
            # so it is applied whenever at least one backend is present.
            Write-Log '[nginx-gw] Applying shared ReferenceGrant for security HTTPRoutes' -Console
            (Invoke-Kubectl -Params 'apply', '-f', "$manifestDir\nginx-gw-ingress-shared.yaml").Output | Write-Log
            if ($oauth2ProxyAvailable) {
                Write-Log '[nginx-gw] Applying shared OAuth2 locations (/_auth, @oauth2_redirect)' -Console
                (Invoke-Kubectl -Params 'apply', '-f', "$manifestDir\oauth2-shared-locations.yaml").Output | Write-Log
                Write-Log '[nginx-gw] Applying HTTPRoute and authorization for oauth2-proxy' -Console
                (Invoke-Kubectl -Params 'apply', '-f', "$manifestDir\nginx-gw-ingress-oauth2-proxy.yaml").Output | Write-Log
            }
            if ($keycloakAvailable) {
                Write-Log '[nginx-gw] Applying HTTPRoute and authorization for keycloak' -Console
                (Invoke-Kubectl -Params 'apply', '-f', "$manifestDir\nginx-gw-ingress-keycloak.yaml").Output | Write-Log
            }
            break
        }
    }
}

function Remove-IngressForSecurity {
    $manifestDir = "$PSScriptRoot\manifests\keycloak"

    # Per-component split manifests (current layout)
    $manifestsToRemove = @(
        'nginx-ingress-oauth2-proxy.yaml',
        'nginx-ingress-keycloak.yaml',
        'traefik-ingress-oauth2-proxy.yaml',
        'traefik-ingress-keycloak.yaml',
        'nginx-gw-ingress-oauth2-proxy.yaml',
        'nginx-gw-ingress-keycloak.yaml',
        'nginx-gw-ingress-shared.yaml',
        'oauth2-shared-locations.yaml'
    )
    foreach ($manifest in $manifestsToRemove) {
        $path = "$manifestDir\$manifest"
        if (Test-Path $path) {
            (Invoke-Kubectl -Params 'delete', '-f', $path, '--ignore-not-found').Output | Write-Log
        }
    }
}

<#
.DESCRIPTION
Checks if Linkerd ServerAuthorization policies exist for nginx-gw ingress in security namespace.
Returns $true if both oauth2-proxy and keycloak ServerAuthorization resources exist.
#>
function Test-NginxGwServerAuthorizationExists {
    $oauth2Auth = (Invoke-Kubectl -Params 'get', 'serverauthorization', 'oauth2-proxy-allow-all', '-n', 'security', '--ignore-not-found').Output
    $keycloakAuth = (Invoke-Kubectl -Params 'get', 'serverauthorization', 'keycloak-allow-all', '-n', 'security', '--ignore-not-found').Output
    
    if ($oauth2Auth -and $keycloakAuth) {
        Write-Log '[Security] ServerAuthorization policies already exist for nginx-gw' -Console
        return $true
    }
    
    return $false
}

function Confirm-EnhancedSecurityOn([string]$Type) {
    # check content of string
    if ($Type -eq 'enhanced') {
        return $true
    }
    return $false
}

function Get-EnhancedSecurityFileLocation {
    return "$env:ProgramData\\K2s\\enhancedsecurity.json"
}

function Get-LinkerdConfigDirectory {
    return "$PSScriptRoot\manifests\linkerd"
}

function Get-LinkerdConfigCRDs {
    return "$PSScriptRoot\manifests\linkerd\linkerd-crds.yaml"
}

function Get-LinkerdConfigTrustManager {
    return "$PSScriptRoot\manifests\linkerd\trust-manager.yaml"
}

function Get-LinkerdConfigCertManager {
    return "$PSScriptRoot\manifests\linkerd\linkerd-cert-manager.yaml"
}

function Get-LinkerdConfigCNI {
    return "$PSScriptRoot\manifests\linkerd\linkerd-cni-plugin-sa.yaml"
}

function Invoke-LinkerdCliRender {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LinkerdExe,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$OutputFile,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        # Windows PowerShell 5.1 turns native stderr into formatted ErrorRecord text when 2>&1 is used, corrupting YAML output.
        $process = Start-Process `
            -FilePath $LinkerdExe `
            -ArgumentList $Arguments `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        $stderrContent = if (Test-Path $stderrFile) { Get-Content -Path $stderrFile -Raw } else { '' }
        if ($process.ExitCode -ne 0) {
            throw "[Linkerd] $Description failed with exit code $($process.ExitCode).`n$stderrContent"
        }

        $stdoutContent = if (Test-Path $stdoutFile) { Get-Content -Path $stdoutFile -Raw } else { '' }
        if ([string]::IsNullOrWhiteSpace($stdoutContent)) {
            throw "[Linkerd] $Description produced no manifest output. stderr: $stderrContent"
        }

        $sanitizedContent = $stdoutContent -replace '[^\x20-\x7E\r\n]', ''
        [System.IO.File]::WriteAllText($OutputFile, $sanitizedContent, [System.Text.UTF8Encoding]::new($false))
        Write-Log "[Linkerd] $Description succeeded, manifest written to '$OutputFile'"
    }
    finally {
        Remove-Item -Path $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

<#
.DESCRIPTION
Waits for the linkerd pods to be available.
#>
function Wait-ForLinkerdAvailable {
    # Linkerd control plane (especially linkerd-destination with 3 containers) may need
    # 1-2 restart cycles on a loaded single-node cluster before probes pass consistently.
    # 300s (5 min) allows for BackOff + restart + stabilization.
    return (Wait-ForPodCondition -Condition Ready -Label 'linkerd.io/workload-ns=linkerd' -Namespace 'linkerd' -TimeoutSeconds 300)
}

<#
.DESCRIPTION
Waits for a cert-manager Certificate resource to reach the Ready condition.
This prevents proceeding with stale or partially-issued certificates that
could cause x509 verification failures (e.g. ErrorKeyMatch race condition).
#>
function Wait-ForCertificateReady {
    param (
        [Parameter(Mandatory = $true)]
        [string]$CertificateName,
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [int]$TimeoutSeconds = 120,
        [string]$KubeToolsPath = (Get-KubeToolsPath)
    )

    $startTime = Get-Date
    $endTime = $startTime.AddSeconds($TimeoutSeconds)
    $renewAttempted = $false
    $diagnosticsLogged = $false

    while ((Get-Date) -lt $endTime) {
        try {
            $readyStatus = &"$KubeToolsPath\kubectl.exe" get certificate $CertificateName -n $Namespace -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>$null
            if ($readyStatus -eq 'True') {
                Write-Log "Certificate '$CertificateName' is Ready." -Console
                return $true
            }

            $elapsed = ((Get-Date) - $startTime).TotalSeconds

            # After 30s of empty status, check if the secret already exists with valid TLS data.
            # cert-manager may have issued the certificate but failed to update the Certificate
            # resource status (e.g. due to controller restart during rapid enable/disable cycles).
            if ($elapsed -ge 30 -and [string]::IsNullOrEmpty($readyStatus)) {
                $secretData = &"$KubeToolsPath\kubectl.exe" get secret $CertificateName -n $Namespace -o jsonpath='{.data.tls\.crt}' 2>$null
                if (-not [string]::IsNullOrEmpty($secretData)) {
                    # Validate the certificate is not expired before accepting
                    try {
                        $certBytes = [System.Convert]::FromBase64String($secretData)
                        $x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
                        $notAfter = $x509.NotAfter
                        $x509.Dispose()
                        if ($notAfter -lt (Get-Date)) {
                            Write-Log "[CertDiag] Secret for '$CertificateName' contains an expired certificate (notAfter: $notAfter). Ignoring stale secret." -Console
                        }
                        else {
                            Write-Log "Certificate '$CertificateName' status is empty but secret exists with valid TLS data (notAfter: $notAfter). Accepting as ready." -Console
                            return $true
                        }
                    }
                    catch {
                        Write-Log "[CertDiag] Could not parse certificate from secret '$CertificateName': $_. Ignoring stale secret." -Console
                    }
                }

                # Try cmctl renew to kick cert-manager into reconciling
                if (-not $renewAttempted -and $elapsed -ge 45) {
                    $renewAttempted = $true
                    $cmctlPath = Join-Path -Path $KubeToolsPath -ChildPath 'cmctl.exe'
                    if (Test-Path $cmctlPath) {
                        Write-Log "[CertDiag] Attempting cmctl renew to force reconciliation" -Console
                        &$cmctlPath renew $CertificateName -n $Namespace 2>&1 | Write-Log
                    }
                }
            }

            # After 60s of empty status, log cert-manager controller state once for diagnostics
            if ($elapsed -ge 60 -and [string]::IsNullOrEmpty($readyStatus) -and -not $diagnosticsLogged) {
                $diagnosticsLogged = $true
                $controllerPods = &"$KubeToolsPath\kubectl.exe" get pods -n cert-manager -l app=cert-manager --no-headers 2>$null
                Write-Log "[CertDiag] cert-manager controller pods: $controllerPods"
                $certDesc = &"$KubeToolsPath\kubectl.exe" get certificate $CertificateName -n $Namespace -o yaml 2>$null | Select-Object -Last 20 | Out-String
                Write-Log "[CertDiag] Certificate status: $certDesc"
            }

            Write-Log "Certificate '$CertificateName' not yet Ready (status: $readyStatus), waiting..." -Console
        }
        catch {
            Write-Log "Error checking certificate status: $_" -Console
        }
        Start-Sleep -Seconds 5
    }

    Write-Log "Certificate '$CertificateName' did not become Ready within ${TimeoutSeconds}s" -Console
    return $false
}

<#
.DESCRIPTION
Waits for a cert-manager Issuer resource to reach the Ready condition.
cert-manager cannot issue Certificates until their referenced Issuer is Ready.
#>
function Wait-ForIssuerReady {
    param (
        [Parameter(Mandatory = $true)]
        [string]$IssuerName,
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [int]$TimeoutSeconds = 60,
        [string]$KubeToolsPath = (Get-KubeToolsPath)
    )

    $startTime = Get-Date
    $endTime = $startTime.AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $endTime) {
        try {
            $readyStatus = &"$KubeToolsPath\kubectl.exe" get issuer $IssuerName -n $Namespace -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>$null
            if ($readyStatus -eq 'True') {
                Write-Log "Issuer '$IssuerName' is Ready." -Console
                return $true
            }
            Write-Log "Issuer '$IssuerName' not yet Ready (status: $readyStatus), waiting..."
        }
        catch {
            Write-Log "Error checking issuer status: $_"
        }
        Start-Sleep -Seconds 3
    }

    Write-Log "Issuer '$IssuerName' did not become Ready within ${TimeoutSeconds}s" -Console
    return $false
}

<#
.DESCRIPTION
Waits for the linkerd viz pods to be available.
#>
function Wait-ForLinkerdVizAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'linkerd.io/extension=viz' -Namespace 'linkerd-viz' -TimeoutSeconds 120)
}

function Wait-ForTrustManagerAvailable($waiTime = 120) {
    return (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=trust-manager' -Namespace 'cert-manager' -TimeoutSeconds $waiTime)
}

function Wait-ForTrustManagerWebhookReady {
    <#
    .SYNOPSIS
    Waits for trust-manager webhook to be ready to accept requests.
    .DESCRIPTION
    After trust-manager pods are ready, the webhook endpoint may still need additional time
    to become available. This function retries creating a test Bundle resource to verify
    webhook readiness before proceeding with actual cert-manager resource creation.
    .PARAMETER MaxRetries
    Maximum number of retry attempts (default: 10)
    .PARAMETER RetryDelaySeconds
    Delay between retries in seconds (default: 3)
    #>
    param(
        [int]$MaxRetries = 10,
        [int]$RetryDelaySeconds = 3
    )

    Write-Log "Waiting for trust-manager webhook to be ready (max retries: $MaxRetries)" -Console

    $testBundleYaml = @"
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: trust-manager-webhook-test
spec:
  sources:
  - useDefaultCAs: true
  target:
    configMap:
      key: trust-bundle.pem
"@

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $testBundleYaml | Out-File -FilePath $tempFile -Encoding UTF8 -Force

        for ($i = 1; $i -le $MaxRetries; $i++) {
            Write-Log "Webhook readiness check attempt $i of $MaxRetries"
            
            # Clear kubectl cache before each attempt so newly registered
            # trust-manager CRDs (Bundle) are discoverable
            $kubeCacheDir = Join-Path (Join-Path $env:USERPROFILE '.kube') 'cache'
            if (Test-Path $kubeCacheDir) {
                Write-Log '[kubectl] Clearing kubectl cache to pick up newly registered CRDs'
                Remove-Item -Recurse -Force $kubeCacheDir -ErrorAction SilentlyContinue
            }

            # Try to create the test bundle using --server-side to bypass
            # any remaining client-side discovery issues
            $result = Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '-f', $tempFile
            
            if ($result.Success) {
                Write-Log "Trust-manager webhook is ready" -Console
                # Clean up test bundle
                $null = Invoke-Kubectl -Params 'delete', '-f', $tempFile, '--ignore-not-found=true'
                return $true
            }
            
            # Check if error is webhook-related or discovery-related (CRDs not yet visible)
            if ($result.Output -match 'failed calling webhook.*trust\.cert-manager\.io|connection refused|timeout|no matches for kind') {
                Write-Log "Webhook/discovery not ready yet (attempt $i/$MaxRetries): $($result.Output). Waiting ${RetryDelaySeconds}s..."
                if ($i -lt $MaxRetries) {
                    Start-Sleep -Seconds $RetryDelaySeconds
                    continue
                }
            } else {
                # Different error - may be a real problem
                Write-Log "Unexpected error during webhook check: $($result.Output)" -Console
                return $false
            }
        }

        Write-Log "Trust-manager webhook did not become ready after $MaxRetries attempts" -Console
        return $false
    }
    finally {
        # Clean up temp file and test bundle
        if (Test-Path $tempFile) {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
        $null = Invoke-Kubectl -Params 'delete', 'bundle', 'trust-manager-webhook-test', '--ignore-not-found=true'
    }
}

function Save-LinkerdMarkerConfig {
    # write info file for enhanced security
    $jsonFile = Get-EnhancedSecurityFileLocation
    $json = "{`"SecurityType`":`"$Type`"}"
    $json | Out-File -FilePath $jsonFile     
}

function Remove-LinkerdMarkerConfig {
    # write info file for enhanced security
    $jsonFile = Get-EnhancedSecurityFileLocation
    if (Test-Path $jsonFile) {
        Remove-Item -Path $jsonFile -Force
    } 
}
function Remove-LinkerdExecutable {
    $binPath = Get-KubeBinPath
    if (Test-Path "$binPath\linkerd.exe") {
        Remove-Item -Path "$binPath\linkerd.exe" -Force
    }
}

function Remove-LinkerdManifests {
    $fileToRemove = "$PSScriptRoot\manifests\linkerd\linkerd.yaml"
    if (Test-Path $fileToRemove) {
        Remove-Item -Path $fileToRemove -Force
    }
    $fileToRemove = "$PSScriptRoot\manifests\linkerd\linkerd-crds.yaml"
    if (Test-Path $fileToRemove) {
        Remove-Item -Path $fileToRemove -Force
    }
}

function Initialize-ConfigFileForCNI {
    # Variables
    $secretName = 'cni-plugin-token'
    $kubeconfigPath = 'C:\Windows\System32\config\systemprofile\config'

    # API URL
    $apiServerUrl = (Invoke-Kubectl -Params 'config', 'view', '--minify', '-o', 'jsonpath={.clusters[0].cluster.server}').Output

    # Fetch the secret
    $secret = (Invoke-Kubectl -Params 'get', 'secret', $secretName, '--namespace', 'security', '-o', 'json').Output | ConvertFrom-Json

    # Decode base64 token and CA cert
    $token = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.data.token))
    $caCert = $secret.data.'ca.crt'

    $clusterName = Get-InstalledClusterName

    # Create the kubeconfig YAML content
    $kubeconfigContent = @"
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: $apiServerUrl
    certificate-authority-data: $caCert
  name: $clusterName

contexts:
- context:
    cluster: $clusterName
    user: cni-plugin-sa
    namespace: security
  name: service-account-context

current-context: service-account-context

users:
- name: cni-plugin-sa
  user:
      token: $token
"@

    # Write the kubeconfig content to the specified file
    $kubeconfigContent | Set-Content -Path $kubeconfigPath
}

function Remove-ConfigFileForCNI {
    $kubeconfigPath = 'C:\Windows\System32\config\systemprofile\config'
    if (Test-Path $kubeconfigPath) {
        Remove-Item -Path $kubeconfigPath -Force
    }
}

# Linkerd CLI helpers

function Get-LinkerdCliPackageFromManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ManifestPath
    )

    $manifest = Get-FromYamlFile -Path $ManifestPath
    $windowsCurlPackages = $manifest.spec.implementations[0].offline_usage.windows.curl
    if ($windowsCurlPackages) {
        foreach ($package in $windowsCurlPackages) {
            $destination = [string]$package.destination
            $url = [string]$package.url

            if ($destination -match '(?i)linkerd\.exe$' -or $url -match '(?i)linkerd2-cli') {
                return $package
            }
        }
    }

    $legacyLinkerdPackages = @($manifest.spec.implementations[0].offline_usage.windows.linkerd)
    foreach ($package in $legacyLinkerdPackages) {
        $destination = [string]$package.destination
        $url = [string]$package.url
        if ([string]::IsNullOrWhiteSpace($destination) -or [string]::IsNullOrWhiteSpace($url)) {
            continue
        }

        Write-Log '[Linkerd] Using legacy manifest key offline_usage.windows.linkerd.' -Console
        return $package
    }

    return $null
}

function Get-LinkerdVersionFromUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url
    )

    $match = [regex]::Match($Url, '/download/(?<version>[^/]+)/')
    if (-not $match.Success) {
        return $null
    }

    $version = $match.Groups['version'].Value
    if ([string]::IsNullOrWhiteSpace($version)) {
        return $null
    }

    return $version.ToLowerInvariant()
}

function Get-InstalledLinkerdCliVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ExecutablePath
    )

    if (-not (Test-Path -LiteralPath $ExecutablePath)) {
        return $null
    }

    $versionOutput = $null
    try {
        $versionOutput = & $ExecutablePath version --client --short 2>&1 | Out-String
    }
    catch {
        try {
            $versionOutput = & $ExecutablePath version 2>&1 | Out-String
        }
        catch {
            Write-Log "[Linkerd] Failed to query CLI version from '$ExecutablePath': $_" -Console
            return $null
        }
    }

    $match = [regex]::Match($versionOutput, '(?<version>(?:edge|stable)-\d+\.\d+\.\d+|v?\d+\.\d+\.\d+)')
    if (-not $match.Success) {
        Write-Log "[Linkerd] Could not parse CLI version output from '$ExecutablePath'." -Console
        return $null
    }

    return $match.Groups['version'].Value.ToLowerInvariant()
}

function Test-IsOfflineInstallationContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $K2sRoot
    )

    $offlineModeEnv = [Environment]::GetEnvironmentVariable('SYSTEM_OFFLINE_MODE')
    if ($offlineModeEnv -and $offlineModeEnv -match '^(?i:true|1|yes)$') {
        return $true
    }

    $windowsNodeArtifactsPath = Join-Path $K2sRoot 'bin\WindowsNodeArtifacts.zip'
    return (Test-Path -LiteralPath $windowsNodeArtifactsPath)
}

function Install-LinkerdCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ManifestPath,

        [Parameter(Mandatory = $true)]
        [string] $K2sRoot,

        [Parameter(Mandatory = $false)]
        [string] $Proxy
    )

    Write-Log '[Linkerd] Checking Linkerd CLI' -Console

    $package = Get-LinkerdCliPackageFromManifest -ManifestPath $ManifestPath
    if (-not $package) {
        Write-Log "[Linkerd] No Linkerd CLI package entry found in '$ManifestPath'. Skipping CLI install." -Console
        return
    }

    $destination = Join-Path $K2sRoot ([string]$package.destination)
    $destination = [System.IO.Path]::GetFullPath($destination)
    $url = [string]$package.url

    $expectedVersion = Get-LinkerdVersionFromUrl -Url $url
    if ($expectedVersion) {
        Write-Log "[Linkerd] Expected CLI version from manifest URL: '$expectedVersion'." -Console
    }
    else {
        Write-Log '[Linkerd] Could not parse expected CLI version from manifest URL. Keeping backward compatible install behavior.' -Console
    }

    if (Test-Path -LiteralPath $destination) {
        if (-not $expectedVersion) {
            Write-Log "[Linkerd] CLI already present at '$destination'. Skipping download." -Console
            return
        }

        $installedVersion = Get-InstalledLinkerdCliVersion -ExecutablePath $destination
        if ($installedVersion -and $installedVersion -eq $expectedVersion) {
            Write-Log "[Linkerd] CLI already present at '$destination' with expected version '$installedVersion'." -Console
            return
        }

        if ($installedVersion) {
            Write-Log "[Linkerd] Refreshing CLI from version '$installedVersion' to '$expectedVersion'." -Console
        }
        else {
            Write-Log "[Linkerd] Refreshing CLI because the cached binary version could not be verified; expected '$expectedVersion'." -Console
        }
    }

    $isOfflineInstallation = Test-IsOfflineInstallationContext -K2sRoot $K2sRoot
    try {
        Write-Log "[Linkerd] Downloading Linkerd CLI from '$url'." -Console
        Invoke-DownloadFile $destination $url $true -ProxyToUse $Proxy
        Write-Log "[Linkerd] CLI installed to '$destination'." -Console
    }
    catch {
        if ($isOfflineInstallation) {
            throw "[Linkerd] Failed to obtain linkerd.exe. The offline package may be outdated or missing linkerd.exe for the security addon. Re-export and re-import the security addon package, then retry. Original error: $($_.Exception.Message)"
        }

        throw
    }
}

# Kyverno policy engine helpers

function Get-KyvernoVersionFromUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url
    )

    $match = [regex]::Match($Url, '/download/(?<version>v?\d+\.\d+\.\d+)/')
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups['version'].Value.TrimStart('v')
}

function Get-InstalledKyvernoCliVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ExecutablePath
    )

    if (-not (Test-Path -LiteralPath $ExecutablePath)) {
        return $null
    }

    try {
        $versionOutput = & $ExecutablePath version 2>&1 | Out-String
    }
    catch {
        Write-Log "[Kyverno] Failed to query CLI version from '$ExecutablePath': $_" -Console
        return $null
    }

    $match = [regex]::Match($versionOutput, 'v?(?<version>\d+\.\d+\.\d+)')
    if (-not $match.Success) {
        Write-Log "[Kyverno] Could not parse CLI version output from '$ExecutablePath'." -Console
        return $null
    }

    return $match.Groups['version'].Value
}

function Install-KyvernoCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ManifestPath,

        [Parameter(Mandatory = $true)]
        [string] $K2sRoot,

        [Parameter(Mandatory = $false)]
        [string] $Proxy
    )

    Write-Log '[Kyverno] Checking Kyverno CLI' -Console

    $manifest = Get-FromYamlFile -Path $ManifestPath
    $impl = $manifest.spec.implementations[0]
    # Kyverno CLI is listed in the windows curl section (alongside cmctl)
    $windowsCurlPackages = $impl.offline_usage.windows.curl
    if (!$windowsCurlPackages) { return }

    foreach ($package in $windowsCurlPackages) {
        if ($package.url -notmatch 'kyverno') { continue }

        $destination = "$K2sRoot\$($package.destination)"
        $destination = [System.IO.Path]::GetFullPath($destination)
        $expectedVersion = Get-KyvernoVersionFromUrl -Url $package.url

        if (Test-Path -LiteralPath $destination) {
            $installedVersion = Get-InstalledKyvernoCliVersion -ExecutablePath $destination
            if ($expectedVersion -and $installedVersion -eq $expectedVersion) {
                Write-Log "[Kyverno] CLI already present at '$destination' with expected version '$installedVersion'." -Console
                continue
            }

            if ($expectedVersion -and $installedVersion) {
                Write-Log "[Kyverno] Refreshing CLI from version '$installedVersion' to '$expectedVersion'." -Console
            }
            elseif ($expectedVersion) {
                Write-Log "[Kyverno] Refreshing CLI because the cached binary version could not be verified; expected '$expectedVersion'." -Console
            }
            else {
                Write-Log '[Kyverno] Refreshing CLI because the expected version could not be determined from the manifest URL.' -Console
            }
        }

        Write-Log "[Kyverno] Downloading Kyverno CLI from '$($package.url)'..." -Console
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("k2s-kyverno-{0}" -f [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $archiveName = [IO.Path]::GetFileName($package.url)
            $tmpArchive = Join-Path $tmp $archiveName

            Invoke-DownloadFile $tmpArchive $package.url $true -ProxyToUse $Proxy
            Write-Log '[Kyverno] Download complete. Extracting...'

            if (Get-Command -Name Expand-ZipWithProgress -ErrorAction SilentlyContinue) {
                Expand-ZipWithProgress -ZipPath $tmpArchive -Destination $tmp
            }
            else {
                Expand-Archive -LiteralPath $tmpArchive -DestinationPath $tmp -Force
            }

            $exe = Get-ChildItem -Path $tmp -Filter 'kyverno.exe' -Recurse -File | Select-Object -First 1
            if (-not $exe) { throw 'kyverno.exe not found in downloaded archive.' }

            $destDir = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

            Copy-Item -LiteralPath $exe.FullName -Destination $destination -Force
            Write-Log "[Kyverno] CLI installed to '$destination'." -Console
        }
        finally {
            Remove-Item -LiteralPath $tmp -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}

function Install-Kyverno {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string] $Proxy,

        [Parameter(Mandatory = $false)]
        [switch] $EnhancedSecurity = $false
    )

    $kyvernoNamespace = 'kyverno'
    $charts = @(Get-ChildItem -Path "$PSScriptRoot\manifests\kyverno" -Filter 'kyverno-*.tgz' -ErrorAction SilentlyContinue)
    if ($charts.Count -eq 0) { throw '[Kyverno] No Helm chart .tgz found in manifests/kyverno/' }
    $chartPath = $charts[0].FullName
    $valuesPath = "$PSScriptRoot\manifests\kyverno\values.yaml"

    Write-Log '[Kyverno] Creating namespace' -Console
    $existingNs = (Invoke-Kubectl -Params 'get', 'namespace', $kyvernoNamespace, '--ignore-not-found', '-o', 'name').Output
    if (-not $existingNs) {
        (Invoke-Kubectl -Params 'create', 'namespace', $kyvernoNamespace).Output | Write-Log
    } else {
        Write-Log "[Kyverno] Namespace '$kyvernoNamespace' already exists" -Console
    }

    if ($EnhancedSecurity) {
        Write-Log '[Kyverno] Enhanced security: adding namespace to the Linkerd mesh' -Console
        (Invoke-Kubectl -Params 'annotate', 'namespace', $kyvernoNamespace, 'linkerd.io/inject=enabled', '--overwrite').Output | Write-Log
        (Invoke-Kubectl -Params 'annotate', 'namespace', $kyvernoNamespace, 'config.linkerd.io/skip-inbound-ports=9443', '--overwrite').Output | Write-Log
    }

    Write-Log '[Kyverno] Waiting for API server to be ready before Helm install...' -Console
    $apiReady = $false
    for ($apiAttempt = 1; $apiAttempt -le 12; $apiAttempt++) {
        $readyz = (Invoke-Kubectl -Params 'get', '--raw', '/readyz').Output
        if ($readyz -match 'ok') {
            $apiReady = $true
            Write-Log '[Kyverno] API server is ready' -Console
            break
        }
        Write-Log "[Kyverno] API server not ready yet (attempt $apiAttempt/12), waiting 10s..." -Console
        Start-Sleep -Seconds 10
    }
    if (-not $apiReady) {
        Write-Log '[Kyverno] Warning: API server did not report ready within 120s; proceeding anyway' -Console
    }

    Write-Log '[Kyverno] Installing via Helm' -Console
    $helmArgs = @('upgrade', '--install', 'kyverno', $chartPath, '-n', $kyvernoNamespace, '-f', $valuesPath, '--timeout', '10m')

    $staleReleaseCheck = Invoke-Helm -Params @('status', 'kyverno', '-n', $kyvernoNamespace, '-o', 'json')
    if ($staleReleaseCheck.Success) {
        try {
            $releaseStatus = ($staleReleaseCheck.Output | Out-String | ConvertFrom-Json).info.status
        } catch {
            $releaseStatus = 'unknown'
        }
        if ($releaseStatus -notin @('deployed', 'superseded')) {
            Write-Log "[Kyverno] Found Helm release in state '$releaseStatus', purging before install to ensure clean state" -Console
            $uninstallResult = Invoke-Helm -Params @('uninstall', 'kyverno', '-n', $kyvernoNamespace, '--no-hooks', '--wait')
            $uninstallResult.Output | Write-Log
            if (-not $uninstallResult.Success) {
                Write-Log '[Kyverno] Warning: pre-clean uninstall failed, proceeding with install attempt' -Console
            }
        }
    }

    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $result = Invoke-Helm -Params $helmArgs
        $result.Output | Write-Log

        if ($result.Success -eq $true) {
            break
        }

        $outputText = ($result.Output | ForEach-Object { "$_" }) -join "`n"
        $isRetryable = $outputText -match 'provided IP is already allocated|context deadline exceeded|has no deployed releases|unable to continue with install: could not get information about the resource|server was unable to return a response in the time allotted|etcdserver: request timed out'
        if ($attempt -lt $maxAttempts -and $isRetryable) {
            $reason = switch -Regex ($outputText) {
                'provided IP is already allocated' { 'ClusterIP allocation conflict'; break }
                'context deadline exceeded'        { 'API server context deadline exceeded'; break }
                'has no deployed releases'         { 'stale pending-install Helm secret (no base release)'; break }
                'could not get information about the resource|server was unable to return a response in the time allotted' { 'API server timeout while resolving CRDs'; break }
                'etcdserver: request timed out'    { 'etcd request timeout'; break }
                default                            { 'transient Helm error' }
            }
            Write-Log "[Kyverno] Helm install attempt $attempt/$maxAttempts failed ($reason) -- purging and retrying" -Console

            $purgeResult = Invoke-Helm -Params @('uninstall', 'kyverno', '-n', $kyvernoNamespace, '--no-hooks')
            $purgeResult.Output | Write-Log
            if (-not $purgeResult.Success) {
                Write-Log '[Kyverno] helm uninstall failed; falling back to direct Helm secret deletion' -Console
                (Invoke-Kubectl -Params 'delete', 'secret', '-n', $kyvernoNamespace,
                    '-l', 'owner=helm,name=kyverno', '--ignore-not-found').Output | Write-Log
            }

            # Delete stale services to release ClusterIPs before retry
            Write-Log "[Kyverno] Deleting services in namespace '$kyvernoNamespace' to release ClusterIPs..." -Console
            (Invoke-Kubectl -Params 'delete', 'svc', '--all', '-n', $kyvernoNamespace, '--force', '--grace-period=0', '--ignore-not-found').Output | Write-Log

            # Wait for services to be fully removed (ClusterIP allocator releases IPs)
            $waitMax = 30
            for ($w = 0; $w -lt $waitMax; $w++) {
                $svcs = (Invoke-Kubectl -Params 'get', 'svc', '-n', $kyvernoNamespace, '--no-headers', '--ignore-not-found').Output
                if ([string]::IsNullOrWhiteSpace($svcs)) {
                    Write-Log '[Kyverno] All services deleted, ClusterIPs released' -Console
                    break
                }
                Write-Log "[Kyverno] Waiting for service cleanup... ($w/$waitMax)" -Console
                Start-Sleep -Seconds 1
            }
            Start-Sleep -Seconds 5  # Allow ClusterIP allocator to fully sync
            continue
        }

        throw "[Kyverno] Helm install failed: $($result.Output)"
    }

    if ($EnhancedSecurity -and $existingNs) {
        Write-Log '[Kyverno] Enhanced security: restarting Kyverno controllers to inject the Linkerd sidecar' -Console
        (Invoke-Kubectl -Params 'rollout', 'restart', 'deployment', '-n', $kyvernoNamespace).Output | Write-Log
    }

    Write-Log '[Kyverno] Waiting for Kyverno controllers to be ready (up to 1200s)...' -Console
    # After a Helm retry, old pods from the failed attempt may still be in Terminating state.
    # kubectl wait picks up ALL pods matching the label (including Terminating ones) and will
    # never succeed for them. Wait for terminating pods to fully disappear first.
    $terminatingWaitMax = 60
    for ($tw = 0; $tw -lt $terminatingWaitMax; $tw++) {
        # Use jsonpath to find pods with a deletionTimestamp (= Terminating).
        # This avoids false positives on Pending/ContainerCreating pods from the new install.
        $terminatingPods = (Invoke-Kubectl -Params 'get', 'pods', '-n', $kyvernoNamespace,
            '-l', 'app.kubernetes.io/instance=kyverno',
            '-o', 'jsonpath={.items[?(@.metadata.deletionTimestamp)].metadata.name}',
            '--ignore-not-found').Output
        if ([string]::IsNullOrWhiteSpace($terminatingPods)) {
            Write-Log '[Kyverno] No terminating pods found, proceeding with readiness wait' -Console
            break
        }
        if ($tw % 10 -eq 0) {
            Write-Log "[Kyverno] Waiting for terminating pods to clear ($tw/$terminatingWaitMax): $terminatingPods" -Console
        }
        Start-Sleep -Seconds 2
    }
    if ($tw -ge $terminatingWaitMax) {
        Write-Log '[Kyverno] Warning: terminating pods did not clear within 120s, proceeding anyway' -Console
    }

    # The admission-controller pod needs its TLS certificate secret
    # (kyverno-svc.kyverno.svc.kyverno-tls-pair) to pass startup probes.
    # When cert-manager is under load (serving linkerd, ingress, trust-manager),
    # TLS provisioning can take 12-15 minutes. Use 1200s to provide headroom.
    $kyvernoReady = Wait-ForKyvernoAvailable -TimeoutSeconds 1200
    if (-not $kyvernoReady) {
        throw '[Kyverno] Controllers did not become ready within 1200s. Check kubectl describe pod -n kyverno for details.'
    }

    # Apply bundled/user-provided policies (webhook is now live).
    $policiesDir = "$PSScriptRoot\manifests\kyverno\policies"
    $policyFiles = @(Get-ChildItem -Path $policiesDir -Filter '*.yaml' -ErrorAction SilentlyContinue)
    if ($policyFiles.Count -gt 0) {
        Write-Log "[Kyverno] Applying $($policyFiles.Count) policy file(s) from policies directory" -Console
        foreach ($policyFile in $policyFiles) {
            Write-Log "[Kyverno] Applying policy: $($policyFile.Name)" -Console
            $applyResult = Invoke-Kubectl -Params 'apply', '--server-side', '-f', $policyFile.FullName
            $applyResult.Output | Write-Log
            if (-not $applyResult.Success) {
                Write-Log "[Kyverno] Warning: failed to apply $($policyFile.Name): $($applyResult.Output)" -Console
            }
        }
    } else {
        Write-Log '[Kyverno] No policy files in policies directory, skipping' -Console
    }

    Write-Log '[Kyverno] Installation complete' -Console
}

function Uninstall-Kyverno {
    [CmdletBinding()]
    param()

    $kyvernoNamespace = 'kyverno'

    # Delete policies first while webhook is live; avoids cleanup deadlock.
    Write-Log '[Kyverno] Removing policies and exceptions first' -Console
    (Invoke-Kubectl -Params 'delete', 'clusterpolicies', '--all', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'policies', '--all', '--all-namespaces', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'policyexceptions', '--all', '--all-namespaces', '--ignore-not-found').Output | Write-Log

    Write-Log '[Kyverno] Removing webhook configurations' -Console
    (Invoke-Kubectl -Params 'delete', 'mutatingwebhookconfiguration', '-l', 'webhook.kyverno.io/managed-by=kyverno', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'validatingwebhookconfiguration', '-l', 'webhook.kyverno.io/managed-by=kyverno', '--ignore-not-found').Output | Write-Log

    Write-Log '[Kyverno] Uninstalling via Helm' -Console
    $result = Invoke-Helm -Params @('uninstall', 'kyverno', '-n', $kyvernoNamespace, '--no-hooks')
    $result.Output | Write-Log
    if ($result.Success -ne $true) {
        Write-Log "[Kyverno] Helm uninstall returned a non-success result: $($result.Output)" -Console
    }

    Write-Log '[Kyverno] Removing CRDs (Helm does not delete them)' -Console
    $crds = (Invoke-Kubectl -Params 'get', 'crd', '-o', 'name').Output
    $kyvernoCrds = if ($crds) { $crds -split "`n" | Where-Object { $_ -match 'kyverno\.io' } } else { @() }
    foreach ($crd in $kyvernoCrds) {
        (Invoke-Kubectl -Params 'delete', $crd, '--ignore-not-found').Output | Write-Log
    }

    Write-Log '[Kyverno] Removing namespace' -Console
    # Log services and their ClusterIPs before namespace deletion for diagnostics
    Write-Log '[Kyverno] Services before namespace deletion:' -Console
    (Invoke-Kubectl -Params 'get', 'svc', '-n', $kyvernoNamespace, '-o', 'wide', '--ignore-not-found').Output | Write-Log

    (Invoke-Kubectl -Params 'delete', 'namespace', $kyvernoNamespace, '--ignore-not-found').Output | Write-Log

    Write-Log '[Kyverno] Waiting for namespace deletion to complete' -Console
    $retries = 0
    $maxRetries = 60
    while ($retries -lt $maxRetries) {
        $ns = (Invoke-Kubectl -Params 'get', 'namespace', $kyvernoNamespace, '--ignore-not-found', '-o', 'name').Output
        if (-not $ns) {
            Write-Log "[Kyverno] Namespace deleted successfully after $($retries * 2)s" -Console
            break
        }
        if ($retries % 5 -eq 0) {
            # Log remaining resources every 10s to diagnose stuck finalizers
            $remaining = (Invoke-Kubectl -Params 'get', 'all', '-n', $kyvernoNamespace, '--ignore-not-found', '-o', 'name').Output
            Write-Log "[Kyverno] Namespace still terminating (attempt $($retries + 1)/$maxRetries), remaining resources: $remaining" -Console
        }
        Start-Sleep -Seconds 2
        $retries++
    }
    if ($retries -ge $maxRetries) {
        Write-Log '[Kyverno] Warning: namespace deletion did not complete within 120s -- proceeding anyway' -Console
        # Log namespace status for post-mortem analysis
        (Invoke-Kubectl -Params 'get', 'namespace', $kyvernoNamespace, '-o', 'yaml', '--ignore-not-found').Output | Write-Log
    }

    # Allow K8s ClusterIP allocator bitmap to release IPs freed by namespace deletion.
    Write-Log '[Kyverno] Waiting 10s for ClusterIP allocator to sync after namespace deletion' -Console
    Start-Sleep -Seconds 10

    Write-Log '[Kyverno] Uninstallation complete' -Console
}

<#
.DESCRIPTION
Waits for all Kyverno controller pods to become Ready.
#>
function Wait-ForKyvernoAvailable {
    param(
        [int] $TimeoutSeconds = 300
    )

    $labels = @(
        'app.kubernetes.io/component=admission-controller',
        'app.kubernetes.io/component=background-controller',
        'app.kubernetes.io/component=cleanup-controller',
        'app.kubernetes.io/component=reports-controller'
    )

    foreach ($label in $labels) {
        $result = Wait-ForPodCondition -Condition Ready -Label $label -Namespace 'kyverno' -TimeoutSeconds $TimeoutSeconds
        if ($result -ne $true) {
            Write-Log "[Kyverno] Pods with label '$label' did not become ready within $TimeoutSeconds seconds." -Console
            return $false
        }
    }
    return $true
}

<#
.DESCRIPTION
Tests if the Kyverno admission controller deployment exists.
#>
function Test-KyvernoServiceAvailability {
    $deployment = (Invoke-Kubectl -Params 'get', 'deployment', '-n', 'kyverno', '-l', 'app.kubernetes.io/component=admission-controller', '--ignore-not-found', '-o', 'name').Output
    return ($null -ne $deployment -and $deployment -match 'deployment')
}
