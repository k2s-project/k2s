# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables Ceph CSI storage provisioner addon

.DESCRIPTION
Removes Ceph CSI operator components and optionally removes PersistentVolumes.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.

.PARAMETER Force
Delete all PersistentVolumes when disabling (data loss)
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Delete all PersistentVolumes (data loss)')]
    [switch] $Force = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule
Initialize-Logging -ShowLogs:$ShowLogs

function Get-CephSmbManifestSourceDir {
    $candidateDirs = @(
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\smb\manifests')),
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'manifests\smb-shared'))
    )

    foreach ($candidateDir in $candidateDirs) {
        if (Test-Path -LiteralPath $candidateDir) {
            return $candidateDir
        }
    }

    return $null
}

function New-CephSmbManifestWorkDir {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Namespace
    )

    $sourceDir = Get-CephSmbManifestSourceDir
    if ([string]::IsNullOrWhiteSpace($sourceDir)) {
        throw 'Shared SMB manifests were not found in either the sibling storage/smb addon or the exported Ceph fallback bundle.'
    }

    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("k2s-ceph-smb-kustomize-" + [guid]::NewGuid().ToString())
    New-Item -Path $workDir -ItemType Directory -ErrorAction Stop | Out-Null
    Copy-Item -Path (Join-Path $sourceDir '*') -Destination $workDir -Recurse -Force

    $filesUsingStandaloneNamespace = @(
        'base\csi-smb-controller.yaml',
        'base\csi-smb-node.yaml',
        'base\rbac-csi-smb.yaml',
        'base\storage-classes\template_StorageClass.yaml',
        'windows\csi-smb-node-windows-hp.yaml'
    )

    foreach ($relativePath in $filesUsingStandaloneNamespace) {
        $fullPath = Join-Path $workDir $relativePath
        $content = Get-Content -Path $fullPath -Raw
        $content = $content -replace 'storage-smb', $Namespace
        Set-Content -Path $fullPath -Value $content -Encoding UTF8
    }

    $cephBaseKustomization = @"
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - rbac-csi-smb.yaml
  - csi-smb-driver.yaml
  - csi-smb-controller.yaml
  - csi-smb-node.yaml
"@
    Set-Content -Path (Join-Path $workDir 'base\kustomization.yaml') -Value $cephBaseKustomization -Encoding UTF8

    return [pscustomobject]@{
        SourceDir = $sourceDir
        WorkDir   = $workDir
    }
}

<#
.SYNOPSIS
Removes the Ceph CSI Kubernetes resources (operator, driver, CRs, StorageClass, namespaces, CRDs).

