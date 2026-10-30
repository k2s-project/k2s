# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$configModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
Import-Module $configModule, $pathModule, $logModule

$ipControlPlane = Get-ConfiguredIPControlPlane
$nameControlPlane = Get-ConfigControlPlaneNodeHostname
$defaultUserName = 'remote'
$remoteUser = "$defaultUserName@$ipControlPlane"
$remotePwd = 'admin'
$key = Get-SSHKeyControlPlane

$kubePath = Get-KubePath
$plinkExe = "$kubePath\bin\plink.exe"
$scpExe = "$kubePath\bin\pscp.exe"
$sshExe = (Get-Command 'ssh.exe' -ErrorAction Stop).Source

# TODO Separate Linux distribution module
$LinuxOsTypeDebianCloud = 'DebianCloud'
$LinuxOsTypeUbuntu = 'Ubuntu'
$ControlPlaneVMBaseImageName = 'Kubemaster-Base.vhdx'
$ControlPlaneVMBaseUbuntuImageName = 'Kubemaster-Base-Ubuntu.vhdx'
$ControlPlaneVMRootfsName = 'Kubemaster-Base.rootfs.tar.gz'
$ControlPlaneVMUbuntuRootfsName = 'Kubemaster-Base-Ubuntu.rootfs.tar.gz'

# Runs ssh.exe once and returns a result object with OutputLines, ExitCode, and HadSocketWarning.
# This helper is used by Invoke-SSHWithKey to enable retry logic without code duplication.
function Invoke-SSHOnce {
    param (
        [Parameter(Mandatory = $true)][string]$SshExePath,
        [Parameter(Mandatory = $true)][array]$Params,
        [Parameter(Mandatory = $false)][uint16]$ExecutionTimeoutSeconds = 0,
        [Parameter(Mandatory = $false)][string]$IpAddress = '',
        [Parameter(Mandatory = $false)][string]$Command = ''
    )

    $rawOutput = $null
    $sshExitCode = 0
    try {
        if ($ExecutionTimeoutSeconds -gt 0) {
            $stdoutFile = [System.IO.Path]::GetTempFileName()
            $stderrFile = [System.IO.Path]::GetTempFileName()
            try {
                $process = Start-Process -FilePath $SshExePath -ArgumentList $Params -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
                if (-not $process.WaitForExit($ExecutionTimeoutSeconds * 1000)) {
                    try {
                        $process.Kill()
                        $process.WaitForExit()
                    }
                    catch {
                        Write-Log "[SSH] Failed to terminate timed out ssh.exe process: $($_.Exception.Message)"
                    }

                    $timeoutMessage = "[SSH] Command timed out after $ExecutionTimeoutSeconds sec. IP: $IpAddress. Command: $Command"
                    Write-Log $timeoutMessage
                    throw $timeoutMessage
                }

                $stdout = if (Test-Path $stdoutFile) { Get-Content -Path $stdoutFile } else { @() }
                $stderr = if (Test-Path $stderrFile) { Get-Content -Path $stderrFile } else { @() }
                $rawOutput = @($stdout) + @($stderr)
                $sshExitCode = $process.ExitCode
            }
            finally {
                Remove-Item -Path $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            $savedErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $rawOutput = &$SshExePath $Params 2>&1
                $sshExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $savedErrorActionPreference
            }
        }
    } catch {
        if ($_.Exception.Message -match '^\[SSH\] Command timed out') {
            throw
        }
        Write-Log "[SSH] Unexpected error during SSH command execution: $_"
        throw
    }

    # Convert to array of strings, handling both regular output and ErrorRecord objects
    $allLines = @()
    if ($null -ne $rawOutput) {
        foreach ($item in $rawOutput) {
            if ($item -is [System.Management.Automation.ErrorRecord]) {
                $allLines += $item.ToString()
            } else {
                $allLines += "$item"
            }
        }
    }

    # Filter out SSH-specific connection warnings that contaminate command output
    $outputLines = @()
    $hadSocketWarning = $false
    foreach ($line in $allLines) {
        if ($line -match '^close - IO is still pending' -or
            $line -match 'IO is still pending on closed socket' -or
            $line -match '^Connection .* closed' -or
            $line -match '^Warning: Permanently added') {
            Write-Log "[SSH] $line"
            if ($line -match 'IO is still pending') {
                $hadSocketWarning = $true
            }
        } else {
            $outputLines += $line
        }
    }

    return [pscustomobject]@{
        OutputLines      = $outputLines
        ExitCode         = $sshExitCode
        HadSocketWarning = $hadSocketWarning
    }
}

function Set-SshPrivateKeyPermissions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # A shared administrator-owned key must also pass OpenSSH checks under LOCAL SYSTEM.
    $administrators = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $acl = [System.Security.AccessControl.FileSecurity]::new()
    $acl.SetOwner($administrators)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($administrators, $system)) {
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity, [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow))
    }

    try {
        $existingAcl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $rules = @($existingAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        $hasExpectedPermissions = $existingAcl.AreAccessRulesProtected -and $rules.Count -eq 2 -and
            $existingAcl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -eq $administrators.Value
        foreach ($identity in @($administrators, $system)) {
            $matchingRules = @($rules | Where-Object {
                    $_.IdentityReference.Value -eq $identity.Value -and
                    $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                    $_.FileSystemRights -eq [System.Security.AccessControl.FileSystemRights]::FullControl -and
                    -not $_.IsInherited -and
                    $_.InheritanceFlags -eq [System.Security.AccessControl.InheritanceFlags]::None -and
                    $_.PropagationFlags -eq [System.Security.AccessControl.PropagationFlags]::None
                })
            $hasExpectedPermissions = $hasExpectedPermissions -and $matchingRules.Count -eq 1
        }
        if (-not $hasExpectedPermissions) {
            Write-Log "[SSH] Restricting private key '$Path' to Administrators and SYSTEM."
            Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        }
    }
    catch {
        $message = "[SSH] Cannot secure private key '$Path': $($_.Exception.Message)"
        Write-Log $message -Console
        throw $message
    }
}

function Test-SshAuthenticationFailure {
    param($Output)

    return (($Output | Out-String) -match '(?im)^\s*(?:WARNING:\s+UNPROTECTED PRIVATE KEY FILE!|Bad permissions(?:\.|\s*$)|Load key\s+.+:|(?:[^\s]+@[^\s]+:\s*)?Permission denied\s*\((?:publickey|password|keyboard-interactive)|Host key verification failed)')
}

