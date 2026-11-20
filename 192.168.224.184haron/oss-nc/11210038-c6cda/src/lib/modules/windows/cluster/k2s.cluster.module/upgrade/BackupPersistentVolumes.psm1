# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Generic PersistentVolume backup and restore functionality for K2s cluster upgrades

.DESCRIPTION
This module provides functionality to backup and restore any PersistentVolume data directly
from the kubemaster VM. It discovers PVs dynamically from the Kubernetes cluster and handles
backing up local/hostPath volumes to the Windows host.

Supports:
- Automatic PV discovery via kubectl
- Local volume type backup (hostPath on VM)
- Compressed tar.gz archives for efficient storage
- Metadata tracking for restore operations
#>

# Import required modules 
$infraModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$vmModule = "$PSScriptRoot\..\..\..\node\k2s.node.module\linuxnode\vm\vm.module.psm1"

Import-Module $infraModule
Import-Module $pathModule
Import-Module $vmModule

<#
.SYNOPSIS
Determines volume type and path from a PV spec object

.DESCRIPTION
Examines a PV spec to identify if it's local, hostPath, or other type,
and extracts the corresponding path. Validates that supported types have paths.

.PARAMETER PVSpec
The spec object from a PersistentVolume

.PARAMETER PVName
Name of the PV for error messages

.PARAMETER ThrowOnMissingPath
If true, throws error when path is missing for local/hostPath volumes.
If false, returns null path.

.OUTPUTS
Hashtable with Type (string) and Path (string or null)

.EXAMPLE
$typeInfo = Get-PVTypeAndPath -PVSpec $pv.spec -PVName "registry-pv" -ThrowOnMissingPath
Returns @{Type='local'; Path='/mnt/registry'}
#>
function Get-PVTypeAndPath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$PVSpec,
        
        [Parameter(Mandatory = $true)]
        [string]$PVName,
        
        [Parameter(Mandatory = $false)]
        [switch]$ThrowOnMissingPath
    )
    
    $result = @{
        Type = $null
        Path = $null
    }
    
    if ($PVSpec.local) {
        $result.Type = 'local'
        $result.Path = $PVSpec.local.path
        
        if ($ThrowOnMissingPath -and -not $result.Path) {
            throw "PV '$PVName' is missing path: spec.local.path"
        }
    }
    elseif ($PVSpec.hostPath) {
        $result.Type = 'hostPath'
        $result.Path = $PVSpec.hostPath.path
        
        if ($ThrowOnMissingPath -and -not $result.Path) {
            throw "PV '$PVName' is missing path: spec.hostPath.path"
        }
    }
    else {
        $result.Type = 'other'
        $result.Path = $null
    }
    
    return $result
}

<#
.SYNOPSIS
Converts kubectl PV JSON output to structured hashtable array

.DESCRIPTION
Takes JSON string from kubectl get pv -o json and converts it to an array of hashtables
with PV details. This is a pure parsing function for unit testing.

.PARAMETER PVListJson
The JSON string from kubectl get pv -o json

.OUTPUTS
Array of hashtables containing PV information with keys: Name, Capacity, Status, ClaimNamespace, ClaimName, ReclaimPolicy, Type, Path

.EXAMPLE
$json = kubectl get pv -o json | Out-String
$pvs = ConvertFrom-PVList -PVListJson $json
Returns formatted PV details from JSON string
#>
function ConvertFrom-PVList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PVListJson
    )
    
    $pvList = $PVListJson | ConvertFrom-Json
    $pvDetails = @()
    
    foreach ($pv in $PVList.items) {
        # Validate mandatory fields
        if (-not $pv.metadata.name) {
            throw "PV is missing mandatory field: metadata.name"
        }
        if (-not $pv.spec.capacity.storage) {
            throw "PV '$($pv.metadata.name)' is missing mandatory field: spec.capacity.storage"
        }
        if (-not $pv.status.phase) {
            throw "PV '$($pv.metadata.name)' is missing mandatory field: status.phase"
        }
        
        $pvInfo = @{
            Name = $pv.metadata.name
            Capacity = $pv.spec.capacity.storage
            Status = $pv.status.phase
            ClaimNamespace = $pv.spec.claimRef.namespace
            ClaimName = $pv.spec.claimRef.name
            ReclaimPolicy = $pv.spec.persistentVolumeReclaimPolicy
        }
        
        # Determine volume type and path
        $typeInfo = Get-PVTypeAndPath -PVSpec $pv.spec -PVName $pv.metadata.name -ThrowOnMissingPath
        $pvInfo.Type = $typeInfo.Type
        $pvInfo.Path = $typeInfo.Path
        
        $pvDetails += $pvInfo
    }
    
    return [array]$pvDetails
}

<#
.SYNOPSIS
Lists all PersistentVolumes in the cluster

.DESCRIPTION
Queries Kubernetes for all PVs and returns their details including name, capacity, type, and path

.OUTPUTS
Array of hashtables containing PV information

