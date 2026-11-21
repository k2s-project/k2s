# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# Define the URL and file paths
$zipUrl = 'https://github.com/ory/hydra/releases/download/v26.2.0/hydra_26.2.0-windows_sqlite_64bit.zip'
$zipFilePath = "$PSScriptRoot\hydra_26.2.0-windows_sqlite_64bit.zip"
$extractPath = "$PSScriptRoot\hydra_extracted"

# Download the ZIP file
Write-Output "Downloading ZIP file from $zipUrl..."
Invoke-WebRequest -Uri $zipUrl -OutFile $zipFilePath

# Create the extraction directory if it doesn't exist
if (-Not (Test-Path -Path $extractPath)) {
    New-Item -ItemType Directory -Path $extractPath | Out-Null
}

# Extract the ZIP file
Write-Output "Extracting ZIP file to $extractPath..."
Expand-Archive -Path $zipFilePath -DestinationPath $extractPath -Force

# Move hydra.exe to the current directory
$hydraExePath = Join-Path -Path $extractPath -ChildPath 'hydra.exe'
if (Test-Path -Path $hydraExePath) {
    Move-Item -Path $hydraExePath -Destination $PSScriptRoot -Force
    Write-Output "hydra.exe extracted and moved to $PSScriptRoot."
}
else {
    Write-Error 'hydra.exe not found in the extracted files.'
}

# Clean up (optional)
Remove-Item -Path $zipFilePath -Force
Remove-Item -Path $extractPath -Recurse -Force
