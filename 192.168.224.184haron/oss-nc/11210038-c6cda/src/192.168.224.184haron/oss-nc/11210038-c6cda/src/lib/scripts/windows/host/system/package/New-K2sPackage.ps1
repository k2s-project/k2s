# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0



Param(
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Linux VM')]
    [long]$VMMemoryStartupBytes = 3GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for Linux VM')]
    [long]$VMProcessorCount = 6,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of Linux VM')]
    [uint64]$VMDiskSize = 10GB,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available to be used during installation')]
    [string] $Proxy = '',
    [parameter(Mandatory = $false, HelpMessage = 'Target directory')]
    [string] $TargetDirectory,
    [parameter(Mandatory = $false, HelpMessage = 'The name of the zip package (it must have the extension .zip)')]
    [string] $ZipPackageFileName,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Creates a zip package that can be used for offline installation')]
    [switch] $ForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'The path to local builds of Kubernetes binaries')]
    [string] $K8sBinsPath = '',
    [parameter(Mandatory = $false, HelpMessage = 'Path to code signing certificate (.pfx file)')]
    [string] $CertificatePath,
    [parameter(Mandatory = $false, HelpMessage = 'Password for the certificate file')]
    [string] $Password,
    [parameter(Mandatory = $false, HelpMessage = 'Packaging profile: Dev (default) or Lite (reduced footprint)')]
    [ValidateSet('Dev','Lite')]
    [string] $Profile = 'Dev',
    [parameter(Mandatory = $false, HelpMessage = 'Comma-separated list of addons to include in the package (default: all available addons)')]
    [string] $AddonsList = ''
)

$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$signingModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\common\k2s.signing.module\k2s.signing.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $signingModule

# Load helper scripts
. "$PSScriptRoot\New-K2sPackage.Archive.ps1"
. "$PSScriptRoot\New-K2sPackage.Addons.ps1"
. "$PSScriptRoot\New-K2sPackage.PuttyTools.ps1"
. "$PSScriptRoot\New-K2sPackage.Signing.ps1"
. "$PSScriptRoot\New-K2sPackage.Provisioning.ps1"

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "- Proxy to be used: $Proxy"
Write-Log "- Target Directory: $TargetDirectory"
Write-Log "- Package file name: $ZipPackageFileName"
Write-Log "- Profile: $Profile"
Write-Log "- Addons List: $AddonsList"

# Note: System.IO.Compression assemblies are loaded in New-K2sPackage.Archive.ps1

# ============================================================================
# MAIN SCRIPT LOGIC
# ============================================================================

$errMsg = ''
if ('' -eq $TargetDirectory) {
    $errMsg = 'The passed target directory is empty'
}
elseif (!(Test-Path -Path $TargetDirectory)) {
    $errMsg = "The passed target directory '$TargetDirectory' could not be found"
}
elseif ('' -eq $ZipPackageFileName) {
    $errMsg = 'The passed zip package name is empty'
}
elseif ($ZipPackageFileName.EndsWith('.zip') -eq $false) {
    $errMsg = "The passed zip package name '$ZipPackageFileName' does not have the extension '.zip'"
}
else {
    $setupInfo = Get-SetupInfo
    if ($null -eq $setupInfo.Error) {
        $productName = $setupInfo.Name
        $errMsg = "'$productName' is installed on your system. Please uninstall '$productName' first and try again."
    }
}