function Invoke-SSHWithKey {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Command = $(throw 'Command not specified'),
        [Parameter(Mandatory = $false)]
        [switch]
        $Nested,
        [Parameter(Mandatory = $false)]
        [string] $IpAddress = $ipControlPlane,
        [string] $UserName = $defaultUserName,
        [Parameter(Mandatory = $false)]
        [uint16]$ExecutionTimeoutSeconds = 0
    )
    Set-SshPrivateKeyPermissions -Path $key
    $userOnRemoteMachine = "$UserName@$IpAddress"
    $params = '-n', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', '-i', $key, $userOnRemoteMachine, $Command

    if ($Nested -eq $true) {
        # omit the "-n" param
        $params = $params[1..($params.Length - 1)]
    }

    $result = Invoke-SSHOnce -SshExePath $sshExe -Params $params -ExecutionTimeoutSeconds $ExecutionTimeoutSeconds -IpAddress $IpAddress -Command $Command

    $outputLines = $result.OutputLines
    $sshExitCode = $result.ExitCode
    $hadSocketWarning = $result.HadSocketWarning

    # If a socket cleanup warning occurred, the exit code may be misleading.
    # Windows SSH can return various non-zero exit codes (255, 3221226356, etc.)
    # when the socket cleanup warning happens, even if the command succeeded.
    # If we have actual output and a socket warning, treat the command as successful.
    if ($hadSocketWarning -and -not (Test-SshAuthenticationFailure -Output $outputLines)) {
        if ($outputLines.Count -gt 0) {
            # We have real output - the command likely succeeded despite the socket warning
            Write-Log "[SSH] Socket warning detected but command produced output - treating as success"
            $global:LASTEXITCODE = 0
        } elseif ($sshExitCode -eq 255 -or $sshExitCode -eq -1 -or $sshExitCode -gt 255) {
            # No output and SSH-level error code - likely a transient connection issue
            Write-Log "[SSH] Ignoring transient socket warning with exit code $sshExitCode - command likely succeeded"
            $global:LASTEXITCODE = 0
        } elseif ($sshExitCode -ne 0) {
            # Socket warning + no output + small non-zero exit code (e.g. 1, 2).
            # This is the sporadic failure case: Windows SSH corrupted the exit code
            # during socket cleanup. Retry once to confirm.
            Write-Log "[SSH] Socket warning with exit code $sshExitCode and no output - retrying command once"
            Start-Sleep -Seconds 1
            $retryResult = Invoke-SSHOnce -SshExePath $sshExe -Params $params -ExecutionTimeoutSeconds $ExecutionTimeoutSeconds -IpAddress $IpAddress -Command $Command

            $outputLines = $retryResult.OutputLines
            if (Test-SshAuthenticationFailure -Output $retryResult.OutputLines) {
                $global:LASTEXITCODE = $retryResult.ExitCode
            }
            elseif ($retryResult.ExitCode -eq 0 -or $retryResult.OutputLines.Count -gt 0 -or $retryResult.HadSocketWarning) {
                # Retry succeeded, or produced output, or hit the same socket warning again.
                # In all cases the remote command is almost certainly fine — the socket
                # warning is definitive evidence of a Windows SSH client bug.
                Write-Log "[SSH] Retry resolved socket warning issue (exit code: $($retryResult.ExitCode), output lines: $($retryResult.OutputLines.Count), socket warning: $($retryResult.HadSocketWarning)) - treating as success"
                $global:LASTEXITCODE = 0
            } else {
                # Retry failed without socket warning — genuine remote command failure
                Write-Log "[SSH] Retry also failed with exit code $($retryResult.ExitCode) without socket warning - preserving error"
                $global:LASTEXITCODE = $retryResult.ExitCode
            }
        } else {
            $global:LASTEXITCODE = 0
        }
    } else {
        # No socket warning - preserve the actual exit code for the caller
        $global:LASTEXITCODE = $sshExitCode
    }

    # Return clean output as a single string (joining with newlines if multiple lines)
    # Note: Do NOT log output to console here - callers decide how to display output
    if ($outputLines.Count -eq 0) {
        return ''
    } elseif ($outputLines.Count -eq 1) {
        return $outputLines[0]
    } else {
        # Return as array to preserve line structure for callers that iterate over lines
        return $outputLines
    }
}

# Helper function to filter SSH socket warnings from output
# Used to clean up transient "close - IO is still pending" and similar messages
function Get-FilteredSSHOutput {
    param(
        [Parameter(Mandatory = $false)]
        $RawOutput
    )

    if ($null -eq $RawOutput) {
        return ''
    }

    $outputLines = @()
    foreach ($item in @($RawOutput)) {
        $line = if ($item -is [System.Management.Automation.ErrorRecord]) {
            $item.ToString()
        } else {
            "$item"
        }

        # Filter out SSH-specific connection warnings
        if ($line -notmatch '^close - IO is still pending' -and
            $line -notmatch 'IO is still pending on closed socket' -and
            $line -notmatch '^Connection .* closed' -and
            $line -notmatch '^Warning: Permanently added') {
            $outputLines += $line
        }
    }

    if ($outputLines.Count -eq 0) {
        return ''
    } elseif ($outputLines.Count -eq 1) {
        return $outputLines[0]
    } else {
        return $outputLines -join "`n"
    }
}

# Helper function to invoke SCP with SSH socket warning handling
# Filters transient "close - IO is still pending" warnings and corrects exit codes
function Invoke-SCPWithKey {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Target,
        [Parameter(Mandatory = $false)]
        [switch]$Recursive = $false,
        [Parameter(Mandatory = $false)]
        [uint16]$Retries = 3,
        [Parameter(Mandatory = $false)]
        [uint16]$RetryDelay = 2
    )

    Set-SshPrivateKeyPermissions -Path $key
    $params = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', '-i', $key)
    if ($Recursive) { $params += '-r' }
    $params += $Source, $Target

    $attempt = 0
    $lastOutput = $null
    $lastScpExitCode = 0

    do {
        $attempt++

        # Capture all output first, then filter SSH connection warnings
        $rawOutput = $null
        $scpExitCode = 0
        $savedErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $rawOutput = &scp.exe $params 2>&1
            $scpExitCode = $LASTEXITCODE
        } catch {
            Write-Log "[SCP] Unexpected error during SCP execution: $_"
            throw
        }
        finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }

        # Convert to array of strings, handling both regular output and ErrorRecord objects
        $allLines = @()
        if ($null -ne $rawOutput) {
            foreach ($item in $rawOutput) {
                if ($item -is [System.Management.Automation.ErrorRecord]) {
                    $allLines += $item.ToString()
                } else {
                    $allLines += "$item"
                }
            }
        }

        # Filter out SSH-specific connection warnings
        $outputLines = @()
        $hadSocketWarning = $false
        foreach ($line in $allLines) {
            if ($line -match '^close - IO is still pending' -or
                $line -match 'IO is still pending on closed socket' -or
                $line -match '^Connection .* closed' -or
                $line -match '^Warning: Permanently added') {
                Write-Log "[SCP] $line"
                if ($line -match 'IO is still pending') {
                    $hadSocketWarning = $true
                }
            } else {
                $outputLines += $line
            }
        }

        # Correct exit code if socket warning detected with SSH-level error codes
        $authenticationFailed = Test-SshAuthenticationFailure -Output $outputLines
        if ($hadSocketWarning -and -not $authenticationFailed) {
            if ($scpExitCode -eq 255 -or $scpExitCode -eq -1 -or $scpExitCode -gt 255) {
                Write-Log "[SCP] Ignoring transient socket warning with exit code $scpExitCode - transfer likely succeeded"
                $global:LASTEXITCODE = 0
            } else {
                $global:LASTEXITCODE = $scpExitCode
            }
        } else {
            $global:LASTEXITCODE = $scpExitCode
        }

        $lastOutput = if ($outputLines.Count -eq 0) { '' } elseif ($outputLines.Count -eq 1) { $outputLines[0] } else { $outputLines -join "`n" }
        $lastScpExitCode = $LASTEXITCODE

        if ($lastScpExitCode -eq 0 -or $authenticationFailed) {
            return $lastOutput
        }

        if ($attempt -le $Retries) {
            Write-Log "[SCP] Attempt $attempt failed with exit code $lastScpExitCode, retrying in $RetryDelay seconds..."
            Start-Sleep -Seconds $RetryDelay
        }
    } while ($attempt -le $Retries)

    # Return the output even on failure - caller decides how to handle
    $global:LASTEXITCODE = $lastScpExitCode
    return $lastOutput
}

