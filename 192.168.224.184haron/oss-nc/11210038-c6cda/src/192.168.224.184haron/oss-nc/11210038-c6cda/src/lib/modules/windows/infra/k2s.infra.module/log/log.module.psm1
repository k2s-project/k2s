# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Imports

$pathModule = "$PSScriptRoot\..\path\path.module.psm1"

Import-Module $pathModule

$script:ConsoleLogging = $false  # Enables Console logging along with file logging
$script:NestedLogging = $false   # Shall be used when we need to capture output from Invoke-Command, which enables console logging, skips file logging.

# logging
$k2sLogFilePart = ':\var\log\k2s.log'
$k2sLogFile = (Get-SystemDriveLetter) + $k2sLogFilePart
$script:LogPathResolved = $false

<#
.SYNOPSIS
Resolves the configured K2s log root directory.

.DESCRIPTION
Fallback chain (first hit wins):
  1. Environment variable K2S_LOG_ROOT
  2. setup.json -> LogRoot (under ProgramData\K2s)
  3. cfg/config.json -> configDir.logs
  4. <SystemDrive>:\var\log (legacy)

The returned path is environment-expanded and created if missing.
#>
function Get-ConfiguredLogDirectory {
    [CmdletBinding()]
    param()

    $raw = $null
    if ($env:K2S_LOG_ROOT) {
        $raw = $env:K2S_LOG_ROOT
    }
    else {
        try {
            $kubePath = Get-KubePath
            $setupJsonPath = Join-Path -Path 'C:\ProgramData\K2s' -ChildPath 'setup.json'
            if (Test-Path -Path $setupJsonPath) {
                $setupJson = Get-Content -Path $setupJsonPath -Raw | ConvertFrom-Json
                if ($setupJson -and $setupJson.PSObject.Properties.Name -contains 'LogRoot' -and $setupJson.LogRoot) {
                    $raw = $setupJson.LogRoot
                }
            }
            if (-not $raw) {
                $cfgPath = Join-Path -Path $kubePath -ChildPath 'cfg\config.json'
                if (Test-Path -Path $cfgPath) {
                    $cfgJson = Get-Content -Path $cfgPath -Raw | ConvertFrom-Json
                    if ($cfgJson -and $cfgJson.configDir -and $cfgJson.configDir.PSObject.Properties.Name -contains 'logs' -and $cfgJson.configDir.logs) {
                        $raw = $cfgJson.configDir.logs
                    }
                }
            }
        }
        catch {
            # Best-effort resolution; fall through to legacy default.
        }
        if (-not $raw) {
            $raw = "$(Get-SystemDriveLetter):\var\log"
        }
    }

    $resolved = [Environment]::ExpandEnvironmentVariables($raw)
    if ($resolved -like '~*') {
        $resolved = $resolved -replace '^~', $env:USERPROFILE
    }

    if (-not (Test-Path -Path $resolved)) {
        New-Item -Path $resolved -ItemType Directory -Force | Out-Null
    }
    return (Resolve-Path -Path $resolved).Path
}

<#
.SYNOPSIS
Resolves the log file path from the configured log root and updates the cached value.

.DESCRIPTION
Updates the script-scope cache $k2sLogFile to point to <ConfiguredLogDir>\k2s.log.
Safe to call multiple times. Tests that override $k2sLogFile via InModuleScope can
suppress this behavior with -Force:$false (default skips when already resolved).
#>
function Update-LogFilePathFromConfig {
    [CmdletBinding()]
    param(
        [switch] $Force
    )
    if (-not $Force -and $script:LogPathResolved) { return }
    try {
        $dir = Get-ConfiguredLogDirectory
        $script:k2sLogFile = Join-Path -Path $dir -ChildPath 'k2s.log'
        $script:LogPathResolved = $true
    }
    catch {
        # Keep legacy default if resolution fails.
    }
}

<#
.SYNOPSIS
Initialize logging module with supplied options.

.DESCRIPTION
Initialize logging module with supplied options to dictate console logging.

.PARAMETER ShowLogs
Enables console logging

.PARAMETER Nested
Enables console logging only (host->VM), should be used when Invoke-Command is used

