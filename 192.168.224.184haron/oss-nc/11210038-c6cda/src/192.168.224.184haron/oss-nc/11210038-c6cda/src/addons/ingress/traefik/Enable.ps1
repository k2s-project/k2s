# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs Traefik Ingress Controller

.DESCRIPTION
NA

.EXAMPLE
# For k2sSetup.
powershell <installation folder>\addons\ingress\traefik\Enable.ps1
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
    [parameter(Mandatory = $false, HelpMessage = 'Omit cert-manager installation')]
    [switch] $OmitCertMgr = $false
)
$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$traefikModule = "$PSScriptRoot\traefik.module.psm1"
$dashboardModule = "$PSScriptRoot\..\..\dashboard\dashboard.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $traefikModule

Initialize-Logging -ShowLogs:$ShowLogs
trap { if ($EncodeStructuredOutput) { Send-ToCli -MessageType $MessageType -Message @{Error = (New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $_.Exception.Message)}; return }; throw }
$ownerOptions = Get-AddonPlacementOwnerOptions -Name 'ingress' -Implementation 'traefik' -BoundParameters $PSBoundParameters -Defaults @{OmitCertMgr = $OmitCertMgr.IsPresent}
$OmitCertMgr = [switch]$ownerOptions.OmitCertMgr
$InfraNodeSelector = Get-AddonEffectiveInfrastructureSelector -Name 'ingress' -Implementation 'traefik' -Selector $InfraNodeSelector

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
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'ingress traefik' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'traefik' })) -eq $true) {
    $errMsg = "Addon 'ingress traefik' is already enabled, nothing to do."

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

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'ingress'; Implementation = 'nginx-gw' })) -eq $true) {
    $errMsg = "Addon 'ingress nginx-gw' is enabled. Disable it first to avoid port conflicts."

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

Assert-SharedInfrastructurePlacement -Name 'external-dns' -Selector $InfraNodeSelector -Namespace 'external-dns' -Deployment 'external-dns'
if (-not $OmitCertMgr) { Assert-SharedInfrastructurePlacement -Name 'cert-manager' -Selector $InfraNodeSelector -Namespace 'cert-manager' -Deployment 'cert-manager' }
if ($InfraNodeSelector) {
    Assert-AddonPlacementHost -Selector $InfraNodeSelector -NodeName (Get-ConfigControlPlaneNodeHostname) -Reason 'Traefik ingress external IP'
    $preflight = New-AddonPlacementInput -AddonName 'ingress' -Path "$PSScriptRoot\manifests" -Selector $InfraNodeSelector -Kustomize
    Remove-Item -LiteralPath $preflight.Path -Force -ErrorAction SilentlyContinue
    Set-AddonPlacementIntent -Addon ([pscustomobject]@{Name = 'ingress'; Implementation = 'traefik'; InfraNodeSelector = $InfraNodeSelector; OmitCertMgr = $OmitCertMgr.IsPresent})
}
Install-GatewayApiCrds

Write-Log 'Installing external-dns' -Console
$externalDnsConfig = Get-ExternalDnsConfigDir
(Invoke-AddonOwnedApply -AddonName 'externaldns' -Path $externalDnsConfig -Selector $InfraNodeSelector -Kustomize).Output | Write-Log
if ($InfraNodeSelector) { Set-SharedInfrastructurePlacement -Name 'external-dns' -Selector $InfraNodeSelector }

if (-not $OmitCertMgr) {
    Write-Log 'Installing cert-manager' -Console
    Enable-CertManager -Proxy $Proxy -EncodeStructuredOutput:$EncodeStructuredOutput -MessageType:$MessageType -InfraNodeSelector $InfraNodeSelector
}
else {
    Write-Log '[ingress traefik] Skipping cert-manager installation (--omitCertMgr)' -Console
}

# we prepare all patches and apply them in a single kustomization,
# instead of applying the unpatched manifests and then applying patches one by one
$controlPlaneIp = Get-ConfiguredIPControlPlane
Write-Log "Preparing kustomization with $controlPlaneIp as an external IP for traefik service" -Console
$kustomization = @"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../manifests

patches:
- patch: |-
    - op: add
      path: /spec/template/spec/containers/0/args/-
      value: --providers.kubernetesIngress.ingressEndpoint
    - op: add
      path: /spec/template/spec/containers/0/args/-
      value: --providers.kubernetesIngress.ingressEndpoint.ip=$controlPlaneIp
  target:
    kind: Deployment
    name: traefik
    namespace: ingress-traefik
- patch: |-
    - op: replace
      path: /spec/externalIPs
      value: 
        - $controlPlaneIp
  target:
    kind: Service
    name: traefik
    namespace: ingress-traefik
"@

# create a temporary directory to store the kustomization file
$kustomizationDir = "$PSScriptRoot/kustomizationDir"
New-Item -Path $kustomizationDir -ItemType 'directory' -ErrorAction SilentlyContinue
$kustomizationFile = "$kustomizationDir\kustomization.yaml"
$kustomization | Out-File $kustomizationFile

Write-Log 'Installing traefik ingress controller' -Console
(Invoke-Kubectl -Params 'create' , 'namespace', 'ingress-traefik').Output | Write-Log
(Invoke-AddonOwnedApply -AddonName 'ingress' -Path $kustomizationDir -Selector $InfraNodeSelector -Kustomize).Output | Write-Log

# delete the temporary directory
Remove-Item -Path $kustomizationDir -Recurse

$allPodsAreUp = (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=traefik' -Namespace 'ingress-traefik' -TimeoutSeconds 120)

if ($allPodsAreUp -ne $true) {
    $errMsg = "All traefik pods could not become ready. Please use kubectl describe for more details.`nInstallation of ingress traefik addon failed"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = @{Message = $err } }
        return
    }

    Write-Log $errMsg -Error
    exit 1 
}

Write-Log 'All ingress traefik pods are up and ready.' -Console

$addonConfig = [pscustomobject] @{Name = 'ingress'; Implementation = 'traefik' }
if ($InfraNodeSelector) { $addonConfig | Add-Member -NotePropertyName OmitCertMgr -NotePropertyValue $OmitCertMgr.IsPresent }
Add-AddonToSetupJson -Addon $addonConfig

if (-not $OmitCertMgr) {
    Assert-IngressTlsCertificate -IngressType 'traefik' -CertificateManifestPath "$PSScriptRoot\manifests\cluster-local-ingress.yaml"
}

&"$PSScriptRoot\Update.ps1"

# adapt other addons
Update-Addons -AddonName $addonName

if (Test-Path $dashboardModule) {
    Import-Module $dashboardModule -Force
    if (Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue) {
        Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins after ingress traefik enable' -Console
        try {
            Sync-HeadlampPlugins
        }
        catch {
            # Plugin sync is best-effort: a failure here must not fail the primary addon operation.
            Write-Log "[Dashboard][Plugin] Headlamp plugin sync failed (ingress traefik enable continues): $($_.Exception.Message)" -Console
        }
    }
}

Write-Log 'Installation of Traefik addon finished.' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
