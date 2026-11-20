# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Provisions a raw, unformatted, unpartitioned disk for a Ceph OSD on a Debian node and prepares it.

.DESCRIPTION
Determines whether the target OSD node identified by -NodeIp is a local Hyper-V virtual machine,
reusing the same detection K2s uses when adding worker nodes: prefer the KubeSwitch ARP/MAC-to-VM
lookup used by the existing-vm add-node path, and fall back to a direct Hyper-V adapter IP-address
match only when needed.

Ceph OSD provisioning is supported only for Hyper-V worker nodes. For supported nodes this script
creates a new dynamic .vhdx on the Windows host, hot-attaches it to the VM as a raw SCSI disk,
discovers the resulting guest device, then runs osd\hyperv\prepare-osd-disk-hyperv.sh to wipe it
to a raw state.

.PARAMETER NodeIp
IP address of the OSD node (ceph-config.json 'clusterHostNodeIp').

.PARAMETER UserName
SSH user for the OSD node. If omitted it is resolved from the cluster descriptor, falling back to 'remote'.

.PARAMETER Device
Target whole-disk block device on the node, e.g. '/dev/sdb'. Optional for Hyper-V nodes; when
omitted, the freshly-attached virtual disk is discovered automatically.

.PARAMETER DiskSizeGB
Size (in GiB) of the virtual disk to create for a Hyper-V node. Default 20.

.PARAMETER OsdIndex
1-based OSD index within the current provisioning run.

.PARAMETER Config
The parsed ceph-config.json object (used to resolve the SSH user).

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'IP address of the OSD node')]
    [string] $NodeIp,
    [parameter(Mandatory = $false, HelpMessage = 'SSH user name for the OSD node')]
    [string] $UserName = '',
    [parameter(Mandatory = $false, HelpMessage = 'Target whole-disk device (optional for Hyper-V)')]
    [string] $Device = '',
    [parameter(Mandatory = $false, HelpMessage = 'Virtual disk size in GiB for Hyper-V nodes')]
    [uint32] $DiskSizeGB = 20,
    [parameter(Mandatory = $false, HelpMessage = '1-based OSD index')]
    [uint32] $OsdIndex = 1,
    [parameter(Mandatory = $false, HelpMessage = 'Force creation of a new Hyper-V virtual disk even when K2s OSD disks already exist')]
    [switch] $CreateNewDisk = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Remove pre-existing K2s OSD virtual disks before provisioning (fresh cluster start)')]
    [switch] $RemoveExistingOsdDisks = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Parsed ceph-config.json object')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot/../../../../../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../../../../lib/modules/windows/node/k2s.node.module/k2s.node.module.psm1"
$clusterConfigModule = "$PSScriptRoot/../../../../../../../lib/modules/windows/infra/k2s.infra.module/config/cluster.config.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterConfigModule
Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Stop'

# Resolve the SSH user: explicit parameter wins, then the OSD/cluster node descriptor, then a safe default.
$sshUserName = $UserName
if ([string]::IsNullOrWhiteSpace($sshUserName) -and $null -ne $Config) {
    try {
        $clusterHostNode = if (($Config.PSObject.Properties.Name -contains 'clusterHost') -and $null -ne $Config.clusterHost -and ($Config.clusterHost.PSObject.Properties.Name -contains 'node')) {
            "$($Config.clusterHost.node)".Trim()
        } else { '' }

        $nodeName = if (-not [string]::IsNullOrWhiteSpace("$($Config.osdHostNode)".Trim())) {
            "$($Config.osdHostNode)".Trim()
        }
        else {
            $clusterHostNode
        }

        $nodeConfig = $null
        if (-not [string]::IsNullOrWhiteSpace($nodeName)) {
            $nodeConfig = Get-NodeConfig -NodeName $nodeName
        }

        if ($null -ne $nodeConfig -and -not [string]::IsNullOrWhiteSpace($nodeConfig.Username)) {
            $sshUserName = $nodeConfig.Username
        }
    }
    catch {
        Write-Log "[Ceph] Could not resolve SSH user from cluster descriptor: $($_.Exception.Message)"
    }
}
if ([string]::IsNullOrWhiteSpace($sshUserName)) {
    $sshUserName = 'remote'
}

