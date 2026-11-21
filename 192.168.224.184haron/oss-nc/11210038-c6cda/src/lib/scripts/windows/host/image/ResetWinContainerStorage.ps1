# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
This script is used to clean the image storage of containerd and docker on the windows node.

.DESCRIPTION
If the cluster is running, then the script expects the user to stop the cluster
The scripts then cleans the containerd and docker directories provided as script arguments.
It is available to remove all running workloads from the cluster before running this script.

Sometimes, it is not possible to clean the directories with a single execution. Hence, the
script also accepts the number of retries to be performed as an argument.

.EXAMPLE
PS> Clean up Containerd and Docker image storage on windows node with no retries
PS> .\ResetWinContainerStorage.ps1 -Containerd D:\containerd -Docker D:\docker
PS>
PS> Clean up Containerd and Docker image storage on windows node with 5 retries
PS> .\ResetWinContainerStorage.ps1 -Containerd D:\containerd -Docker D:\docker -MaxRetries 5
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Containerd directory')]
    [string]$Containerd = '',
    [parameter(Mandatory = $false, HelpMessage = 'Docker directory')]
    [string]$Docker = 'C:\docker1',
    [parameter(Mandatory = $false, HelpMessage = 'Number of retries to be performed for deleting each directory')]
    [int]$MaxRetries = 1,
    [parameter(Mandatory = $false, HelpMessage = 'Use zap.exe to forcefully delete the folder')]
    [switch]$ForceZap = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'Trigger clean-up of windows container storage without user prompts')]
    [switch]$Force = $false
)
$infraModule = "$PSScriptRoot\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule

Initialize-Logging -ShowLogs:$ShowLogs

function Get-DockerStatus() {
    if (Get-Process 'dockerd' -ErrorAction SilentlyContinue) {
        return $true
    }
    return $false
}

<#
.SYNOPSIS
Cleanup docker storage directory

.DESCRIPTION
Cleanup docker storage directory  from all reparse points which could lead to an inconsistent system.
Also delete the whole folder afterwards.

# Only for docker: Cleanup in the docker way by renaming the folders
# Get-ChildItem -Path d:\docker\windowsfilter -Directory | % {Rename-Item $_.FullName "$($_.FullName)-removing" -ErrorAction:SilentlyContinue}
# Restart-Service *docker*
# needs to be done multiple times till all directories from windowsfilter are deleted !!

# OR

# 1. set right to be able to delete reparse points
# 2. icacls "D:\containerdold" /grant Administrators:F /t /C
# 3. Get-ChildItem -Path e:\docker_old3 -Force -Recurse -Attributes Reparsepoint -ErrorAction 'silentlycontinue' | % { $n = $_.FullName.Trim("\"); fsutil reparsepoint delete "$n" }
# deletes all reparse points
# then afterwards all directories can be deleted
# 4. takeown /a /r /d Y /f e:\docker_old3
# 5. remove-item -path "e:\docker_old3" -Force -Recurse -ErrorAction SilentlyContinue

