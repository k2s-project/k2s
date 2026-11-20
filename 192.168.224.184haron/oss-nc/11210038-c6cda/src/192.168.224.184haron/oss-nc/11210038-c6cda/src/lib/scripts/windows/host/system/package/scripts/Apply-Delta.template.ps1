# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Applies the K2s delta update package.
.DESCRIPTION
    This script provides a convenient wrapper to apply the delta update using the
    update.module.psm1 included in this delta package. It must be executed from
    the extracted delta package directory.
.PARAMETER ShowLogs
    Display detailed log output during the update process.
.PARAMETER ShowProgress
    Show progress indicators during the update phases.
#>

#Requires -RunAsAdministrator

Param(
    [Parameter(Mandatory = $false)]
    [switch] $ShowLogs = $false,
    [Parameter(Mandatory = $false)]
    [switch] $ShowProgress = $false
)

$ErrorActionPreference = 'Stop'

# Determine the delta package path (this script's directory contains the extracted delta)
$scriptRoot = $PSScriptRoot
$deltaManifestPath = Join-Path $scriptRoot 'delta-manifest.json'

if (-not (Test-Path -LiteralPath $deltaManifestPath)) {
    Write-Host "[ERROR] delta-manifest.json not found in $scriptRoot" -ForegroundColor Red
    Write-Host "[ERROR] This script must be run from the root of the extracted delta package directory." -ForegroundColor Red
    exit 1
}

# Load the update module from the delta package
$updateModulePath = Join-Path $scriptRoot 'lib\modules\windows\cluster\k2s.cluster.module\update\update.module.psm1'
if (-not (Test-Path -LiteralPath $updateModulePath)) {
    Write-Host "[ERROR] Update module not found at: $updateModulePath" -ForegroundColor Red
    Write-Host "[ERROR] The delta package may be incomplete or corrupted." -ForegroundColor Red
    exit 2
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "K2s Delta Update" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Importing update module..." -ForegroundColor Yellow

try {
    Import-Module $updateModulePath -Force
} catch {
    Write-Host "[ERROR] Failed to import update module: $($_.Exception.Message)" -ForegroundColor Red
    exit 3
}

Write-Host "Starting delta update process..." -ForegroundColor Yellow
Write-Host ""

# Test the update by executing from the current directory (delta root)
# No need to repackage - PerformClusterUpdate now expects to run from extracted delta directory
Write-Host "Testing delta update from current directory..." -ForegroundColor Yellow
Write-Host "Delta root: $scriptRoot" -ForegroundColor Gray

try {
    # Change to the script root directory (where delta-manifest.json is)
    Push-Location $scriptRoot

    # Execute the update - it will detect delta-manifest.json in current directory
    $result = PerformClusterUpdate -ShowLogs:$ShowLogs -ShowProgress:$ShowProgress

    Pop-Location

    if ($result) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "Delta update completed successfully!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Red
        Write-Host "Delta update failed!" -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Red
        exit 4
    }
} catch {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "Delta update encountered an error:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    exit 5
} finally {
    # No temporary zip to cleanup - we execute directly from the directory
}