.EXAMPLE
Get-PersistentVolumes
Returns all PVs in the cluster with their configuration
#>
function Get-PersistentVolumes {
    Write-Log "[PVBackup] Querying cluster for PersistentVolumes..." -Console
    
    try {
        $pvListJson = kubectl get pv -o json 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-Log "[PVBackup] Failed to query PVs: $pvListJson" -Console -Error
            return @()
        }
        
        # Convert array output to single string if needed
        if ($pvListJson -is [array]) {
            $pvListJson = $pvListJson -join "`n"
        }
        
        $pvDetails = ConvertFrom-PVList -PVListJson $pvListJson

        Write-Log "[PVBackup] Found $($pvDetails.Count) PersistentVolume(s) in cluster (includes system, user workload, and addon volumes)" -Console
        return $pvDetails
    }
    catch {
        Write-Log "[PVBackup] Error querying PVs: $_" -Console -Error
        return @()
    }
}

<#
.SYNOPSIS
[Internal] Exports a single PersistentVolume's data from kubemaster VM to a compressed archive

.DESCRIPTION
Internal helper function that creates a backup of a PV's data directory from the kubemaster VM.
Only supports local and hostPath volume types (volumes stored on the VM filesystem).
The backup is compressed as a tar.gz file for efficient storage and transfer.

Uses the following approach:
1. Validates PV exists and is a supported type (local/hostPath)
2. Creates a temporary copy of the PV data with accessible permissions
3. Compresses the directory into a tar.gz archive on the VM
4. Transfers the compressed archive to the Windows host via SCP
5. Cleans up temporary files on both VM and host

.PARAMETER PVName
Name of the PersistentVolume to backup (e.g., 'registry-pv', 'opensearch-cluster-master-pv')

.PARAMETER ExportPath
Directory path on Windows host where the backup will be saved.

.PARAMETER BackupName
Name for the backup file (without extension). 
Defaults to '<pvname>-backup'

.OUTPUTS
Boolean indicating if backup was successful

.EXAMPLE
Export-PersistentVolume -PVName registry-pv -ExportPath "C:\backup\pv"
Exports registry-pv to specified backup directory

.EXAMPLE
Export-PersistentVolume -PVName opensearch-cluster-master-pv -ExportPath "D:\backups" -BackupName "opensearch-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Exports with timestamp to custom location

