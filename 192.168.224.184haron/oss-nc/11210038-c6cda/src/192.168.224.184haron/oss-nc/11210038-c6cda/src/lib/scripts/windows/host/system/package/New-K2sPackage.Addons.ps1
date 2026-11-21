# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# Addon-related helper functions for New-K2sPackage.ps1

# Dynamically discover all available addon implementations by scanning the addons directory
function Get-AvailableAddons {
    param(
        [string]$AddonsRootPath
    )

    $addonPaths = @{}

    if (-not (Test-Path $AddonsRootPath)) {
        Write-Log "[Addons] Warning: Addons directory not found at '$AddonsRootPath'" -Console
        return $addonPaths
    }

    # Get all addon directories (exclude 'common' and module files)
    $addonDirs = Get-ChildItem -Path $AddonsRootPath -Directory | Where-Object { $_.Name -ne 'common' }

    foreach ($addonDir in $addonDirs) {
        $manifestPath = Join-Path $addonDir.FullName 'addon.manifest.yaml'

        if (Test-Path $manifestPath) {
            # Check if this addon has multiple implementations (subdirectories with Enable.ps1)
            $implDirs = Get-ChildItem -Path $addonDir.FullName -Directory | Where-Object {
                Test-Path (Join-Path $_.FullName 'Enable.ps1')
            }

            if ($implDirs.Count -gt 0) {
                # Multi-implementation addon (e.g., ingress with nginx/traefik)
                foreach ($implDir in $implDirs) {
                    $addonKey = "$($addonDir.Name) $($implDir.Name)"
                    $relativePath = "addons/$($addonDir.Name)/$($implDir.Name)"
                    $addonPaths[$addonKey] = $relativePath
                }
            } else {
                # Single-implementation addon (Enable.ps1 directly in addon folder)
                $enableScript = Join-Path $addonDir.FullName 'Enable.ps1'
                if (Test-Path $enableScript) {
                    $addonKey = $addonDir.Name
                    $relativePath = "addons/$($addonDir.Name)"
                    $addonPaths[$addonKey] = $relativePath
                }
            }
        }
    }

    return $addonPaths
}

# Check if a test directory name matches a selected addon
function Test-AddonTestFolderMatch {
    param(
        [string]$TestDirName,
        [string]$AddonName
    )

    # Extract base addon name (remove implementation suffix for multi-impl addons)
    $addonBaseName = $AddonName
    $implName = $null

    if ($AddonName -match '^(.+)\s+(.+)$') {
        # Multi-implementation addon like "ingress nginx"
        $addonBaseName = $matches[1]
        $implName = $matches[2]

        # For multi-impl addons, match:
        # 1. Exact base name (e.g., "ingress" for common tests)
        # 2. Base name with implementation (e.g., "ingress-nginx" or "ingress-nginx_sec_test")
        if ($TestDirName -eq $addonBaseName) {
            return $true
        }

        # Check if test folder specifically matches this implementation
        # Pattern: basename-implname (with optional suffix like _sec_test)
        if ($TestDirName -like "$addonBaseName-$implName*") {
            return $true
        }

        return $false
    } else {
        # Single-implementation addon - match exact name or with suffix
        return ($TestDirName -eq $addonBaseName -or $TestDirName -like "$addonBaseName`_*")
    }
}

