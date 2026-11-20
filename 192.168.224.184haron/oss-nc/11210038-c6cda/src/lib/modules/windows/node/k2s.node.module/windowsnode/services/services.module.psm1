# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$infraModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$loopBackAdapterModule = "$PSScriptRoot\..\network\loopbackadapter.module.psm1"
Import-Module $infraModule, $loopBackAdapterModule

$kubeBinPath = Get-KubeBinPath

function Get-IsNssmServiceRunning($name) {
    return $(Get-Service -Name $name -ErrorAction SilentlyContinue).Status -eq "Running"
}

function Start-NssmService($name) {
    $svc = $(Get-Service -Name $name -ErrorAction SilentlyContinue).Status
    if (($svc) -and ($svc -ne 'Running')) {
        Write-Log ('Starting service: ' + $name)
        &$kubeBinPath\nssm start $name
    }
}

function Restart-NssmService($name) {
    $svc = $(Get-Service -Name $name -ErrorAction SilentlyContinue).Status
    if (($svc) -and ($svc -eq 'Running')) {
        Write-Log ('Restarting service: ' + $name)
        &$kubeBinPath\nssm restart $name
    }
}

function Stop-NssmService($name) {
    $svc = $(Get-Service -Name $name -ErrorAction SilentlyContinue).Status
    if (($svc) -and ($svc -ne 'Stopped')) {
        Write-Log ('Stopping service: ' + $name)
        &$kubeBinPath\nssm stop $name
    }
}

