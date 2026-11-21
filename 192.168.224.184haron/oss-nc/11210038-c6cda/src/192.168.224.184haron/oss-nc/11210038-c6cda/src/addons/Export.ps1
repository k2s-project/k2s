# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Export directory of addon')]
    [string] $ExportDir,
    [parameter(Mandatory = $false, HelpMessage = 'Export all addons')]
    [switch] $All,
    [parameter(Mandatory = $false, HelpMessage = 'Name of Addons to export')]
    [string[]] $Names,
    [parameter(Mandatory = $false, HelpMessage = 'Omit container images from export')]
    [switch] $OmitImages,
    [parameter(Mandatory = $false, HelpMessage = 'Omit packages (debian, linux, windows) from export')]
    [switch] $OmitPackages,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot\..\lib\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\lib\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../lib/modules/windows/node/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\addons.module.psm1"
$exportModule = "$PSScriptRoot\export.module.psm1"
$ociModule = "$PSScriptRoot\oci.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule, $exportModule, $ociModule

function New-CompatTemporaryFile {
    <#
    .SYNOPSIS
    Creates a temporary file object compatible with New-TemporaryFile usage
    #>
    $tempPath = [System.IO.Path]::GetTempFileName()
    return [PSCustomObject]@{
        FullName = $tempPath
    }
}

