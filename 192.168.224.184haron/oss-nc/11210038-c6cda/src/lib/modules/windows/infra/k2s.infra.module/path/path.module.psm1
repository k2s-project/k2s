# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

function Get-KubePath {
    $scriptRoot = $PSScriptRoot
    $kubePath = (Get-Item $scriptRoot).Parent.Parent.Parent.Parent.Parent.Parent.FullName
    return $kubePath
}

function Get-KubeBinPath {
    $kubePath = Get-KubePath
    return "$kubePath\bin"
}

function Get-KubeToolsPath {
    $kubeBinPath = Get-KubeBinPath
    return "$kubeBinPath\kube"
}

function New-K2sTempFile {
    return [System.IO.Path]::GetTempFileName()
}

function Get-CrictlExePath {
    $kubeBinPath = Get-KubeBinPath
    $crictlExe = "$kubeBinPath\crictl.exe"
    if (-Not (Test-Path -Path $crictlExe)) {
        $crictlCommand = Get-Command -Name 'crictl.exe' -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $crictlCommand) {
            $crictlExe = ($crictlCommand | Select-Object -First 1).Source
        }
        else {
            # Return default path instead of throwing error during installation
            # Write-Log "crictl.exe not found yet in k2s bin location '$crictlExe' or in PATH, returning default path for installation"
            return $crictlExe
        }       
    }
    return $crictlExe
}

function Get-K2sExePath {
    $kubePath = Get-KubePath
    $k2sExe = "$kubePath\k2s.exe"    
    return $k2sExe
}

function Get-InstallationDriveLetter {
    $kubePath = Get-KubePath
    $installationDriveLetter = ($kubePath).Split(':')[0]
    return $installationDriveLetter
}

function Get-SystemDriveLetter {
    return 'C'
}

function Test-PathPrerequisites {
    $kubePath = Get-KubePath
    $installationDirectoryType = Get-Item "$kubePath" | Select-Object -ExpandProperty LinkType
    if ($null -ne $installationDirectoryType) {
        throw "Your installation directory '$kubePath' is of type '$installationDirectoryType'. Only normal directories are supported."
    }
}

function Update-SystemPath ($Action, $Addendum) {
    $regLocation = 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment'
    $path = (Get-ItemProperty -Path $regLocation -Name PATH).path

    # Add an item to PATH
    if ($Action -eq 'add') {
        $path = $path + [IO.Path]::PathSeparator + $Addendum
        $path = ( $path -split [IO.Path]::PathSeparator | Select-Object -Unique ) -join [IO.Path]::PathSeparator
        Set-ItemProperty -Path $regLocation -Name PATH -Value $path

        $env:Path = $env:Path + [IO.Path]::PathSeparator + $Addendum
        $env:Path = ( $env:Path -split [IO.Path]::PathSeparator | Select-Object -Unique ) -join [IO.Path]::PathSeparator

        Write-Verbose "Added $Addendum to PATH variable"
    }

    # Remove an item from PATH
    if ($Action -eq 'remove') {
        # Case-insensitive match: Windows paths are case-insensitive, so PATH entries that differ only in
        # casing (e.g. 'C:\K' vs 'C:\k') must still be removed (important for installation re-homing).
        $path = ($path.Split([IO.Path]::PathSeparator) | Where-Object { $_ -ine "$Addendum" }) -join [IO.Path]::PathSeparator
        Set-ItemProperty -Path $regLocation -Name PATH -Value $path

        # Also drop the entry from the current process PATH so an uninstall (and a subsequent reinstall to a
        # different USERPROFILE) does not leave a stale entry in the running session. Mirrors the 'add' branch,
        # which updates $env:Path in-session too.
        $env:Path = ($env:Path.Split([IO.Path]::PathSeparator) | Where-Object { $_ -ine "$Addendum" }) -join [IO.Path]::PathSeparator

        Write-Verbose "Removed $Addendum from system PATH variable"
    }
}

