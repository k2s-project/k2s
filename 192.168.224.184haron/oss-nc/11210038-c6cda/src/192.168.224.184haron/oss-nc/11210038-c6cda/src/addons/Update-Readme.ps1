# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

Import-Module "$PSScriptRoot\..\lib\modules\windows\infra\k2s.infra.module\yaml\yaml.module.psm1"

$ErrorActionPreference = 'Stop'

Write-Output 'Updating the addons README file started'

$manifestFileName = 'addon.manifest.yaml'
$readmeFileName = 'README.md'

Write-Output "Looking for '$manifestFileName' files in '$PSScriptRoot'.."

$addons = [System.Collections.ArrayList]@()

Get-ChildItem -File -Recurse -Depth 1 -Path $PSScriptRoot -Filter $manifestFileName `
| ForEach-Object { 
    $addon = Get-FromYamlFile -Path $_.FullName
    $addons.Add($addon) | Out-Null
}

Write-Output "Found $($addons.Count) addons, creating markdown table.."

$newLines = [System.Collections.ArrayList]::new(('|Addon|Description|', '|---|---|'))

$lines = [System.Collections.ArrayList]@()
foreach ($addonManifest in $addons) {
    foreach ($implementation in $addonManifest.spec.implementations) {
        $addonName = $addonManifest.metadata.name
        $readmePath = "./$($addonManifest.metadata.name)/$readmeFileName"
        if ($addonManifest.metadata.name -ne $implementation.name) {
            $addonName += " $($implementation.name)"
            $readmePath = "./$($addonManifest.metadata.name)/$($implementation.name)/$readmeFileName"
        }
        $lines.Add("| [$($addonName)]($readmePath) | $($implementation.description) | ")
    }
}

$newLines.AddRange($lines) | Out-Null

$path = "$PSScriptRoot\$readmeFileName"
$content = Get-Content -Path $path
$lines = [System.Collections.ArrayList]::new($content)

$startIndex = -1
$endIndex = -1

for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'addons-list-start') {
        $startIndex = $i
        Write-Output "  found start of generated section at index $i"
        continue
    }
    
    if ($lines[$i] -match 'addons-list-end') {
        $endIndex = $i
        Write-Output "  found end of generated section at index $i"
        break
    }
}

if ($startIndex -lt 0 -or $endIndex -lt 0) {
    throw "invalid indices [$startIndex,$endIndex]"
}

Write-Output 'Removing old list..'

$lines.RemoveRange($startIndex + 1, $endIndex - $startIndex - 1)

Write-Output 'Inserting new list..'

$lines.InsertRange($startIndex + 1, $newLines)

Write-Output "Writing updated content to $path.."

$lines | Set-Content -Path $path -Force

Write-Output 'DONE'