.DESCRIPTION
Deletes the kustomized manifests, strips finalizers from the Ceph CSI custom resources so their
namespaces can terminate, and removes the cluster-scoped StorageClass, CSIDriver and CRDs that are
not part of any manifest.
#>
function Remove-CephCsiKubernetesResources {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestsDir,
        [string]$StorageClassName = 'ceph-cephfs'
    )

    (Invoke-Kubectl -Params 'delete', '-k', $ManifestsDir, '--ignore-not-found', '--wait=false').Output | Write-Log

    $cephCrKinds = @(
        'clientprofiles.csi.ceph.io',
        'clientprofilemappings.csi.ceph.io',
        'drivers.csi.ceph.io',
        'cephconnections.csi.ceph.io',
        'operatorconfigs.csi.ceph.io'
    )
    $finalizerPatchFile = Join-Path ([System.IO.Path]::GetTempPath()) ("k2s-ceph-finalizer-" + [guid]::NewGuid().ToString() + ".json")
    Set-Content -Path $finalizerPatchFile -Value '{"metadata":{"finalizers":null}}' -Encoding ascii -NoNewline
    try {
        foreach ($crKind in $cephCrKinds) {
            $getResult = Invoke-Kubectl -Params 'get', $crKind, '--all-namespaces', '--ignore-not-found', '-o', 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name', '--no-headers'
            if (-not $getResult.Success) {
                # CRD for this kind no longer exists (already deleted) - nothing to clean up.
                continue
            }
            $crLines = @($getResult.Output | ForEach-Object { "$_" } | Where-Object { $_ -match '\S' })
            foreach ($entry in $crLines) {
                $cols = ($entry.Trim() -split '\s+')
                $crNamespace = $cols[0]
                $crName = $cols[1]
                if ([string]::IsNullOrWhiteSpace($crName)) {
                    continue
                }
                Write-Log "[Ceph] Removing finalizers from $crKind $crNamespace/$crName"
                (Invoke-Kubectl -Params 'patch', $crKind, $crName, '-n', $crNamespace, '--type', 'merge', '--patch-file', $finalizerPatchFile).Output | Write-Log
            }
        }
    }
    finally {
        Remove-Item -Path $finalizerPatchFile -Force -ErrorAction SilentlyContinue
    }

    (Invoke-Kubectl -Params 'delete', 'storageclass', $StorageClassName, '--ignore-not-found').Output | Write-Log

    (Invoke-Kubectl -Params 'delete', 'configmap', 'cephfs-smb-shared-images', '-n', 'ceph-csi-operator-system', '--ignore-not-found').Output | Write-Log

    # Remove the CSIDriver object that the operator creates dynamically for the CephFS driver.
    # It is cluster-scoped and not part of any manifest, so 'delete -k' does not remove it and it
    # survives namespace deletion. Because the Driver CR finalizer is stripped above, the operator
    # never gets to delete it either - so remove it explicitly to avoid leaving it orphaned.
    (Invoke-Kubectl -Params 'delete', 'csidriver', 'cephfs.csi.ceph.com', '--ignore-not-found').Output | Write-Log

    (Invoke-Kubectl -Params 'delete', 'namespace', 'ceph-csi-operator-system', '--ignore-not-found', '--wait=false').Output | Write-Log

    (Invoke-Kubectl -Params 'delete', 'namespace', 'ceph-csi-cephfs', '--ignore-not-found', '--wait=false').Output | Write-Log

    (Invoke-Kubectl -Params 'delete', '-f', (Join-Path $ManifestsDir 'crds'), '--ignore-not-found', '--wait=false').Output | Write-Log
}

<#
.SYNOPSIS
Resolves the name and IP of the node that hosts the provisioned Ceph cluster.

.DESCRIPTION
The target node is identified by 'clusterHost.node' in ceph-config.json. The K2s control plane node
(e.g. 'kubemaster') is NOT stored in cluster.json, so its IP comes from the control-plane
configuration; any other node is resolved from the K2s cluster descriptor (cluster.json). Returns an
object with 'Name' and 'Ip' (empty 'Ip' when it cannot be resolved).
#>
function Get-CephClusterHostNodeName {
    param(
        [pscustomobject]$Config
    )

    if ($null -eq $Config) {
        return ''
    }

    if (($Config.PSObject.Properties.Name -contains 'clusterHost') -and $null -ne $Config.clusterHost -and ($Config.clusterHost.PSObject.Properties.Name -contains 'node')) {
        return "$($Config.clusterHost.node)".Trim()
    }

    return ''
}

function Get-CephClusterHostNode {
    param(
        [pscustomobject]$Config
    )

    $clusterHostNode = Get-CephClusterHostNodeName -Config $Config
    $clusterHostNodeIp = ''
    if (-not [string]::IsNullOrWhiteSpace($clusterHostNode)) {
        $controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
        if ($clusterHostNode -eq $controlPlaneNodeName) {
            $clusterHostNodeIp = "$(Get-ConfiguredIPControlPlane)".Trim()
        }
        else {
            $targetNodeConfig = Get-NodeConfig -NodeName $clusterHostNode
            if ($null -ne $targetNodeConfig) {
                $clusterHostNodeIp = "$($targetNodeConfig.IpAddress)".Trim()
            }
            else {
                Write-Log "[Ceph] WARNING: Node '$clusterHostNode' from ceph-config.json was not found in cluster.json; cannot resolve its IP for on-node Ceph cluster teardown." -Console
            }
        }
    }

    return [pscustomobject]@{ Name = $clusterHostNode; Ip = $clusterHostNodeIp }
}

<#
.SYNOPSIS
Tears down the Ceph cluster that the addon provisioned on the host node.

