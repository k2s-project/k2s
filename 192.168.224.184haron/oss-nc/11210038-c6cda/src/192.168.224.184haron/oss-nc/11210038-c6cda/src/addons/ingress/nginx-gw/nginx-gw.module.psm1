# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Contains common methods for installing and uninstalling nginx-gw
#>
function Get-ExternalDnsConfigDir {
    return "$PSScriptRoot\..\..\common\manifests\external-dns"
}

function Get-NginxGatewayYamlDir {
    return "$PSScriptRoot\manifests"
}

function Get-NginxGatewayCrdsDir {
    return "$PSScriptRoot\manifests\crds"
}

<#
.DESCRIPTION
Determines if the security service is deployed in the cluster
#>
function Test-SecurityAddonAvailability {
    $existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'security', '-o', 'yaml').Output
    if ("$existingServices" -match '.* keycloak .*') {
        return $true
    }
    return $false
}

<#
.SYNOPSIS
Creates TLS certificate for nginx-gw using cert-manager

.DESCRIPTION
Installs temporary cert-manager instance to create self-signed TLS certificate,
then removes cert-manager to avoid conflicts with security addon.
Only runs when security addon is NOT enabled.

.PARAMETER Namespace
The namespace where the TLS secret should be created

.PARAMETER SecretName
The name of the TLS secret to create

.PARAMETER DnsName
The DNS name for the certificate (default: k2s.cluster.local)
#>
function New-TlsCertificateWithCertManager {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        
        [Parameter(Mandatory = $false)]
        [string]$SecretName = 'k2s-cluster-local-tls',
        
        [Parameter(Mandatory = $false)]
        [string]$DnsName = 'k2s.cluster.local'
    )
    
    Write-Log "Creating TLS certificate '$SecretName' in namespace '$Namespace'" -Console
    
    try {
        # Apply Certificate resource
        Write-Log 'Creating Certificate resource for self-signed certificate' -Console
        $certificateYaml = "$PSScriptRoot\manifests\k2s-cluster-local-tls-certificate.yaml"
        
        if (-not (Test-Path $certificateYaml)) {
            Write-Log "Error: Certificate manifest not found at $certificateYaml" -Error
            return $false
        }
        
        (Invoke-Kubectl -Params 'apply', '-f', $certificateYaml).Output | Write-Log
        
        # Wait for certificate to be issued and secret to be created
        Write-Log 'Waiting for cert-manager to issue certificate and create secret...' -Console
        $maxRetries = 30
        $retryCount = 0
        $certificateIssued = $false
        
        while ($retryCount -lt $maxRetries) {
            $secretCheck = (Invoke-Kubectl -Params 'get', 'secret', $SecretName, '-n', $Namespace, '--ignore-not-found').Output
            if (-not [string]::IsNullOrWhiteSpace($secretCheck)) {
                $certificateIssued = $true
                Write-Log "Certificate issued successfully - Secret '$SecretName' created" -Console
                break
            }
            
            Start-Sleep -Seconds 2
            $retryCount++
        }
        
        if (-not $certificateIssued) {
            Write-Log "Warning: Timeout waiting for certificate issuance after $($maxRetries * 2) seconds" -Console
            Write-Log "Check status with: kubectl describe certificate $SecretName -n $Namespace" -Console
            return $false
        }
        return $true
    }
    catch {
        Write-Log "Error creating TLS certificate: $_" -Error
        return $false
    }
}

<#
.SYNOPSIS
Enables SnippetsFilter support in NGINX Gateway Fabric controller.
.DESCRIPTION
Patches the nginx-gw-controller deployment to add --snippets-filters flag
and adds necessary RBAC permissions to the ClusterRole. This is required
for OAuth2 authentication with SnippetsFilter resources.
.EXAMPLE
Enable-NginxGatewaySnippetsFilter
#>
function Enable-NginxGatewaySnippetsFilter {
    [CmdletBinding()]
    param()

    Write-Log 'Enabling SnippetsFilter support for OAuth2 authentication' -Console

    # Check if deployment exists
    $deployment = kubectl get deployment nginx-gw-controller -n nginx-gw -o json 2>$null | ConvertFrom-Json
    if (-not $deployment) {
        Write-Log '  NGINX Gateway controller deployment not found, skipping SnippetsFilter setup' -Console
        return
    }

    # Check if --snippets-filters flag already exists
    $args = $deployment.spec.template.spec.containers[0].args
    if ($args -contains '--snippets-filters') {
        Write-Log '  SnippetsFilter flag already enabled' -Console
    } else {
        Write-Log '  Adding --snippets-filters flag to controller' -Console
        
        # Create temporary patch file to avoid PowerShell JSON escaping issues
        $deploymentPatchFile = [System.IO.Path]::GetTempFileName()
        $deploymentPatch = '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--snippets-filters"}]'
        Set-Content -Path $deploymentPatchFile -Value $deploymentPatch -NoNewline
        
        kubectl patch deployment nginx-gw-controller -n nginx-gw --type=json --patch-file $deploymentPatchFile 2>&1 | Write-Log
        Remove-Item -Path $deploymentPatchFile -Force
    }

    # Check if ClusterRole has snippetsfilters permissions
    $clusterRole = kubectl get clusterrole nginx-gw-controller -o json 2>$null | ConvertFrom-Json
    $hasSnippetsFilterPermission = $false

    foreach ($rule in $clusterRole.rules) {
        if ($rule.apiGroups -contains 'gateway.nginx.org' -and $rule.resources -contains 'snippetsfilters') {
            $hasSnippetsFilterPermission = $true
            break
        }
    }

    if ($hasSnippetsFilterPermission) {
        Write-Log '  SnippetsFilter RBAC permissions already configured' -Console
    } else {
        Write-Log '  Adding SnippetsFilter RBAC permissions' -Console
        
        # Create temporary patch file to avoid PowerShell JSON escaping issues
        $clusterRolePatchFile = [System.IO.Path]::GetTempFileName()
        $clusterRolePatch = '[{"op":"add","path":"/rules/-","value":{"apiGroups":["gateway.nginx.org"],"resources":["snippetsfilters"],"verbs":["list","watch"]}}]'
        Set-Content -Path $clusterRolePatchFile -Value $clusterRolePatch -NoNewline
        
        kubectl patch clusterrole nginx-gw-controller --type=json --patch-file $clusterRolePatchFile 2>&1 | Write-Log
        Remove-Item -Path $clusterRolePatchFile -Force
        
        Write-Log '  Restarting controller pod to apply changes' -Console
        kubectl delete pod -l app.kubernetes.io/name=nginx-gw -n nginx-gw 2>&1 | Write-Log
    }

    Write-Log 'SnippetsFilter support enabled for NGINX Gateway' -Console
}

Export-ModuleMember -Function Get-ExternalDnsConfigDir, Get-NginxGatewayYamlDir, Get-NginxGatewayCrdsDir, Test-SecurityAddonAvailability, New-TlsCertificateWithCertManager, Enable-NginxGatewaySnippetsFilter
