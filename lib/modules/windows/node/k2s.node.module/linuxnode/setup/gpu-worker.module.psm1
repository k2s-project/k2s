# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Module for setting up GPU support on external Linux worker nodes.

.DESCRIPTION
    This module provides functions to configure external Linux workers as GPU-capable nodes.
    It handles:
    - NVIDIA driver verification
    - NVIDIA Container Toolkit installation
    - CRI-O/CDI configuration
    - Node labeling for GPU workloads

    Prerequisites:
    - NVIDIA kernel drivers must be pre-installed on the target Linux machine
    - The node must be accessible via SSH
#>

$infraModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\cluster\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $clusterModule

# GPU node label keys used by K2s
$script:GpuLabelKey = 'gpu'
$script:AcceleratorLabel = 'accelerator'

function Get-GpuAddonNvidiaImages {
    $repoRoot = (Get-Item -Path $PSScriptRoot).Parent.Parent.Parent.Parent.Parent.Parent.Parent.FullName
    $manifestPath = Join-Path -Path $repoRoot -ChildPath 'addons\gpu-node\addon.manifest.yaml'
    
    if (!(Test-Path -Path $manifestPath)) {
        throw "[GPU] GPU addon manifest not found at: $manifestPath"
    }
    
    $manifestContent = Get-Content -Path $manifestPath -Raw
    if ([string]::IsNullOrWhiteSpace($manifestContent)) {
        throw "[GPU] GPU addon manifest is empty: $manifestPath"
    }
    
    $imageMatches = [regex]::Matches($manifestContent, 'nvcr\.io/nvidia/[A-Za-z0-9_./-]+:[A-Za-z0-9_.-]+')
    $images = @($imageMatches | ForEach-Object { $_.Value } | Select-Object -Unique)

    if ($images.Count -eq 0) {
        throw "[GPU] No NVIDIA container images found in addon manifest at: $manifestPath"
    }
    
    $devicePluginVersion = ($images | Where-Object { $_ -match '^nvcr\.io/nvidia/k8s-device-plugin:' } | Select-Object -First 1) -replace '^.*:', ''
    $dcgmExporterVersion = ($images | Where-Object { $_ -match '^nvcr\.io/nvidia/k8s/dcgm-exporter:' } | Select-Object -First 1) -replace '^.*:', ''

    Write-Log "[GPU] k8s-device-plugin version from addon manifest: $devicePluginVersion" -Console
    Write-Log "[GPU] dcgm-exporter version from addon manifest: $dcgmExporterVersion" -Console
    Write-Log "[GPU] Using NVIDIA images from addon manifest: $($images -join ', ')"

    return $images
}

<#
.SYNOPSIS
    Installs and configures the NVIDIA Container Toolkit on the target Linux node.

.DESCRIPTION
    Installs the NVIDIA Container Toolkit packages required for running GPU workloads
    in containers. Supports both online (apt) and offline (pre-downloaded packages)
    installation modes.

.PARAMETER UserName
    SSH username for the remote node.

.PARAMETER IpAddress
    IP address of the remote node.

.PARAMETER Proxy
    Optional HTTP proxy for package downloads.

.PARAMETER Offline
    When set, uses pre-downloaded packages from the node package instead of apt.

.PARAMETER NodePackagePath
    Path to the node package directory containing offline GPU packages.
#>
function Install-NvidiaContainerToolkit {
    param (
        [Parameter(Mandatory = $true)]
        [string] $UserName,
        [Parameter(Mandatory = $true)]
        [string] $IpAddress,
        [Parameter(Mandatory = $false)]
        [string] $Proxy = '',
        [Parameter(Mandatory = $false)]
        [switch] $Offline = $false,
        [Parameter(Mandatory = $false)]
        [string] $OsName = '',
        [Parameter(Mandatory = $false)]
        [string] $Architecture = 'amd64'
    )

    $requiredPackages = @(
        'libnvidia-container1',
        'libnvidia-container-tools',
        'nvidia-container-runtime',
        'nvidia-container-toolkit'
    )

    # Check if already installed
    $alreadyInstalled = $true
    foreach ($pkg in $requiredPackages) {
        $checkResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute "dpkg -l $pkg 2>/dev/null | grep -q '^ii'" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors
        if (!$checkResult.Success) {
            $alreadyInstalled = $false
            break
        }
    }

    if ($alreadyInstalled) {
        Write-Log "[GPU] NVIDIA Container Toolkit already installed on $IpAddress" -Console
        return
    }

    if ($Offline) {
        Install-NvidiaContainerToolkitOffline -UserName $UserName -IpAddress $IpAddress -OsName $OsName -Architecture $Architecture
    } else {
        Install-NvidiaContainerToolkitOnline -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy
    }

    # Verify installation
    $verifyResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'dpkg -l nvidia-container-toolkit 2>/dev/null | grep -q "^ii"' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors
    if (!$verifyResult.Success) {
        throw "[GPU] Failed to verify NVIDIA Container Toolkit installation on $IpAddress"
    }

    Write-Log "[GPU] NVIDIA Container Toolkit installed successfully on $IpAddress" -Console
}