.EXAMPLE
Get-PersistentVolumes | Where-Object { $_.Type -eq 'local' } | ForEach-Object { Export-PersistentVolume -PVName $_.Name }
Backs up all local PVs in the cluster
#>
function Export-PersistentVolume {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PVName,
        
        [Parameter(Mandatory = $true)]
        [string]$ExportPath,
        
        [Parameter(Mandatory = $false)]
        [string]$BackupName
    )
    
    # Determine backup name
    if (-not $BackupName) {
        $BackupName = "$PVName-backup"
    }
    
    Write-Log "[PVBackup] Starting export of PersistentVolume '$PVName'..." -Console

    try {
        # Step 1: Query PV details from cluster
        Write-Log "[PVBackup] Querying PV details from cluster..." -Console
        $pvYaml = kubectl get pv $PVName -o json 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-Log "[PVBackup] PV '$PVName' not found in cluster" -Console -Error
            return $false
        }
        
        $pv = $pvYaml | ConvertFrom-Json
        
        # Determine volume type and path
        $typeInfo = Get-PVTypeAndPath -PVSpec $pv.spec -PVName $PVName
        $volumeType = $typeInfo.Type
        $volumePath = $typeInfo.Path
        
        # Validate supported volume type
        if ($volumeType -notin @('local', 'hostPath')) {
            Write-Log "[PVBackup] PV '$PVName' is not a local or hostPath volume (unsupported type: $volumeType)" -Console -Error
            return $false
        }
        
        # Validate path exists for supported types
        if (-not $volumePath) {
            Write-Log "[PVBackup] PV '$PVName' is missing volume path" -Console -Error
            return $false
        }
        
        Write-Log "[PVBackup] PV Type: $volumeType" -Console
        Write-Log "[PVBackup] PV Path: $volumePath" -Console
        Write-Log "[PVBackup] Capacity: $($pv.spec.capacity.storage)" -Console
        Write-Log "[PVBackup] Status: $($pv.status.phase)" -Console

        if ($pv.spec.claimRef) {
            Write-Log "[PVBackup] Bound to: $($pv.spec.claimRef.namespace)/$($pv.spec.claimRef.name)" -Console
        }
        
        # Ensure export directory exists on Windows host
        if (-not (Test-Path $ExportPath)) {
            Write-Log "[PVBackup] Creating export directory: $ExportPath" -Console
            New-Item -Path $ExportPath -ItemType Directory -Force | Out-Null
        }
        
        # Setup paths for backup
        $tempCopyPath = "/tmp/pv-backup-$PVName"
        $tempArchivePath = "/tmp/pv-backup-$PVName.tar.gz"
        $finalBackupPath = Join-Path $ExportPath "$BackupName.tar.gz"
        
        # Get VM connection details using K2s helper functions
        $sshKeyControlPlane = Get-SSHKeyControlPlane
        $ipAddress = Get-ConfiguredIPControlPlane
        $sshUser = 'remote'  # Standard K2s VM user with passwordless sudo
        
        Write-Log "[PVBackup] Connecting to VM at $ipAddress"

        # Step 2: Check if volume path exists on VM
        Write-Log "[PVBackup] Checking volume path on VM..." -Console
        $checkCmd = "sudo test -d '$volumePath' && echo 'exists' || echo 'missing'"
        $checkResult = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $checkCmd -NoLog
        
        if ($checkResult.Output -notmatch 'exists') {
            Write-Log "[PVBackup] Volume path not found at $volumePath on VM (check output: '$($checkResult.Output)')" -Console -Error
            return $false
        }
        
        Write-Log "[PVBackup] Volume path found on VM" -Console

        # Step 3: Get size of volume for user information
        Write-Log "[PVBackup] Calculating volume size..." -Console
        $sizeCmd = "sudo du -sh '$volumePath' | cut -f1"
        $sizeResult = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 5 -CmdToExecute $sizeCmd -NoLog
        $volumeSize = $sizeResult.Output
        Write-Log "[PVBackup] Volume size: $volumeSize" -Console

        # Step 4: Clean up any previous temporary files
        Write-Log "[PVBackup] Cleaning up any previous temporary files..." -Console
        $cleanupCmd = "sudo rm -rf '$tempCopyPath' '$tempArchivePath'"
        Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $cleanupCmd -NoLog | Out-Null
        
        # Step 5: Create temporary copy with proper permissions
        Write-Log "[PVBackup] Creating temporary copy with accessible permissions..." -Console
        $copyCmd = "sudo rm -rf '$tempCopyPath' && sudo mkdir -p '$tempCopyPath' && sudo cp -r '$volumePath'/* '$tempCopyPath'/ && sudo chown -R $sshUser`:users '$tempCopyPath'"
        Invoke-CmdOnControlPlaneViaSSHKey -Timeout 60 -CmdToExecute $copyCmd -NoLog | Out-Null
        
        Write-Log "[PVBackup] Temporary copy created successfully" -Console

        # Step 6: Compress the directory into tar.gz on VM
        Write-Log "[PVBackup] Compressing volume data (this may take a while)..." -Console
        $compressCmd = "cd '$tempCopyPath' && tar czf '$tempArchivePath' ."
        Invoke-CmdOnControlPlaneViaSSHKey -Timeout 180 -CmdToExecute $compressCmd -NoLog | Out-Null
        
        Write-Log "[PVBackup] Compression completed" -Console

        # Step 7: Get compressed archive size
        $archiveSizeCmd = "ls -lh '$tempArchivePath' | awk '{print `$5}'"
        $archiveSizeResult = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $archiveSizeCmd -NoLog
        $archiveSize = $archiveSizeResult.Output
        Write-Log "[PVBackup] Compressed archive size: $archiveSize" -Console

        # Step 8: Transfer compressed archive to Windows host via SCP
        Write-Log "[PVBackup] Transferring archive to Windows host..." -Console
        Write-Log "[PVBackup] Target: $finalBackupPath" -Console

        # Use scp.exe directly (following K2s vm.module.psm1 pattern)
        $scpArgs = @(
            '-o', 'StrictHostKeyChecking=no',
            '-i', "`"$sshKeyControlPlane`"",
            "$sshUser@$ipAddress`:$tempArchivePath",
            "`"$finalBackupPath`""
        )
        
        $scpResult = & scp.exe @scpArgs 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "SCP transfer failed: $scpResult"
        }
        
        Write-Log "[PVBackup] Archive transferred successfully" -Console

        # Step 9: Verify tar.gz file exists on Windows
        if (-not (Test-Path $finalBackupPath)) {
            throw "Transferred file not found at: $finalBackupPath"
        }
        
        $localFileSize = (Get-Item $finalBackupPath).Length
        Write-Log "[PVBackup] Backup archive size: $([Math]::Round($localFileSize / 1MB, 2)) MB" -Console

        # Step 10: Clean up temporary files on VM
        Write-Log "[PVBackup] Cleaning up temporary files on VM..." -Console
        $vmCleanupCmd = "sudo rm -rf '$tempCopyPath' '$tempArchivePath'"
        Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $vmCleanupCmd -NoLog | Out-Null
        
        Write-Log "[PVBackup] VM cleanup completed" -Console

        # Step 11: Create backup metadata file
        $metadataPath = Join-Path $ExportPath "$BackupName-metadata.json"
        $metadata = @{
            version          = "1.0"
            backupType       = "persistent-volume"
            pvName           = $PVName
            volumeType       = $volumeType
            volumePath       = $volumePath
            capacity         = $pv.spec.capacity.storage
            createdAt        = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            sourceSize       = if ($volumeSize) { $volumeSize.Trim() } else { "unknown" }
            archiveSize      = "$([Math]::Round($localFileSize / 1MB, 2)) MB"
            vmIpAddress      = $ipAddress
            backupFile       = "$BackupName.tar.gz"
            claimNamespace   = $pv.spec.claimRef.namespace
            claimName        = $pv.spec.claimRef.name
            reclaimPolicy    = $pv.spec.persistentVolumeReclaimPolicy
        }
        
        $metadata | ConvertTo-Json -Depth 3 | Set-Content -Path $metadataPath -Encoding UTF8
        Write-Log "[PVBackup] Backup metadata saved: $metadataPath" -Console

        Write-Log "[PVBackup] ========================================" -Console
        Write-Log "[PVBackup] PersistentVolume backup completed successfully!" -Console
        Write-Log "[PVBackup] PV Name: $PVName" -Console
        Write-Log "[PVBackup] Backup location: $finalBackupPath" -Console
        Write-Log "[PVBackup] Metadata: $metadataPath" -Console
        Write-Log "[PVBackup] ========================================" -Console

        return $true
    }
    catch {
        Write-Log "[PVBackup] Error during PV export: $_" -Console -Error
        Write-Log "[PVBackup] Stack trace: $($_.ScriptStackTrace)" -Console

        # Attempt cleanup on error
        try {
            Write-Log "[PVBackup] Attempting cleanup after error..." -Console

            # Clean up VM
            $vmCleanupCmd = "sudo rm -rf '$tempCopyPath' '$tempArchivePath'"
            Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $vmCleanupCmd -NoLog -ErrorAction SilentlyContinue | Out-Null
            
            # Clean up local files
            if (Test-Path $finalBackupPath) {
                Remove-Item $finalBackupPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Log "[PVBackup] Cleanup encountered errors (non-critical): $_" -Console
        }
        
        return $false
    }
}

<#
.SYNOPSIS
Validates backup file and loads metadata

.DESCRIPTION
Checks if backup file exists, validates its size, and loads the associated metadata JSON file.

.PARAMETER BackupPath
Path to the backup tar.gz file

.OUTPUTS
Hashtable with Valid (bool), Error (string), Metadata (object), BackupFileSize (long)
#>
function Get-BackupMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupPath
    )
    
    $result = @{
        Valid = $false
        Error = $null
        Metadata = $null
        BackupFileSize = 0
    }
    
    try {
        # Validate backup file exists
        if (-not (Test-Path $BackupPath)) {
            $result.Error = "Backup file not found: $BackupPath"
            Write-Log "[PVBackup] $($result.Error)" -Console -Error
            return $result
        }
        
        $result.BackupFileSize = (Get-Item $BackupPath).Length
        Write-Log "[PVBackup] Backup file size: $([Math]::Round($result.BackupFileSize / 1MB, 2)) MB" -Console
        
        # Load metadata
        $metadataPath = $BackupPath -replace '\.tar\.gz$', '-metadata.json'
        
        if (-not (Test-Path $metadataPath)) {
            $result.Error = "Metadata file not found: $metadataPath"
            Write-Log "[PVBackup] $($result.Error)" -Console -Error
            Write-Log "[PVBackup] Cannot determine restore target without metadata" -Console -Error
            return $result
        }
        
        $result.Metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        
        Write-Log "[PVBackup] Backup metadata loaded:" -Console
        Write-Log "[PVBackup]   PV Name: $($result.Metadata.pvName)" -Console
        Write-Log "[PVBackup]   Volume Type: $($result.Metadata.volumeType)" -Console
        Write-Log "[PVBackup]   Target Path: $($result.Metadata.volumePath)" -Console
        Write-Log "[PVBackup]   Original Capacity: $($result.Metadata.capacity)" -Console
        Write-Log "[PVBackup]   Backup Date: $($result.Metadata.createdAt)" -Console
        
        $result.Valid = $true
        return $result
    }
    catch {
        $result.Error = "Error loading metadata: $_"
        Write-Log "[PVBackup] $($result.Error)" -Console -Error
        return $result
    }
}

<#
.SYNOPSIS
Prompts for confirmation and checks pods using PV

.DESCRIPTION
Prompts user for confirmation (unless -Force is specified) and checks if any pods are currently using the PV.

.PARAMETER Metadata
Metadata object from backup

.PARAMETER VolumeTargetPath
Target path where volume will be restored

.PARAMETER Force
Skip confirmation prompts

.OUTPUTS
Hashtable with Continue (bool) and UsingPods (array)
#>
function Confirm-RestoreOperation {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata,
        
        [Parameter(Mandatory = $true)]
        [string]$VolumeTargetPath,
        
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )
    
    $result = @{
        Continue = $true
        UsingPods = @()
    }
    
    try {
        # Prompt for confirmation unless -Force is specified
        if (-not $Force) {
            Write-Log "[PVBackup] WARNING: This will replace the existing volume data at $VolumeTargetPath on the VM!" -Console
            $confirmation = Read-Host "Are you sure you want to continue? (yes/no)"
            
            if ($confirmation -ne 'yes') {
                Write-Log "[PVBackup] Restore cancelled by user" -Console
                $result.Continue = $false
                return $result
            }
        }
        
        # Check if PV is in use (warn if pods are using it)
        Write-Log "[PVBackup] Checking if PV is in use..." -Console
        if ($Metadata.claimNamespace -and $Metadata.claimName) {
            $kubeToolsPath = Get-KubeToolsPath
            $kubectlExe = "$kubeToolsPath\kubectl.exe"
            $podsJson = & $kubectlExe get pods -n $Metadata.claimNamespace -o json 2>&1
            if ($LASTEXITCODE -eq 0) {
                $pods = $podsJson | ConvertFrom-Json
                $usingPods = $pods.items | Where-Object {
                    $_.spec.volumes | Where-Object { $_.persistentVolumeClaim.claimName -eq $Metadata.claimName }
                }
                
                if ($usingPods) {
                    $result.UsingPods = $usingPods
                    Write-Log "[PVBackup] WARNING: Found $($usingPods.Count) pod(s) using this PV:" -Console
                    foreach ($pod in $usingPods) {
                        Write-Log "[PVBackup]   - $($pod.metadata.namespace)/$($pod.metadata.name)" -Console
                    }
                    Write-Log "[PVBackup] It is recommended to stop these pods before restoring" -Console
                    
                    if (-not $Force) {
                        $continueAnyway = Read-Host "Continue anyway? (yes/no)"
                        if ($continueAnyway -ne 'yes') {
                            Write-Log "[PVBackup] Restore cancelled" -Console
                            $result.Continue = $false
                            return $result
                        }
                    }
                }
            }
        }
        
        return $result
    }
    catch {
        Write-Log "[PVBackup] Error during confirmation: $_" -Console -Error
        $result.Continue = $false
        return $result
    }
}

<#
.SYNOPSIS
Transfers backup to VM via SCP

.DESCRIPTION
Transfers the backup tar.gz file from Windows host to the VM using SCP.

.PARAMETER BackupPath
Path to backup file on Windows host

.PARAMETER TempUploadPath
Target path on VM for uploaded file

.PARAMETER PVName
Name of the PersistentVolume (for logging)

.OUTPUTS
Boolean indicating transfer success
#>
function Copy-BackupToVM {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupPath,
        
        [Parameter(Mandatory = $true)]
        [string]$TempUploadPath,
        
        [Parameter(Mandatory = $true)]
        [string]$PVName
    )
    
    try {
        Write-Log "[PVBackup] Transferring backup to VM..." -Console
        
        # Verify backup is tar.gz
        if ($BackupPath -notmatch '\.tar\.gz$') {
            throw "Backup file must be a .tar.gz archive. Found: $BackupPath"
        }
        
        # Get VM connection details
        $sshKeyControlPlane = Get-SSHKeyControlPlane
        $ipAddress = Get-ConfiguredIPControlPlane
        $sshUser = 'remote'
        
        Write-Log "[PVBackup] Connecting to kubemaster VM at $ipAddress" -Console
        
        $scpArgs = @(
            '-o', 'StrictHostKeyChecking=no',
            '-i', "`"$sshKeyControlPlane`"",
            "`"$BackupPath`"",
            "$sshUser@$ipAddress`:$TempUploadPath"
        )
        
        $scpResult = & scp.exe @scpArgs 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "SCP transfer failed: $scpResult"
        }
        
        Write-Log "[PVBackup] Transfer completed successfully" -Console
        return $true
    }
    catch {
        Write-Log "[PVBackup] Error during backup transfer: $_" -Console -Error
        return $false
    }
}