<#
.SYNOPSIS
Detaches and deletes a K2s OSD virtual disk that was created during this run.

.DESCRIPTION
Used to roll back a freshly created ceph-osd-*.vhdx when the subsequent disk preparation
fails. Without this, every failed enable attempt leaves an orphaned VHDX attached to the VM,
which then accumulate (sdb, sdc, sdf, ...) and break single-new-device detection on later runs.
#>
function Remove-CreatedOsdVhdx {
    param(
        [Parameter(Mandatory = $true)][string] $VmName,
        [Parameter(Mandatory = $true)][string] $VhdxPath
    )

    if ([string]::IsNullOrWhiteSpace($VhdxPath)) { return }

    try {
        # Detach the disk from the VM first so the file is not locked.
        $attached = @(Get-VMHardDiskDrive -VMName $VmName -ErrorAction SilentlyContinue |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) -and $_.Path -eq $VhdxPath })
        foreach ($drive in $attached) {
            Remove-VMHardDiskDrive -VMName $drive.VMName -ControllerType $drive.ControllerType -ControllerNumber $drive.ControllerNumber -ControllerLocation $drive.ControllerLocation -ErrorAction SilentlyContinue
            Write-Log "[Ceph] Rollback: detached virtual disk '$VhdxPath' from VM '$VmName'." -Console
        }
    }
    catch {
        Write-Log "[Ceph] Rollback: WARNING - could not detach virtual disk '$VhdxPath' from VM '$VmName': $($_.Exception.Message)" -Console
    }

    try {
        if (Test-Path $VhdxPath) {
            Remove-Item -Path $VhdxPath -Force -ErrorAction Stop
            Write-Log "[Ceph] Rollback: deleted orphaned OSD virtual disk '$VhdxPath'." -Console
        }
    }
    catch {
        Write-Log "[Ceph] Rollback: WARNING - could not delete virtual disk file '$VhdxPath': $($_.Exception.Message)" -Console
    }
}

function Get-GuestWholeDiskNames {
    param(
        [string] $UserName,
        [string] $IpAddress
    )

    # -e 7,11 excludes loop (major 7) and sr/cdrom (major 11) devices.
    $result = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'lsblk -dn -o NAME -e 7,11' -UserName $UserName -IpAddress $IpAddress -NoLog -IgnoreErrors -Retries 3
    $names = @(($result.Output | Out-String) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    return $names
}

function Get-HyperVReusableOsdDevices {
    param(
        [string] $UserName,
        [string] $IpAddress
    )

    # Return whole-disk devices that look like empty Hyper-V virtual disks and are safe to wipe.
    $cmd = @'
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null)"
ROOT_DISK=""
if [ -n "$ROOT_SRC" ]; then
    ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1 | tr -d '[:space:]')"
fi

for name in $(lsblk -dn -o NAME -e 7,11 2>/dev/null); do
    [ -n "$name" ] || continue
    dev="/dev/$name"
    base="$name"

    vendor="$(lsblk -dn -o VENDOR "$dev" 2>/dev/null | sed 's/[[:space:]]\+$//')"
    model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]\+$//')"
    if ! echo "$vendor $model" | grep -qi 'virtual disk'; then
        continue
    fi

    if [ -n "$ROOT_DISK" ] && [ "$ROOT_DISK" = "$dev" ]; then
        continue
    fi

    if [ -n "$(lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$' || true)" ]; then
        continue
    fi
    if [ -n "$(ls "/sys/block/$base/holders" 2>/dev/null || true)" ]; then
        continue
    fi
    if [ -n "$(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | grep -E "^${dev}([0-9]+|p[0-9]+)?$" || true)" ]; then
        continue
    fi
    if [ -n "$(lsblk -nr -o NAME "$dev" 2>/dev/null | grep -v "^$base$" || true)" ]; then
        continue
    fi
    if [ -n "$(sudo blkid -o value -s TYPE "$dev" 2>/dev/null || true)" ]; then
        continue
    fi

    echo "$dev"
