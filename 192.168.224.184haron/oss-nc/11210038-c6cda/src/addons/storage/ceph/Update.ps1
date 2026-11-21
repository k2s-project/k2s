# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Reconciles the Ceph OSD hosts declared in ceph-config.json with the running cluster.

.DESCRIPTION
When the storage/ceph addon is enabled this script prepares any Ceph OSD host that is declared in
'osdHosts' in ceph-config.json, is now part of the K2s cluster (listed in cluster.json), but is not
yet registered with the running Ceph cluster. For every such host it:
  1. authorizes the stored cephadm cluster public key and installs podman/lvm2 (prepare-ceph-osd-host.sh),
  2. registers the host with the Ceph orchestrator ('ceph orch host add'),
  3. provisions the configured number of OSD disks on it (New-CephOsdDisk.ps1),
  4. labels the host and creates the OSD daemons (add-ceph-host-labels-and-osd.sh).

It is invoked by the add-node flow (Add.ps1) so that adding a node that is listed as an 'osdHosts'
entry automatically turns it into a Ceph OSD host, and can also be run standalone to reconcile the
configuration. The script is idempotent - hosts that are already registered with the cluster are
skipped.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../../../lib/modules/windows/node/k2s.node.module/k2s.node.module.psm1"
$clusterConfigModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/config/cluster.config.module.psm1"
$proxyModule = "$PSScriptRoot/../../../lib/modules/windows/node/k2s.node.module/windowsnode/proxy/proxy.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
Import-Module $infraModule, $clusterModule, $nodeModule, $clusterConfigModule, $proxyModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot
$addonDescriptor = [pscustomobject] @{Name = $addonName; Implementation = 'ceph' }

if ((Test-IsAddonEnabled -Addon $addonDescriptor) -ne $true) {
    Write-Log '[Ceph] storage/ceph addon is not enabled; nothing to reconcile.' -Console
    exit 0
}

$cephConfigPath = "$PSScriptRoot\config\ceph-config.json"
if (-not (Test-Path $cephConfigPath)) {
    Write-Log "[Ceph] ERROR: ceph-config.json not found at '$cephConfigPath'." -Console -Error
    exit 1
}

try {
    $Config = Get-Content -Path $cephConfigPath -Raw | ConvertFrom-Json
}
catch {
    Write-Log "[Ceph] ERROR: Failed to parse ceph-config.json: $($_.Exception.Message)" -Console -Error
    exit 1
}

function Resolve-ClusterNodeConfigForCephHost {
    param(
        [Parameter(Mandatory = $true)][string]$DeclaredHostName
    )

    $declared = "$DeclaredHostName".Trim()
    if ([string]::IsNullOrWhiteSpace($declared)) { return $null }

    $nodeConfig = Get-NodeConfig -NodeName $declared
    if ($null -ne $nodeConfig) {
        return [pscustomobject]@{
            NodeConfig = $nodeConfig
            MatchedBy = 'NodeName'
            DeclaredHostName = $declared
            ResolvedNodeName = "$($nodeConfig.Name)".Trim()
        }
    }

    return $null
}

# Determine the configured OSD hosts (Linux only). Nothing to do when none are declared.
$osdHosts = if ($Config -and ($Config.PSObject.Properties.Name -contains 'osdHosts') -and $null -ne $Config.osdHosts) { @($Config.osdHosts) } else { @() }
if ($osdHosts.Count -eq 0) {
    Write-Log '[Ceph] No OSD hosts declared in ceph-config.json (osdHosts is empty); nothing to reconcile.' -Console
    exit 0
}

# Resolve the cluster/bootstrap host (where cephadm and 'ceph orch' run).
$clusterHostNode = if ($Config -and ($Config.PSObject.Properties.Name -contains 'clusterHost') -and $null -ne $Config.clusterHost -and ($Config.clusterHost.PSObject.Properties.Name -contains 'node')) { "$($Config.clusterHost.node)".Trim() } else { '' }
if ([string]::IsNullOrWhiteSpace($clusterHostNode)) {
    Write-Log "[Ceph] ERROR: 'clusterHost.node' is required in ceph-config.json." -Console -Error
    exit 1
}

$controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
if ($clusterHostNode -eq $controlPlaneNodeName) {
    $bootstrapNodeIp = "$(Get-ConfiguredIPControlPlane)".Trim()
    $bootstrapNodeUser = "$(Get-DefaultUserNameControlPlane)".Trim()
}
else {
    $bootstrapNodeConfig = Get-NodeConfig -NodeName $clusterHostNode
    if ($null -eq $bootstrapNodeConfig) {
        Write-Log "[Ceph] ERROR: Cluster host node '$clusterHostNode' not found in cluster.json." -Console -Error
        exit 1
    }
    $bootstrapNodeIp = "$($bootstrapNodeConfig.IpAddress)".Trim()
    $bootstrapNodeUser = "$($bootstrapNodeConfig.Username)".Trim()
}
if ([string]::IsNullOrWhiteSpace($bootstrapNodeUser)) { $bootstrapNodeUser = 'remote' }
if ([string]::IsNullOrWhiteSpace($bootstrapNodeIp)) {
    Write-Log "[Ceph] ERROR: Could not resolve an IP address for cluster host node '$clusterHostNode'." -Console -Error
    exit 1
}

# Retrieve the cephadm public key stored in setup.json during enable so it can be authorized on
# newly added OSD hosts. Fall back to reading it directly from the bootstrap node if not stored.
$cephPubKey = "$(Get-AddonSetupJsonProperty -Addon $addonDescriptor -PropertyName 'CephPublicKey')".Trim()
if ([string]::IsNullOrWhiteSpace($cephPubKey)) {
    Write-Log '[Ceph] Stored cephadm public key not found in setup.json; reading it from the cluster host.' -Console
    $pubKeyResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo cat /etc/ceph/ceph.pub' -UserName $bootstrapNodeUser -IpAddress $bootstrapNodeIp -NoLog -IgnoreErrors -Retries 2
    $cephPubKey = (($pubKeyResult.Output | Out-String) -split "`r?`n" | Where-Object { $_.Trim().StartsWith('ssh-') -or $_.Trim().StartsWith('ecdsa-') } | Select-Object -First 1).Trim()
    if (-not [string]::IsNullOrWhiteSpace($cephPubKey)) {
        Set-AddonSetupJsonProperty -Addon $addonDescriptor -PropertyName 'CephPublicKey' -PropertyValue $cephPubKey
    }
}
else {
    Write-Log '[Ceph] Using cephadm public key from setup.json to prepare newly added OSD hosts.' -Console
}
if ([string]::IsNullOrWhiteSpace($cephPubKey)) {
    Write-Log '[Ceph] ERROR: Could not obtain the cephadm public key required to prepare OSD hosts.' -Console -Error
    exit 1
}

# Resolve the K2s transparent proxy used for offline package/image access on the OSD host.
$proxy = ''
try {
    $kubeSwitchIp = Get-ConfiguredKubeSwitchIP
    if (-not [string]::IsNullOrWhiteSpace($kubeSwitchIp)) { $proxy = "http://${kubeSwitchIp}:8181" }
}
catch {
    Write-Log "[Ceph] WARNING: Could not determine the K2s proxy; OSD host preparation will run without one: $($_.Exception.Message)" -Console
}

$prepareHostScript = "$PSScriptRoot\scripts\linux\debian\prepare-ceph-osd-host.sh"
$prepareDiskScript = "$PSScriptRoot\scripts\linux\debian\osd\New-CephOsdDisk.ps1"
$addOsdScript = "$PSScriptRoot\scripts\linux\debian\add-ceph-host-labels-and-osd.sh"
foreach ($requiredScript in @($prepareHostScript, $prepareDiskScript, $addOsdScript)) {
    if (-not (Test-Path $requiredScript)) {
        Write-Log "[Ceph] ERROR: Required script not found: '$requiredScript'." -Console -Error
        exit 1
    }
}

# Resolve the Ceph container image from the storage addon manifest so newly added OSD hosts can
# pull it locally via the proxy; without it cephadm's own pull from quay.io fails on air-gapped nodes.
$cephImage = ''
try {
    $manifestPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..\addon.manifest.yaml'))
    if (Test-Path $manifestPath) {
        $imageRef = Get-Content -Path $manifestPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -like '- quay.io/ceph/ceph:*' } | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($imageRef)) { $cephImage = ($imageRef -replace '^-\s*', '') }
    }
    else {
        Write-Log "[Ceph] WARNING: Storage addon manifest not found at '$manifestPath'; OSD hosts will rely on a locally present Ceph image." -Console
    }
}
catch {
    Write-Log "[Ceph] WARNING: Could not resolve the Ceph image from the addon manifest; OSD hosts will rely on a locally present image: $($_.Exception.Message)" -Console
}
if (-not [string]::IsNullOrWhiteSpace($cephImage)) {
    Write-Log "[Ceph] Using Ceph image '$cephImage' for OSD host preparation." -Console
}