<#
.SYNOPSIS
Restores volume data on VM

.DESCRIPTION
Backs up existing data, extracts archive, sets permissions, and verifies the restored data.

.PARAMETER VolumeTargetPath
Target path for volume data on VM

.PARAMETER TempUploadPath
Path to uploaded tar.gz file on VM

.PARAMETER TempExtractPath
Temporary extraction path on VM

.PARAMETER PVName
Name of the PersistentVolume

.OUTPUTS
Hashtable with Success (bool), RestoredSize (string), BackupPath (string)
#>
function Restore-VolumeDataOnVM {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VolumeTargetPath,
        
        [Parameter(Mandatory = $true)]
        [string]$TempUploadPath,
        
        [Parameter(Mandatory = $true)]
        [string]$TempExtractPath,
        
        [Parameter(Mandatory = $true)]
        [string]$PVName
    )
    
    $result = @{
        Success = $false
        RestoredSize = $null
        BackupPath = $null
    }
    
    try {
        # Backup existing volume data on VM (if exists)
        Write-Log "[PVBackup] Creating backup of existing volume data on VM..." -Console
        $backupTimestamp = Get-Date -Format 'yyyyMMddHHmmss'
        $existingBackupPath = "/tmp/pv-backup-$PVName-$backupTimestamp"
        $backupExistingCmd = "sudo test -d '$VolumeTargetPath' && sudo mv '$VolumeTargetPath' '$existingBackupPath' || echo 'no existing volume data'"
        Invoke-CmdOnControlPlaneViaSSHKey -Timeout 5 -CmdToExecute $backupExistingCmd -NoLog | Out-Null
        
        $result.BackupPath = $existingBackupPath
        
        # Extract and restore volume data on VM
        Write-Log "[PVBackup] Extracting and restoring volume data on VM..." -Console
        
        # Clean up any previous restore attempts
        $cleanCmd = "sudo rm -rf '$TempExtractPath'"
        Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $cleanCmd -NoLog | Out-Null
        
        # Extract uploaded archive directly to target location
        $extractCmd = "sudo mkdir -p '$VolumeTargetPath' && sudo tar xzf '$TempUploadPath' -C '$VolumeTargetPath'"
        Invoke-CmdOnControlPlaneViaSSHKey -Timeout 120 -CmdToExecute $extractCmd -NoLog | Out-Null
        
        # Set proper permissions: 755 for directories (rwxr-xr-x) and 644 for files (rw-r--r--) so services can read them
        $permissionsCmd = "sudo chown -R root:root '$VolumeTargetPath' && sudo chmod -R 755 '$VolumeTargetPath' && sudo find '$VolumeTargetPath' -type f -exec chmod 644 {} \;"
        Invoke-CmdOnControlPlaneViaSSHKey -Timeout 60 -CmdToExecute $permissionsCmd -NoLog | Out-Null
        
        Write-Log "[PVBackup] Volume data restored successfully with proper permissions" -Console
        
        # Verify restored directory
        Write-Log "[PVBackup] Verifying restored volume data..." -Console
        $verifyCmd = "sudo du -sh '$VolumeTargetPath' | cut -f1"
        $verifyResult = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 5 -CmdToExecute $verifyCmd -NoLog
        $result.RestoredSize = $verifyResult.Output
        Write-Log "[PVBackup] Restored volume size: $($result.RestoredSize)" -Console
        
        $result.Success = $true
        return $result
    }
    catch {
        Write-Log "[PVBackup] Error during volume data restore: $_" -Console -Error
        return $result
    }
}

