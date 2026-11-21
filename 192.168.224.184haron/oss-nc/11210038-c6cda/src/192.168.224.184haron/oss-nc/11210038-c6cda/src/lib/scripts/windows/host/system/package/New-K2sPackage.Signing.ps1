# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# Code signing helper functions for New-K2sPackage.ps1

# Copy files to temporary directory for signing, excluding items from exclusion list
function Copy-FilesForSigning {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string[]]$ExclusionList,
        [bool]$IsOfflineInstallation
    )

    Write-Log "Creating temporary copy for signing to avoid file locking issues..." -Console
    Write-Log "Temporary signing directory: $DestinationPath" -Console

    New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null

    $filesToCopy = Get-ChildItem -Path $SourcePath -Force -Recurse
    $copiedCount = 0
    $skippedCount = 0

    foreach ($file in $filesToCopy) {
        $relativePath = $file.FullName.Replace("$SourcePath\", '')
        $targetPath = Join-Path $DestinationPath $relativePath

        # Skip files in exclusion list
        $shouldExclude = $false
        foreach ($exclusion in $ExclusionList) {
            if ($file.FullName.StartsWith($exclusion)) {
                $shouldExclude = $true
                $skippedCount++
                break
            }
        }

        if ($IsOfflineInstallation -and -not $shouldExclude) {
            # No additional exclusions - let Set-K2sFileSignature handle file type filtering
            Write-Log "Including file for potential signing: $($file.FullName)"
        }

        if (-not $shouldExclude) {
            if ($file.PSIsContainer) {
                New-Item -Path $targetPath -ItemType Directory -Force | Out-Null
            } else {
                $targetDir = Split-Path -Path $targetPath -Parent
                if (-not (Test-Path $targetDir)) {
                    New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
                }
                Copy-Item -Path $file.FullName -Destination $targetPath -Force
                $copiedCount++
            }
        }
    }

    Write-Log "Copied $copiedCount files/folders, skipped $skippedCount excluded items" -Console
    return $copiedCount
}

# Sign contents of offline installation ZIP artifacts
function Invoke-OfflineArtifactsSigning {
    param(
        [string]$TempSigningPath,
        [string]$WindowsNodeArtifactsZipFilePath,
        [string]$CertificatePath,
        [securestring]$SecurePassword
    )

    Write-Log 'Signing contents of offline installation ZIP files...' -Console

    # Sign Windows Node Artifacts ZIP contents
    $winArtifactsZipInTemp = Join-Path (Join-Path $TempSigningPath "bin") (Split-Path $WindowsNodeArtifactsZipFilePath -Leaf)
    if (-not (Test-Path $winArtifactsZipInTemp)) {
        Write-Log "Windows Node Artifacts ZIP not found in temp directory, skipping signing" -Console
        return
    }

    Write-Log "Signing contents of Windows Node Artifacts: $winArtifactsZipInTemp" -Console
    $winArtifactsExtractPath = Join-Path $TempSigningPath "win-artifacts-extract"

    try {
        # Extract the ZIP
        New-Item -Path $winArtifactsExtractPath -ItemType Directory -Force | Out-Null
        Expand-Archive -Path $winArtifactsZipInTemp -DestinationPath $winArtifactsExtractPath -Force

        # Sign contents
        Set-K2sFileSignature -SourcePath $winArtifactsExtractPath -CertificatePath $CertificatePath -Password $SecurePassword -ExclusionList @()

        # Remove old ZIP and create new one with signed contents
        Remove-Item -Path $winArtifactsZipInTemp -Force
        Compress-Archive -Path "$winArtifactsExtractPath\*" -DestinationPath $winArtifactsZipInTemp -CompressionLevel Optimal

        Write-Log "Windows Node Artifacts contents signed and repackaged." -Console
    }
    finally {
        if (Test-Path $winArtifactsExtractPath) {
            Remove-Item -Path $winArtifactsExtractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Log 'Offline installation ZIP contents signing completed.' -Console
}

# Create signed package with all code signing steps
# Note: This function requires $EncodeStructuredOutput, $MessageType, and New-ZipArchive
# to be available in the calling script's scope
function New-SignedPackage {
    param(
        [string]$KubePath,
        [string[]]$ExclusionList,
        [string]$CertificatePath,
        [string]$Password,
        [string]$ZipPackagePath,
        [bool]$ForOfflineInstallation,
        [string]$WindowsNodeArtifactsZipFilePath,
        [bool]$EncodeStructuredOutput,
        [string]$MessageType,
        [string[]]$SelectedAddons,
        [hashtable]$AllAddonPaths
    )

    Write-Log 'Code signing requested - signing executables and scripts...' -Console

    # Validate that Password is provided
    if ([string]::IsNullOrEmpty($Password)) {
        $errMsg = "Password is required when providing a certificate path."
        Write-Log $errMsg -Error

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'code-signing-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return $false
        }
        exit 1
    }

    # Convert string password to SecureString for internal use
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force

    # Create temporary directory for signing to avoid file locking issues
    $tempSigningPath = Join-Path $env:TEMP "k2s-package-signing-$(Get-Random)"

    try {
        # Copy files to temp directory
        $copiedCount = Copy-FilesForSigning -SourcePath $KubePath -DestinationPath $tempSigningPath `
            -ExclusionList $ExclusionList -IsOfflineInstallation $ForOfflineInstallation

        if ($copiedCount -eq 0) {
            Write-Log "WARNING: No files were copied for signing!" -Error
            return $false
        }

        # Filter addon manifests before signing (if applicable)
        Update-AddonManifestsInPackage -PackageRootPath $tempSigningPath -SelectedAddons $SelectedAddons -AllAddonPaths $AllAddonPaths

        # Sign files in temporary directory
        Write-Log "Signing all executables and PowerShell scripts with certificate: $CertificatePath" -Console
        Set-K2sFileSignature -SourcePath $tempSigningPath -CertificatePath $CertificatePath -Password $securePassword -ExclusionList @()
        Write-Log 'Code signing completed successfully.' -Console

        # For offline installation, sign contents of ZIP files
        if ($ForOfflineInstallation) {
            Invoke-OfflineArtifactsSigning -TempSigningPath $tempSigningPath `
                -WindowsNodeArtifactsZipFilePath $WindowsNodeArtifactsZipFilePath `
                -CertificatePath $CertificatePath -SecurePassword $securePassword
        }

        # Create ZIP package from signed files
        Write-Log 'Start creation of zip package from signed files...' -Console
        Write-Log "About to create ZIP with the following parameters:" -Console
        Write-Log "- Source directory: $tempSigningPath" -Console
        Write-Log "- Target ZIP: $ZipPackagePath" -Console

        # Check if temp directory has content
        $tempFiles = Get-ChildItem -Path $tempSigningPath -Recurse -Force
        Write-Log "Temp directory contains $($tempFiles.Count) items" -Console
        if ($tempFiles.Count -eq 0) {
            Write-Log "WARNING: Temp signing directory is empty!" -Error
            return $false
        }

        # Use signed files from temporary directory for ZIP creation
        New-ZipArchive -ExclusionList @() -BaseDirectory $tempSigningPath -TargetPath $ZipPackagePath

        return $true
    }
    catch {
        Write-Log "Error during code signing: $_" -Error
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = "Code signing failed: $_" }
        }
        return $false
    }
    finally {
        # Clean up temporary signing directory
        if (Test-Path $tempSigningPath) {
            Write-Log "Cleaning up temporary signing directory..." -Console
            Remove-Item -Path $tempSigningPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