function Invoke-ExeWithAsciiEncoding {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [Parameter(Mandatory = $true)][array]$Arguments,
        [string]$PipeInput = $null
    )
    $oldInputEncoding  = [Console]::InputEncoding
    $oldOutputEncoding = [Console]::OutputEncoding
    try {
        [Console]::InputEncoding  = [System.Text.Encoding]::ASCII
        [Console]::OutputEncoding = [System.Text.Encoding]::ASCII
        $result = Write-Output $PipeInput | & $ExePath @Arguments 2>&1
        return $result
    } finally {
        [Console]::InputEncoding  = $oldInputEncoding
        [Console]::OutputEncoding = $oldOutputEncoding
    }
}

function Invoke-CmdOnControlPlaneViaSSHKey(
    [Parameter(Mandatory = $false)]
    $CmdToExecute,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [uint16]$Retries = 0,
    [Parameter(Mandatory = $false)]
    [uint16]$Timeout = 1,
    [Parameter(Mandatory = $false)]
    [switch]$NoLog = $false,
    [Parameter(Mandatory = $false , HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
    [switch]$Nested = $false,
    [Parameter(Mandatory = $false, HelpMessage = 'repair CMD for the case first run did not work out')]
    [string]$RepairCmd = $null) {

    $invocationParams = @{
        CmdToExecute = $CmdToExecute
        IgnoreErrors = $IgnoreErrors
        Retries      = $Retries
        Timeout      = $Timeout
        NoLog        = $NoLog
        Nested       = $Nested
        RepairCmd    = $RepairCmd
        IpAddress    = $ipControlPlane
    }
    return Invoke-CmdOnVmViaSSHKey @invocationParams
}

function Invoke-CmdOnVmViaSSHKey(
    [Parameter(Mandatory = $false)]
    $CmdToExecute,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [uint16]$Retries = 0,
    [Parameter(Mandatory = $false)]
    [uint16]$Timeout = 1,
    [Parameter(Mandatory = $false)]
    [switch]$NoLog = $false,
    [Parameter(Mandatory = $false , HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
    [switch]$Nested = $false,
    [Parameter(Mandatory = $false, HelpMessage = 'repair CMD for the case first run did not work out')]
    [string]$RepairCmd = $null,
    [Parameter(Mandatory = $false)]
    [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
    [string]$UserName = $defaultUserName,
    [Parameter(Mandatory = $false)]
    [uint16]$ExecutionTimeoutSeconds = 0) {

    if (!$NoLog) {
        Write-Log "cmd: $CmdToExecute, retries: $Retries, timeout: $Timeout sec, execution timeout: $ExecutionTimeoutSeconds sec, ignore err: $IgnoreErrors, nested: $Nested, ip address: $IpAddress"
    }
    $Stoploop = $false
    [uint16]$Retrycount = 1
    do {
        $success = $false
        $output = $null
        $exitCode = $null
        try {
            $output = Invoke-SSHWithKey -Command $CmdToExecute -Nested:$Nested -UserName $UserName -IpAddress $IpAddress -ExecutionTimeoutSeconds $ExecutionTimeoutSeconds
            $exitCode = $LASTEXITCODE
            $success = ($exitCode -eq 0)

            if (!$success -and !$IgnoreErrors) {
                throw "Error occurred while executing command '$CmdToExecute' in control plane (exit code: '$LASTEXITCODE')"
            }
            $Stoploop = $true
        }
        catch {
            Write-Log $_
            if ($null -eq $output) {
                $output = $_.Exception.Message
            }
            if ($Retrycount -gt $Retries -or (Test-SshAuthenticationFailure -Output $output) -or
                ($output -match '^\[SSH\] Cannot secure private key')) {
                $Stoploop = $true
            }
            else {
                Write-Log "cmd: $CmdToExecute will be retried.."

                if ($null -ne $RepairCmd -and !$IgnoreErrors) {
                    Write-Log "Executing repair cmd: $RepairCmd"

                    Invoke-SSHWithKey -Command $RepairCmd -Nested:$Nested -UserName $UserName -IpAddress $IpAddress
                }

                Start-Sleep -Seconds $Timeout
                $Retrycount = $Retrycount + 1
            }
        }
    }
    While ($Stoploop -eq $false)

    return [pscustomobject]@{ Success = $success; Output = $output; ExitCode = $exitCode }
}

function Invoke-CmdOnControlPlaneViaUserAndPwd(
    [Parameter(Mandatory = $false)]
    $CmdToExecute,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [uint16]$Retries = 0,
    [Parameter(Mandatory = $false)]
    [uint16]$Timeout = 2,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUser = $remoteUser,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUserPwd = $remotePwd,
    [Parameter(Mandatory = $false)]
    [switch]$NoLog = $false,
    [Parameter(Mandatory = $false)]
    [string]$RepairCmd = $null) {
    if (!$NoLog) {
        Write-Log "cmd: $CmdToExecute, retries: $Retries, timeout: $Timeout sec, ignore err: $IgnoreErrors"
    }
    $Stoploop = $false
    [uint16]$Retrycount = 1
    do {
        try {
            $output = &"$plinkExe" -ssh -4 -legacy-stdio-prompts $RemoteUser -pw $RemoteUserPwd -no-antispoof $CmdToExecute 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
            $success = ($LASTEXITCODE -eq 0)
            if (!$success -and !$IgnoreErrors) { throw "Error occurred while executing command '$CmdToExecute' (exit code: '$LASTEXITCODE')" }
            $Stoploop = $true
        }
        catch {
            Write-Log $_
            if ($Retrycount -gt $Retries) {
                $Stoploop = $true
            }
            else {
                Write-Log "cmd: $CmdToExecute will be retried.."

                # try to repair the command
                if (![string]::IsNullOrWhiteSpace($RepairCmd) -and !$IgnoreErrors) {
                    Write-Log "Executing repair cmd: $RepairCmd"
                    &"$plinkExe" -ssh -4 -legacy-stdio-prompts $RemoteUser -pw $RemoteUserPwd -no-antispoof $RepairCmd 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
                }

                Start-Sleep -Seconds $Timeout
                $Retrycount = $Retrycount + 1
            }
        }
    }
    While ($Stoploop -eq $false)

    return [pscustomobject]@{ Success = $success; Output = $output }
}

function Get-IsControlPlaneRunning {
    $vmNode = Get-VM -Name $nameControlPlane -ErrorAction SilentlyContinue

    if ($null -eq ($vmNode)) {
        return $false
    }

    $masterVmState = ($vmNode).State
    return $masterVmState -eq [Microsoft.HyperV.PowerShell.VMState]::Running
}

function Copy-FromControlPlaneViaSSHKey($Source, $Target,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false) {
    
    Copy-FromRemoteComputerViaSSHKey -Source $Source -Target $Target -IpAddress $ipControlPlane -UserName $defaultUserName -IgnoreErrors:$IgnoreErrors
}

function Copy-FromRemoteComputerViaSSHKey($Source, $Target,
    [Parameter(Mandatory = $false)]
    [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
    [Parameter(Mandatory = $false)]
    [string]$UserName = $(throw 'Argument missing: UserName'),
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [uint16]$Retries = 3,
    [Parameter(Mandatory = $false)]
    [uint16]$RetryDelay = 2) {
    Write-Log "Copying '$Source' to '$Target', ignoring errors: '$IgnoreErrors'"

    $userOnRemoteMachine = "$UserName@$IpAddress"

    $linuxSourceDirectory = $Source -replace "${userOnRemoteMachine}:", ''
    $leaf = Split-Path $linuxSourceDirectory -Leaf
    $filter = $leaf

    # Use Invoke-CmdOnVmViaSSHKey with retry logic to handle transient SSH errors like "close - IO is still pending"
    $result = Invoke-CmdOnVmViaSSHKey -CmdToExecute "[ -d '$linuxSourceDirectory' ]" -IpAddress $IpAddress -UserName $UserName -IgnoreErrors -NoLog -Retries 2 -Timeout 2
    $isDir = $result.Success

    if ($leaf.Contains("*")) {
        # copy all/specific files in directory e.g. pvc-* or *
        (Invoke-CmdOnControlPlaneViaSSHKey 'sudo mkdir /tmp/matchedFilesCopyFromControlPlaneViaSSHKey').Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey "cd `$(dirname '$linuxSourceDirectory') && find . -name '$filter' | sudo xargs -i cp --parents {} -r /tmp/matchedFilesCopyFromControlPlaneViaSSHKey").Output | Write-Log

        $tarFolder = "/tmp/matchedFilesCopyFromControlPlaneViaSSHKey"
        $targetDirectory = $Target
    } elseif ($isDir) {
        # single folder copy
        $tarFolder = $linuxSourceDirectory
        $targetDirectory = "$Target\$leaf"
    } else {
        $output = Invoke-SCPWithKey -Source "${userOnRemoteMachine}:$Source" -Target "$Target" -Recursive -Retries $Retries -RetryDelay $RetryDelay
        if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
            throw "Could not copy '$Source' to '$Target': $output"
        }
        Write-Log $output
        return
    }

    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo rm -rf /tmp/copy.tar').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey "sudo tar -cf /tmp/copy.tar -C $tarFolder .").Output | Write-Log

    $output = Invoke-SCPWithKey -Source "${userOnRemoteMachine}:/tmp/copy.tar" -Target "$env:temp\copy.tar" -Retries $Retries -RetryDelay $RetryDelay
    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }
    Write-Log $output

    New-Item -Path "$targetDirectory" -ItemType Directory -ErrorAction SilentlyContinue | Out-Null

    $output = tar.exe -xf "$env:temp\copy.tar" -C "$targetDirectory"
    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }
    Write-Log $output

    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo rm -rf /tmp/copy.tar').Output | Write-Log
    Remove-Item -Path "$env:temp\copy.tar" -Force -ErrorAction SilentlyContinue
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo rm -rf /tmp/matchedFilesCopyFromControlPlaneViaSSHKey').Output | Write-Log
}

function Copy-FromRemoteComputerViaUserAndPwd($Source, $Target, $IpAddress,
    [Parameter(Mandatory = $false)]
    [string]$UserName = $defaultUserName,
    [Parameter(Mandatory = $false)]
    [string]$UserPwd = $remotePwd,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false) {
    Write-Log "Copying '$Source' to '$Target' at '$IpAddress', ignoring errors: '$IgnoreErrors'"

    $output = Invoke-ExeWithAsciiEncoding -ExePath $scpExe -Arguments @('-ssh','-4','-q','-r','-pw',$UserPwd,"${UserName}@${IpAddress}:$Source","$Target") -PipeInput 'yes'

    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }
    Write-Log $output
}

function Copy-ToControlPlaneViaSSHKey($Source, $Target,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [uint16]$Retries = 3,
    [Parameter(Mandatory = $false)]
    [uint16]$RetryDelay = 2) {
    
    Copy-ToRemoteComputerViaSshKey -Source $Source -Target $Target -UserName $defaultUserName -IpAddress $ipControlPlane -IgnoreErrors:$IgnoreErrors -Retries $Retries -RetryDelay $RetryDelay
}

function Copy-ToRemoteComputerViaSshKey($Source, $Target, $UserName, $IpAddress,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [uint16]$Retries = 3,
    [Parameter(Mandatory = $false)]
    [uint16]$RetryDelay = 2) {
    Write-Log "Copying '$Source' to '$Target', ignoring errors: '$IgnoreErrors'"

    $remoteComputerUser = "$UserName@$IpAddress"

    $leaf = Split-Path $Source -leaf
    $targetDirectory = $Target -replace "${remoteComputerUser}:", ''

    $tempDirectory = "$env:TEMP\matchedFilesCopyToRemoteComputerViaSSHKey"
    if ($leaf.Contains("*")) {
        # copy all/specific files in directory e.g. pvc-* or *
        $filter = $leaf

        New-Item -Path "$tempDirectory" -ItemType Directory -Force | Out-Null
        Get-ChildItem -Path $(Split-Path $Source -Parent) -Filter $filter -Force | ForEach-Object {
            Write-Log "  Adding '$($_.FullName)'.."
            Copy-Item "$($_.FullName)" "$tempDirectory" -Force -Recurse
        }

        $tarFolder = "$tempDirectory"
    } elseif ($(Test-Path $Source) -and (Get-Item $Source) -is [System.IO.DirectoryInfo]) {
        # single folder copy
        $tarFolder = $Source
        $targetDirectory = "$targetDirectory/$leaf"
    } else {
         # single file copy
        $output = Invoke-SCPWithKey -Source "$Source" -Target "${remoteComputerUser}:$Target" -Recursive -Retries $Retries -RetryDelay $RetryDelay
        if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
            throw "Could not copy '$Source' to '$Target': $output"
        }
        Write-Log $output
        return
    }

    $isControlPlane = ($IpAddress -eq $ipControlPlane)
    $invokeSshCmd = if ($isControlPlane) {
        { param($cmd) (Invoke-CmdOnControlPlaneViaSSHKey $cmd).Output | Write-Log }
    } else {
        { param($cmd) (Invoke-CmdOnVmViaSSHKey -CmdToExecute $cmd -UserName $UserName -IpAddress $IpAddress).Output | Write-Log }
    }

    & $invokeSshCmd 'sudo rm -rf /tmp/copy.tar'

    $output = tar.exe -cf "$env:TEMP\copy.tar" -C $tarFolder .
    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }

    $output = Invoke-SCPWithKey -Source "$env:temp\copy.tar" -Target "${remoteComputerUser}:/tmp" -Retries $Retries -RetryDelay $RetryDelay
    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }

    & $invokeSshCmd "mkdir -p $targetDirectory"
    & $invokeSshCmd "tar -xf /tmp/copy.tar -C $targetDirectory"
    & $invokeSshCmd 'sudo rm -rf /tmp/copy.tar'
    Remove-Item -Path "$env:temp\copy.tar" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$tempDirectory" -Force -Recurse -ErrorAction SilentlyContinue
}