<#
.SYNOPSIS
Restarts pods using the PV

.DESCRIPTION
Queries for pods using the PVC, deletes them, and waits for them to restart.

.PARAMETER Metadata
Metadata object from backup containing claim namespace and name

.OUTPUTS
Array of pod restart result hashtables with PodName, Namespace, Deleted, Restarted
#>
function Restart-PodsUsingPV {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata
    )
    
    $results = @()
    
    try {
        if ($Metadata.claimNamespace -and $Metadata.claimName) {
            $kubeToolsPath = Get-KubeToolsPath
            $kubectlExe = "$kubeToolsPath\kubectl.exe"
            
            Write-Log "[PVBackup] Restarting pod(s) using PVC '$($Metadata.claimNamespace)/$($Metadata.claimName)'..." -Console
            
            $podsJson = & $kubectlExe get pods -n $Metadata.claimNamespace -o json 2>&1
            if ($LASTEXITCODE -eq 0) {
                $pods = $podsJson | ConvertFrom-Json
                $usingPods = $pods.items | Where-Object {
                    $_.spec.volumes | Where-Object { $_.persistentVolumeClaim.claimName -eq $Metadata.claimName }
                }
                
                if ($usingPods) {
                    foreach ($pod in $usingPods) {
                        $podName = $pod.metadata.name
                        $podNamespace = $pod.metadata.namespace
                        
                        $podResult = @{
                            PodName = $podName
                            Namespace = $podNamespace
                            Deleted = $false
                            Restarted = $false
                        }
                        
                        Write-Log "[PVBackup] Restarting pod: $podNamespace/$podName" -Console
                        & $kubectlExe delete pod -n $podNamespace $podName --wait=false 2>&1 | Out-Null
                        
                        if ($LASTEXITCODE -eq 0) {
                            $podResult.Deleted = $true
                            Write-Log "[PVBackup] Pod deleted, waiting for it to restart..." -Console
                            
                            # Wait for pod to be ready (60 second timeout)
                            $waitResult = & $kubectlExe wait --for=condition=ready pod -n $podNamespace $podName --timeout=60s 2>&1
                            
                            if ($LASTEXITCODE -eq 0) {
                                $podResult.Restarted = $true
                                Write-Log "[PVBackup] Pod $podNamespace/$podName restarted successfully" -Console
                            }
                            else {
                                Write-Log "[PVBackup] Pod restart may still be in progress: $waitResult" -Console
                            }
                        }
                        else {
                            Write-Log "[PVBackup] Failed to delete pod $podNamespace/$podName" -Console
                        }
                        
                        $results += $podResult
                    }
                }
                else {
                    Write-Log "[PVBackup] No pods currently using this PVC" -Console
                }
            }
        }
        
        return $results
    }
    catch {
        Write-Log "[PVBackup] Error during pod restart: $_" -Console -Error
        return $results
    }
}

