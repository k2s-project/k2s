# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# Archive (ZIP) creation helper functions for New-K2sPackage.ps1
# Note: This function requires $EncodeStructuredOutput and $MessageType to be available
# in the calling script's scope for error handling.

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-ZipArchive() {
    Param(
        [parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $ExclusionList,
        [parameter(Mandatory = $true)]
        [string] $BaseDirectory,
        [parameter(Mandatory = $true)]
        [string] $TargetPath,
        [parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]] $InclusionList = @()
    )

    Write-Log "Creating ZIP archive: $TargetPath from base directory: $BaseDirectory" -Console

    # Normalize the base directory to its full path to avoid 8.3 vs long name issues
    $normalizedBaseDirectory = (Get-Item $BaseDirectory).FullName
    Write-Log "BaseDirectory normalized: $normalizedBaseDirectory" -Console

    $files = Get-ChildItem -Path $BaseDirectory -Force -Recurse | ForEach-Object { $_.FullName }
    Write-Log "Found $($files.Count) total files and directories to process" -Console

    $fileStreamMode = [System.IO.FileMode]::Create
    $zipMode = [System.IO.Compression.ZipArchiveMode]::Create
    $compressionLevel = [System.IO.Compression.CompressionLevel]::Optimal

    $zipFileStream = $null
    $zipFile = $null

    try {
        $zipFileStream = [System.IO.File]::Open($TargetPath, $fileStreamMode)
        $zipFile = [System.IO.Compression.ZipArchive]::new($zipFileStream, $zipMode)
        Write-Log "ZIP archive opened successfully" -Console

        $addedCount = 0
        $skippedCount = 0

        foreach ($file in $files) {
            $sourceFileStream = $null
            $zipFileStreamEntry = $null

            try {
                # Check exclusion list
                $shouldSkip = $false
                foreach ($exclusion in $ExclusionList) {
                    if ($file.StartsWith($exclusion)) {
                        $shouldSkip = $true
                        break
                    }
                }
                # Check inclusion list - both exact match and subdirectory match
                if ($shouldSkip) {
                    $shouldInclude = $false
                    # Check if file/directory is explicitly included OR is within an included directory
                    foreach ($inclusion in $InclusionList) {
                        if ($file -eq $inclusion -or $file.StartsWith("$inclusion\")) {
                            $shouldInclude = $true
                            break
                        }
                    }
                    if ($shouldInclude) {
                        Write-Log "Re-including whitelisted file: $file" -Console
                        $shouldSkip = $false
                    }
                }
                if ($shouldSkip) {
                    Write-Log "Skipping excluded file: $file"
                    $skippedCount++
                    continue
                }

                $relativeFilePath = $file.Replace("$normalizedBaseDirectory\", '')

                # Debug: Check if the replacement worked properly
                if ($relativeFilePath -eq $file) {
                    # Replacement didn't work, try alternative method
                    Write-Log "WARNING: Standard replacement failed for file: $file" -Console
                    Write-Log "BaseDirectory: $normalizedBaseDirectory" -Console

                    # Try using Resolve-Path or manual substring
                    try {
                        $filePathResolved = (Resolve-Path $file).Path
                        if ($filePathResolved.StartsWith($normalizedBaseDirectory)) {
                            $relativeFilePath = $filePathResolved.Substring($normalizedBaseDirectory.Length).TrimStart('\')
                            Write-Log "Alternative method worked. Relative path: $relativeFilePath" -Console
                        } else {
                            Write-Log "ERROR: File path doesn't start with base directory!" -Error
                            Write-Log "File: $filePathResolved" -Error
                            Write-Log "Base: $normalizedBaseDirectory" -Error
                            continue
                        }
                    } catch {
                        Write-Log "ERROR: Could not resolve paths for relative calculation: $_" -Error
                        continue
                    }
                }

                $isDirectory = (Get-Item $file) -is [System.IO.DirectoryInfo]

                if ($isDirectory) {
                    Write-Log "Adding directory: $relativeFilePath"
                    $zipFileEntry = $zipFile.CreateEntry("$relativeFilePath\")
                    $addedCount++
                }
                else {
                    # Check if file exists and is accessible
                    if (-not (Test-Path $file -PathType Leaf)) {
                        Write-Log "Warning: File not found or not accessible: $file" -Console
                        continue
                    }

                    Write-Log "Adding file: $relativeFilePath (Size: $((Get-Item $file).Length) bytes)"
                    $zipFileEntry = $zipFile.CreateEntry($relativeFilePath, $compressionLevel)
                    $zipFileStreamEntry = $zipFileEntry.Open()
                    $sourceFileStream = [System.IO.File]::OpenRead($file)
                    $sourceFileStream.CopyTo($zipFileStreamEntry)
                    $addedCount++
                }
            }
            catch {
                Write-Log "Error adding file '$file' to ZIP: $_" -Error
                # Don't break the entire process for one file error, but log it
                $skippedCount++
            }
            finally {
                # Properly dispose of streams for this file
                if ($sourceFileStream) { $sourceFileStream.Dispose() }
                if ($zipFileStreamEntry) { $zipFileStreamEntry.Dispose() }
            }
        }

        Write-Log "ZIP creation completed. Added: $addedCount, Skipped: $skippedCount" -Console

    }
    catch {
        Write-Log "CRITICAL ERROR in New-ZipArchive: $_" -Error

        # Clean up the partial ZIP file
        if ($zipFile) { $zipFile.Dispose() }
        if ($zipFileStream) { $zipFileStream.Dispose() }
        if (Test-Path $TargetPath) {
            Remove-Item $TargetPath -Force -ErrorAction SilentlyContinue
        }

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'build-package-failed' -Message "ZIP creation failed: $_"
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log "ZIP creation failed: $_" -Error
        exit 1
    }
    finally {
        # Properly dispose of main ZIP resources
        if ($zipFile) {
            $zipFile.Dispose()
            Write-Log "ZIP file disposed successfully" -Console
        }
        if ($zipFileStream) {
            $zipFileStream.Dispose()
            Write-Log "ZIP file stream disposed successfully" -Console
        }
    }

    # Verify the created ZIP file
    if (Test-Path $TargetPath) {
        $zipSize = (Get-Item $TargetPath).Length
        Write-Log "ZIP file created successfully. Size: $zipSize bytes" -Console

        # Quick verification that the ZIP is readable
        try {
            $testZip = [System.IO.Compression.ZipFile]::OpenRead($TargetPath)
            $entryCount = $testZip.Entries.Count
            $testZip.Dispose()
            Write-Log "ZIP verification successful. Contains $entryCount entries" -Console
        }
        catch {
            Write-Log "Warning: ZIP file may be corrupted. Verification failed: $_" -Error
        }
    }
    else {
        Write-Log "ERROR: ZIP file was not created at expected path: $TargetPath" -Error
    }
}