function Start-ServiceProcess($serviceName) {
    $svc = $(Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status
    if (($svc) -and ($svc -ne 'Running')) {
        Write-Log ('Starting service: ' + $serviceName)
        Start-Service -Name $serviceName -WarningAction SilentlyContinue
    }
}

function Stop-ServiceProcess($serviceName, $processName) {
    if ($(Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Write-Log ("Stopping running service: " + $serviceName)
        Stop-Service -Name $serviceName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    }
    Stop-Process -Name $processName -Force -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    Outputs node service status.
.DESCRIPTION
    Outputs node service status.
.PARAMETER Iteration
    Iteration no.
.EXAMPLE
    Write-NodeServiceStatus -Iteration 3
#>
function Write-NodeServiceStatus {
    param (
        [Parameter(Mandatory = $true)]
        [int] $Iteration
    )

    $prefix = "State of services (checkpoint $Iteration):"
    $stateFlanneld = $(Get-Service flanneld).Status
    $stateKubelet = $(Get-Service kubelet).Status
    $stateKubeproxy = $(Get-Service kubeproxy).Status
    if ($stateFlanneld -eq 'Running' -and $stateKubelet -eq 'Running' -and $stateKubeproxy -eq 'Running') {
        Write-Log "$prefix All running"
    }
    elseif ($stateFlanneld -eq 'Stopped' -and $stateKubelet -eq 'Stopped' -and $stateKubeproxy -eq 'Stopped') {
        Write-Log "$prefix All STOPPED"
    }
    else {
        Write-Log "$prefix"
        Write-Log "             flanneld:  $stateFlanneld"
        Write-Log "             kubelet:   $stateKubelet"
        Write-Log "             kubeproxy: $stateKubeproxy"
    }

    Write-Log '###################################################'
    Write-Log "flanneld:  $stateFlanneld"
    $adapterName = Get-L2BridgeName
    Get-NetIPAddress -InterfaceAlias $adapterName -ErrorAction SilentlyContinue | Out-Null
}

<#
.SYNOPSIS
    Restarts a specified service if it is running
.DESCRIPTION
    Restarts a specified service if it is running.
.PARAMETER Name
    Name of the service
.EXAMPLE
    Restart-WinService -Name 'WslService'
.NOTES
    Does nothing if the service was not found.
#>
function Restart-WinService {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Name = $(throw 'Please provide the name of the windows service.')
    )

    $svc = $(Get-Service -Name $Name -ErrorAction SilentlyContinue).Status
    if ($svc) {
        Write-Log "Service status before restarting '$Name': $svc"
        Restart-Service $Name -WarningAction SilentlyContinue -Force
        $iteration = 0
        while ($true) {
            $iteration++
            $svcstatus = $(Get-Service -Name $Name -ErrorAction SilentlyContinue).Status
            if ($svcstatus -eq 'Running') {
                Write-Log "Service re-started '$Name' "
                break
            }
            if ($iteration -ge 5) {
                Write-Warning "'$Name' Service is not running !!"
                break
            }
            Write-Log "'$Name' Waiting for service status to be started: $svc"
            Start-Sleep -s 2
        }
        return
    }
    Write-Warning "Service not found: $Name"
}

function Start-WSL() {
    Restart-WinService 'WslService'
    Write-Log 'Disable Remote App authentication warning dialog'
    REG ADD 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' /V 'AuthenticationLevel' /T REG_DWORD /D '0' /F

    Write-Log 'Start KubeMaster with WSL2'
    Start-Process wsl -WindowStyle Hidden
}

<#
.SYNOPSIS
    Re-points an nssm-managed service from one installation path to another.
.DESCRIPTION
    Reads the service's Application, AppDirectory and AppParameters values from the
    nssm registry parameters and replaces every occurrence of the old installation path
    with the new one. This is used when relocating a K2s installation (e.g. after a delta
    update) so that services launch their executables from the new installation folder.

    The replacement is case-insensitive so that minor casing differences in the stored
    paths (e.g. 'C:\k' vs 'c:\k') are handled correctly.
.PARAMETER Name
    Name of the Windows service managed by nssm (e.g. 'containerd', 'flanneld').
.PARAMETER OldPath
    The current installation path that is baked into the service configuration. Trailing
    backslashes are ignored (the value is trimmed before matching).
.PARAMETER NewPath
    The new installation path that should replace the old one. Trailing backslashes are
    ignored (the value is trimmed before substitution).
.PARAMETER NssmPath
    Optional full path to nssm.exe. Defaults to the nssm.exe in the module's bin path, or
    'nssm.exe' (resolved via PATH) when the module bin path could not be determined.
.OUTPUTS
    [hashtable] Map of changed nssm parameter names to their previous values (for rollback).
    Returns an empty hashtable when the service does not exist or nothing changed.
#>
function Update-NssmServiceInstallPath {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $OldPath,
        [Parameter(Mandatory = $true)]
        [string] $NewPath,
        [Parameter(Mandatory = $false)]
        [string] $NssmPath = $(if ($kubeBinPath) { "$kubeBinPath\nssm.exe" } else { 'nssm.exe' })
    )

    # Trim trailing separators so callers passing a path with a trailing backslash still match
    # the values stored in the nssm registry parameters.
    $OldPath = $OldPath.TrimEnd('\')
    $NewPath = $NewPath.TrimEnd('\')

    $previousValues = @{}

    if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) {
        return $previousValues
    }

    $regKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name\Parameters"
    if (-not (Test-Path -LiteralPath $regKey)) {
        return $previousValues
    }

    $props = Get-ItemProperty -Path $regKey -ErrorAction SilentlyContinue
    $oldPathPattern = [regex]::Escape($OldPath)

    foreach ($parameter in @('Application', 'AppDirectory', 'AppParameters')) {
        $current = $props.$parameter
        if ($null -eq $current) { continue }
        if ($current -is [Array]) { $current = ($current -join ' ') }
        if ($current.IndexOf($OldPath, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

        $newValue = [regex]::Replace($current, $oldPathPattern, $NewPath, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        Write-Log ("Re-pointing service '{0}' parameter '{1}' to new installation path" -f $Name, $parameter)
        # Write the value DIRECTLY to the registry instead of via 'nssm.exe set'. nssm reads its
        # configuration from these registry values, so a direct write is equivalent - and it avoids a
        # PowerShell native-command quoting bug: when the installation path contains spaces (e.g.
        # 'C:\Program Files\k2s'), an AppParameters value such as --config-path="C:\Program Files\...\x.yaml"
        # mixes spaces with embedded double quotes. Passing that string as a native argument to nssm.exe
        # makes PowerShell wrap it in quotes without escaping the embedded ones, so nssm stores a mangled
        # value and the service fails to start. Set-ItemProperty writes the exact string verbatim.
        try {
            Set-ItemProperty -Path $regKey -Name $parameter -Value $newValue -ErrorAction Stop
        } catch {
            Write-Log ("[Update][Warn] Failed to write nssm registry value for service '{0}' parameter '{1}'; not recording for rollback: {2}" -f $Name, $parameter, $_.Exception.Message)
            continue
        }
        $previousValues[$parameter] = $current
    }

    return $previousValues
}

Export-ModuleMember -Function Start-NssmService,
Restart-NssmService, Stop-NssmService,
Get-IsNssmServiceRunning, Write-NodeServiceStatus,
Restart-WinService, Start-ServiceProcess, Stop-ServiceProcess, Start-WSL,
Update-NssmServiceInstallPath