<#
.SYNOPSIS
[Internal] Restores a single PersistentVolume's data from a backup archive to the kubemaster VM

.DESCRIPTION
Internal helper function that restores a previously backed up PV data directory to the kubemaster VM.
The target path is read from the backup metadata file.

WARNING: This will replace the existing volume content on the VM.

Uses the following approach:
1. Validates backup file and metadata exist on Windows host
2. Reads target path from metadata
3. Transfers tar.gz archive to VM via SCP
4. Extracts and restores to the volume path with proper permissions
5. Cleans up temporary files

.PARAMETER BackupPath
Full path to the backup tar.gz file on Windows host

.PARAMETER Force
If specified, will not prompt for confirmation before replacing volume content

.OUTPUTS
Boolean indicating if restore was successful

.EXAMPLE
Restore-PersistentVolume -BackupPath "C:\k2s\var\backup\pv\registry-pv-backup.tar.gz"
Restores PV from backup file

.EXAMPLE
Restore-PersistentVolume -BackupPath "D:\backups\opensearch-20241204.tar.gz" -Force
Restores without confirmation prompt

.NOTES
After restoring, you may need to restart the pod(s) using the PVC to recognize the restored data.
Use: kubectl delete pod -n <namespace> <pod-name>
#>
function Restore-PersistentVolume {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupPath,
        
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )
    
    Write-Log "[PVBackup] Starting restore of PersistentVolume..." -Console
    
    try {
        # Step 1: Validate backup file and load metadata
        $metadataResult = Get-BackupMetadata -BackupPath $BackupPath
        
        if (-not $metadataResult.Valid) {
            return $false
        }
        
        $metadata = $metadataResult.Metadata
        $volumeTargetPath = $metadata.volumePath
        $pvName = $metadata.pvName
        
        # Step 2: Prompt for confirmation and check pods using PV
        $confirmResult = Confirm-RestoreOperation -Metadata $metadata -VolumeTargetPath $volumeTargetPath -Force:$Force
        
        if (-not $confirmResult.Continue) {
            return $false
        }
        
        # Setup paths
        $tempUploadPath = "/tmp/pv-restore-$pvName.tar.gz"
        $tempExtractPath = "/tmp/pv-restore-$pvName"
        
        # Step 3: Transfer backup to VM via SCP
        $transferSuccess = Copy-BackupToVM -BackupPath $BackupPath -TempUploadPath $tempUploadPath -PVName $pvName
        
        if (-not $transferSuccess) {
            return $false
        }
        
        # Step 4: Restore volume data on VM (backup existing, extract, set permissions, verify)
        $restoreResult = Restore-VolumeDataOnVM -VolumeTargetPath $volumeTargetPath -TempUploadPath $tempUploadPath -TempExtractPath $tempExtractPath -PVName $pvName
        
        if (-not $restoreResult.Success) {
            return $false
        }
        
        # Step 5: Clean up temporary files
        Write-Log "[PVBackup] Cleaning up temporary files on VM..." -Console
        $vmCleanupCmd = "sudo rm -rf '$tempUploadPath' '$tempExtractPath'"
        Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $vmCleanupCmd -NoLog | Out-Null
        
        Write-Log "[PVBackup] ========================================" -Console
        Write-Log "[PVBackup] PersistentVolume restore completed successfully!" -Console
        Write-Log "[PVBackup] PV Name: $pvName" -Console
        Write-Log "[PVBackup] Restored from: $BackupPath" -Console
        Write-Log "[PVBackup] Target path: $volumeTargetPath" -Console
        Write-Log "[PVBackup] Old data backed up to: $($restoreResult.BackupPath) (on VM)" -Console
        
        # Step 6: Restart pods using the PVC to recognize restored data
        $podRestartResults = Restart-PodsUsingPV -Metadata $metadata
        
        Write-Log "[PVBackup] ========================================" -Console
        
        return $true
    }
    catch {
        Write-Log "[PVBackup] Error during PV restore: $_" -Console -Error
        Write-Log "[PVBackup] Stack trace: $($_.ScriptStackTrace)" -Console
        
        # Attempt cleanup on error
        try {
            Write-Log "[PVBackup] Attempting cleanup after error..." -Console
            
            # Clean up VM
            $vmCleanupCmd = "sudo rm -rf '$tempUploadPath' '$tempExtractPath'"
            Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $vmCleanupCmd -NoLog -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            Write-Log "[PVBackup] Cleanup encountered errors (non-critical): $_" -Console
        }
        
        return $false
    }
}

