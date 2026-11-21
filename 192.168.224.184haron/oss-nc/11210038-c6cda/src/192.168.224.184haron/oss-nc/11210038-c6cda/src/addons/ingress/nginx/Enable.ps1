# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables ingress nginx in the cluster to the ingress-nginx namespace

.DESCRIPTION
Ingress nginx is using k8s load balancer and is bound to the IP of the master machine.
It allows applications to register their ingress resources and handles incoming HTTP/HTPPS traffic.

.EXAMPLE
# For k2sSetup
powershell <installation folder>\addons\ingress\nginx\Enable.ps1
#>
Param(
    [string] $InfraNodeSelector = '',
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'Omit cert-manager installation')]
    [switch] $OmitCertMgr = $false
)
$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$nginxModule = "$PSScriptRoot\nginx.module.psm1"
$dashboardModule = "$PSScriptRoot\..\..\dashboard\dashboard.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $nginxModule

Initialize-Logging -ShowLogs:$ShowLogs
trap { if ($EncodeStructuredOutput) { Send-ToCli -MessageType $MessageType -Message @{Error = (New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $_.Exception.Message)}; return }; throw }
$ownerOptions = Get-AddonPlacementOwnerOptions -Name 'ingress' -Implementation 'nginx' -BoundParameters $PSBoundParameters -Defaults @{OmitCertMgr = $OmitCertMgr.IsPresent}
$OmitCertMgr = [switch]$ownerOptions.OmitCertMgr
$InfraNodeSelector = Get-AddonEffectiveInfrastructureSelector -Name 'ingress' -Implementation 'nginx' -Selector $InfraNodeSelector

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
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'ingress nginx' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

Write-Log 'Checking if ingress nginx is already enabled'

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx' })) -eq $true) {
    $errMsg = "Addon 'ingress nginx' is already enabled, nothing to do."

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

$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'ingress-nginx', '-o', 'yaml').Output
$retryIntent = Test-AddonPlacementIntent -Name 'ingress' -Implementation 'nginx' -Selector $InfraNodeSelector
if ("$existingServices" -match '.*ingress-nginx-controller.*' -and -not $retryIntent) {
    $errMsg = 'It seems as if ingress nginx is already installed in the namespace ingress-nginx. Disable it before enabling it again.'
    
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Installing ExternalDNS' -Console
Assert-SharedInfrastructurePlacement -Name 'external-dns' -Selector $InfraNodeSelector -Namespace 'external-dns' -Deployment 'external-dns'
if (-not $OmitCertMgr) { Assert-SharedInfrastructurePlacement -Name 'cert-manager' -Selector $InfraNodeSelector -Namespace 'cert-manager' -Deployment 'cert-manager' }
if ($InfraNodeSelector) {
    Assert-AddonPlacementHost -Selector $InfraNodeSelector -NodeName (Get-ConfigControlPlaneNodeHostname) -Reason 'ingress external IP and local traffic policy'
    $preflight = New-AddonPlacementInput -AddonName 'ingress' -Path (Get-IngressNginxConfig) -Selector $InfraNodeSelector
    Remove-Item -LiteralPath $preflight.Path -Force -ErrorAction SilentlyContinue
    Set-AddonPlacementIntent -Addon ([pscustomobject]@{Name = 'ingress'; Implementation = 'nginx'; InfraNodeSelector = $InfraNodeSelector; OmitCertMgr = $OmitCertMgr.IsPresent})
}
$externalDnsConfig = Get-ExternalDnsConfigDir
(Invoke-AddonOwnedApply -AddonName 'externaldns' -Path $externalDnsConfig -Selector $InfraNodeSelector -Kustomize).Output | Write-Log
if ($InfraNodeSelector) { Set-SharedInfrastructurePlacement -Name 'external-dns' -Selector $InfraNodeSelector }

if (-not $OmitCertMgr) {
    Write-Log 'Installing cert-manager' -Console
    Enable-CertManager -Proxy $Proxy -EncodeStructuredOutput:$EncodeStructuredOutput -MessageType:$MessageType -InfraNodeSelector $InfraNodeSelector
}
else {
    Write-Log '[ingress nginx] Skipping cert-manager installation (--omitCertMgr)' -Console
}

Write-Log 'Installing ingress nginx' -Console
$ingressNginxNamespace = 'ingress-nginx'
$ingressNginxConfig = Get-IngressNginxConfig

(Invoke-Kubectl -Params 'create', 'ns', $ingressNginxNamespace).Output | Write-Log
(Invoke-AddonOwnedApply -AddonName 'ingress' -Path $ingressNginxConfig -Selector $InfraNodeSelector).Output | Write-Log

$controlPlaneIp = Get-ConfiguredIPControlPlane

Write-Log "Setting $controlPlaneIp as an external IP for ingress-nginx-controller service" -Console
$patchJson = ''
if ($PSVersionTable.PSVersion.Major -gt 5) {
    $patchJson = '{"spec":{"externalIPs":["' + $controlPlaneIp + '"]}}'
}
else {
    $patchJson = '{\"spec\":{\"externalIPs\":[\"' + $controlPlaneIp + '\"]}}'
}
$ingressNginxSvc = 'ingress-nginx-controller'

(Invoke-Kubectl -Params 'patch', 'svc', $ingressNginxSvc, '-p', "$patchJson", '-n', $ingressNginxNamespace).Output | Write-Log

$allPodsAreUp = (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/component=controller' -Namespace 'ingress-nginx' -TimeoutSeconds 300)
$allJobsAreCompleted = (Wait-ForJobCondition -Condition Complete -Label 'app.kubernetes.io/component=admission-webhook' -Namespace 'ingress-nginx' -TimeoutSeconds 300)

if ($allPodsAreUp -ne $true -or $allJobsAreCompleted -ne $true) {
    $errMsg = "All ingress nginx pods could not become ready. Please use kubectl describe for more details.`nInstallation of ingress nginx failed."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$clusterIngressConfig = "$PSScriptRoot\manifests\cluster-local-ingress.yaml"
(Invoke-Kubectl -Params 'apply' , '-f', $clusterIngressConfig).Output | Write-Log



Write-Log 'All ingress nginx pods are up and ready.'

$addonConfig = [pscustomobject] @{Name = 'ingress'; Implementation = 'nginx' }
if ($InfraNodeSelector) { $addonConfig | Add-Member -NotePropertyName OmitCertMgr -NotePropertyValue $OmitCertMgr.IsPresent }
Add-AddonToSetupJson -Addon $addonConfig

if (-not $OmitCertMgr) {
    Assert-IngressTlsCertificate -IngressType 'nginx' -CertificateManifestPath $clusterIngressConfig
}

&"$PSScriptRoot\Update.ps1"

# adapt other addons
Update-Addons -AddonName $addonName

if (Test-Path $dashboardModule) {
    Import-Module $dashboardModule -Force
    if (Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue) {
        Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins after ingress nginx enable' -Console
        try {
            Sync-HeadlampPlugins
        }
        catch {
            # Plugin sync is best-effort: a failure here must not fail the primary addon operation.
            Write-Log "[Dashboard][Plugin] Headlamp plugin sync failed (ingress nginx enable continues): $($_.Exception.Message)" -Console
        }
    }
}

Write-Log 'ingress nginx installed successfully' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