<#
.SYNOPSIS
    Installs NVIDIA Container Toolkit packages from pre-downloaded packages (offline mode).
#>
function Install-NvidiaContainerToolkitOffline {
    param (
        [Parameter(Mandatory = $true)]
        [string] $UserName,
        [Parameter(Mandatory = $true)]
        [string] $IpAddress,
        [Parameter(Mandatory = $false)]
        [string] $OsName = '',
        [Parameter(Mandatory = $false)]
        [string] $Architecture = 'amd64'
    )

    Write-Log "[GPU] Installing NVIDIA Container Toolkit (offline) on $IpAddress" -Console

    # GPU packages are keyed by worker architecture to prevent cross-architecture reuse.
    $linuxNodeDir = Get-DirectoryOfLinuxNodeArtifactsOnWindowsHost
    $gpuPackagesDir = Join-Path (Join-Path (Join-Path (Join-Path $linuxNodeDir 'packages') $OsName) $Architecture) 'nvidia-gpu'
    if (!(Test-Path $gpuPackagesDir) -and $Architecture -eq 'amd64') {
        $gpuPackagesDir = Join-Path (Join-Path (Join-Path $linuxNodeDir 'packages') $OsName) 'nvidia-gpu'
    }

    if ([string]::IsNullOrWhiteSpace($OsName) -or !(Test-Path $gpuPackagesDir)) {
        throw @"
[GPU] Offline GPU packages not found at: $gpuPackagesDir
To enable GPU support offline, create a node package that includes GPU artifacts:
  k2s system package --node-package --os $OsName --include-gpu --target-dir C:\output --name node-gpu.zip

Then use:
  k2s node add --ip-addr <ip> --username <user> --node-package <path-to-package>
"@
    }

    Write-Log "[GPU] Found GPU packages at: $gpuPackagesDir" -Console

    # Copy GPU packages to remote node
    $remoteGpuDir = '/tmp/k2s-gpu-packages'
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "rm -rf $remoteGpuDir && mkdir -p $remoteGpuDir" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

    # Copy all .deb files
    $debFiles = Get-ChildItem -Path $gpuPackagesDir -Filter '*.deb' -File
    if ($debFiles.Count -eq 0) {
        throw "[GPU] No .deb files found in $gpuPackagesDir"
    }

    Write-Log "[GPU] Copying $($debFiles.Count) .deb files to remote node" -Console
    foreach ($deb in $debFiles) {
        Copy-ToRemoteComputerViaSshKey -Source $deb.FullName -Target $remoteGpuDir -UserName $UserName -IpAddress $IpAddress
    }

    # Install packages
    Write-Log "[GPU] Installing GPU packages on remote node" -Console
    $installCmd = "cd $remoteGpuDir && sudo dpkg -i *.deb 2>&1"
    $installResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $installCmd -UserName $UserName -IpAddress $IpAddress
    $installResult.Output | Write-Log

    # Fix any broken dependencies
    if (!$installResult.Success) {
        Write-Log "[GPU] Fixing broken dependencies..." -Console
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo apt-get --fix-broken install -y' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
    }

    # Clean up
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "rm -rf $remoteGpuDir" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
}

<#
.SYNOPSIS
    Installs NVIDIA Container Toolkit packages from the internet.
.PARAMETER UserName
    SSH username for the remote node.
.PARAMETER IpAddress
    IP address of the remote node.
.PARAMETER Proxy
    Optional HTTP proxy URI (for example 'http://172.19.1.1:8181').
    For backward compatibility, values provided as 'host:port' are also accepted
    and normalized to 'http://host:port'.
