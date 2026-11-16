# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName,
    [Parameter(Mandatory = $true)]
    [string]$AdministratorPassword,
    [Parameter()]
    [string]$DomainName,
    [Parameter(Mandatory = $false)]
    [int]$TimeoutInSeconds = 1800,
    [Parameter(Mandatory = $false)]
    [switch]$NoLog = $false
)

Import-Module "$PSScriptRoot\..\..\..\lib\modules\windows\infra\k2s.infra.module\log\log.module.psm1"

if ($DomainName) {
    $userName = "$DomainName\administrator"
}
else {
    $userName = 'administrator'
}

$pass = ConvertTo-SecureString $AdministratorPassword -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($userName, $pass)
$secondsIncrement = 5
$elapsedSeconds = 0

# Measure the timeout with a wall-clock stopwatch: a failed New-PSSession attempt can block for
# ~30s on its own, so counting only the sleep intervals would stretch the timeout several-fold.
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

if ($NoLog -ne $true) {
    Write-Log "Waiting for connection with VM: '$VMName' (timeout: $($TimeoutInSeconds)s) ..."
}

do {
    $result = New-PSSession -VMName $VMName -Credential $cred -ErrorAction SilentlyContinue

    if (-not $result) {
        Start-Sleep -Seconds $secondsIncrement
        $elapsedSeconds = [int]$stopwatch.Elapsed.TotalSeconds

        if ($NoLog -ne $true) {
            Write-Log "$($elapsedSeconds)s.. " -Progress
        }
    }
} while (-not $result -and $elapsedSeconds -lt $TimeoutInSeconds)

if ($elapsedSeconds -gt 0 -and $NoLog -ne $true) {
    Write-Log '.'
}

$result
