# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Creates a JSON file with list of all container images used in K2s.
.DESCRIPTION
Scraps container images from running K2s cluster workloads and yaml manifests under addons folder.
Core images are retrieved from all running pods in the cluster.
Addon images are scraped from YAML manifests and addon configuration files.
All available addons are automatically discovered and processed.
.NOTES
Requires a running K2s cluster with kubectl access.
.EXAMPLE
    # Get all images from cluster and addons
    .\build\bom\DumpK2sImages.ps1
#>

Param(
)

&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1

$addonsModule = "$PSScriptRoot\..\..\addons\addons.module.psm1"
$yamlModule = "$PSScriptRoot\..\..\lib\modules\windows\infra\k2s.infra.module\yaml\yaml.module.psm1"
$pathModule = "$PSScriptRoot\..\..\lib\modules\windows\infra\k2s.infra.module\path\path.module.psm1"

Import-Module $addonsModule, $yamlModule, $pathModule

<#
.SYNOPSIS
Gets container images from all running workloads in the K2s cluster.

.DESCRIPTION
Uses kubectl to query all pods in the cluster and extracts container images.
Includes both init containers and regular containers.

.OUTPUTS
Array of unique container image names with tags.
#>
function Get-ImagesFromCluster {
    Write-Host "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Getting container images from running K2s cluster..."
    
    $kubeToolsPath = Get-KubeToolsPath
    $kubectlPath = Join-Path -Path $kubeToolsPath -ChildPath 'kubectl.exe'
    
    if (-not (Test-Path $kubectlPath)) {
        throw "kubectl not found at $kubectlPath. Please ensure K2s is installed."
    }
    
    $images = New-Object System.Collections.Generic.List[System.String]
    
    try {
        # Get all pods from all namespaces
        Write-Host "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Querying all pods in all namespaces..."
        $podsJson = & $kubectlPath get pods --all-namespaces -o json 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to get pods from cluster: $podsJson"
        }
        
        $pods = $podsJson | ConvertFrom-Json
        
        if ($null -eq $pods.items -or $pods.items.Count -eq 0) {
            Write-Warning "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] No pods found in cluster"
            return @()
        }
        
        Write-Host "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Found $($pods.items.Count) pods in cluster"
        
        foreach ($pod in $pods.items) {
            $namespace = $pod.metadata.namespace
            $podName = $pod.metadata.name
            
            # Extract images from init containers
            if ($pod.spec.initContainers) {
                foreach ($container in $pod.spec.initContainers) {
                    if ($container.image) {
                        $image = $container.image.Trim()
                        if ($image -ne '' -and -not $images.Contains($image)) {
                            Write-Host "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')]   Found init container image: $image (pod: $namespace/$podName)"
                            $images.Add($image)
                        }
                    }
                }
            }
            
            # Extract images from regular containers
            if ($pod.spec.containers) {
                foreach ($container in $pod.spec.containers) {
                    if ($container.image) {
                        $image = $container.image.Trim()
                        if ($image -ne '' -and -not $images.Contains($image)) {
                            Write-Host "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')]   Found container image: $image (pod: $namespace/$podName)"
                            $images.Add($image)
                        }
                    }
                }
            }
        }
        
        Write-Host "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Total unique images found in cluster: $($images.Count)"
        return $images.ToArray()
    }
    catch {
        Write-Error "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Error getting images from cluster: $_"
        throw
    }
}

$addonManifests = @()

Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Starting Scrapping of Container Images for all addons"
$allAddonManifests = Find-AddonManifests -Directory "$global:KubernetesPath\addons\" |`
    ForEach-Object {
    $manifest = Get-FromYamlFile -Path $_
    $manifest | Add-Member -NotePropertyName 'path' -NotePropertyValue $_
    $dirPath = Split-Path -Path $_ -Parent
    $dirName = Split-Path -Path $dirPath -Leaf
    $manifest | Add-Member -NotePropertyName 'dir' -NotePropertyValue @{path = $dirPath; name = $dirName }
    $manifest
}

# Process all discovered addons
$addonManifests += $allAddonManifests

Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Found $($addonManifests.Count) addon manifests to process"

$finalJsonFile = "$PSScriptRoot\container-images-used.json"

if (Test-Path -Path $finalJsonFile) {
    Remove-Item -Force $finalJsonFile -ErrorAction SilentlyContinue
}

# Get core images from running K2s cluster
Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Getting core images from running K2s cluster..."
$staticImages = Get-ImagesFromCluster

if ($staticImages.Count -eq 0) {
    throw "No images found in cluster. Please ensure the K2s cluster is running and accessible."
}

Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Core images count: $($staticImages.Count)"
Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Core images found from cluster:"
Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Images: $([string]::Join(', ', $staticImages))"
Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] -----------------------------------------------------------------------------"
foreach ($image in $staticImages) {
    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] -> Image: $image"
}
Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] -----------------------------------------------------------------------------"

