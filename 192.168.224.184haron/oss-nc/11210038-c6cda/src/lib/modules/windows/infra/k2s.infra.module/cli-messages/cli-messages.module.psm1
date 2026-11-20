# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$logModule = "$PSScriptRoot/../log/log.module.psm1"

Import-Module $logModule

<#
.SYNOPSIS
Sends a message to the standard output.

.DESCRIPTION
Serializes the message to JSON, compresses and encodes it base64-wise and sends it to the standard output.

.PARAMETER MessageType
The type of the message

.PARAMETER Message
The message

.EXAMPLE
Send-ToCli -MessageType "my-type" -Message @{Name = "Thomas"}
#>
function Send-ToCli {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Type of the data message to be sent')]
        [string] $MessageType = $(throw 'Please specify the message type.'),
        [parameter(Mandatory = $false, HelpMessage = 'The data message as arbitrary object')]
        [object] $Message = $(throw 'Please specify the message.')
    ) 
    $maxPayloadLength = 8000    

    Write-Log "Converting message of type '$MessageType' to JSON.."

    $json = ConvertTo-Json -InputObject $Message -Compress -Depth 100

    Write-Log 'message converted'

    $memoryStream = New-Object System.IO.MemoryStream
    $compressionStream = New-Object System.IO.Compression.GZipStream($memoryStream, [System.IO.Compression.CompressionMode]::Compress)

    $streamWriter = New-Object System.IO.StreamWriter($compressionStream)
    $streamWriter.Write($json)
    $streamWriter.Close();

    Write-Log 'JSON compressed'

    $payload = [System.Convert]::ToBase64String($memoryStream.ToArray())

    Write-Log "JSON base64 encoded (length=$($payload.Length))"

    if ($payload.Length -lt $maxPayloadLength) {
        Write-Output "#pm#$MessageType#$payload"
        Write-Log 'message sent via CLI'
        return 
    }

    Write-Log "message length exceeds $maxPayloadLength, chunking.."

    $chunks = $payload -split "(.{$maxPayloadLength})" | Where-Object { $_ }

    for ($i = 0; $i -lt $chunks.Count; $i++) {
        Write-Output "#pm#$MessageType#$($chunks[$i])"
        Write-Log "message $($i+1) of $($chunks.Count) sent via CLI"
    }
}

Export-ModuleMember -Function Send-ToCli