#>
function Install-NvidiaContainerToolkitOnline {
    param (
        [Parameter(Mandatory = $true)]
        [string] $UserName,
        [Parameter(Mandatory = $true)]
        [string] $IpAddress,
        [Parameter(Mandatory = $false)]
        [string] $Proxy = ''
    )

    Write-Log "[GPU] Installing NVIDIA Container Toolkit (online) on $IpAddress" -Console

    if ([string]::IsNullOrWhiteSpace($Proxy)) {
        $kubeSwitchIp = Get-ConfiguredKubeSwitchIP
        if (![string]::IsNullOrWhiteSpace($kubeSwitchIp)) {
            $Proxy = "http://${kubeSwitchIp}:8181"
            Write-Log "[GPU] Using K2s HTTP proxy: $Proxy"
        }
    }

    if (![string]::IsNullOrWhiteSpace($Proxy) -and ($Proxy -notmatch '^https?://')) {
        $Proxy = "http://$Proxy"
        Write-Log "[GPU] Normalized proxy to URI format: $Proxy"
    }

    $aptProxyConfigured = $false
    $curlProxy = ''
    if (![string]::IsNullOrWhiteSpace($Proxy)) {
        $curlProxy = "-x $Proxy"
        Write-Log "[GPU] Configuring apt proxy: $Proxy"
        $aptProxyConf = "Acquire::http::Proxy `"$Proxy`";`nAcquire::https::Proxy `"$Proxy`";`n"
        $aptProxyConfBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($aptProxyConf))
        $aptProxyCmd = "echo '$aptProxyConfBase64' | base64 -d | sudo tee /etc/apt/apt.conf.d/95k2s-proxy"
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute $aptProxyCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
        $aptProxyConfigured = $true
    }

    try {
        Write-Log "[GPU] Setting up NVIDIA apt repository (proxy='$Proxy')" -Console

        $repoSetupCmd = "curl --retry 3 --retry-all-errors -fsSL https://nvidia.github.io/libnvidia-container/gpgkey $curlProxy | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && curl --retry 3 --retry-all-errors -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list $curlProxy | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"

        $repoResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $repoSetupCmd -UserName $UserName -IpAddress $IpAddress
        Write-Log "[GPU] Repo setup result - Success: $($repoResult.Success), Output: $($repoResult.Output)"
        if (!$repoResult.Success) {
            throw "[GPU] Failed to set up NVIDIA repository on $IpAddress. Ensure the node has internet access or use --node-package for offline installation."
        }

        $verifySourcesCmd = 'cat /etc/apt/sources.list.d/nvidia-container-toolkit.list 2>/dev/null || echo "FILE_NOT_FOUND"'
        $verifyResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $verifySourcesCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors
        $verifyResult.Output | Write-Log
        if ($verifyResult.Output -match 'FILE_NOT_FOUND') {
            Write-Log '[GPU] WARNING: NVIDIA repository file /etc/apt/sources.list.d/nvidia-container-toolkit.list was not created.' -Console
        }

        # Proxy is taken from /etc/apt/apt.conf.d/95k2s-proxy when configured above
        $updateCmd = 'sudo apt-get update'
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute $updateCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log

        $installCmd = 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libnvidia-container1 libnvidia-container-tools nvidia-container-runtime nvidia-container-toolkit'
        $installResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $installCmd -UserName $UserName -IpAddress $IpAddress
        $installResult.Output | Write-Log

        if (!$installResult.Success) {
            throw "[GPU] Failed to install NVIDIA Container Toolkit packages on $IpAddress"
        }
    }
    finally {
        # Remove the temporary apt proxy config so future apt operations on this
        # (potentially long-lived) node do not depend on the K2s proxy being reachable.
        if ($aptProxyConfigured) {
            Write-Log '[GPU] Removing temporary apt proxy configuration (/etc/apt/apt.conf.d/95k2s-proxy)'
            (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo rm -f /etc/apt/apt.conf.d/95k2s-proxy' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log
        }
    }
}

<#
.SYNOPSIS
    Configures CRI-O for NVIDIA GPU support via CDI.

.DESCRIPTION
    Configures CRI-O to use NVIDIA Container Runtime and CDI for GPU device injection.
    This is required for Kubernetes to schedule GPU workloads on the node.

.PARAMETER UserName
    SSH username for the remote node.

.PARAMETER IpAddress
    IP address of the remote node.
