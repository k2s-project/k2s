# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
K2s Code Signing Module

.DESCRIPTION
This module provides functionality for creating and managing code signing certificates
for K2s executables and scripts. All certificates are stored in the LocalMachine certificate store,
which requires administrator privileges for installation and management.

.NOTES
Administrator privileges are required to install certificates to the LocalMachine store.
#>

$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
Signs all K2s executables and PowerShell scripts in a directory

.DESCRIPTION
Recursively finds and signs all PowerShell scripts (.ps1, .psm1), executable files (.exe, .dll), 
and installer packages (.msi) in the specified directory using the provided certificate. 
The certificate will be imported to the LocalMachine\My store if not already present.

Note: CMD and BAT files cannot be Authenticode signed as they are plain text files.

.PARAMETER SourcePath
Root directory to search for files to sign

.PARAMETER CertificatePath
Path to the code signing certificate (.pfx file)

.PARAMETER Password
Password for the certificate file

.PARAMETER ExclusionList
Array of file paths or directory paths to exclude from signing

.NOTES
Requires administrator privileges to install the certificate in the LocalMachine\My store.

.EXAMPLE
Set-K2sFileSignature -SourcePath "C:\k2s" -CertificatePath "C:\certs\signing.pfx" -Password $securePassword
#>
function Set-K2sFileSignature {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [Parameter(Mandatory)]
        [string]$CertificatePath,
        [SecureString]$Password,
        [string[]]$ExclusionList = @()
    )

    if (-not (Test-Path $SourcePath)) {
        throw "Source path does not exist: $SourcePath"
    }

    if (-not (Test-Path $CertificatePath)) {
        throw "Certificate file not found: $CertificatePath"
    }

    Write-Log "Starting code signing process for: $SourcePath" -Console
    Write-Log "Using certificate: $CertificatePath" -Console

    try {
        Write-Log "Importing certificate to certificate store..." -Console
        $cert = Import-PfxCertificate -FilePath $CertificatePath -CertStoreLocation Cert:\LocalMachine\My -Password $Password
        Write-Log "Certificate imported successfully. Thumbprint: $($cert.Thumbprint)" -Console        
    }
    catch {
        throw "Failed to access or import certificate: $_"
    }

    # Get all signable files
    $filesToSign = Get-SignableFiles -Path $SourcePath -ExclusionList $ExclusionList

    if ($filesToSign.Count -eq 0) {
        Write-Log "No files found to sign." -Console
        return
    }

    Write-Log "Found $($filesToSign.Count) files to sign" -Console

    $signedCount = 0
    $failedCount = 0

    foreach ($file in $filesToSign) {
        try {
            Write-Log "Signing: $file" -Console
            
            # Sign file (works for both executables and PowerShell scripts)
            Set-AuthenticodeSignature -FilePath $file -Certificate $cert | Out-Null
            
            # Verify the signature
            $signature = Get-AuthenticodeSignature -FilePath $file
            if ($signature.Status -eq 'Valid') {
                $signedCount++
                Write-Log "Successfully signed: $file" -Console
            }
            elseif ($signature.Status -eq 'UnknownError' -and $signature.StatusMessage -like "*not trusted*") {
                # For self-signed certificates, this is expected if not installed in Trusted Root
                $signedCount++
                Write-Log "Signed with self-signed certificate (not in trusted root): $file" -Console
                Write-Log "Note: Install certificate to Trusted Root store for full trust validation" -Console
            }
            else {
                $failedCount++
                Write-Log "Failed to sign (status: $($signature.Status)): $file" -Error
                Write-Log "Status message: $($signature.StatusMessage)" -Error
            }
        }
        catch {
            $failedCount++
            Write-Log "Failed to sign: $file - Error: $_" -Error
        }
    }

    Write-Log "Code signing completed. Signed: $signedCount, Failed: $failedCount" -Console

    if ($failedCount -gt 0) {
        throw "Code signing failed for $failedCount files"
    }
}

<#
.SYNOPSIS
Gets a list of files that can be code signed

.DESCRIPTION
Recursively searches a directory for PowerShell scripts, executable files, dynamic libraries,
and installer packages that can be Authenticode signed, excluding specified paths.

Note: CMD and BAT files are excluded as they cannot be Authenticode signed.

.PARAMETER Path
Root directory to search

.PARAMETER ExclusionList
Array of file paths or directory paths to exclude

.EXAMPLE
Get-SignableFiles -Path "C:\k2s" -ExclusionList @("C:\k2s\.git", "C:\k2s\temp")
#>
function Get-SignableFiles {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string[]]$ExclusionList = @()
    )

    if (-not (Test-Path $Path)) {
        throw "Path does not exist: $Path"
    }

    # Extensions of files that can be Authenticode signed
    # Note: CMD and BAT files are plain text and cannot be Authenticode signed
    $signableExtensions = @(
        '*.ps1',    # PowerShell scripts
        '*.psm1',   # PowerShell modules  
        '*.exe',    # Executables
        '*.dll',    # Dynamic libraries
        '*.msi'     # Installer packages
    )
    
    $allFiles = @()
    
    foreach ($extension in $signableExtensions) {
        $files = Get-ChildItem -Path $Path -Filter $extension -Recurse -File | ForEach-Object { $_.FullName }
        $allFiles += $files
    }

    # Filter out excluded files
    $filteredFiles = @()
    foreach ($file in $allFiles) {
        $shouldExclude = $false
        
        foreach ($exclusion in $ExclusionList) {
            if ($file -eq $exclusion -or $file.StartsWith($exclusion)) {
                $shouldExclude = $true
                break
            }
        }
        
        if (-not $shouldExclude) {
            $filteredFiles += $file
        }
    }

    return $filteredFiles
}

Export-ModuleMember -Function @(
    'Set-K2sFileSignature',
    'Get-SignableFiles'
)
