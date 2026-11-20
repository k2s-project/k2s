# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Upgrades a single worker node offline from a node package zip.

.DESCRIPTION
Performs an offline upgrade of a bare-metal worker node already joined to the K2s cluster.
The node package zip (created by 'k2s system package --node-package') must contain:
    packages/<distKey>/     - Distribution-specific packages, e.g. packages/debian12/, packages/debian13/
    images/                 - Container images exported as OCI-archive .tar files

Supported OS families
    debian  - Debian 12/13, Ubuntu (packages installed via dpkg + apt-get, images via buildah)
    windows - Not yet supported (reserved for future use)

The script:
    1. Validates that the zip file exists.
    2. Looks up the node in the cluster; reads its IP and OS type from Kubernetes.
    3. Extracts the zip to a temp directory.
    4. Detects the exact distribution (e.g. debian12) via SSH and validates a matching folder
         exists in the zip - throws an error if not found (no silent fallback).
    5. Cordons the node (stops new pods being scheduled) and drains it (evicts existing pods).
    6. OS-specific: copies and installs packages, imports container images, restarts the service.
    7. Uncordons the node (re-enables scheduling).
    8. Waits for the node to report Ready.

.PARAMETER NodeName
Name of the worker node to upgrade (must match the hostname as registered in the cluster).

.PARAMETER NodePackagePath
Absolute or relative path to the node package .zip file.

.PARAMETER UserName
SSH user on the worker node. If not provided, the value is read from cluster.json node details.

.PARAMETER ShowLogs
Stream log output to the console in addition to the log file.

.PARAMETER EncodeStructuredOutput
When set, results are sent back to the CLI as structured JSON messages.

.PARAMETER MessageType
Message type identifier used together with EncodeStructuredOutput.

.EXAMPLE
# Upgrade node 'worker1' using a pre-built node package
k2s system upgrade --node worker1 --path .\node-package-v1.1.zip
#>

Param(
    [Parameter(Mandatory = $true, HelpMessage = 'Name of the worker node to upgrade')]
    [string] $NodeName,
    [Parameter(Mandatory = $true, HelpMessage = 'Path to the node package zip')]
    [string] $NodePackagePath,
    [Parameter(Mandatory = $false, HelpMessage = 'SSH user on the worker node (defaults to cluster.json value for the node)')]
    [string] $UserName = '',
    [Parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [Parameter(Mandatory = $false, HelpMessage = 'Encode results as structured CLI output')]
    [switch] $EncodeStructuredOutput = $false,
    [Parameter(Mandatory = $false, HelpMessage = 'Message type for structured output')]
    [string] $MessageType = ''
)

$durationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$infraModule   = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule    = "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$clusterConfigModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\config\cluster.config.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule, $clusterConfigModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Stop'

$installationPath = Get-KubePath
Set-Location $installationPath

# ===========================================================================
# Helper: Install Debian/Ubuntu-family .deb packages on a remote node via SSH.
# ===========================================================================
function Install-DebianPackages {
    param(
        [string] $UserName,
        [string] $IpAddress,
        [string] $DebPackagesDir
    )

    $allDebs = Get-ChildItem -Path $DebPackagesDir -Filter '*.deb' -Recurse -File
    if ($allDebs.Count -eq 0) {
        Write-Log "[NodeUpgrade] No .deb files found under '$DebPackagesDir' - skipping package install." -Console
        return
    }

    Write-Log "[NodeUpgrade] Installing $($allDebs.Count) .deb package(s) on $IpAddress" -Console

    $remoteDir = '/tmp/k2s-node-upgrade-pkgs'
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "rm -rf $remoteDir; mkdir -p $remoteDir" `
        -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

    foreach ($deb in $allDebs) {
        Write-Log "[NodeUpgrade] Copying '$($deb.Name)'" -Console
        Copy-ToRemoteComputerViaSshKey -Source $deb.FullName -Target $remoteDir `
            -UserName $UserName -IpAddress $IpAddress
    }

    Write-Log '[NodeUpgrade] Running dpkg install' -Console
    (Invoke-CmdOnVmViaSSHKey `
        -CmdToExecute "sudo dpkg -i $remoteDir/*.deb 2>&1; sudo DEBIAN_FRONTEND=noninteractive apt-get install -f -y 2>&1" `
        -UserName $UserName -IpAddress $IpAddress).Output | Write-Log -Console

    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "rm -rf $remoteDir" `
        -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

    Write-Log '[NodeUpgrade] Debian package installation complete.' -Console
}

# ===========================================================================
# Helper: Purge removed Debian packages from a remote node.
# Called when a node delta package lists DebianPackageDiff.Removed entries.
# Package names are derived by stripping the version/arch suffix from .deb filenames.
# ===========================================================================
function Invoke-DebianPackagePurge {
    param(
        [string]   $UserName,
        [string]   $IpAddress,
        [string[]] $RemovedDebFilenames
    )

    if ($RemovedDebFilenames.Count -eq 0) { return }

    # Convert filenames like 'kubelet_1.35.2-1.1_amd64.deb' -> 'kubelet'
    $pkgNames = $RemovedDebFilenames | ForEach-Object {
        $leaf = [IO.Path]::GetFileNameWithoutExtension($_)
        # dpkg convention: <name>_<version>_<arch> — strip from first '_'
        if ($leaf -match '^([^_]+)_') { $matches[1] } else { $leaf }
    } | Sort-Object -Unique

    Write-Log "[NodeUpgrade] Purging $($pkgNames.Count) removed package(s): $($pkgNames -join ', ')" -Console
    $purgeCmd = "sudo dpkg --purge --force-depends $($pkgNames -join ' ') 2>&1"
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute $purgeCmd `
        -UserName $UserName -IpAddress $IpAddress).Output | Write-Log -Console
    Write-Log '[NodeUpgrade] Package purge complete.' -Console
}

