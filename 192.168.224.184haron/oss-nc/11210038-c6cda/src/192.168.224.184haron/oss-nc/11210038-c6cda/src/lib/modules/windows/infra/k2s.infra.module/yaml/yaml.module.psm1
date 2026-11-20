# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

$pathModule = "$PSScriptRoot\..\path\path.module.psm1"

Import-Module $pathModule

function Test-LastExecutionForSuccess {
    return $LASTEXITCODE -eq 0
}

function Get-FromYamlFile {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Path = $(throw 'Path not specified')
    )
    if ((Test-Path -Path $Path) -ne $true) {
        throw "path '$Path' does not exist"
    }

    $kubeBinPath = Get-KubeBinPath
    $yaml2jsonExe = [System.IO.Path]::Combine($kubeBinPath, 'yaml2json.exe')
    $tempJsonFile = New-K2sTempFile

    try {
        Invoke-Expression "&`"$yaml2jsonExe`" -input `"$Path`" -output `"$tempJsonFile`" -verbosity error"
        if ((Test-LastExecutionForSuccess) -ne $true) {
            throw "yaml2json conversion failed for '$Path'. See log output above for details."
        }
    
        $result = Get-Content -Path $tempJsonFile | Out-String | ConvertFrom-Json
    }
    finally {
        Remove-Item -Path $tempJsonFile -Force -ErrorAction Continue
    }

    return $result
}

Export-ModuleMember -Function Get-FromYamlFile