.EXAMPLE
Invoke-GracefulCleanup -Directory d:\docker
Invoke-GracefulCleanup -Directory d:\containerd
#>
function Invoke-GracefulCleanup {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Docker directory to clean up')]
        [string] $Directory = 'c:\docker'
    )
    $errActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    if ($Trace) {
        Set-PSDebug -Trace 1
    }

    Write-Log "Take ownership now on items in dir: $Directory" -Console
    # 'takeown /r' recurses into reparse points inside the containerd storage (e.g. snapshot
    # mount points) whose targets may no longer resolve, emitting a benign
    # 'ERROR: File or Directory not found.' line. The top-level directory is guaranteed to exist
    # (checked by the caller before cleanup), so this specific message is a false positive and is
    # filtered from the log. All other output - including genuine errors - is still logged, and the
    # takeown invocation (ownership semantics) is unchanged.
    takeown /a /r /d Y /F $Directory 2>&1 |
        Where-Object { $_ -notmatch 'ERROR:\s*File or Directory not found\.' } |
        Write-Log -Console

    Write-Log 'Add ownership also for Administrators' -Console
    icacls $Directory /grant Administrators:F /t /C 2>&1 | Write-Log -Console

    Write-Log "Delete reparse points in the directory: $Directory" -Console
    Get-ChildItem -Path $Directory -Force -Recurse -Attributes Reparsepoint -ErrorAction SilentlyContinue | ForEach-Object { $n = $_.FullName.Trim('\'); fsutil reparsepoint delete "$n" 2>&1 | Write-Log -Console }

    Write-Log "Remove items from: $Directory" -Console
    Remove-Item -Path $Directory -Force -Recurse -ErrorAction SilentlyContinue

    Write-Log 'Cleanup finished' -Console

    $ErrorActionPreference = $errActionPreference
}

function Stop-ContainerdForStorageCleanup {
    # Safety net only: ensure the containerd runtime is not running before deletion. In practice the
    # service is usually already stopped/absent here, and stopping it does NOT resolve the
    # 'Access is denied' errors on the snapshot layers (that is an ACL/HCS-layer issue, handled by
    # Remove-WindowsSnapshotterLayers below - see its comment for the real root cause).
    $svc = Get-Service -Name 'containerd' -ErrorAction SilentlyContinue
    if ($null -ne $svc -and $svc.Status -ne 'Stopped') {
        Write-Log "[ResetWinStorage] Stopping 'containerd' service before cleanup" -Console
        Stop-Service -Name 'containerd' -Force -ErrorAction SilentlyContinue
    }

    Get-Process -Name 'containerd-shim-runhcs-v1' -ErrorAction SilentlyContinue |
        Where-Object { $null -ne $_ } |
        ForEach-Object {
            Write-Log "[ResetWinStorage] Stopping lingering containerd shim process (PID $($_.Id))" -Console
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
}

function Invoke-ZapFolder([string]$Folder) {
    # zap.exe wraps hcsshim.DestroyLayer (the HCS/Host-Compute-Service API for removing a Windows
    # container image layer). DestroyLayer runs with backup/restore privileges and understands the
    # layer format, so it removes files that takeown/icacls/Remove-Item cannot. It requires the
    # 'vmcompute' service to be running (it is) and expects the path of a SINGLE layer folder.
    $zap = Join-Path (Get-KubeBinPath) 'zap.exe'
    if (-not (Test-Path $zap)) {
        Write-Log ("[ResetWinStorage] zap.exe not found at '$zap'. HCS layer cleanup (DestroyLayer) for " +
            "'$Folder' was SKIPPED. Generic filesystem cleanup will still continue, but Windows container " +
            'image layers may not be fully removable without zap.exe.') -Error
        return
    }
    & $zap -folder $Folder 2>&1 | Write-Log -Console
}

function Remove-WindowsSnapshotterLayers([string]$ContainerdDir) {
    # Root cause of the persistent 'Access is denied' (with containerd fully stopped): the
    # directories under root\io.containerd.snapshotter.v1.windows\snapshots\<N> are Windows CONTAINER
    # IMAGE LAYERS managed by the Host Compute Service (HCS). Their 'Files\...' contents are base
    # image files that keep the original NTFS ownership/ACLs (TrustedInstaller/SYSTEM) and contain
    # WCIFS reparse points/hardlinks. These cannot be reliably re-owned or deleted with
    # takeown/icacls/Remove-Item - icacls reports '<path>: Access is denied.' The supported removal
    # path (used by upstream containerd's Windows snapshotter) is the HCS DestroyLayer API, which
    # zap.exe wraps. It must be called PER LAYER folder, not on the containerd root.
    $snapshotsPath = Join-Path $ContainerdDir 'root\io.containerd.snapshotter.v1.windows\snapshots'
    if (-not (Test-Path $snapshotsPath)) {
        return
    }

    Write-Log "[ResetWinStorage] Destroying Windows container image layers via HCS under: $snapshotsPath" -Console
    # Destroy most-derived layers first: the Windows snapshotter names each snapshot directory with its
    # integer storage ID (a monotonic counter), so a child layer always has a higher ID than its
    # parent. Sort NUMERICALLY descending - a lexicographic sort would order '138' before '4' and could
    # attempt to destroy a parent before its child. Any unexpected non-numeric name sorts last (-1).
    Get-ChildItem -Path $snapshotsPath -Directory -ErrorAction SilentlyContinue |
        Sort-Object -Property { if ($_.Name -match '^\d+$') { [long]$_.Name } else { -1 } } -Descending |
        ForEach-Object {
            Write-Log "[ResetWinStorage] Destroying container layer: $($_.FullName)" -Console
            Invoke-ZapFolder -Folder $_.FullName
        }
}

function Test-IsContainerdStorage([string]$ContainerdPath) {
    # Safety guard: refuse to run destructive cleanup unless the target really looks like a containerd
    # storage directory. This prevents accidental data loss if a wrong path (e.g. 'D:\Projects', 'D:\')
    # is passed via --containerd. The directory must contain 'root' and 'state', plus AT LEAST ONE
    # immediate child directory (under 'root' or 'state') named with containerd's stable plugin
    # namespace prefix 'io.containerd.'. Matching the prefix instead of a fixed list of plugin IDs keeps
    # the check version-independent: future plugins, snapshotters, metadata/content stores are all
    # named 'io.containerd.<type>.<version>.<name>', so they are accepted automatically, while arbitrary
    # user folders (which won't have root+state plus an 'io.containerd.*' child) are still rejected.
    if ([string]::IsNullOrWhiteSpace($ContainerdPath) -or -not (Test-Path $ContainerdPath)) {
        return $false
    }

    $rootPath = Join-Path $ContainerdPath 'root'
    $statePath = Join-Path $ContainerdPath 'state'
    if (-not (Test-Path $rootPath) -or -not (Test-Path $statePath)) {
        return $false
    }

    foreach ($basePath in @($rootPath, $statePath)) {
        $pluginDir = Get-ChildItem -Path $basePath -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name.StartsWith('io.containerd.', [System.StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -First 1
        if ($null -ne $pluginDir) {
            return $true
        }
    }

    return $false
}

function Invoke-CleanupOfContainerStorage([string]$Directory, [int]$MaxRetries, [bool]$ForceZap) {
    $successfulDirectoryCleanup = $false
    for ($i = 0; $i -lt $MaxRetries; $i++) {
        Invoke-GracefulCleanup -Directory $Directory
        if (Test-Path $Directory) {
            Write-Log "Directory $Directory could not be successfully deleted. Will retry again..." -Console
        }
        else {
            Write-Log "Directory $Directory cleaned up successfully." -Console
            $successfulDirectoryCleanup = $true
            break
        }
    }
    if (!$successfulDirectoryCleanup) {
        if ($ForceZap) {
            Write-Log 'Directory could not be cleaned up after exhausting all retries. Will zap it using zap.exe' -Console
            Invoke-ZapFolder -Folder $Directory
            if (Test-Path $Directory) {
                Write-Log "Directory $Directory could not be successfully deleted. Please try again." -Error
            }
            else {
                Write-Log "Directory $Directory cleaned up successfully." -Console
            }
        }
        else {
            Write-Log "Directory $Directory could not be successfully deleted. Please try again." -Error
        }
    }
}

$setupInfo = Get-SetupInfo

if ($setupInfo.LinuxOnly) {
    $errMsg = 'Resetting WinContainerStorage for Linux-only setup is not supported.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($setupInfo.Name -eq 'k2s') {
    $clusterState = Get-RunningState -SetupName $setupInfo.Name

    if ($clusterState.IsRunning -eq $true) {
        $errMsg = 'K2s is still running. Please stop K2s before performing this operation. Please ensure that no workloads are running in K2s.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeSystemRunning) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
}

$dockerRunningStatus = Get-DockerStatus
if ($dockerRunningStatus) {
    $errMsg = 'Docker daemon is running. Please stop Docker daemon before performing this operation.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'docker-running' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if (!$Force) {
    $answer = Read-Host "WARNING: Deletion of containerd/docker directory may take a very long time depending on the size of the folder and number of retries.`nContinue? (y/N)"
    if ($answer -ne 'y') {
        $msg = 'Resetting Windows container storage cancelled.'

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeUserCancellation) -Message $msg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $msg -Console
        exit 0
    }
}

if ([string]::IsNullOrWhiteSpace($Containerd)) {
    try {
        $storageDrive = Get-StorageLocalDrive          # e.g. 'D:'
        $storageFolder = Get-StorageLocalFolderName    # e.g. '\Somaris\appdata' (or '\')
        # %BEST-DRIVE% = <drive><folder>; containerd root/state live under <drive><folder>\containerd (see config.toml.template).
        $Containerd = Join-Path "$storageDrive$storageFolder" 'containerd'
        # NOTE: the underlying value is kept as-is (Windows collapses repeated separators when
        # accessing the path). Only the displayed log is normalized to a human-readable form,
        # collapsing any doubled backslashes (introduced by Get-StorageLocalFolderName) for display.
        $displayPath = $Containerd -replace '\\{2,}', '\'
        Write-Log "[ResetWinStorage] Using configured containerd storage path: $displayPath" -Console
    }
    catch {
        $Containerd = 'C:\containerd'
        Write-Log "[ResetWinStorage] Could not determine configured containerd path, falling back to '$Containerd'. $_" -Console
    }
}

$cleanUpWasPerformed = $false
if (Test-Path $Containerd) {
    # Safety validation: before ANY destructive action (DestroyLayer / takeown / icacls / delete),
    # verify the target actually resembles a containerd storage directory. Applies to both the
    # configured path and an explicit --containerd value.
    if (-not (Test-IsContainerdStorage -ContainerdPath $Containerd)) {
        $errMsg = @"
The specified path does not appear to be a valid containerd storage directory.

Path:
$Containerd

Expected layout:

  root\
  state\

with standard containerd runtime directories.

Aborting cleanup - no ownership changes or deletions were performed.
"@
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'invalid-containerd-storage' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    # Safety net: make sure the runtime is not running (usually already stopped here).
    Stop-ContainerdForStorageCleanup
    # Real fix for 'Access is denied' on snapshot layers: remove each Windows container image layer
    # via the HCS DestroyLayer API (zap.exe) before the generic file-system cleanup. takeown/icacls/
    # Remove-Item cannot reset the base-image ACLs/reparse points on these layers.
    Remove-WindowsSnapshotterLayers -ContainerdDir $Containerd
    Write-Log "Performing cleanup of $Containerd" -Console
    Invoke-CleanupOfContainerStorage -Directory $Containerd -MaxRetries $MaxRetries -ForceZap $ForceZap
    $cleanUpWasPerformed = $true
}

if (Test-Path $Docker) {
    Write-Log "Performing cleanup of $Docker" -Console
    Invoke-CleanupOfContainerStorage -Directory $Docker -MaxRetries $MaxRetries -ForceZap $ForceZap
    $cleanUpWasPerformed = $true
}

if ($cleanUpWasPerformed) {
    Write-Log 'Done. Windows node container storage is reset.' -Console
}
else {
    Write-Log 'Done. Nothing to reset.' -Console
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