$images = New-Object System.Collections.Generic.List[System.Object]
$addonImages = New-Object System.Collections.Generic.List[System.Object]
$addonNameImagesMapping = @{}

foreach ($manifest in $addonManifests) {
    foreach ($implementation in $manifest.spec.implementations) {
        # there are more than one implementation
        $dirPath = $manifest.dir.path
        $addonName = $manifest.metadata.name
        if ($implementation.name -ne $manifest.metadata.name) {
            $dirPath = Join-Path -Path $($manifest.dir.path) -ChildPath $($implementation.name)
            $addonName += "-$($implementation.name)"
        }
        $files = Get-Childitem -recurse $dirPath | Where-Object { $_.Name -match '.*.yaml$' } | ForEach-Object { $_.Fullname }

        foreach ($file in $files) {
            $imageLines = @()
            $content = Get-Content -Path $file
            if ($file -match 'chart\.yaml$') {
                continue
            }
            if ($file -match 'values\.yaml$') {
                foreach ($line in $content) {
                    if ($line -match 'image:' -or $line -match 'repository:' -or $line -match 'tag:') {
                        $imageLines += $line
                    }
                }
            } else {
                $imageLines = Get-Content $file | Select-String 'image:' | Select-Object -ExpandProperty Line
            }

            foreach ($imageLine in $imageLines) {
                $unTrimmedFullImageName = ''
                if ($imageLine -match 'image:') {
                    $unTrimmedFullImageName = (($imageLine -split 'image: ')[1] -split '#')[0]
                } elseif ($imageLine -match 'repository:') {
                    $repo = ($imageLine -replace '.*repository:\s*', '') -split '#' | Select-Object -First 1
                    $repo = $repo.Trim("`"'").Trim()
                    $tagLine = $content | Where-Object { $_ -match 'tag:' } | Select-Object -First 1
                    $tag = ''
                    if ($tagLine) {
                        $tag = ($tagLine -replace '.*tag:\s*', '') -split '#' | Select-Object -First 1
                        $tag = $tag.Trim("`"'").Trim()
                    }
                    if ($repo -ne '') {
                        if ($tag -ne '') {
                            $unTrimmedFullImageName = "$($repo):$($tag)"
                        } else {
                            # If tag is missing, default to 'latest'
                            $unTrimmedFullImageName = "$($repo):latest"
                        }
                    }
                }
                $fullImageName = $unTrimmedFullImageName.Trim().Trim("`"'")

                if ($fullImageName -eq '') {
                    continue
                }

                # if $fullImageName does not contain a : then ignore (no tag specified)
                if ($fullImageName.IndexOf(':') -eq -1) {
                    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] WARNING: Skipping image without tag: $fullImageName (file: $file)"
                    continue
                }

                # Additional validation: ensure there's actually a tag after the colon
                $parts = $fullImageName -split ':'
                if ($parts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($parts[1])) {
                    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] WARNING: Skipping image with empty tag: $fullImageName (file: $file)"
                    continue
                }

                $images.Add("$fullImageName")

                # Initialize the image list if not already present
                if (-not $addonNameImagesMapping.ContainsKey($addonName)) {
                    $addonNameImagesMapping[$addonName] = @()
                }

                # Add the image name if it does not already exist in the list
                if (-not ($addonNameImagesMapping[$addonName] -contains $fullImageName)) {
                    $addonNameImagesMapping[$addonName] += "$fullImageName"
                }
            }

        }

        if ($null -ne $implementation.offline_usage) {
            $linuxPackages = $implementation.offline_usage.linux
            $additionImages = $linuxPackages.additionalImages

            if ($additionImages.Count -ne 0) {
                # Validate each additional image has a tag
                foreach ($additionalImage in $additionImages) {
                    if ($additionalImage.IndexOf(':') -eq -1) {
                        Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] WARNING: Skipping additional image without tag: $additionalImage (addon: $addonName)"
                        continue
                    }
                    
                    $parts = $additionalImage -split ':'
                    if ($parts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($parts[1])) {
                        Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] WARNING: Skipping additional image with empty tag: $additionalImage (addon: $addonName)"
                        continue
                    }

                    if (-not $addonNameImagesMapping.ContainsKey($addonName)) {
                        $addonNameImagesMapping[$addonName] = @()
                    }

                    if (-not ($addonNameImagesMapping[$addonName] -contains $additionalImage)) {
                        $addonNameImagesMapping[$addonName] += $additionalImage
                    }
                    $images.Add($additionalImage)
                }
            }

            # extract additionalImagesFiles if present
            if ($linuxPackages.additionalImagesFiles -and $linuxPackages.additionalImagesFiles.Count -gt 0) {
                $extractedImages = Get-ImagesFromYamlFiles -YamlFiles $linuxPackages.additionalImagesFiles -BaseDirectory $dirPath
                
                # Ensure $extractedImages is always an array
                if ($null -ne $extractedImages) {
                    if ($extractedImages -is [string]) {
                        $extractedImages = @($extractedImages)
                    }
                    
                    if ($extractedImages.Count -gt 0) {
                        if (-not $addonNameImagesMapping.ContainsKey($addonName)) {
                            $addonNameImagesMapping[$addonName] = @()
                        }
                        foreach ($extractedImage in $extractedImages) {
                            if (-not ($addonNameImagesMapping[$addonName] -contains $extractedImage)) {
                                $addonNameImagesMapping[$addonName] += $extractedImage
                            }
                            # Add individual images to avoid AddRange type issues
                            if (-not $images.Contains($extractedImage)) {
                                $images.Add($extractedImage)
                            }
                        }
                        Write-Output "Extracted $($extractedImages.Count) images from YAML files for addon $addonName"
                    }
                }
            }
        }

        $addonImages = $images | Select-Object -Unique | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim("`"'") }
        $addonImages = Remove-VersionlessImages -Images $addonImages
    }
}


