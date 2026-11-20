# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Backs up monitoring configuration/resources

.DESCRIPTION
Exports selected Kubernetes resources of the monitoring addon into a staging folder.
The CLI wraps the staging folder into a zip archive.

This backup is config-only:
- Kubernetes Secrets are NOT exported.
- Persistent volume data is NOT exported.

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\monitoring\Backup.ps1 -BackupDir C:\Temp\monitoring-backup
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Directory where backup files will be written')]
    [string] $BackupDir,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

function Fail([string]$errMsg, [string]$code = 'addon-backup-failed') {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code $code -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        exit 1
    }

    Write-Log $errMsg -Error
    exit 1
}

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Fail $systemError.Message 'system-not-available'
}

Write-Log "[MonitoringBackup] Backing up addon 'monitoring'" -Console

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{ Name = 'monitoring' })) -ne $true) {
    Fail "Addon 'monitoring' is not enabled. Enable it before running backup." 'addon-not-enabled'
}

$namespace = 'monitoring'
$nsCheck = Invoke-Kubectl -Params 'get', 'ns', $namespace
if (-not $nsCheck.Success) {
    Fail "Namespace '$namespace' not found. Is addon 'monitoring' installed? Details: $($nsCheck.Output)" 'namespace-not-found'
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

$script:files = @()

function Get-NamesFromKubectlListOutput([object]$output) {
    if ($null -eq $output) {
        return @()
    }

    $text = ''
    if ($output -is [array]) {
        $text = ($output | ForEach-Object { "$($_)" }) -join "`n"
    }
    else {
        $text = "$output"
    }

    return @($text -split "`r?`n" | ForEach-Object { "$($_)".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-KubectlOutputText([object]$output) {
    if ($null -eq $output) {
        return ''
    }
    if ($output -is [array]) {
        return ($output | ForEach-Object { "$($_)" }) -join "`n"
    }
    return "$output"
}

function Try-ListResourceNames {
    param(
        [Parameter(Mandatory = $true)][string] $Resource
    )

    $list = Invoke-Kubectl -Params 'get', $Resource, '-n', $namespace, '-o', 'name'
    if ($list.Success) {
        return (Get-NamesFromKubectlListOutput -output $list.Output)
    }

    $out = "$($list.Output)"
    if ($out -match '(the server doesn\x27t have a resource type|No resources found|not found)') {
        return @()
    }

    throw "Failed to list resources '$Resource' in namespace '$namespace': $out"
}

function Export-ResourceYaml {
    param(
        [Parameter(Mandatory = $true)][string] $Resource,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $OutPath
    )

    $get = Invoke-Kubectl -Params 'get', $Resource, $Name, '-n', $namespace, '-o', 'yaml'
    if (-not $get.Success) {
        throw "Failed to export ${Resource}/${Name}: $($get.Output)"
    }
    $get.Output | Set-Content -Path $OutPath -Encoding UTF8 -Force
}

function Try-ExportAll {
    param(
        [Parameter(Mandatory = $true)][string] $Resource,
        [Parameter(Mandatory = $true)][string] $FilePrefix,
        [Parameter(Mandatory = $false)][scriptblock] $ShouldSkip
    )

    $names = Try-ListResourceNames -Resource $Resource
    foreach ($full in $names) {
        $nameOnly = ($full -split '/')[1]
        if ($ShouldSkip -and (& $ShouldSkip $nameOnly)) {
            continue
        }

        $safeName = $nameOnly -replace '[^a-zA-Z0-9_.-]', '_'
        $outPath = Join-Path $BackupDir ("{0}_{1}.yaml" -f $FilePrefix, $safeName)
        Export-ResourceYaml -Resource $Resource -Name $nameOnly -OutPath $outPath
        $script:files += (Split-Path -Leaf $outPath)
    }
}

function Test-IsHelmManagedItem {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Item
    )

    $labels = $Item.metadata.labels
    if ($labels) {
        if ($labels.'app.kubernetes.io/managed-by' -eq 'Helm') {
            return $true
        }
        if ($labels.'helm.sh/chart') {
            return $true
        }
    }

    $ann = $Item.metadata.annotations
    if ($ann) {
        if ($ann.'meta.helm.sh/release-name') {
            return $true
        }
        if ($ann.'meta.helm.sh/release-namespace') {
            return $true
        }
    }

    return $false
}

function Try-ExportNonHelmManaged {
    param(
        [Parameter(Mandatory = $true)][string] $Resource,
        [Parameter(Mandatory = $true)][string] $FilePrefix
    )

    $list = Invoke-Kubectl -Params 'get', $Resource, '-n', $namespace, '-o', 'json'
    if (-not $list.Success) {
        $out = (Get-KubectlOutputText -output $list.Output)
        if ($out -match '(the server doesn\x27t have a resource type|No resources found|not found)') {
            return
        }
        throw "Failed to list resources '$Resource' in namespace '$namespace': $out"
    }

    $obj = $null
    try {
        $obj = (Get-KubectlOutputText -output $list.Output) | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse kubectl JSON for '$Resource': $($_.Exception.Message)"
    }

    if (-not $obj.items) {
        return
    }

    foreach ($item in $obj.items) {
        if (Test-IsHelmManagedItem -Item $item) {
            continue
        }

        $nameOnly = "$($item.metadata.name)"
        if ([string]::IsNullOrWhiteSpace($nameOnly)) {
            continue
        }

        $safeName = $nameOnly -replace '[^a-zA-Z0-9_.-]', '_'
        $outPath = Join-Path $BackupDir ("{0}_{1}.yaml" -f $FilePrefix, $safeName)
        Export-ResourceYaml -Resource $Resource -Name $nameOnly -OutPath $outPath
        $script:files += (Split-Path -Leaf $outPath)
    }
}

function Try-ExportConfigMapsBySelector {
    param(
        [Parameter(Mandatory = $true)][string] $LabelSelector,
        [Parameter(Mandatory = $true)][string] $FilePrefix
    )

    # Use JSON so we can filter out Helm-managed (default) dashboards/datasources.
    $list = Invoke-Kubectl -Params 'get', 'configmap', '-n', $namespace, '-l', $LabelSelector, '-o', 'json'
    if (-not $list.Success) {
        $out = (Get-KubectlOutputText -output $list.Output)
        if ($out -match '(No resources found|not found)') {
            return
        }
        throw "Failed to list ConfigMaps with selector '$LabelSelector': $out"
    }

    $obj = $null
    try {
        $obj = (Get-KubectlOutputText -output $list.Output) | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse kubectl JSON for ConfigMaps with selector '$LabelSelector': $($_.Exception.Message)"
    }

    if (-not $obj.items) {
        return
    }

    foreach ($item in $obj.items) {
        if (Test-IsHelmManagedItem -Item $item) {
            continue
        }

        $nameOnly = "$($item.metadata.name)"
        if ([string]::IsNullOrWhiteSpace($nameOnly) -or $nameOnly -eq 'kube-root-ca.crt') {
            continue
        }

        # The kube-prometheus-stack addon ships many default Grafana dashboards/datasources.
        # They are reproducible by re-enabling the addon and often do not carry Helm metadata
        # because they are created/maintained by a Grafana sidecar.
        # Keep backups focused on user-created ConfigMaps.
        if ($nameOnly -match '^kube-prometheus-stack-') {
            continue
        }

        $safeName = $nameOnly -replace '[^a-zA-Z0-9_.-]', '_'
        $outPath = Join-Path $BackupDir ("{0}_{1}.yaml" -f $FilePrefix, $safeName)
        Export-ResourceYaml -Resource 'configmap' -Name $nameOnly -OutPath $outPath
        $leaf = (Split-Path -Leaf $outPath)
        if ($script:files -notcontains $leaf) {
            $script:files += $leaf
        }
    }
}

try {
    # Export user-facing Grafana dashboards/datasources (config-only)
    Try-ExportConfigMapsBySelector -LabelSelector 'grafana_dashboard=1' -FilePrefix 'configmap_grafana_dashboard'
    Try-ExportConfigMapsBySelector -LabelSelector 'grafana_datasource=1' -FilePrefix 'configmap_grafana_datasource'

    # Ingress-related resources for the monitoring UI
    Try-ExportAll -Resource 'ingress' -FilePrefix 'ingress'
    Try-ExportAll -Resource 'httproute' -FilePrefix 'httproute'
    Try-ExportAll -Resource 'ingressroute.traefik.containo.us' -FilePrefix 'ingressroute'
    Try-ExportAll -Resource 'middleware.traefik.containo.us' -FilePrefix 'middleware'

    # Prometheus Operator CRs: export only non-Helm-managed objects (user-created/custom)
    Try-ExportNonHelmManaged -Resource 'prometheus.monitoring.coreos.com' -FilePrefix 'prometheus'
    Try-ExportNonHelmManaged -Resource 'alertmanager.monitoring.coreos.com' -FilePrefix 'alertmanager'
    Try-ExportNonHelmManaged -Resource 'prometheusrule.monitoring.coreos.com' -FilePrefix 'prometheusrule'
    Try-ExportNonHelmManaged -Resource 'servicemonitor.monitoring.coreos.com' -FilePrefix 'servicemonitor'
    Try-ExportNonHelmManaged -Resource 'podmonitor.monitoring.coreos.com' -FilePrefix 'podmonitor'
    Try-ExportNonHelmManaged -Resource 'alertmanagerconfig.monitoring.coreos.com' -FilePrefix 'alertmanagerconfig'
}
catch {
    Fail "Backup of addon 'monitoring' failed: $($_.Exception.Message)" 'addon-backup-failed'
}

$version = 'unknown'
try {
    $version = Get-ConfigProductVersion
}
catch {
    # best-effort only
}

$manifest = [pscustomobject]@{
    k2sVersion = $version
    addon      = 'monitoring'
    files      = $script:files
    createdAt  = (Get-Date).ToString('o')
}

$manifestPath = Join-Path $BackupDir 'backup.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8 -Force

if ($script:files.Count -eq 0) {
    $pods = Invoke-Kubectl -Params 'get', 'pods', '-n', $namespace, '-o', 'name'
    $deployments = Invoke-Kubectl -Params 'get', 'deployments', '-n', $namespace, '-o', 'name'

    if (($pods.Success -and [string]::IsNullOrWhiteSpace("$($pods.Output)")) -and ($deployments.Success -and [string]::IsNullOrWhiteSpace("$($deployments.Output)"))) {
        Write-Log "[MonitoringBackup] No files exported; namespace '$namespace' contains no resources. This usually means the addon is not deployed (enable may have failed) or kubectl points to a different cluster context." -Console
    }
    else {
        Write-Log "[MonitoringBackup] No files exported; created metadata-only backup" -Console
    }
}
else {
    Write-Log "[MonitoringBackup] Backup artifacts prepared ($($script:files.Count) file(s))" -Console
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