done
'@

    $result = Invoke-CmdOnVmViaSSHKey -CmdToExecute $cmd -UserName $UserName -IpAddress $IpAddress -NoLog -IgnoreErrors -Retries 3
    $devices = @(($result.Output | Out-String) -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -match '^/dev/' })
    return $devices
}

function Resolve-HyperVVmNameByIp {
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

# ---------------------------------------------------------------------------
# Determine node type using the same signal K2s uses when adding a worker node:
# prefer KubeSwitch ARP/MAC lookup to identify an existing Hyper-V VM.
# ---------------------------------------------------------------------------
$vmName = Resolve-HyperVVmNameByIp -IpAddress $NodeIp

if ([string]::IsNullOrWhiteSpace($vmName)) {
    Write-Log "[Ceph] ERROR: Node '$NodeIp' is not a local Hyper-V VM. Ceph OSD provisioning supports only Hyper-V worker nodes." -Console -Error
    exit 1
}
Write-Log "[Ceph] Node '$NodeIp' detected as a local Hyper-V VM ('$vmName')." -Console
$nodeType = 'HyperV'

# ---------------------------------------------------------------------------
# Provision / prepare the OSD disk according to the node type.
# ---------------------------------------------------------------------------
$createdVhdxPath = ''

$diskScript = Join-Path $PSScriptRoot 'hyperv\prepare-osd-disk-hyperv.sh'

    # If no explicit device was given, create and attach a fresh virtual disk, then discover it.
    if ([string]::IsNullOrWhiteSpace($Device)) {
        $createAndAttachNewDisk = $true
        $vmHardDisks = @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction SilentlyContinue)
        $existingK2sOsdDisks = @($vmHardDisks | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.Path) -and ((Split-Path $_.Path -Leaf) -like 'ceph-osd-*.vhdx')
        })

        # A fresh cluster starts with zero OSDs, so any pre-existing K2s OSD virtual disks are orphans
        # left behind by earlier failed attempts. Remove them up front so they neither get (incorrectly)
        # reused nor keep accumulating (sdb, sdc, sdf, ...) and breaking single-new-device detection.
        if ($RemoveExistingOsdDisks -and $existingK2sOsdDisks.Count -gt 0) {
            Write-Log "[Ceph] Removing $($existingK2sOsdDisks.Count) pre-existing K2s OSD virtual disk(s) from VM '$vmName' before provisioning a fresh cluster..." -Console
            foreach ($orphanDisk in $existingK2sOsdDisks) {
                Remove-CreatedOsdVhdx -VmName $vmName -VhdxPath $orphanDisk.Path
            }
            # Rescan the guest so the detached disks disappear before we diff for the new one.
            Invoke-CmdOnVmViaSSHKey -CmdToExecute 'for h in /sys/class/scsi_host/host*/scan; do echo "- - -" | sudo tee $h > /dev/null; done; sudo udevadm settle' -UserName $sshUserName -IpAddress $NodeIp -NoLog -IgnoreErrors -Retries 3 | Out-Null
            Start-Sleep -Seconds 2
            $vmHardDisks = @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction SilentlyContinue)
            $existingK2sOsdDisks = @()
        }

        if ($existingK2sOsdDisks.Count -gt 0 -and -not $CreateNewDisk) {
            $existingPaths = @($existingK2sOsdDisks | ForEach-Object { $_.Path }) -join ', '
            Write-Log "[Ceph] Reusing existing K2s OSD virtual disk attachment(s) on VM '$vmName': $existingPaths" -Console
                $reusableDevices = @(Get-HyperVReusableOsdDevices -UserName $sshUserName -IpAddress $NodeIp |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -match '^/dev/' })
            if ($reusableDevices.Count -eq 1) {
                $Device = $reusableDevices[0]
                $createAndAttachNewDisk = $false
                Write-Log "[Ceph] Reusing existing empty OSD guest device '$Device'." -Console
            }
            elseif ($reusableDevices.Count -gt 1) {
                $Device = ($reusableDevices | Sort-Object | Select-Object -First 1)
                $createAndAttachNewDisk = $false
                Write-Log "[Ceph] Multiple reusable empty OSD guest devices found ($($reusableDevices -join ', ')); selecting '$Device'." -Console
            }
            else {
                Write-Log "[Ceph] Existing OSD virtual disks are attached but none is currently reusable as an empty raw disk. Creating a new virtual disk." -Console
            }
        }

        if ($createAndAttachNewDisk) {
            if ($existingK2sOsdDisks.Count -gt 0 -and $CreateNewDisk) {
                Write-Log "[Ceph] Existing K2s OSD disk(s) already attached on VM '$vmName'; creating an additional OSD disk as requested." -Console
            }
            Write-Log "[Ceph] Creating and attaching a new ${DiskSizeGB} GiB virtual disk to VM '$vmName'..." -Console

            $disksBefore = Get-GuestWholeDiskNames -UserName $sshUserName -IpAddress $NodeIp

            # Place the new VHDX next to the VM's existing disk (or the VM folder as a fallback).
            $osDisk = $vmHardDisks | Select-Object -First 1
            if ($null -ne $osDisk -and -not [string]::IsNullOrWhiteSpace($osDisk.Path)) {
                $vhdxDir = Split-Path $osDisk.Path -Parent
            }
            else {
                $vhdxDir = (Get-VM -Name $vmName).Path
            }
            $vhdxPath = Join-Path $vhdxDir ("ceph-osd-" + ([guid]::NewGuid().ToString('N').Substring(0, 8)) + '.vhdx')

            $vhdxCreated = $false
            try {
                New-VHD -Path $vhdxPath -SizeBytes ([int64]$DiskSizeGB * 1GB) -Dynamic | Out-Null
                $vhdxCreated = $true
                $createdVhdxPath = $vhdxPath  # Track the created VHDX path for later cleanup validation
                Add-VMHardDiskDrive -VMName $vmName -Path $vhdxPath -ControllerType SCSI
                Write-Log "[Ceph] Attached virtual disk '$vhdxPath' to VM '$vmName'."
            }
            catch {
                Write-Log "[Ceph] ERROR: Failed to create/attach the virtual disk: $($_.Exception.Message)" -Console -Error
                if ($vhdxCreated -and (Test-Path $vhdxPath)) {
                    Remove-Item -Path $vhdxPath -Force -ErrorAction SilentlyContinue
                }
                exit 1
            }

            # Trigger a SCSI rescan inside the guest and let udev settle so the new disk appears.
            Invoke-CmdOnVmViaSSHKey -CmdToExecute 'for h in /sys/class/scsi_host/host*/scan; do echo "- - -" | sudo tee $h > /dev/null; done; sudo udevadm settle' -UserName $sshUserName -IpAddress $NodeIp -NoLog -IgnoreErrors -Retries 3 | Out-Null
            Start-Sleep -Seconds 3

            $disksAfter = Get-GuestWholeDiskNames -UserName $sshUserName -IpAddress $NodeIp
            $newDisks = @($disksAfter | Where-Object { $disksBefore -notcontains $_ })

            if ($newDisks.Count -eq 1) {
                $Device = "/dev/$($newDisks[0])"
                Write-Log "[Ceph] New virtual disk appeared in guest as '$Device'."
            }
            else {
                if ($newDisks.Count -eq 0) {
                    Write-Log "[Ceph] Attached the virtual disk but no single new guest disk could be identified. Probing for reusable empty OSD devices..." -Console
                }
                else {
                    Write-Log "[Ceph] Multiple new devices appeared in the guest ($($newDisks -join ', ')); probing for reusable empty OSD devices..." -Console
                }

                $reusableAfterAttach = @(Get-HyperVReusableOsdDevices -UserName $sshUserName -IpAddress $NodeIp |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -match '^/dev/' })
                if ($reusableAfterAttach.Count -eq 1) {
                    $Device = $reusableAfterAttach[0]
                    Write-Log "[Ceph] Resolved OSD target device after attach as '$Device'." -Console
                }
                elseif ($reusableAfterAttach.Count -gt 1) {
                    $Device = ($reusableAfterAttach | Sort-Object | Select-Object -First 1)
                    Write-Log "[Ceph] Multiple reusable empty OSD devices detected after attach ($($reusableAfterAttach -join ', ')); selecting '$Device'." -Console
                }
                else {
                    Write-Log "[Ceph] Could not resolve a reusable empty OSD device after attach; falling back to guest auto-detection in prepare-osd-disk-hyperv.sh." -Console
                    $Device = ''
                }
            }
        }
    }

