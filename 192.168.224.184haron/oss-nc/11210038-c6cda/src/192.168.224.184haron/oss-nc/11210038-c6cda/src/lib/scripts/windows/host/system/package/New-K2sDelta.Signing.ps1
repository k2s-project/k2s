# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Code signing helpers

<#
.SYNOPSIS
    Signs executable and script files in the staging directory.

.DESCRIPTION
    Delegates to Set-K2sFileSignature from the signing module (k2s.signing.module)
    which handles certificate store import, self-signed certificate validation,
    and proper file type filtering. Logs warnings for files that fail to sign
    but does not throw.

.PARAMETER Context
    Hashtable containing:
    - StageDir: Directory containing files to sign
    - CertificatePath: Path to .pfx certificate file
    - Password: Certificate password (plain string)

.OUTPUTS
    PSCustomObject with properties:
    - Success: $true if signing completed (even with warnings)
    - SignedCount: Number of successfully signed files
    - FailedCount: Number of files that failed to sign
    - Skipped: $true if signing was skipped due to missing parameters
    - Error: Error message if signing setup failed
#>
function Invoke-DeltaCodeSigning {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Context
    )

    $result = [pscustomobject]@{
        Success     = $false
        SignedCount = 0
        FailedCount = 0
        Skipped     = $false
        Error       = $null
    }

    # Check if both parameters are provided
    if (-not $Context.CertificatePath -or -not $Context.Password) {
        if ($Context.CertificatePath -or $Context.Password) {
            Write-Log "[Warning] Both -CertificatePath and -Password must be specified for signing; skipping signing."
        }
        $result.Skipped = $true
        $result.Success = $true
        return $result
    }

    Write-Log "[Signing] Attempting code signing using certificate '$($Context.CertificatePath)'" -Console

    try {
        # Convert plain password to SecureString for Set-K2sFileSignature
        $securePassword = ConvertTo-SecureString -String $Context.Password -AsPlainText -Force

        # Delegate to the production signing module which handles:
        # - Certificate store import (Import-PfxCertificate)
        # - Self-signed certificate validation (UnknownError + "not trusted" = OK)
        # - Proper file type filtering (exe, dll, ps1, psm1, psd1, msi)
        Set-K2sFileSignature -SourcePath $Context.StageDir `
            -CertificatePath $Context.CertificatePath `
            -Password $securePassword `
            -ExclusionList @()

        $result.Success = $true
        Write-Log "[Signing] Code signing completed successfully" -Console
    }
    catch {
        $errorMsg = $_.Exception.Message
        if ($errorMsg -match 'failed for (\d+) files') {
            # Set-K2sFileSignature throws when files fail - extract count
            $result.FailedCount = [int]$matches[1]
            Write-Log "[Signing][Warning] $errorMsg" -Console
            # Treat as non-fatal for delta packages (third-party binaries may resist signing)
            $result.Success = $true
        } else {
            Write-Log "[Signing][Error] Code signing failed: $errorMsg" -Console
            $result.Error = $errorMsg
        }
    }

    return $result
}
