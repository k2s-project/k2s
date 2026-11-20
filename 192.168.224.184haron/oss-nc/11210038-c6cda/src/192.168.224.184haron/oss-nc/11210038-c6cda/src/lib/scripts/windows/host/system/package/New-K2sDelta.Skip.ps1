# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Skip list & staging cleanup helpers

function Test-SpecialSkippedFile {
    param(
        [string] $Path,
        [string[]] $List
    )
    $leaf = [IO.Path]::GetFileName($Path)

    # Check explicit skip list
    foreach ($f in $List) {
        if ($leaf -ieq $f) { return $true }
    }

    # Skip entire addons directory - addons are not handled by delta upgrades.
    # Users manage addons separately via 'k2s addons enable/disable' commands.
    # Including addon files in delta could cause inconsistencies since addon
    # enable/disable scripts don't run during delta upgrades.
    if ($Path -match '^addons/') {
        return $true
    }

    return $false
}

<#
.SYNOPSIS
    Tests if a file path matches any of the cluster config skip patterns.

.DESCRIPTION
    Checks if the given relative path matches any of the patterns in the cluster config
    skip list. These patterns protect cluster-specific files (certificates, kubeconfig,
    kubelet config) from being overwritten during delta updates.

.PARAMETER Path
    The relative file path to check (forward slashes, no leading slash).

.PARAMETER Patterns
    Array of path patterns to match against. Supports wildcards (*).

.OUTPUTS
    $true if the path matches a pattern and should be skipped, $false otherwise.
#>
function Test-ClusterConfigSkippedPath {
    param(
        [string] $Path,
        [string[]] $Patterns
    )

    if (-not $Patterns -or $Patterns.Count -eq 0) { return $false }

    # Normalize path to forward slashes
    $normalizedPath = $Path -replace '\\', '/'
    $normalizedPath = $normalizedPath -replace '^/', ''  # Remove leading slash if present

    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }

        # Normalize pattern
        $normalizedPattern = $pattern -replace '\\', '/'
        $normalizedPattern = $normalizedPattern -replace '^/', ''

        # Use -like for wildcard matching
        if ($normalizedPath -like $normalizedPattern) {
            Write-Log "[SkipList] Excluding cluster config file from diff: $Path (matches pattern: $pattern)" -Console
            return $true
        }
    }

    return $false
}

function Test-InWholeDir {
    param(
        [string] $Path,
        [string[]] $Dirs
    )
    foreach ($d in $Dirs) {
        if ($Path.StartsWith($d + '/')) { return $true }
    }
    return $false
}

function Remove-SpecialSkippedFilesFromStage {
    param(
        [Parameter(Mandatory = $true)] [string]  $StagePath,
        [Parameter(Mandatory = $true)] [string[]] $Skipped
    )
    Write-Log "[StageCleanup] Starting removal of special skipped files from '$StagePath' (Patterns: $([string]::Join(', ', $Skipped)))" -Console
    $totalRemoved = 0
    foreach ($sf in $Skipped) {
        $foundFiles = Get-ChildItem -Path $StagePath -Recurse -File -Filter $sf -ErrorAction SilentlyContinue
        if ($foundFiles) {
            Write-Log "[StageCleanup] Found $($foundFiles.Count) candidate(s) for pattern '$sf'" -Console
        }
        foreach ($m in $foundFiles) {
            try {
                Remove-Item -LiteralPath $m.FullName -Force -ErrorAction Stop
                Write-Log "Removed special skipped file from stage: $($m.FullName)" -Console
                $totalRemoved++
            }
            catch {
                Write-Log "[Warning] Failed to remove special skipped file '$($m.FullName)': $($_.Exception.Message)" -Console
            }
        }
    }
    Write-Log "[StageCleanup] Completed special skip removal. Total removed: $totalRemoved" -Console
}

<#
.SYNOPSIS
    Returns the default skip lists for delta package creation.

.DESCRIPTION
    Returns two arrays: SpecialSkippedFiles (large binaries and cluster config files)
    and ClusterConfigSkippedPaths (path patterns for cluster-specific files).
    These lists define what files should be excluded from file-level diffing.

.OUTPUTS
    PSCustomObject with properties:
    - SpecialSkippedFiles: Array of filenames to skip
    - ClusterConfigSkippedPaths: Array of path patterns to skip
