# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

Function Get-ExceptionMessage {
    param (
        [Parameter(Mandatory = $false, ValueFromPipeline=$true)]
        [ScriptBlock] $Script
    )
    process {
        $message = "No exception thrown"
        try {
            & { 
                [CmdletBinding()]
                Param ()
                &$Script | Out-Null
            } -ErrorAction Stop
        }
        catch {
            $message = $_.Exception.Message
        } 
        $message
    }
}

Function Assert-LegalCharactersInPath {
    param (
        [Parameter(ValueFromPipeline=$true)]
        [string]$Path = ''
    )
    
    $isValid = ![string]::IsNullOrWhiteSpace($Path)

    if ($isValid) {
        try {
            Test-Path -Path $Path -ErrorAction Stop | Out-Null
        }
        catch {
            $isValid = $false
        }
    }
    $isValid
}

Function Assert-Pattern {
    param (
        [string]$Path = $(throw "Argument missing: Path"),
        [string]$Pattern = $(throw "Argument missing: Pattern")

    )
    
    [regex]::IsMatch($Path, $Pattern)
}

Function Assert-Path {
    param (
        [Parameter(ValueFromPipeline=$true)]
        [string]$Path,
        [ValidateSet("Leaf", "Container")]
        [string]$PathType = $(throw "Argument missing: PathType"),
        [boolean]$ShallExist = $(throw "Argument missing: ShallExist")
    )
    if ((Test-Path -Path $Path -PathType $PathType -ErrorAction Stop) -ne $ShallExist) {
        $messageSuffix = "exist"
        if (!$ShallExist) {
            $messageSuffix = "not " + $messageSuffix
        }
        throw "The path '$Path' shall $messageSuffix"
    } 

    $Path
}

Function Compare-Hashtables {
    param (
        [hashtable]$Left = $(throw "Argument missing: Left"),
        [hashtable]$Right = $(throw "Argument missing: Right")
    )
    $areEqual = $true

    if ($Left.Count -ne $Right.Count) {
        return $false
    }
    foreach ($item in $Left.GetEnumerator() )
    {
        if (!($Right.ContainsKey($item.Key))) { $areEqual = $false;  break } 
        if ($Right[$item.Key] -ne $item.Value) { $areEqual = $false;  break  } 
    }

    $areEqual
}

Function Get-IsValidIPv4Address {
    param ([string]$value)
    $isValid = $true
    $parts = $value -split '\.'
    if ($parts.Count -eq 4) {
        foreach ($part in $parts) {
            try {
                [int]$partAsInt = $part
                if ($partAsInt -lt 0 -or $partAsInt -gt 255) {
                    $isValid = $false
                    break
                }

            }
            catch {
                $isValid = $false
                break
            }
            
        }
    } else {
        $isValid = $false
    }
    
    $isValid
}
