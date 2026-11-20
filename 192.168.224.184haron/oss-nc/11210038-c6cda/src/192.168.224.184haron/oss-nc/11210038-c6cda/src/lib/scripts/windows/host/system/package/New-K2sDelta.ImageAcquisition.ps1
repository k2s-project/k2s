# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
Helper functions for container image acquisition in delta packages.

.DESCRIPTION
Exports complete container images (tar files) for delta packages.
For Windows images, copies tar files from WindowsNodeArtifacts.zip.
For Linux images, exports complete OCI archives from buildah.
#>

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Exports changed container images for delta package.

.DESCRIPTION
Exports complete container image tar files that can be imported with k2s image import.
For Windows: copies tar files from bin\WindowsNodeArtifacts.zip\images\
For Linux: exports complete OCI archive from buildah in temporary VM.

.PARAMETER NewPackageRoot
Path to the extracted new package root directory.

.PARAMETER NewVhdxPath
Path to the new package's VHDX file.

.PARAMETER ChangedImages
Array of changed image objects from Compare-ContainerImages.

.PARAMETER StagingDir
Directory to stage extracted images.

.PARAMETER ExistingVmContext
Optional VM context from previous operations to reuse instead of creating new VM.

.PARAMETER ShowLogs
Show detailed logs.

.OUTPUTS
Hashtable with Success flag, ExtractedImages array, and statistics.
#>
function Export-ChangedImageLayers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NewPackageRoot,

        [Parameter(Mandatory = $true)]
        [string]$NewVhdxPath,

        [Parameter(Mandatory = $true)]
        [array]$ChangedImages,

        [Parameter(Mandatory = $true)]
        [string]$StagingDir,

        [Parameter(Mandatory = $false)]
        [PSCustomObject]$ExistingVmContext,

        [Parameter(Mandatory = $false)]
        [switch]$ShowLogs
    )

    $result = @{
        Success         = $false
        ExtractedLayers = @()
        TotalSize       = 0
        ErrorMessage    = ''
        FailedImages    = @()
    }

    if ($ChangedImages.Count -eq 0) {
        Write-Log "[ImageAcq] No changed images to process" -Console
        $result.Success = $true
        return $result
    }

    Write-Log "[ImageAcq] Exporting $($ChangedImages.Count) complete container images for delta package" -Console

    # Create staging directories
    $linuxImagesDir = Join-Path $StagingDir 'image-delta\linux\images'
    $windowsImagesDir = Join-Path $StagingDir 'image-delta\windows\images'

    New-Item -ItemType Directory -Path $linuxImagesDir -Force | Out-Null
    New-Item -ItemType Directory -Path $windowsImagesDir -Force | Out-Null

    $vmName = $null

    # Debug: Log all incoming images
    Write-Log "[ImageAcq] All ChangedImages received ($($ChangedImages.Count) total):" -Console
    foreach ($img in $ChangedImages) {
        Write-Log "[ImageAcq]   - $($img.FullName) (Platform: $($img.Platform))" -Console
    }

    try {
        # Process Windows images first (simple file copy from zip)
        # Use @() to ensure array result even with single/zero items
        $windowsImages = @($ChangedImages | Where-Object { $_.Platform -eq 'windows' })

        Write-Log "[ImageAcq] Filtered Windows images: $($windowsImages.Count)" -Console

        if ($windowsImages.Count -gt 0) {
            Write-Log "[ImageAcq] Processing $($windowsImages.Count) Windows images..." -Console
            Write-Log "[ImageAcq] NewPackageRoot: $NewPackageRoot" -Console
            Write-Log "[ImageAcq] WindowsImagesDir: $windowsImagesDir" -Console

            foreach ($imgChange in $windowsImages) {
                try {
                    Write-Log "[ImageAcq] Copying Windows image: $($imgChange.FullName)" -Console

                    $copyResult = Copy-WindowsImageFromPackage -NewPackageRoot $NewPackageRoot `
                                                                -ImageChange $imgChange `
                                                                -ImagesDir $windowsImagesDir `
                                                                -ShowLogs:$ShowLogs

                    Write-Log "[ImageAcq] Copy result: Success=$($copyResult.Success), Error=$($copyResult.ErrorMessage)" -Console

                    if ($copyResult.Success) {
                        $result.ExtractedLayers += $copyResult.ImageInfo
                        $result.TotalSize += $copyResult.Size
                        Write-Log "[ImageAcq] Successfully copied Windows image: $($imgChange.FullName)" -Console
                    } else {
                        Write-Log "[ImageAcq] Warning: Failed to copy Windows image $($imgChange.FullName): $($copyResult.ErrorMessage)" -Console
                        $result.FailedImages += $imgChange.FullName
                    }

                } catch {
                    Write-Log "[ImageAcq] Error processing Windows image $($imgChange.FullName): $_" -Console
                    $result.FailedImages += $imgChange.FullName
                }
            }
        }

        # Process Linux images (export from VM)
        # Use @() to ensure array result even with single/zero items
        $linuxImages = @($ChangedImages | Where-Object { $_.Platform -eq 'linux' })

        if ($linuxImages.Count -gt 0) {
            # Determine if we should use an existing VM or create a new one
            if ($ExistingVmContext) {
                Write-Log "[ImageAcq] Using existing VM for Linux image export: $($ExistingVmContext.VmName)" -Console
                $vmName = $ExistingVmContext.VmName
                $guestIp = $ExistingVmContext.GuestIp
                $switchName = $ExistingVmContext.SwitchName
                $natName = $ExistingVmContext.NatName
                $hostSwitchIp = $ExistingVmContext.HostSwitchIp
                $usingExistingVm = $true
            } else {
                Write-Log "[ImageAcq] Creating temporary VM for Linux image export..." -Console

                # Generate unique names for VM infrastructure
                $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $switchNameEnding = "imgdelta-$timestamp"
                $switchName = "k2s-sw-$switchNameEnding"
                $natName = "k2s-nat-$switchNameEnding"
                $vmName = "k2s-imgdelta-$switchNameEnding"

                # Network configuration
                $networkPrefix = '192.168.99.0'
                $prefixLen = 24
                $hostSwitchIp = '192.168.99.1'
                $guestIp = '192.168.99.10'
                $usingExistingVm = $false

                Write-Log "[ImageAcq] VM='$vmName', Switch='$switchName', GuestIP='$guestIp'" -Console
            }

            try {
                # Create VM infrastructure only if not reusing existing VM
                if (-not $usingExistingVm) {
                    # Create network
                    Write-Log "[ImageAcq] Creating VM network infrastructure..." -Console
                    $netCtx = New-K2sHvNetwork -SwitchName $switchName -NatName $natName -HostSwitchIp $hostSwitchIp -NetworkPrefix $networkPrefix -PrefixLen $prefixLen
                    if ($netCtx.SwitchName -ne $switchName) {
                        $switchName = $netCtx.SwitchName
                    }

                    # Create and start VM
                    New-K2sHvTempVm -VmName $vmName -VhdxPath $NewVhdxPath -SwitchName $switchName

                    # Wait for VM to be ready
                    if (-not (Wait-K2sHvGuestIp -Ip $guestIp -TimeoutSeconds 180)) {
                        throw "Guest IP $guestIp not reachable within timeout"
                    }
                    Write-Log "[ImageAcq] VM ready at $guestIp" -Console

                    # Wait for SSH to be ready
                    Write-Log "[ImageAcq] Waiting 60 seconds for SSH server to initialize..." -Console
                    Start-Sleep -Seconds 60
                }

                # Process each Linux image
                foreach ($imgChange in $linuxImages) {
                    try {
                        Write-Log "[ImageAcq] Exporting Linux image: $($imgChange.FullName)" -Console

                        $exportResult = Export-LinuxImageFromBuildah -GuestIp $guestIp `
                                                                      -ImageChange $imgChange `
                                                                      -ImagesDir $linuxImagesDir `
                                                                      -ShowLogs:$ShowLogs

                        if ($exportResult.Success) {
                            $result.ExtractedLayers += $exportResult.ImageInfo
                            $result.TotalSize += $exportResult.Size
                            Write-Log "[ImageAcq] Successfully exported Linux image: $($imgChange.FullName)" -Console
                        } else {
                            Write-Log "[ImageAcq] Warning: Failed to export Linux image $($imgChange.FullName): $($exportResult.ErrorMessage)" -Console
                            $result.FailedImages += $imgChange.FullName
                        }

                    } catch {
                        Write-Log "[ImageAcq] Error processing Linux image $($imgChange.FullName): $_" -Console
                        $result.FailedImages += $imgChange.FullName
                    }
                }

            } catch {
                $linuxVmError = $_
                Write-Log "[ImageAcq] Error setting up Linux VM: $linuxVmError" -Console
                # Mark all Linux images as failed
                foreach ($img in $linuxImages) {
                    $result.FailedImages += $img.FullName
                }
            } finally {
                # Cleanup VM and network infrastructure only if we created it
                if ($vmName -and -not $usingExistingVm) {
                    Write-Log "[ImageAcq] Cleaning up temporary VM infrastructure..." -Console

                    # Create cleanup context
                    $cleanupCtx = [pscustomobject]@{
                        VmName       = $vmName
                        SwitchName   = $switchName
                        NatName      = $natName
                        HostSwitchIp = $hostSwitchIp
                        CreatedVm    = $true
                    }

                    Remove-K2sHvEnvironment -Context $cleanupCtx
                }
            }
        }

        $result.Success = ($result.FailedImages.Count -eq 0)
        $totalSizeMB = [math]::Round($result.TotalSize / 1MB, 2)
        Write-Log "[ImageAcq] Image export complete. Exported: $($result.ExtractedLayers.Count) images, Total size: ${totalSizeMB} MB, Failed: $($result.FailedImages.Count)" -Console
        if (-not $result.Success) {
            $result.ErrorMessage = "Failed to export required image(s): $($result.FailedImages -join ', ')"
        }

    } catch {
        $result.ErrorMessage = "Exception during image export: $_"
        Write-Log $result.ErrorMessage -Console

    } finally {
        # No global cleanup needed here - VM cleanup handled above
    }

    return $result
}

