# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Parameter validation and version reading helpers

<#
.SYNOPSIS
    Validates delta package creation parameters.

.DESCRIPTION
    Checks that input packages exist, target directory is valid, and output filename
    has correct extension. Returns a result object with validation status and error details.

.PARAMETER Context
    Hashtable containing: InputPackageOne, InputPackageTwo, TargetDirectory, ZipPackageFileName

.OUTPUTS
    PSCustomObject with properties:
    - Valid: $true if all parameters are valid
    - ErrorMessage: Description of validation failure (if any)
    - ErrorCode: Machine-readable error code for CLI
    - ExitCode: Suggested exit code for script termination
#>
function Test-DeltaPackageParameters {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Context
    )

    $result = [pscustomobject]@{
        Valid        = $false
        ErrorMessage = $null
        ErrorCode    = $null
        ExitCode     = 0
    }

    # Validate InputPackageOne
    if ([string]::IsNullOrWhiteSpace($Context.InputPackageOne) -or -not (Test-Path -LiteralPath $Context.InputPackageOne)) {
        $result.ErrorMessage = "InputPackageOne missing or not found: '$($Context.InputPackageOne)'"
        $result.ErrorCode = 'delta-package-input-not-found'
        $result.ExitCode = 2
        return $result
    }

    # Validate InputPackageTwo
    if ([string]::IsNullOrWhiteSpace($Context.InputPackageTwo) -or -not (Test-Path -LiteralPath $Context.InputPackageTwo)) {
        $result.ErrorMessage = "InputPackageTwo missing or not found: '$($Context.InputPackageTwo)'"
        $result.ErrorCode = 'delta-package-input-not-found'
        $result.ExitCode = 3
        return $result
    }

    # Validate TargetDirectory
    if ('' -eq $Context.TargetDirectory) {
        $result.ErrorMessage = 'The passed target directory is empty'
        $result.ErrorCode = 'build-package-failed'
        $result.ExitCode = 1
        return $result
    }
    if (!(Test-Path -Path $Context.TargetDirectory)) {
        $result.ErrorMessage = "The passed target directory '$($Context.TargetDirectory)' could not be found"
        $result.ErrorCode = 'build-package-failed'
        $result.ExitCode = 1
        return $result
    }

    # Validate ZipPackageFileName
    if ('' -eq $Context.ZipPackageFileName) {
        $result.ErrorMessage = 'The passed zip package name is empty'
        $result.ErrorCode = 'build-package-failed'
        $result.ExitCode = 1
        return $result
    }
    if ($Context.ZipPackageFileName.EndsWith('.zip') -eq $false) {
        $result.ErrorMessage = "The passed zip package name '$($Context.ZipPackageFileName)' does not have the extension '.zip'"
        $result.ErrorCode = 'build-package-failed'
        $result.ExitCode = 1
        return $result
    }

    $result.Valid = $true
    return $result
}

<#
.SYNOPSIS
    Reads the VERSION file from a package extraction directory.

.DESCRIPTION
    Attempts to read and trim the contents of a VERSION file. Returns null if file
    doesn't exist or cannot be read.

.PARAMETER ExtractPath
    Root path of extracted package containing VERSION file.

.OUTPUTS
    String containing version, or $null if not found.
#>
function Get-PackageVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ExtractPath
    )

    $versionFile = Join-Path $ExtractPath 'VERSION'
    if (Test-Path -LiteralPath $versionFile) {
        $version = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction SilentlyContinue)
        if ($version) {
            return $version.Trim()
        }
    }
    return $null
}

function Get-PackageKubernetesVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ExtractPath
    )

    $configModulePath = Join-Path $ExtractPath 'lib\modules\windows\infra\k2s.infra.module\config\config.module.psm1'
    if (-not (Test-Path -LiteralPath $configModulePath)) {
        return $null
    }

    $content = Get-Content -LiteralPath $configModulePath -Raw -ErrorAction SilentlyContinue
    if ($content -match "(?ms)function\s+Get-DefaultK8sVersion\s*\{.*?return\s+['`"](?<version>v?\d+\.\d+\.\d+)['`"]") {
        $version = $matches['version']
        if ($version -notmatch '^v') {
            $version = "v$version"
        }
        return $version
    }

    return $null
}
