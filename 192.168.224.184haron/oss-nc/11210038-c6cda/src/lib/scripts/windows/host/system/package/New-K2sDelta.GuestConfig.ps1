# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Guest configuration file diff helpers for delta packaging
# Tracks changes to config files, systemd units, and custom binaries in Linux Kubemaster VM

# Path patterns for cluster-specific guest VM files that should NEVER be overwritten during updates.
# These files are generated during kubeadm init and contain cluster-specific certificates, keys, and configuration.
# Overwriting them would break the running cluster.
# Format: Linux paths with forward slashes, supports wildcard (*) matching.
$script:GuestConfigSkippedPaths = @(
    # Kubernetes PKI - contains all cluster certificates and keys (CA, API server, etcd, etc.)
    '/etc/kubernetes/pki/*',
    # Kubeconfig files - contain cluster-specific certificates and API server endpoints
    '/etc/kubernetes/admin.conf',
    '/etc/kubernetes/kubelet.conf',
    '/etc/kubernetes/controller-manager.conf',
    '/etc/kubernetes/scheduler.conf',
    # Static pod manifests - contain cluster-specific IPs and settings
    '/etc/kubernetes/manifests/*',
    # Kubelet PKI and configuration
    '/var/lib/kubelet/pki/*',
    '/var/lib/kubelet/config.yaml',
    # CNI network configuration - may contain cluster-specific settings
    '/etc/cni/net.d/*'
)

<#
.SYNOPSIS
    Tests if a guest VM file path matches any cluster config skip pattern.

.DESCRIPTION
    Checks if the given path should be excluded from guest config diff because
    it contains cluster-specific certificates, keys, or configuration.

.PARAMETER Path
    The file path to check (Linux format with forward slashes).

.OUTPUTS
    $true if the path matches a skip pattern, $false otherwise.
#>
function Test-GuestConfigSkippedPath {
    param(
        [string] $Path
    )

    if (-not $script:GuestConfigSkippedPaths -or $script:GuestConfigSkippedPaths.Count -eq 0) {
        return $false
    }

    foreach ($pattern in $script:GuestConfigSkippedPaths) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }

        # Use -like for wildcard matching
        if ($Path -like $pattern) {
            return $true
        }
    }

    return $false
}

<#
.SYNOPSIS
    Gets file hashes from specific directories in a running guest VM via SSH.

.DESCRIPTION
    Connects to the guest VM and runs find + sha256sum to enumerate files in the
    specified configuration directories. Returns a hashtable mapping relative paths
    to their SHA256 hashes.

.PARAMETER VmContext
    PSCustomObject with VM connection context (GuestIp, VmName, SwitchName, etc.).
    If provided, assumes VM is already running and reuses the connection.

.PARAMETER NewExtract
    Path to the new package extraction directory (used to locate SSH client).

.PARAMETER OldExtract
    Path to the old package extraction directory (used to locate SSH client).

.PARAMETER ConfigPaths
    Array of paths to scan in the guest VM. Defaults to common config directories.

.OUTPUTS
    PSCustomObject with Hashes hashtable, Error string, and ScannedPaths array.