<#
.SYNOPSIS
Copies a Windows container image tar from the package WindowsNodeArtifacts.zip.

.PARAMETER NewPackageRoot
Root directory of the extracted new package.

.PARAMETER ImageChange
Image change object containing image metadata.

.PARAMETER ImagesDir
Directory to store copied image tar file.

.OUTPUTS
Hashtable with Success flag, ImageInfo, Size, and ErrorMessage.
#>
function Copy-WindowsImageFromPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NewPackageRoot,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ImageChange,

        [Parameter(Mandatory = $true)]
        [string]$ImagesDir,

        [Parameter(Mandatory = $false)]
        [switch]$ShowLogs
    )

    $result = @{
        Success      = $false
        ImageInfo    = $null
        Size         = 0
        ErrorMessage = ''
    }

    try {
        $imageName = $ImageChange.FullName

        # Windows image tar filename format: registry.domain__repo__image_tag.tar
        # e.g., shsk2s.azurecr.io/pause-win:v1.8.0 -> shsk2s.azurecr.io__pause-win_v1.5.0.tar
        $sanitizedName = $imageName -replace '/', '__' -replace ':', '_'
        $sourceTarName = "$sanitizedName.tar"

        Write-Log "[ImageAcq] Looking for Windows image tar: $sourceTarName" -Console

        # Path to WindowsNodeArtifacts.zip
        $winArtifactsZip = Join-Path $NewPackageRoot 'bin\WindowsNodeArtifacts.zip'

        if (-not (Test-Path $winArtifactsZip)) {
            $result.ErrorMessage = "WindowsNodeArtifacts.zip not found at $winArtifactsZip"
            return $result
        }

        Write-Log "[ImageAcq] Opening WindowsNodeArtifacts.zip to extract $sourceTarName" -Console

        # Open zip and find the image tar
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($winArtifactsZip)

        try {
            # Look for the image in images/ folder
            $imageEntry = $zip.Entries | Where-Object {
                ($_.FullName -eq "images/$sourceTarName") -or ($_.FullName -eq "images\$sourceTarName")
            } | Select-Object -First 1

            if (-not $imageEntry) {
                # List available images for debugging
                $availableImages = $zip.Entries | Where-Object { $_.FullName -like 'images/*' } | Select-Object -ExpandProperty FullName
                Write-Log "[ImageAcq] Available images in zip: $($availableImages -join ', ')" -Console
                $result.ErrorMessage = "Image tar '$sourceTarName' not found in WindowsNodeArtifacts.zip images folder"
                return $result
            }

            Write-Log "[ImageAcq] Found image entry: $($imageEntry.FullName), size: $($imageEntry.Length)" -Console

            # Extract to destination
            $destTarPath = Join-Path $ImagesDir $sourceTarName
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($imageEntry, $destTarPath, $true)

            if (Test-Path $destTarPath) {
                $fileInfo = Get-Item $destTarPath
                $result.Size = $fileInfo.Length

                $result.ImageInfo = [PSCustomObject]@{
                    ImageName    = $imageName
                    Platform     = 'windows'
                    FilePath     = $destTarPath
                    RelativePath = "image-delta/windows/images/$sourceTarName"
                    Size         = $result.Size
                }

                $result.Success = $true
                $sizeMB = [math]::Round($result.Size / 1MB, 2)
                Write-Log "[ImageAcq] Windows image copied: ${sizeMB} MB" -Console
            } else {
                $result.ErrorMessage = "Failed to extract image tar to $destTarPath"
            }

        } finally {
            $zip.Dispose()
        }

    } catch {
        $result.ErrorMessage = "Exception during Windows image copy: $_"
        Write-Log $result.ErrorMessage -Console
    }

    return $result
}