<#
.SYNOPSIS
Backs up all local/hostPath PersistentVolumes in the cluster

.DESCRIPTION
Discovers all PVs in the cluster and backs up those with local or hostPath storage types.
Creates individual backup archives for each PV.

.PARAMETER ExportPath
Directory path on Windows host where backups will be saved.

.PARAMETER IncludeNames
Optional array of PV names to include. If specified, only these PVs will be backed up.

.PARAMETER ExcludeNames
Optional array of PV names to exclude from backup.

.OUTPUTS
Hashtable with backup results for each PV

.EXAMPLE
Backup-AllPersistentVolumes -ExportPath "C:\backup\pv"
Backs up all local/hostPath PVs to specified location

.EXAMPLE
Backup-AllPersistentVolumes -ExportPath "D:\k2s-backups" -ExcludeNames @('test-pv')
Backs up all PVs except 'test-pv' to custom location
#>
function Backup-AllPersistentVolumes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExportPath,
        
        [Parameter(Mandatory = $false)]
        [string[]]$IncludeNames,
        
        [Parameter(Mandatory = $false)]
        [string[]]$ExcludeNames
    )

    Write-Log "[PVBackup] Starting backup of all PersistentVolumes..." -Console

    $pvList = Get-PersistentVolumes
    
    if ($pvList.Count -eq 0) {
        Write-Log "[PVBackup] No PersistentVolumes found in cluster" -Console
        return @{}
    }
    
    # Filter PVs
    $pvsToBackup = $pvList | Where-Object {
        # Only local/hostPath volumes
        ($_.Type -eq 'local' -or $_.Type -eq 'hostPath') -and
        # Include filter
        (-not $IncludeNames -or $IncludeNames -contains $_.Name) -and
        # Exclude filter
        (-not $ExcludeNames -or $ExcludeNames -notcontains $_.Name)
    }
    if ($ExcludeNames -and $ExcludeNames.Count -gt 0) {
        Write-Log "[PVBackup] Applying addon PV exclusion filter to cluster PVs..."
        $excludedPVs = $pvList | Where-Object { $ExcludeNames -contains $_.Name }
        if ($excludedPVs.Count -gt 0) {
            Write-Log "[PVBackup] Excluding addon-managed PV(s): $($excludedPVs.Name -join ', ')" -Console
        } else {
            Write-Log "[PVBackup] No addon PVs found in cluster to exclude"
        }
    }
    Write-Log "[PVBackup] Found $($pvsToBackup.Count) PV(s) to backup" -Console

    $results = @{}
    $successCount = 0
    $failCount = 0
    
    foreach ($pv in $pvsToBackup) {
        Write-Log "[PVBackup] ----------------------------------------" -Console
        Write-Log "[PVBackup] Backing up PV: $($pv.Name)" -Console
        
        $backupParams = @{
            PVName = $pv.Name
            ExportPath = $ExportPath
        }
        
        $success = Export-PersistentVolume @backupParams
        
        $results[$pv.Name] = $success
        
        if ($success) {
            $successCount++
        }
        else {
            $failCount++
        }
    }
    
    Write-Log "[PVBackup] ========================================" -Console
    Write-Log "[PVBackup] All PV backups completed" -Console
    Write-Log "[PVBackup] Success: $successCount | Failed: $failCount" -Console
    Write-Log "[PVBackup] ========================================" -Console

    return $results
}

