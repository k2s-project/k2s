# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Creates a new Ceph cluster on a Debian Linux target node.

.DESCRIPTION
Invoked by the storage/ceph addon Enable.ps1 when ceph-config.json sets
'clusterMode' to a value other than 'existing' and 'clusterDistribution' resolves
to 'debian13'. Provisions a fresh Ceph cluster on the node identified by -NodeIp and
writes the resulting connection details (monitorEndpoints, cephKey, clusterId) back
into the provided configuration so the subsequent CSI installation can connect.

.PARAMETER NodeIp
IP address of the cluster/bootstrap node that will host the new Ceph cluster
(resolved from ceph-config.json 'clusterHost.node').

.PARAMETER Config
The parsed ceph-config.json object.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'IP address of the target Ceph host node')]
    [string] $NodeIp,
    [parameter(Mandatory = $false, HelpMessage = 'Parsed ceph-config.json object')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot/../../../../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../../../lib/modules/windows/node/k2s.node.module/k2s.node.module.psm1"
$clusterConfigModule = "$PSScriptRoot/../../../../../../lib/modules/windows/infra/k2s.infra.module/config/cluster.config.module.psm1"
$proxyModule = "$PSScriptRoot/../../../../../../lib/modules/windows/node/k2s.node.module/windowsnode/proxy/proxy.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterConfigModule, $proxyModule
Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "[Ceph] Creating new Ceph cluster on node '$NodeIp'" -Console

function Get-CephadminDownloadUrlFromStorageManifest {
    $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\addon.manifest.yaml'
    $manifestPath = [System.IO.Path]::GetFullPath($manifestPath)

    if (!(Test-Path -Path $manifestPath)) {
        throw "[Ceph] Storage addon manifest not found at '$manifestPath'"
    }

    $manifestContent = Get-Content -Path $manifestPath -Raw
    if ([string]::IsNullOrWhiteSpace($manifestContent)) {
        throw "[Ceph] Storage addon manifest is empty: '$manifestPath'"
    }

    $urlRef = Get-Content -Path $manifestPath |
        ForEach-Object {
            if ($_ -match '^\s*url:\s*(https?://\S+)\s*$') {
                $Matches[1]
            }
        } |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($urlRef)) {
        throw "[Ceph] No valid cephadm download URL found in storage addon manifest '$manifestPath'"
    }

    Write-Log "[Ceph] Using Ceph admin download URL: '$urlRef'" -Console
    return $urlRef
}

<#
.SYNOPSIS
Reads the Ceph image reference from the storage addon manifest.
#>
function Get-CephImageFromStorageManifest {
    $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\addon.manifest.yaml'
    $manifestPath = [System.IO.Path]::GetFullPath($manifestPath)

    if (!(Test-Path -Path $manifestPath)) {
        throw "[CephSMB] Storage addon manifest not found at '$manifestPath'"
    }

    $imageRef = Get-Content -Path $manifestPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -like '- quay.io/ceph/ceph:*' } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($imageRef)) {
        throw "[CephSMB] No quay.io/ceph/ceph:<tag> image found in storage addon additionalImages in '$manifestPath'"
    }

    return ($imageRef -replace '^-\s*', '')
}

<#
.SYNOPSIS
Runs the Debian Ceph cluster bootstrap script on the target node.

.DESCRIPTION
Copies create-ceph-cluster.sh to the target node and executes it remotely,
following the same pattern as Get-BuildahDebPackagesFromInternet. The remote
script bootstraps a new Ceph cluster and creates the CephFS filesystem/pool
named in the addon configuration.
#>
Function New-CephClusterOnNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [string]$CephFsFilesystem = $(throw 'Argument missing: CephFsFilesystem'),
        [string]$CephFsPool = $(throw 'Argument missing: CephFsPool'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$CephadminUrl = $(throw 'Argument missing: CephadminUrl'),
        [string]$OsdCrushChooseleafType = '',
        [string]$MonCount = '',
        [string]$MgrCount = '',
        [string]$MdsCount = '',
        [string]$TotalOsdCount = '',
        [string]$Proxy = '',
        [string]$InstalledDistribution = 'debian',
        [string]$CephImage = ''
    )

    $scriptSourcePath = "$PSScriptRoot\create-ceph-cluster.sh"
    $scriptOutput = Invoke-RemoteScript -LocalScriptPath $scriptSourcePath `
                        -UserName $UserName `
                        -IpAddress $IpAddress `
                        -UserPwd $UserPwd `
                        -Arguments @($Proxy, $CephadminUrl, $CephFsFilesystem, 'root', $OsdCrushChooseleafType, $MonCount, $MgrCount, $MdsCount, $TotalOsdCount, $CephImage) `
                        -CleanupAfterExecution `
                        -Retries 0 -DetailedLogging

    Write-Log '[Ceph] Finished new Ceph cluster bootstrap'

    return $scriptOutput
}

function Resolve-CephNodeAccess {
    param (
        [Parameter(Mandatory = $true)][string]$NodeName
    )

    $resolvedNodeName = "$NodeName".Trim()
    $resolvedUserName = 'remote'
    $resolvedIpAddress = ''

    if ([string]::IsNullOrWhiteSpace($resolvedNodeName)) {
        return [pscustomobject]@{ NodeName = ''; UserName = $resolvedUserName; IpAddress = ''; NodeType = '' }
    }

    $controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
    if ($resolvedNodeName -eq $controlPlaneNodeName) {
        $resolvedIpAddress = "$(Get-ConfiguredIPControlPlane)".Trim()
        $resolvedUserName = "$(Get-DefaultUserNameControlPlane)".Trim()
        if ([string]::IsNullOrWhiteSpace($resolvedUserName)) { $resolvedUserName = 'remote' }
        return [pscustomobject]@{ NodeName = $resolvedNodeName; UserName = $resolvedUserName; IpAddress = $resolvedIpAddress; NodeType = 'VM-EXISTING' }
    }

    $resolvedNodeType = ''
    try {
        $targetNodeConfig = Get-NodeConfig -NodeName $resolvedNodeName
        if ($null -ne $targetNodeConfig) {
            if (-not [string]::IsNullOrWhiteSpace($targetNodeConfig.Username)) { $resolvedUserName = $targetNodeConfig.Username }
            if (-not [string]::IsNullOrWhiteSpace($targetNodeConfig.IpAddress)) { $resolvedIpAddress = "$($targetNodeConfig.IpAddress)".Trim() }
            if (-not [string]::IsNullOrWhiteSpace($targetNodeConfig.NodeType)) { $resolvedNodeType = "$($targetNodeConfig.NodeType)".Trim() }
        }
    }
    catch {
        Write-Log "[Ceph] WARNING: Could not resolve access details for node '$resolvedNodeName': $($_.Exception.Message)" -Console
    }

    return [pscustomobject]@{ NodeName = $resolvedNodeName; UserName = $resolvedUserName; IpAddress = $resolvedIpAddress; NodeType = $resolvedNodeType }
}

<#
.SYNOPSIS
Builds a normalized OSD host descriptor from a host section of ceph-config.json.