function Copy-ToControlPlaneViaUserAndPwd($Source, $Target,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [uint16]$Retries = 3,
    [Parameter(Mandatory = $false)]
    [uint16]$RetryDelay = 2) {
    Write-Log "Copying '$Source' to '$Target', ignoring errors: '$IgnoreErrors'"

    $attempt = 0
    $output = $null

    do {
        $attempt++
        $output = Invoke-ExeWithAsciiEncoding -ExePath $scpExe -Arguments @('-ssh','-4','-q','-r','-pw',$remotePwd,"$Source","${remoteUser}:$Target") -PipeInput 'yes'

        if ($LASTEXITCODE -eq 0) {
            break
        }

        if ($attempt -le $Retries) {
            Write-Log "[SCP] Attempt $attempt failed (exit code $LASTEXITCODE), retrying in $RetryDelay seconds..."
            Start-Sleep -Seconds $RetryDelay
        }
    } while ($attempt -le $Retries)

    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }
    Write-Log $output
}

function Copy-ToRemoteComputerViaUserAndPwd($Source, $Target, $IpAddress,
    [Parameter(Mandatory = $false)]
    [string]$UserName = $defaultUserName,
    [Parameter(Mandatory = $false)]
    [string]$UserPwd = $remotePwd,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [uint16]$Retries = 3,
    [Parameter(Mandatory = $false)]
    [uint16]$RetryDelay = 2) {
    Write-Log "Copying '$Source' to '$Target', ignoring errors: '$IgnoreErrors'"

    $attempt = 0
    $output = $null

    do {
        $attempt++
        $output = Invoke-ExeWithAsciiEncoding -ExePath $scpExe -Arguments @('-ssh','-4','-q','-r','-pw',$UserPwd,"$Source","${UserName}@${IpAddress}:$Target") -PipeInput 'yes'

        if ($LASTEXITCODE -eq 0) {
            break
        }

        if ($attempt -le $Retries) {
            Write-Log "[SCP] Attempt $attempt failed (exit code $LASTEXITCODE), retrying in $RetryDelay seconds..."
            Start-Sleep -Seconds $RetryDelay
        }
    } while ($attempt -le $Retries)

    if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) {
        throw "Could not copy '$Source' to '$Target': $output"
    }
    Write-Log $output
}