# ===========================================================================
# Helper: Copy OCI-archive .tar images to a Linux node and load via buildah.
# ===========================================================================
function Import-OciImages {
    param(
        [string] $UserName,
        [string] $IpAddress,
        [string] $ImagesDir
    )

    $tars = Get-ChildItem -Path $ImagesDir -Filter '*.tar' -File
    if ($tars.Count -eq 0) {
        Write-Log "[NodeUpgrade] No .tar files found in '$ImagesDir' - skipping image import." -Console
        return
    }

    Write-Log "[NodeUpgrade] Loading $($tars.Count) container image(s) on $IpAddress" -Console

    $remoteDir = '/tmp/k2s-node-upgrade-images'
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "rm -rf $remoteDir; mkdir -p $remoteDir" `
        -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

    foreach ($tar in $tars) {
        $remotePath = "$remoteDir/$($tar.Name)"
        Write-Log "[NodeUpgrade] Copying image '$($tar.Name)'" -Console
        Copy-ToRemoteComputerViaSshKey -Source $tar.FullName -Target $remotePath `
            -UserName $UserName -IpAddress $IpAddress

        Write-Log "[NodeUpgrade] Loading '$($tar.Name)' via buildah" -Console
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo buildah pull oci-archive:$remotePath 2>&1" `
            -UserName $UserName -IpAddress $IpAddress -Retries 2 -Timeout 120).Output | Write-Log -Console
    }

    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "rm -rf $remoteDir" `
        -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

    Write-Log '[NodeUpgrade] Container image import complete.' -Console
}

$tempDir = $null
$deltaManifest = $null
$isDeltaUpgrade = $false

try {
    # ------------------------------------------------------------------
    # Phase 1 - Validate inputs
    # ------------------------------------------------------------------
    Write-Log "[NodeUpgrade] === Phase 1: Validating inputs ===" -Console

    $resolvedPackagePath = Resolve-Path -Path $NodePackagePath -ErrorAction SilentlyContinue
    if ($null -eq $resolvedPackagePath) {
        throw "[NodeUpgrade] Node package path '$NodePackagePath' does not exist."
    }
    $NodePackagePath = $resolvedPackagePath.Path

    if (-not $NodePackagePath.EndsWith('.zip')) {
        throw "[NodeUpgrade] Node package path '$NodePackagePath' must be a .zip file."
    }

    Write-Log "[NodeUpgrade] Node:    $NodeName" -Console
    Write-Log "[NodeUpgrade] Package: $NodePackagePath" -Console

    # ------------------------------------------------------------------
    # Phase 2 - Locate node in cluster and determine its OS type
    # ------------------------------------------------------------------
    Write-Log "[NodeUpgrade] === Phase 2: Locating node and determining OS ===" -Console

    $nodeResult = (Invoke-Kubectl -Params @('get', 'node', $NodeName, '--no-headers', '-o', 'name')).Output
    if ([string]::IsNullOrWhiteSpace($nodeResult)) {
        throw "[NodeUpgrade] Node '$NodeName' not found in cluster."
    }
    Write-Log "[NodeUpgrade] Node '$NodeName' found in cluster." -Console

    # Check if the node is Ready before proceeding with upgrade
    $nodeStatusOutput = (Invoke-Kubectl -Params @('get', 'node', $NodeName, '--no-headers')).Output | Out-String
    if ([string]::IsNullOrWhiteSpace($nodeStatusOutput) -or -not ($nodeStatusOutput -match '\s+Ready(?:\s|,|$)')) {
        throw "[NodeUpgrade] Node '$NodeName' is not in Ready state. Cannot proceed with upgrade."
    }
    Write-Log "[NodeUpgrade] Node '$NodeName' is in Ready state." -Console

    # Resolve SSH username from cluster descriptor if not provided explicitly.
    if ([string]::IsNullOrWhiteSpace($UserName)) {
        $nodeConfig = Get-NodeConfig -NodeName $NodeName
        if ($null -eq $nodeConfig) {
            throw "[NodeUpgrade] Node '$NodeName' not found in cluster.json. Provide -UserName or update cluster.json node details."
        }

        $resolvedUserName = "$($nodeConfig.Username)".Trim()
        if ([string]::IsNullOrWhiteSpace($resolvedUserName)) {
            throw "[NodeUpgrade] Username missing for node '$NodeName' in cluster.json. Provide -UserName or update cluster.json node details."
        }

        $UserName = $resolvedUserName
        Write-Log "[NodeUpgrade] Resolved SSH user from cluster.json: $UserName" -Console
    }
    else {
        Write-Log "[NodeUpgrade] Using SSH user from CLI parameter: $UserName" -Console
    }

    $nodeIp = (Invoke-Kubectl -Params @('get', 'node', $NodeName, '-o',
        "jsonpath={.status.addresses[?(@.type=='InternalIP')].address}")).Output.Trim()
    if ([string]::IsNullOrWhiteSpace($nodeIp)) {
        throw "[NodeUpgrade] Could not determine IP address of node '$NodeName'."
    }
    Write-Log "[NodeUpgrade] Node IP: $nodeIp" -Console

    # Query the OS type Kubernetes reports for the node ('linux' or 'windows')
    $nodeOs = (Invoke-Kubectl -Params @('get', 'node', $NodeName, '-o',
        'jsonpath={.status.nodeInfo.operatingSystem}')).Output.Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($nodeOs)) {
        $nodeOs = 'linux'   # safe default for bare-metal Linux workers
    }
    Write-Log "[NodeUpgrade] Node OS (from cluster): $nodeOs" -Console
    # ------------------------------------------------------------------
    # Phase 3 - Extract node package
    # ------------------------------------------------------------------
    Write-Log "[NodeUpgrade] === Phase 3: Extracting node package ===" -Console

    $tempDir = Join-Path $env:TEMP "k2s-node-upgrade-$(Get-Random)"
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    Write-Log "[NodeUpgrade] Extracting to '$tempDir'" -Console
    Expand-Archive -Path $NodePackagePath -DestinationPath $tempDir -Force

    $packagesDir = Join-Path $tempDir 'packages'
    if (-not (Test-Path $packagesDir)) {
        throw "[NodeUpgrade] No 'packages' directory found in node package zip."
    }

    # Read delta-manifest.json if present.
    # If present, this is a node delta package and we execute delta-specific behavior.
    # If absent, we treat the input as a full node package.
    $deltaManifestPath = Join-Path $tempDir 'delta-manifest.json'
    if (Test-Path $deltaManifestPath) {
        try {
            $deltaManifest = Get-Content -LiteralPath $deltaManifestPath -Raw | ConvertFrom-Json
            Write-Log "[NodeUpgrade] Delta manifest detected (DeltaType=$($deltaManifest.DeltaType), ManifestVersion=$($deltaManifest.ManifestVersion))" -Console

            # Guardrail: node upgrade only accepts node-package deltas.
            # Cluster deltas (or unknown delta types) must not flow through this path.
            if ([string]::IsNullOrWhiteSpace("$($deltaManifest.DeltaType)") -or $deltaManifest.DeltaType -ne 'node-package') {
                throw "[NodeUpgrade] Unsupported delta manifest type '$($deltaManifest.DeltaType)'. Expected DeltaType 'node-package'."
            }

            $isDeltaUpgrade = $true
            Write-Log '[NodeUpgrade] Upgrade mode: DELTA (node package delta detected)' -Console
        } catch {
            throw "[NodeUpgrade] Failed to load valid node delta manifest from '$deltaManifestPath': $($_.Exception.Message)"
        }
    } else {
        Write-Log '[NodeUpgrade] Upgrade mode: FULL (no delta-manifest.json found)' -Console
    }

    # ------------------------------------------------------------------
    # Phase 4 - Detect exact distribution and validate package folder
    # ------------------------------------------------------------------
    Write-Log "[NodeUpgrade] === Phase 4: Detecting OS distribution on node '$NodeName' ===" -Console

    $distKey  = ''
    $osFamily = ''

    switch ($nodeOs) {
        'linux' {
            # Reads lsb_release via SSH key - returns e.g. 'debian12', 'debian13', 'ubuntu22'
            $distKey = Get-InstalledDistribution -UserName $UserName -IpAddress $nodeIp
            Write-Log "[NodeUpgrade] Detected Linux distribution: $distKey" -Console

            # Map distribution key to a package-handler family
            if ($distKey -match '^(debian|ubuntu)\d') {
                $osFamily = 'debian'
            }
            else {
                throw "[NodeUpgrade] Unsupported Linux distribution '$distKey'. " +
                      'Only Debian/Ubuntu-based distributions are currently supported.'
            }
        }
        'windows' {
            $distKey  = 'windows'
            $osFamily = 'windows'
            Write-Log '[NodeUpgrade] Windows worker node detected.' -Console
        }
        default {
            throw "[NodeUpgrade] Unknown node OS '$nodeOs'."
        }
    }

    # Validate that the zip contains a folder exactly matching the detected OS key
    # (e.g. 'debian12', 'debian13', 'windows').  No fallback - fail fast with a clear message.
    $distPackagesDir = Join-Path $packagesDir $distKey
    if (-not (Test-Path $distPackagesDir)) {
        $available = (Get-ChildItem -Path $packagesDir -Directory -ErrorAction SilentlyContinue).Name -join ', '
        throw "[NodeUpgrade] Package folder '$distKey' not found in zip (available: $available). " +
              "Build a matching node package with 'k2s system package --node-package'."
    }
    Write-Log "[NodeUpgrade] Package folder located: $distPackagesDir" -Console

    # ------------------------------------------------------------------
    # Phase 5 - Cordon and drain the node
    # ------------------------------------------------------------------
    Write-Log "[NodeUpgrade] === Phase 5: Cordoning and draining node '$NodeName' ===" -Console

    (Invoke-Kubectl -Params @('cordon', $NodeName)).Output | Write-Log -Console
    (Invoke-Kubectl -Params @('drain', $NodeName,
        '--ignore-daemonsets',
        '--delete-emptydir-data',
        '--force',
        '--timeout=120s')).Output | Write-Log -Console

    # ------------------------------------------------------------------
    # Phase 6 - OS-specific: install packages, load images, restart service
    # ------------------------------------------------------------------
    Write-Log "[NodeUpgrade] === Phase 6: Applying upgrade for OS family '$osFamily' ===" -Console

    $imagesDir = Join-Path $tempDir 'images'

    switch ($osFamily) {
        'debian' {
            # --- Purge removed packages (delta packages only) ---
            if ($isDeltaUpgrade) {
                $removedDebs = @($deltaManifest.DebianPackageDiff.Removed | Where-Object { $_ })
                if ($removedDebs.Count -gt 0) {
                    Write-Log '[NodeUpgrade] [debian] Purging removed packages from delta manifest' -Console
                    Invoke-DebianPackagePurge -UserName $UserName -IpAddress $nodeIp -RemovedDebFilenames $removedDebs
                }
            }

            # --- Packages ---
            Write-Log '[NodeUpgrade] [debian] Installing packages' -Console
            Install-DebianPackages -UserName $UserName -IpAddress $nodeIp -DebPackagesDir $distPackagesDir

            # --- Container images ---
            Write-Log '[NodeUpgrade] [debian] Importing container images' -Console
            if (Test-Path $imagesDir) {
                Import-OciImages -UserName $UserName -IpAddress $nodeIp -ImagesDir $imagesDir
            }
            else {
                Write-Log "[NodeUpgrade] [debian] No 'images' directory in package - skipping image import." -Console
            }

            # --- Restart kubelet so upgraded binaries take effect ---
            Write-Log '[NodeUpgrade] [debian] Restarting kubelet' -Console
            (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl restart kubelet 2>&1' `
                -UserName $UserName -IpAddress $nodeIp).Output | Write-Log -Console
        }
        'windows' {
            throw '[NodeUpgrade] Windows worker node upgrade is not yet supported via this path.'
        }
        default {
            throw "[NodeUpgrade] Unsupported OS family '$osFamily'."
        }
    }

    # ------------------------------------------------------------------
    # Phase 7 - Uncordon the node
    # ------------------------------------------------------------------
    Write-Log "[NodeUpgrade] === Phase 7: Uncordoning node '$NodeName' ===" -Console

    (Invoke-Kubectl -Params @('uncordon', $NodeName)).Output | Write-Log -Console

    # ------------------------------------------------------------------
    # Phase 8 - Wait for node to be Ready
    # ------------------------------------------------------------------
    Write-Log "[NodeUpgrade] === Phase 8: Waiting for node '$NodeName' to be Ready ===" -Console

    $waitOutput = (Invoke-Kubectl -Params @('wait', "node/$NodeName", '--for=condition=Ready', '--timeout=180s')).Output
    Write-Log "[NodeUpgrade] $waitOutput" -Console

    Write-Log '---------------------------------------------------------------' -Console
    Write-Log "[NodeUpgrade] Node '$NodeName' upgraded successfully.  Duration: $('{0:hh\:mm\:ss}' -f $durationStopwatch.Elapsed)" -Console
    Write-Log '---------------------------------------------------------------' -Console
}
catch {
    $errMsg = $_.Exception.Message
    Write-Log "[NodeUpgrade] ERROR: $errMsg" -Console

    # Best-effort uncordon so the cluster doesn't stay degraded
    try {
        (Invoke-Kubectl -Params @('uncordon', $NodeName)).Output | Write-Log
    }
    catch { }

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Error -Code 'node-upgrade-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err}
        exit 0
    }
    throw
}
finally {
    if ($null -ne $tempDir -and (Test-Path $tempDir)) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log '[NodeUpgrade] Temporary extraction directory cleaned up.' -Console
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null}
}