#>
function Get-DefaultSkipLists {
    param()

    # Internal list of special files that should be excluded from diff/staging and handled separately if needed.
    # NOTE: Large binary artifacts are excluded because they are handled by separate delta logic (VHDX, images, etc.)
    # NOTE: Cluster-specific config files are excluded because overwriting them would break a running cluster.
    #       These files are generated during kubeadm init with cluster-specific certificates and IPs.
    $specialSkippedFiles = @(
        # Large binary artifacts (handled separately)
        'Kubemaster-Base.vhdx',
        'trivy.exe',
        'virtctl.exe',
        'virt-viewer-x64-11.0-1.0.msi',
        'k2s-bom.json',
        'k2s-bom.xml',
        'Kubemaster-Base.rootfs.tar.gz',
        'WindowsNodeArtifacts.zip',
        # Cluster-specific configuration (must be preserved to keep cluster running)
        'config'  # Main kubeconfig file at $kubePath\config - contains cluster certs and API endpoint
    )

    # Path patterns for cluster-specific files that should never be overwritten during updates.
    # These patterns match against the full relative path, not just the filename.
    # Format: Use forward slashes, no leading slash, matches via -like operator with wildcards.
    $clusterConfigSkippedPaths = @(
        # Windows kubelet configuration and PKI
        'etc/kubernetes/bootstrap-kubelet.conf',
        'etc/kubernetes/pki/*',
        'var/lib/kubelet/config.yaml',
        'var/lib/kubelet/pki/*'
    )

    # Default wholesale directories that should always be included in their entirety.
    # These directories contain version-specific binaries that must be replaced as a unit.
    #
    # NOTE: In K2s offline packages, Windows binaries are stored inside WindowsNodeArtifacts.zip,
    #       not as separate directories. The Copy-WindowsNodeArtifactsToStaging function extracts
    #       bin/kube and bin/docker from the ZIP during delta package creation.
    #       The directories listed here will be processed if they exist in the source package.
    #       If they don't exist (e.g., bin/docker, bin/kube in offline package), they are skipped
    #       with a warning, and the ZIP extraction provides the binaries instead.
    $defaultWholesaleDirectories = @(
        'bin/cni'           # CNI plugins (exists in offline package)
        # bin/kube and bin/docker are extracted from WindowsNodeArtifacts.zip by
        # Copy-WindowsNodeArtifactsToStaging in New-K2sDeltaPackage.ps1
    )

    return [pscustomobject]@{
        SpecialSkippedFiles       = $specialSkippedFiles
        ClusterConfigSkippedPaths = $clusterConfigSkippedPaths
        DefaultWholesaleDirectories = $defaultWholesaleDirectories
    }
}

<#
.SYNOPSIS
    Computes file diff between old and new file maps.

.DESCRIPTION
    Compares two file hash maps to determine added, changed, and removed files,
    while excluding files matching skip lists and wholesale directories.

.PARAMETER Context
    Hashtable containing:
    - OldMap: Hashtable of old package file hashes
    - NewMap: Hashtable of new package file hashes
    - WholeDirsNormalized: Array of wholesale directories to exclude
    - SpecialSkippedFiles: Array of filenames to skip
    - ClusterConfigSkippedPaths: Array of path patterns to skip

.OUTPUTS
    PSCustomObject with properties:
    - Added: Array of added file paths
    - Changed: Array of changed file paths
    - Removed: Array of removed file paths
#>
function Compare-FileMaps {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Context
    )

    $added = @()
    $removed = @()
    $changed = @()

    # Added & changed (exclude files beneath wholesale directories and cluster-specific config)
    foreach ($p in $Context.NewMap.Keys) {
        if (Test-InWholeDir -path $p -dirs $Context.WholeDirsNormalized) { continue }
        if (Test-SpecialSkippedFile -path $p -list $Context.SpecialSkippedFiles) { continue }
        if (Test-ClusterConfigSkippedPath -path $p -patterns $Context.ClusterConfigSkippedPaths) { continue }
        if (-not $Context.OldMap.ContainsKey($p)) { $added += $p; continue }
        if ($Context.OldMap[$p].Hash -ne $Context.NewMap[$p].Hash) { $changed += $p }
    }

    # Removed (exclude files beneath wholesale directories and cluster-specific config)
    foreach ($p in $Context.OldMap.Keys) {
        if (Test-InWholeDir -path $p -dirs $Context.WholeDirsNormalized) { continue }
        if (Test-SpecialSkippedFile -path $p -list $Context.SpecialSkippedFiles) { continue }
        if (Test-ClusterConfigSkippedPath -path $p -patterns $Context.ClusterConfigSkippedPaths) { continue }
        if (-not $Context.NewMap.ContainsKey($p)) { $removed += $p }
    }

    return [pscustomobject]@{
        Added   = $added
        Changed = $changed
        Removed = $removed
    }
}

<#
.SYNOPSIS
    Filters delta file list to exclude skip patterns.

.DESCRIPTION
    Takes combined added+changed list and filters out any files matching
    special skipped files or cluster config paths.

.PARAMETER FileList
    Array of file paths to filter.

.PARAMETER SpecialSkippedFiles
    Array of filenames to exclude.

.PARAMETER ClusterConfigSkippedPaths
    Array of path patterns to exclude.

.OUTPUTS
    Filtered array of file paths.
#>
function Get-FilteredDeltaFileList {
    param(
        [Parameter(Mandatory = $true)]
        [array] $FileList,

        [Parameter(Mandatory = $true)]
        [array] $SpecialSkippedFiles,

        [Parameter(Mandatory = $true)]
        [array] $ClusterConfigSkippedPaths
    )

    return $FileList | Where-Object {
        (-not (Test-SpecialSkippedFile -path $_ -list $SpecialSkippedFiles)) -and
        (-not (Test-ClusterConfigSkippedPath -path $_ -patterns $ClusterConfigSkippedPaths))
    }
}
