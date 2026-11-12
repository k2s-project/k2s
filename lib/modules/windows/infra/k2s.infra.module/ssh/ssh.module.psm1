# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$logModule = "$PSScriptRoot\..\log\log.module.psm1"

Import-Module $logModule

<#
.SYNOPSIS
Removes all entries of a host from the current user's known_hosts file.

.DESCRIPTION
Wraps 'ssh-keygen.exe -R'. Win32-OpenSSH writes messages like "Host x not found in known_hosts"
to stderr, and ssh-keygen.exe can then block forever when stderr is an anonymous pipe. A PowerShell
'2>&1' redirection or any pipeline over the native call creates exactly such a pipe, so the tool is
started with its output redirected to temporary files instead and bounded by a timeout. Its output
is written to the log.

.PARAMETER HostName
The IP address or host name whose entries shall be removed.

.PARAMETER TimeoutSeconds
Maximum time to wait for ssh-keygen.exe before it is terminated.
#>
function Remove-SshKnownHostEntry {
    param (
        [Parameter(Mandatory = $true)]
        [string]$HostName,
        [ValidateRange(1, 600)]
        [int]$TimeoutSeconds = 30
    )

    if (-not (Get-Command 'ssh-keygen.exe' -ErrorAction SilentlyContinue)) {
        Write-Log "[SSH] ssh-keygen.exe not found, skip removing '$HostName' from known_hosts"
        return
    }

    $stdOutFile = [System.IO.Path]::GetTempFileName()
    $stdErrFile = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process -FilePath 'ssh-keygen.exe' -ArgumentList @('-R', $HostName) -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdOutFile -RedirectStandardError $stdErrFile
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Write-Log "[SSH] 'ssh-keygen.exe -R $HostName' did not finish within $TimeoutSeconds seconds, terminating it"
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        Get-Content -Path $stdOutFile, $stdErrFile -ErrorAction SilentlyContinue | ForEach-Object { "$_" } | Write-Log
    }
    finally {
        Remove-Item -Path $stdOutFile, $stdErrFile -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Remove-SshKnownHostEntry