.DESCRIPTION
The addon ALWAYS provisions a new Ceph cluster on enable, so disabling must tear it down. Deleting
that cluster is destructive and irreversible, so an explicit, dedicated confirmation is required
(separate from the PVC data prompt). Explicit -Force deletes without prompting; otherwise the user
is asked interactively. Only Debian 13 nodes are supported.
#>
function Remove-ProvisionedCephClusterOnNode {
    param(
        [Parameter(Mandatory = $true)][string]$ClusterHostNode,
        [Parameter(Mandatory = $true)][string]$ClusterHostNodeIp,
        [pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$RemoveClusterScript,
        [switch]$ShowLogs
    )

    if (-not (Test-Path $RemoveClusterScript)) {
        Write-Log "[Ceph] WARNING: Teardown script not found at '$RemoveClusterScript'; skipping on-node Ceph cluster teardown." -Console
        return
    }

    # Only Debian 13 nodes are supported, so the Debian teardown script is always used.
    Write-Log "[Ceph] Tearing down provisioned Ceph cluster on node '$ClusterHostNode' ($ClusterHostNodeIp)" -Console
    & $RemoveClusterScript -NodeIp $ClusterHostNodeIp -Config $Config -ShowLogs:$ShowLogs
    if ($LASTEXITCODE -ne 0) {
        Write-Log "[Ceph] WARNING: On-node Ceph cluster teardown reported a non-zero exit code ($LASTEXITCODE). Manual cleanup on '$ClusterHostNodeIp' may be required." -Console
        return
    }

    Write-Log '[Ceph] On-node Ceph cluster teardown completed' -Console
}

<#
.SYNOPSIS
Removes the Windows hosts-file entry that Enable.ps1 may have created for the Ceph dashboard.

.DESCRIPTION
Older enables mapped the dashboard hostname to the node IP in the Windows hosts file. This cleans up
that entry (identified by 'dashboardHost' in the config) when present.
#>
function Remove-CephDashboardHostEntry {
    param(
        [pscustomobject]$Config
    )

    $clusterHostNode = Get-CephClusterHostNodeName -Config $Config
    $controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
    if (-not [string]::IsNullOrWhiteSpace($clusterHostNode) -and $clusterHostNode -eq $controlPlaneNodeName) {
        Write-Log "[Ceph] Skipping dashboard hosts-entry cleanup for control plane node '$clusterHostNode'." -Console
        return
    }

    $dashboardHost = if ($Config -and ($Config.PSObject.Properties.Name -contains 'dashboardHost')) { "$($Config.dashboardHost)".Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($dashboardHost)) {
        return
    }

    $hostFile = 'C:\Windows\System32\drivers\etc\hosts'
    try {
        if (Test-Path $hostFile) {
            $pattern = '^\s*\S+\s+' + [regex]::Escape($dashboardHost) + '\s*$'
            $content = @(Get-Content -Path $hostFile)
            $filtered = @($content | Where-Object { $_ -notmatch $pattern })
            if ($filtered.Count -ne $content.Count) {
                # Use WriteAllLines instead of Set-Content: Set-Content throws
                # 'Stream was not readable' when the resulting array is empty (e.g. the
                # dashboard entry was the only line in the hosts file).
                [System.IO.File]::WriteAllLines($hostFile, [string[]]$filtered, [System.Text.Encoding]::ASCII)
                Write-Log "[Ceph] Removed hosts entry for '$dashboardHost' from '$hostFile'" -Console
            }
        }
    }
    catch {
        Write-Log "[Ceph] WARNING: Failed to remove hosts entry for '$dashboardHost': $($_.Exception.Message)" -Console
    }
}

<#
.SYNOPSIS
Removes the Ceph CSI container images that were pulled onto the K2s cluster node(s).

.DESCRIPTION
The k8s resource deletions only remove the pods; their cached images stay in containerd until
explicitly removed. The exact image references are read from the storage addon manifest's ceph
'additionalImages' list so this stays in sync with what the addon installs. Only that exact repo:tag
list is removed (not a broad namespace) so images other addons might share are untouched. These
images are re-imported from the offline package on the next enable.
#>
function Remove-CephCsiNodeImages {
    param(
        [Parameter(Mandatory = $true)][string]$StorageManifestPath
    )

    try {
        if (-not (Test-Path $StorageManifestPath)) {
            Write-Log "[Ceph] WARNING: Storage addon manifest not found at '$StorageManifestPath'; skipping node image cleanup." -Console
            return
        }

        # Collect the ceph CSI image references (repo:tag) declared under additionalImages. The
        # smb implementation declares an empty additionalImages list, so only the ceph entries
        # (quay.io/ceph, quay.io/cephcsi, registry.k8s.io/sig-storage) match here.
        $cephImageRefs = @(
            Get-Content -Path $StorageManifestPath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^-\s+(quay\.io/ceph/|quay\.io/cephcsi/|registry\.k8s\.io/sig-storage/)\S+:\S+$' } |
            ForEach-Object { ($_ -replace '^-\s+', '').Trim() } |
            Select-Object -Unique
        )

        if ($cephImageRefs.Count -eq 0) {
            Write-Log '[Ceph] No Ceph CSI images found in storage addon manifest; skipping node image cleanup.'
            return
        }

        Write-Log "[Ceph] Removing $($cephImageRefs.Count) Ceph CSI image(s) from the K2s cluster node(s)" -Console

        # Enumerate the images actually present on the nodes so we can map each manifest reference to
        # its ContainerImage (with ImageId/Node) for Remove-Image.
        $nodeImages = @(Get-ContainerImagesInk2s -IncludeK8sImages $true)

        foreach ($imageRef in $cephImageRefs) {
            $matchingImages = @($nodeImages | Where-Object { "$($_.Repository):$($_.Tag)" -eq $imageRef })
            if ($matchingImages.Count -eq 0) {
                Write-Log "[Ceph] Image '$imageRef' not present on any node; nothing to remove."
                continue
            }

            foreach ($img in $matchingImages) {
                try {
                    $removeResult = Remove-Image -ContainerImage $img -Force
                    if ("$removeResult" -match '__K2S_IMAGE_DELETE_FAILED__') {
                        Write-Log "[Ceph] WARNING: Failed to remove image '$imageRef' from node '$($img.Node)': $removeResult" -Console
                    }
                    else {
                        Write-Log "[Ceph] Removed image '$imageRef' from node '$($img.Node)'" -Console
                    }
                }
                catch {
                    Write-Log "[Ceph] WARNING: Failed to remove image '$imageRef' from node '$($img.Node)': $($_.Exception.Message)" -Console
                }
            }
        }
    }
    catch {
        Write-Log "[Ceph] WARNING: Ceph CSI image cleanup on the cluster node(s) failed: $($_.Exception.Message)" -Console
    }
}

<#
.SYNOPSIS
Resolves the local Hyper-V VM name that hosts the given guest IP.

.DESCRIPTION
Mirrors the robust resolution used during enable (New-CephOsdDisk.ps1): first an ARP/MAC lookup on
the K2s control-plane switch - which works even when Hyper-V guest integration services do NOT report
the guest IP - and only then falls back to the direct guest-IP adapter lookup. Returns $null when no
local VM matches (e.g. a bare-metal OSD host).

The teardown previously used the guest-IP lookup alone, which silently returned no VM whenever the
guest IP was not reported by integration services, leaving the OSD VHDX disks attached to the VM
(visible as sdb/sdc inside the guest) after the addon was disabled.
#>
function Resolve-CephHyperVVmNameByIp {
    param(
        [Parameter(Mandatory = $true)][string] $IpAddress
    )

    try {
        $kubeSwitchName = Get-ControlPlaneNodeDefaultSwitchName
        if (-not [string]::IsNullOrWhiteSpace($kubeSwitchName)) {
            Test-Connection -ComputerName $IpAddress -Count 2 -Quiet -ErrorAction SilentlyContinue | Out-Null

            $arpEntry = Get-NetNeighbor -IPAddress $IpAddress -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Unreachable' } | Select-Object -First 1
            if ($null -ne $arpEntry -and -not [string]::IsNullOrWhiteSpace($arpEntry.LinkLayerAddress)) {
                $targetMac = $arpEntry.LinkLayerAddress -replace '-', ''
                $vmsOnKubeSwitch = @(Get-VM | Where-Object {
                        $adapters = Get-VMNetworkAdapter -VMName $_.Name -ErrorAction SilentlyContinue
                        @($adapters | Where-Object { $_.SwitchName -eq $kubeSwitchName }).Count -gt 0
                    })

                foreach ($vm in $vmsOnKubeSwitch) {
                    $adapters = @(Get-VMNetworkAdapter -VMName $vm.Name -ErrorAction SilentlyContinue)
                    foreach ($adapter in $adapters) {
                        $vmMac = $adapter.MacAddress -replace '-', ''
                        if ($vmMac -eq $targetMac) {
                            Write-Log "[Ceph] Matched node '$IpAddress' to Hyper-V VM '$($vm.Name)' via ARP/MAC lookup on switch '$kubeSwitchName'."
                            return $vm.Name
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Log "[Ceph] Hyper-V ARP/MAC detection failed for '$IpAddress': $($_.Exception.Message)"
    }

    try {
        $vmAdapter = Get-VMNetworkAdapter -All -ErrorAction SilentlyContinue | Where-Object { @($_.IPAddresses) -contains $IpAddress } | Select-Object -First 1
        if ($null -ne $vmAdapter -and -not [string]::IsNullOrWhiteSpace($vmAdapter.VMName)) {
            Write-Log "[Ceph] Matched node '$IpAddress' to Hyper-V VM '$($vmAdapter.VMName)' via direct guest-IP adapter lookup."
            return $vmAdapter.VMName
        }
    }
    catch {
        Write-Log "[Ceph] Hyper-V guest-IP detection failed for '$IpAddress': $($_.Exception.Message)"
    }

    return $null
}

<#
.SYNOPSIS
Removes the virtual OSD disk volumes (VHDX files) that the addon created on Hyper-V VMs.

.DESCRIPTION
The enable process creates dynamic VHDX files named ceph-osd-*.vhdx in the VM storage directory
and attaches them to the cluster host VM. This cleanup function detaches and removes those files
to fully clean up the addon. Only applies to Hyper-V VMs; bare-metal nodes are unaffected since
those use existing physical disks.

Disabling the addon tears down the ENTIRE Ceph cluster on the resolved host VM, so every attached
ceph-osd-*.vhdx on that VM is removed - including orphaned disks left behind by a previously failed
enable that were never recorded in the config. The cluster ID and any tracked disk paths are used
only for logging context, not as a hard gate.
#>
function Remove-CephOsdVirtualDisks {
    param(
        [Parameter(Mandatory = $true)][string]$ClusterHostNode,
        [Parameter(Mandatory = $false)][pscustomobject]$Config
    )

    if ([string]::IsNullOrWhiteSpace($ClusterHostNode)) {
        Write-Log "[Ceph] No cluster host node name available; skipping OSD virtual disk cleanup." -Console
        return
    }

    # Cluster ID is used only for logging context here - disable removes the whole cluster on this
    # host VM, so all ceph-osd-*.vhdx are cleared even when the id or tracked paths are missing
    # (e.g. after a failed enable that left orphaned disks behind).
    $clusterId = if ($Config -and ($Config.PSObject.Properties.Name -contains 'clusterId')) { "$($Config.clusterId)".Trim() } else { '' }
    $clusterIdDisplay = if (-not [string]::IsNullOrWhiteSpace($clusterId)) { $clusterId } else { 'unknown' }

    # Attempt to resolve the VM name from the node name
    $controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
    $nodeIp = ''
    if ($ClusterHostNode -eq $controlPlaneNodeName) {
        # Control plane node - IP comes from the control-plane configuration.
        $nodeIp = "$(Get-ConfiguredIPControlPlane)".Trim()
    }
    else {
        # Regular worker node - might be Hyper-V or bare-metal; IP comes from cluster.json.
        try {
            $nodeConfig = Get-NodeConfig -NodeName $ClusterHostNode
            if ($null -ne $nodeConfig -and -not [string]::IsNullOrWhiteSpace($nodeConfig.IpAddress)) {
                $nodeIp = "$($nodeConfig.IpAddress)".Trim()
            }
        }
        catch {
            Write-Log "[Ceph] Could not resolve node '$ClusterHostNode' for OSD disk cleanup: $($_.Exception.Message)"
        }
    }

    # Use the same robust ARP/MAC + guest-IP resolution as enable so the VM is still found when
    # Hyper-V integration services do not report the guest IP (which previously caused the OSD
    # disks to be left attached after disable).
    $vmName = $null
    if (-not [string]::IsNullOrWhiteSpace($nodeIp)) {
        $vmName = Resolve-CephHyperVVmNameByIp -IpAddress $nodeIp
    }

    if ([string]::IsNullOrWhiteSpace($vmName)) {
        Write-Log "[Ceph] Could not identify a local Hyper-V VM for node '$ClusterHostNode' (ip '$nodeIp'); skipping OSD virtual disk cleanup (may be bare-metal)." -Console
        return
    }

    try {
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if ($null -eq $vm) {
            Write-Log "[Ceph] Hyper-V VM '$vmName' not found; skipping OSD virtual disk cleanup." -Console
            return
        }

        # Find all attached ceph-osd-*.vhdx disks on this VM
        $allOsdDisks = @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) -and ((Split-Path $_.Path -Leaf) -like 'ceph-osd-*.vhdx') })

        if ($allOsdDisks.Count -eq 0) {
            Write-Log "[Ceph] No OSD virtual disks found on VM '$vmName'; nothing to remove." -Console
            return
        }

        Write-Log "[Ceph] Found $($allOsdDisks.Count) OSD virtual disk(s) on VM '$vmName'" -Console

        # Disable removes the entire cluster on this host, so remove every attached ceph-osd-*.vhdx,
        # including untracked orphans from earlier failed enable attempts.
        $disksToDelete = $allOsdDisks

        Write-Log "[Ceph] Removing $($disksToDelete.Count) OSD virtual disk(s) from VM '$vmName' (cluster '$clusterIdDisplay')..." -Console

        foreach ($disk in $disksToDelete) {
            $diskPath = $disk.Path
            $diskName = Split-Path $diskPath -Leaf

            try {
                # Detach the disk from the VM. Remove-VMHardDiskDrive has no -VMHardDiskDrive/-Force
                # combo; it is addressed by its controller coordinates (same call the enable rollback uses).
                Remove-VMHardDiskDrive -VMName $disk.VMName -ControllerType $disk.ControllerType -ControllerNumber $disk.ControllerNumber -ControllerLocation $disk.ControllerLocation -ErrorAction SilentlyContinue
                Write-Log "[Ceph] Detached virtual disk '$diskName' from VM '$vmName'."

                # Remove the VHDX file
                if (Test-Path $diskPath) {
                    Remove-Item -Path $diskPath -Force -ErrorAction SilentlyContinue
                    Write-Log "[Ceph] Deleted OSD virtual disk file: '$diskPath'" -Console
                }
                else {
                    Write-Log "[Ceph] OSD virtual disk file already removed: '$diskPath'"
                }
            }
            catch {
                Write-Log "[Ceph] WARNING: Failed to remove OSD virtual disk '$diskName': $($_.Exception.Message)" -Console
            }
        }

        Write-Log '[Ceph] OSD virtual disk cleanup completed' -Console
    }
    catch {
        Write-Log "[Ceph] WARNING: OSD virtual disk cleanup failed: $($_.Exception.Message)" -Console
    }
}

Write-Log 'Checking cluster status' -Console
$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

if ($null -eq $Config) {
    $cephConfigPath = "$PSScriptRoot\config\ceph-config.json"
    if (Test-Path $cephConfigPath) {
        try {
            $Config = Get-Content -Path $cephConfigPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Log "[Ceph] Warning: failed to parse ceph-config.json for teardown detection: $($_.Exception.Message)" -Console
        }
    }
}

$storageClassName = if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.storageClassName)) { "$($Config.storageClassName)" } else { 'ceph-cephfs' }

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }
    Write-Log $systemError.Message -Error
    exit 1
}