#>
function Set-CrioGpuConfiguration {
    param (
        [Parameter(Mandatory = $true)]
        [string] $UserName,
        [Parameter(Mandatory = $true)]
        [string] $IpAddress
    )

    Write-Log "[GPU] Configuring CRI-O for GPU support on $IpAddress" -Console

    # Generate CDI spec for NVIDIA devices
    Write-Log "[GPU] Generating CDI specification..." -Console
    $cdiCmd = 'sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>&1 || true'
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute $cdiCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log

    # Ensure CDI directory exists and spec is readable
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo mkdir -p /etc/cdi && sudo chmod 755 /etc/cdi' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output | Write-Log

    # Configure CRI-O to enable CDI devices
    # Use base64 encoding to avoid all shell quoting issues when passing through SSH
    $crioConfig = @'
[crio.runtime]
enable_cdi = true
cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]
'@
    $crioConfigBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($crioConfig))
    $crioConfigCmd = "sudo mkdir -p /etc/crio/crio.conf.d && echo '$crioConfigBase64' | base64 -d | sudo tee /etc/crio/crio.conf.d/99-nvidia-gpu.conf"
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute $crioConfigCmd -UserName $UserName -IpAddress $IpAddress -Timeout 10).Output | Write-Log

    # Restart CRI-O to apply changes
    Write-Log "[GPU] Restarting CRI-O to apply GPU configuration..." -Console
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl restart crio' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

    # Wait for CRI-O to be ready
    Start-Sleep -Seconds 3
    $crioStatus = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl is-active crio' -UserName $UserName -IpAddress $IpAddress -IgnoreErrors
    if ($crioStatus.Output -notmatch 'active') {
        Write-Log "[GPU] WARNING: CRI-O may not have restarted correctly. Status: $($crioStatus.Output)" -Console
    }

    Write-Log "[GPU] CRI-O GPU configuration complete on $IpAddress" -Console
}

<#
.SYNOPSIS
    Ensures NVIDIA device plugin container images are available on a worker node.

.DESCRIPTION
    Checks if required GPU images are present. For offline installations, images
    are already loaded during node setup via Copy-KubernetesImagesFromControlPlaneToRemoteComputer.
    For online installations, pulls the images via buildah/crictl.

.PARAMETER UserName
    SSH username for the remote node.

.PARAMETER IpAddress
    IP address of the remote node.

.PARAMETER Proxy
    Optional HTTP proxy for image pulls (online mode only).
#>
function Install-GpuDevicePluginImages {
    param (
        [Parameter(Mandatory = $true)]
        [string] $UserName,
        [Parameter(Mandatory = $true)]
        [string] $IpAddress,
        [Parameter(Mandatory = $false)]
        [string] $Proxy = ''
    )

    Write-Log "[GPU] Ensuring device plugin images are available on $IpAddress" -Console

    # Resolve image versions from gpu-node addon manifest so automation that scans
    # addon files (Enable.ps1/addon.manifest.yaml) stays the source of truth.
    $images = Get-GpuAddonNvidiaImages

    # If no proxy specified, use K2s's HTTP proxy
    if ([string]::IsNullOrWhiteSpace($Proxy)) {
        $kubeSwitchIp = Get-ConfiguredKubeSwitchIP
        if (![string]::IsNullOrWhiteSpace($kubeSwitchIp)) {
            $Proxy = "http://${kubeSwitchIp}:8181"
            Write-Log "[GPU] Using K2s HTTP proxy for image pulls: $Proxy"
        }
    }

    # Build proxy environment if provided.
    $proxyEnv = ''
    if (![string]::IsNullOrWhiteSpace($Proxy)) {
        # Normalize proxy URL - strip existing scheme to avoid duplication
        $proxyHost = $Proxy -replace '^https?://', ''
        $proxyEnv = "HTTPS_PROXY=http://$proxyHost HTTP_PROXY=http://$proxyHost "
    }

    foreach ($image in $images) {
        # Skip if already present (e.g., loaded from offline package during node setup)
        $alreadyPresent = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo crictl inspecti '$image' >/dev/null 2>&1 && echo present || echo missing" -UserName $UserName -IpAddress $IpAddress -IgnoreErrors).Output
        if ($alreadyPresent -match 'present') {
            Write-Log "[GPU] Image already present: $image" -Console
            continue
        }

        # Online mode: pull image
        Write-Log "[GPU] Pulling image: $image" -Console

        # Try buildah pull (shares storage with CRI-O)
        $pullCmd = "sudo ${proxyEnv}buildah pull '$image' 2>&1"
        $pullResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $pullCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors
        $pullResult.Output | Write-Log

        if (!$pullResult.Success) {
            # Fallback: try crictl pull
            Write-Log "[GPU] buildah pull failed, trying crictl pull..." -Console
            $crictlCmd = "sudo ${proxyEnv}crictl pull '$image' 2>&1"
            $crictlResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $crictlCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors
            $crictlResult.Output | Write-Log

            if (!$crictlResult.Success) {
                Write-Log "[GPU] WARNING: Failed to pull image '$image' - the device plugin pod may stall waiting for the image" -Console
                Write-Log "[GPU] For offline support, create node package with: k2s system package node --include-gpu" -Console
            } else {
                Write-Log "[GPU] Image pulled successfully via crictl: $image" -Console
            }
        } else {
            Write-Log "[GPU] Image pulled successfully: $image" -Console
        }
    }

    Write-Log "[GPU] Device plugin images check complete on $IpAddress" -Console
}