# Add exclusions for addon test folders that don't match selected addons
function Add-TestFolderExclusions {
    param(
        [string]$KubePath,
        [string[]]$SelectedAddons,
        [ref]$ExclusionListRef,
        [hashtable]$AllAddonPaths
    )

    $testAddonsPath = Join-Path $KubePath 'test/e2e/addons'
    if (-not (Test-Path $testAddonsPath)) {
        return
    }

    # Build a map of selected implementations per base addon
    $selectedImplsByAddon = @{}
    foreach ($addon in $SelectedAddons) {
        if ($addon -match '^(.+)\s+(.+)$') {
            # Multi-implementation addon like "ingress nginx"
            $baseName = $matches[1]
            $implName = $matches[2]

            if (-not $selectedImplsByAddon.ContainsKey($baseName)) {
                $selectedImplsByAddon[$baseName] = @()
            }
            $selectedImplsByAddon[$baseName] += $implName
        }
    }

    # Build a list of all known implementation names from AllAddonPaths
    $allKnownImpls = @{}
    foreach ($addonKey in $AllAddonPaths.Keys) {
        if ($addonKey -match '^(.+)\s+(.+)$') {
            $baseName = $matches[1]
            $implName = $matches[2]

            if (-not $allKnownImpls.ContainsKey($baseName)) {
                $allKnownImpls[$baseName] = @()
            }
            if ($allKnownImpls[$baseName] -notcontains $implName) {
                $allKnownImpls[$baseName] += $implName
            }
        }
    }

    $testAddonDirs = Get-ChildItem -Path $testAddonsPath -Directory
    foreach ($testDir in $testAddonDirs) {
        $testDirName = $testDir.Name
        $shouldInclude = $false

        # Check if this test directory matches any selected addon
        foreach ($addon in $SelectedAddons) {
            if (Test-AddonTestFolderMatch -TestDirName $testDirName -AddonName $addon) {
                $shouldInclude = $true
                break
            }
        }

        if ($shouldInclude) {
            Write-Log "[Addons] Including test folder for addon: test/e2e/addons/$testDirName" -Console

            # For multi-implementation addons, check if we need to exclude specific subdirectories
            if ($selectedImplsByAddon.ContainsKey($testDirName)) {
                $selectedImpls = $selectedImplsByAddon[$testDirName]
                $knownImpls = $allKnownImpls[$testDirName]

                # Check for implementation-specific subdirectories
                $implSubdirs = Get-ChildItem -Path $testDir.FullName -Directory -ErrorAction SilentlyContinue
                foreach ($implSubdir in $implSubdirs) {
                    $implSubdirName = $implSubdir.Name

                    # Check if this subdirectory name matches a known implementation
                    if ($knownImpls -contains $implSubdirName) {
                        # This is an implementation-specific subdirectory
                        if ($selectedImpls -notcontains $implSubdirName) {
                            # Exclude this unselected implementation subdirectory
                            $subdirFullPath = Join-Path $KubePath "test/e2e/addons/$testDirName/$implSubdirName"
                            if (-not ($ExclusionListRef.Value -contains $subdirFullPath)) {
                                $ExclusionListRef.Value += $subdirFullPath
                            }
                            Write-Log "[Addons] Excluding test subdirectory: test/e2e/addons/$testDirName/$implSubdirName" -Console
                        } else {
                            Write-Log "[Addons] Including test subdirectory: test/e2e/addons/$testDirName/$implSubdirName" -Console
                        }
                    }
                }
            }
        } else {
            # Exclude this test folder since it doesn't match any selected addon
            $testDirFullPath = Join-Path $KubePath "test/e2e/addons/$testDirName"
            if (-not ($ExclusionListRef.Value -contains $testDirFullPath)) {
                $ExclusionListRef.Value += $testDirFullPath
            }
            Write-Log "[Addons] Excluding test folder: test/e2e/addons/$testDirName" -Console
        }
    }
}

# Filter addon manifest to only include selected implementations
function Update-AddonManifestForSelectedImplementations {
    param(
        [string]$ManifestPath,
        [string[]]$SelectedImplementations
    )

    if (-not (Test-Path $ManifestPath)) {
        Write-Log "Manifest not found: $ManifestPath" -Console
        return
    }

    Write-Log "Filtering manifest $ManifestPath to only include implementations: $($SelectedImplementations -join ', ')" -Console

    # Read the manifest file line by line
    $lines = Get-Content -Path $ManifestPath
    $filteredLines = @()
    $inImplementationsSection = $false
    $currentImplName = ''
    $skipCurrentImpl = $false
    $implementationLineIndent = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # Detect when we enter the implementations section
        if ($line -match '^\s*implementations:\s*$') {
            $inImplementationsSection = $true
            $filteredLines += $line
            continue
        }

        # If we're in implementations section, check for implementation entries
        if ($inImplementationsSection) {
            # Check if this is a new implementation entry (- name: xxx at the correct indent level)
            if ($line -match '^\s+- name:\s+(.+)$') {
                # Calculate indent level of this "- name:" line
                $currentIndent = ($line -replace '\S.*$', '').Length

                # If this is the first implementation, record the indent
                if ($implementationLineIndent -eq 0) {
                    $implementationLineIndent = $currentIndent
                }

                # Only treat as new implementation if at the same indent as first one
                if ($currentIndent -eq $implementationLineIndent) {
                    $currentImplName = $matches[1].Trim()
                    $skipCurrentImpl = $SelectedImplementations -notcontains $currentImplName

                    if ($skipCurrentImpl) {
                        Write-Log "  Excluding implementation: $currentImplName" -Console
                        continue
                    } else {
                        Write-Log "  Including implementation: $currentImplName" -Console
                        $filteredLines += $line
                        continue
                    }
                }
            }

            # Check if we're exiting the implementations section (back to top-level key)
            if ($line -match '^\S' -and $line.Trim() -ne '') {
                $inImplementationsSection = $false
                $skipCurrentImpl = $false
                $implementationLineIndent = 0
                $filteredLines += $line
                continue
            }

            # We're inside implementations section - skip lines if current impl is not selected
            if ($skipCurrentImpl) {
                continue
            }
        }

        # Add all other lines
        $filteredLines += $line
    }

    # Validate that we have at least one implementation left
    $hasImplementations = $false
    $inImpls = $false
    foreach ($line in $filteredLines) {
        if ($line -match '^\s*implementations:\s*$') {
            $inImpls = $true
            continue
        }
        if ($inImpls -and $line -match '^\s+- name:\s+') {
            $hasImplementations = $true
            break
        }
        if ($inImpls -and $line -match '^\S') {
            break
        }
    }

    if (-not $hasImplementations) {
        Write-Log "  WARNING: No implementations left after filtering! Keeping original manifest." -Console
        return
    }

    # Write the filtered content back to the file
    $filteredLines | Set-Content -Path $ManifestPath -Force
    Write-Log "  Manifest filtered successfully" -Console
}