Write-Log 'Check whether storage ceph addon is already disabled'
if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'ceph-csi-operator-system', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'storage'; Implementation = 'ceph' })) -ne $true) {
    $errMsg = "Addon 'storage ceph' is already disabled, nothing to do."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

if (-not $Force) {
    $cephHostNodeForPrompt = Get-CephClusterHostNode -Config $Config
    $cephHostNodeDisplay = if (-not [string]::IsNullOrWhiteSpace($cephHostNodeForPrompt.Name)) { $cephHostNodeForPrompt.Name } else { 'unknown-node' }
    $cephHostIpDisplay = if (-not [string]::IsNullOrWhiteSpace($cephHostNodeForPrompt.Ip)) { $cephHostNodeForPrompt.Ip } else { 'unknown-ip' }

    Write-Log '' -Console
    Write-Log "[Ceph] WARNING: Disabling storage ceph will uninstall the Ceph cluster on '$cephHostNodeDisplay' ($cephHostIpDisplay)." -Console
    $answer = Read-Host 'ALL DATA in the Ceph cluster will be permanently lost. Continue? (y/N)'
    if ($answer -ne 'y') {
        Write-Log '[Ceph] Disable operation cancelled by user.' -Console
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = (New-Error -Severity Warning -Code 'operation-cancelled' -Message 'Disable storage ceph cancelled by user') }
            return
        }
        exit 1
    }

    $Force = $true
    Write-Log '[Ceph] DESTRUCTIVE OPERATION CONFIRMED. Ceph cluster will be removed.' -Console
}