if ($errMsg -ne '') {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'build-package-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$zipPackagePath = Join-Path "$TargetDirectory" "$ZipPackageFileName"

if (Test-Path $zipPackagePath) {
    Write-Log "Removing already existing file '$zipPackagePath'" -Console
    Remove-Item $zipPackagePath -Force
}

# create exclusion list
$kubePath = Get-KubePath
$exclusionList = @('.git', '.vscode', '.gitignore') | ForEach-Object { Join-Path $kubePath $_ }
$exclusionList += "$kubePath\cmd\vfprules\vfprules.exe"
$exclusionList += "$kubePath\cmd\httpproxy\httpproxy.exe"
$exclusionList += "$kubePath\cmd\devgon\devgon.exe"
$exclusionList += "$kubePath\cmd\bridge\bridge.exe"
$exclusionList += "$kubePath\bin\debian-12-genericcloud-amd64.qcow2"  # Large guest cloud image not needed in package
$exclusionList += "$kubePath\bin\debian-13-genericcloud-amd64.qcow2"  # Large guest cloud image not needed in package

# Inclusion list (whitelist) - initialized empty; may be populated per profile
$inclusionList = @()

# Parse addons list if provided
# Use 'none' to exclude all addons from the package
$selectedAddons = @()
$excludeAllAddons = $false
if ($AddonsList -ieq 'none') {
    $excludeAllAddons = $true
    Write-Log '[Addons] Excluding all addons from package (--addons-list none)' -Console
} elseif ($AddonsList -ne '') {
    $selectedAddons = $AddonsList.Split(',') | ForEach-Object { $_.Trim() }
    Write-Log "[Addons] Custom addon list specified: $($selectedAddons -join ', ')" -Console
}

# Discover all available addons
$addonsRootPath = Join-Path $kubePath 'addons'
$allAddonPaths = Get-AvailableAddons -AddonsRootPath $addonsRootPath
Write-Log "[Addons] Discovered $($allAddonPaths.Count) addon implementations" -Console


if ($Profile -eq 'Lite') {
    Write-Log '[Profile] Applying Lite profile exclusions for reduced package size' -Console
    $liteExclude = @(
        (Join-Path $kubePath 'build'),
        (Join-Path $kubePath 'bin/Kubemaster-Base.rootfs.tar.gz')
    )

    # Handle addon selection for Lite profile
    if ($excludeAllAddons) {
        # Exclude individual addon subdirectories but keep root-level module files and common/
        # (addons.module.psm1, export.module.psm1, etc. are required for cluster operation;
        #  common/ contains shared manifests needed by individually imported addons)
        $addonsRootDir = Join-Path $kubePath 'addons'
        $addonSubDirs = Get-ChildItem -Path $addonsRootDir -Directory | Where-Object { $_.Name -ne 'common' }
        foreach ($dir in $addonSubDirs) {
            $liteExclude += $dir.FullName
        }
        $liteExclude += (Join-Path $kubePath 'test/e2e/addons')
        Write-Log '[Profile+Addons] Lite profile: excluding all addons (keeping addons module files and common/)' -Console
    } elseif ($selectedAddons.Count -gt 0) {
        # Specific addons requested: exclude those NOT selected
        $pathsToInclude = @()
        foreach ($addon in $selectedAddons) {
            if ($allAddonPaths.ContainsKey($addon)) {
                $pathsToInclude += $allAddonPaths[$addon]
            } else {
                Write-Log "[Addons] Warning: Unknown addon '$addon' - will be ignored" -Console
            }
        }

        # Exclude all addon paths NOT in the include list
        foreach ($addonPath in $allAddonPaths.Values) {
            if ($pathsToInclude -notcontains $addonPath) {
                $liteExclude += (Join-Path $kubePath $addonPath)
            }
        }

        # Exclude manifests for multi-implementation addons where no implementations are selected
        Add-UnselectedAddonManifestExclusions -KubePath $kubePath -AddonsRootPath $addonsRootPath `
            -SelectedAddons $selectedAddons -ExclusionListRef ([ref]$liteExclude)

        # Exclude test folders for NON-selected addons
        Add-TestFolderExclusions -KubePath $kubePath -SelectedAddons $selectedAddons `
            -ExclusionListRef ([ref]$liteExclude) -AllAddonPaths $allAddonPaths

        # Include test folders for selected addons
        $testAddonsPath = Join-Path $kubePath 'test/e2e/addons'
        if (Test-Path $testAddonsPath) {
            $testAddonDirs = Get-ChildItem -Path $testAddonsPath -Directory
            foreach ($testDir in $testAddonDirs) {
                $testDirName = $testDir.Name
                $shouldInclude = $false

                # Check if this test directory matches any selected addon
                foreach ($addon in $selectedAddons) {
                    # Extract base addon name (remove implementation suffix for multi-impl addons)
                    $addonBaseName = $addon
                    if ($addon -match '^(.+)\s+(.+)$') {
                        # Multi-implementation addon like "ingress nginx"
                        $addonBaseName = $matches[1]
                        $implName = $matches[2]

                        # Check if test dir matches base name or full implementation name
                        # e.g., "ingress" or "ingress-nginx" for "ingress nginx"
                        if ($testDirName -eq $addonBaseName -or
                            $testDirName -eq "$addonBaseName-$implName" -or
                            $testDirName -like "$addonBaseName*") {
                            $shouldInclude = $true
                            break
                        }
                    } else {
                        # Single-implementation addon
                        if ($testDirName -eq $addonBaseName -or $testDirName -like "$addonBaseName*") {
                            $shouldInclude = $true
                            break
                        }
                    }
                }

                if ($shouldInclude) {
                    $testDirFullPath = Join-Path $kubePath "test/e2e/addons/$testDirName"
                    $inclusionList += $testDirFullPath
                    Write-Log "[Addons] Including test folder for addon: test/e2e/addons/$testDirName" -Console
                }
            }
        }

        Write-Log "[Profile+Addons] Lite profile with selected addons: $($selectedAddons -join ', ')" -Console
    } else {
        # No addons list specified: include ALL addons and their tests (default behavior)
        Write-Log "[Profile] Lite profile: including all addons and addon tests (default)" -Console
    }

    foreach ($p in $liteExclude) {
        if (-not ($exclusionList -contains $p)) { $exclusionList += $p }
    }

    # Also ensure root-level compiled k2s.exe (if present) is kept
    $rootK2sExe = Join-Path $kubePath 'k2s.exe'
    if (Test-Path $rootK2sExe) { $inclusionList += $rootK2sExe }
    $rootK2sExeLicense = Join-Path $kubePath 'k2s.exe.license'
    if (Test-Path $rootK2sExeLicense) { $inclusionList += $rootK2sExeLicense }
} elseif ($excludeAllAddons) {
    # Dev profile with 'none': exclude addon subdirectories but keep root-level module files and common/
    # (addons.module.psm1, export.module.psm1, etc. are required for cluster operation;
    #  common/ contains shared manifests needed by individually imported addons)
    $addonsRootDir = Join-Path $kubePath 'addons'
    $addonSubDirs = Get-ChildItem -Path $addonsRootDir -Directory | Where-Object { $_.Name -ne 'common' }
    foreach ($dir in $addonSubDirs) {
        if (-not ($exclusionList -contains $dir.FullName)) { $exclusionList += $dir.FullName }
    }
    $testAddonsFullPath = Join-Path $kubePath 'test/e2e/addons'
    if (-not ($exclusionList -contains $testAddonsFullPath)) { $exclusionList += $testAddonsFullPath }
    Write-Log '[Addons] Dev profile: excluding all addons (keeping addons module files and common/)' -Console
} elseif ($selectedAddons.Count -gt 0) {
    Write-Log "[Addons] Dev profile with custom addon list: $($selectedAddons -join ', ')" -Console

    $pathsToInclude = @()
    foreach ($addon in $selectedAddons) {
        if ($allAddonPaths.ContainsKey($addon)) {
            $pathsToInclude += $allAddonPaths[$addon]
        } else {
            Write-Log "[Addons] Warning: Unknown addon '$addon' - will be ignored" -Console
        }
    }

    # Exclude all addon paths NOT in the include list
    foreach ($addonPath in $allAddonPaths.Values) {
        if ($pathsToInclude -notcontains $addonPath) {
            $fullPath = Join-Path $kubePath $addonPath
            if (-not ($exclusionList -contains $fullPath)) {
                $exclusionList += $fullPath
            }
        }
    }

    # Exclude manifests for multi-implementation addons where no implementations are selected
    Add-UnselectedAddonManifestExclusions -KubePath $kubePath -AddonsRootPath $addonsRootPath `
        -SelectedAddons $selectedAddons -ExclusionListRef ([ref]$exclusionList)

    # Exclude test folders for NON-selected addons
    Add-TestFolderExclusions -KubePath $kubePath -SelectedAddons $selectedAddons `
        -ExclusionListRef ([ref]$exclusionList) -AllAddonPaths $allAddonPaths
} else {
    # Dev profile with no addon list: include ALL addons (default behavior)
    Write-Log "[Addons] Dev profile: including all addons (default)" -Console
}

# if the zip package is to be used for offline installation then use existing base image and windows node artifacts file
# or create a new one for the one that does not exist.
# Otherwise include the base image and the Windows node artifacts file in the exclusion list

$controlPlaneBaseVhdxPath = Get-ControlPlaneVMBaseImagePath
$winNodeArtifactsZipFilePath = Get-WindowsNodeArtifactsZipFilePath
if ($ForOfflineInstallation) {
    # Provide windows parts
    if (Test-Path $winNodeArtifactsZipFilePath) {
        if ($K8sBinsPath -ne '') {
            Compress-WindowsNodeArtifactsWithLocalKubeTools -K8sBinsPath $K8sBinsPath
        }
        Write-Log "The already existing file '$winNodeArtifactsZipFilePath' will be used." -Console
    }
    else {
        try {
            Write-Log "The file '$winNodeArtifactsZipFilePath' does not exist. Creating it using proxy $Proxy ..." -Console
            Get-AndZipWindowsNodeArtifacts($winNodeArtifactsZipFilePath)
        }
        catch {
            Write-Log "Creation of file '$winNodeArtifactsZipFilePath' failed. Performing clean-up...Error: $_" -Console
            Invoke-DownloadsCleanup -DeleteFilesForOfflineInstallation $true

            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code 'build-package-failed' -Message $_
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }

            Write-Log $_ -Error
            exit 1
        }
    }

    # Provide linux parts
    if (Test-Path $controlPlaneBaseVhdxPath) {
        Write-Log "The already existing file '$controlPlaneBaseVhdxPath' will be used." -Console
    }
    else {
        try {
            Write-Log "The file '$controlPlaneBaseVhdxPath' does not exist. Creating it..." -Console
            New-ProvisionedKubemasterBaseImage -WindowsNodeArtifactsZip:$winNodeArtifactsZipFilePath -OutputPath:$controlPlaneBaseVhdxPath
        }
        catch {
            Write-Log "Creation of file '$controlPlaneBaseVhdxPath' failed. Performing clean-up... Error: $_" -Console
            Clear-ProvisioningArtifacts

            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code 'build-package-failed' -Message $_
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }

            Write-Log $_ -Error
            exit 1
        }
    }
}
else {
    $controlPlaneRootfsPath = Get-ControlPlaneVMRootfsPath
    $exclusionList += $controlPlaneBaseVhdxPath
    $exclusionList += $controlPlaneRootfsPath
    $exclusionList += $winNodeArtifactsZipFilePath
}