# Process all addon manifests and filter out non-selected implementations
function Update-AddonManifestsInPackage {
    param(
        [string]$PackageRootPath,
        [string[]]$SelectedAddons,
        [hashtable]$AllAddonPaths
    )

    if ($SelectedAddons.Count -eq 0) {
        Write-Log "No addon filtering needed - all addons included" -Console
        return
    }

    Write-Log "Processing addon manifests to filter implementations..." -Console

    $addonsPath = Join-Path $PackageRootPath 'addons'
    if (-not (Test-Path $addonsPath)) {
        Write-Log "Addons directory not found in package: $addonsPath" -Console
        return
    }

    # Group selected addons by base name to find multi-implementation scenarios
    $addonGroups = @{}
    foreach ($addon in $SelectedAddons) {
        if ($addon -match '^(.+)\s+(.+)$') {
            # Multi-implementation addon like "ingress nginx"
            $baseName = $matches[1]
            $implName = $matches[2]

            if (-not $addonGroups.ContainsKey($baseName)) {
                $addonGroups[$baseName] = @()
            }
            $addonGroups[$baseName] += $implName
        }
    }

    # Process each multi-implementation addon
    foreach ($baseName in $addonGroups.Keys) {
        $manifestPath = Join-Path $addonsPath "$baseName\addon.manifest.yaml"
        if (Test-Path $manifestPath) {
            $selectedImpls = $addonGroups[$baseName]
            Update-AddonManifestForSelectedImplementations -ManifestPath $manifestPath -SelectedImplementations $selectedImpls
        }
    }
}

# Exclude addon manifests for multi-implementation addons where no implementations are selected
function Add-UnselectedAddonManifestExclusions {
    param(
        [string]$KubePath,
        [string]$AddonsRootPath,
        [string[]]$SelectedAddons,
        [ref]$ExclusionListRef
    )

    $addonDirs = Get-ChildItem -Path $AddonsRootPath -Directory | Where-Object { $_.Name -ne 'common' }
    foreach ($addonDir in $addonDirs) {
        # Check if this is a multi-implementation addon
        $implDirs = Get-ChildItem -Path $addonDir.FullName -Directory | Where-Object {
            Test-Path (Join-Path $_.FullName 'Enable.ps1')
        }

        if ($implDirs.Count -gt 0) {
            # Multi-implementation addon - check if any implementation is selected
            $anyImplSelected = $false
            foreach ($implDir in $implDirs) {
                $addonKey = "$($addonDir.Name) $($implDir.Name)"
                if ($SelectedAddons -contains $addonKey) {
                    $anyImplSelected = $true
                    break
                }
            }

            # If no implementations selected, exclude the manifest
            if (-not $anyImplSelected) {
                $manifestPath = Join-Path $addonDir.FullName 'addon.manifest.yaml'
                if (Test-Path $manifestPath) {
                    $fullPath = Join-Path $KubePath "addons/$($addonDir.Name)/addon.manifest.yaml"
                    if (-not ($ExclusionListRef.Value -contains $fullPath)) {
                        $ExclusionListRef.Value += $fullPath
                    }
                }
            }
        }
    }
}
