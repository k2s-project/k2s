# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Setup Windows Autoconfiguration APIPA to not kick in
https://www.it-administrator.de/lexikon/automatic_private_ip_adressing.html

Like
reg.exe add HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters /v IPAutoconfigurationEnabled /t REG_DWORD /d 0 /f

#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Reset to default setting')]
    [switch] $EnableAutoConf = $false
)

# load global settings
&$PSScriptRoot\common\GlobalVariables.ps1

#Set-PSDebug -Trace 1

$Path = 'HKLM:SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
$Name = 'IPAutoconfigurationEnabled'
$PropertyType = 'DWord'
if ($EnableAutoConf) {
    $NewValue = 1
}
else {
    $NewValue = 0
}

if ($(Get-ItemProperty -Path $path -Name $Name -ErrorAction 'SilentlyContinue')) {
    $oldValue = $( Get-ItemPropertyValue -Path $path -Name $Name -ErrorAction 'SilentlyContinue' )
    #Write-Output "Old value: $oldValue"
}

if ($oldValue -ne $NewValue) {
    if ($(Get-Service -Name kubelet -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Write-Output "First stop complete kubernetes incl. VM"
        &"$global:KubernetesPath\lib\scripts\windows\host\stop\stop.ps1"
    }

    Write-Output "Changing registry, set $Name to $NewValue"
    Set-ItemProperty -Path $path -Name $Name -Value $NewValue -Type $PropertyType -ErrorAction 'Stop'

    Write-Output "`nWindows Autoconfiguration settings were changed. This will take effect"
    Write-Output "after next Windows start. You have to reboot now, sorry.`n"
    Write-Output "*** PLEASE REBOOT THE COMPUTER TO COMPLETE CLEANUP ***`n" -ForegroundColor Red
}
else {
    Write-Output 'Windows Autoconfiguration settings were already ok, no changes.'
}

# maybe?
# Remove-ItemProperty -Path $path -Name $Name -ErrorAction 'Stop'