Write-Log 'Uninstalling storage ceph' -Console

Write-Log "[Ceph] Deleting PersistentVolumeClaims bound to StorageClass $storageClassName" -Console
Remove-PersistentVolumeClaimsForStorageClass -StorageClass $storageClassName | Write-Log

# Also clean up the Ceph SMB (mgr/smb) integration created by the -w / setupWindowsNode enable path:
# the ceph-smb StorageClass + PVCs, the smbcreds Secret, the SMB CSI driver, and the native mgr/smb
# cluster/share on the Ceph cluster host. All best-effort; errors are non-fatal because the whole
# Ceph cluster is removed afterwards regardless.
$smbConfig = if ($Config -and $Config.PSObject.Properties.Name -contains 'smb') { $Config.smb } else { $null }
$smbStorageClassName = if ($null -ne $smbConfig -and ($smbConfig.PSObject.Properties.Name -contains 'storageClassName') -and -not [string]::IsNullOrWhiteSpace($smbConfig.storageClassName)) { "$($smbConfig.storageClassName)" } else { 'ceph-smb' }
$smbClusterId = if ($null -ne $smbConfig -and ($smbConfig.PSObject.Properties.Name -contains 'clusterId') -and -not [string]::IsNullOrWhiteSpace($smbConfig.clusterId)) { "$($smbConfig.clusterId)" } else { 'k2ssmb' }
$smbShareName = if ($null -ne $smbConfig -and ($smbConfig.PSObject.Properties.Name -contains 'shareName') -and -not [string]::IsNullOrWhiteSpace($smbConfig.shareName)) { "$($smbConfig.shareName)" } else { 'cephfs' }
$smbPlacementLabel = if ($null -ne $smbConfig -and ($smbConfig.PSObject.Properties.Name -contains 'placementLabel') -and -not [string]::IsNullOrWhiteSpace($smbConfig.placementLabel)) { "$($smbConfig.placementLabel)" } else { 'smb' }
$smbNamespace = 'storage-smb-ceph'
$smbWinMountPath = if ($null -ne $smbConfig -and ($smbConfig.PSObject.Properties.Name -contains 'winMountPath') -and -not [string]::IsNullOrWhiteSpace($smbConfig.winMountPath)) { "$($smbConfig.winMountPath)" } else { 'C:\k8s-ceph-share' }