#>
function Get-GuestFileHashes {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $VmContext,

        [Parameter(Mandatory = $true)]
        [string] $NewExtract,

        [Parameter(Mandatory = $true)]
        [string] $OldExtract,

        [Parameter(Mandatory = $false)]
        [string[]] $ConfigPaths = @(
            '/etc/kubernetes',
            '/etc/cni',
            '/etc/containerd',
            '/etc/sysctl.d',
            '/etc/netplan',
            '/lib/systemd/system',
            '/usr/local/bin'
        )
    )

    $result = [pscustomobject]@{
        Hashes       = @{}
        Error        = $null
        ScannedPaths = $ConfigPaths
        FileCount    = 0
    }

    try {
        $guestIp = $VmContext.GuestIp
        $sshUser = 'remote'
        $sshPwd = 'admin'

        # Get SSH client
        $sshInfo = Get-K2sHvSshClient -NewExtract $NewExtract -OldExtract $OldExtract
        $sshClient = $sshInfo.Path
        $usingPlink = $sshInfo.UsingPlink
        $plinkHostKey = $null

        if ($usingPlink) {
            $plinkHostKey = Get-K2sPlinkHostKey -SshClient $sshClient -SshUser $sshUser -GuestIp $guestIp
        }

        # Build SSH args
        if ($usingPlink) {
            $sshArgs = @('-batch', '-noagent', '-P', '22')
            if ($plinkHostKey) { $sshArgs += @('-hostkey', $plinkHostKey) }
            $sshArgs += @('-pw', $sshPwd)
            $sshArgs += ("$sshUser@$guestIp")
        } else {
            $sshArgs = @('-p', '22', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null')
            $sshArgs += ("$sshUser@$guestIp")
        }

        # Build find command for all config paths
        # Use find to enumerate files, then sha256sum each one
        # Filter only existing directories to avoid errors
        $pathList = $ConfigPaths -join ' '
        # Use single-quoted here-string for shell script, then replace placeholder
        $findScript = 'for p in __PATHS__; do if [ -d "$p" ]; then find "$p" -type f -exec sha256sum {} \; 2>/dev/null; fi; done'
        $findScript = $findScript -replace '__PATHS__', $pathList
        $findCmd = "sudo sh -c '$findScript'"

        Write-Log "[GuestConfig] Scanning config files in guest VM at $guestIp" -Console
        Write-Log "[GuestConfig] Paths: $($ConfigPaths -join ', ')" -Console

        $hashOutput = & $sshClient @($sshArgs + $findCmd) 2>&1

        if ($LASTEXITCODE -ne 0) {
            # Non-zero exit might just mean some paths didn't exist, check if we got output
            $errorLines = $hashOutput | Where-Object { $_ -match 'error|Error|ERROR|Permission denied' }
            if ($errorLines) {
                Write-Log "[GuestConfig][Warning] Some scan errors: $($errorLines | Select-Object -First 3 | Join-String -Separator ' | ')" -Console
            }
        }

        # Parse sha256sum output: "hash  /path/to/file"
        $hashes = @{}
        foreach ($line in $hashOutput) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            # sha256sum format: "64-char-hash  /path/to/file" (two spaces between hash and path)
            if ($line -match '^([a-f0-9]{64})\s+(.+)$') {
                $hash = $matches[1]
                $filePath = $matches[2].Trim()
                $hashes[$filePath] = $hash
            }
        }

        $result.Hashes = $hashes
        $result.FileCount = $hashes.Count
        Write-Log "[GuestConfig] Scanned $($hashes.Count) config files from guest VM" -Console

    } catch {
        $result.Error = "Failed to scan guest config files: $($_.Exception.Message)"
        Write-Log "[GuestConfig][Error] $($result.Error)" -Console
    }

    return $result
}

<#
.SYNOPSIS
    Copies config files from guest VM to local staging directory.

.DESCRIPTION
    Copies the specified files from the guest VM to the local staging directory,
    preserving the directory structure (e.g., /etc/kubernetes/admin.conf ->
    guest-config/etc/kubernetes/admin.conf).

.PARAMETER VmContext
    PSCustomObject with VM connection context.

.PARAMETER NewExtract
    Path to the new package extraction directory.

.PARAMETER OldExtract
    Path to the old package extraction directory.

.PARAMETER FilePaths
    Array of absolute paths in the guest VM to copy.

.PARAMETER OutputDir
    Local directory to copy files to (guest-config/ will be the root).

.OUTPUTS
    PSCustomObject with CopiedFiles array, FailedFiles array, and Error string.