<#
.SYNOPSIS
Restores all PersistentVolumes from backups in a directory

.DESCRIPTION
Discovers all backup files in the specified directory and restores them.
Each backup must have an associated metadata JSON file.

.PARAMETER BackupPath
Directory path containing PV backup files (.tar.gz).

.PARAMETER IncludeNames
Optional array of PV names to include. If specified, only these PVs will be restored.

.PARAMETER ExcludeNames
Optional array of PV names to exclude from restore.

.PARAMETER Force
If specified, will not prompt for confirmation before restoring each PV.

.OUTPUTS
Hashtable with restore results for each PV

.EXAMPLE
Restore-AllPersistentVolumes -BackupPath "C:\backup\pv" -Force
Restores all PVs from specified backup location without prompts

.EXAMPLE
Restore-AllPersistentVolumes -BackupPath "D:\k2s-backups" -ExcludeNames @('test-pv')
Restores all PVs except 'test-pv' from custom location
#>
function Restore-AllPersistentVolumes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupPath,
        
        [Parameter(Mandatory = $false)]
        [string[]]$IncludeNames,
        
        [Parameter(Mandatory = $false)]
        [string[]]$ExcludeNames,
        
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )
    
    Write-Log "[PVBackup] Starting restore of all PersistentVolumes..." -Console
    
    # Find all backup files
    if (-not (Test-Path $BackupPath)) {
        Write-Log "[PVBackup] Backup directory not found: $BackupPath" -Console -Error
        return @{}
    }
    
    $backupFiles = Get-ChildItem -Path $BackupPath -Filter "*-backup.tar.gz" -File
    
    if ($backupFiles.Count -eq 0) {
        Write-Log "[PVBackup] No backup files found in $BackupPath" -Console
        return @{}
    }
    
    Write-Log "[PVBackup] Found $($backupFiles.Count) backup file(s)" -Console
    
    # Filter backups based on PV names from metadata
    $backupsToRestore = @()
    
    foreach ($backupFile in $backupFiles) {
        $metadataPath = $backupFile.FullName -replace '\.tar\.gz$', '-metadata.json'
        
        if (-not (Test-Path $metadataPath)) {
            Write-Log "[PVBackup] Skipping $($backupFile.Name) - metadata not found" -Console
            continue
        }
        
        try {
            $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
            $pvName = $metadata.pvName
            
            # Apply filters
            $includeThis = (-not $IncludeNames -or $IncludeNames -contains $pvName)
            $excludeThis = ($ExcludeNames -and $ExcludeNames -contains $pvName)
            
            if ($includeThis -and -not $excludeThis) {
                $backupsToRestore += @{
                    BackupFile = $backupFile.FullName
                    PVName = $pvName
                    Metadata = $metadata
                }
            }
        }
        catch {
            Write-Log "[PVBackup] Skipping $($backupFile.Name) - failed to read metadata: $_" -Console
        }
    }
    
    if ($backupsToRestore.Count -eq 0) {
        Write-Log "[PVBackup] No backups match the specified criteria" -Console
        return @{}
    }
    
    Write-Log "[PVBackup] Found $($backupsToRestore.Count) backup(s) to restore" -Console
    
    # Prompt for confirmation unless -Force is specified
    if (-not $Force) {
        Write-Log "[PVBackup] The following PVs will be restored:" -Console
        foreach ($backup in $backupsToRestore) {
            Write-Log "[PVBackup]   - $($backup.PVName) (from $($backup.Metadata.createdAt))" -Console
        }
        
        $confirmation = Read-Host "Continue with restore? (yes/no)"
        if ($confirmation -ne 'yes') {
            Write-Log "[PVBackup] Restore cancelled by user" -Console
            return @{}
        }
    }
    
    $results = @{}
    $successCount = 0
    $failCount = 0
    
    foreach ($backup in $backupsToRestore) {
        Write-Log "[PVBackup] ----------------------------------------" -Console
        Write-Log "[PVBackup] Restoring PV: $($backup.PVName)" -Console
        
        $restoreParams = @{
            BackupPath = $backup.BackupFile
            Force = $true  # Already confirmed above
        }
        
        $success = Restore-PersistentVolume @restoreParams
        
        $results[$backup.PVName] = $success
        
        if ($success) {
            $successCount++
        }
        else {
            $failCount++
        }
    }
    
    Write-Log "[PVBackup] ========================================" -Console
    Write-Log "[PVBackup] All PV restores completed" -Console
    Write-Log "[PVBackup] Success: $successCount | Failed: $failCount" -Console
    Write-Log "[PVBackup] ========================================" -Console
    
    return $results
}

Export-ModuleMember -Function Backup-AllPersistentVolumes, Restore-AllPersistentVolumes
