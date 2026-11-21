# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
Invokes the ctr.exe CLI with the given arguments and handles stderr suppression.

.DESCRIPTION
ctr.exe writes containerd config deprecation warnings to stderr which causes
PowerShell to treat the invocation as failed under $ErrorActionPreference = 'Stop'.
This wrapper temporarily switches to 'Continue' and captures stderr so that real
errors are still logged while harmless deprecation warnings are ignored.

.PARAMETER Arguments
The arguments to pass to ctr.exe (e.g. '-n', 'k8s.io', 'images', 'import', $path).

.OUTPUTS
[bool] $true when ctr.exe exits with code 0, $false otherwise.
#>
function Invoke-Ctr {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $false)]
        [string]$CtrExePath = ''
    )

    $resolvedCtrExe = if ($CtrExePath -ne '') { $CtrExePath } else { "$(Get-KubeBinPath)\containerd\ctr.exe" }

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $resolvedCtrExe @Arguments 2>&1
        $ctrExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEAP
    }

    if ($ctrExitCode -ne 0) {
        $errLines = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
        if ($errLines.Count -gt 0) {
            Write-Log "[ctr] $($errLines -join '; ')"
        }
    }

    return ($ctrExitCode -eq 0)
}

Export-ModuleMember -Function Invoke-Ctr
