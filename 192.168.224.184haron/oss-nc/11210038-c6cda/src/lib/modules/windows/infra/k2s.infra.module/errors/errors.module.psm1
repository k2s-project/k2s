# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

enum Severity {
    Warning = 3
    Error = 4
}

class Error {
    [Severity]$Severity
    [string]$Code
    [string]$Message
}

function New-Error {
    param (
        [Parameter(Mandatory = $false)]
        [Severity]$Severity = [Severity]::Error,
        [Parameter(Mandatory = $false)]
        [string]$Code = $(throw 'Code not specified'),
        [Parameter(Mandatory = $false)]
        [string]$Message = $(throw 'Message not specified')
    )
    $err = [Error]::new()
    $err.Severity = $Severity
    $err.Code = $Code
    $err.Message = $Message
    return $err
}

function Get-ErrCodeSystemNotInstalled { 'system-not-installed' }

function Get-ErrCodeSystemNotRunning { 'system-not-running' }

function Get-ErrCodeSystemRunning { 'system-running' }

function Get-ErrCodeUserCancellation { 'op-cancelled-by-user' }

function Get-ErrCodeWrongSetupType { 'wrong-setup-type' }

Export-ModuleMember -Function New-Error, Get-ErrCodeSystemNotInstalled, Get-ErrCodeSystemNotRunning, 
Get-ErrCodeSystemRunning, Get-ErrCodeUserCancellation, Get-ErrCodeWrongSetupType