Write-Log "[CephSMB] Deleting PersistentVolumeClaims bound to StorageClass $smbStorageClassName" -Console
Remove-PersistentVolumeClaimsForStorageClass -StorageClass $smbStorageClassName | Write-Log

$smbNsExists = (Invoke-Kubectl -Params 'get', 'namespace', $smbNamespace, '--ignore-not-found', '--no-headers').Output
$smbScExists = (Invoke-Kubectl -Params 'get', 'storageclass', $smbStorageClassName, '--ignore-not-found', '--no-headers').Output
if (-not [string]::IsNullOrWhiteSpace($smbNsExists) -or -not [string]::IsNullOrWhiteSpace($smbScExists)) {
    Write-Log '[CephSMB] Removing Ceph SMB StorageClass, credentials and SMB CSI driver' -Console

    # Delete the ceph-smb StorageClass.
    (Invoke-Kubectl -Params 'delete', 'storageclass', $smbStorageClassName, '--ignore-not-found').Output | Write-Log

    # Delete the smbcreds Secret.
    (Invoke-Kubectl -Params 'delete', 'secret', 'smbcreds', '-n', $smbNamespace, '--ignore-not-found').Output | Write-Log

    # Remove the SMB CSI driver resources via the same shared-source overlay used during enable.
    try {
        $smbManifestWork = New-CephSmbManifestWorkDir -Namespace $smbNamespace
        $smbWindowsDir = Join-Path $smbManifestWork.WorkDir 'windows'
        (Invoke-Kubectl -Params 'delete', '-k', $smbWindowsDir, '--ignore-not-found', '--wait=false').Output | Write-Log
        Remove-Item -Path $smbManifestWork.WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "[CephSMB] WARNING: Shared SMB manifests not found while disabling ceph SMB resources. Skipping SMB CSI manifest deletion. Details: $($_.Exception.Message)" -Console
    }

    # Delete the Ceph SMB namespace (let it terminate in background).
    (Invoke-Kubectl -Params 'delete', 'namespace', $smbNamespace, '--ignore-not-found', '--wait=false').Output | Write-Log
}