$kubenodeBaseVhdxPath = "$(Split-Path -Path $controlPlaneBaseVhdxPath)\Kubenode-Base.vhdx"
$exclusionList += $kubenodeBaseVhdxPath

# Ensure plink.exe and pscp.exe are available in bin folder for the package
$kubeBinPath = Get-KubeBinPath
$plinkPath = Join-Path $kubeBinPath 'plink.exe'
$pscpPath = Join-Path $kubeBinPath 'pscp.exe'

$puttytoolsResult = Ensure-PuttyToolsAvailable -PlinkPath $plinkPath -PscpPath $pscpPath `
    -IsOfflineInstallation $ForOfflineInstallation -WindowsNodeArtifactsZipPath $winNodeArtifactsZipFilePath `
    -Proxy $Proxy

if (-not $puttytoolsResult) {
    Write-Log "Warning: Could not ensure plink.exe and pscp.exe availability. Package may be incomplete." -Console
}

Write-Log 'Content of the exclusion list:' -Console
$exclusionList | ForEach-Object { " - $_ " } | Write-Log -Console

# Code signing logic (if requested)
if ($CertificatePath) {
    $signingResult = New-SignedPackage -KubePath $kubePath -ExclusionList $exclusionList `
        -CertificatePath $CertificatePath -Password $Password -ZipPackagePath $zipPackagePath `
        -ForOfflineInstallation $ForOfflineInstallation -WindowsNodeArtifactsZipFilePath $winNodeArtifactsZipFilePath `
        -EncodeStructuredOutput $EncodeStructuredOutput -MessageType $MessageType `
        -SelectedAddons $selectedAddons -AllAddonPaths $allAddonPaths

    if (-not $signingResult) {
        Write-Log "Code signing failed or was incomplete" -Error
        exit 1
    }
} else {
    Write-Log 'No code signing requested - creating standard package.' -Console

    # Filter addon manifests if custom addon selection
    if ($selectedAddons.Count -gt 0) {
        Write-Log 'Custom addon selection detected - creating temporary copy for manifest filtering...' -Console
        $tempPackagePath = Join-Path $env:TEMP "k2s-package-temp-$(Get-Random)"

        try {
            # Copy files to temp directory for manifest filtering
            $copiedCount = Copy-FilesForSigning -SourcePath $kubePath -DestinationPath $tempPackagePath `
                -ExclusionList $exclusionList -IsOfflineInstallation $ForOfflineInstallation

            if ($copiedCount -eq 0) {
                Write-Log "WARNING: No files were copied!" -Error
                exit 1
            }

            # Filter addon manifests in temp directory
            Update-AddonManifestsInPackage -PackageRootPath $tempPackagePath -SelectedAddons $selectedAddons -AllAddonPaths $allAddonPaths

            Write-Log 'Start creation of zip package from filtered files...' -Console
            New-ZipArchive -ExclusionList @() -BaseDirectory $tempPackagePath -TargetPath "$zipPackagePath"
        }
        finally {
            # Clean up temporary directory
            if (Test-Path $tempPackagePath) {
                Write-Log "Cleaning up temporary package directory..." -Console
                Remove-Item -Path $tempPackagePath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        # No filtering needed - create package directly from source
        Write-Log 'Start creation of zip package...' -Console
        New-ZipArchive -ExclusionList $exclusionList -BaseDirectory $kubePath -TargetPath "$zipPackagePath" -InclusionList $inclusionList
    }
}

Write-Log "Zip package available at '$zipPackagePath'." -Console

Write-Log 'Removing implicitly created K2s config dir'
Remove-Item -Path "$(Get-K2sConfigDir)" -Force -Recurse -ErrorAction SilentlyContinue

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
