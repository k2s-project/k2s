# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $module = "$PSScriptRoot\cli-messages.module.psm1"

    $moduleName = (Import-Module $module -Force -PassThru).Name

    function ConvertFrom-CompressedString {
        param (
            [Parameter(Mandatory)]
            [string]
            $CompressedString
        )

        $bytes = [System.Convert]::FromBase64String($CompressedString)

        $memoryStream = New-Object System.IO.MemoryStream
        $memoryStream.Write($bytes, 0, $bytes.Length)
        $memoryStream.Seek(0, 0) | Out-Null

        $decompressionStream = New-Object System.IO.Compression.GZipStream($memoryStream, [System.IO.Compression.CompressionMode]::Decompress)

        $streamReader = New-Object System.IO.StreamReader($decompressionStream)

        $json = $streamReader.ReadToEnd()

        $streamReader.Close()
        $memoryStream.Close()

        return ConvertFrom-Json $json
    }
}

Describe 'Send-ToCli' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'message type not specified' {
        It 'throws an error' {
            { Send-ToCli -Message 'test message' } | Should -Throw
        }
    }

    Context 'message not specified' {
        It 'throws an error' {
            { Send-ToCli -MessageType 'test type' } | Should -Throw
        }
    }

    Context 'message and type are valid' {
        BeforeAll {
            $message = @{Name = 'Test'; Successful = $true }
        }

        It 'CLI message is structured correctly' {
            $type = 'unit test'

            $output = Send-ToCli -Message $message -MessageType $type

            $output | Should -BeLike "#pm#$type#*"
        }

        It 'compress and encodes the data correctly' {
            $output = Send-ToCli -Message $message -MessageType 'test'

            $obj = ConvertFrom-CompressedString (($output -split '#')[3])

            $obj.Name | Should -Be $message.Name
            $obj.Successful | Should -Be $message.Successful
        }
    }

    Context 'message payload exceeds CLI line length limit' {
        BeforeAll {
            $testObj = @{
                Name      = 'Gopher'
                Language  = 'Go'
                Level     = 'intermediate'
                Timestamp = Get-Date -Format 'o'
                List      = @{
                    P1 = 'value1'
                    P3 = 'value2'
                    P4 = 'value3'
                }
            }

            $length = 10000
            $longList = New-Object 'object[]' $length

            for ($i = 0; $i -lt $length; $i++) {
                $longList[$i] = $testObj
            }
        }

        It 'chunkes the message' {
            $type = 'unit test'

            $output = Send-ToCli -Message $longList -MessageType $type

            $output.Count | Should -Be 2
            $output[0] | Should -BeLike "#pm#$type#*"
            $output[1] | Should -BeLike "#pm#$type#*"
        }

        It 'compresses and encodes the chunks correctly' {
            $output = Send-ToCli -Message $longList -MessageType 'test'

            $chunks = $output | ForEach-Object { $_ -split '#' | Select-Object -Last 1 } 

            $fullPayload = $chunks -join ''

            $list = ConvertFrom-CompressedString ($fullPayload)

            $list.Count | Should -Be $length
            $list.value[0].Name | Should -Be $testObj.Name
            $list.value[0].Language | Should -Be $testObj.Language
            $list.value[0].Level | Should -Be $testObj.Level
            $list.value[0].Timestamp | Should -Be $testObj.Timestamp
            $list.value[0].List.P1 | Should -Be $testObj.List.P1
            $list.value[0].List.P3 | Should -Be $testObj.List.P3
            $list.value[0].List.P4 | Should -Be $testObj.List.P4
        }
    }
}