# Remove the native Ceph mgr/smb cluster + share on the Ceph cluster host.
$cephHostNodeForSmb = Get-CephClusterHostNode -Config $Config
if (-not [string]::IsNullOrWhiteSpace($cephHostNodeForSmb.Ip)) {
    $removeSmbScript = "$PSScriptRoot\scripts\linux\debian\Remove-CephSmbCluster.ps1"
    if (Test-Path $removeSmbScript) {
        Write-Log "[CephSMB] Removing native Ceph mgr/smb cluster '$smbClusterId'" -Console
        & $removeSmbScript -NodeIp $cephHostNodeForSmb.Ip `
            -Config $Config `
            -SmbClusterId $smbClusterId `
            -PlacementLabel $smbPlacementLabel `
            -ShowLogs:$ShowLogs
    }

    $cephSmbSharePath = "\\$($cephHostNodeForSmb.Ip)\$smbShareName"

    # Remove the host shortcut first (before disconnecting so the reparse point removal works).
    if (Test-Path -LiteralPath $smbWinMountPath) {
        $shortcutItem = Get-Item -LiteralPath $smbWinMountPath -ErrorAction SilentlyContinue
        if ($null -ne $shortcutItem -and ($shortcutItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Write-Log "[CephSMB] Removing host shortcut '$smbWinMountPath'" -Console
            Remove-Item -LiteralPath $smbWinMountPath -Force -ErrorAction SilentlyContinue
        }
    }

    # Remove all SMB mappings/sessions to this server so nothing lingers after disable.
    Get-SmbGlobalMapping -ErrorAction SilentlyContinue |
        Where-Object { $_.RemotePath -like "\\$($cephHostNodeForSmb.Ip)\*" } |
        Remove-SmbGlobalMapping -Force -ErrorAction SilentlyContinue
    Get-SmbMapping -ErrorAction SilentlyContinue |
        Where-Object { $_.RemotePath -like "\\$($cephHostNodeForSmb.Ip)\*" } |
        Remove-SmbMapping -Force -ErrorAction SilentlyContinue
    net use "\\$($cephHostNodeForSmb.Ip)" /delete /y 2>&1 | Write-Log

    # Remove the Credential Manager entry created during enable.
    cmdkey /delete:$($cephHostNodeForSmb.Ip) 2>&1 | Write-Log
}

Remove-CephCsiKubernetesResources -ManifestsDir "$PSScriptRoot\manifests" -StorageClassName $storageClassName

$cephHostNode = Get-CephClusterHostNode -Config $Config
if (-not [string]::IsNullOrWhiteSpace($cephHostNode.Ip)) {
    Remove-ProvisionedCephClusterOnNode -ClusterHostNode $cephHostNode.Name `
        -ClusterHostNodeIp $cephHostNode.Ip `
        -Config $Config `
        -RemoveClusterScript "$PSScriptRoot\scripts\linux\debian\Remove-CephCluster.ps1" `
        -ShowLogs:$ShowLogs

    # Remove the OSD virtual disk files (VHDX) that were created on Hyper-V VMs
    Remove-CephOsdVirtualDisks -ClusterHostNode $cephHostNode.Name -Config $Config
}

# Remove the local dashboard-access artifact that an older Enable.ps1 may have created (Windows
# hosts entry hostname -> node IP).
Remove-CephDashboardHostEntry -Config $Config

# Remove the Ceph CSI container images that were pulled onto the K2s cluster node(s).
Remove-CephCsiNodeImages -StorageManifestPath (Join-Path -Path $PSScriptRoot -ChildPath '..\addon.manifest.yaml')

# Remove the addon (with its implementation) from setup.json so that 'k2s addons ls' no longer
# reports it as enabled and Test-IsAddonEnabled returns false.
Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = $addonName; Implementation = 'ceph' })

# Unregister the backup/restore/upgrade hooks.
Remove-ScriptsFromHooksDir -ScriptNames @(Get-ChildItem -Path "$PSScriptRoot\hooks" -Filter '*.ps1' | ForEach-Object { $_.Name })

Write-Log "[Ceph] Addon disabled successfully" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{
        Error = $null
        Status = "Storage ceph addon disabled successfully"
        AddonName = $addonName
        DataAction = if ($Force) { "deleted" } else { "prompted" }
    }
}