<#
.SYNOPSIS
    Labels a Kubernetes node as GPU-capable.

.DESCRIPTION
    Applies GPU labels to the node so it can be targeted by GPU workloads
    and the NVIDIA device plugin DaemonSet.

.PARAMETER NodeName
    Kubernetes node name (lowercase hostname).
#>
function Set-GpuNodeLabels {
    param (
        [Parameter(Mandatory = $true)]
        [string] $NodeName
    )

    Write-Log "[GPU] Labeling node '$NodeName' as GPU-capable" -Console

    $kubeToolsPath = Get-KubeToolsPath
    $kubectl = "$kubeToolsPath\kubectl.exe"

    # Apply GPU labels
    $labels = @(
        "$script:GpuLabelKey=true",
        "$script:AcceleratorLabel=nvidia"
    )

    foreach ($label in $labels) {
        $result = & $kubectl label node $NodeName.ToLower() $label --overwrite 2>&1
        Write-Log "[GPU] Applied label '$label': $result"
    }

    Write-Log "[GPU] Node '$NodeName' labeled as GPU-capable" -Console
}

<#
.SYNOPSIS
    Main entry point for setting up GPU support on an external Linux worker node.

.DESCRIPTION
    Orchestrates the complete GPU setup process:
    1. Installs NVIDIA Container Toolkit
    2. Configures CRI-O for GPU support
    3. Pre-pulls NVIDIA device plugin images
    4. Labels the node for GPU workloads

.PARAMETER UserName
    SSH username for the remote node.

.PARAMETER IpAddress
    IP address of the remote node.

.PARAMETER NodeName
    Kubernetes node name (hostname).

.PARAMETER Proxy
    Optional HTTP proxy for package downloads.

.PARAMETER NodePackagePath
    Path to node package for offline installation.
#>
function Initialize-GpuWorkerNode {
    param (
        [Parameter(Mandatory = $true)]
        [string] $UserName,
        [Parameter(Mandatory = $true)]
        [string] $IpAddress,
        [Parameter(Mandatory = $true)]
        [string] $NodeName,
        [Parameter(Mandatory = $false)]
        [string] $Proxy = '',
        [Parameter(Mandatory = $false)]
        [switch] $Offline = $false,
        [Parameter(Mandatory = $false)]
        [string] $OsName = '',
        [Parameter(Mandatory = $false)]
        [string] $Architecture = 'amd64'
    )

    Write-Log '[GPU] ======================================' -Console
    Write-Log "[GPU] Initializing GPU support for worker node $NodeName ($IpAddress)" -Console
    Write-Log "[GPU] Mode: $(if ($Offline) { 'offline' } else { 'online' })" -Console
    Write-Log '[GPU] ======================================' -Console

    # Step 1: Install NVIDIA Container Toolkit (offline: from .deb files, online: from apt)
    Install-NvidiaContainerToolkit -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy -Offline:$Offline -OsName $OsName -Architecture $Architecture

    # Step 2: Configure CRI-O
    Set-CrioGpuConfiguration -UserName $UserName -IpAddress $IpAddress

    # Step 3: Ensure device plugin images are available
    # For offline mode, images are already loaded from the node package during Install-LinuxPackagesAndAddContainerImagesIntoRemoteComputer
    # For online mode, pull the images
    if (-not $Offline) {
        Install-GpuDevicePluginImages -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy
    } else {
        Write-Log "[GPU] Skipping image pull (offline mode - images loaded from node package)" -Console
    }

    # Step 4: Label the node
    Set-GpuNodeLabels -NodeName $NodeName

    Write-Log '[GPU] ======================================' -Console
    Write-Log "[GPU] GPU support initialized for node $NodeName" -Console
    Write-Log '[GPU] ======================================' -Console
    Write-Log '[GPU] The node is now ready for GPU workloads.' -Console
    Write-Log '[GPU] To run GPU pods, ensure the gpu-node addon is enabled:' -Console
    Write-Log "[GPU]   k2s addons enable gpu-node --node $NodeName" -Console
    Write-Log '[GPU] ======================================' -Console
}

# Export module functions
Export-ModuleMember -Function `
    Install-NvidiaContainerToolkit,
    Set-CrioGpuConfiguration,
    Set-GpuNodeLabels,
    Initialize-GpuWorkerNode,Install-NvidiaContainerToolkitOffline