$scriptArgs = if ([string]::IsNullOrWhiteSpace($Device)) { @() } else { @($Device) }

if (-not (Test-Path $diskScript)) {
    Write-Log "[Ceph] ERROR: OSD disk preparation script not found: '$diskScript'" -Console -Error
    if ($nodeType -eq 'HyperV' -and -not [string]::IsNullOrWhiteSpace($createdVhdxPath)) {
        Remove-CreatedOsdVhdx -VmName $vmName -VhdxPath $createdVhdxPath
    }
    exit 1
}

try {
    Write-Log "[Ceph] Preparing raw OSD disk on '$NodeIp' ($nodeType)$(if ($Device) { " target '$Device'" })..." -Console
    $diskOutput = Invoke-RemoteScript -LocalScriptPath $diskScript -UserName $sshUserName -IpAddress $NodeIp -Arguments $scriptArgs -CleanupAfterExecution -Retries 2 -DetailedLogging

    $diskOutputText = ($diskOutput | Out-String)
    $readyLine = $diskOutputText -split "`r?`n" | Where-Object { $_.Trim().StartsWith('K2S_CEPH_OSD_DISK_READY=') } | Select-Object -Last 1
    $diskLine = $diskOutputText -split "`r?`n" | Where-Object { $_.Trim().StartsWith('K2S_CEPH_OSD_DISK=') } | Select-Object -Last 1

    if ([string]::IsNullOrWhiteSpace($readyLine)) {
        throw "OSD disk preparation did not complete successfully on node '$NodeIp'."
    }

    $preparedDisk = if (-not [string]::IsNullOrWhiteSpace($diskLine)) { $diskLine.Trim().Substring('K2S_CEPH_OSD_DISK='.Length).Trim() } else { $Device }
}
catch {
    Write-Log "[Ceph] ERROR: $($_.Exception.Message)" -Console -Error
    # Roll back the virtual disk we created this run so it does not become an orphaned attachment.
    if ($nodeType -eq 'HyperV' -and -not [string]::IsNullOrWhiteSpace($createdVhdxPath)) {
        Remove-CreatedOsdVhdx -VmName $vmName -VhdxPath $createdVhdxPath
    }
    exit 1
}

Write-Log "[Ceph] Raw OSD disk '$preparedDisk' is ready on node '$NodeIp' - cephadm/ceph-volume can now consume it as an OSD." -Console
Write-Output "K2S_CEPH_OSD_DISK=$preparedDisk"
Write-Output "K2S_CEPH_OSD_NODE_IP=$NodeIp"
# Output the VHDX path if one was created (Hyper-V nodes only) so the calling script can track it for cleanup validation
if (-not [string]::IsNullOrWhiteSpace($createdVhdxPath)) {
    Write-Output "K2S_CEPH_OSD_VHDX_PATH=$createdVhdxPath"
}
exit 0