.EXAMPLE
Initialize-Logging -ShowLogs:$true   ---------> Will log all messages to console along with file logging
Initialize-Logging -ShowLogs:$false   --------> Default behaviour, will log all messages to file and messages with -Console flag to console.
#>
function Initialize-Logging {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Write all messages to console and log file.')]
        [switch] $ShowLogs = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'Write all messages to only to console for nested case.')]
        [switch] $Nested = $false
    )
    Write-Verbose "Initializing log module with ShowLogs:$ShowLogs, Nested:$Nested"
    $script:ConsoleLogging = $ShowLogs
    $script:NestedLogging = $Nested
    Update-LogFilePathFromConfig
}

<#
.SYNOPSIS
Removes log file

.DESCRIPTION
Removes log file for fresh installation if AppendLogFile

.PARAMETER AppendLogFile
If set then log file will not deleted

.EXAMPLE
Reset-LogFile -AppendLogFile:$true
#>
function Reset-LogFile {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Write all messages to console and log file.')]
        [switch] $AppendLogFile = $false
    )
    #cleanup old logs
    if ( -not  $AppendLogFile) {
        Remove-Item -Path $k2sLogFile -Force -Recurse -ErrorAction SilentlyContinue
    }
}

function Format-ConsoleMessage {
    param (
        [string] $Message,
        [string] $Timestamp,        
        [switch] $Progress = $false
    )
    if ($Error) {
        return "[$Timestamp][ERROR] $Message"
    } elseif (-not $Progress) {
        return "[$Timestamp] $Message"
    } else {
        return $Message
    }
}

function Write-ToLogFile {
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'The log file message to write.')]
        [string] $LogFileMessage,
        [Parameter(Mandatory = $false, HelpMessage = 'The timestamp for the log entry.')]
        [string] $Timestamp ,
        [Parameter(Mandatory = $false, HelpMessage = 'The caller information for the log entry.')]
        [string] $Caller = $null
    )

    # Ensure the log directory exists
    if (-not (Test-Path -Path $k2sLogFile)) {
        $logDir = Split-Path -Path $k2sLogFile
        mkdir -Force $logDir | Out-Null
    }
    
$logfileMessagePadded = $LogFileMessage.PadRight(2)

$formattedMessage = @"
[$Timestamp] | Msg: $logfileMessagePadded | From: $Caller
"@


    # Write the formatted message to the log file
    $formattedMessage | Out-File -Append -FilePath $k2sLogFile -Encoding utf8 -Force
}

<#
.SYNOPSIS
Logs a message to the log file and output console based on supplied flags.

.DESCRIPTION
Based on input flags, passed message will be either displayed on the console, or logged to file, or both.

.PARAMETER Messages
The message

.EXAMPLE
Write-Log "Hello"                      ---------> Will write the message in log file: [30-10-2023 13:20:40] Hello
Write-Log "Hello" -Console             ---------> Will write the message in log file: [30-10-2023 13:20:40] Hello and
console: [10:34:53] Hello
Write-Log "Hello" -Progress            ---------> Will write the message in file with no newline
Write-Log "Hello" -Console -Progress   ---------> Will write the message in file and in console with no newline
#>