.DESCRIPTION
Reads osdCount (default 1) and osdSizesInGb/osdSizeInGb (default 20) from an entry of the
'osdHosts' array and returns a uniform descriptor used by the OSD provisioning loop.
#>
function New-CephHostDescriptor {
    param (
        [pscustomobject]$HostConfig,
        [Parameter(Mandatory = $true)][string]$NodeName,
        [Parameter(Mandatory = $true)][string]$NodeIp,
        [Parameter(Mandatory = $true)][string]$UserName,
        [bool]$IsBootstrapNode = $false
    )

    [uint32]$osdCount = 1
    [uint32]$osdDiskSizeGB = 20
    $osdDiskSizesGB = @()

    if ($null -ne $HostConfig) {
        $configuredCount = if ($HostConfig.PSObject.Properties.Name -contains 'osdCount') { "$($HostConfig.osdCount)".Trim() } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($configuredCount)) {
            $parsedCount = 0
            if ([uint32]::TryParse($configuredCount, [ref]$parsedCount) -and $parsedCount -gt 0) { $osdCount = $parsedCount }
            else { Write-Log "[Ceph] WARNING: Invalid osdCount '$configuredCount' for host '$NodeName'. Falling back to $osdCount." -Console }
        }

        if ($HostConfig.PSObject.Properties.Name -contains 'osdSizesInGb' -and $null -ne $HostConfig.osdSizesInGb) {
            foreach ($sizeEntry in @($HostConfig.osdSizesInGb)) {
                $parsedSize = 0
                if ([uint32]::TryParse("$sizeEntry".Trim(), [ref]$parsedSize) -and $parsedSize -gt 0) {
                    $osdDiskSizesGB += $parsedSize
                }
                else {
                    Write-Log "[Ceph] WARNING: Invalid osdSizesInGb entry '$sizeEntry' for host '$NodeName'. Ignoring this entry." -Console
                }
            }
            if ($osdDiskSizesGB.Count -gt 0) {
                $osdDiskSizeGB = $osdDiskSizesGB[0]
            }
        }

        if ($osdDiskSizesGB.Count -eq 0) {
            $configuredSize = if ($HostConfig.PSObject.Properties.Name -contains 'osdSizeInGb') { "$($HostConfig.osdSizeInGb)".Trim() } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($configuredSize)) {
                $parsedSize = 0
                if ([uint32]::TryParse($configuredSize, [ref]$parsedSize) -and $parsedSize -gt 0) { $osdDiskSizeGB = $parsedSize }
                else { Write-Log "[Ceph] WARNING: Invalid osdSizeInGb '$configuredSize' for host '$NodeName'. Falling back to ${osdDiskSizeGB} GiB." -Console }
            }
        }
    }

    return [pscustomobject]@{
        NodeName         = "$NodeName".Trim()
        NodeIp           = "$NodeIp".Trim()
        UserName         = if ([string]::IsNullOrWhiteSpace($UserName)) { 'remote' } else { "$UserName".Trim() }
        OsdCount         = $osdCount
        OsdDiskSizeGB    = $osdDiskSizeGB
        OsdDiskSizesGB   = @($osdDiskSizesGB)
        IsBootstrapNode  = $IsBootstrapNode
    }
}