function Assert-ControlPlaneArtifactDiskSizeCompatibility {
    param(
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of Control Plane VM (Linux)')]
        [uint64] $MasterDiskSize,
        [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
        [switch] $WSL = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Force online installation')]
        [switch] $ForceOnlineInstallation = $false
    )

    if ($ForceOnlineInstallation) {
        Write-Log '[Precheck] Skip package disk-size guard for force-online installation mode'
        return
    }

    $controlPlaneBaseImagePath = Get-ControlPlaneVMBaseImagePath
    if (!(Test-Path -Path $controlPlaneBaseImagePath)) {
        Write-Log "[Precheck] Skip package disk-size guard because packaged control-plane artifact is missing at '$controlPlaneBaseImagePath'. This is allowed for online installation when the base VHDX is not present in the local bin folder."
        return
    }

    try {
        $packagedVhd = Get-VHD -Path $controlPlaneBaseImagePath -ErrorAction Stop
    }
    catch {
        throw "[PREREQ-FAILED] Precheck failed: could not read packaged control-plane VHDX at '$controlPlaneBaseImagePath': $_"
    }

    $packagedDiskSize = [uint64]$packagedVhd.Size
    $requestedDiskSize = [uint64]$MasterDiskSize

    if ($requestedDiskSize -lt $packagedDiskSize) {
        $requestedSizeGb = Convert-BytesToGB -SizeInBytes $requestedDiskSize
        $packagedSizeGb = Convert-BytesToGB -SizeInBytes $packagedDiskSize
        throw "[PREREQ-FAILED] Precheck failed: requested master disk size $requestedSizeGb GB is smaller than packaged control-plane disk size $packagedSizeGb GB. Installation is stopped to prevent artifact inconsistency. Rerun install with master disk >= $packagedSizeGb GB, or rebuild the package with a smaller control-plane base disk."
    }

    $mode = if ($WSL) { 'WSL' } else { 'Hyper-V' }
    Write-Log "[Precheck] Control-plane packaged disk-size compatibility passed for $mode mode"
}

function Test-ControlPlanePrerequisites(
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for Control Plane VM (Linux)')]
    [long] $MasterVMProcessorCount,
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Control Plane VM (Linux)')]
    [long] $MasterVMMemory,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of Control Plane VM (Linux)')]
    [uint64] $MasterDiskSize,
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
    [switch] $WSL = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force online installation')]
    [switch] $ForceOnlineInstallation = $false) {

    Write-Log "Using Control Plane VM ProcessorCount: $MasterVMProcessorCount"
    Write-Log "Using Control Plane VM Memory: $(Convert-BytesToGB -SizeInBytes $MasterVMMemory)GB"
    Write-Log "Using Control Plane VM Diskspace: $(Convert-BytesToGB -SizeInBytes $MasterDiskSize)GB"

    # check memory
    $minimalProvisioningBaseImageSize = Get-MinimalProvisioningBaseMemorySize
    if ( $MasterVMMemory -lt $minimalProvisioningBaseImageSize ) {
        Write-Log "k2s needs minimal $(Convert-BytesToGB -SizeInBytes $minimalProvisioningBaseImageSize)GB main memory, you have passed a lower value!" -Error
        throw "[PREREQ-FAILED] Master node memory passed too low: $(Convert-BytesToGB -SizeInBytes $MasterVMMemory)GB"
    }

    # check disk
    $minimalProvisioningBaseImageSize = Get-MinimalProvisioningBaseImageDiskSize
    if ( $MasterDiskSize -lt $minimalProvisioningBaseImageSize ) {
        Write-Log "k2s needs minimal $(Convert-BytesToGB -SizeInBytes $minimalProvisioningBaseImageSize)GB disk space, you have passed a lower value!" -Error
        throw "[PREREQ-FAILED] Master VM Disk size passed too low: $(Convert-BytesToGB -SizeInBytes $MasterDiskSize)GB"
    }

    Assert-ControlPlaneArtifactDiskSizeCompatibility -MasterDiskSize $MasterDiskSize -WSL:$WSL -ForceOnlineInstallation:$ForceOnlineInstallation

    #Check for running VMs and minikube
    $runningVMs = Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running }
    if ($runningVMs) {
        Write-Log 'Active Hyper-V VM:'
        Write-Log $($runningVMs | Select-Object -Property Name)
        if ($runningVMs | Where-Object Name -eq 'minikube') {
            throw "[PREREQ-FAILED] Minikube must be stopped before running the installer, do 'minikube stop'"
        }
    }

    # Check for external switches
    Test-ExistingExternalSwitch

    if (Get-VM -ErrorAction SilentlyContinue -Name $nameControlPlane) {
        throw "[PREREQ-FAILED] $nameControlPlane VM must not exist before installation, please perform k2s uninstall"
    }
}