# Read K2s version for export metadata and file naming
$k2sVersion = Get-Content "$PSScriptRoot\..\VERSION" -Raw | ForEach-Object { $_.Trim() }

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$setupInfo = Get-SetupInfo
if ($setupInfo.LinuxOnly -eq $true) {
    $errMsg = 'Cannot export addons in Linux-only setup' 
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code ErrCodeWrongSetupType -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$tmpExportDir = "${ExportDir}\tmp-exported-addons"
Remove-Item -Force "$tmpExportDir" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
mkdir -Force "${tmpExportDir}\artifacts" | Out-Null

$ociMediaTypes = Get-OciMediaTypes

$addonManifests = @()
$allManifests = Find-AddonManifests -Directory $PSScriptRoot |`
    ForEach-Object { 
    $manifest = Get-FromYamlFile -Path $_ 
    $manifest | Add-Member -NotePropertyName 'path' -NotePropertyValue $_
    $dirPath = Split-Path -Path $_ -Parent
    $dirName = Split-Path -Path $dirPath -Leaf
    $manifest | Add-Member -NotePropertyName 'dir' -NotePropertyValue @{path = $dirPath; name = $dirName }
    $manifest
}

if ($All) {
    $addonManifests += $allManifests
}
else {    
    # Support both quoted ("ingress nginx") and unquoted (ingress nginx) multi-word addon names
    $i = 0
    while ($i -lt $Names.Count) {
        $name = $Names[$i]
        $foundManifest = $null
        
        $nameParts = $name -split '\s+'
        $addonName = $nameParts[0]
        $implementationName = if ($nameParts.Count -gt 1) { $nameParts[1] } else { $null }
        
        # Lookahead: treat next arg as implementation name if it's not a known addon
        if ($null -eq $implementationName -and ($i + 1) -lt $Names.Count) {
            $nextArg = $Names[$i + 1]
            $nextArgBase = ($nextArg -split '\s+')[0]
            $isAddonBaseName = $allManifests | Where-Object { $_.metadata.name -eq $nextArgBase } | Select-Object -First 1
            if ($null -eq $isAddonBaseName) {
                $implementationName = $nextArg
                $i++
            }
        }

        # Default implementation when none is specified, mirroring 'k2s addons enable storage' (-> smb)
        if ($null -eq $implementationName -and $addonName -eq 'storage') {
            $implementationName = 'smb'
        }

        foreach ($manifest in $allManifests) {
            if ($manifest.metadata.name -eq $addonName) {
                # Clone to prevent mutations when exporting multiple implementations
                $foundManifest = $manifest.PSObject.Copy()
                $foundManifest.spec = $manifest.spec.PSObject.Copy()

                if ($null -ne $implementationName) {
                    $foundManifest.spec.implementations = @($manifest.spec.implementations | Where-Object { $_.name -eq $implementationName })
                }
                break
            }
        }

        if ($null -eq $foundManifest) {
            $errMsg = "no addon with name '$addonName' found"
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Severity Warning -Code ErrCodeAddonNotFound -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }
        
            Write-Log $errMsg -Error
            exit 1
        }

        $addonManifests += $foundManifest
        $i++
    }
}

$windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
$Proxy = "http://$($windowsHostIpAddress):8181"

$currentHttpProxy = $env:http_proxy
$currentHttpsProxy = $env:https_proxy

try {
    $env:http_proxy = $Proxy
    $env:https_proxy = $Proxy

    # Create OCI Image Layout structure at artifacts root
    $artifactsRoot = Join-Path $tmpExportDir 'artifacts'
    New-OciLayoutFile -LayoutPath $artifactsRoot
    $blobsDir = New-OciBlobsDirectory -LayoutPath $artifactsRoot

    $addonManifestReferences = @()

    foreach ($manifest in $addonManifests) {
        foreach ($implementation in $manifest.spec.implementations) {
            # there are more than one implementation
            $addonName = $manifest.metadata.name
            $dirName = $manifest.dir.name
            $dirPath = $manifest.dir.path
            if ($implementation.name -ne $addonName) {
                $addonName += " $($implementation.name)"
                $dirName += "-$($implementation.name)"
                $dirPath = Join-Path -Path $($manifest.dir.path) -ChildPath $($implementation.name)
            }

             $addonFolderName = ($addonName -split '\s+') -join '-'

             # Destination path for OCI artifact: $tmpExportDir\artifacts\ingress-nginx
             $artifactPath = Join-Path -Path $tmpExportDir -ChildPath "artifacts\$addonFolderName"

             if (-not (Test-Path $artifactPath)) {
                 New-Item -ItemType Directory -Path $artifactPath -Force | Out-Null
             }

             # Create staging directories for OCI layers
             $configStaging = Join-Path $artifactPath 'config-staging'
             $manifestsStaging = Join-Path $artifactPath 'manifests-staging'
             $scriptsStaging = Join-Path $artifactPath 'scripts-staging'
             $packagesStaging = Join-Path $artifactPath 'packages-staging'
             $imagesStaging = Join-Path $artifactPath 'images-staging'
             
             New-Item -ItemType Directory -Path $configStaging -Force | Out-Null
             New-Item -ItemType Directory -Path $manifestsStaging -Force | Out-Null
             New-Item -ItemType Directory -Path $scriptsStaging -Force | Out-Null
             New-Item -ItemType Directory -Path $packagesStaging -Force | Out-Null
             New-Item -ItemType Directory -Path $imagesStaging -Force | Out-Null

             $sourceManifestsDir = Join-Path $dirPath 'manifests'
             if (Test-Path $sourceManifestsDir) {
                 $manifestFiles = @(Get-ChildItem -Path $sourceManifestsDir -Recurse -File)
                 Write-Log "Copying $($manifestFiles.Count) files from addon manifests directory"
                 Copy-Item -Path (Join-Path $sourceManifestsDir '*') -Destination $manifestsStaging -Recurse -Force -ErrorAction SilentlyContinue
             } else {
                 Write-Log "No manifests directory found at $sourceManifestsDir"
             }

             if ($manifest.metadata.name -eq 'storage' -and $implementation.name -eq 'ceph') {
                 $sharedSmbSourceDir = Join-Path $manifest.dir.path 'smb\manifests'
                 if (Test-Path $sharedSmbSourceDir) {
                     $sharedSmbDestDir = Join-Path $manifestsStaging 'smb-shared'
                     $sharedSmbFiles = @(Get-ChildItem -Path $sharedSmbSourceDir -Recurse -File)
                     Write-Log "Copying $($sharedSmbFiles.Count) shared SMB manifest files into Ceph export fallback bundle"
                     New-Item -ItemType Directory -Path $sharedSmbDestDir -Force | Out-Null
                     Copy-Item -Path (Join-Path $sharedSmbSourceDir '*') -Destination $sharedSmbDestDir -Recurse -Force -ErrorAction SilentlyContinue
                 }
                 else {
                     Write-Log "Warning: shared SMB manifests not found at $sharedSmbSourceDir while exporting storage ceph" -Console
                 }
             }

             # Inject gitops-sync/ Job template into manifests layer for GitOps delivery.
             $gitopsSyncSource = Join-Path $PSScriptRoot 'common\manifests\addon-sync\gitops-sync'
             Write-Log "Checking for gitops-sync source at: $gitopsSyncSource"
             
             if (Test-Path $gitopsSyncSource) {
                 $gitopsSyncDest = Join-Path $manifestsStaging 'gitops-sync'
                 New-Item -ItemType Directory -Path $gitopsSyncDest -Force | Out-Null
                 
                 $gitopsSyncFiles = @(Get-ChildItem -Path $gitopsSyncSource -File)
                 Write-Log "Found $($gitopsSyncFiles.Count) gitops-sync files to inject"
                 Copy-Item -Path (Join-Path $gitopsSyncSource '*') -Destination $gitopsSyncDest -Recurse -Force

                 # Replace the timestamp placeholder with the actual export timestamp
                 $exportTimestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'
                 $syncJobPath = Join-Path $gitopsSyncDest 'sync-job.yaml'
                 if (Test-Path $syncJobPath) {
                     $content = [System.IO.File]::ReadAllText($syncJobPath, [System.Text.Encoding]::UTF8)
                     $content = $content -replace 'EXPORT_TIMESTAMP_PLACEHOLDER', $exportTimestamp
                     $content = $content -replace 'ADDON_NAME_PLACEHOLDER', $addonFolderName
                     [System.IO.File]::WriteAllText($syncJobPath, $content, [System.Text.UTF8Encoding]::new($false))
                     Write-Log "Injected gitops-sync Job template with timestamp $exportTimestamp and addon name $addonFolderName" -Console
                 } else {
                     Write-Log "Warning: sync-job.yaml not found at $syncJobPath" -Console
                 }
             } else {
                 Write-Log "Warning: gitops-sync source directory not found at $gitopsSyncSource" -Console
             }

             $readmePath = Join-Path $dirPath 'README.md'
             if (Test-Path $readmePath) {
                 Copy-Item -Path $readmePath -Destination $scriptsStaging -Force
             }

             @('*.ps1', '*.psm1','*.sh') | ForEach-Object {
                 Get-ChildItem -Path $dirPath -Filter $_ -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                     $relativePath = $_.FullName.Substring($dirPath.Length + 1)
                     $targetPath = Join-Path $scriptsStaging $relativePath
                     $targetDir = Split-Path $targetPath -Parent

                     if (-not (Test-Path $targetDir)) {
                         New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                     }

                     Copy-Item -Path $_.FullName -Destination $targetPath -Force
                 }
             }
             
             @('*.png', '*.jpg', '*.jpeg', '*.gif', '*.svg', '*.drawio', '*.drawio.png', '*.md', '*.ndjson', '*.json', '*.license', 'Dockerfile*') | ForEach-Object {
                 Get-ChildItem -Path $dirPath -Filter $_ -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                     if ($_.Name -ne 'README.md') {
                         $relativePath = $_.FullName.Substring($dirPath.Length + 1)
                         $targetPath = Join-Path $scriptsStaging $relativePath
                         $targetDir = Split-Path $targetPath -Parent
                         
                         if (-not (Test-Path $targetDir)) {
                             New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                         }
                         
                         Copy-Item -Path $_.FullName -Destination $targetPath -Force
                         Write-Log "Copying documentation asset: $relativePath"
                     }
                 }
             }

            # Handle addon.manifest.yaml and collect configuration files into config layer
            $manifestFile = $null
            if ($implementation.name -ne $manifest.metadata.name) {
                $parentAddonFolder = Split-Path -Path $dirPath -Parent
                $manifestFile = Join-Path $parentAddonFolder "addon.manifest.yaml"
            } else {
                $manifestFile = Join-Path $dirPath "addon.manifest.yaml"
            }
            
            if ($manifestFile -and (Test-Path $manifestFile)) {
                $configManifestPath = Join-Path $configStaging "addon.manifest.yaml"
                
                # For single implementation exports
                if (-not $All -and $Names.Count -eq 1 -and $implementation.name -ne $manifest.metadata.name) {
                    $kubeBinPath = Get-KubeBinPath
                    $yqExe = Join-Path $kubeBinPath "windowsnode\yaml\yq.exe"
                    
                    try {
                        Copy-Item -Path $manifestFile -Destination $configManifestPath -Force
                        
                        $tempFilterFile = New-CompatTemporaryFile
                        $filterContent = ".spec.implementations |= [.[] | select(.name == `"$($implementation.name)`")]"
                        Set-Content -Path $tempFilterFile.FullName -Value $filterContent -Encoding ASCII
                        
                        & $yqExe eval --from-file $tempFilterFile.FullName --inplace $configManifestPath
                        
                        Write-Log "Filtered manifest for single implementation: $($implementation.name)" -Console
                        Remove-Item -Path $tempFilterFile.FullName -Force -ErrorAction SilentlyContinue
                    } catch {
                        Write-Log "Failed to filter manifest with yq.exe (Path: $yqExe), falling back to copy: $_" -Console
                        Copy-Item -Path $manifestFile -Destination $configManifestPath -Force
                    }
                } else {
                    # For all exports or single implementation addons, copy original manifest
                    Copy-Item -Path $manifestFile -Destination $configManifestPath -Force
                }
            } else {
                Write-Log "Warning: addon.manifest.yaml not found for $addonName"
            }
            
            # Collect additional configuration files into config layer
            # Look for values.yaml, settings.json, config files in addon directory
            $configFilePatterns = @('values.yaml', 'values-*.yaml', 'settings.json', '*.config.json', '*.config.yaml')
            foreach ($pattern in $configFilePatterns) {
                Get-ChildItem -Path $dirPath -Filter $pattern -File -ErrorAction SilentlyContinue | ForEach-Object {
                    Copy-Item -Path $_.FullName -Destination $configStaging -Force
                    Write-Log "Added config file to config layer: $($_.Name)"
                }
            }
            
            # Look for config subdirectory
            $configSubDir = Join-Path $dirPath 'config'
            if (Test-Path $configSubDir) {
                $configSubDirDest = Join-Path $configStaging 'config'
                New-Item -ItemType Directory -Path $configSubDirDest -Force | Out-Null
                Copy-Item -Path (Join-Path $configSubDir '*') -Destination $configSubDirDest -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Added config subdirectory to config layer"
            }
            
            # Look for specific addon config files (like orthanc.json for dicom)
            $addonSpecificConfigs = Get-ChildItem -Path $dirPath -Recurse -Include '*.json' -File -ErrorAction SilentlyContinue | 
                Where-Object { 
                    $_.Name -notmatch '^(package|tsconfig|eslint|babel)' -and
                    $_.Directory.Name -eq $manifest.metadata.name -and
                    (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -notmatch '"apiVersion"\s*:\s*"'
                }
            foreach ($configFile in $addonSpecificConfigs) {
                Copy-Item -Path $configFile.FullName -Destination $configStaging -Force
                Write-Log "Added addon-specific config file to config layer: $($configFile.Name)"
            }

            # Add version information as OCI annotations (stored in oci-manifest.json)
            Write-Log "Preparing OCI artifact for addon $addonName" -Console
            
            if ($OmitImages) {
                Write-Log "Omitting container images for addon $addonName (--omit-images)" -Console
            } else {
            Write-Log "Pulling images for addon $addonName from $dirPath" -Console

            Write-Log '---'
            $images = @()
            $linuxImages = @()
            $windowsImages = @()
            $files = Get-Childitem -recurse $dirPath | Where-Object { $_.Name -match '.*.yaml$' } | ForEach-Object { $_.Fullname }

            # check if there is a subfolder called chart for helm charts
            if (Test-Path -Path "$dirPath\manifests\chart") {
                $charts = Get-Childitem -recurse "$dirPath\manifests\chart" | Where-Object { $_.Name -match '.*.tgz$' } | ForEach-Object { $_.Fullname }
                if ($null -eq $charts -or $charts.Count -eq 0) {
                    Write-Log "No images found for addon $addonName in form of an chart"
                } else {
                    Write-Log "Found images for addon $addonName in form of an chart, count: $($charts.Count)"
                    # ensure only one entry in the list
                    $charts = $charts | Select-Object -Unique
                    foreach ($chart in $charts) {
                        # extracting yaml files from the helm chart
                        $chartFolder = "${tmpExportDir}\helm\$dirName"
                        mkdir -Force $chartFolder | Out-Null
                        # extracting yaml files from the helm chart
                        $valuesFile = "$dirPath\manifests\chart\values.yaml"
                        # extract release from chart file name by removing the .tgz extension and the version
                        # from kubernetes-dashboard-x.x.x.tgz -> kubernetes-dashboard
                        $chartNameParts = [System.IO.Path]::GetFileNameWithoutExtension($chart).Split('-')
                        $release = $chartNameParts[0..($chartNameParts.Length - 2)] -join '-'

                        if ((Test-Path -Path $valuesFile)) {
                            (Invoke-Helm -Params 'template', $release, $chart, '-f', $valuesFile, '--output-dir', $chartFolder).Output | Write-Log 
                        } else {
                            (Invoke-Helm -Params 'template', $release, $chart, '--output-dir', $chartFolder).Output | Write-Log 
                        }
                        $files += Get-Childitem -recurse $chartFolder | Where-Object { $_.Name -match '.*.yaml$' } | ForEach-Object { $_.Fullname }
                    }
                }
            }

            foreach ($file in $files) {
                if ($null -ne (Select-String -Path $file -Pattern '## exclude-from-export')) {
                    continue
                }

                $imageLines = Get-Content $file | Select-String 'image:' | Select-Object -ExpandProperty Line
                foreach ($imageLine in $imageLines) {
                    if ($imageLine.TrimStart() -match '^#') {
                        continue
                    }
                    
                    $image = (($imageLine -split 'image: ')[1] -split '#')[0]
                    $parts = $image.Split(':')
                    if ($parts.Count -gt 1) {
                        Write-Log "Image is valid $image"
                    } else {
                        Write-Log "Image is not valid $image, will skip it"
                        continue
                    }
                    if ($imageLine.Contains('#windows_image')) {
                        $windowsImages += $image
                    }
                    else {
                        $linuxImages += $image
                    }
                }
            }

            # Process addon.manifest.yaml offline_usage section for image declarations
            if ($null -ne $implementation.offline_usage) {
                $linuxPackages = $implementation.offline_usage.linux
                
                # Collect Linux-only images from additionalImages
                if ($linuxPackages.additionalImages) {
                    $linuxImages += $linuxPackages.additionalImages
                }
                
                # Extract images from referenced YAML manifest files (e.g., deployment.yaml)
                if ($linuxPackages.additionalImagesFiles) {
                    $linuxImages += Get-ImagesFromYamlFiles -YamlFiles $linuxPackages.additionalImagesFiles -BaseDirectory $dirPath
                }

                # Collect Windows-specific images from additionalImages
                $windowsPackages = $implementation.offline_usage.windows
                if ($null -ne $windowsPackages -and $windowsPackages.additionalImages) {
                    $windowsImages += $windowsPackages.additionalImages
                }
                
                # Extract Windows images from referenced YAML manifest files (e.g., daemonset.yaml)
                if ($null -ne $windowsPackages -and $windowsPackages.additionalImagesFiles) {
                    $windowsImages += Get-ImagesFromYamlFiles -YamlFiles $windowsPackages.additionalImagesFiles -BaseDirectory $dirPath
                }
            }

            $linuxImages = $linuxImages | Select-Object -Unique | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim("`"'").Trim(' ') }
            $linuxImages = Remove-VersionlessImages -Images $linuxImages
            $windowsImages = $windowsImages | Select-Object -Unique | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim("`"'").Trim(' ') }
            $windowsImages = Remove-VersionlessImages -Images $windowsImages
            $images += $linuxImages
            $images += $windowsImages
            $images = $images | Select-Object -Unique

            Write-Log "[AddonExport] === IMAGE LISTS AFTER PROCESSING ==="
            Write-Log "[AddonExport] Linux images to pull ($($linuxImages.Count)):"
            foreach ($img in $linuxImages) { Write-Log "[AddonExport]   - $img" }
            Write-Log "[AddonExport] Windows images to pull ($($windowsImages.Count)):"
            foreach ($img in $windowsImages) { Write-Log "[AddonExport]   - $img" }
            Write-Log "[AddonExport] Total unique images ($($images.Count)):"
            foreach ($img in $images) { Write-Log "[AddonExport]   - $img" }

            mkdir -Force "${tmpExportDir}\addons\$dirName" | Out-Null

            Write-Log "[AddonExport] === PULLING LINUX IMAGES ==="
            foreach ($image in $linuxImages) {
                Write-Log "Pulling linux image $image"
                $pull = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -Retries 5 -CmdToExecute "sudo buildah pull $image 2>&1"
                Write-Log "[AddonExport] Pull result for $image : Success=$($pull.Success) Output='$($pull.Output)'"
                Write-Log $pull.Output
                if (!$pull.Success) {
                    $errMsg = "Pulling linux image $image failed"
                    if ($EncodeStructuredOutput -eq $true) {
                        $err = New-Error -Severity Warning -Code ErrCodeAddonNotFound -Message $errMsg
                        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                        return
                    }
                
                    Write-Log $errMsg -Error
                    exit 1
                }
            }

            foreach ($image in $windowsImages) {
                Write-Log "Pulling windows image $image"
                $kubeBinPath = Get-KubeBinPath
                &$(Get-NerdctlExe) -n 'k8s.io' pull $image --all-platforms 2>&1 | Out-Null
                &$(Get-CrictlExe) --config $kubeBinPath\crictl.yaml pull $image
                if (!$?) {
                    $errMsg = "Pulling linux image $image failed"
                    if ($EncodeStructuredOutput -eq $true) {
                        $err = New-Error -Severity Warning -Code ErrCodeAddonNotFound -Message $errMsg
                        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                        return
                    }
                    
                    Write-Log $errMsg -Error
                    exit 1
                }
            }

            if ($images.Count -gt 0) {
                Write-Log '---'
                Write-Log "Images pulled successfully for addon $addonName"
                Write-Log '---'

                $linuxContainerImages = Get-ContainerImagesOnLinuxNode -IncludeK8sImages $false
                $windowsContainerImages = Get-ContainerImagesOnWindowsNode -IncludeK8sImages $false

                Write-Log "Exporting images for addon $addonName" -Console
                Write-Log "[AddonExport] Found $($linuxContainerImages.Count) linux container images, $($windowsContainerImages.Count) windows container images"
                foreach ($img in $linuxContainerImages) {
                    Write-Log "[AddonExport] Linux image: Repository='$($img.Repository)' Tag='$($img.Tag)' ImageId='$($img.ImageId)'"
                }

                $linuxImageTars = @()
                $windowsImageTars = @()
                
                foreach ($image in $images) {
                    Write-Log $image
                    $imageNameWithoutTag = ($image -split ':')[0]
                    $imageTag = ($image -split ':')[1]
                    Write-Log "[AddonExport] Looking for: imageNameWithoutTag='$imageNameWithoutTag' imageTag='$imageTag'"
                    Write-Log "[AddonExport] Regex pattern: '.*${imageNameWithoutTag}$'"
                    
                    # Test regex matching manually for debugging
                    foreach ($testImg in $linuxContainerImages) {
                        $repoMatch = $testImg.Repository -match ".*${imageNameWithoutTag}$"
                        $tagMatch = $testImg.Tag -eq $imageTag
                        if ($repoMatch -or $tagMatch) {
                            Write-Log "[AddonExport] Testing against: Repository='$($testImg.Repository)' Tag='$($testImg.Tag)' -> RepoMatch=$repoMatch TagMatch=$tagMatch"
                        }
                    }
                    
                    $linuxImageToExportArray = @($linuxContainerImages | Where-Object { $_.Repository -match ".*${imageNameWithoutTag}$" -and $_.Tag -eq $imageTag })
                    $windowsImageToExportArray = @($windowsContainerImages | Where-Object { $_.Repository -match ".*${imageNameWithoutTag}$" -and $_.Tag -eq $imageTag })
                    Write-Log "[AddonExport] Matched linux images: $($linuxImageToExportArray.Count), windows images: $($windowsImageToExportArray.Count)"
                    
                    if ($linuxImageToExportArray.Count -eq 0 -and $windowsImageToExportArray.Count -eq 0) {
                        Write-Log "[AddonExport] WARNING: No matching images found for '$image' - image will NOT be exported!"
                    }
                    $exportImageScript = "$PSScriptRoot\..\lib\scripts\windows\host\image\Export-Image.ps1"
                    
                    if ($linuxImageToExportArray -and $linuxImageToExportArray.Count -gt 0) {
                        $imageToExport = $linuxImageToExportArray[0]
                        # Create meaningful tar filename from image name (shared sanitizer, see oci.module.psm1)
                        $linuxImageTarPath = Join-Path $imagesStaging (ConvertTo-ImageTarFileName -Image $image)
                        &$exportImageScript -Id $imageToExport.ImageId -ExportPath $linuxImageTarPath -ShowLogs:$ShowLogs

                        if (!$?) {
                            $errMsg = "Image $imageNameWithoutTag could not be exported."
                            if ($EncodeStructuredOutput -eq $true) {
                                $err = New-Error -Code 'image-not-exported' -Message $errMsg
                                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                                return
                            }
                        
                            Write-Log $errMsg -Error
                            exit 1
                        }
                        $linuxImageTars += $linuxImageTarPath
                    }

                    if ($windowsImageToExportArray -and $windowsImageToExportArray.Count -gt 0) {
                        $imageToExport = $windowsImageToExportArray[0]
                        # Create meaningful tar filename from image name (shared sanitizer, see oci.module.psm1)
                        $windowsImageTarPath = Join-Path $imagesStaging (ConvertTo-ImageTarFileName -Image $image -Windows)
                        &$exportImageScript -Id $imageToExport.ImageId -ExportPath $windowsImageTarPath -ShowLogs:$ShowLogs

                        if (!$?) {
                            $errMsg = "Image $imageNameWithoutTag could not be exported!"
                            if ($EncodeStructuredOutput -eq $true) {
                                $err = New-Error -Code 'image-not-exported' -Message $errMsg
                                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                                return
                            }
                        
                            Write-Log $errMsg -Error
                            exit 1
                        }
                        $windowsImageTars += $windowsImageTarPath
                    }
                }
                
                # Consolidate Linux images into single tar layer
                if ($linuxImageTars.Count -gt 0) {
                    Write-Log "Consolidating $($linuxImageTars.Count) Linux images into single layer"
                    $linuxImagesLayerPath = Join-Path $artifactPath 'images-linux.tar'
                    
                    # creating a consolidated tar (even for single image) to maintain consistent structure
                    New-TarArchive -SourceFiles $linuxImageTars -DestinationPath $linuxImagesLayerPath -WorkingDirectory $imagesStaging
                }
                
                # Consolidate Windows images into single tar layer
                if ($windowsImageTars.Count -gt 0) {
                    Write-Log "Consolidating $($windowsImageTars.Count) Windows images into single layer"
                    $windowsImagesLayerPath = Join-Path $artifactPath 'images-windows.tar'
                    
                    # creating a consolidated tar (even for single image) to maintain consistent structure
                    New-TarArchive -SourceFiles $windowsImageTars -DestinationPath $windowsImagesLayerPath -WorkingDirectory $imagesStaging
                }
            }
            else {
                Write-Log "No images found for addon $addonName"
            }
            } 

            if ($null -ne $implementation.offline_usage -and -not $OmitPackages) {
                Write-Log '---'
                Write-Log "Downloading packages for addon $addonName" -Console
                $linuxPackages = $implementation.offline_usage.linux

                # adding repos for debian packages download
                $repos = $linuxPackages.repos
                if ($repos) {
                    Write-Log 'Adding repos for debian packages download'
                    foreach ($repo in $repos) {
                        $repoWithReplacedHttpProxyPlaceHolder = $repo.Replace('__LOCAL_HTTP_PROXY__', "$(Get-ConfiguredKubeSwitchIP):8181")
                        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "$repoWithReplacedHttpProxyPlaceHolder").Output | Write-Log
                    }

                    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt-get update > /dev/null 2>&1').Output | Write-Log
                }

                # download debian packages
                $debianPackages = $linuxPackages.deb
                if ($debianPackages) {
                    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt-get clean > /dev/null 2>&1').Output | Write-Log
                    foreach ($package in $debianPackages) {
                        if (!(Get-DebianPackageAvailableOffline -addon $manifest.metadata.name -implementation $implementation.name -package $package)) {
                            Write-Log "Downloading debian package `"$package`" with dependencies"
                            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo DEBIAN_FRONTEND=noninteractive apt-get --download-only reinstall -y $package > /dev/null 2>&1").Output | Write-Log
                            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "mkdir -p .$dirName/${package}").Output | Write-Log
                            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo cp /var/cache/apt/archives/*.deb .$dirName/${package}").Output | Write-Log
                            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt-get clean > /dev/null 2>&1').Output | Write-Log
                        }
                    }

                    $targetDebianPkgDir = "${packagesStaging}\debianpackages"

                    mkdir -Force $targetDebianPkgDir | Out-Null
                    Copy-FromControlPlaneViaSSHKey -Source ".$dirName/*" -Target $targetDebianPkgDir
                }

                # download linux packages via curl
                $linuxCurlPackages = $linuxPackages.curl
                if ($linuxCurlPackages) {
                    $targetLinuxPkgDir = "${packagesStaging}\linuxpackages"
                    mkdir -Force $targetLinuxPkgDir | Out-Null

                    foreach ($package in $linuxCurlPackages) {
                        $filename = ([uri]$package.url).Segments[-1]

                        Invoke-DownloadFile "$targetLinuxPkgDir\${filename}" $package.url $true -ProxyToUse $Proxy
                    }
                }

                # download windows packages via curl
                $windowsPackages = $implementation.offline_usage.windows
                $windowsCurlPackages = $windowsPackages.curl
                if ($windowsCurlPackages) {
                    $targetWinPkgDir = "${packagesStaging}\windowspackages"
                    mkdir -Force $targetWinPkgDir | Out-Null
                    foreach ($package in $windowsCurlPackages) {
                        $filename = ([uri]$package.url).Segments[-1]

                        Invoke-DownloadFile "$targetWinPkgDir\${filename}" $package.url $true -ProxyToUse $Proxy
                    }
                }
            }
            elseif ($OmitPackages) {
                Write-Log "Omitting packages for addon $addonName (--omit-packages)" -Console
            }

            Write-Log "Creating OCI artifact layers for $addonName" -Console
            
            $ociLayerDescriptors = @()
            
            # Layer 0: Configuration files (addon.manifest.yaml, values.yaml, settings.json, etc.) - store in blobs
            if ((Get-ChildItem $configStaging -ErrorAction SilentlyContinue).Count -gt 0) {
                $configTarPath = Join-Path $artifactPath 'config.tar.gz'
                if (New-TarGzArchive -SourcePath $configStaging -DestinationPath $configTarPath -ArchiveContents) {
                    $blobResult = Add-ContentToBlobs -BlobsDir $blobsDir -SourcePath $configTarPath -Move
                    $ociLayerDescriptors += @{
                        mediaType = $ociMediaTypes.ConfigFiles
                        size = $blobResult.Size
                        digest = $blobResult.Digest
                        annotations = @{ 'org.opencontainers.image.title' = 'config.tar.gz' }
                    }
                    Write-Log "Created config files layer: $($blobResult.Digest)"
                }
            }
            
            # Layer 1: Manifests - store in blobs
            $manifestsStageCount = (Get-ChildItem $manifestsStaging -ErrorAction SilentlyContinue).Count
            Write-Log "Manifests staging directory contains $manifestsStageCount items"
            
            if ($manifestsStageCount -gt 0) {
                $manifestsTarPath = Join-Path $artifactPath 'manifests.tar.gz'
                $tarCreated = New-TarGzArchive -SourcePath $manifestsStaging -DestinationPath $manifestsTarPath -ArchiveContents
                
                if ($tarCreated) {
                    $blobResult = Add-ContentToBlobs -BlobsDir $blobsDir -SourcePath $manifestsTarPath -Move
                    $ociLayerDescriptors += @{
                        mediaType = $ociMediaTypes.Manifests
                        size = $blobResult.Size
                        digest = $blobResult.Digest
                        annotations = @{ 'org.opencontainers.image.title' = 'manifests.tar.gz' }
                    }
                    Write-Log "Created manifests layer: $($blobResult.Digest)"
                } else {
                    Write-Log "Warning: New-TarGzArchive returned false for manifests layer" -Console
                }
            } else {
                # Create empty manifests layer
                Write-Log "Creating empty manifests layer (no content in staging directory)" -Console
                $manifestsTarPath = Join-Path $artifactPath 'manifests.tar.gz'
                
                # Create minimal tar.gz with empty directory structure
                $emptyManifestDir = Join-Path $artifactPath 'empty-manifest-temp'
                New-Item -ItemType Directory -Path $emptyManifestDir -Force | Out-Null
                
                if (New-TarGzArchive -SourcePath $emptyManifestDir -DestinationPath $manifestsTarPath -ArchiveContents) {
                    Remove-Item -Path $emptyManifestDir -Recurse -Force -ErrorAction SilentlyContinue
                    $blobResult = Add-ContentToBlobs -BlobsDir $blobsDir -SourcePath $manifestsTarPath -Move
                    $ociLayerDescriptors += @{
                        mediaType = $ociMediaTypes.Manifests
                        size = $blobResult.Size
                        digest = $blobResult.Digest
                        annotations = @{ 'org.opencontainers.image.title' = 'manifests.tar.gz' }
                    }
                    Write-Log "Created empty manifests layer: $($blobResult.Digest)"
                }
            }
            
            # Layer 2: Helm Charts (if chart subfolder exists) - store in blobs
            $chartsDir = Join-Path $manifestsStaging 'chart'
            if (Test-Path $chartsDir) {
                $chartsTarPath = Join-Path $artifactPath 'charts.tar.gz'
                if (New-TarGzArchive -SourcePath $chartsDir -DestinationPath $chartsTarPath -ArchiveContents) {
                    $blobResult = Add-ContentToBlobs -BlobsDir $blobsDir -SourcePath $chartsTarPath -Move
                    $ociLayerDescriptors += @{
                        mediaType = $ociMediaTypes.Charts
                        size = $blobResult.Size
                        digest = $blobResult.Digest
                        annotations = @{ 'org.opencontainers.image.title' = 'charts.tar.gz' }
                    }
                    Write-Log "Created charts layer: $($blobResult.Digest)"
                }
            }
            
            # Layer 3: Scripts - store in blobs
            if ((Get-ChildItem $scriptsStaging -ErrorAction SilentlyContinue).Count -gt 0) {
                $scriptsTarPath = Join-Path $artifactPath 'scripts.tar.gz'
                if (New-TarGzArchive -SourcePath $scriptsStaging -DestinationPath $scriptsTarPath -ArchiveContents) {
                    $blobResult = Add-ContentToBlobs -BlobsDir $blobsDir -SourcePath $scriptsTarPath -Move
                    $ociLayerDescriptors += @{
                        mediaType = $ociMediaTypes.Scripts
                        size = $blobResult.Size
                        digest = $blobResult.Digest
                        annotations = @{ 'org.opencontainers.image.title' = 'scripts.tar.gz' }
                    }
                    Write-Log "Created scripts layer: $($blobResult.Digest)"
                }
            }
            
            # Layer 4: Linux Images - store in blobs
            $linuxImagesLayer = Join-Path $artifactPath 'images-linux.tar'
            if (Test-Path $linuxImagesLayer) {
                $blobResult = Add-ContentToBlobs -BlobsDir $blobsDir -SourcePath $linuxImagesLayer -Move
                $ociLayerDescriptors += @{
                    mediaType = $ociMediaTypes.ImagesLinux
                    size = $blobResult.Size
                    digest = $blobResult.Digest
                    annotations = @{ 'org.opencontainers.image.title' = 'images-linux.tar' }
                }
                Write-Log "Created Linux images layer: $($blobResult.Digest)"
            }
            
            # Layer 5: Windows Images - store in blobs
            $windowsImagesLayer = Join-Path $artifactPath 'images-windows.tar'
            if (Test-Path $windowsImagesLayer) {
                $blobResult = Add-ContentToBlobs -BlobsDir $blobsDir -SourcePath $windowsImagesLayer -Move
                $ociLayerDescriptors += @{
                    mediaType = $ociMediaTypes.ImagesWindows
                    size = $blobResult.Size
                    digest = $blobResult.Digest
                    annotations = @{ 'org.opencontainers.image.title' = 'images-windows.tar' }
                }
                Write-Log "Created Windows images layer: $($blobResult.Digest)"
            }
            
            # Layer 6: Packages - store in blobs
            if ((Get-ChildItem $packagesStaging -Recurse -ErrorAction SilentlyContinue).Count -gt 0) {
                $packagesTarPath = Join-Path $artifactPath 'packages.tar.gz'
                if (New-TarGzArchive -SourcePath $packagesStaging -DestinationPath $packagesTarPath -ArchiveContents) {
                    $blobResult = Add-ContentToBlobs -BlobsDir $blobsDir -SourcePath $packagesTarPath -Move
                    $ociLayerDescriptors += @{
                        mediaType = $ociMediaTypes.Packages
                        size = $blobResult.Size
                        digest = $blobResult.Digest
                        annotations = @{ 'org.opencontainers.image.title' = 'packages.tar.gz' }
                    }
                    Write-Log "Created packages layer: $($blobResult.Digest)"
                }
            }
            
            # Create metadata.json as the OCI Config (contains addon metadata)
            $addonVersion = if ($implementation.version) { $implementation.version } else { "1.0.0" }
            $metadataJson = @{
                name = $manifest.metadata.name
                version = $addonVersion
                implementation = $implementation.name
                description = if ($manifest.metadata.description) { $manifest.metadata.description } else { "" }
                k2sVersion = $k2sVersion
                exportDate = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
            $metadataBlobResult = Add-JsonContentToBlobs -BlobsDir $blobsDir -Content $metadataJson
            Write-Log "Created metadata.json config: $($metadataBlobResult.Digest)"
            
            $ociManifest = @{
                schemaVersion = 2
                mediaType = 'application/vnd.oci.image.manifest.v1+json'
                artifactType = 'application/vnd.k2s.addon.v1'
                config = @{
                    mediaType = $ociMediaTypes.Config
                    size = $metadataBlobResult.Size
                    digest = $metadataBlobResult.Digest
                }
                layers = @()
                annotations = @{
                    'org.opencontainers.image.title' = $addonFolderName
                    'org.opencontainers.image.version' = $addonVersion
                    'org.opencontainers.image.created' = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
                    'org.opencontainers.image.vendor' = 'K2s Project'
                    'org.opencontainers.image.licenses' = 'Apache-2.0'
                    'org.opencontainers.image.description' = if ($manifest.metadata.description) { $manifest.metadata.description } else { "K2s addon: $($manifest.metadata.name)" }
                    'vnd.k2s.addon.name' = $manifest.metadata.name
                    'vnd.k2s.addon.implementation' = $implementation.name
                    'vnd.k2s.addon.export-name' = $addonFolderName
                    'vnd.k2s.version' = $k2sVersion
                    'vnd.k2s.export.date' = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
                    'vnd.k2s.export.type' = if ($All) { 'all' } else { 'specific' }
                }
            }
            
            # Add layer descriptors to manifest 
            if ($ociLayerDescriptors.Count -gt 0) {
                $ociManifest.layers = $ociLayerDescriptors
            } else {
                # Use OCI empty descriptor as fallback 
                $emptyJson = '{}'
                $emptyTempFile = New-CompatTemporaryFile
                try {
                    [System.IO.File]::WriteAllText($emptyTempFile.FullName, $emptyJson, [System.Text.UTF8Encoding]::new($false))
                    $emptyBlobResult = Add-ContentToBlobs -BlobsDir $blobsDir -SourcePath $emptyTempFile.FullName -Move
                } finally {
                    if (Test-Path $emptyTempFile.FullName) {
                        Remove-Item -Path $emptyTempFile.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
                $ociManifest.layers = @(
                    @{
                        mediaType = 'application/vnd.oci.empty.v1+json'
                        size = $emptyBlobResult.Size
                        digest = $emptyBlobResult.Digest
                    }
                )
                Write-Log "No content layers - added OCI empty descriptor as fallback"
            }
            
            # Store the manifest itself in blobs
            $manifestBlobResult = Add-JsonContentToBlobs -BlobsDir $blobsDir -Content $ociManifest
            Write-Log "Stored addon manifest in blobs: $($manifestBlobResult.Digest)"
            
            # Track manifest reference for index.json
            $addonManifestReferences += @{
                dirName = $addonFolderName
                baseAddonName = $manifest.metadata.name
                implementation = $implementation.name
                version = $addonVersion
                manifestDigest = $manifestBlobResult.Digest
                manifestSize = $manifestBlobResult.Size
            }
            
            # Clean up per-addon staging directory (layers are now in blobs)
            Remove-Item -Path $artifactPath -Recurse -Force -ErrorAction SilentlyContinue
            
            Remove-Item -Path $configStaging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $manifestsStaging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $scriptsStaging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $packagesStaging -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $imagesStaging -Recurse -Force -ErrorAction SilentlyContinue

            Write-Log '---' -Console    
        }    
    }

    # Create OCI Image Index (index.json) with proper digest and size references
    $indexManifest = @{
        schemaVersion = 2
        mediaType = 'application/vnd.oci.image.index.v1+json'
        manifests = @()
        annotations = @{
            'org.opencontainers.image.created' = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
            'org.opencontainers.image.vendor' = 'K2s Project'
            'org.opencontainers.image.licenses' = 'Apache-2.0'
            'vnd.k2s.version' = $k2sVersion
            'vnd.k2s.export.date' = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
            'vnd.k2s.export.type' = if ($All) { 'all' } else { 'specific' }
            'vnd.k2s.addon.count' = $addonManifestReferences.Count.ToString()
        }
    }
    
    foreach ($addonRef in $addonManifestReferences) {
        # Reference the manifest stored in blobs by digest
        $indexManifest.manifests += @{
            mediaType = 'application/vnd.oci.image.manifest.v1+json'
            size = $addonRef.manifestSize
            digest = $addonRef.manifestDigest
            artifactType = 'application/vnd.k2s.addon.v1'
            annotations = @{
                'org.opencontainers.image.ref.name' = "v$($addonRef.version)"
                'org.opencontainers.image.title' = $addonRef.dirName
                'org.opencontainers.image.version' = $addonRef.version
                'vnd.k2s.addon.name' = $addonRef.baseAddonName
                'vnd.k2s.addon.implementation' = $addonRef.implementation
                'vnd.k2s.addon.export-name' = $addonRef.dirName
            }
        }
    }
    
    $indexJsonPath = "${tmpExportDir}\artifacts\index.json"
    $json = $indexManifest | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($indexJsonPath, $json, [System.Text.UTF8Encoding]::new($false))
}
finally {
    $env:http_proxy = $currentHttpProxy
    $env:https_proxy = $currentHttpsProxy
}

# Generate versioned filename according to pattern: K2s-{version}-addons-{addon-names}
$exportedAddonNames = if ($All) {
    "all"
} else {
    ($addonManifestReferences | ForEach-Object { 
        ($_.dirName -replace '[_\s]+', '-').ToLower()
    }) -join '-'
}

# Create local tar archive (OCI layout)
$versionedFileName = "K2s-${k2sVersion}-addons-${exportedAddonNames}.oci.tar"
$finalExportPath = Join-Path $ExportDir $versionedFileName

Remove-Item -Force $finalExportPath -ErrorAction SilentlyContinue

# Create OCI-layout tar archive
$currentLocation = Get-Location
try {
    Set-Location "${tmpExportDir}\artifacts"
    $tarResult = & tar -cvf $finalExportPath "." 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Warning: tar creation returned: $tarResult"
    }
}
finally {
    Set-Location $currentLocation
}

Remove-Item -Force "$tmpExportDir" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
Write-Log '---'
Write-Log "Addons exported successfully as OCI-compliant artifact to $finalExportPath" -Console
Write-Log "OCI Image Layout structure:" -Console
Write-Log "  oci-layout           - OCI layout marker (imageLayoutVersion: 1.0.0)" -Console
Write-Log "  index.json           - OCI image index with manifest references" -Console
Write-Log "  blobs/sha256/        - Content-addressable blob storage" -Console
Write-Log "Layer types:" -Console
Write-Log "  Config:  metadata.json       (application/vnd.k2s.addon.config.v1+json)" -Console
Write-Log "  Layer 0: config.tar.gz       (application/vnd.k2s.addon.configfiles.v1.tar+gzip)" -Console
Write-Log "  Layer 1: manifests.tar.gz    (application/vnd.k2s.addon.manifests.v1.tar+gzip)" -Console
Write-Log "  Layer 2: charts.tar.gz       (application/vnd.cncf.helm.chart.content.v1.tar+gzip) [if helm-based]" -Console
Write-Log "  Layer 3: scripts.tar.gz      (application/vnd.k2s.addon.scripts.v1.tar+gzip)" -Console
if ($OmitImages) {
    Write-Log "  Layer 4: images-linux.tar    (application/vnd.oci.image.layer.v1.tar) [SKIPPED]" -Console
    Write-Log "  Layer 5: images-windows.tar  (application/vnd.k2s.addon.images-windows.v1.tar) [SKIPPED]" -Console
} else {
    Write-Log "  Layer 4: images-linux.tar    (application/vnd.oci.image.layer.v1.tar)" -Console
    Write-Log "  Layer 5: images-windows.tar  (application/vnd.k2s.addon.images-windows.v1.tar)" -Console
}
if ($OmitPackages) {
    Write-Log "  Layer 6: packages.tar.gz     (application/vnd.k2s.addon.packages.v1.tar+gzip) [SKIPPED]" -Console
} else {
    Write-Log "  Layer 6: packages.tar.gz     (application/vnd.k2s.addon.packages.v1.tar+gzip)" -Console
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
