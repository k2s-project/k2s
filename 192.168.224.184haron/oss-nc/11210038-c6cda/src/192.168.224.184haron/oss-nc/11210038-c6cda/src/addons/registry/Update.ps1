# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$registryModule = "$PSScriptRoot\registry.module.psm1"
$imageRegistryModule = "$PSScriptRoot\..\..\lib\modules\windows\cluster\k2s.cluster.module\image\registry\registry.module.psm1"

Import-Module $addonsModule, $registryModule, $imageRegistryModule

$Addon = [pscustomobject] @{Name = 'registry' }

Remove-RegistryFromSetupJson -Name 'k2s.registry*' -IsRegex $true

if (Test-NginxIngressControllerAvailability) {
    $registryName = 'k2s.registry.local'

    Remove-IngressForTraefik -Addon $Addon
    Remove-IngressForNginxGateway -Addon $Addon
    Remove-NodePort

    Remove-Registry -Name 'k2s.registry.local*'
    Set-Registry -Name $registryName -Https -LocalRegistry

    $props = Get-AddonProperties -Addon $Addon

    Write-Log "  Applying nginx ingress manifest for $($props.Name)..." -Console
    $kustomizationDir = Get-IngressNginxConfigDirectory -Directory $props.Directory

    Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir | Out-Null
}
elseif (Test-NginxGatewayAvailability) {
    $registryName = 'k2s.registry.local'

    Remove-IngressForNginx -Addon $Addon
    Remove-IngressForTraefik -Addon $Addon
    Remove-NodePort

    Remove-Registry -Name 'k2s.registry.local*'
    Set-Registry -Name $registryName -Https -LocalRegistry

    $certificatePath = "$PSScriptRoot\manifests\ingress-nginx-gw\k2s-registry-local-tls-certificate.yaml"
    if (Test-Path $certificatePath) {
        Write-Log "  Ensuring registry TLS certificate exists..." -Console
        Invoke-Kubectl -Params 'apply', '-f', $certificatePath | Out-Null
    }

    Update-IngressForNginxGateway -Addon $Addon
}
elseif (Test-TraefikIngressControllerAvailability) {
    $registryName = 'k2s.registry.local'

    Remove-IngressForNginx -Addon $Addon
    Remove-IngressForNginxGateway -Addon $Addon
    Remove-NodePort

    Remove-Registry -Name 'k2s.registry.local*'
    Set-Registry -Name $registryName -Https -LocalRegistry

    Update-IngressForTraefik -Addon $Addon
}
else {
    $registryName = 'k2s.registry.local:30500'

    Remove-IngressForNginx -Addon $Addon
    Remove-IngressForTraefik -Addon $Addon
    Remove-IngressForNginxGateway -Addon $Addon

    Update-NodePort

    Remove-Registry -Name 'k2s.registry.local*'
    Set-Registry -Name $registryName -LocalRegistry
}

Add-RegistryToSetupJson -Name $registryName