function Convert-BytesToGB {
    param (
        [parameter(Mandatory = $true)]
        [long] $SizeInBytes
    )
    return [math]::round($SizeInBytes / 1GB, 2)
}

function Test-ExistingExternalSwitch {
    $l2BridgeSwitchName = Get-L2BridgeSwitchName
    $externalSwitches = Get-VMSwitch | Where-Object { $_.SwitchType -eq 'External' -and $_.Name -ne $l2BridgeSwitchName}
    if ($externalSwitches) {
        Write-Log 'Found External Switches:'
        Write-Log $($externalSwitches | Select-Object -Property Name)
        Write-Log 'Precheck failed: Cannot proceed further with existing External Network Switches as it conflicts with k2s networking' -Console
        Write-Log "Remove all your External Network Switches with command PS>Get-VMSwitch | Where-Object { `$_.SwitchType -eq 'External'  -and `$_.Name -ne '$l2BridgeSwitchName'} | Remove-VMSwitch -Force" -Console
        Write-Log 'WARNING: This will remove your External Switches, please check whether these switches are required before executing the command' -Console
        throw '[PREREQ-FAILED] Remove all the existing External Network Switches and retry the k2s command again'
    }

}

function Get-LinuxOsType($LinuxVhdxPath) {
    $linuxOsType = $LinuxOsTypeDebianCloud
    if (!([string]::IsNullOrWhiteSpace($LinuxVhdxPath))) {
        if (!(Test-Path $LinuxVhdxPath)) {
            throw "The specified file in the path '`$LinuxVhdxPath' does not exist"
        }
        $fileExtension = (Get-Item $LinuxVhdxPath).Extension
        if (!($fileExtension -eq '.vhdx')) {
            throw ('Disk is not a vhdx or vhd disk.' )
        }

        $linuxOsType = $LinuxOsTypeUbuntu
    }
    return $linuxOsType
}

function Get-ControlPlaneVMBaseImagePath {
    $linuxOsType = Get-LinuxOsType
    $fileName = switch ( $linuxOsType ) {
        $LinuxOsTypeDebianCloud { $ControlPlaneVMBaseImageName }
        $LinuxOsTypeUbuntu { $ControlPlaneVMBaseUbuntuImageName }
        Default { throw "The Linux OS type '$linuxOsType' is not supported." }
    }
    return "$kubePath\bin\$fileName"
}

function Get-ControlPlaneVMRootfsPath {
    $linuxOsType = Get-LinuxOsType
    $fileName = switch ( $linuxOsType ) {
        $LinuxOsTypeDebianCloud { $ControlPlaneVMRootfsName }
        $LinuxOsTypeUbuntu { $ControlPlaneVMUbuntuRootfsName }
        Default { throw "The Linux OS type '$linuxOsType' is not supported." }
    }
    return "$kubePath\bin\$fileName"
}

function Test-SshRouteViaLocalAddress {
    param (
        [Parameter(Mandatory = $true)]
        [string]$RemoteIPAddress,
        [Parameter(Mandatory = $true)]
        [string]$LocalIPAddress
    )

    $localAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -eq $LocalIPAddress })
    if ($localAddresses.Count -ne 1 -or $localAddresses[0].AddressState -ne 'Preferred') {
        Write-Log "[SSH-Routing] Waiting for a unique, preferred local address '$LocalIPAddress'."
        return $false
    }

    $routeErrors = @()
    $routeInfo = @(Find-NetRoute -RemoteIPAddress $RemoteIPAddress -ErrorAction SilentlyContinue -ErrorVariable routeErrors)
    if ($routeErrors.Count -gt 0) {
        Write-Log "[SSH-Routing] Cannot determine the route to '$RemoteIPAddress': $($routeErrors | Out-String)"
        return $false
    }

    $sources = @($routeInfo | Where-Object { $_.IPAddress -eq $LocalIPAddress })
    $routes = @($routeInfo | Where-Object { $_.DestinationPrefix })
    $interfaceIndex = $localAddresses[0].InterfaceIndex
    if ($sources.Count -eq 1 -and $routes.Count -eq 1 -and
        $sources[0].InterfaceIndex -eq $interfaceIndex -and
        $routes[0].InterfaceIndex -eq $interfaceIndex -and
        $routes[0].NextHop -eq '0.0.0.0' -and
        $routes[0].DestinationPrefix -ne '0.0.0.0/0') {
        return $true
    }

    $selectedRoutes = ($routes | ForEach-Object {
            "$($_.DestinationPrefix) via $($_.NextHop) on '$($_.InterfaceAlias)' (index $($_.InterfaceIndex))"
        }) -join '; '
    Write-Log "[SSH-Routing] Waiting for an on-link route from '$LocalIPAddress' to '$RemoteIPAddress' on interface $interfaceIndex. Selected routes: '$selectedRoutes'."
    return $false
}

<#
.SYNOPSIS
    Waits until a command can be executet via SSH on a remote machine.
.DESCRIPTION
    Waits until a command can be executet via SSH on a remote machine. Aborts the operation if a certain number of retries failed.