#>
function Copy-GuestConfigFiles {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $VmContext,

        [Parameter(Mandatory = $true)]
        [string] $NewExtract,

        [Parameter(Mandatory = $true)]
        [string] $OldExtract,

        [Parameter(Mandatory = $true)]
        [string[]] $FilePaths,

        [Parameter(Mandatory = $true)]
        [string] $OutputDir
    )

    $result = [pscustomobject]@{
        CopiedFiles  = @()
        FailedFiles  = @()
        Error        = $null
    }

    if ($FilePaths.Count -eq 0) {
        Write-Log "[GuestConfig] No files to copy" -Console
        return $result
    }

    try {
        $guestIp = $VmContext.GuestIp
        $sshUser = 'remote'
        $sshPwd = 'admin'

        # Locate pscp/scp
        $pscpCandidates = @(
            (Join-Path $NewExtract 'bin\pscp.exe'),
            (Join-Path $OldExtract 'bin\pscp.exe'),
            'pscp.exe'
        )
        $scpClient = $pscpCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        $usePlink = ($scpClient -and $scpClient.ToLower().EndsWith('pscp.exe'))

        if (-not $scpClient) {
            # Fallback to regular scp
            $scpClient = 'scp.exe'
            $usePlink = $false
        }

        # Get plink host key if using pscp
        $plinkHostKey = $null
        if ($usePlink) {
            $plinkPath = $scpClient -replace 'pscp\.exe$', 'plink.exe'
            if (Test-Path -LiteralPath $plinkPath) {
                $plinkHostKey = Get-K2sPlinkHostKey -SshClient $plinkPath -SshUser $sshUser -GuestIp $guestIp
            }
        }

        # Ensure output directory exists
        $guestConfigDir = Join-Path $OutputDir 'guest-config'
        if (-not (Test-Path -LiteralPath $guestConfigDir)) {
            New-Item -ItemType Directory -Path $guestConfigDir -Force | Out-Null
        }

        Write-Log "[GuestConfig] Copying $($FilePaths.Count) config files from guest VM" -Console

        foreach ($remotePath in $FilePaths) {
            try {
                # Build local path preserving directory structure
                # e.g., /etc/kubernetes/admin.conf -> guest-config/etc/kubernetes/admin.conf
                $relativePath = $remotePath.TrimStart('/')
                $localPath = Join-Path $guestConfigDir $relativePath
                $localDir = Split-Path $localPath -Parent

                if (-not (Test-Path -LiteralPath $localDir)) {
                    New-Item -ItemType Directory -Path $localDir -Force | Out-Null
                }

                # Build copy args
                if ($usePlink) {
                    $copyArgs = @('-batch', '-P', '22')
                    if ($plinkHostKey) { $copyArgs += @('-hostkey', $plinkHostKey) }
                    $copyArgs += @('-pw', $sshPwd)
                    $copyArgs += ("${sshUser}@${guestIp}:$remotePath")
                    $copyArgs += $localPath
                } else {
                    $copyArgs = @('-P', '22', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null')
                    $copyArgs += ("${sshUser}@${guestIp}:$remotePath")
                    $copyArgs += $localPath
                }

                $null = & $scpClient @copyArgs 2>&1

                if (Test-Path -LiteralPath $localPath) {
                    $result.CopiedFiles += $relativePath
                } else {
                    $result.FailedFiles += $remotePath
                    Write-Log "[GuestConfig][Warning] Failed to copy: $remotePath" -Console
                }
            } catch {
                $result.FailedFiles += $remotePath
                Write-Log "[GuestConfig][Warning] Error copying $remotePath`: $($_.Exception.Message)" -Console
            }
        }

        Write-Log "[GuestConfig] Copied $($result.CopiedFiles.Count) files, $($result.FailedFiles.Count) failed" -Console

    } catch {
        $result.Error = "Failed to copy guest config files: $($_.Exception.Message)"
        Write-Log "[GuestConfig][Error] $($result.Error)" -Console
    }

    return $result
}

<#
.SYNOPSIS
    Computes differences in guest configuration files between old and new VHDX images.

