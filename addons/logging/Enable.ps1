# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables logging addon in the cluster to the logging namespace

.DESCRIPTION
The logging addon collects all logs from containers/pods running inside the k2s cluster.
Logs can be analyzed via opensearch dashboards.

.EXAMPLE
# For k2sSetup
powershell <installation folder>\addons\logging\Enable.ps1
#>
Param(
    [string] $InfraNodeSelector = '',
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'External access option')]
    [ValidateSet('nginx', 'nginx-gw', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'Omit OpenSearch and OpenSearch Dashboards; Fluent-bit uses stdout output')]
    [switch] $OmitOpensearch = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [string] $StorageNode
)
$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib/modules/windows/node/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$loggingModule = "$PSScriptRoot\logging.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $nodeModule, $loggingModule

Initialize-Logging -ShowLogs:$ShowLogs
trap { if ($EncodeStructuredOutput) { Send-ToCli -MessageType $MessageType -Message @{Error = (New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $_.Exception.Message)}; return }; throw }
$ownerOptions = Get-AddonPlacementOwnerOptions -Name 'logging' -BoundParameters $PSBoundParameters -Defaults @{StorageNode = $StorageNode; Ingress = $Ingress; OmitOpensearch = $OmitOpensearch.IsPresent}
$StorageNode = $ownerOptions.StorageNode
$Ingress = $ownerOptions.Ingress
$OmitOpensearch = [switch]$ownerOptions.OmitOpensearch
$InfraNodeSelector = Get-AddonEffectiveInfrastructureSelector -Name 'logging' -Selector $InfraNodeSelector

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
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'logging' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'logging' })) -eq $true) {
    $errMsg = "Addon 'logging' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ($OmitOpensearch -and $Ingress -ne 'none') {
    Write-Log '--omitOpensearch ignores --ingress (no dashboard to expose); ingress flag will be ignored' -Console
    $Ingress = 'none'
}

if ($InfraNodeSelector -and $OmitOpensearch) { throw 'Infrastructure placement is not applicable with --omitOpensearch: Fluent Bit is node-local and remains distributed.' }
if ($InfraNodeSelector -and $Ingress -ne 'none') { throw 'Enable ingress separately before enabling logging with infrastructure placement.' }
if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

if ([string]::IsNullOrEmpty($StorageNode)) {
    $StorageNode = Get-ConfigControlPlaneNodeHostname
}
$placement = $null
if ($InfraNodeSelector) {
    Assert-AddonPlacementHost -Selector $InfraNodeSelector -NodeName $StorageNode -Reason 'OpenSearch local PV and vm.max_map_count prerequisite'
    Assert-AddonStoragePlacement -Namespace 'logging' -VolumeNames 'opensearch-cluster-master-pv' -NodeName $StorageNode
    $placement = New-AddonPlacementInput -AddonName 'logging' -Path "$PSScriptRoot\manifests\logging" -Selector $InfraNodeSelector -StorageNode $StorageNode -Kustomize
    Set-AddonPlacementIntent -Addon ([pscustomobject]@{Name = 'logging'; InfraNodeSelector = $InfraNodeSelector; StorageNode = $StorageNode; Ingress = $Ingress; OmitOpensearch = $OmitOpensearch.IsPresent})
}

$controlPlaneHostname = Get-ConfigControlPlaneNodeHostname
if ($StorageNode -eq $controlPlaneHostname) {
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo mkdir -m 777 -p /logging').Output | Write-Log

    # OpenSearch requires vm.max_map_count >= 262144; set it persistently so it survives reboots
    $sysctlResult = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-opensearch.conf && sudo sysctl -w vm.max_map_count=262144'
    if (-not $sysctlResult.Success) {
        Write-Log "Warning: sysctl vm.max_map_count setting failed" -Console
    }
    $sysctlResult.Output | Write-Log
} else {
    $clusterDescriptor = Get-JsonContent -FilePath (Get-ClusterDescriptorFilePath)
    $workerNode = @($clusterDescriptor.nodes) | Where-Object { $_.Name -eq $StorageNode } | Select-Object -First 1
    if (-not $workerNode) { throw "Storage node '$StorageNode' not found in cluster descriptor" }
    (Invoke-CmdOnVmViaSSHKey -IpAddress $workerNode.IpAddress -UserName $workerNode.Username -Timeout 2 -CmdToExecute 'sudo mkdir -m 777 -p /logging').Output | Write-Log

    # OpenSearch requires vm.max_map_count >= 262144; set it persistently so it survives reboots
    $sysctlResult = Invoke-CmdOnVmViaSSHKey -IpAddress $workerNode.IpAddress -UserName $workerNode.Username -Timeout 2 -CmdToExecute 'echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-opensearch.conf && sudo sysctl -w vm.max_map_count=262144'
    if (-not $sysctlResult.Success) {
        Write-Log "Warning: sysctl vm.max_map_count setting failed" -Console
    }
    $sysctlResult.Output | Write-Log
}

