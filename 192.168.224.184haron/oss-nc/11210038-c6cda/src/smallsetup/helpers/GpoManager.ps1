# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.DESCRIPTION
Operations to be performed during startup/shutdown of Windows host machine aka node,
this script provides a way to register a script based on Group Policy Object which shall be invoked during startup/shutdown.
.EXAMPLE

To register stop during shutdown
PS> .\smallsetup\helpers\GpoManager.ps1 -method "Shutdown" -methodscript "C:\k\lib\scripts\windows\host\stop\stop.ps1"

To cleanup registered Shutdown GPO
PS> .\smallsetup\helpers\GpoManager.ps1 -method "Shutdown" -cleanup
#>

Param (
    [parameter(Mandatory = $true, HelpMessage="Script to be invoked")]
    [ValidateSet('Startup', 'Shutdown')]
    [string] $method,
    [parameter(Mandatory = $false, HelpMessage="Script to be invoked")]
    [string] $methodScript = 'C:\k\lib\scripts\windows\host\stop\stop.ps1',
    [parameter(Mandatory = $false, HelpMessage="Cleanup registered GPO")]
    [switch] $cleanup = $false
)

$GpoName = "k2sGP$method"
$methodPath = "$ENV:systemRoot\System32\GroupPolicy\Machine\Scripts\$method"
$RegistryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy"

$RegistryScriptsPath = "$RegistryPath\Scripts\$method\0"
$RegistrySmScriptsPath = "$RegistryPath\State\Machine\Scripts\$method\0"


function CleanupGPO {
    param ([string] $item)
    Write-Output "Cleaning GPO in $item"
    if (Test-Path $item) {
        if ((Get-ItemPropertyValue $item -Name GPOName -ErrorAction SilentlyContinue) -eq $GpoName) {
            Write-Output "Removing base $item"
            Remove-Item -path $item -Recurse
        } else {
            #Look for k2s GPO in the list
            $iterator = 0
            while ((Test-Path "$item\$iterator")) {
                if ($null -ne (Get-ItemProperty "$item\$iterator" -Name Isk2s -ErrorAction SilentlyContinue)){
                    Write-Output "Removing from base $item\$iterator"
                    Remove-Item "$item\$iterator" -Recurse
                    break
                }
                $iterator++
            }
        }
    }
}

if ($cleanup) {
    Write-Output "Cleaning up registered GPO for k2s!"
    $cleanupItems = "$RegistryScriptsPath", "$RegistrySmScriptsPath"
    foreach ($cleanupItem in $cleanupItems) {
        CleanupGPO $cleanupItem
    }

    return
}

$methodPath = "$ENV:systemRoot\System32\GroupPolicy\Machine\Scripts\$method"
if (-not (Test-Path $methodPath)) {
    New-Item -path $methodPath -itemType Directory
}

$items = @("$RegistryScriptsPath", "$RegistrySmScriptsPath")
foreach ($item in $items) {

    if (Test-Path $item) {
        Write-Output "Base already exists $item"
        continue
    } else {
        # If the base path does not exist then create one
        New-Item -path "$item\0" -force
    }

    New-ItemProperty -path "$item" -name DisplayName -propertyType String -value "Local Group Policy" -force
    New-ItemProperty -path "$item" -name FileSysPath -propertyType String -value "$ENV:systemRoot\System32\GroupPolicy\Machine" -force
    New-ItemProperty -path "$item" -name GPO-ID -propertyType String -value "LocalGPO" -force
    New-ItemProperty -path "$item" -name GPOName -propertyType String -value $GpoName -force
    New-ItemProperty -path "$item" -name PSScriptOrder -propertyType DWord -value 2 -force
    New-ItemProperty -path "$item" -name SOM-ID -propertyType String -value "Local" -force
}

$iteration = 0
while (Test-Path "$RegistryScriptsPath\$iteration") {

    if ((Get-ItemPropertyValue "$RegistryScriptsPath" -Name GPOName -ErrorAction SilentlyContinue) -eq $GpoName) {
        Write-Output "Found GP at $RegistryScriptsPath\$iteration"
        break
    }

    if ($null -ne (Get-ItemProperty "$RegistryScriptsPath\$iteration" -Name Isk2s -ErrorAction SilentlyContinue)) {
        Write-Output "Found GP at $RegistryScriptsPath\$iteration"
        break
    }
    $iteration++
}

$items = @("$RegistryScriptsPath\$iteration", "$RegistrySmScriptsPath\$iteration")
foreach ($item in $items) {
    if (-not (Test-Path $item)) {
        New-Item -path $item -force
    }
}

$BinaryString = "00,00,00,00,00,00,00,00,00,00,00,00,00,00,00,00"
$ExecTime = $BinaryString.Split(',') | ForEach-Object {"0x$_"}
$items = @("$RegistryScriptsPath\$iteration", "$RegistrySmScriptsPath\$iteration")
foreach ($item in $items) {
    New-ItemProperty -path "$item" -name Isk2s -propertyType DWord -value 1 -force
    New-ItemProperty -path "$item" -name Script -propertyType String -value $methodScript -force
    New-ItemProperty -path "$item" -name Parameters -propertyType String -value $method -force
    New-ItemProperty -path "$item" -name IsPowershell -propertyType DWord -value 1 -force
    New-ItemProperty -path "$item" -name ExecTime -propertyType Binary -value ([byte[]]$ExecTime) -force
}