function Write-Log {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Messages to be logged.', ValueFromPipeline = $true)]
        [string[]] $Messages,
        [Parameter(Mandatory = $false, HelpMessage = 'Write all messages to console and log file.')]
        [switch] $Console = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'This is a progress message, do not append new line in the log file.')]
        [switch] $Progress = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'This is an error message, add to log file and console as Write-Error.')]
        [switch] $Error = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'Write messages to stdout using Write-Output (default is Write-Information)')]
        [switch] $Raw = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Write ssh stdout messages to stdout using Write-Output (mark message with '#ssh#')")]
        [switch] $Ssh = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'Caller script name to include in log file.')]
        [string] $Caller = $MyInvocation.ScriptName
    )

    Begin {
        if (-not (Test-Path -Path $k2sLogFile)) {
            $logDir = Split-Path -Path $k2sLogFile
            mkdir -Force $logDir | Out-Null
        }
    }

    Process {
        try {
            foreach ($message in $Messages) {
                $message = $message -replace "[`n`r]", ' ' -replace "[`0]", ''

                if ([string]::IsNullOrWhiteSpace($message) -or ($message.Trim().Length -eq 0)) {
                    continue
                }

                $dayTimestamp = [DateTime]::Now.ToString('dd-MM-yyyy HH:mm:ss')
                $timestamp = [DateTime]::Now.ToString('HH:mm:ss')
                
                # Get name of the caller script and function
                $callerScript = if (![string]::IsNullOrEmpty($Caller)) {
                    [System.IO.Path]::GetFileName($Caller)
                } else {
                    $null
                }

                $stack = Get-PSCallStack
                $callingFunction = if ($stack.Count -gt 1) {
                    $stack[1].FunctionName
                } else {
                    $null
                }

                $logFileMessage = $message
                
                $logFileMessage = Protect-SensitiveInfo -InputText  $logFileMessage
                
                $messageForConsole = $message
                if (-not $script:ConsoleLogging) {
                    $messageForConsole = Remove-CategoryTags -Message $messageForConsole
                }

                $consoleMessage = Format-ConsoleMessage -Message $messageForConsole -Timestamp $timestamp -Progress:$Progress
                
                $consoleMessage = Remove-ModuleSpecificMessages -ConsoleMessage $consoleMessage

                if ($script:NestedLogging) {
                    Write-NestedLogging -ConsoleMessage $consoleMessage -Message $message -Timestamp $timestamp
                    return
                }

                # Handle specific log message format
                if ($message -match '^\[\d{2}:\d{2}:\d{2}\]\[([^]]+)\]') {
                    Write-SpecificLogMessage -Message $message -LogFileMessage $logFileMessage -Timestamp $dayTimestamp -Caller "[$callerScript]($callingFunction)"
                    return
                }

                if ($Error) {
                    Write-ErrorMessage -Message $message -ConsoleMessage $consoleMessage -DayTimestamp $dayTimestamp -Caller "[$callerScript]($callingFunction)"
                }               
                elseif ($Progress -and ($Console -or $script:ConsoleLogging)) {
                    Write-ProgressMessage  -ConsoleMessage $consoleMessage -LogFileMessage $logFileMessage -Timestamp $dayTimestamp -Caller "[$callerScript]($callingFunction)"
                }               
                elseif ($Console -or $script:ConsoleLogging) {
                    Write-ConsoleMessage  -Message $message -ConsoleMessage $consoleMessage -LogFileMessage $logFileMessage -Timestamp $dayTimestamp -Caller "[$callerScript]($callingFunction)" -Raw:$Raw -Ssh:$Ssh 
                }             
                else {
                    # Use the new Write-ToLogFile function
                    Write-ToLogFile -LogFileMessage $logFileMessage -Timestamp $dayTimestamp -Caller "[$callerScript]($callingFunction)"
                }
            }
        } catch [System.IO.DirectoryNotFoundException] {
            return
        }
    }

    End {}
}

function Write-SpecificLogMessage {
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'The log message to process.')]
        [string] $Message,
        [Parameter(Mandatory = $true, HelpMessage = 'The log file message to write.')]
        [string] $LogFileMessage,
        [Parameter(Mandatory = $false, HelpMessage = 'The timestamp for the log entry.')]
        [string] $Timestamp ,
        [Parameter(Mandatory = $false, HelpMessage = 'The caller information for the log entry.')]
        [string] $Caller = $null
    )

    if ($script:ConsoleLogging) {
        Write-Information $Message -InformationAction Continue
    }
    # Use the new Write-ToLogFile function
    Write-ToLogFile -LogFileMessage $logFileMessage -Timestamp $Timestamp -Caller $Caller
}

function Remove-ModuleSpecificMessages {
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'The console message to process.')]
        [string] $ConsoleMessage
    )

    if ($ConsoleMessage -match '\[([^]]+::[^]]+)\]\s?') {
        $match = ($ConsoleMessage | Select-String -Pattern '\[([^]]+::[^]]+)\]\s?').Matches.Value
        return $ConsoleMessage.Replace($match, '')
    }    

    return $ConsoleMessage
}

function Remove-CategoryTags {
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'The message to strip category tags from.')]
        [string] $Message
    )

    # Strip leading category tags like [Proxy], [KubeInit], [ClusterIP-Webhook] from messages
    # These are meant for log file categorization and should not appear on console in default mode
    return $Message -replace '^\[[\w-]+\]\s*', ''
}
    

function Write-NestedLogging {
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'Indicates if the message is an error.')]
        [switch] $Error,
        [Parameter(Mandatory = $true, HelpMessage = 'The console message to log.')]
        [string] $ConsoleMessage,
        [Parameter(Mandatory = $true, HelpMessage = 'The original message to log.')]
        [string] $Message,
        [Parameter(Mandatory = $true, HelpMessage = 'The timestamp for the log entry.')]
        [string] $Timestamp
    )

    if ($Error) {
        Write-Error -Message $ConsoleMessage
    } else {
        Write-Output "[$Timestamp][$env:COMPUTERNAME] $Message"
    }
}