<#
.SYNOPSIS
Returns the ordered list of OSD host descriptors from osdHosts.
#>
function Get-CephHostDescriptors {
    param (
        [pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$BootstrapNodeName,
        [Parameter(Mandatory = $true)][string]$BootstrapNodeIp,
        [Parameter(Mandatory = $true)][string]$BootstrapNodeUserName
    )

    $descriptors = @()

    if ($null -ne $Config -and ($Config.PSObject.Properties.Name -contains 'osdHosts') -and $null -ne $Config.osdHosts) {
        foreach ($osdHostConfig in @($Config.osdHosts)) {
            if ($null -eq $osdHostConfig) { continue }
            $osdNodeName = if ($osdHostConfig.PSObject.Properties.Name -contains 'node') { "$($osdHostConfig.node)".Trim() } else { '' }
            if ([string]::IsNullOrWhiteSpace($osdNodeName)) { continue }

            $osdNodeOs = if ($osdHostConfig.PSObject.Properties.Name -contains 'os') { "$($osdHostConfig.os)".Trim().ToLowerInvariant() } else { 'linux' }
            if (-not [string]::IsNullOrWhiteSpace($osdNodeOs) -and $osdNodeOs -ne 'linux') {
                Write-Log "[Ceph] WARNING: OSD host '$osdNodeName' has os '$osdNodeOs'; only Linux OSD hosts are provisioned currently. Skipping it." -Console
                continue
            }

            $access = $null
            $isBootstrapNode = $false
            if ($osdNodeName -eq $BootstrapNodeName) {
                $access = [pscustomobject]@{ NodeName = $BootstrapNodeName; UserName = $BootstrapNodeUserName; IpAddress = $BootstrapNodeIp }
                $isBootstrapNode = $true
            }
            else {
                $access = Resolve-CephNodeAccess -NodeName $osdNodeName
                if ([string]::IsNullOrWhiteSpace($access.IpAddress)) {
                    Write-Log "[Ceph] WARNING: Could not resolve an IP address for OSD host '$osdNodeName' from cluster.json. Skipping it." -Console
                    continue
                }
                if (-not [string]::Equals("$($access.NodeType)", 'VM-EXISTING', [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-Log "[Ceph] ERROR: OSD host '$osdNodeName' has NodeType '$($access.NodeType)'. Ceph OSD provisioning supports only Hyper-V worker nodes (NodeType 'VM-EXISTING')." -Console -Error
                    exit 1
                }
            }

            $descriptors += (New-CephHostDescriptor -HostConfig $osdHostConfig -NodeName $osdNodeName -NodeIp $access.IpAddress -UserName $access.UserName -IsBootstrapNode $isBootstrapNode)
        }
    }

    if ($descriptors.Count -eq 0) {
        Write-Log "[Ceph] WARNING: No valid OSD host entries were resolved from ceph-config.json 'osdHosts'. The Ceph cluster was created without OSD provisioning." -Console
    }

    return , $descriptors
}

<#
.SYNOPSIS
Detaches and deletes OSD virtual disks that were created during the current run.

.DESCRIPTION
Rolls back ceph-osd-*.vhdx files created earlier in the same OSD-provisioning loop when a
later OSD (or cluster) step fails. Without this, a partially successful run leaves those
disks attached to the VM where they accumulate across retries (sdb, sdc, sdf, ...) and
break single-new-device detection on subsequent enable attempts. The owning VM is resolved
by matching the VHDX path against every VM's attached disks, so no VM name is required.
#>
function Remove-CreatedOsdVhdxPaths {
    param(
        [string[]] $VhdxPaths
    )

    if ($null -eq $VhdxPaths -or $VhdxPaths.Count -eq 0) { return }

    foreach ($vhdxPath in $VhdxPaths) {
        if ([string]::IsNullOrWhiteSpace($vhdxPath)) { continue }

        try {
            $attachedDrives = @(Get-VM -ErrorAction SilentlyContinue |
                    Get-VMHardDiskDrive -ErrorAction SilentlyContinue |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) -and $_.Path -eq $vhdxPath })
            foreach ($drive in $attachedDrives) {
                Remove-VMHardDiskDrive -VMName $drive.VMName -ControllerType $drive.ControllerType -ControllerNumber $drive.ControllerNumber -ControllerLocation $drive.ControllerLocation -ErrorAction SilentlyContinue
                Write-Log "[Ceph] Rollback: detached OSD virtual disk '$vhdxPath' from VM '$($drive.VMName)'." -Console
            }
        }
        catch {
            Write-Log "[Ceph] Rollback: WARNING - could not detach OSD virtual disk '$vhdxPath': $($_.Exception.Message)" -Console
        }

        try {
            if (Test-Path $vhdxPath) {
                Remove-Item -Path $vhdxPath -Force -ErrorAction Stop
                Write-Log "[Ceph] Rollback: deleted orphaned OSD virtual disk '$vhdxPath'." -Console
            }
        }
        catch {
            Write-Log "[Ceph] Rollback: WARNING - could not delete OSD virtual disk file '$vhdxPath': $($_.Exception.Message)" -Console
        }
    }
}

function Invoke-CephOsdPreparation {
    param (
        [Parameter(Mandatory = $true)][string]$BootstrapNodeName,
        [Parameter(Mandatory = $true)][string]$BootstrapNodeIp,
        [Parameter(Mandatory = $true)][string]$BootstrapNodeUserName,
        [string]$CephPubKey = '',
        [string]$Proxy = '',
        [string]$CephImage = '',
        [pscustomobject]$Config,
        [switch]$ShowLogs = $false
    )

    $prepareDiskScript = Join-Path $PSScriptRoot 'osd\New-CephOsdDisk.ps1'
    if (-not (Test-Path $prepareDiskScript)) {
        Write-Log "[Ceph] ERROR: OSD disk preparation orchestrator not found: '$prepareDiskScript'" -Console -Error
        exit 1
    }

    $prepareHostScript = Join-Path $PSScriptRoot 'prepare-ceph-osd-host.sh'
    $addOsdScript = Join-Path $PSScriptRoot 'add-ceph-host-labels-and-osd.sh'
    if (-not (Test-Path $addOsdScript)) {
        Write-Log "[Ceph] ERROR: Ceph OSD add script not found: '$addOsdScript'" -Console -Error
        exit 1
    }

    $clusterFsid = if ($null -ne $Config) { "$($Config.clusterId)".Trim() } else { '' }

    $hostDescriptors = Get-CephHostDescriptors -Config $Config -BootstrapNodeName $BootstrapNodeName -BootstrapNodeIp $BootstrapNodeIp -BootstrapNodeUserName $BootstrapNodeUserName

    # Track OSD disk paths (Hyper-V VHDX) for rollback and cleanup validation across all hosts.
    $osdDiskPaths = @()
    # Track devices that had successful OSD provisioning so orphaned OSDs can be cleaned on failure.
    $provisionedOsdDevices = @()

    foreach ($hostDescriptor in $hostDescriptors) {
        $osdNodeIp = $hostDescriptor.NodeIp
        $osdNodeUser = $hostDescriptor.UserName
        $osdCount = $hostDescriptor.OsdCount
        $osdDiskSizeGB = $hostDescriptor.OsdDiskSizeGB
        $osdDiskSizesGB = @($hostDescriptor.OsdDiskSizesGB)
        $orchestratorHostName = $hostDescriptor.NodeName

        if ([string]::IsNullOrWhiteSpace($orchestratorHostName)) {
            $hostnameResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'hostname -s' -UserName $osdNodeUser -IpAddress $osdNodeIp -NoLog -IgnoreErrors -Retries 2
            $orchestratorHostName = (($hostnameResult.Output | Out-String).Trim() -split "`r?`n" | Select-Object -First 1).Trim()
        }

        if ([string]::IsNullOrWhiteSpace($orchestratorHostName)) {
            Write-Log "[Ceph] ERROR: Could not resolve Ceph host name for node '$osdNodeIp' to add labels/osd." -Console -Error
            exit 1
        }

        if ($hostDescriptor.IsBootstrapNode) {
            Write-Log "[Ceph] Bootstrap node '$BootstrapNodeIp' ($orchestratorHostName) is also an OSD host; skipping prepare-ceph-osd-host.sh because bootstrap already installed the required host packages." -Console
        }
        else {
            if ([string]::IsNullOrWhiteSpace($CephPubKey)) {
                Write-Log "[Ceph] ERROR: Cannot prepare OSD host '$osdNodeIp' because the cephadm public key was not available." -Console -Error
                exit 1
            }

            if (-not (Test-Path $prepareHostScript)) {
                Write-Log "[Ceph] ERROR: OSD host preparation script not found: '$prepareHostScript'" -Console -Error
                exit 1
            }

            Write-Log "[Ceph] Preparing remote OSD host '$osdNodeIp' ($orchestratorHostName) for cephadm..." -Console
            $prepareHostArgs = @($CephPubKey, $Proxy)
            if (-not [string]::IsNullOrWhiteSpace($CephImage)) {
                $prepareHostArgs += $CephImage
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

            # Register the freshly prepared host with the cephadm orchestrator so OSDs can be placed on it.
            # The orchestrator may need a few seconds to become fully responsive after a fresh bootstrap,
            # so we retry the registration with a delay rather than failing immediately.
            $maxHostAddAttempts = 6
            $hostRegistered = $false
            for ($hostAddAttempt = 1; $hostAddAttempt -le $maxHostAddAttempts; $hostAddAttempt++) {
                Write-Log "[Ceph] Registering OSD host '$orchestratorHostName' ($osdNodeIp) with the Ceph orchestrator (attempt $hostAddAttempt/$maxHostAddAttempts)..." -Console
                $hostAddResult = Invoke-CmdOnVmViaSSHKey `
                                    -CmdToExecute "sudo cephadm shell -- ceph orch host add $orchestratorHostName $osdNodeIp" `
                                    -UserName $BootstrapNodeUserName `
                                    -IpAddress $BootstrapNodeIp `
                                    -IgnoreErrors

                $hostAddOutput = if ($null -ne $hostAddResult) { ($hostAddResult.Output | Out-String).Trim() } else { '' }

                if ($hostAddResult.Success) {
                    Write-Log "[Ceph] OSD host '$orchestratorHostName' registered successfully." -Console
                    $hostRegistered = $true
                    break
                }

                # Even when the command returns non-zero, cephadm may have added the host (e.g. 'already exists').
                $hostLsResult = Invoke-CmdOnVmViaSSHKey `
                                    -CmdToExecute 'sudo cephadm shell -- ceph orch host ls' `
                                    -UserName $BootstrapNodeUserName `
                                    -IpAddress $BootstrapNodeIp `
                                    -NoLog `
                                    -IgnoreErrors
                if (($hostLsResult.Output | Out-String) -match [regex]::Escape($orchestratorHostName)) {
                    Write-Log "[Ceph] OSD host '$orchestratorHostName' is already present in the Ceph orchestrator host list." -Console
                    $hostRegistered = $true
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
        }

        if ($osdDiskSizesGB.Count -gt 0) {
            Write-Log "[Ceph] OSD host '$orchestratorHostName' configuration: count=$osdCount, sizesInGb=[$($osdDiskSizesGB -join ', ')]" -Console
        }
        else {
            Write-Log "[Ceph] OSD host '$orchestratorHostName' configuration: count=$osdCount, size=${osdDiskSizeGB}GiB" -Console
        }

        # Add the host label once (osd) before creating OSDs, to avoid repeating label operations per disk.
        Write-Log "[Ceph] Adding host label (osd) on '$orchestratorHostName'..." -Console
        $addLabelsOutput = Invoke-RemoteScript -LocalScriptPath $addOsdScript `
                                -UserName $BootstrapNodeUserName `
                                -IpAddress $BootstrapNodeIp `
                                -UserPwd '' `
                                -Arguments @($orchestratorHostName) `
                                -CleanupAfterExecution `
                                -Retries 2 -DetailedLogging

        if (($addLabelsOutput | Out-String) -match '\[CephOsdAdd\]\s+ERROR:') {
            Write-Log "[Ceph] ERROR: Failed while adding host labels on '$orchestratorHostName'. See previous CephOsdAdd logs." -Console -Error
            Remove-CreatedOsdVhdxPaths -VhdxPaths $osdDiskPaths
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
                    Remove-CreatedOsdVhdxPaths -VhdxPaths $osdDiskPaths
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
                Remove-CreatedOsdVhdxPaths -VhdxPaths $osdDiskPaths
                exit 1
            }

            $prepareDiskOutputText = ($prepareDiskOutput | Out-String)
            $preparedDiskLine = $prepareDiskOutputText -split "`r?`n" | Where-Object { $_.Trim().StartsWith('K2S_CEPH_OSD_DISK=') } | Select-Object -Last 1
            $preparedDisk = if (-not [string]::IsNullOrWhiteSpace($preparedDiskLine)) { $preparedDiskLine.Trim().Substring('K2S_CEPH_OSD_DISK='.Length).Trim() } else { '' }

            # Track the VHDX path if one was created (for Hyper-V nodes) BEFORE validating the device,
            # so a rollback can remove it even when the returned device path is missing.
            $vhdxPathLine = $prepareDiskOutputText -split "`r?`n" | Where-Object { $_.Trim().StartsWith('K2S_CEPH_OSD_VHDX_PATH=') } | Select-Object -Last 1
            if (-not [string]::IsNullOrWhiteSpace($vhdxPathLine)) {
                $vhdxPath = $vhdxPathLine.Trim().Substring('K2S_CEPH_OSD_VHDX_PATH='.Length).Trim()
                if (-not [string]::IsNullOrWhiteSpace($vhdxPath)) {
                    $osdDiskPaths += $vhdxPath
                }
            }

            if ([string]::IsNullOrWhiteSpace($preparedDisk)) {
                Write-Log "[Ceph] ERROR: OSD disk preparation for OSD #$osdIndex on '$orchestratorHostName' finished but no device path was returned." -Console -Error
                Remove-CreatedOsdVhdxPaths -VhdxPaths $osdDiskPaths
                exit 1
            }

            Write-Log "[Ceph] Creating OSD #$osdIndex on '$($orchestratorHostName):$($preparedDisk)'..." -Console
            $createOsdScriptArgs = @($orchestratorHostName, $preparedDisk)
            if (-not [string]::IsNullOrWhiteSpace($clusterFsid)) {
                $createOsdScriptArgs += $clusterFsid
            }

            $addOsdOutput = Invoke-RemoteScript -LocalScriptPath $addOsdScript `
                                -UserName $BootstrapNodeUserName `
                                -IpAddress $BootstrapNodeIp `
                                -UserPwd '' `
                                -Arguments $createOsdScriptArgs `
                                -CleanupAfterExecution `
                                -Retries 2 -DetailedLogging

            if (($addOsdOutput | Out-String) -match '\[CephOsdAdd\]\s+ERROR:') {
                Write-Log "[Ceph] ERROR: Failed while creating OSD #$osdIndex on '$orchestratorHostName'. See previous CephOsdAdd logs." -Console -Error
                Remove-CreatedOsdVhdxPaths -VhdxPaths $osdDiskPaths
                exit 1
            }

            # Track successful OSD provisioning for cleanup on later failure
            $provisionedOsdDevices += $preparedDisk
        }
    }

    # Final orchestrator reconciliation: refresh device inventory and let cephadm schedule OSDs
    # on any remaining available devices (observed to surface delayed third OSD details in dashboard).
    Write-Log "[Ceph] Refreshing cephadm device inventory after explicit OSD provisioning..." -Console
    $refreshDevicesResult = Invoke-CmdOnVmViaSSHKey `
                            -CmdToExecute "sudo cephadm shell -- ceph orch device ls --refresh" `
                            -UserName $BootstrapNodeUserName `
                            -IpAddress $BootstrapNodeIp `
                            -NoLog `
                            -IgnoreErrors
    if (-not $refreshDevicesResult.Success) {
        $refreshDevicesOutput = if ($null -ne $refreshDevicesResult) { ($refreshDevicesResult.Output | Out-String).Trim() } else { '' }
        Write-Log "[Ceph] WARNING: 'ceph orch device ls --refresh' failed; continuing with OSD reconciliation." -Console
        if (-not [string]::IsNullOrWhiteSpace($refreshDevicesOutput)) { Write-Log "[Ceph] Output: $refreshDevicesOutput" }
    }

    Write-Log "[Ceph] Applying cephadm OSD reconciliation on all available devices..." -Console
    $applyAllDevicesResult = Invoke-CmdOnVmViaSSHKey `
                            -CmdToExecute "sudo cephadm shell -- ceph orch apply osd --all-available-devices" `
                            -UserName $BootstrapNodeUserName `
                            -IpAddress $BootstrapNodeIp `
                            -NoLog `
                            -IgnoreErrors
    if (-not $applyAllDevicesResult.Success) {
        $applyAllDevicesOutput = if ($null -ne $applyAllDevicesResult) { ($applyAllDevicesResult.Output | Out-String).Trim() } else { '' }
        Write-Log "[Ceph] WARNING: 'ceph orch apply osd --all-available-devices' failed; continuing with explicit OSD state." -Console
        if (-not [string]::IsNullOrWhiteSpace($applyAllDevicesOutput)) { Write-Log "[Ceph] Output: $applyAllDevicesOutput" }
    }

    $configuredChooseleafType = if ($null -ne $Config -and ($Config.PSObject.Properties.Name -contains 'clusterHost') -and $null -ne $Config.clusterHost -and -not [string]::IsNullOrWhiteSpace("$($Config.clusterHost.osdCrushChooseleafType)".Trim())) {
        "$($Config.clusterHost.osdCrushChooseleafType)".Trim()
    }
    else {
        ''
    }

    # Reconcile pool replication with the number of OSDs that were actually provisioned. With
    # fewer OSDs (or fewer hosts) than the default size=3, replicated pools stay permanently
    # undersized/degraded (PG_DEGRADED / TOO_FEW_OSDS -> HEALTH_WARN). Set every pool's size to the
    # actual OSD count (capped at 3, Ceph's conventional replication maximum) and min_size to 1 so a
    # single surviving replica keeps the pool available. On OSD-level profiles (chooseleaf_type=0)
    # also apply the OSD-failure-domain rule (k2s-osd-rule) so replicas can be placed across OSDs on
    # the same host. Runs after OSD provisioning, when the pools and OSDs are consistently present.
    $cephFsName = if ($null -ne $Config -and ($Config.PSObject.Properties.Name -contains 'cephfsFilesystem')) { "$($Config.cephfsFilesystem)".Trim() } else { '' }

    # Determine how many OSDs are actually up so the pool size never exceeds the available OSDs.
    $actualOsdCount = 0
    $osdCountResult = Invoke-CmdOnVmViaSSHKey `
                        -CmdToExecute "sudo cephadm shell -- ceph osd ls" `
                        -UserName $BootstrapNodeUserName `
                        -IpAddress $BootstrapNodeIp `
                        -NoLog `
                        -IgnoreErrors `
                        -Retries 2
    if ($null -ne $osdCountResult -and $osdCountResult.Success) {
        $actualOsdCount = @(($osdCountResult.Output | Out-String) -split "`r?`n" | Where-Object { $_.Trim() -match '^\d+$' }).Count
    }
    if ($actualOsdCount -lt 1) { $actualOsdCount = 1 }
    $desiredPoolSize = [Math]::Min($actualOsdCount, 3)

    Write-Log "[Ceph] Reconciling pool replication to size=$desiredPoolSize / min_size=1 (actual OSD count=$actualOsdCount) after OSD provisioning..." -Console

    # Ensure global defaults reflect the actual OSD count for any pools created later.
    # When size=1 is required, first unlock single-replica pools (disabled by default in Ceph).
    if ($desiredPoolSize -eq 1) {
        Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo cephadm shell -- ceph config set global mon_allow_pool_size_one true" -UserName $BootstrapNodeUserName -IpAddress $BootstrapNodeIp -NoLog -IgnoreErrors | Out-Null
        Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo cephadm shell -- ceph config set mon mon_allow_pool_size_one true" -UserName $BootstrapNodeUserName -IpAddress $BootstrapNodeIp -NoLog -IgnoreErrors | Out-Null
        # Single OSD/host cannot provide redundancy; avoid permanent health warn noise.
        Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo cephadm shell -- ceph config set global mon_warn_on_pool_no_redundancy false" -UserName $BootstrapNodeUserName -IpAddress $BootstrapNodeIp -NoLog -IgnoreErrors | Out-Null
        Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo cephadm shell -- ceph health mute POOL_NO_REDUNDANCY 1w --sticky" -UserName $BootstrapNodeUserName -IpAddress $BootstrapNodeIp -NoLog -IgnoreErrors | Out-Null
    }
    else {
        # Re-enable redundancy warnings when replication > 1 is feasible again.
        Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo cephadm shell -- ceph config set global mon_warn_on_pool_no_redundancy true" -UserName $BootstrapNodeUserName -IpAddress $BootstrapNodeIp -NoLog -IgnoreErrors | Out-Null
        Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo cephadm shell -- ceph health unmute POOL_NO_REDUNDANCY" -UserName $BootstrapNodeUserName -IpAddress $BootstrapNodeIp -NoLog -IgnoreErrors | Out-Null
    }
    Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo cephadm shell -- ceph config set global osd_pool_default_size $desiredPoolSize" -UserName $BootstrapNodeUserName -IpAddress $BootstrapNodeIp -NoLog -IgnoreErrors | Out-Null
    Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo cephadm shell -- ceph config set global osd_pool_default_min_size 1" -UserName $BootstrapNodeUserName -IpAddress $BootstrapNodeIp -NoLog -IgnoreErrors | Out-Null

    $poolsToReconcile = @('.mgr')
    if (-not [string]::IsNullOrWhiteSpace($cephFsName)) {
        $poolsToReconcile += "cephfs.$cephFsName.meta"
        $poolsToReconcile += "cephfs.$cephFsName.data"
    }

    foreach ($pool in $poolsToReconcile) {
        $poolReconciled = $false
        $maxPoolAttempts = 12
        for ($poolAttempt = 1; $poolAttempt -le $maxPoolAttempts; $poolAttempt++) {
            $poolExistsResult = Invoke-CmdOnVmViaSSHKey `
                                -CmdToExecute "sudo cephadm shell -- ceph osd pool ls | grep -qx '$pool'" `
                                -UserName $BootstrapNodeUserName `
                                -IpAddress $BootstrapNodeIp `
                                -NoLog `
                                -IgnoreErrors

            if (-not $poolExistsResult.Success) {
                Write-Log "[Ceph] Pool '$pool' not available yet (attempt $poolAttempt/$maxPoolAttempts), retrying in 10s..." -Console
                Start-Sleep -Seconds 10
                continue
            }

            # On OSD-level profiles, place replicas across OSDs (not hosts) so single-host / few-host
            # clusters can satisfy the replication size.
            if ($configuredChooseleafType -eq '0') {
                Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo cephadm shell -- ceph osd pool set $pool crush_rule k2s-osd-rule" -UserName $BootstrapNodeUserName -IpAddress $BootstrapNodeIp -NoLog -IgnoreErrors | Out-Null
            }

            $setSizeCmd = if ($desiredPoolSize -eq 1) {
                "sudo cephadm shell -- ceph osd pool set $pool size $desiredPoolSize --yes-i-really-mean-it"
            } else {
                "sudo cephadm shell -- ceph osd pool set $pool size $desiredPoolSize"
            }
            $setSizeResult = Invoke-CmdOnVmViaSSHKey `
                                -CmdToExecute $setSizeCmd `
                                -UserName $BootstrapNodeUserName `
                                -IpAddress $BootstrapNodeIp `
                                -NoLog `
                                -IgnoreErrors
            Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo cephadm shell -- ceph osd pool set $pool min_size 1" -UserName $BootstrapNodeUserName -IpAddress $BootstrapNodeIp -NoLog -IgnoreErrors | Out-Null

            if ($null -ne $setSizeResult -and $setSizeResult.Success) {
                $poolReconciled = $true
                Write-Log "[Ceph] Reconciled pool '$pool' to size=$desiredPoolSize / min_size=1$(if ($configuredChooseleafType -eq '0') { ' (crush_rule=k2s-osd-rule)' })" -Console
                break
            }

            $setSizeOutput = if ($null -ne $setSizeResult) { ($setSizeResult.Output | Out-String).Trim() } else { '' }
            Write-Log "[Ceph] Failed to reconcile pool '$pool' (attempt $poolAttempt/$maxPoolAttempts), retrying in 10s..." -Console
            if (-not [string]::IsNullOrWhiteSpace($setSizeOutput)) {
                Write-Log "[Ceph] Output: $setSizeOutput"
            }
            Start-Sleep -Seconds 10
        }

        if (-not $poolReconciled) {
            $manualSizeCmd = if ($desiredPoolSize -eq 1) {
                "sudo cephadm shell -- ceph config set global mon_allow_pool_size_one true; sudo cephadm shell -- ceph osd pool set $pool size $desiredPoolSize --yes-i-really-mean-it"
            } else {
                "sudo cephadm shell -- ceph osd pool set $pool size $desiredPoolSize"
            }
            Write-Log "[Ceph] WARNING: Could not reconcile pool '$pool' to size=$desiredPoolSize/min_size=1. If health warnings reference '$pool', run: $manualSizeCmd; sudo cephadm shell -- ceph osd pool set $pool min_size 1" -Console
        }
    }

    # Store tracked OSD disk paths in config for cleanup validation by cluster ID
    if ($null -ne $Config -and $osdDiskPaths.Count -gt 0) {
        $Config | Add-Member -NotePropertyName 'osdDiskPaths' -NotePropertyValue ($osdDiskPaths | ConvertTo-Json -Compress) -Force
    }

    # Store provisioned OSD devices in config so they can be cleaned up if cluster setup fails after provisioning
    if ($null -ne $Config -and $provisionedOsdDevices.Count -gt 0) {
        $Config | Add-Member -NotePropertyName 'provisionedOsdDevices' -NotePropertyValue ($provisionedOsdDevices | ConvertTo-Json -Compress) -Force
    }
}

<#
.SYNOPSIS
Extracts the Ceph dashboard connection details from cephadm bootstrap output.

.DESCRIPTION
cephadm prints a block like:
    Ceph Dashboard is now available at:
                 URL: https://<host>:8443/
                User: admin
            Password: <password>
plus a 'Cluster fsid: <fsid>' line. This parses those values and writes them
into the shared ceph-config object so Enable.ps1 can surface them to the user.

cephadm builds the dashboard URL from the node hostname (e.g. https://deb13cephadmintest1:8443/),
which does not resolve from the K2s Windows host (and can return HTTP 404). When -NodeIp is given the
URL is rewritten to use the node IP directly before it is stored and logged, so the dashboard URL is
consistently the node IP regardless of whether the cluster runs on kubemaster or an additional node.
#>
Function Set-CephDashboardDetailsFromBootstrapOutput {
    param (
        [Parameter(Mandatory = $true)]
        $BootstrapOutput,
        [pscustomobject]$Config,
        [string]$NodeIp = ''
    )

    if ($null -eq $Config) { return }

    $outputText = ($BootstrapOutput | Out-String)

    $getMatch = {
        param([string]$Pattern)
        $m = [regex]::Match($outputText, $Pattern)
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
        return $null
    }

    $dashboardUrl = & $getMatch '(?m)^\s*URL:\s*(\S+)\s*$'
    $dashboardUser = & $getMatch '(?m)^\s*User:\s*(\S+)\s*$'
    $dashboardPassword = & $getMatch '(?m)^\s*Password:\s*(\S+)\s*$'
    $clusterFsid = & $getMatch '(?m)^\s*Cluster fsid:\s*(\S+)\s*$'

    if (-not [string]::IsNullOrWhiteSpace($dashboardUrl) -and -not [string]::IsNullOrWhiteSpace($NodeIp)) {
        $uri = $null
        try { $uri = [uri]$dashboardUrl } catch { $uri = $null }
        if ($null -eq $uri) {
            Write-Log "[Ceph] WARNING: Could not parse dashboard URL '$dashboardUrl'; leaving it unchanged." -Console
        }
        else {
            $parsedIp = $null
            $isIpHost = [System.Net.IPAddress]::TryParse($uri.Host, [ref]$parsedIp)
            if (-not $isIpHost) {
                $builder = [System.UriBuilder]$uri
                $builder.Host = $NodeIp
                $ipDashboardUrl = $builder.Uri.AbsoluteUri
                $dashboardUrl = $ipDashboardUrl
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($dashboardUrl)) {
        $Config | Add-Member -NotePropertyName 'dashboardUrl' -NotePropertyValue $dashboardUrl -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($dashboardUser)) {
        $Config | Add-Member -NotePropertyName 'dashboardUser' -NotePropertyValue $dashboardUser -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($dashboardPassword)) {
        $Config | Add-Member -NotePropertyName 'dashboardPassword' -NotePropertyValue $dashboardPassword -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($clusterFsid)) {
        $Config | Add-Member -NotePropertyName 'clusterId' -NotePropertyValue $clusterFsid -Force
    }

    # Log presence but do NOT log the password.
    Write-Log "[Ceph] Ceph dashboard available at '$dashboardUrl' (user '$dashboardUser')" -Console
}

<#
.SYNOPSIS
Reads the actual Ceph connection details from the create-ceph-cluster.sh output.

.DESCRIPTION
create-ceph-cluster.sh emits K2S_CEPH_* marker lines with the values read back
from the freshly provisioned cluster (fsid, monitor endpoints, admin key, CephFS
filesystem/pool, user). This parses those markers and writes them into the shared
ceph-config object so Enable.ps1 persists them to ceph-config.json and the CSI
driver connects to the real cluster instead of the placeholder config values.
#>
Function Set-CephConnectionDetailsFromClusterOutput {
    param (
        [Parameter(Mandatory = $true)]
        $ClusterOutput,
        [pscustomobject]$Config
    )

    if ($null -eq $Config) { return }

    $lines = ($ClusterOutput | Out-String) -split "`r?`n"

    $getMarker = {
        param([string]$Name)
        $prefix = "$Name="
        $line = $lines | Where-Object { $_.Trim().StartsWith($prefix) } | Select-Object -Last 1
        if ($null -eq $line) { return $null }
        return $line.Trim().Substring($prefix.Length).Trim()
    }

    $fsid = & $getMarker 'K2S_CEPH_FSID'
    $monEndpoints = & $getMarker 'K2S_CEPH_MON_ENDPOINTS'
    $adminKey = & $getMarker 'K2S_CEPH_ADMIN_KEY'
    $fsName = & $getMarker 'K2S_CEPH_FS_NAME'
    $dataPool = & $getMarker 'K2S_CEPH_DATA_POOL'
    $cephUser = & $getMarker 'K2S_CEPH_USER'

    if (-not [string]::IsNullOrWhiteSpace($fsid)) {
        $Config | Add-Member -NotePropertyName 'clusterId' -NotePropertyValue $fsid -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($monEndpoints)) {
        $Config | Add-Member -NotePropertyName 'monitorEndpoints' -NotePropertyValue $monEndpoints -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($adminKey)) {
        $Config | Add-Member -NotePropertyName 'cephKey' -NotePropertyValue $adminKey -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($fsName)) {
        $Config | Add-Member -NotePropertyName 'cephfsFilesystem' -NotePropertyValue $fsName -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($dataPool)) {
        $Config | Add-Member -NotePropertyName 'cephfsPool' -NotePropertyValue $dataPool -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($cephUser)) {
        $Config | Add-Member -NotePropertyName 'cephUser' -NotePropertyValue $cephUser -Force
    }

    # Do NOT print the resolved connection details to the CLI - they are already shown to the user
    # in the addon usage notes at the end of enable. Keep only a file-log line (no -Console) for
    # diagnostics, with the admin key masked.
    Write-Log "[Ceph] Resolved cluster connection details (fsid=$fsid, monitorEndpoints=$monEndpoints, cephfsFilesystem=$fsName, cephfsPool=$dataPool, cephUser=$cephUser, cephKey=<hidden>)"

    # The fsid, admin key and monitor endpoints are essential for the CSI driver to connect.
    # If any of them is missing the cluster provisioning did not complete correctly.
    $missing = @()
    if ([string]::IsNullOrWhiteSpace($fsid)) { $missing += 'clusterId (fsid)' }
    if ([string]::IsNullOrWhiteSpace($adminKey)) { $missing += 'cephKey (admin key)' }
    if ([string]::IsNullOrWhiteSpace($monEndpoints)) { $missing += 'monitorEndpoints' }

    if ($missing.Count -gt 0) {
        Write-Log "[Ceph] ERROR: Could not read essential Ceph connection details from the cluster: $($missing -join ', ')." -Console -Error
        return $false
    }

    return $true
}

$clusterHostConfig = if ($Config -and ($Config.PSObject.Properties.Name -contains 'clusterHost')) { $Config.clusterHost } else { $null }
$clusterHostNode = if ($null -ne $clusterHostConfig -and ($clusterHostConfig.PSObject.Properties.Name -contains 'node')) { "$($clusterHostConfig.node)".Trim() } else { '' }
$controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
if (-not [string]::IsNullOrWhiteSpace($clusterHostNode) -and $clusterHostNode -eq $controlPlaneNodeName) {
    # Control plane node (e.g. kubemaster) is not part of cluster.json nodes.
    $nodeUserName = "$(Get-DefaultUserNameControlPlane)".Trim()
    if ([string]::IsNullOrWhiteSpace($nodeUserName)) { $nodeUserName = 'remote' }
    Write-Log "[Ceph] Resolved control plane node connection: UserName='$nodeUserName', IpAddress='$NodeIp'" -Console
}
else {
    $nodeConfig = $null
    if (-not [string]::IsNullOrWhiteSpace($clusterHostNode)) {
        $nodeConfig = Get-NodeConfig -NodeName $clusterHostNode
    }

    if ($null -eq $nodeConfig) {
        Write-Log "[Ceph] WARNING: Node '$clusterHostNode' not found in cluster.json; falling back to NodeIp='$NodeIp' and userName='remote'" -Console
        $nodeUserName = 'remote'
    }
    else {
        $nodeUserName = $nodeConfig.Username
        Write-Log "[Ceph] Resolved node connection from cluster.json: UserName='$nodeUserName', IpAddress='$($nodeConfig.IpAddress)'" -Console
    }
}

$cephFsFilesystem = if ($Config) { "$($Config.cephfsFilesystem)".Trim() } else { '' }
$cephFsPool = if ($Config) { "$($Config.cephfsPool)".Trim() } else { '' }

$configuredOsdCrushChooseleafType = if ($null -ne $clusterHostConfig -and ($clusterHostConfig.PSObject.Properties.Name -contains 'osdCrushChooseleafType')) { "$($clusterHostConfig.osdCrushChooseleafType)".Trim() } else { '' }
if (-not [string]::IsNullOrWhiteSpace($configuredOsdCrushChooseleafType)) {
    $parsedOsdCrushChooseleafType = 0
    if (-not ([int]::TryParse($configuredOsdCrushChooseleafType, [ref]$parsedOsdCrushChooseleafType) -and $parsedOsdCrushChooseleafType -ge 0)) {
        Write-Log "[Ceph] WARNING: Invalid osdCrushChooseleafType '$configuredOsdCrushChooseleafType' in ceph-config.json. Ignoring it and using the Ceph default." -Console
        $configuredOsdCrushChooseleafType = ''
    }
}

$configuredMonCount = if ($null -ne $clusterHostConfig -and ($clusterHostConfig.PSObject.Properties.Name -contains 'monCount')) { "$($clusterHostConfig.monCount)".Trim() } else { '' }
if (-not [string]::IsNullOrWhiteSpace($configuredMonCount)) {
    $parsedMonCount = 0
    if (-not ([uint32]::TryParse($configuredMonCount, [ref]$parsedMonCount) -and $parsedMonCount -gt 0)) {
        Write-Log "[Ceph] WARNING: Invalid monCount '$configuredMonCount' in ceph-config.json. Ignoring it and using the Ceph default." -Console
        $configuredMonCount = ''
    }
}

$configuredMgrCount = if ($null -ne $clusterHostConfig -and ($clusterHostConfig.PSObject.Properties.Name -contains 'mgrCount')) { "$($clusterHostConfig.mgrCount)".Trim() } else { '' }
if (-not [string]::IsNullOrWhiteSpace($configuredMgrCount)) {
    $parsedMgrCount = 0
    if (-not ([uint32]::TryParse($configuredMgrCount, [ref]$parsedMgrCount) -and $parsedMgrCount -gt 0)) {
        Write-Log "[Ceph] WARNING: Invalid mgrCount '$configuredMgrCount' in ceph-config.json. Ignoring it and using the Ceph default." -Console
        $configuredMgrCount = ''
    }
}

$configuredMdsCount = if ($null -ne $clusterHostConfig -and ($clusterHostConfig.PSObject.Properties.Name -contains 'mdsCount')) { "$($clusterHostConfig.mdsCount)".Trim() } else { '' }
if (-not [string]::IsNullOrWhiteSpace($configuredMdsCount)) {
    $parsedMdsCount = 0
    if (-not ([uint32]::TryParse($configuredMdsCount, [ref]$parsedMdsCount) -and $parsedMdsCount -gt 0)) {
        Write-Log "[Ceph] WARNING: Invalid mdsCount '$configuredMdsCount' in ceph-config.json. Ignoring it and using the Ceph default." -Console
        $configuredMdsCount = ''
    }
}

# Compute the total number of OSDs from osdHosts only.
# create-ceph-cluster.sh uses this to right-size replicated pools (single OSD => size/min_size 1).
[uint32]$totalOsdCount = 0
if ($Config -and ($Config.PSObject.Properties.Name -contains 'osdHosts') -and $null -ne $Config.osdHosts) {
    foreach ($osdHostEntry in @($Config.osdHosts)) {
        if ($null -eq $osdHostEntry) { continue }
        $entryNodeName = if ($osdHostEntry.PSObject.Properties.Name -contains 'node') { "$($osdHostEntry.node)".Trim() } else { '' }
        if ([string]::IsNullOrWhiteSpace($entryNodeName)) { continue }

        $entryOs = if ($osdHostEntry.PSObject.Properties.Name -contains 'os') { "$($osdHostEntry.os)".Trim().ToLowerInvariant() } else { 'linux' }
        if (-not [string]::IsNullOrWhiteSpace($entryOs) -and $entryOs -ne 'linux') { continue }

        $entryOsdCount = 1
        if ($osdHostEntry.PSObject.Properties.Name -contains 'osdCount') {
            $parsedEntryOsdCount = 0
            if ([uint32]::TryParse("$($osdHostEntry.osdCount)".Trim(), [ref]$parsedEntryOsdCount) -and $parsedEntryOsdCount -gt 0) { $entryOsdCount = $parsedEntryOsdCount }
        }
        $totalOsdCount += $entryOsdCount
    }
}
$configuredTotalOsdCount = if ($totalOsdCount -gt 0) { "$totalOsdCount" } else { '' }

if ([string]::IsNullOrWhiteSpace($Proxy)) {
    $kubeSwitchIp = Get-ConfiguredKubeSwitchIP
    if ([string]::IsNullOrWhiteSpace($kubeSwitchIp)) {
        throw '[NodePkg] Could not determine KubeSwitch IP for default proxy.'
    }
    $Proxy = "http://${kubeSwitchIp}:8181"
    Write-Log "[NodePkg] No proxy specified. Defaulting to K2s transparent proxy '$Proxy'." -Console
}
$cephadminUrl = Get-CephadminDownloadUrlFromStorageManifest

$cephImage = Get-CephImageFromStorageManifest

Write-Log "[Ceph] Running remote Ceph bootstrap on '$NodeIp' using image '$cephImage'. This can take several minutes (image pull/package install)." -Console

$bootstrapOutput = New-CephClusterOnNode -UserName $nodeUserName `
                      -UserPwd '' `
                      -IpAddress $NodeIp `
                      -CephFsFilesystem $cephFsFilesystem `
                      -CephFsPool $cephFsPool `
                      -CephadminUrl $cephadminUrl `
                      -OsdCrushChooseleafType $configuredOsdCrushChooseleafType `
                      -MonCount $configuredMonCount `
                      -MgrCount $configuredMgrCount `
                      -MdsCount $configuredMdsCount `
                      -TotalOsdCount $configuredTotalOsdCount `
                      -Proxy $Proxy `
                      -InstalledDistribution 'debian' `
                      -CephImage $cephImage

# Surface the cephadm dashboard connection details (URL / user / password) back into the shared config
# object so Enable.ps1 can print them in the PowerShell console. The dashboard URL is rewritten to use
# the node IP directly (instead of the cephadm hostname) so it is reachable from the K2s Windows host
# regardless of whether the cluster runs on kubemaster or an additional node.
Set-CephDashboardDetailsFromBootstrapOutput -BootstrapOutput $bootstrapOutput -Config $Config -NodeIp $NodeIp

if ($null -ne $Config) {
    $dashboardUrl = if ($Config.PSObject.Properties.Name -contains 'dashboardUrl') { "$($Config.dashboardUrl)".Trim() } else { '' }
    $dashboardUser = if ($Config.PSObject.Properties.Name -contains 'dashboardUser') { "$($Config.dashboardUser)".Trim() } else { '' }
    $dashboardPassword = if ($Config.PSObject.Properties.Name -contains 'dashboardPassword') { "$($Config.dashboardPassword)".Trim() } else { '' }

    if (-not [string]::IsNullOrWhiteSpace($dashboardUrl)) {
        Write-Log '[Ceph] Dashboard details captured from bootstrap:' -Console
        Write-Log "[Ceph]   URL: $dashboardUrl" -Console
        if (-not [string]::IsNullOrWhiteSpace($dashboardUser)) {
            Write-Log "[Ceph]   User: $dashboardUser" -Console
        }
        if (-not [string]::IsNullOrWhiteSpace($dashboardPassword)) {
            Write-Log "[Ceph]   Password: $dashboardPassword" -Console
        }
    }
}

# After bootstrap, tell the user (on the CLI) that a new volume drive will be consumed for the
# Ceph OSD, and surface the cephadm public key so additional OSD hosts can be prepared with
# scripts\linux\debian\prepare-ceph-osd-host.sh.
Write-Log '[Ceph] A new (empty) volume drive will be consumed to create the Ceph OSD.' -Console
$cephPubKeyLine = ($bootstrapOutput | Out-String) -split "`r?`n" | Where-Object { $_.Trim().StartsWith('K2S_CEPH_PUB_KEY=') } | Select-Object -Last 1
if (-not [string]::IsNullOrWhiteSpace($cephPubKeyLine)) {
    $cephPubKeyValue = $cephPubKeyLine.Trim().Substring('K2S_CEPH_PUB_KEY='.Length).Trim()
    # Surface the cephadm public key into the shared config object so Enable.ps1 can persist it in
    # setup.json and later OSD host additions (Update.ps1 / add-node flow) can prepare new hosts.
    if (-not [string]::IsNullOrWhiteSpace($cephPubKeyValue) -and $null -ne $Config) {
        $Config | Add-Member -NotePropertyName 'cephPublicKey' -NotePropertyValue $cephPubKeyValue -Force
    }
}

# Read the ACTUAL Ceph connection values (monitor endpoints, admin key, filesystem/pool, fsid)
# from the freshly provisioned cluster back into the shared config object so Enable.ps1 persists
# them into ceph-config.json and connects the CSI driver to the real cluster.
$connectionResolved = Set-CephConnectionDetailsFromClusterOutput -ClusterOutput $bootstrapOutput -Config $Config

# Guard against any stray pipeline output from helper logging: use the last emitted value.
$connectionResolved = [bool]($connectionResolved | Select-Object -Last 1)

if (-not $connectionResolved) {
    Write-Log "[Ceph] ERROR: New Ceph cluster provisioning did not yield valid connection details on node '$NodeIp'." -Console -Error
    exit 1
}

Invoke-CephOsdPreparation -BootstrapNodeName $clusterHostNode -BootstrapNodeIp $NodeIp -BootstrapNodeUserName $nodeUserName -CephPubKey $cephPubKeyValue -Proxy $Proxy -CephImage $cephImage -Config $Config -ShowLogs:$ShowLogs

$cephFsForSubvolumeGroup = if (-not [string]::IsNullOrWhiteSpace($cephFsFilesystem)) { $cephFsFilesystem } else { 'cephfs' }

Write-Log "[Ceph] Creating CephFS subvolumegroup 'csi' in filesystem '$cephFsForSubvolumeGroup' (required by CSI driver)" -Console
# Invoke-CmdOnVmViaSSHKey returns {Success, Output} - there is no ExitCode property.
# -Retries is a no-op when -IgnoreErrors is set (retries only fire inside the catch block).
# Use our own retry loop so a transiently-unavailable MDS (just deployed by cephadm) is handled.
$subvolumeGroupCreated = $false
$lastSubvolumeGroupOutput = ''
$maxSubvolumeGroupAttempts = 5
for ($svgAttempt = 1; $svgAttempt -le $maxSubvolumeGroupAttempts; $svgAttempt++) {
    $createSubvolumeGroupResult = Invoke-CmdOnVmViaSSHKey `
                                -CmdToExecute "sudo cephadm shell ceph fs subvolumegroup create $cephFsForSubvolumeGroup csi" `
                                -UserName $nodeUserName `
                                -IpAddress $NodeIp `
                                -NoLog `
                                -IgnoreErrors
    $lastSubvolumeGroupOutput = if ($null -ne $createSubvolumeGroupResult) { ($createSubvolumeGroupResult.Output | Out-String).Trim() } else { '' }
    if ($createSubvolumeGroupResult.Success -or $lastSubvolumeGroupOutput -imatch 'already exists|eexist') {
        $subvolumeGroupCreated = $true
        break
    }
    Write-Log "[Ceph] Subvolumegroup create attempt $svgAttempt/$maxSubvolumeGroupAttempts failed (MDS may not be ready yet), retrying in 10s..." -Console
    if (-not [string]::IsNullOrWhiteSpace($lastSubvolumeGroupOutput)) {
        Write-Log "[Ceph] Output: $lastSubvolumeGroupOutput"
    }
    Start-Sleep -Seconds 10
}
if (-not $subvolumeGroupCreated) {
    Write-Log "[Ceph] ERROR: Failed to create subvolumegroup 'csi' in CephFS filesystem '$cephFsForSubvolumeGroup' after $maxSubvolumeGroupAttempts attempts on node '$NodeIp'." -Console -Error
    if (-not [string]::IsNullOrWhiteSpace($lastSubvolumeGroupOutput)) {
        Write-Log "[Ceph] Last command output: $lastSubvolumeGroupOutput" -Console -Error
    }
    exit 1
}
Write-Log "[Ceph] Subvolumegroup 'csi' created (or already exists) in CephFS filesystem '$cephFsForSubvolumeGroup'" -Console

Write-Log "[Ceph] Ceph cluster connection details resolved successfully"
exit 0
