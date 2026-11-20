# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Downloads all Kubernetes node packages (kubelet, kubeadm, kubectl, CRI-O, buildah)
    and their dependencies for the specified Linux distribution, then bundles them into a zip file
    for offline installation.

.DESCRIPTION
    Boots an ephemeral Hyper-V VM from a cloud image matching the target OS/version,
    SSHes in, runs the distribution-specific download scripts to fetch .deb packages via
    apt-get download, copies the packages back to the Windows host, and creates a zip archive.

    Node package creation requires an existing K2s cluster on the machine where the command
    runs. When -Proxy is omitted, the local cluster proxy
    (http://<KubeSwitchIP>:8181, e.g. http://172.19.1.1:8181) is used automatically.

    The -TargetDirectory and -ZipPackageFileName flags are required and control
    where the resulting zip is written and what it is named.

.PARAMETER OS
    Linux distribution name and version combined. Supported: debian12, debian13. Example: debian12

.PARAMETER TargetDirectory
    Directory where the resulting zip file is written.

.PARAMETER ZipPackageFileName
    File name for the resulting zip archive (must end in .zip).

.PARAMETER Proxy
    Optional HTTP proxy to use for package downloads inside the VM. When omitted, the
    local cluster transparent proxy (http://<KubeSwitchIP>:8181, e.g. http://172.19.1.1:8181)
    is used by default. Node package creation requires an installed and running K2s cluster.

.PARAMETER ShowLogs
    When set, all log output is also printed to the console.

.EXAMPLE
    # Download Debian 12 node packages (uses the cluster proxy by default)
    k2s system package --node-package --os debian12 --target-dir "C:\out" --name "debian12-node.zip"

.EXAMPLE
    # Download Debian 13 node packages (uses the cluster proxy by default)
    k2s system package --node-package --os debian13 --target-dir "C:\out" --name "debian13-node.zip"
#>

param (
    [Parameter(Mandatory = $true, HelpMessage = 'Target Linux distribution and version combined (e.g. debian12, debian13)')]
    [string] $OS,

    [Parameter(Mandatory = $true, HelpMessage = 'Directory where the resulting zip file is written')]
    [string] $TargetDirectory,

    [Parameter(Mandatory = $true, HelpMessage = 'File name of the resulting zip archive (must end in .zip)')]
    [string] $ZipPackageFileName,

    [Parameter(Mandatory = $false, HelpMessage = 'HTTP proxy for package downloads inside the VM')]
    [string] $Proxy = '',

    [Parameter(Mandatory = $false, HelpMessage = 'Include NVIDIA Container Toolkit packages for GPU support')]
    [switch] $IncludeGpu = $false,

    [Parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [Parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [Parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule  = "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$vmProvisioningHelper = "$PSScriptRoot\New-K2sNodePackage.VmProvisioning.ps1"
$puttyToolsHelper = "$PSScriptRoot\New-K2sPackage.PuttyTools.ps1"

Import-Module $infraModule, $nodeModule, $clusterModule
. $vmProvisioningHelper
. $puttyToolsHelper

if ($EncodeStructuredOutput) {
    Initialize-Logging -ShowLogs:$false
} else {
    Initialize-Logging -ShowLogs:$ShowLogs
}

$distributionKey = $OS.ToLower()

Write-Log "[NodePkg] Starting node package creation for OS='$OS'" -Console
Write-Log "[NodePkg] Distribution key: $distributionKey" -Console
Write-Log "[NodePkg] Target directory: $TargetDirectory" -Console
Write-Log "[NodePkg] Output zip: $ZipPackageFileName" -Console

# ---------------------------------------------------------------------------
# Pre-check: node package creation requires a running K2s cluster. The cluster
# provides the transparent proxy (httpproxy.exe) at <KubeSwitchIP>:8181 that the
# ephemeral VM uses to download packages from the internet. Fail fast otherwise.
# ---------------------------------------------------------------------------
$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }
    Write-Log $systemError.Message -Error
    exit 1
}

# Clean up stale node-package NATs and switches from previous failed runs.
# Without this, random subnet selection can collide with a stale NAT/route,
# causing New-NetIPAddress to fail and host-to-VM SSH to time out.
$staleNetworkNamePattern = 'k2s-nodepkg-debian*'
Write-Log "[NodePkg] Cleaning stale network artifacts matching '$staleNetworkNamePattern'" -Console
Get-NetNat -ErrorAction SilentlyContinue |
    Where-Object Name -like $staleNetworkNamePattern |
    ForEach-Object {
        Write-Log "[NodePkg] Removing stale NetNat '$($_.Name)'"
        Remove-NetNat -Name $_.Name -Confirm:$false -ErrorAction SilentlyContinue
    }
Get-VMSwitch -ErrorAction SilentlyContinue |
    Where-Object Name -like $staleNetworkNamePattern |
    ForEach-Object {
        Write-Log "[NodePkg] Removing stale VMSwitch '$($_.Name)'"
        Remove-VMSwitch -Name $_.Name -Force -ErrorAction SilentlyContinue
    }

if ([string]::IsNullOrWhiteSpace($Proxy)) {
    $kubeSwitchIp = Get-ConfiguredKubeSwitchIP
    if ([string]::IsNullOrWhiteSpace($kubeSwitchIp)) {
        throw '[NodePkg] Could not determine KubeSwitch IP for default proxy.'
    }
    $Proxy = "http://${kubeSwitchIp}:8181"
    Write-Log "[NodePkg] No proxy specified. Defaulting to K2s transparent proxy '$Proxy'." -Console
}

# Initialize variables for VM and network provisioning
$tempPath = [System.IO.Path]::GetTempPath()
$stagingDir = Join-Path $tempPath "k2s-node-pkg-$([guid]::NewGuid().ToString().Substring(0, 8))"
$vmName = "k2s-nodepkg-$distributionKey-$(Get-Random -Maximum 9999)"
$switchName = ''
$natName = ''
$guestIp = ''
$sshUser = ''
$sshPwd = ''
$inProvisioningVhdxPath = ''
$usesSharedKubeSwitch = $false

$provisioningDir = Join-Path $stagingDir "provisioning"
$downloadsDir = Join-Path $stagingDir "downloads"
$packagesDir = Join-Path $stagingDir "packages"
$packagesByOsDir = Join-Path $packagesDir $distributionKey
$k8sPkgDir = Join-Path $packagesByOsDir "kubernetes"
$buildahPkgDir = Join-Path $packagesByOsDir "buildah"
$gpuPkgDir = Join-Path $packagesByOsDir "nvidia-gpu"
$imagesDir = Join-Path $stagingDir "images"
$remoteK8sPkgDir = "/tmp/k2s-k8s-packages"
$remoteBuildahPkgDir = "/tmp/k2s-buildah-packages"
$remoteGpuPkgDir = "/tmp/k2s-gpu-packages"
$remoteImagesExportDir = "/tmp/k2s-images"
$vmProvisioningStarted = $false

New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null
New-Item -Path $packagesDir -ItemType Directory -Force | Out-Null
New-Item -Path $packagesByOsDir -ItemType Directory -Force | Out-Null
New-Item -Path $k8sPkgDir -ItemType Directory -Force | Out-Null
New-Item -Path $buildahPkgDir -ItemType Directory -Force | Out-Null
if ($IncludeGpu) {
    New-Item -Path $gpuPkgDir -ItemType Directory -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------

Test-SupportedWorkerOS -OS $distributionKey

$zipTarget = Join-Path $TargetDirectory $ZipPackageFileName
if (Test-Path $zipTarget) {
    Write-Log "[NodePkg] Package already exists: $zipTarget" -Console
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null}
    }
    return
}

# ---------------------------------------------------------------------------
# Prerequisite: ensure plink.exe and pscp.exe are available
# ---------------------------------------------------------------------------
Assert-PuttyToolsReady -LogPrefix '[NodePkg]' -Proxy $Proxy

# ---------------------------------------------------------------------------
# Resolve paths and versions
# ---------------------------------------------------------------------------
$k8sVersion  = Get-DefaultK8sVersion

function Assert-PackagesDownloaded {
    param(
        [Parameter(Mandatory = $true)]
        [string]$K8sPath,
        [Parameter(Mandatory = $true)]
        [string]$BuildahPath
    )

    $k8sDebCount = @(Get-ChildItem -Path $K8sPath -Filter '*.deb' -File -ErrorAction SilentlyContinue).Count
    $buildahDebCount = @(Get-ChildItem -Path $BuildahPath -Filter '*.deb' -File -ErrorAction SilentlyContinue).Count
    $totalDebCount = $k8sDebCount + $buildahDebCount

    Write-Log "[NodePkg] Local package counts: kubernetes=$k8sDebCount, buildah=$buildahDebCount, total=$totalDebCount" -Console

    if ($totalDebCount -eq 0) {
        throw "[NodePkg] No .deb packages were copied from the VM. Check remote download script output and remote package paths."
    }
}

try {


    $vmContext = Start-NodePackageVmProvisioning `
        -DistributionKey $distributionKey `
        -VmName $vmName `
        -Proxy $Proxy `
        -ShowLogs:$ShowLogs

    $switchName = $vmContext.SwitchName
    $natName = $vmContext.NatName
    $guestIp = $vmContext.GuestIp
    $sshUser = $vmContext.SshUser
    $sshPwd = $vmContext.SshPwd
    $inProvisioningVhdxPath = $vmContext.InProvisioningVhdxPath
    $usesSharedKubeSwitch = $vmContext.UsesSharedKubeSwitch
    $vmProvisioningStarted = $true

    # -----------------------------------------------------------------------
    # Phase 4 - Download Kubernetes packages inside the VM
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 4: Downloading Kubernetes packages inside VM (k8sVersion=$k8sVersion) ===" -Console
    Get-KubernetesArtifactsFromInternet `
        -UserName              $sshUser `
        -UserPwd               $sshPwd `
        -IpAddress             $guestIp `
        -Proxy                 $Proxy `
        -K8sVersion            $k8sVersion `
        -TargetPath            $remoteK8sPkgDir `
        -InstalledDistribution $distributionKey

    # -----------------------------------------------------------------------
    # Phase 5 - Download buildah packages inside the VM
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 5: Downloading buildah packages inside VM ===" -Console
    Get-BuildahDebPackagesFromInternet `
        -UserName              $sshUser `
        -UserPwd               $sshPwd `
        -IpAddress             $guestIp `
        -Proxy                 $Proxy `
        -TargetPath            $remoteBuildahPkgDir `
        -InstalledDistribution $distributionKey

    # -----------------------------------------------------------------------
    # Phase 6 - Install Kubernetes packages inside the VM
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 6: Installing Kubernetes packages inside VM ===" -Console
    Install-KubernetesArtifacts `
        -UserName              $sshUser `
        -UserPwd               $sshPwd `
        -IpAddress             $guestIp `
        -Proxy                 $Proxy `
        -SourcePath            $remoteK8sPkgDir `
        -InstalledDistribution $distributionKey

    # -----------------------------------------------------------------------
    # Phase 7 - Install buildah packages inside the VM
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 7: Installing buildah packages inside VM ===" -Console
    Install-BuildahDebPackages `
        -UserName              $sshUser `
        -UserPwd               $sshPwd `
        -IpAddress             $guestIp `
        -SourcePath            $remoteBuildahPkgDir `
        -InstalledDistribution $distributionKey

    # -----------------------------------------------------------------------
    # Phase 7.5 (optional) - Download NVIDIA Container Toolkit packages
    # -----------------------------------------------------------------------
    if ($IncludeGpu) {
        Write-Log "[NodePkg] === Phase 7.5: Downloading NVIDIA Container Toolkit packages (GPU support) ===" -Console
        Get-NvidiaGpuDebPackagesFromInternet `
            -UserName   $sshUser `
            -UserPwd    $sshPwd `
            -IpAddress  $guestIp `
            -Proxy      $Proxy `
            -TargetPath $remoteGpuPkgDir
    }

    # -----------------------------------------------------------------------
    # Phase 8 - Pull and export Kubernetes/flannel images from VM
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 8: Pulling and exporting container images inside VM ===" -Console

    $remoteUser = "$sshUser@$guestIp"
    New-Item -Path $imagesDir -ItemType Directory -Force | Out-Null

    # Use existing image pull helpers from k2s.node.module
    Get-KubernetesImages `
        -UserName   $sshUser `
        -UserPwd    $sshPwd `
        -IpAddress  $guestIp `
        -K8sVersion $k8sVersion

    Get-FlannelImages `
        -UserName  $sshUser `
        -UserPwd   $sshPwd `
        -IpAddress $guestIp

    # Pull GPU images if --include-gpu is specified
    if ($IncludeGpu) {
        Get-GpuContainerImages `
            -UserName  $sshUser `
            -UserPwd   $sshPwd `
            -IpAddress $guestIp `
            -Proxy     $Proxy
    }

    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "mkdir -p $remoteImagesExportDir" -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output | Write-Log

    # Kubeadm is the source of truth for Kubernetes images, including pause.
    $kubeadmImagesOutput = (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo kubeadm config images list --kubernetes-version $k8sVersion" -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output
    $kubeadmImageRefs = @($kubeadmImagesOutput | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[^\s]+/[^\s]+:[^\s]+$' })

    if (@($kubeadmImageRefs).Count -eq 0) {
        throw "[NodePkg] Could not resolve Kubernetes images with kubeadm for version '$k8sVersion'."
    }

    Write-Log "[NodePkg] Kubeadm images selected for export: $($kubeadmImageRefs -join ', ')" -Console

    # Build non-kubeadm export list from crictl JSON to avoid fragile text parsing.
    $imagesJsonOutput = (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'sudo crictl images -o json' -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output
    $imagesJsonText = ($imagesJsonOutput -join "`n")
    $imagesDoc = $imagesJsonText | ConvertFrom-Json

    $imageRefsToExport = @($kubeadmImageRefs)
    foreach ($img in @($imagesDoc.images)) {
        foreach ($repoTag in @($img.repoTags)) {
            if ([string]::IsNullOrWhiteSpace($repoTag) -or $repoTag -match '<none>') {
                continue
            }
            if ($repoTag -like 'docker.io/flannel/*') {
                $imageRefsToExport += $repoTag
            }
            # Include GPU images when --include-gpu is specified
            if ($IncludeGpu -and $repoTag -like 'nvcr.io/*') {
                $imageRefsToExport += $repoTag
            }
        }
    }
    $imageRefsToExport = $imageRefsToExport | Select-Object -Unique

    if (@($imageRefsToExport).Count -eq 0) {
        throw "[NodePkg] No container images were selected for export."
    }

    Write-Log "[NodePkg] Images selected for export: $($imageRefsToExport -join ', ')" -Console

    foreach ($imageFullName in $imageRefsToExport) {
        $sanitizedName = $imageFullName.Replace('/','_').Replace(':', '__')
        $finalExportPath = Join-Path $imagesDir "$sanitizedName.tar"
        $targetFilePath = "$remoteImagesExportDir/${sanitizedName}.tar"
        $buildahPushCmd = 'sudo buildah push {0} oci-archive:{1}:{0} 2>&1' -f $imageFullName, $targetFilePath

        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $buildahPushCmd -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output | Write-Log

        Copy-FromRemoteComputerViaUserAndPwd `
            -Source    $targetFilePath `
            -Target    $finalExportPath `
            -IpAddress $guestIp `
            -UserName  $sshUser `
            -UserPwd   $sshPwd

        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo rm -f $targetFilePath" -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output | Write-Log
    }

    $localExportCount = @(Get-ChildItem -Path $imagesDir -Filter '*.tar' -File -ErrorAction SilentlyContinue).Count
    if ($localExportCount -eq 0) {
        throw '[NodePkg] No container images were exported and copied to staging. Check image listing command output in logs.'
    }
    Write-Log "[NodePkg] Exported container images copied to staging: $localExportCount" -Console

    $remoteK8sDebCount = (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "ls -1 $remoteK8sPkgDir/*.deb 2>/dev/null | wc -l" -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output
    $remoteBuildahDebCount = (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "ls -1 $remoteBuildahPkgDir/*.deb 2>/dev/null | wc -l" -RemoteUser $remoteUser -RemoteUserPwd $sshPwd -IgnoreErrors).Output
    Write-Log "[NodePkg] Remote package counts before copy: kubernetes=$($remoteK8sDebCount.Trim()), buildah=$($remoteBuildahDebCount.Trim())" -Console

    # -----------------------------------------------------------------------
    # Phase 9 - Copy packages from VM back to Windows host
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 9: Copying packages from VM to Windows ===" -Console
    Copy-FromRemoteComputerViaUserAndPwd `
        -Source    "$remoteK8sPkgDir/*" `
        -Target    $k8sPkgDir `
        -IpAddress $guestIp `
        -UserName  $sshUser `
        -UserPwd   $sshPwd

    Copy-FromRemoteComputerViaUserAndPwd `
        -Source    "$remoteBuildahPkgDir/*" `
        -Target    $buildahPkgDir `
        -IpAddress $guestIp `
        -UserName  $sshUser `
        -UserPwd   $sshPwd

    if ($IncludeGpu) {
        Write-Log "[NodePkg] Copying GPU packages from VM to Windows..." -Console
        Copy-FromRemoteComputerViaUserAndPwd `
            -Source    "$remoteGpuPkgDir/*" `
            -Target    $gpuPkgDir `
            -IpAddress $guestIp `
            -UserName  $sshUser `
            -UserPwd   $sshPwd

        $localGpuDebCount = @(Get-ChildItem -Path $gpuPkgDir -Filter '*.deb' -File -ErrorAction SilentlyContinue).Count
        Write-Log "[NodePkg] Local GPU package count: $localGpuDebCount" -Console
    }

    Assert-PackagesDownloaded -K8sPath $k8sPkgDir -BuildahPath $buildahPkgDir

    # -----------------------------------------------------------------------
    # Phase 10 - Create output zip
    # -----------------------------------------------------------------------
    Write-Log "[NodePkg] === Phase 10: Creating output zip ===" -Console
    New-Item -Path $TargetDirectory -ItemType Directory -Force | Out-Null
    $zipTarget = Join-Path $TargetDirectory $ZipPackageFileName
    if (Test-Path $zipTarget) { Remove-Item $zipTarget -Force }

    $zipContents = @($packagesDir, $imagesDir)
    $gpuIncludedMsg = ''
    if ($IncludeGpu) {
        $gpuIncludedMsg = ' (with GPU support)'
    }

    Compress-Archive -Path $zipContents -DestinationPath $zipTarget -Force
    Write-Log "[NodePkg] Node package zip created${gpuIncludedMsg}: $zipTarget" -Console
    Write-Log "[NodePkg] Package creation for '$distributionKey' completed successfully." -Console
}
catch {
    $errMsg = $_.Exception.Message
    Write-Log "[NodePkg] ERROR: $errMsg" -Console
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Error -Code 'node-package-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err}
        exit 0
    }
    throw
}
finally {

    if($vmProvisioningStarted)
    {
        Write-Log '[NodePkg] Cleaning up VM and network...' -Console

        $vmExists = $null -ne (Get-VM -Name $vmName -ErrorAction SilentlyContinue)
        if ($vmExists) {
            try { Stop-VirtualMachineForBaseImageProvisioning -Name $vmName }
            catch { Write-Log "[NodePkg] Warning during VM stop: $($_.Exception.Message)" -Console }

            try { Remove-VirtualMachineForBaseImageProvisioning -VmName $vmName -VhdxFilePath $inProvisioningVhdxPath }
            catch { Write-Log "[NodePkg] Warning during VM removal: $($_.Exception.Message)" -Console }
        }
        else {
            Write-Log "[NodePkg] No VM '$vmName' found for cleanup." -Console
        }

        if (-not $usesSharedKubeSwitch) {
            try { Remove-NetworkForProvisioning -SwitchName $switchName -NatName $natName }
            catch { Write-Log "[NodePkg] Warning during network cleanup: $($_.Exception.Message)" -Console }
        }
        else {
            Write-Log "[NodePkg] Skipping network cleanup because shared KubeSwitch '$switchName' is reused by K2s." -Console
        }

        if (Test-Path $stagingDir) {
            Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log '[NodePkg] Staging directory cleaned up.' -Console
        }
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null}
}