.PARAMETER User
    The user and IP of the remote machine, e.g. admin@192.168.0.11
.PARAMETER UserPwd
    The password for the remote user
.PARAMETER SshTestCommand
    The SSH test command to execute on the remote machine, e.g. 'whoami'
.PARAMETER ExpectedSshTestCommandResult
    The expected SSH test command result. DEFAULT: regex expression; with StrictEqualityCheck = $true: e.g. for command 'whoami' ==> 'my-machine\admin'
.PARAMETER StrictEqualityCheck
    If set, the SSH test command result will be checked with strict equality comparer (i.e. '-eq') instead of a regex expression match
.PARAMETER LocalIPAddress
    For key-based SSH, require an on-link route using this local IPv4 address and require a known host key.
.EXAMPLE
    Wait-ForSshPossible -User 'admin@192.168.0.11' -UserPwd 'my-secret' -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl'
    ==> result will match the regex expression
.EXAMPLE
    Wait-ForSshPossible -User 'admin@192.168.0.11' -UserPwd 'my-secret' -SshTestCommand 'whoami' -ExpectedSshTestCommandResult 'my-machine\admin' -StrictEqualityCheck
    ==> result will be checked for strict equality, i.e. <result> -eq 'my-machine\admin'
#>
function Wait-ForSshPossible {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $User = $(throw 'Please specify the user and IP of the remote machine, e.g. admin@192.168.0.11'),
        [Parameter()]
        [string]$SshKey = '',
        [Parameter()]
        [string]$UserPwd = '',
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SshTestCommand = $(throw 'Please specify the SSH test command to execute on the remote machine.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ExpectedSshTestCommandResult = $(throw 'Please specify the expected SSH test command result.'),
        [Parameter(HelpMessage = 'Check the expected and actual result for strict equality; otherwise, a regex match will be conducted.')]
        [switch]$StrictEqualityCheck = $false,
        [Parameter(HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
        [switch]$Nested = $false,
        [Parameter()]
        [string]$LocalIPAddress = ''
    )
    if ($LocalIPAddress -ne '' -and $SshKey -eq '') {
        $message = '[SSH-Routing] A local address can only be specified for key-based SSH.'
        Write-Log $message -Console
        throw $message
    }
    $iteration = 0
    $maxIterations = 80  # 30 attempts before recovery + 50 after, handles nested Hyper-V issues
    $baseDelay = 3       # Base delay in seconds
    $maxDelay = 15       # Maximum delay between attempts
    $startTime = Get-Date
    if ($SshKey -ne '') {
        Set-SshPrivateKeyPermissions -Path $SshKey
    }
    $hostKeyChecking = if ($LocalIPAddress -ne '') { 'yes' } else { 'no' }
    $sshParams = @('-o', 'BatchMode=yes', '-o', "StrictHostKeyChecking=$hostKeyChecking", '-o', 'ConnectTimeout=10')
    if (-not $Nested) {
        $sshParams += '-n'
    }
    $sshParams += @('-i', $SshKey, $User, $SshTestCommand)
    $remoteIPAddress = ($User -split '@', 2)[-1]
    Write-Log "Performing SSH login into VM with $($User)..."
    while ($true) {
        $iteration++
        $rawResult = ''

        if ($LocalIPAddress -ne '' -and -not (Test-SshRouteViaLocalAddress -RemoteIPAddress $remoteIPAddress -LocalIPAddress $LocalIPAddress)) {
            $sshExitCode = 255
            $result = "[SSH-Routing] Waiting for the VM network from '$LocalIPAddress' to '$remoteIPAddress'; SSH was not attempted."
        }
        elseif ($SshKey -ne '') {
            $savedErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $rawResult = ssh.exe @sshParams 2>&1
                $sshExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $savedErrorActionPreference
            }
            # Filter out SSH socket warnings that can interfere with result matching
            $result = Get-FilteredSSHOutput -RawOutput $rawResult
            if (Test-SshAuthenticationFailure -Output $result) {
                $message = "[SSH] Authentication or private-key failure for '$User' using '$SshKey': $result"
                # The route can change between the readiness check and SSH opening its socket.
                $hostKeyFailure = $result -match '(?im)Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED'
                if ($LocalIPAddress -ne '' -and $hostKeyFailure -and
                    -not (Test-SshRouteViaLocalAddress -RemoteIPAddress $remoteIPAddress -LocalIPAddress $LocalIPAddress)) {
                    Write-Log "[SSH-Routing] The route changed during SSH host-key verification. Retrying after VM networking is ready; trusted keys are unchanged. SSH diagnostic: $result" -Console
                }
                else {
                    Write-Log $message -Console
                    throw $message
                }
            }
            if ($sshExitCode -ne 0) {
                $result = "SSH failed (exit code $sshExitCode): $result"
            }
        }
        else {
            $plinkArgs = @('-ssh', '-4', '-legacy-stdio-prompts', $User, '-pw', $UserPwd, '-no-antispoof', "$($SshTestCommand)")
            $result = Invoke-ExeWithAsciiEncoding -ExePath $plinkExe -Arguments $plinkArgs -PipeInput 'y'
        }

        $commandSucceeded = ($SshKey -eq '' -or $sshExitCode -eq 0)
        if ($commandSucceeded -and $StrictEqualityCheck -eq $true) {
            if ($result -eq $ExpectedSshTestCommandResult) {
                break
            }
        }
        elseif ($commandSucceeded) {
            if ($result -match $ExpectedSshTestCommandResult) {
                break
            }
        }

        if ($iteration -eq $maxIterations) {
            Write-Log "SSH login into VM with $($User) still not available after $maxIterations attempts, ssh result is '$($result)' aborting..." -Console
            throw "Unable to SSH login into VM after $maxIterations attempts"
        }

        # Mid-flight network recovery: after 30 consecutive "Connection timed out" failures,
        # attempt to fix broken L2 connectivity by disconnecting/reconnecting the VM adapter.
        # This handles sporadic nested Hyper-V issues where KubeSwitch recreation leaves the
        # VM NIC in a broken state. Only triggers during failure — zero happy-path impact.
        if ($iteration -eq 30 -and $result -match 'Connection timed out') {
            Write-Log "[SSH-Recovery] 30 consecutive SSH timeouts detected. Attempting VM network adapter recovery..." -Console
            try {
                $vmName = $nameControlPlane
                $switchName = Get-ControlPlaneNodeDefaultSwitchName
                Write-Log "[SSH-Recovery] Stopping VM '$vmName'..."
                Stop-VM -Name $vmName -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5

                Write-Log "[SSH-Recovery] Disconnecting VM network adapter..."
                Disconnect-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3

                Write-Log "[SSH-Recovery] Reconnecting VM to switch '$switchName'..."
                Connect-VMNetworkAdapter -VMName $vmName -SwitchName $switchName
                Start-Sleep -Seconds 3

                Write-Log "[SSH-Recovery] Starting VM '$vmName'..."
                Start-VM -Name $vmName -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 15

                Write-Log "[SSH-Recovery] VM restarted with reconnected adapter, resuming SSH attempts..." -Console
            }
            catch {
                Write-Log "[SSH-Recovery] Recovery attempt failed: $_. Continuing SSH retries..."
            }
        }

        # Enhanced logging for sporadic failure diagnosis
        if ($iteration -ge 3) {
            $timeWaited = [int]((Get-Date) - $startTime).TotalSeconds
            Write-Log "SSH login into VM with $($User) not yet possible (attempt $iteration/$maxIterations, waited ${timeWaited}s), current result is '$($result)' waiting for it..."
        }

        # Implement progressive backoff for better handling of sporadic failures
        if ($iteration -le 5) {
            # Quick retries for the first few attempts
            $delayTime = $baseDelay
        } elseif ($iteration -le 15) {
            # Medium delays for intermediate attempts
            $delayTime = [Math]::Min($baseDelay + ($iteration - 5), $maxDelay)
        } else {
            # Longer delays for later attempts to handle slow VM initialization
            $delayTime = $maxDelay
        }

        # Add small random jitter to prevent thundering herd in concurrent scenarios
        $jitter = Get-Random -Minimum 0 -Maximum 2
        $finalDelay = $delayTime + $jitter

        Start-Sleep $finalDelay
    }
    $endTime = Get-Date
    $durationSeconds = Get-DurationInSeconds -StartTime $startTime -EndTime $endTime
    Write-Log "SSH login into VM: $($User) now possible after $iteration attempts, total duration: ${durationSeconds} seconds"
}

<#
.SYNOPSIS
    Establishes first time connection with VM by accepting the key and retries until a command can be executet via SSH on a Linux machine.
.DESCRIPTION
    Waits until Initial connection command can be executed via SSH on a Linux machine.
.EXAMPLE
    Wait-ForSSHConnectionToLinuxVMViaPwd
#>
function Wait-ForSSHConnectionToLinuxVMViaPwd(
    [Parameter(Mandatory = $false)]
    [string]$User = $remoteUser,
    [Parameter(Mandatory = $false)]
    [string]$UserPwd = $remotePwd) {
    Write-Log "Initiating first time SSH login into VM with user $User"
    Wait-ForSshPossible -User $User -UserPwd $UserPwd -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl'
}


<#
.SYNOPSIS
    Waits until a command can be executet via SSH on a Linux machine.
.DESCRIPTION
    Waits until a command can be executet via SSH on a Linux machine. Convenience wrapper around Wait-ForSshPossible.
.EXAMPLE
    Wait-ForSSHConnectionToLinuxVMViaSshKey
#>
function Wait-ForSSHConnectionToLinuxVMViaSshKey {
    Param(
        [Parameter(Mandatory = $false)]
        [string]$User = $remoteUser,
        [parameter(Mandatory = $false, HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
        [switch] $Nested = $false,
        [Parameter(Mandatory = $false)]
        [string]$LocalIPAddress = ''
    )
    Wait-ForSshPossible -User $User -SshKey $key -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl' -Nested:$Nested -LocalIPAddress $LocalIPAddress
}

function Get-DefaultUserNameControlPlane {
    return $defaultUserName
}

function Get-DefaultUserPwdControlPlane {
    return $remotePwd
}

function Get-DefaultUserNameWorkerNode {
    return $defaultUserName
}

function Get-DefaultUserPwdWorkerNode {
    return $remotePwd
}

<#
.SYNOPSIS
    Copies the Kube config file from master node to local machine.
.DESCRIPTION
    Copies the Kube config file from master node to local machine.
.EXAMPLE
    Copy-KubeConfigFromControlPlaneNode
#>
function Copy-KubeConfigFromControlPlaneNode {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
        [switch] $Nested = $false
    )

    # getting kube config from VM to windows host
    Write-Log "Retrieving kube config from master VM, writing to '$kubePath\config'"
    Remove-Item -Path "$kubePath\config" -Force -ErrorAction SilentlyContinue
    # checking cluster state
    $i = 0;
    while ($true) {
        $i++
        Write-Log "Handling loop for started cluster, checking kubeconfig availability (iteration $i):"
        Start-Sleep -s 3

        Write-Log 'Trying to get kube config from /etc/kubernetes/admin.conf'
        # Add retries to handle transient SSH socket issues
        (Invoke-CmdOnControlPlaneViaSSHKey 'sudo cp /etc/kubernetes/admin.conf /home' -Nested:$Nested -Retries 2 -Timeout 2 -IgnoreErrors).Output | Write-Log
        Write-Log 'Trying to chmod file from /home/admin.conf'
        (Invoke-CmdOnControlPlaneViaSSHKey 'sudo chmod 775 /home/admin.conf' -Nested:$Nested -Retries 2 -Timeout 2 -IgnoreErrors).Output | Write-Log
        Write-Log 'Trying to scp file from /home/admin.conf'
        $source = '/home/admin.conf'
        Copy-FromControlPlaneViaSSHKey -Source $source -Target "$kubePath\config" -IgnoreErrors
        if (Test-Path "$kubePath\config") {
            Write-Log "Kube config '$kubePath\config' successfully retrieved !"
            break;
        }
        Write-Log '... kube config not yet available.'
        if ($i -eq 25) {
            throw 'timeout, unable to find kubeconfig inside control plane, check the cluster availability'
        }
    }
}

function Get-ControlPlaneRemoteUser {
    return $remoteUser
}

Export-ModuleMember -Function Invoke-CmdOnControlPlaneViaSSHKey,
Set-SshPrivateKeyPermissions,
Invoke-CmdOnVmViaSSHKey,
Invoke-SCPWithKey,
Invoke-CmdOnControlPlaneViaUserAndPwd,
Get-IsControlPlaneRunning,
Copy-FromControlPlaneViaSSHKey,
Copy-FromRemoteComputerViaUserAndPwd,
Copy-ToControlPlaneViaSSHKey,
Copy-ToRemoteComputerViaSshKey,
Copy-ToControlPlaneViaUserAndPwd,
Copy-ToRemoteComputerViaUserAndPwd,
Test-ControlPlanePrerequisites,
Test-ExistingExternalSwitch,
Get-ControlPlaneVMBaseImagePath,
Get-ControlPlaneVMRootfsPath,
Wait-ForSSHConnectionToLinuxVMViaPwd,
Wait-ForSSHConnectionToLinuxVMViaSshKey,
Wait-ForSshPossible,
Get-DefaultUserNameControlPlane,
Get-DefaultUserPwdControlPlane,
Get-DefaultUserNameWorkerNode,
Get-DefaultUserPwdWorkerNode,
Copy-KubeConfigFromControlPlaneNode,
Get-ControlPlaneRemoteUser,
Copy-FromRemoteComputerViaSSHKey
