# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $module = "$PSScriptRoot\oci.module.psm1"

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'OCI fallback helpers' -Tag 'unit', 'ci', 'oci', 'addon' {
    Context 'Get-Sha256HexLower' {
        It 'returns lowercase SHA256 hash matching .NET reference output' {
            InModuleScope -ModuleName $moduleName {
                $tmpFile = [System.IO.Path]::GetTempFileName()
                try {
                    [System.IO.File]::WriteAllText($tmpFile, 'k2s-oci-hash-test', [System.Text.UTF8Encoding]::new($false))

                    $actual = Get-Sha256HexLower -Path $tmpFile

                    $sha256 = [System.Security.Cryptography.SHA256]::Create()
                    try {
                        $expected = $sha256.ComputeHash([System.IO.File]::ReadAllBytes($tmpFile))
                    }
                    finally {
                        if ($sha256) {
                            $sha256.Dispose()
                        }
                    }
                    $expectedHex = ([System.BitConverter]::ToString($expected).Replace('-', '').ToLowerInvariant())

                    $actual | Should -Be $expectedHex
                    $actual | Should -Match '^[a-f0-9]{64}$'
                }
                finally {
                    if (Test-Path $tmpFile) {
                        Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }

    Context 'New-CompatTemporaryFile' {
        It 'returns an object with FullName and creates the file' {
            InModuleScope -ModuleName $moduleName {
                $tempFile = New-CompatTemporaryFile
                try {
                    $tempFile | Should -Not -BeNullOrEmpty
                    $tempFile.PSObject.Properties.Name | Should -Contain 'FullName'
                    $tempFile.FullName | Should -Not -BeNullOrEmpty
                    (Test-Path $tempFile.FullName) | Should -BeTrue
                }
                finally {
                    if ($tempFile -and $tempFile.FullName -and (Test-Path $tempFile.FullName)) {
                        Remove-Item -Path $tempFile.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
}