$manifestsPath = "$PSScriptRoot\manifests\logging"

function Stop-WithError ([string]$Message) {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $Message
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    }
    else { Write-Log $Message -Error }
    exit 1
}

# Returns the configured K2s log root escaped for the Windows Fluent Bit conf,
# which uses doubled backslashes (e.g. C:\\var\\log). Used to substitute the
# __LOG_ROOT__ placeholder in the Windows configmaps so the Fluent Bit storage
# buffer (flb-storage) follows the relocated log root instead of C:\var\log.
function Get-EscapedLogRootForFluentBit {
    $logRoot = (Get-ConfiguredLogDirectory).TrimEnd('\')
    return ($logRoot -replace '\\', '\\')
}

# Applies a kubectl action while the given Windows Fluent Bit manifest has its
# __LOG_ROOT__ placeholder substituted on disk, then restores the original file.
# Mirrors the temporary replace/restore pattern used for __STORAGE_NODE__.
function Invoke-WithLogRootSubstitution {
    param(
        [Parameter(Mandatory = $true)][string] $ManifestFile,
        [Parameter(Mandatory = $true)][scriptblock] $Action
    )
    $original = [System.IO.File]::ReadAllText($ManifestFile)
    [System.IO.File]::WriteAllText($ManifestFile, $original.Replace('__LOG_ROOT__', (Get-EscapedLogRootForFluentBit)))
    try {
        return (& $Action)
    }
    finally {
        [System.IO.File]::WriteAllText($ManifestFile, $original)
    }
}

function Wait-FluentBitReady {
    Write-Log 'Waiting for Fluent-bit DaemonSets to be ready...' -Console
    $cmd = Invoke-Kubectl -Params 'rollout', 'status', 'daemonset/fluent-bit', '-n', 'logging', '--timeout=300s'
    Write-Log $cmd.Output
    if (!$cmd.Success) { Stop-WithError 'Fluent-bit could not be deployed successfully!' }

    if ($setupInfo.LinuxOnly -eq $false) {
        $cmd = Invoke-Kubectl -Params 'rollout', 'status', 'daemonset/fluent-bit-win', '-n', 'logging', '--timeout=300s'
        Write-Log $cmd.Output
        if (!$cmd.Success) { Stop-WithError 'Fluent-bit Windows could not be deployed successfully!' }
    }
}

if ($OmitOpensearch) {
    Write-Log 'Deploying Fluent-bit only (--omitOpensearch)' -Console

    (Invoke-Kubectl -Params 'apply', '-f', "$manifestsPath\namespace.yaml").Output | Write-Log

    $fluentbitPath = "$manifestsPath\fluentbit"
    (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitPath\clusterrole.yaml").Output | Write-Log
    (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitPath\clusterrolebinding.yaml").Output | Write-Log
    (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitPath\serviceaccount.yaml").Output | Write-Log
    (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitPath\service.yaml").Output | Write-Log
    (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitPath\service-otel.yaml").Output | Write-Log
    (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitPath\stdout\configmap-stdout.yaml").Output | Write-Log
    (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitPath\daemonset.yaml").Output | Write-Log

    if ($setupInfo.LinuxOnly -eq $false) {
        $fluentbitWindowsPath = "$manifestsPath\fluentbit\windows"
        $winStdoutConfigMap = "$fluentbitWindowsPath\stdout\configmap-windows-stdout.yaml"
        Invoke-WithLogRootSubstitution -ManifestFile $winStdoutConfigMap -Action {
            (Invoke-Kubectl -Params 'apply', '-f', $winStdoutConfigMap).Output | Write-Log
        }
        (Invoke-Kubectl -Params 'apply', '-f', "$fluentbitWindowsPath\daemonset-windows.yaml").Output | Write-Log
    }

    Wait-FluentBitReady
}
else {
    Write-Log 'Installing fluent-bit and opensearch stack' -Console

    # opensearch
    # opensearch dashboards
    # fluent-bit linux

    (Invoke-Kubectl -Params 'apply', '-f', "$manifestsPath\namespace.yaml").Output | Write-Log

    # Inject storage node hostname into PV manifest
    $pvFile = "$PSScriptRoot\manifests\logging\opensearch\persistentvolume.yaml"
    $pvOrig = [System.IO.File]::ReadAllText($pvFile)
    if (-not $placement) { [System.IO.File]::WriteAllText($pvFile, $pvOrig.Replace('__STORAGE_NODE__', $StorageNode)) }
    try {
        $createResult = if ($placement) { Invoke-Kubectl -Params 'apply', '-f', $placement.Path } else { Invoke-Kubectl -Params 'create', '-k', "$manifestsPath\" }
    }
    finally {
        # Restore PV manifest placeholder
        if (-not $placement) { [System.IO.File]::WriteAllText($pvFile, $pvOrig) }
        if ($placement) { Remove-Item -LiteralPath $placement.Path -Force -ErrorAction SilentlyContinue }
    }
    $createResult.Output | Write-Log
    if (!$createResult.Success) { Stop-WithError "Failed to create logging resources: $($createResult.Output)" }

    # fluent-bit windows
    if ($setupInfo.LinuxOnly -eq $false) {
        $winConfigMap = "$manifestsPath\fluentbit\windows\configmap-windows.yaml"
        $createWinResult = Invoke-WithLogRootSubstitution -ManifestFile $winConfigMap -Action {
            Invoke-Kubectl -Params 'create', '-k', "$manifestsPath\fluentbit\windows"
        }
        $createWinResult.Output | Write-Log
        if (!$createWinResult.Success) { Stop-WithError "Failed to create logging Windows resources: $($createWinResult.Output)" }
    }

    Write-Log 'Waiting for pods being ready...' -Console

    $kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', 'logging', '--timeout=900s')
    Write-Log $kubectlCmd.Output
    if (!$kubectlCmd.Success) {
        Write-Log '[Logging] Rollout status timed out - gathering diagnostics' -Console
        (Invoke-Kubectl -Params 'describe', 'pod', '-n', 'logging', '-l', 'app.kubernetes.io/name=opensearch').Output | Write-Log
        (Invoke-Kubectl -Params 'get', 'events', '-n', 'logging', '--sort-by=.lastTimestamp').Output | Write-Log
        Stop-WithError 'Opensearch could not be deployed successfully!'
    }

    $kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'deployments', '-n', 'logging', '--timeout=600s')
    Write-Log $kubectlCmd.Output
    if (!$kubectlCmd.Success) {
        Write-Log '[Logging] Deployment rollout failed - gathering diagnostics' -Console
        (Invoke-Kubectl -Params 'describe', 'pod', '-n', 'logging', '-l', 'app.kubernetes.io/name=opensearch-dashboards').Output | Write-Log
        (Invoke-Kubectl -Params 'get', 'events', '-n', 'logging', '--sort-by=.lastTimestamp').Output | Write-Log
        Stop-WithError 'Opensearch dashboards could not be deployed successfully!'
    }

    Wait-FluentBitReady

    # Import saved objects 
    $dashboardIP = (Invoke-Kubectl -Params 'get', 'pods', '-l=app.kubernetes.io/name=opensearch-dashboards', '-n', 'logging', '-o=jsonpath="{.items[0].status.podIP}"').Output
    $dashboardIP = $dashboardIP -replace '"', ''

    $importingSavedObjects = curl.exe -X POST --retry 10 --retry-delay 5 --silent --disable --fail --retry-all-errors "http://${dashboardIP}:5601/logging/api/saved_objects/_import?overwrite=true" -H 'osd-xsrf: true' -F "file=@$PSScriptRoot/opensearch-dashboard-saved-objects/k2s-index-pattern.ndjson" 2>$null
    Write-Log $importingSavedObjects

    &"$PSScriptRoot\Update.ps1"
}

$addonConfig = [pscustomobject]@{Name = 'logging'; OmitOpensearch = $OmitOpensearch.IsPresent}
if ($InfraNodeSelector) {
    $addonConfig | Add-Member -NotePropertyName StorageNode -NotePropertyValue $StorageNode
    $addonConfig | Add-Member -NotePropertyName Ingress -NotePropertyValue $Ingress
    $addonConfig | Add-Member -NotePropertyName InfraNodeSelector -NotePropertyValue $InfraNodeSelector
}
Add-AddonToSetupJson -Addon $addonConfig
if ($InfraNodeSelector) { Set-AddonPlacementIntent -Addon $addonConfig -Clear }
Write-Log 'Logging Stack installed successfully'

if (-not $OmitOpensearch) {
    Write-UsageForUser
    Write-BrowserWarningForUser
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
