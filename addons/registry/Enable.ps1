# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables k2s.registry in the cluster to the private-registry namespace

.DESCRIPTION
The local registry allows to push/pull images to/from the local volume of KubeMaster.
Each node inside the cluster can connect to the registry.

.EXAMPLE
# For k2sSetup
powershell <installation folder>\addons\registry\Enable.ps1
#>
Param(
    [string] $InfraNodeSelector = '',
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Enable ingress addon')]
    [ValidateSet('nginx', 'nginx-gw', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'Node for persistent storage (default: control plane)')]
    [string] $StorageNode
)
$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib/modules/windows/node/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$registryModule = "$PSScriptRoot\registry.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule, $registryModule

Initialize-Logging -ShowLogs:$ShowLogs
trap { if ($EncodeStructuredOutput) { Send-ToCli -MessageType $MessageType -Message @{Error = (New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $_.Exception.Message)}; return }; throw }
$ownerOptions = Get-AddonPlacementOwnerOptions -Name 'registry' -BoundParameters $PSBoundParameters -Defaults @{StorageNode = $StorageNode; Ingress = $Ingress}
$StorageNode = $ownerOptions.StorageNode
$Ingress = $ownerOptions.Ingress
$InfraNodeSelector = Get-AddonEffectiveInfrastructureSelector -Name 'registry' -Selector $InfraNodeSelector

Write-Log 'Checking cluster status' -Console

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
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'registry' can only be enabled for 'k2s' setup type."
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'registry' })) -eq $true) {
    $errMsg = "Addon 'registry' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($InfraNodeSelector -and $Ingress -ne 'none') { throw 'Enable ingress separately before enabling registry with infrastructure placement.' }
if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

# Inject storage node hostname into PV manifest
if ([string]::IsNullOrEmpty($StorageNode)) {
    $StorageNode = Get-ConfigControlPlaneNodeHostname
}
$placement = $null
if ($InfraNodeSelector) {
    Assert-AddonPlacementHost -Selector $InfraNodeSelector -NodeName $StorageNode -Reason 'registry local PV and authentication directory'
    Assert-AddonStoragePlacement -Namespace 'registry' -VolumeNames 'registry-pv' -NodeName $StorageNode
    $placement = New-AddonPlacementInput -AddonName 'registry' -Path "$PSScriptRoot\manifests\registry" -Selector $InfraNodeSelector -StorageNode $StorageNode -Kustomize
    Set-AddonPlacementIntent -Addon ([pscustomobject]@{Name = 'registry'; InfraNodeSelector = $InfraNodeSelector; StorageNode = $StorageNode; Ingress = $Ingress})
}

# Create folder structure for certificates and authentication files
Write-Log 'Creating authentication files and secrets' -Console
$controlPlaneHostname = Get-ConfigControlPlaneNodeHostname
if ($StorageNode -eq $controlPlaneHostname) {
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -Retries 3 -CmdToExecute 'sudo mkdir -p /registry /registry/auth /registry/repository').Output | Write-Log
} else {
    $clusterDescriptor = Get-JsonContent -FilePath (Get-ClusterDescriptorFilePath)
    $workerNode = @($clusterDescriptor.nodes) | Where-Object { $_.Name -eq $StorageNode } | Select-Object -First 1
    if (-not $workerNode) { throw "Storage node '$StorageNode' not found in cluster descriptor" }
    (Invoke-CmdOnVmViaSSHKey -IpAddress $workerNode.IpAddress -UserName $workerNode.Username -Timeout 2 -Retries 3 -CmdToExecute 'sudo mkdir -p /registry /registry/auth /registry/repository').Output | Write-Log
}

# Create secrets
(Invoke-Kubectl -Params 'create', 'namespace', 'registry').Output | Write-Log

$pvFile = "$PSScriptRoot\manifests\registry\persistent-volume.yaml"
$pvOrig = [System.IO.File]::ReadAllText($pvFile)
if (-not $placement) { [System.IO.File]::WriteAllText($pvFile, $pvOrig.Replace('__STORAGE_NODE__', $StorageNode)) }
try {
    # Apply registry pod with persistent volume
    Write-Log 'Creating local registry' -Console
    $applyResult = if ($placement) { Invoke-Kubectl -Params 'apply', '-f', $placement.Path } else { Invoke-Kubectl -Params 'apply', '-k', "$PSScriptRoot\manifests\registry" }
    $applyResult.Output | Write-Log
    if (-not $applyResult.Success) {
        if ($placement) { throw "Registry apply failed: $($applyResult.Output)" }
        Write-Log "[Registry] WARNING apply failed, continuing: $($applyResult.Output)"
    }
}
finally {
    # Restore PV manifest placeholder
    if (-not $placement) { [System.IO.File]::WriteAllText($pvFile, $pvOrig) }
    if ($placement) { Remove-Item -LiteralPath $placement.Path -Force -ErrorAction SilentlyContinue }
}

$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', 'registry', '--timeout=300s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'k2s.registry.local did not start in time! Please disable addon and try to enable again!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Add-HostEntries -Url 'k2s.registry.local'

Add-CoreDNSHostEntry -Hostname 'k2s.registry.local'

&"$PSScriptRoot\Update.ps1"

$addonConfig = [pscustomobject]@{Name = 'registry'}
if ($InfraNodeSelector) {
    $addonConfig | Add-Member -NotePropertyName StorageNode -NotePropertyValue $StorageNode
    $addonConfig | Add-Member -NotePropertyName Ingress -NotePropertyValue $Ingress
    $addonConfig | Add-Member -NotePropertyName InfraNodeSelector -NotePropertyValue $InfraNodeSelector
}
Add-AddonToSetupJson -Addon $addonConfig
if ($InfraNodeSelector) { Set-AddonPlacementIntent -Addon $addonConfig -Clear }

Write-RegistryUsageForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