<#
.SYNOPSIS
Exports a Linux container image from buildah as OCI archive tar.

.PARAMETER VmName
Name of the temporary VM.

.PARAMETER ImageChange
Image change object containing OldImage and NewImage.

.PARAMETER ImagesDir
Directory to store exported image tar file.

.OUTPUTS
Hashtable with Success flag, ImageInfo, Size, and ErrorMessage.
#>
function Export-LinuxImageFromBuildah {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GuestIp,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ImageChange,

        [Parameter(Mandatory = $true)]
        [string]$ImagesDir,

        [Parameter(Mandatory = $false)]
        [switch]$ShowLogs
    )

    $result = @{
        Success      = $false
        ImageInfo    = $null
        Size         = 0
        ErrorMessage = ''
    }

    try {
        # Get image ID - handle both Added (has .Image) and Changed (has .NewImage) cases
        $imageObj = if ($ImageChange.NewImage) { $ImageChange.NewImage } elseif ($ImageChange.Image) { $ImageChange.Image } else { $null }
        $newImageId = if ($imageObj) {
            if ($imageObj.ImageId) { $imageObj.ImageId }
            elseif ($imageObj.Id) { $imageObj.Id }
            else { $null }
        } else { $null }

        $imageName = $ImageChange.FullName

        Write-Log "[ImageAcq] Image object: $($imageObj | ConvertTo-Json -Compress -Depth 2 -ErrorAction SilentlyContinue)" -Console

        if ([string]::IsNullOrWhiteSpace($newImageId)) {
            # If we don't have an ID, try to use the image name directly with buildah
            Write-Log "[ImageAcq] No image ID found, using image name: $imageName" -Console
            $newImageId = $imageName
        }

        Write-Log "[ImageAcq] Exporting complete image as OCI archive: $imageName (ID: $newImageId)" -Console

        $sanitizedName = $imageName -replace '[/:]', '-'
        $remoteTarPath = "/tmp/delta-image-$sanitizedName.tar"
        $localTarPath = Join-Path $ImagesDir "$sanitizedName.tar"

        # Export image to tar (build command carefully to avoid PowerShell variable parsing issues)
        # Use longer timeout (600s = 10 min) for large images
        $ociArchivePath = "oci-archive:$remoteTarPath" + ":$imageName"
        $exportCmd = "sudo buildah push '$newImageId' $ociArchivePath 2>&1"
        $exportOutput = Invoke-K2sGuestCmd -GuestIp $GuestIp -Command $exportCmd -Timeout 600

        if (-not $exportOutput.Success) {
            $result.ErrorMessage = "Failed to export image: $($exportOutput.ErrorMessage)"

            # Cleanup remote tar
            Invoke-K2sGuestCmd -GuestIp $GuestIp -Command "sudo rm -f $remoteTarPath" -Timeout 10 | Out-Null
            return $result
        }

        Write-Log "[ImageAcq] Image exported, copying to host..." -Console

        # Copy tar from VM to host
        $copyResult = Copy-K2sGuestFile -GuestIp $GuestIp -RemotePath $remoteTarPath -LocalPath $localTarPath

        if (-not $copyResult.Success) {
            $result.ErrorMessage = "Failed to copy image tar: $($copyResult.ErrorMessage)"

            # Cleanup remote tar
            Invoke-K2sGuestCmd -GuestIp $GuestIp -Command "sudo rm -f $remoteTarPath" -Timeout 10 | Out-Null
            return $result
        }

        # Cleanup remote tar
        Invoke-K2sGuestCmd -GuestIp $GuestIp -Command "sudo rm -f $remoteTarPath" -Timeout 10 | Out-Null

        # Get file size
        if (Test-Path $localTarPath) {
            $fileInfo = Get-Item $localTarPath
            $result.Size = $fileInfo.Length

            $result.ImageInfo = [PSCustomObject]@{
                ImageName    = $imageName
                Platform     = 'linux'
                FilePath     = $localTarPath
                RelativePath = "image-delta/linux/images/$sanitizedName.tar"
                Size         = $result.Size
            }

            $result.Success = $true
            $sizeMB = [math]::Round($result.Size / 1MB, 2)
            Write-Log "[ImageAcq] Linux image exported: ${sizeMB} MB" -Console
        } else {
            $result.ErrorMessage = "Exported tar not found at expected path"
        }

    } catch {
        $result.ErrorMessage = "Exception during Linux image export: $_"
        Write-Log $result.ErrorMessage -Console
    }

    return $result
}