$clusterFsid = if ($Config -and ($Config.PSObject.Properties.Name -contains 'clusterId')) { "$($Config.clusterId)".Trim() } else { '' }

# Snapshot the hosts already registered with the Ceph orchestrator so already-provisioned hosts are skipped.
$orchHostLsResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo cephadm shell -- ceph orch host ls' -UserName $bootstrapNodeUser -IpAddress $bootstrapNodeIp -NoLog -IgnoreErrors -Retries 2
$orchHostLsText = ($orchHostLsResult.Output | Out-String)

$reconciledCount = 0

Write-Log "[Ceph] Reconciling $($osdHosts.Count) configured OSD host entry(ies) from ceph-config.json with the running Ceph cluster..." -Console

foreach ($osdHostConfig in $osdHosts) {
    if ($null -eq $osdHostConfig) { continue }

    $osdNodeName = if ($osdHostConfig.PSObject.Properties.Name -contains 'node') { "$($osdHostConfig.node)".Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($osdNodeName)) { continue }

    $osdNodeOs = if ($osdHostConfig.PSObject.Properties.Name -contains 'os') { "$($osdHostConfig.os)".Trim().ToLowerInvariant() } else { 'linux' }
    if (-not [string]::IsNullOrWhiteSpace($osdNodeOs) -and $osdNodeOs -ne 'linux') {
        Write-Log "[Ceph] OSD host '$osdNodeName' has os '$osdNodeOs'; only Linux OSD hosts are provisioned currently. Skipping." -Console
        continue
    }

    $isBootstrapOsdHost = $false
    if ($osdNodeName -eq $clusterHostNode) {
        $isBootstrapOsdHost = $true
        $osdNodeIp = $bootstrapNodeIp
        $osdNodeUser = $bootstrapNodeUser
    }
    else {
        $resolvedNode = Resolve-ClusterNodeConfigForCephHost -DeclaredHostName $osdNodeName
        if ($null -eq $resolvedNode -or $null -eq $resolvedNode.NodeConfig) {
            Write-Log "[Ceph] OSD host '$osdNodeName' is declared in ceph-config.json but not yet part of the K2s cluster (cluster.json). Skipping until the node is added." -Console
            continue
        }

        $osdNodeConfig = $resolvedNode.NodeConfig

        $osdNodeType = if ($osdNodeConfig.PSObject.Properties.Name -contains 'NodeType') { "$($osdNodeConfig.NodeType)".Trim() } else { '' }
        if (-not [string]::Equals($osdNodeType, 'VM-EXISTING', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Log "[Ceph] ERROR: OSD host '$osdNodeName' has NodeType '$osdNodeType'. Ceph OSD provisioning supports only Hyper-V worker nodes (NodeType 'VM-EXISTING')." -Console -Error
            exit 1
        }

        $osdNodeIp = "$($osdNodeConfig.IpAddress)".Trim()
        $osdNodeUser = "$($osdNodeConfig.Username)".Trim()
    }

    if ([string]::IsNullOrWhiteSpace($osdNodeUser)) { $osdNodeUser = 'remote' }
    if ([string]::IsNullOrWhiteSpace($osdNodeIp)) {
        Write-Log "[Ceph] WARNING: Could not resolve an IP address for OSD host '$osdNodeName'. Skipping." -Console
        continue
    }

    # Resolve the cephadm host name (as cephadm identifies it) via 'hostname -s'.
    $hostnameResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'hostname -s' -UserName $osdNodeUser -IpAddress $osdNodeIp -NoLog -IgnoreErrors -Retries 2
    $orchestratorHostName = (($hostnameResult.Output | Out-String).Trim() -split "`r?`n" | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($orchestratorHostName)) { $orchestratorHostName = $osdNodeName }

    Write-Log "[Ceph] Evaluating configured OSD host '$orchestratorHostName' ($osdNodeIp) from ceph-config.json..." -Console

    if ($orchHostLsText -match [regex]::Escape($orchestratorHostName)) {
        Write-Log "[Ceph] OSD host '$orchestratorHostName' ($osdNodeIp) is already part of the Ceph cluster. Ignoring this host entry." -Console
        continue
    }

    Write-Log "[Ceph] OSD host '$orchestratorHostName' ($osdNodeIp) is configured but not yet part of the Ceph cluster. This node will be added now." -Console

    [uint32]$osdCount = 1
    if ($osdHostConfig.PSObject.Properties.Name -contains 'osdCount') {
        $parsedOsdCount = 0
        if ([uint32]::TryParse("$($osdHostConfig.osdCount)".Trim(), [ref]$parsedOsdCount) -and $parsedOsdCount -gt 0) { $osdCount = $parsedOsdCount }
    }

    [uint32]$osdDiskSizeGB = 20
    $osdDiskSizesGB = @()
    if ($osdHostConfig.PSObject.Properties.Name -contains 'osdSizesInGb' -and $null -ne $osdHostConfig.osdSizesInGb) {
        foreach ($sizeEntry in @($osdHostConfig.osdSizesInGb)) {
            $parsedSize = 0
            if ([uint32]::TryParse("$sizeEntry".Trim(), [ref]$parsedSize) -and $parsedSize -gt 0) {
                $osdDiskSizesGB += $parsedSize
            }
            else {
                Write-Log "[Ceph] WARNING: Invalid osdSizesInGb entry '$sizeEntry' for host '$orchestratorHostName'. Ignoring this entry." -Console
            }
        }
        if ($osdDiskSizesGB.Count -gt 0) {
            $osdDiskSizeGB = $osdDiskSizesGB[0]
        }
    }

    if ($osdDiskSizesGB.Count -eq 0 -and $osdHostConfig.PSObject.Properties.Name -contains 'osdSizeInGb') {
        $parsedSize = 0
        if ([uint32]::TryParse("$($osdHostConfig.osdSizeInGb)".Trim(), [ref]$parsedSize) -and $parsedSize -gt 0) { $osdDiskSizeGB = $parsedSize }
    }

    if ($osdDiskSizesGB.Count -gt 0) {
        Write-Log "[Ceph] Preparing OSD host '$orchestratorHostName' ($osdNodeIp): count=$osdCount, sizesInGb=[$($osdDiskSizesGB -join ', ')]" -Console
    }
    else {
        Write-Log "[Ceph] Preparing OSD host '$orchestratorHostName' ($osdNodeIp): count=$osdCount, size=${osdDiskSizeGB}GiB" -Console
    }

    if ($isBootstrapOsdHost) {
        Write-Log "[Ceph] OSD host '$orchestratorHostName' is the cluster/bootstrap host; skipping prepare-ceph-osd-host.sh because bootstrap already installed required host packages." -Console
    }
    else {
        $prepareHostArgs = @($cephPubKey, $proxy)
        if (-not [string]::IsNullOrWhiteSpace($cephImage)) {
            $prepareHostArgs += $cephImage
        }
        $hostPrepOutput = Invoke-RemoteScript -LocalScriptPath $prepareHostScript `
                            -UserName $osdNodeUser `
                            -IpAddress $osdNodeIp `
                            -UserPwd '' `
                            -Arguments $prepareHostArgs `
                            -CleanupAfterExecution `
                            -Retries 2 -DetailedLogging

        if (-not (($hostPrepOutput | Out-String) -match 'K2S_CEPH_OSD_HOST_READY=1')) {
            Write-Log "[Ceph] ERROR: OSD host preparation did not complete successfully on node '$osdNodeIp'." -Console -Error
            exit 1
        }
    }

    $maxHostAddAttempts = 6
    $hostRegistered = $false
    for ($hostAddAttempt = 1; $hostAddAttempt -le $maxHostAddAttempts; $hostAddAttempt++) {
        Write-Log "[Ceph] Registering OSD host '$orchestratorHostName' ($osdNodeIp) with the Ceph orchestrator (attempt $hostAddAttempt/$maxHostAddAttempts)..." -Console
        $hostAddResult = Invoke-CmdOnVmViaSSHKey `
                            -CmdToExecute "sudo cephadm shell -- ceph orch host add $orchestratorHostName $osdNodeIp" `
                            -UserName $bootstrapNodeUser `
                            -IpAddress $bootstrapNodeIp `
                            -IgnoreErrors

        $hostAddOutput = if ($null -ne $hostAddResult) { ($hostAddResult.Output | Out-String).Trim() } else { '' }

        if ($hostAddResult.Success) {
            Write-Log "[Ceph] OSD host '$orchestratorHostName' registered successfully." -Console
            $hostRegistered = $true
            $orchHostLsText += "`n$orchestratorHostName"
            break
        }

        $verifyResult = Invoke-CmdOnVmViaSSHKey `
                            -CmdToExecute 'sudo cephadm shell -- ceph orch host ls' `
                            -UserName $bootstrapNodeUser `
                            -IpAddress $bootstrapNodeIp `
                            -NoLog `
                            -IgnoreErrors
        if (($verifyResult.Output | Out-String) -match [regex]::Escape($orchestratorHostName)) {
            Write-Log "[Ceph] OSD host '$orchestratorHostName' is already present in the Ceph orchestrator host list." -Console
            $hostRegistered = $true
            $orchHostLsText += "`n$orchestratorHostName"
            break
        }

        if (-not [string]::IsNullOrWhiteSpace($hostAddOutput)) {
            Write-Log "[Ceph] ceph orch host add output: $hostAddOutput" -Console
        }

        if ($hostAddAttempt -lt $maxHostAddAttempts) {
            Write-Log "[Ceph] Orchestrator not ready yet; retrying in 10s..." -Console
            Start-Sleep -Seconds 10
        }
    }

    if (-not $hostRegistered) {
        Write-Log "[Ceph] ERROR: Could not register OSD host '$orchestratorHostName' ($osdNodeIp) with the Ceph orchestrator after $maxHostAddAttempts attempts." -Console -Error
        exit 1
    }

    Write-Log "[Ceph] OSD host '$orchestratorHostName' has been added to the Ceph cluster and will now be provisioned based on ceph-config.json." -Console

    # Label the host as an OSD host once before creating OSDs.
    Write-Log "[Ceph] Adding host label (osd) on '$orchestratorHostName'..." -Console
    $addLabelsOutput = Invoke-RemoteScript -LocalScriptPath $addOsdScript `
                            -UserName $bootstrapNodeUser `
                            -IpAddress $bootstrapNodeIp `
                            -UserPwd '' `
                            -Arguments @($orchestratorHostName) `
                            -CleanupAfterExecution `
                            -Retries 2 -DetailedLogging
    if (($addLabelsOutput | Out-String) -match '\[CephOsdAdd\]\s+ERROR:') {
        Write-Log "[Ceph] ERROR: Failed while adding host labels on '$orchestratorHostName'. See previous CephOsdAdd logs." -Console -Error
        exit 1
    }

    for ($osdIndex = 1; $osdIndex -le $osdCount; $osdIndex++) {
        [uint32]$currentOsdDiskSizeGB = $osdDiskSizeGB
        if ($osdDiskSizesGB.Count -gt 0) {
            if ($osdIndex -le $osdDiskSizesGB.Count) {
                $currentOsdDiskSizeGB = [uint32]$osdDiskSizesGB[$osdIndex - 1]
            }
            else {
                Write-Log "[Ceph] ERROR: OSD host '$orchestratorHostName' defines osdCount=$osdCount but only $($osdDiskSizesGB.Count) osdSizesInGb values. Provide one size per OSD or use osdSizeInGb as a common size." -Console -Error
                exit 1
            }
        }

        Write-Log "[Ceph] Preparing OSD disk #$osdIndex of $osdCount on host '$orchestratorHostName' ($osdNodeIp)..." -Console

        $prepareDiskParams = @{
            NodeIp                 = $osdNodeIp
            UserName               = $osdNodeUser
            DiskSizeGB             = $currentOsdDiskSizeGB
            OsdIndex               = $osdIndex
            CreateNewDisk          = ($osdIndex -gt 1)
            RemoveExistingOsdDisks = ($osdIndex -eq 1)
            Config                 = $Config
            ShowLogs               = $ShowLogs
        }

        $prepareDiskOutput = & $prepareDiskScript @prepareDiskParams
        if ($LASTEXITCODE -ne 0) {
            Write-Log "[Ceph] ERROR: OSD disk preparation failed on host '$orchestratorHostName' for OSD #$osdIndex (exit code $LASTEXITCODE)." -Console -Error
            exit 1
        }

        $prepareDiskOutputText = ($prepareDiskOutput | Out-String)
        $preparedDiskLine = $prepareDiskOutputText -split "`r?`n" | Where-Object { $_.Trim().StartsWith('K2S_CEPH_OSD_DISK=') } | Select-Object -Last 1
        $preparedDisk = if (-not [string]::IsNullOrWhiteSpace($preparedDiskLine)) { $preparedDiskLine.Trim().Substring('K2S_CEPH_OSD_DISK='.Length).Trim() } else { '' }
        if ([string]::IsNullOrWhiteSpace($preparedDisk)) {
            Write-Log "[Ceph] ERROR: OSD disk preparation for OSD #$osdIndex on '$orchestratorHostName' finished but no device path was returned." -Console -Error
            exit 1
        }

        Write-Log "[Ceph] Creating OSD #$osdIndex on '$($orchestratorHostName):$($preparedDisk)'..." -Console
        $createOsdScriptArgs = @($orchestratorHostName, $preparedDisk)
        if (-not [string]::IsNullOrWhiteSpace($clusterFsid)) { $createOsdScriptArgs += $clusterFsid }

        $addOsdOutput = Invoke-RemoteScript -LocalScriptPath $addOsdScript `
                            -UserName $bootstrapNodeUser `
                            -IpAddress $bootstrapNodeIp `
                            -UserPwd '' `
                            -Arguments $createOsdScriptArgs `
                            -CleanupAfterExecution `
                            -Retries 2 -DetailedLogging
        if (($addOsdOutput | Out-String) -match '\[CephOsdAdd\]\s+ERROR:') {
            Write-Log "[Ceph] ERROR: Failed while creating OSD #$osdIndex on '$orchestratorHostName'. See previous CephOsdAdd logs." -Console -Error
            exit 1
        }
    }

    Write-Log "[Ceph] OSD host '$orchestratorHostName' ($osdNodeIp) provisioned with $osdCount OSD(s)." -Console
    $reconciledCount++
}

