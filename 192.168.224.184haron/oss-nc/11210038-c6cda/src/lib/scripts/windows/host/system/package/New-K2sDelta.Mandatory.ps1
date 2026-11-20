# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Mandatory file inclusion helpers

<#
.SYNOPSIS
    Ensures a mandatory file is included in the delta package.

.DESCRIPTION
    Copies a required file from the new package to staging if not already present.
    Returns whether the file was added and updates the provided lists.

.PARAMETER RelativePath
    Relative path of the file within the package.

.PARAMETER NewExtract
    Path to extracted new package.

.PARAMETER StageDir
    Path to staging directory.

.PARAMETER Label
    Display label for logging (e.g., "k2s.exe").

.PARAMETER Added
    Reference to added files array (will be updated if file is added).

.PARAMETER Changed
    Reference to changed files array (will be updated if file is added).

.OUTPUTS
    PSCustomObject with properties:
    - Success: $true if file is now in staging
    - WasAdded: $true if file was copied (not already present)
    - Warning: Warning message if file not found in source
#>
function Ensure-MandatoryFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Ensure is clearer for this use case')]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RelativePath,

        [Parameter(Mandatory = $true)]
        [string] $NewExtract,

        [Parameter(Mandatory = $true)]
        [string] $StageDir,

        [Parameter(Mandatory = $true)]
        [string] $Label,

        [Parameter(Mandatory = $false)]
        [ref] $Added,

        [Parameter(Mandatory = $false)]
        [ref] $Changed
    )

    $result = [pscustomobject]@{
        Success  = $false
        WasAdded = $false
        Warning  = $null
    }

    $source = Join-Path $NewExtract $RelativePath
    $dest = Join-Path $StageDir $RelativePath

    if (-not (Test-Path -LiteralPath $source)) {
        $result.Warning = "$Label not found in new package - delta update may fail!"
        Write-Log "[Warning] $($result.Warning)" -Console
        return $result
    }

    if (Test-Path -LiteralPath $dest) {
        Write-Log "[Mandatory] $Label already staged" -Console
        $result.Success = $true
        return $result
    }

    # Ensure destination directory exists
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    Write-Log "[Mandatory] Adding $Label to delta package (required for update execution)" -Console
    Copy-Item -LiteralPath $source -Destination $dest -Force

    # Update tracking arrays if provided
    if ($Changed -and $Added) {
        if ($RelativePath -notin $Added.Value -and $RelativePath -notin $Changed.Value) {
            $Changed.Value += $RelativePath
        }
    }

    $result.Success = $true
    $result.WasAdded = $true
    return $result
}

<#
.SYNOPSIS
    Ensures all mandatory files are included in the delta package.

.DESCRIPTION
    Copies k2s.exe, update.module.psm1, and Apply-Delta.ps1 to staging.
    These files are required for delta update execution.

.PARAMETER Context
    Hashtable containing: NewExtract, StageDir, ScriptRoot, Added, Changed

.OUTPUTS
    PSCustomObject with properties:
    - Success: $true if all mandatory files were processed
    - Warnings: Array of warning messages for missing files
#>
function Ensure-MandatoryFiles {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Ensure is clearer for this use case')]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Context
    )

    $result = [pscustomobject]@{
        Success  = $true
        Warnings = @()
    }

    # Ensure k2s.exe
    $k2sResult = Ensure-MandatoryFile -RelativePath 'k2s.exe' `
        -NewExtract $Context.NewExtract `
        -StageDir $Context.StageDir `
        -Label 'k2s.exe' `
        -Added ([ref]$Context.Added) `
        -Changed ([ref]$Context.Changed)

    if ($k2sResult.Warning) { $result.Warnings += $k2sResult.Warning }

    # Ensure VERSION file (critical for version tracking after upgrade)
    $versionResult = Ensure-MandatoryFile -RelativePath 'VERSION' `
        -NewExtract $Context.NewExtract `
        -StageDir $Context.StageDir `
        -Label 'VERSION file' `
        -Added ([ref]$Context.Added) `
        -Changed ([ref]$Context.Changed)

    if ($versionResult.Warning) { $result.Warnings += $versionResult.Warning }

    # Ensure update module
    $updateModuleRelPath = 'lib/modules/windows/cluster/k2s.cluster.module/update/update.module.psm1'
    $updateResult = Ensure-MandatoryFile -RelativePath $updateModuleRelPath `
        -NewExtract $Context.NewExtract `
        -StageDir $Context.StageDir `
        -Label 'update module' `
        -Added ([ref]$Context.Added) `
        -Changed ([ref]$Context.Changed)

    if ($updateResult.Warning) { $result.Warnings += $updateResult.Warning }

    # Copy Apply-Delta.ps1 from template
    $templatePath = Join-Path $Context.ScriptRoot 'scripts/Apply-Delta.template.ps1'
    $applyScriptPath = Join-Path $Context.StageDir 'Apply-Delta.ps1'

    if (Test-Path -LiteralPath $templatePath) {
        Copy-Item -LiteralPath $templatePath -Destination $applyScriptPath -Force
        Write-Log "[Mandatory] Created Apply-Delta.ps1 wrapper script" -Console
    }
    else {
        $result.Warnings += "Apply-Delta.ps1 template not found at: $templatePath"
        Write-Log "[Warning] Apply-Delta.ps1 template not found - creating inline" -Console
        # Fallback: create minimal inline script
        New-ApplyDeltaScriptInline -OutputPath $applyScriptPath
    }

    return $result
}

<#
.SYNOPSIS
    Creates Apply-Delta.ps1 script inline as fallback.

.DESCRIPTION
    Used when the template file is not found. Creates a minimal wrapper script.

.PARAMETER OutputPath
    Path where the script should be written.
#>
function New-ApplyDeltaScriptInline {
    param(
        [Parameter(Mandatory = $true)]
        [string] $OutputPath
    )

    $content = @'
# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0
#Requires -RunAsAdministrator
Param(
    [switch] $ShowLogs = $false,
    [switch] $ShowProgress = $false
)
$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$updateModulePath = Join-Path $scriptRoot 'lib\modules\windows\cluster\k2s.cluster.module\update\update.module.psm1'
if (-not (Test-Path -LiteralPath $updateModulePath)) {
    Write-Host "[ERROR] Update module not found" -ForegroundColor Red
    exit 1
}
Import-Module $updateModulePath -Force
Push-Location $scriptRoot
try {
    $result = PerformClusterUpdate -ShowLogs:$ShowLogs -ShowProgress:$ShowProgress
    if (-not $result) { exit 1 }
} finally {
    Pop-Location
}
'@
    $content | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
}