function Write-ErrorMessage {
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'The log message to process.')]
        [string] $Message,
        [Parameter(Mandatory = $true, HelpMessage = 'The console message to display.')]
        [string] $ConsoleMessage,
        [Parameter(Mandatory = $true, HelpMessage = 'The timestamp for the log entry.')]
        [string] $DayTimestamp,
        [Parameter(Mandatory = $false, HelpMessage = 'Caller script name to include in log file.')]
        [string] $Caller
    )

    # Use the new Write-ToLogFile function
    Write-ToLogFile -LogFileMessage "[ERROR] $Message" -Timestamp $DayTimestamp -Caller $Caller
    Write-Error $ConsoleMessage
}

function Write-ProgressMessage {
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'The console message to display.')]
        [string] $ConsoleMessage,
        [Parameter(Mandatory = $true, HelpMessage = 'The log file message to write.')]
        [string] $LogFileMessage,
        [Parameter(Mandatory = $false, HelpMessage = 'The timestamp for the log entry.')]
        [string] $Timestamp ,
        [Parameter(Mandatory = $false, HelpMessage = 'The caller information for the log entry.')]
        [string] $Caller = $null
    )

    Write-Host $ConsoleMessage -NoNewline
    Write-ToLogFile -LogFileMessage $LogFileMessage -Timestamp $Timestamp -Caller $Caller
}

function Write-ConsoleMessage  {
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'The log message to process.')]
        [string] $Message,
        [Parameter(Mandatory = $true, HelpMessage = 'The console message to display.')]
        [string] $ConsoleMessage,
        [Parameter(Mandatory = $true, HelpMessage = 'The log file message to write.')]
        [string] $LogFileMessage,
        [Parameter(Mandatory = $false, HelpMessage = 'The timestamp for the log entry.')]
        [string] $Timestamp ,
        [Parameter(Mandatory = $false, HelpMessage = 'The caller information for the log entry.')]
        [string] $Caller = $null,
        [Parameter(Mandatory = $false, HelpMessage = 'Indicates if raw output is enabled.')]
        [switch] $Raw,
        [Parameter(Mandatory = $false, HelpMessage = 'Indicates if SSH output is enabled.')]
        [switch] $Ssh
    )

    if ($Raw) {
        Write-Output $Message
    } elseif ($Ssh) {
        Write-Output "#ssh#$Message"
    } else {
        Write-Information $ConsoleMessage -InformationAction Continue
    }
    Write-ToLogFile -LogFileMessage $LogFileMessage -Timestamp $Timestamp -Caller $Caller
}

function Write-DefaultMessage {
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'The log file message to write.')]
        [string] $LogFileMessage,
        [Parameter(Mandatory = $false, HelpMessage = 'The timestamp for the log entry.')]
        [string] $Timestamp ,
        [Parameter(Mandatory = $false, HelpMessage = 'The caller information for the log entry.')]
        [string] $Caller = $null
    )

    # Use the new Write-ToLogFile function
    Write-ToLogFile -LogFileMessage $LogFileMessage -Timestamp $Timestamp -Caller $Caller
}

function Get-k2sLogDirectory {
    $logsDir = Split-Path -Path $k2sLogFile -Parent
    return $logsDir
}

function Get-LogFilePath {
    return $k2sLogFile
}

function Get-LogFilePathPart {
    return $k2sLogFilePart
}

function Protect-SensitiveInfo {
    param (
        [string]$InputText
    )

    return $InputText `
        -replace '(\btoken[:\s]+)[^\s]+', '${1}[REDACTED]' `
        -replace '(--discovery-token-ca-cert-hash(?:\s+sha256:)?\s*)[^\s]+', '${1}[REDACTED]'
}