.DESCRIPTION
    Reuses existing VM contexts from Debian diff (or boots new VMs if contexts not provided),
    scans configuration directories for files, computes SHA256 hashes, and identifies
    added, changed, and removed configuration files. Changed and added files are
    extracted from the new VM to a local staging directory.

.PARAMETER OldVhdxPath
    Path to the old (base) Kubemaster VHDX file (used if OldVmContext is not provided).

.PARAMETER OldVmContext
    PSCustomObject with VM context for the old VHDX (already running, reused from Debian diff).
    If not provided, will boot a new VM from OldVhdxPath.

.PARAMETER NewVmContext
    PSCustomObject with VM context for the new VHDX (already running, reused from Debian diff).
    If not provided, will boot a new VM from NewVhdxPath.

.PARAMETER NewVhdxPath
    Path to the new Kubemaster VHDX file (used if NewVmContext is not provided).

.PARAMETER NewExtract
    Path to the new package extraction directory.

.PARAMETER OldExtract
    Path to the old package extraction directory.

.PARAMETER OutputDir
    Local staging directory where extracted config files will be placed.

.PARAMETER ConfigPaths
    Array of paths to scan in the guest VM. Defaults to common config directories.

.OUTPUTS
    PSCustomObject with Added, Changed, Removed arrays, CopiedFiles list, and Error.
