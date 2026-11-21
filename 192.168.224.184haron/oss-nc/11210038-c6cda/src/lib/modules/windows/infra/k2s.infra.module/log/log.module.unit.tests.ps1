# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $module = "$PSScriptRoot\log.module.psm1"

    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe "Reset-LogFile" {
    BeforeEach {
        $mockLogFile = "$env:TEMP\mock.log"
        InModuleScope $moduleName {
            $script:k2sLogFile = "$env:TEMP\mock.log"
        }
        if (Test-Path $mockLogFile) {
            Remove-Item -Path $mockLogFile -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType File -Path $mockLogFile | Out-Null
    }

    AfterEach {
        Remove-Item -Path $mockLogFile -Force -ErrorAction SilentlyContinue
    }

    It "should delete the log file when AppendLogFile is false" {
        # Arrange
        # (Setup done in BeforeEach)
        # Act
        Reset-LogFile -AppendLogFile:$false
        # Assert
        Test-Path $mockLogFile | Should -Be $false
    }

    It "should not delete the log file when AppendLogFile is true" {
        # Arrange
        # (Setup done in BeforeEach)
        # Act
        Reset-LogFile -AppendLogFile:$true
        # Assert
        Test-Path $mockLogFile | Should -Be $true
    }
}

Describe "Get-k2sLogDirectory" {
    BeforeEach {
        $mockLogFile = "$env:TEMP\mock.log"
        InModuleScope $moduleName {
            $script:k2sLogFile = "$env:TEMP\mock.log"
        }
        if (Test-Path $mockLogFile) {
            Remove-Item -Path $mockLogFile -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType File -Path $mockLogFile | Out-Null
    }

    AfterEach {
        Remove-Item -Path $mockLogFile -Force -ErrorAction SilentlyContinue
    }

    It "should return the log directory path" {
        # Arrange
        # (Setup done in BeforeEach)
        # Act
        $result = Get-k2sLogDirectory
        # Assert
        $result | Should -Be (Split-Path -Path $mockLogFile -Parent)
    }
}

Describe "Get-LogFilePath" {
    BeforeEach {
        $mockLogFile = "$env:TEMP\mock.log"
        InModuleScope $moduleName {
            $script:k2sLogFile = "$env:TEMP\mock.log"
        }
        if (Test-Path $mockLogFile) {
            Remove-Item -Path $mockLogFile -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType File -Path $mockLogFile | Out-Null
    }

    AfterEach {
        Remove-Item -Path $mockLogFile -Force -ErrorAction SilentlyContinue
    }

    It "should return the log file path" {
        # Arrange
        # (Setup done in BeforeEach)
        # Act
        $result = Get-LogFilePath
        # Assert
        $result | Should -Be $mockLogFile
    }
}

Describe "Save-k2sLogDirectory" {
    BeforeEach {
        $mockVarLogDir = "$env:TEMP\mock_var_log"
        $mockLogFile = Join-Path -Path $mockVarLogDir -ChildPath "mock.log"
        InModuleScope $moduleName {
            $k2sLogFile = "$mockLogFile"
        }
        if ((Test-Path $mockLogFile) -or (Test-Path $mockVarLogDir)) {
            Remove-Item -Path $mockVarLogDir -Force -Recurse -ErrorAction SilentlyContinue
            Remove-Item -Path $mockLogFile -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $mockVarLogDir | Out-Null
        New-Item -ItemType File -Path $mockLogFile | Out-Null
    }

    AfterEach {
        Remove-Item -Path "$zipFilePath" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$mockVarLogDir" -Force -Recurse -ErrorAction SilentlyContinue
    }

    It "should back up logs to a zip file in the TEMP directory" {
        # Arrange
        # (Setup done in BeforeEach)
        # Act
        $output = & {
            Save-k2sLogDirectory -VarLogDirectory "$mockVarLogDir"
        } *>&1 # Capture console output

        # Extract the zip file name from the output message
        $zipFileName = $output -match "Logs backed up in (.+\.zip)" | Out-Null
        $zipFilePath = $matches[1]

        # Assert
        Test-Path $zipFilePath | Should -Be $true
    }
}

Describe "Write-Log Function Tests" {
    BeforeEach {
        $mockLogFile = "$env:TEMP\mock.log"
        InModuleScope $moduleName {
            $script:k2sLogFile = "$env:TEMP\mock.log"
        }
        if (Test-Path $mockLogFile) {
            Remove-Item -Path $mockLogFile -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType File -Path $mockLogFile | Out-Null
    }

    AfterEach {
        # Clean up the mock log file
        Remove-Item -Path $mockLogFile -Force -ErrorAction SilentlyContinue
    }

    It "should write a message to the log file" {
        # Arrange
        $message = "Test log message"
        # Act
        Write-Log -Messages $message
        # Assert
        $logContent = Get-Content -Path $mockLogFile
        $logContent | Should -Match "\| Msg: Test log message \|"
    }

    It "should write a message to the console with specific format when -Console is used" {
        # Arrange
        $message = "Test console message"
        $expectedFormat = "\[\d{2}:\d{2}:\d{2}\] Test console message"
        # Act
        $output = & {
            Write-Log -Messages $message -Console
        } *>&1 # Capture console output
        # Assert
        $output | Should -Match $expectedFormat
        $logContent = Get-Content -Path $mockLogFile
        $logContent | Should -Match "\| Msg: Test console message \|"
    }

    It "should call Write-Host -NoNewline when Write-Log is called with -Progress -Console" {
        # Arrange
        InModuleScope $moduleName {
            $progressMessage = "ProgressTest"
            Mock Write-Host { } -ModuleName 'log.module'
            # Act
            Write-Log -Messages $progressMessage -Progress -Console
            Write-Log -Messages $progressMessage -Progress -Console
            # Assert
            Assert-MockCalled Write-Host -Times 2 -Exactly -ParameterFilter {
                $NoNewline -eq $true -and
                $Object -eq $progressMessage
            }
        }
    }

    It "should output the raw message when -Raw is used" {
        # Arrange
        InModuleScope $moduleName {
            $msg = "raw message"
            # Act
            $output = & {
                Write-ConsoleMessage -Message $msg -ConsoleMessage "ignored" -LogFileMessage "ignored" -Raw
            }
            # Assert
            $output | Should -Be $msg
        }
    }

    It "should output the ssh-formatted message when -Ssh is used" {
        # Arrange
        InModuleScope $moduleName {
            $msg = "ssh message"
            # Act
            $output = & {
                Write-ConsoleMessage -Message $msg -ConsoleMessage "ignored" -LogFileMessage "ignored" -Ssh
            }
            # Assert
            $output | Should -Be "#ssh#$msg"
        }
    }
}

Describe "Get-ConfiguredLogDirectory" {
    BeforeEach {
        $script:savedEnv = $env:K2S_LOG_ROOT
    }

    AfterEach {
        if ($null -eq $script:savedEnv) {
            Remove-Item Env:K2S_LOG_ROOT -ErrorAction SilentlyContinue
        }
        else {
            $env:K2S_LOG_ROOT = $script:savedEnv
        }
    }

    It "honors the K2S_LOG_ROOT environment variable when set" {
        # Arrange
        $tempDir = Join-Path $env:TEMP ("k2s-logroot-" + [Guid]::NewGuid())
        $env:K2S_LOG_ROOT = $tempDir
        try {
            # Act
            $result = Get-ConfiguredLogDirectory
            # Assert
            $result | Should -Be (Resolve-Path $tempDir).Path
            Test-Path $tempDir | Should -Be $true
        }
        finally {
            Remove-Item -Path $tempDir -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

    It "expands environment variables embedded in the value" {
        # Arrange
        $tempDir = Join-Path $env:TEMP ("k2s-logroot-env-" + [Guid]::NewGuid())
        $env:K2S_LOG_ROOT = '%TEMP%\' + (Split-Path -Leaf $tempDir)
        try {
            # Act
            $result = Get-ConfiguredLogDirectory
            # Assert
            $result | Should -Be (Resolve-Path $tempDir).Path
        }
        finally {
            Remove-Item -Path $tempDir -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

    It "creates the directory if it does not yet exist" {
        # Arrange
        $tempDir = Join-Path $env:TEMP ("k2s-logroot-mkdir-" + [Guid]::NewGuid())
        Test-Path $tempDir | Should -Be $false
        $env:K2S_LOG_ROOT = $tempDir
        try {
            # Act
            Get-ConfiguredLogDirectory | Out-Null
            # Assert
            Test-Path $tempDir | Should -Be $true
        }
        finally {
            Remove-Item -Path $tempDir -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}