function Save-k2sLogDirectory {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Remove var folder after saving logs')]
        [switch] $RemoveVar = $false,
        [Parameter(Mandatory = $false, HelpMessage = 'Override source log directory (defaults to the configured/active K2s log root)')]
        [string] $VarLogDirectory = ''
    )

    if (!(Test-Path "$env:TEMP")) {
        New-Item -Path "$env:TEMP" -ItemType Directory | Out-Null
    }

    # Resolve source log directory: explicit param > active resolver > legacy default.
    if ([string]::IsNullOrWhiteSpace($VarLogDirectory)) {
        try {
            $VarLogDirectory = Get-ConfiguredLogDirectory
        }
        catch {
            $VarLogDirectory = "$(Get-SystemDriveLetter):\var\log"
        }
    }

    $destinationFolder = "$env:TEMP\k2s_log_$(get-date -f yyyyMMdd_HHmmss)"

    # Collect logs from primary location, plus any kubelet-managed paths under
    # <SystemDrive>:\var\log (pods/containers) which kubelet hardcodes.
    New-Item -Path $destinationFolder -ItemType Directory -Force | Out-Null
    if (Test-Path $VarLogDirectory) {
        Copy-Item -Path "$VarLogDirectory\*" -Destination $destinationFolder -Force -Recurse -ErrorAction SilentlyContinue
    }
    else {
        Write-Log "Source log directory '$VarLogDirectory' not found - skipping log copy" -Console
    }

    $systemDriveLetter = (Get-Item $env:SystemDrive).PSDrive.Name
    $legacyVarLog = "$($systemDriveLetter):\var\log"
    if ((Test-Path $legacyVarLog) -and ($VarLogDirectory.TrimEnd('\') -ne $legacyVarLog.TrimEnd('\'))) {
        $legacyTarget = Join-Path $destinationFolder 'system-drive-var-log'
        New-Item -Path $legacyTarget -ItemType Directory -Force | Out-Null
        Copy-Item -Path "$legacyVarLog\*" -Destination $legacyTarget -Force -Recurse -ErrorAction SilentlyContinue
    }

    Compress-Archive -Path "$destinationFolder\*" -DestinationPath "$destinationFolder.zip" -CompressionLevel Optimal -Force
    Remove-Item -Path "$destinationFolder" -Force -Recurse -ErrorAction SilentlyContinue

    Write-Log "Logs backed up in $destinationFolder.zip (source: $VarLogDirectory)" -Console

    if ($RemoveVar) {
        # Determine the active log root from the configured/resolved log file path so we don't
        # accidentally delete a custom log location *outside* the source tree, but still preserve
        # the legacy behavior of cleaning up <SystemDrive>:\var when no relocation is configured.
        $activeLogRoot = $null
        try {
            if ($script:k2sLogFile) {
                $activeLogRoot = Split-Path -Path $script:k2sLogFile -Parent
            }
        }
        catch {
            $activeLogRoot = $null
        }

        $legacyVarRoot = "$((Get-Item $env:SystemDrive).PSDrive.Name):\var"
        $legacyVarRootInstall = "$(Get-SystemDriveLetter):\var"

        # Only nuke the entire <drive>:\var tree when the active log root is still inside it.
        # If the operator relocated the logs elsewhere, only that directory is removed.
        if ($activeLogRoot -and ($activeLogRoot -notlike "$legacyVarRoot*") -and ($activeLogRoot -notlike "$legacyVarRootInstall*")) {
            Remove-Item -Path $activeLogRoot -Force -Recurse -ErrorAction SilentlyContinue
        }

        # the directory '<system drive>:\var' must be deleted (regardless of the installation drive) since
        # kubelet.exe writes hardcoded to '<system drive>:\var\lib\kubelet\device-plugins' (see '\pkg\kubelet\cm\devicemanager\manager.go' under https://github.com/kubernetes/kubernetes.git)
        $systemDriveLetter = (Get-Item $env:SystemDrive).PSDrive.Name
        Remove-Item -Path "$($systemDriveLetter):\var" -Force -Recurse -ErrorAction SilentlyContinue
        if ($(Get-SystemDriveLetter) -ne "$systemDriveLetter") {
            Remove-Item -Path "$(Get-SystemDriveLetter):\var" -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}

function Get-DurationInSeconds {
    param (
        [Parameter(Mandatory = $true)]
        [DateTime]$StartTime,
        [Parameter(Mandatory = $true)]
        [DateTime]$EndTime
    )

    $duration = New-TimeSpan -Start $StartTime -End $EndTime
    $durationSeconds = $duration.TotalSeconds

    return $durationSeconds
}

Export-ModuleMember -Variable k2sLogFilePart, k2sLogFile
Export-ModuleMember -Function Initialize-Logging, Write-Log, Reset-LogFile, Get-k2sLogDirectory, Save-k2sLogDirectory, Get-LogFilePath, Get-LogFilePathPart, Get-DurationInSeconds, Get-ConfiguredLogDirectory, Update-LogFilePathFromConfig