#>
function Get-GuestConfigDiff {
    param(
        [Parameter(Mandatory = $false)]
        [string] $OldVhdxPath,

        [Parameter(Mandatory = $false)]
        [pscustomobject] $OldVmContext,

        [Parameter(Mandatory = $false)]
        [pscustomobject] $NewVmContext,

        [Parameter(Mandatory = $false)]
        [string] $NewVhdxPath,

        [Parameter(Mandatory = $true)]
        [string] $NewExtract,

        [Parameter(Mandatory = $true)]
        [string] $OldExtract,

        [Parameter(Mandatory = $true)]
        [string] $OutputDir,

        [Parameter(Mandatory = $false)]
        [string[]] $ConfigPaths = @(
            '/etc/kubernetes',
            '/etc/cni',
            '/etc/containerd',
            '/etc/sysctl.d',
            '/etc/netplan',
            '/lib/systemd/system',
            '/usr/local/bin'
        )
    )

    $result = [pscustomobject]@{
        Processed      = $false
        Error          = $null
        Added          = @()
        Changed        = @()
        Removed        = @()
        AddedCount     = 0
        ChangedCount   = 0
        RemovedCount   = 0
        CopiedFiles    = @()
        FailedFiles    = @()
        ScannedPaths   = $ConfigPaths
    }

    $bootedOldVm = $false
    $bootedNewVm = $false

    try {
        Write-Log "[GuestConfig] Starting guest config diff" -Console

        # Validate inputs
        if (-not $OldVmContext -and -not $OldVhdxPath) {
            throw "Either OldVmContext or OldVhdxPath must be provided"
        }
        if ($OldVhdxPath -and -not (Test-Path -LiteralPath $OldVhdxPath)) {
            throw "Old VHDX not found: $OldVhdxPath"
        }

        if (-not $NewVmContext -and -not $NewVhdxPath) {
            throw "Either NewVmContext or NewVhdxPath must be provided"
        }

        # --- Scan OLD VHDX (reuse VM context if provided, otherwise boot new) ---
        $oldVmContextToUse = $OldVmContext

        if ($oldVmContextToUse) {
            Write-Log "[GuestConfig] Reusing existing old VM context: $($oldVmContextToUse.VmName)" -Console
        } else {
            Write-Log "[GuestConfig] Booting temporary VM for old VHDX scan..." -Console

            $switchNameEnding = 'cfg-old'
            $hostSwitchIp = '172.19.4.1'
            $networkPrefix = '172.19.4.0'
            $guestIp = '172.19.4.100'
            $prefixLen = 24
            $switchName = "k2s-switch-$switchNameEnding"
            $natName = "k2s-nat-$switchNameEnding"
            $vmName = "k2s-kubemaster-$switchNameEnding"

            $oldVmContextToUse = [pscustomobject]@{
                SwitchName   = $switchName
                NatName      = $natName
                HostSwitchIp = $hostSwitchIp
                NetworkPrefix = $networkPrefix
                PrefixLen    = $prefixLen
                GuestIp      = $guestIp
                VmName       = $vmName
                CreatedVm    = $false
            }

            # Create network
            $netCtx = New-K2sHvNetwork -SwitchName $switchName -NatName $natName -HostSwitchIp $hostSwitchIp -NetworkPrefix $networkPrefix -PrefixLen $prefixLen
            if ($netCtx.SwitchName -ne $switchName) {
                $switchName = $netCtx.SwitchName
                $oldVmContextToUse.SwitchName = $switchName
            }

            # Create and start VM
            New-K2sHvTempVm -VmName $vmName -VhdxPath $OldVhdxPath -SwitchName $switchName
            $oldVmContextToUse.CreatedVm = $true
            $bootedOldVm = $true

            # Wait for guest IP
            if (-not (Wait-K2sHvGuestIp -Ip $guestIp -TimeoutSeconds 180)) {
                throw "Old VM guest IP $guestIp not reachable within timeout"
            }

            # Wait for SSH to be ready
            Write-Log "[GuestConfig] Waiting for SSH to be ready on old VM..." -Console
            Start-Sleep -Seconds 60
        }

        # Scan old VM for config file hashes
        $oldHashes = Get-GuestFileHashes -VmContext $oldVmContextToUse -NewExtract $NewExtract -OldExtract $OldExtract -ConfigPaths $ConfigPaths

        if ($oldHashes.Error) {
            throw "Failed to scan old VM: $($oldHashes.Error)"
        }

        Write-Log "[GuestConfig] Old VM scan complete: $($oldHashes.FileCount) files" -Console

        # Note: VM cleanup is handled by the caller (New-K2sDeltaPackage.ps1)

        # --- Scan NEW VHDX (reuse existing VM context if available) ---
        $newVmContextToUse = $NewVmContext

        if (-not $newVmContextToUse) {
            Write-Log "[GuestConfig] Booting temporary VM for new VHDX scan..." -Console

            if (-not (Test-Path -LiteralPath $NewVhdxPath)) {
                throw "New VHDX not found: $NewVhdxPath"
            }

            $switchNameEnding = 'cfg-new'
            $hostSwitchIp = '172.19.5.1'
            $networkPrefix = '172.19.5.0'
            $guestIp = '172.19.5.100'
            $prefixLen = 24
            $switchName = "k2s-switch-$switchNameEnding"
            $natName = "k2s-nat-$switchNameEnding"
            $vmName = "k2s-kubemaster-$switchNameEnding"

            $newVmContextToUse = [pscustomobject]@{
                SwitchName   = $switchName
                NatName      = $natName
                HostSwitchIp = $hostSwitchIp
                NetworkPrefix = $networkPrefix
                PrefixLen    = $prefixLen
                GuestIp      = $guestIp
                VmName       = $vmName
                CreatedVm    = $false
            }

            $netCtx = New-K2sHvNetwork -SwitchName $switchName -NatName $natName -HostSwitchIp $hostSwitchIp -NetworkPrefix $networkPrefix -PrefixLen $prefixLen
            if ($netCtx.SwitchName -ne $switchName) {
                $switchName = $netCtx.SwitchName
                $newVmContextToUse.SwitchName = $switchName
            }

            New-K2sHvTempVm -VmName $vmName -VhdxPath $NewVhdxPath -SwitchName $switchName
            $newVmContextToUse.CreatedVm = $true
            $bootedNewVm = $true

            if (-not (Wait-K2sHvGuestIp -Ip $guestIp -TimeoutSeconds 180)) {
                throw "New VM guest IP $guestIp not reachable within timeout"
            }

            Write-Log "[GuestConfig] Waiting for SSH to be ready on new VM..." -Console
            Start-Sleep -Seconds 60
        } else {
            Write-Log "[GuestConfig] Reusing existing new VM context: $($newVmContextToUse.VmName)" -Console
        }

        # Scan new VM for config file hashes
        $newHashes = Get-GuestFileHashes -VmContext $newVmContextToUse -NewExtract $NewExtract -OldExtract $OldExtract -ConfigPaths $ConfigPaths

        if ($newHashes.Error) {
            throw "Failed to scan new VM: $($newHashes.Error)"
        }

        Write-Log "[GuestConfig] New VM scan complete: $($newHashes.FileCount) files" -Console

        # --- Compute differences (excluding cluster-specific config files) ---
        $added = @()
        $changed = @()
        $removed = @()
        $skippedCount = 0

        $oldHashMap = $oldHashes.Hashes
        $newHashMap = $newHashes.Hashes

        # Find added and changed files (excluding cluster-specific paths)
        foreach ($path in $newHashMap.Keys) {
            # Skip cluster-specific files that should never be overwritten
            if (Test-GuestConfigSkippedPath -Path $path) {
                $skippedCount++
                continue
            }

            if (-not $oldHashMap.ContainsKey($path)) {
                $added += $path
            } elseif ($oldHashMap[$path] -ne $newHashMap[$path]) {
                $changed += $path
            }
        }

        # Find removed files (excluding cluster-specific paths)
        foreach ($path in $oldHashMap.Keys) {
            # Skip cluster-specific files
            if (Test-GuestConfigSkippedPath -Path $path) {
                continue
            }

            if (-not $newHashMap.ContainsKey($path)) {
                $removed += $path
            }
        }

        if ($skippedCount -gt 0) {
            Write-Log "[GuestConfig] Skipped $skippedCount cluster-specific files (PKI, kubeconfig, manifests, CNI)" -Console
        }

        Write-Log "[GuestConfig] Diff complete: Added=$($added.Count), Changed=$($changed.Count), Removed=$($removed.Count)" -Console

        # --- Copy changed and added files from new VM ---
        $filesToCopy = @($added) + @($changed)

        if ($filesToCopy.Count -gt 0) {
            $copyResult = Copy-GuestConfigFiles -VmContext $newVmContextToUse -NewExtract $NewExtract -OldExtract $OldExtract -FilePaths $filesToCopy -OutputDir $OutputDir

            $result.CopiedFiles = $copyResult.CopiedFiles
            $result.FailedFiles = $copyResult.FailedFiles

            if ($copyResult.Error) {
                Write-Log "[GuestConfig][Warning] Copy error: $($copyResult.Error)" -Console
            }
        }

        # Note: VM cleanup is handled by the caller (New-K2sDeltaPackage.ps1)
        # Only clean up VMs we booted ourselves (fallback mode)
        if ($bootedNewVm -and $newVmContextToUse) {
            Remove-K2sHvEnvironment -Context $newVmContextToUse
        }
        if ($bootedOldVm -and $oldVmContextToUse) {
            Remove-K2sHvEnvironment -Context $oldVmContextToUse
        }

        # Set results
        $result.Processed = $true
        $result.Added = $added
        $result.Changed = $changed
        $result.Removed = $removed
        $result.AddedCount = $added.Count
        $result.ChangedCount = $changed.Count
        $result.RemovedCount = $removed.Count

        Write-Log "[GuestConfig] Guest config diff complete" -Console

    } catch {
        $result.Error = $_.Exception.Message
        Write-Log "[GuestConfig][Error] $($result.Error)" -Console

        # Clean up VMs we booted ourselves on error (fallback mode only)
        if ($bootedOldVm -and $oldVmContextToUse) {
            try { Remove-K2sHvEnvironment -Context $oldVmContextToUse } catch { }
        }
        if ($bootedNewVm -and $newVmContextToUse) {
            try { Remove-K2sHvEnvironment -Context $newVmContextToUse } catch { }
        }
    }

    return $result
}