$totalCountMapping = 0

# uniques list of images
$uniqueSingleImages = New-Object System.Collections.Generic.List[System.String]

foreach ($addonName in $addonNameImagesMapping.Keys) {
    $uniqueImages = $addonNameImagesMapping[$addonName] | Sort-Object -Unique
    $finalImages = @()
    $finalImages = $uniqueImages | Where-Object { $_ -ne '' }
    $totalCountMapping = $totalCountMapping + $($finalImages.Count)
    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Addon: $addonName"
    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Addon Images Count: $($finalImages.Count)"
    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Images: $([string]::Join(', ', $uniqueImages))"
    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] -----------------------------------------------------------------------------"

    # check if images are all in the addons image list
    foreach ($image in $finalImages) {
        Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] -> Image: $image"
    
        if ($uniqueSingleImages.Contains($image)) {
            Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')]  Info: Image $image is already in the addon images list, it's a duplicate"
        }
        else {
            $uniqueSingleImages.Add($image)
        }
        if (-not $addonImages.Contains($image)) {
            Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] ERROR: Image $image is not in the addon images list"
        }
    }
}

Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Number of addons: $($addonNameImagesMapping.Keys.Count)"
Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Number of addon images: $($addonImages.Count)"
Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Number of images in mapping: $totalCountMapping"

if ($($addonImages.Count) -ne $totalCountMapping) {
    Write-Warning "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Check the image mapping and addon list for duplicates or a single image referenced by two addons"
}

$finalImages = ($staticImages + $addonImages) | Select-Object -Unique

# Final validation: Remove any images without tags
$validatedImages = @()
foreach ($img in $finalImages) {
    if ($img -eq '') {
        continue
    }
    
    # Check if image has a colon (tag separator)
    if ($img.IndexOf(':') -eq -1) {
        Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] WARNING: Excluding image without tag from final list: $img"
        continue
    }
    
    # Check if tag is not empty after colon
    $parts = $img -split ':', 2
    if ($parts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($parts[1])) {
        Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] WARNING: Excluding image with empty tag from final list: $img"
        continue
    }
    
    $validatedImages += $img
}

$finalImages = $validatedImages
Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Final validated images count: $($finalImages.Count)"

$imageDetailsArray = New-Object System.Collections.ArrayList

foreach ($image in $finalImages) {
    $imageName, $imageVersion = $image -split ':', 2

    if ($image -eq '') {
        continue
    }

    if ($null -eq $imageVersion -Or $imageVersion -eq '') {
        Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] WARNING: Skipping image with null/empty version: $image"
        continue
    }

    # Remove empty spaces
    $imageVersion = $imageVersion.Trim()
    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Found image $image with version $imageVersion"

    # Determine the type of image
    $imageType = if ($staticImages -contains $image) { 'core' } else { 'addons' }

    $referrerName = 'core'
    if ($imageType -eq 'addons') {
        # Look for addon name using image name
        foreach ($addonName in $addonNameImagesMapping.Keys) {

            $tempImages = $addonNameImagesMapping[$addonName]
            #Write-Output "Addon images '$addonName' $([string]::Join(', ', $tempImages))"

            if ($tempImages.contains("$image")) {
                Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Belongs to addon '$addonName'"
                $referrerName = $addonName
                break
            }
        }

        if ($referrerName -eq 'core') {
            Write-Warning "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Unable to find addon referring image: $image - assigning to 'unknown'"
            $referrerName = 'unknown'
        }
    }


    $imageDetailsObject = New-Object PSObject -Property @{
        ImageName    = $imageName
        ImageVersion = $imageVersion
        ImageType    = $imageType
        ImageRef     = $referrerName
    }

    # Add the object to the array
    $imageDetailsArray.Add($imageDetailsObject) | Out-Null
    Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] *********************************************************************************"
}

# Output the image details in a JSON format file
$imageDetailsArray | ConvertTo-Json | Out-File -FilePath $finalJsonFile

Write-Output "[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] Done Dumping Container Images"
