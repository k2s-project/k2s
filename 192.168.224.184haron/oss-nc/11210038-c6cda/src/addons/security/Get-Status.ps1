# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$securityModule = "$PSScriptRoot\security.module.psm1"

Import-Module $addonsModule, $securityModule

$certManagerAvailable = Wait-ForCertManagerAvailable -WaitTimeout '30s'
$certManagerProp = @{Name = 'IsCertManagerAvailable'; Value = $certManagerAvailable; Okay = $certManagerAvailable }
if ($certManagerProp.Value -eq $true) {
    $certManagerProp.Message = 'The cert-manager API is ready'
}
else {
    $certManagerProp.Message = 'The cert-manager API is not ready. Please use cmctl.exe for further diagnostics.'
} 

$caRootCertificateAvailable = Wait-ForCARootCertificate
$caRootCertificateProp = @{Name = 'IsCaRootCertificateAvailable'; Value = $caRootCertificateAvailable; Okay = $caRootCertificateAvailable }
if ($caRootCertificateProp.Value -eq $true) {
    $caRootCertificateProp.Message = 'The CA root certificate is available'
}
else {
    $caRootCertificateProp.Message = "The CA root certificate is not available ('ca-issuer-root-secret' not created)."
} 

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
$securityProp = @{Name = 'Type of security'; Value = $EnancedSecurityEnabled; Okay = $certManagerAvailable }
$linkerdProp = @{Name = 'Type of security'; Value = $EnancedSecurityEnabled; Okay = $EnancedSecurityEnabled  }
if ($certManagerAvailable) {
    if ($EnancedSecurityEnabled) {
        $securityProp.Message = 'Type of security: enhanced'
        $linkerdProp.Message = 'The linkerd API is ready'
    } else {
        $securityProp.Message = 'Type of security: basic' 
        $linkerdProp.Message = 'The linkerd API is not available because of basic security'
    }
} else {
    $securityProp.Message = 'Type of security: none'
    $linkerdProp.Message = 'The linkerd API is not available'
}

$trustManagerAvailable = Test-TrustManagerServiceAvailability
$trustManagerProp = @{Name = 'IsTrustManagerAvailable'; Value = $trustManagerAvailable; Okay = $trustManagerAvailable }
if ($trustManagerProp.Value -eq $true) {
    $trustManagerProp.Message = 'The trust-manager API is ready'
}
else {
    $trustManagerProp.Message = 'The trust-manager API is not available because of basic security'
}

$keycloakAvailable = Test-KeyCloakServiceAvailability
$keycloakProp = @{Name = 'IsKeycloakAvailable'; Value = $keycloakAvailable; Okay = $keycloakAvailable }
if ($keycloakProp.Value -eq $true) {
    $keycloakProp.Message = 'The keycloak API is ready'
}
else {
    $keycloakProp.Message = 'The keycloak API is not ready or was omitted with -OmitKeycloak'
}

# Check for hydra deployment (optional)
$hydraDeployment = (Invoke-Kubectl -Params '-n', 'security', 'get', 'deployment', 'hydra', '--ignore-not-found').Output
$hydraAvailable = $false
if ($hydraDeployment -and $hydraDeployment -notmatch 'NotFound') {
    $hydraAvailable = $true
}
$hydraProp = @{Name = 'IsHydraAvailable'; Value = $hydraAvailable; Okay = $hydraAvailable }
if ($hydraProp.Value -eq $true) {
    $hydraProp.Message = 'The hydra API is ready'
} else {
    $hydraProp.Message = 'The hydra API is not deployed (possibly omitted with -OmitHydra)'
}

# Check for OAuth2 proxy deployment (optional)
$oauth2ProxyAvailable = Test-OAuth2ProxyServiceAvailability
$oauth2ProxyProp = @{Name = 'IsOAuth2ProxyAvailable'; Value = $oauth2ProxyAvailable; Okay = $oauth2ProxyAvailable }
if ($oauth2ProxyProp.Value -eq $true) {
    $oauth2ProxyProp.Message = 'The OAuth2 proxy is ready'
} else {
    $oauth2ProxyProp.Message = 'The OAuth2 proxy is not deployed (possibly omitted with -OmitOAuth2Proxy)'
}

# Check for Kyverno deployment (optional)
$kyvernoAvailable = Test-KyvernoServiceAvailability
$kyvernoProp = @{Name = 'IsKyvernoAvailable'; Value = $kyvernoAvailable; Okay = $kyvernoAvailable }
if ($kyvernoProp.Value -eq $true) {
    $kyvernoProp.Message = 'The Kyverno policy engine is ready'
} else {
    $kyvernoProp.Message = 'The Kyverno policy engine is not deployed (possibly omitted with -OmitPolicyEnf)'
}

return $securityProp, $certManagerProp, $caRootCertificateProp, $keycloakProp, $hydraProp, $oauth2ProxyProp, $trustManagerProp, $linkerdProp, $kyvernoProp
