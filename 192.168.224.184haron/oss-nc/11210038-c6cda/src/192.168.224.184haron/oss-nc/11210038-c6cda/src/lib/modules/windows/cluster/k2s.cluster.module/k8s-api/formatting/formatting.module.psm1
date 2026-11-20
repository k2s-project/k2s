# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

function Convert-ToAgeString {
    param (
        [Parameter(Mandatory = $false)]
        [timespan]
        $Duration
    )

    if ($Duration.TotalDays -ge 1) {
        if ($Duration.Hours -eq 0) {
            return $Duration.ToString('%d\d')
        }

        return $Duration.ToString('%d\d%h\h')
    }
    
    $minutes = $Duration.TotalMinutes

    if ($minutes -lt 60) {
        $seconds = $Duration.TotalSeconds

        if ($seconds -lt 60) {
            return $Duration.ToString('s\s')
        }

        if ($Duration.Seconds -eq 0) {
            return $Duration.ToString('%m\m')
        }

        return $Duration.ToString('%m\m%s\s')
    }

    if ($Duration.Seconds -eq 0 -and $Duration.Minutes -eq 0) {
        return $Duration.ToString('%h\h')
    }

    if ($Duration.Seconds -eq 0) {
        return $Duration.ToString('%h\h%m\m')
    }

    return $Duration.ToString('%h\h%m\m%s\s')
}

function Convert-ToUnixPath {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Path = $(throw 'path not specified')
    )
    return $Path -replace '\\', '/'    
}

Export-ModuleMember -Function Convert-ToAgeString, Convert-ToUnixPath
