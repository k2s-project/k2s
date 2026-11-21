# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# Putty tools (plink/pscp) helper functions for New-K2sPackage.ps1

# Restore plink.exe and pscp.exe from WindowsNodeArtifacts.zip
function Restore-PuttyToolsFromArchive {
    param(
        [string]$WindowsNodeArtifactsZipPath,
        [string]$PlinkDestination,
        [string]$PscpDestination
    )

    Write-Log "Restoring plink.exe and pscp.exe to bin folder from WindowsNodeArtifacts.zip..." -Console
    Write-Log "  WindowsNodeArtifacts.zip path: $WindowsNodeArtifactsZipPath (exists: $(Test-Path $WindowsNodeArtifactsZipPath))" -Console

    if (-not (Test-Path $WindowsNodeArtifactsZipPath)) {
        Write-Log "ERROR: WindowsNodeArtifacts.zip not found, cannot restore plink/pscp!" -Error
        return $false
    }

    # Extract them from WindowsNodeArtifacts.zip
    $tempExtractPath = Join-Path $env:TEMP "putty-restore-$(Get-Random)"
    try {
        New-Item -Path $tempExtractPath -ItemType Directory -Force | Out-Null
        Write-Log "  Extracting WindowsNodeArtifacts.zip to temp location..." -Console
        Expand-Archive -Path $WindowsNodeArtifactsZipPath -DestinationPath $tempExtractPath -Force

        Write-Log "  Temp extract path: $tempExtractPath" -Console

        # The structure is puttytools (one word, all lowercase) at root
        $puttytoolsDir = Join-Path $tempExtractPath 'puttytools'
        Write-Log "  Looking for puttytools directory: $puttytoolsDir (exists: $(Test-Path $puttytoolsDir))" -Console

        if (Test-Path $puttytoolsDir) {
            $plinkSource = Join-Path $puttytoolsDir 'plink.exe'
            $pscpSource = Join-Path $puttytoolsDir 'pscp.exe'

            Write-Log "  plink.exe source: $plinkSource (exists: $(Test-Path $plinkSource))" -Console
            Write-Log "  pscp.exe source: $pscpSource (exists: $(Test-Path $pscpSource))" -Console

            $restoredCount = 0
            if (Test-Path $plinkSource) {
                Copy-Item -Path $plinkSource -Destination $PlinkDestination -Force
                Write-Log "  Restored plink.exe" -Console
                $restoredCount++
            } else {
                Write-Log "  WARNING: plink.exe not found at $plinkSource" -Console
            }

            if (Test-Path $pscpSource) {
                Copy-Item -Path $pscpSource -Destination $PscpDestination -Force
                Write-Log "  Restored pscp.exe" -Console
                $restoredCount++
            } else {
                Write-Log "  WARNING: pscp.exe not found at $pscpSource" -Console
            }

            return ($restoredCount -eq 2)
        } else {
            Write-Log "  ERROR: puttytools directory not found at expected path: $puttytoolsDir" -Error
            Write-Log "  Contents of temp extract path:" -Console
            Get-ChildItem -Path $tempExtractPath -Recurse -Force | Select-Object -First 20 | ForEach-Object { Write-Log "    $($_.FullName)" -Console }
            return $false
        }
    }
    catch {
        Write-Log "ERROR: Failed to restore putty tools: $_" -Error
        return $false
    }
    finally {
        if (Test-Path $tempExtractPath) {
            Remove-Item -Path $tempExtractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Download plink.exe and pscp.exe using putty-tools module
function Get-PuttyToolsViaDownload {
    param(
        [string]$PlinkDestination,
        [string]$PscpDestination,
        [string]$Proxy,
        [string]$PuttyToolsModulePath
    )

    Write-Log "Downloading plink.exe and pscp.exe for package..." -Console

    if (-not (Test-Path $PuttyToolsModulePath)) {
        Write-Log "Warning: Could not find putty-tools module at $PuttyToolsModulePath" -Console
        return $false
    }

    try {
        Import-Module $PuttyToolsModulePath -Force

        $downloadedCount = 0
        if (-not (Test-Path $PlinkDestination)) {
            Invoke-DownloadPlink -Destination $PlinkDestination -Proxy $Proxy
            Write-Log "  Downloaded plink.exe" -Console
            $downloadedCount++
        }
        if (-not (Test-Path $PscpDestination)) {
            Invoke-DownloadPscp -Destination $PscpDestination -Proxy $Proxy
            Write-Log "  Downloaded pscp.exe" -Console
            $downloadedCount++
        }

        return ($downloadedCount -gt 0)
    }
    catch {
        Write-Log "ERROR: Failed to download putty tools: $_" -Error
        return $false
    }
}

# Ensure plink.exe and pscp.exe are available in bin folder
function Ensure-PuttyToolsAvailable {
    param(
        [string]$PlinkPath,
        [string]$PscpPath,
        [bool]$IsOfflineInstallation,
        [string]$WindowsNodeArtifactsZipPath,
        [string]$Proxy
    )

    Write-Log "Checking plink.exe and pscp.exe availability..."
    Write-Log "  plink.exe path: $PlinkPath (exists: $(Test-Path $PlinkPath))"
    Write-Log "  pscp.exe path: $PscpPath (exists: $(Test-Path $PscpPath))"

    # Check if both tools already exist
    if ((Test-Path $PlinkPath) -and (Test-Path $PscpPath)) {
        Write-Log "  plink.exe and pscp.exe already present in bin folder"
        return $true
    }

    if ($IsOfflineInstallation) {
        # For offline packages: restore from WindowsNodeArtifacts.zip
        return Restore-PuttyToolsFromArchive -WindowsNodeArtifactsZipPath $WindowsNodeArtifactsZipPath `
            -PlinkDestination $PlinkPath -PscpDestination $PscpPath
    } else {
        # For non-offline packages: download if not present
        $puttytoolsModulePath = "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\windowsnode\downloader\artifacts\putty-tools\putty-tools.module.psm1"
        return Get-PuttyToolsViaDownload -PlinkDestination $PlinkPath -PscpDestination $PscpPath `
            -Proxy $Proxy -PuttyToolsModulePath $puttytoolsModulePath
    }
}

function Assert-PuttyToolsReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPrefix,
        [string]$Proxy = ''
    )

    Write-Log "$LogPrefix === Prerequisite: Checking plink.exe / pscp.exe ===" -Console

    $kubeBinPath = Get-KubeBinPath
    $plinkPath = Join-Path $kubeBinPath 'plink.exe'
    $pscpPath = Join-Path $kubeBinPath 'pscp.exe'
    $windowsNodeArtifactsZipPath = Get-WindowsNodeArtifactsZipFilePath
    $useOfflineInstallation = Test-Path $windowsNodeArtifactsZipPath

    Write-Log "$LogPrefix plink.exe: $plinkPath (exists: $(Test-Path $plinkPath))" -Console
    Write-Log "$LogPrefix pscp.exe:  $pscpPath (exists: $(Test-Path $pscpPath))" -Console
    Write-Log "$LogPrefix WindowsNodeArtifacts.zip: $windowsNodeArtifactsZipPath (exists: $useOfflineInstallation)" -Console

    $puttyToolsAvailable = Ensure-PuttyToolsAvailable -PlinkPath $plinkPath -PscpPath $pscpPath `
        -IsOfflineInstallation $useOfflineInstallation -WindowsNodeArtifactsZipPath $windowsNodeArtifactsZipPath `
        -Proxy $Proxy

    if (-not $puttyToolsAvailable) {
        throw "$LogPrefix Could not obtain plink.exe / pscp.exe. Place them in the bin\ folder, or ensure WindowsNodeArtifacts.zip is present for offline restore, or provide internet access for download."
    }

    Write-Log "$LogPrefix plink.exe and pscp.exe are ready." -Console
}
