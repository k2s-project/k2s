# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

function Write-OutputIntoDumpFile {
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'File in which the message should be dumped')]
        [ValidateNotNullOrEmpty()]
        [string]$DumpFilePath,

        [Parameter(Mandatory = $true, HelpMessage = 'Description of the command being executed')]
        [ValidateNotNullOrEmpty()]
        [string]$Description,

        [Parameter(Mandatory = $false, HelpMessage = 'Output of the command being executed', ValueFromPipeline = $true)]
        [string[]]$Messages,

        [Parameter(Mandatory = $false, HelpMessage = 'Helps to distinguish the output of the previous execution with the current execution')]
        [string]$Separator = ' '
    )

    Begin {
        if (-not (Test-Path $DumpFilePath)) {
            New-DumpFile -FilePath $DumpFilePath
        } else {
            $Separator | Out-File -Append -FilePath $DumpFilePath -Encoding UTF8
        }

        $Description | Out-File -Append -FilePath $DumpFilePath -Encoding UTF8
    }

    Process {
        if ($null -ne $Messages -and $Messages.Length -gt 0) {
            $Messages | Out-File -Append -FilePath $DumpFilePath -Encoding UTF8
        }
    }
}

function New-DumpFile(
    [string] $FilePath
) {


    #Check If directory is present. If not create it.
    $directoryPath = [System.IO.Path]::GetDirectoryName($FilePath)

    if (-not (Test-Path $directoryPath)) {
        New-Item -Path $directoryPath -ItemType Directory -Force | Out-Null
    }
    #Finally create the file
    New-Item -Path $FilePath -ItemType File -Force | Out-Null
}

Export-ModuleMember -Function Write-OutputIntoDumpFile