# Final orchestrator reconciliation: refresh device inventory and let cephadm schedule OSDs on
# any remaining available devices (helps surface delayed OSDs in the dashboard).
Write-Log "[Ceph] Refreshing cephadm device inventory after OSD setup..." -Console
$refreshDevicesResult = Invoke-CmdOnVmViaSSHKey `
                        -CmdToExecute "sudo cephadm shell -- ceph orch device ls --refresh" `
                        -UserName $bootstrapNodeUser `
                        -IpAddress $bootstrapNodeIp `
                        -NoLog `
                        -IgnoreErrors
if (-not $refreshDevicesResult.Success) {
    $refreshDevicesOutput = if ($null -ne $refreshDevicesResult) { ($refreshDevicesResult.Output | Out-String).Trim() } else { '' }
    Write-Log "[Ceph] WARNING: 'ceph orch device ls --refresh' failed; continuing." -Console
    if (-not [string]::IsNullOrWhiteSpace($refreshDevicesOutput)) { Write-Log "[Ceph] Output: $refreshDevicesOutput" }
}

Write-Log "[Ceph] Applying cephadm OSD reconciliation on all available devices..." -Console
$applyAllDevicesResult = Invoke-CmdOnVmViaSSHKey `
                        -CmdToExecute "sudo cephadm shell -- ceph orch apply osd --all-available-devices" `
                        -UserName $bootstrapNodeUser `
                        -IpAddress $bootstrapNodeIp `
                        -NoLog `
                        -IgnoreErrors
if (-not $applyAllDevicesResult.Success) {
    $applyAllDevicesOutput = if ($null -ne $applyAllDevicesResult) { ($applyAllDevicesResult.Output | Out-String).Trim() } else { '' }
    Write-Log "[Ceph] WARNING: 'ceph orch apply osd --all-available-devices' failed; continuing with explicit OSD state." -Console
    if (-not [string]::IsNullOrWhiteSpace($applyAllDevicesOutput)) { Write-Log "[Ceph] Output: $applyAllDevicesOutput" }
}

if ($reconciledCount -eq 0) {
    Write-Log '[Ceph] All declared OSD hosts are already part of the Ceph cluster; nothing to do.' -Console
}
else {
    Write-Log "[Ceph] Reconciled $reconciledCount new OSD host(s) into the Ceph cluster." -Console
}

exit 0