function Update-UserPath ($Action, $Addendum) {
    # Per-user (HKCU) counterpart of Update-SystemPath. Used only for locations that live under the user's
    # profile - e.g. krew installs its plugins into '%USERPROFILE%\.krew\bin', which is per-user by design
    # and therefore must NOT go into the machine-wide PATH (that would leak the installing user's directory
    # to every account). The only intentional difference from Update-SystemPath is the registry scope.
    $regLocation = 'Registry::HKEY_CURRENT_USER\Environment'
    $path = (Get-ItemProperty -Path $regLocation -Name PATH -ErrorAction SilentlyContinue).path
    # Track whether HKCU:\Environment already had a PATH value so the 'remove' branch does not create a
    # spurious empty entry on hives that never had one (e.g. Server Core / fresh profile).
    $pathExists = ($null -ne $path)
    if ($null -eq $path) {
        # Unlike the machine hive, HKCU:\Environment may not have a PATH value yet (e.g. Server Core / fresh profile).
        $path = ''
    }

    # Add an item to PATH
    if ($Action -eq 'add') {
        $path = $path + [IO.Path]::PathSeparator + $Addendum
        $path = ( $path -split [IO.Path]::PathSeparator | Where-Object { $_ -ne '' } | Select-Object -Unique ) -join [IO.Path]::PathSeparator
        Set-ItemProperty -Path $regLocation -Name PATH -Value $path

        $env:Path = $env:Path + [IO.Path]::PathSeparator + $Addendum
        $env:Path = ( $env:Path -split [IO.Path]::PathSeparator | Select-Object -Unique ) -join [IO.Path]::PathSeparator

        Write-Verbose "Added $Addendum to user PATH variable"
    }

    # Remove an item from PATH
    if ($Action -eq 'remove') {
        # Case-insensitive match: Windows paths are case-insensitive, so PATH entries that differ only in
        # casing (e.g. 'C:\K' vs 'C:\k') must still be removed (important for installation re-homing).
        $path = ($path.Split([IO.Path]::PathSeparator) | Where-Object { $_ -ine "$Addendum" }) -join [IO.Path]::PathSeparator
        # Only write the registry value back if HKCU:\Environment already had a PATH value; otherwise removing
        # from a non-existent value would create a spurious empty PATH entry (fresh profile / Server Core).
        if ($pathExists) {
            Set-ItemProperty -Path $regLocation -Name PATH -Value $path
        }

        # Also drop the entry from the current process PATH so an uninstall (and a subsequent reinstall to a
        # different USERPROFILE) does not leave a stale entry in the running session. Mirrors the 'add' branch,
        # which updates $env:Path in-session too. (Update-SystemPath intentionally does not do this; here we keep
        # Update-UserPath internally consistent between its own add/remove branches.)
        $env:Path = ($env:Path.Split([IO.Path]::PathSeparator) | Where-Object { $_ -ine "$Addendum" }) -join [IO.Path]::PathSeparator

        Write-Verbose "Removed $Addendum from user PATH variable"
    }
}

function Set-EnvVars {
    $kubePath = Get-KubePath
    Update-SystemPath -Action 'add' "$kubePath"
    Update-SystemPath -Action 'add' "$kubePath\bin"
    Update-SystemPath -Action 'add' "$kubePath\bin\kube"
    Update-SystemPath -Action 'add' "$kubePath\bin\docker"
    Update-SystemPath -Action 'add' "$kubePath\bin\containerd"
    # krew installs its plugins into '%USERPROFILE%\.krew\bin' (per-user); expose them via the USER PATH so
    # plugins installed via 'kubectl krew install' are discoverable. The krew binary itself stays machine-wide (bin\kube).
    Update-UserPath -Action 'add' "$env:USERPROFILE\.krew\bin"
}

function Reset-EnvVars {
    $kubePath = Get-KubePath
    Update-SystemPath -Action 'remove' "$kubePath"
    Update-SystemPath -Action 'remove' "$kubePath\bin"
    Update-SystemPath -Action 'remove' "$kubePath\bin\kube"
    Update-SystemPath -Action 'remove' "$kubePath\bin\docker"
    Update-SystemPath -Action 'remove' "$kubePath\containerd" # Backward compatibility
    Update-SystemPath -Action 'remove' "$kubePath\bin\containerd"
    # Remove the krew user-plugins PATH entry added during installation (USER scope).
    Update-UserPath -Action 'remove' "$env:USERPROFILE\.krew\bin"
}

<#
.SYNOPSIS
Write refresh info.

.DESCRIPTION
Write information about refersh of env variables
#>
function Write-RefreshEnvVariables {
    $kubePath = Get-KubePath
    Write-Log ' ' -Console
    Write-Log '   Update PATH environment variable for proper usage:' -Console
    Write-Log ' ' -Console
    Write-Log "   Powershell: '$kubePath\smallsetup\helpers\RefreshEnv.ps1'" -Console
    Write-Log "   Command Prompt: '$kubePath\smallsetup\helpers\RefreshEnv.cmd'" -Console
    Write-Log '   Or open new shell' -Console
    Write-Log ' ' -Console
}

Export-ModuleMember -Function Get-KubePath, Get-KubeBinPath, Get-KubeToolsPath, New-K2sTempFile, Get-CrictlExePath, Get-K2sExePath,
Get-InstallationDriveLetter,
Get-SystemDriveLetter,
Test-PathPrerequisites,
Update-SystemPath,
Update-UserPath,
Set-EnvVars,
Write-RefreshEnvVariables,
Reset-EnvVars
