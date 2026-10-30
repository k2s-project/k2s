# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $modulePath = "$PSScriptRoot/vm.module.psm1"
    $moduleName = (Import-Module $modulePath -PassThru -Force).Name
}

Describe 'Invoke-CmdOnControlPlaneViaUserAndPwd retries' -Tag 'unit', 'ci', 'vm' {
    It 'recovers a hostname read after a transient connection abort' {
        InModuleScope $moduleName {
            function Test-PlinkInvocation {}
            $originalPlink = $script:plinkExe
            $script:plinkExe = 'Test-PlinkInvocation'
            $script:hostnameAttempts = 0
            Mock Write-Log { if ($Raw) { $Messages } }
            Mock Start-Sleep {}
            Mock Test-PlinkInvocation {
                $script:hostnameAttempts++
                if ($script:hostnameAttempts -eq 1) {
                    $global:LASTEXITCODE = 1
                    'FATAL ERROR: Network error: Software caused connection abort'
                }
                else {
                    $global:LASTEXITCODE = 0
                    'kubenode'
                }
            }
            try {
                $result = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'hostname' -RemoteUser 'remote@172.18.12.22' -RemoteUserPwd 'fixture' -Retries 3 -Timeout 3 -NoLog
                $result.Success | Should -BeTrue
                $result.Output | Should -Be 'kubenode'
                Should -Invoke Test-PlinkInvocation -Times 2 -Exactly
                Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 3 }
            }
            finally {
                $script:plinkExe = $originalPlink
            }
        }
    }

    It 'stops after four failed attempts and returns the failure' {
        InModuleScope $moduleName {
            function Test-PlinkInvocation {}
            $originalPlink = $script:plinkExe
            $script:plinkExe = 'Test-PlinkInvocation'
            Mock Write-Log { if ($Raw) { $Messages } }
            Mock Start-Sleep {}
            Mock Test-PlinkInvocation {
                $global:LASTEXITCODE = 1
                'connection abort'
            }
            try {
                $result = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'hostname' -RemoteUser 'remote@172.18.12.22' -RemoteUserPwd 'fixture' -Retries 3 -Timeout 3 -NoLog
                $result.Success | Should -BeFalse
                $result.Output | Should -Be 'connection abort'
                Should -Invoke Test-PlinkInvocation -Times 4 -Exactly
                Should -Invoke Start-Sleep -Times 3 -Exactly
            }
            finally {
                $script:plinkExe = $originalPlink
            }
        }
    }
}

Describe 'Invoke-SSHOnce' -Tag 'unit', 'ci', 'vm' {
    Context 'Socket warning filtering' {
        It 'filters socket warning and sets HadSocketWarning flag' {
            InModuleScope $moduleName {
                # Arrange: mock ssh.exe to return socket warning + real output
                $script:sshExe = 'ssh.exe'
                Mock -CommandName 'ssh.exe' -MockWith {
                    'command output'
                    Write-Error 'close - IO is still pending on closed socket. read:1, write:0, io:0000027287D7CD60'
                    $global:LASTEXITCODE = 1
                }

                # Act
                $result = Invoke-SSHOnce -SshExePath 'ssh.exe' -Params @('-n', 'user@host', 'echo test')

                # Assert
                $result.HadSocketWarning | Should -BeTrue
                $result.OutputLines | Should -Contain 'command output'
                $result.OutputLines | Should -Not -Contain 'close - IO is still pending on closed socket. read:1, write:0, io:0000027287D7CD60'
            }
        }

        It 'returns no socket warning flag for clean output' {
            InModuleScope $moduleName {
                Mock -CommandName 'ssh.exe' -MockWith {
                    'clean output'
                    $global:LASTEXITCODE = 0
                }

                $result = Invoke-SSHOnce -SshExePath 'ssh.exe' -Params @('-n', 'user@host', 'echo test')

                $result.HadSocketWarning | Should -BeFalse
                $result.OutputLines | Should -Contain 'clean output'
                $result.ExitCode | Should -Be 0
            }
        }

        It 'filters Warning: Permanently added messages' {
            InModuleScope $moduleName {
                Mock -CommandName 'ssh.exe' -MockWith {
                    Write-Error "Warning: Permanently added '172.19.1.100' (ED25519) to the list of known hosts."
                    'real output'
                    $global:LASTEXITCODE = 0
                }

                $result = Invoke-SSHOnce -SshExePath 'ssh.exe' -Params @('-n', 'user@host', 'echo test')

                $result.OutputLines | Should -Contain 'real output'
                $result.OutputLines.Count | Should -Be 1
            }
        }
    }
}

Describe 'Invoke-SSHWithKey socket warning retry' -Tag 'unit', 'ci', 'vm' {
    BeforeEach {
        Mock Set-SshPrivateKeyPermissions {} -ModuleName $moduleName
    }

    Context 'Socket warning with output' {
        It 'treats as success and returns clean output' {
            InModuleScope $moduleName {
                Mock Invoke-SSHOnce -MockWith {
                    [pscustomobject]@{
                        OutputLines      = @('passwd: password changed.')
                        ExitCode         = 1
                        HadSocketWarning = $true
                    }
                }

                $output = Invoke-SSHWithKey -Command 'sudo passwd -d remote' -IpAddress '172.19.1.100'

                $LASTEXITCODE | Should -Be 0
                $output | Should -Be 'passwd: password changed.'
                Should -Invoke Invoke-SSHOnce -Times 1 -Exactly
            }
        }
    }

    Context 'Socket warning with no output and exit code 255' {
        It 'treats as success without retry' {
            InModuleScope $moduleName {
                Mock Invoke-SSHOnce -MockWith {
                    [pscustomobject]@{
                        OutputLines      = @()
                        ExitCode         = 255
                        HadSocketWarning = $true
                    }
                }

                $output = Invoke-SSHWithKey -Command 'sudo touch /tmp/test' -IpAddress '172.19.1.100'

                $LASTEXITCODE | Should -Be 0
                $output | Should -Be ''
                Should -Invoke Invoke-SSHOnce -Times 1 -Exactly
            }
        }
    }

    Context 'Socket warning with no output and small non-zero exit code' {
        It 'retries and succeeds when retry returns exit code 0' {
            InModuleScope $moduleName {
                $script:callCount = 0
                Mock Invoke-SSHOnce -MockWith {
                    $script:callCount++
                    if ($script:callCount -eq 1) {
                        [pscustomobject]@{
                            OutputLines      = @()
                            ExitCode         = 1
                            HadSocketWarning = $true
                        }
                    } else {
                        [pscustomobject]@{
                            OutputLines      = @()
                            ExitCode         = 0
                            HadSocketWarning = $false
                        }
                    }
                }
                Mock Start-Sleep {}

                $output = Invoke-SSHWithKey -Command 'sudo touch /tmp/test' -IpAddress '172.19.1.100'

                $LASTEXITCODE | Should -Be 0
                Should -Invoke Invoke-SSHOnce -Times 2 -Exactly
                Should -Invoke Start-Sleep -Times 1 -Exactly
            }
        }

        It 'retries and succeeds when retry also has socket warning' {
            InModuleScope $moduleName {
                Mock Invoke-SSHOnce -MockWith {
                    [pscustomobject]@{
                        OutputLines      = @()
                        ExitCode         = 1
                        HadSocketWarning = $true
                    }
                }
                Mock Start-Sleep {}

                $output = Invoke-SSHWithKey -Command 'sudo systemctl reload ssh' -IpAddress '172.19.1.100'

                $LASTEXITCODE | Should -Be 0
                Should -Invoke Invoke-SSHOnce -Times 2 -Exactly
            }
        }

        It 'retries and preserves error when retry fails without socket warning' {
            InModuleScope $moduleName {
                $script:callCount = 0
                Mock Invoke-SSHOnce -MockWith {
                    $script:callCount++
                    if ($script:callCount -eq 1) {
                        [pscustomobject]@{
                            OutputLines      = @()
                            ExitCode         = 1
                            HadSocketWarning = $true
                        }
                    } else {
                        [pscustomobject]@{
                            OutputLines      = @()
                            ExitCode         = 1
                            HadSocketWarning = $false
                        }
                    }
                }
                Mock Start-Sleep {}

                $output = Invoke-SSHWithKey -Command 'bad-command' -IpAddress '172.19.1.100'

                $LASTEXITCODE | Should -Be 1
                Should -Invoke Invoke-SSHOnce -Times 2 -Exactly
            }
        }
    }

    Context 'No socket warning' {
        It 'preserves non-zero exit code without retry' {
            InModuleScope $moduleName {
                Mock Invoke-SSHOnce -MockWith {
                    [pscustomobject]@{
                        OutputLines      = @()
                        ExitCode         = 127
                        HadSocketWarning = $false
                    }
                }

                $output = Invoke-SSHWithKey -Command 'nonexistent-command' -IpAddress '172.19.1.100'

                $LASTEXITCODE | Should -Be 127
                Should -Invoke Invoke-SSHOnce -Times 1 -Exactly
            }
        }

        It 'preserves exit code 0 and returns output' {
            InModuleScope $moduleName {
                Mock Invoke-SSHOnce -MockWith {
                    [pscustomobject]@{
                        OutputLines      = @('hello world')
                        ExitCode         = 0
                        HadSocketWarning = $false
                    }
                }

                $output = Invoke-SSHWithKey -Command 'echo hello world' -IpAddress '172.19.1.100'

                $LASTEXITCODE | Should -Be 0
                $output | Should -Be 'hello world'
                Should -Invoke Invoke-SSHOnce -Times 1 -Exactly
            }
        }
    }
}

Describe 'Invoke-ExeWithAsciiEncoding' -Tag 'unit','ci','vm'  {
    Context 'PipeInput provided' {
        It 'returns piped text when executing system more.com' -Skip:(
        -not (Test-Path "$env:SystemRoot\System32\more.com")
        ){
            InModuleScope $moduleName {
                $exe = "$env:SystemRoot\System32\more.com"
                $args = @('')
                $text = 'yes'
                $originalIn = [Console]::InputEncoding.WebName
                $originalOut = [Console]::OutputEncoding.WebName
                $result = Invoke-ExeWithAsciiEncoding -ExePath $exe -Arguments $args -PipeInput $text
                ($result -join '').Trim() | Should -Be $text
                [Console]::InputEncoding.WebName | Should -Be $originalIn
                [Console]::OutputEncoding.WebName | Should -Be $originalOut
            }
        }
    }
    Context 'No PipeInput, arguments echo output'  {
        It 'captures output' -Skip:(
        -not (Test-Path "$env:SystemRoot\System32\cmd.exe")
        ){
            InModuleScope $moduleName {
                $exe = "$env:SystemRoot\System32\cmd.exe"
                $args = @('/c', 'echo', 'log-line')
                $result = Invoke-ExeWithAsciiEncoding -ExePath $exe -Arguments $args
                ($result -join '').Trim() | Should -Be 'log-line'
            }
        }
    }
}

Describe 'Control-plane artifact disk-size precheck' -Tag 'unit', 'ci', 'vm' {
    Context 'Assert-ControlPlaneArtifactDiskSizeCompatibility' {
        It 'skips package guard in force-online mode' {
            InModuleScope $moduleName {
                Mock Get-ControlPlaneVMBaseImagePath { 'C:\pkg\Kubemaster-Base.vhdx' }
                Mock Test-Path { $true }
                Mock Get-VHD { [pscustomobject]@{ Size = 60GB } }

                { Assert-ControlPlaneArtifactDiskSizeCompatibility -MasterDiskSize 50GB -ForceOnlineInstallation } | Should -Not -Throw

                Should -Invoke Get-ControlPlaneVMBaseImagePath -Times 0 -Exactly
                Should -Invoke Test-Path -Times 0 -Exactly
                Should -Invoke Get-VHD -Times 0 -Exactly
            }
        }

        It 'skips package guard when packaged control-plane artifact is missing' {
            InModuleScope $moduleName {
                Mock Get-ControlPlaneVMBaseImagePath { 'C:\pkg\Kubemaster-Base.vhdx' }
                Mock Test-Path { $false }

                { Assert-ControlPlaneArtifactDiskSizeCompatibility -MasterDiskSize 60GB } | Should -Not -Throw

                Should -Invoke Get-ControlPlaneVMBaseImagePath -Times 1 -Exactly
                Should -Invoke Test-Path -Times 1 -Exactly
            }
        }

        It 'fails when requested disk size is smaller than packaged provisioned size' {
            InModuleScope $moduleName {
                Mock Get-ControlPlaneVMBaseImagePath { 'C:\pkg\Kubemaster-Base.vhdx' }
                Mock Test-Path { $true }
                Mock Get-VHD { [pscustomobject]@{ Size = 60GB } }

                { Assert-ControlPlaneArtifactDiskSizeCompatibility -MasterDiskSize 50GB } | Should -Throw '*Precheck failed*smaller than packaged*'
            }
        }

        It 'fails with prereq contract when packaged VHDX cannot be read' {
            InModuleScope $moduleName {
                Mock Get-ControlPlaneVMBaseImagePath { 'C:\pkg\Kubemaster-Base.vhdx' }
                Mock Test-Path { $true }
                Mock Get-VHD { throw 'Hyper-V service unavailable' }

                { Assert-ControlPlaneArtifactDiskSizeCompatibility -MasterDiskSize 60GB } | Should -Throw '*Precheck failed*could not read packaged control-plane VHDX*'
            }
        }

        It 'passes when requested disk size equals packaged provisioned size' {
            InModuleScope $moduleName {
                Mock Get-ControlPlaneVMBaseImagePath { 'C:\pkg\Kubemaster-Base.vhdx' }
                Mock Test-Path { $true }
                Mock Get-VHD { [pscustomobject]@{ Size = 60GB } }

                { Assert-ControlPlaneArtifactDiskSizeCompatibility -MasterDiskSize 60GB } | Should -Not -Throw
            }
        }

        It 'passes when requested disk size is greater than packaged provisioned size' {
            InModuleScope $moduleName {
                Mock Get-ControlPlaneVMBaseImagePath { 'C:\pkg\Kubemaster-Base.vhdx' }
                Mock Test-Path { $true }
                Mock Get-VHD { [pscustomobject]@{ Size = 60GB } }

                { Assert-ControlPlaneArtifactDiskSizeCompatibility -MasterDiskSize 80GB } | Should -Not -Throw
            }
        }

        It 'applies the same behavior in WSL mode' {
            InModuleScope $moduleName {
                Mock Get-ControlPlaneVMBaseImagePath { 'C:\pkg\Kubemaster-Base.vhdx' }
                Mock Test-Path { $true }
                Mock Get-VHD { [pscustomobject]@{ Size = 60GB } }

                { Assert-ControlPlaneArtifactDiskSizeCompatibility -MasterDiskSize 50GB -WSL } | Should -Throw '*Precheck failed*smaller than packaged*'
            }
        }
    }

    Context 'Test-ControlPlanePrerequisites integration' {
        It 'passes WSL and force-online context into shared artifact guard' {
            InModuleScope $moduleName {
                Mock Get-MinimalProvisioningBaseMemorySize { 4GB }
                Mock Get-MinimalProvisioningBaseImageDiskSize { 20GB }
                Mock Assert-ControlPlaneArtifactDiskSizeCompatibility {}
                Mock Get-VM { @() }
                Mock Test-ExistingExternalSwitch {}

                { Test-ControlPlanePrerequisites -MasterVMProcessorCount 6 -MasterVMMemory 8GB -MasterDiskSize 60GB -WSL -ForceOnlineInstallation } | Should -Not -Throw

                Should -Invoke Assert-ControlPlaneArtifactDiskSizeCompatibility -Times 1 -Exactly -ParameterFilter {
                    $MasterDiskSize -eq 60GB -and $WSL -eq $true -and $ForceOnlineInstallation -eq $true
                }
            }
        }
    }
}

Describe 'SSH private-key permissions' -Tag 'unit', 'ci', 'vm' {
    BeforeEach {
        Mock Write-Log {} -ModuleName $moduleName
        Mock Get-Acl {
            $acl = [System.Security.AccessControl.FileSecurity]::new()
            $acl.SetSecurityDescriptorSddlForm('O:SYD:(A;;FA;;;WD)')
            return $acl
        } -ModuleName $moduleName
        Mock Set-Acl {} -ModuleName $moduleName
    }

    It 'replaces broad access with a protected administrator-owned ACL using well-known SIDs' {
        InModuleScope $moduleName {
            Set-SshPrivateKeyPermissions -Path 'C:\key with spaces\id_rsa'
            Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter {
                $LiteralPath -eq 'C:\key with spaces\id_rsa' -and
                $AclObject.AreAccessRulesProtected -and
                $AclObject.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544' -and
                $AclObject.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]).Count -eq 2 -and
                $AclObject.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]'Access, Owner') -eq
                'O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)'
            }
        }
    }

    It 'does not rewrite an already secured key with descriptor <Descriptor>' -TestCases @(
        @{ Descriptor = 'O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)' }
        @{ Descriptor = 'O:BAD:PAI(A;;FA;;;SY)(A;;FA;;;BA)' }
    ) {
        param($Descriptor)
        InModuleScope $moduleName -Parameters @{ Descriptor = $Descriptor } {
            Mock Get-Acl {
                $acl = [System.Security.AccessControl.FileSecurity]::new()
                $acl.SetSecurityDescriptorSddlForm($Descriptor)
                return $acl
            }
            Set-SshPrivateKeyPermissions -Path 'C:\id_rsa'
            Should -Invoke Set-Acl -Times 0 -Exactly
        }
    }

    It 'reports an unreadable or missing key explicitly' {
        InModuleScope $moduleName {
            Mock Get-Acl { throw 'Key not found' }
            { Set-SshPrivateKeyPermissions -Path 'C:\id_rsa' } | Should -Throw '*Cannot secure private key*Key not found*'
            Should -Invoke Set-Acl -Times 0 -Exactly
        }
    }

    It 'does not swallow an ACL write failure' {
        InModuleScope $moduleName {
            Mock Set-Acl { throw 'Access denied' }
            { Set-SshPrivateKeyPermissions -Path 'C:\id_rsa' } | Should -Throw '*Cannot secure private key*Access denied*'
        }
    }
}

Describe 'SSH authentication failure handling' -Tag 'unit', 'ci', 'vm' {
    BeforeEach {
        Mock Set-SshPrivateKeyPermissions {} -ModuleName $moduleName
        Mock Write-Log {} -ModuleName $moduleName
        Mock Start-Sleep {} -ModuleName $moduleName
    }

    It 'secures the key before executing SSH' {
        InModuleScope $moduleName {
            Mock Invoke-SSHOnce {
                Should -Invoke Set-SshPrivateKeyPermissions -Times 1 -Exactly -ParameterFilter { $Path -eq $key }
                [pscustomobject]@{ OutputLines = @('ok'); ExitCode = 0; HadSocketWarning = $false }
            }
            Invoke-SSHWithKey -Command 'true' | Should -Be 'ok'
        }
    }

    It 'preserves an authentication failure even when accompanied by a socket warning' {
        InModuleScope $moduleName {
            Mock Invoke-SSHOnce {
                [pscustomobject]@{
                    OutputLines = @('WARNING: UNPROTECTED PRIVATE KEY FILE!', 'Permission denied (publickey).')
                    ExitCode = 255
                    HadSocketWarning = $true
                }
            }
            Invoke-SSHWithKey -Command 'true' | Should -Not -BeNullOrEmpty
            $LASTEXITCODE | Should -Be 255
            Should -Invoke Invoke-SSHOnce -Times 1 -Exactly
        }
    }

    It 'never executes SSH if securing the key failed' {
        InModuleScope $moduleName {
            Mock Set-SshPrivateKeyPermissions { throw 'Cannot secure private key' }
            Mock Invoke-SSHOnce {}
            { Invoke-SSHWithKey -Command 'true' } | Should -Throw '*Cannot secure private key*'
            Should -Invoke Invoke-SSHOnce -Times 0 -Exactly
        }
    }

    It 'returns a failed result with the local failure diagnostic rather than stale success' {
        InModuleScope $moduleName {
            Mock Invoke-SSHWithKey {
                $global:LASTEXITCODE = 0
                throw 'Cannot secure private key'
            }
            $result = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'true' -IpAddress '172.19.1.100' -IgnoreErrors
            $result.Success | Should -BeFalse
            $result.ExitCode | Should -BeNullOrEmpty
            $result.Output | Should -Be 'Cannot secure private key'
        }
    }

    It 'does not retry or run remote repairs for a local key-permission failure' {
        InModuleScope $moduleName {
            Mock Invoke-SSHWithKey { throw "[SSH] Cannot secure private key 'C:\id_rsa': Access denied" }
            $result = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'true' -IpAddress '172.19.1.100' -Retries 3 -RepairCmd 'repair'
            $result.Success | Should -BeFalse
            Should -Invoke Invoke-SSHWithKey -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    It 'does not classify remote filesystem permission errors as SSH authentication errors' {
        InModuleScope $moduleName {
            Test-SshAuthenticationFailure -Output "rm: cannot remove '/tmp/file': Permission denied" | Should -BeFalse
            Test-SshAuthenticationFailure -Output 'remote@172.19.1.100: Permission denied (publickey).' | Should -BeTrue
        }
    }

    It 'preserves authentication rejection on a socket-warning retry' {
        InModuleScope $moduleName {
            $script:sshAttempts = 0
            Mock Invoke-SSHOnce {
                $script:sshAttempts++
                if ($script:sshAttempts -eq 1) {
                    [pscustomobject]@{ OutputLines = @(); ExitCode = 1; HadSocketWarning = $true }
                }
                else {
                    [pscustomobject]@{ OutputLines = @('Permission denied (publickey).'); ExitCode = 255; HadSocketWarning = $true }
                }
            }
            Invoke-SSHWithKey -Command 'true' | Should -Be 'Permission denied (publickey).'
            $LASTEXITCODE | Should -Be 255
            Should -Invoke Invoke-SSHOnce -Times 2 -Exactly
        }
    }

    It 'returns the SSH exit code and does not retry authentication errors or run repair commands' {
        InModuleScope $moduleName {
            Mock Invoke-SSHWithKey {
                $global:LASTEXITCODE = 255
                'Permission denied (publickey).'
            }
            $result = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'true' -IpAddress '172.19.1.100' -Retries 3 -RepairCmd 'repair'
            $result.Success | Should -BeFalse
            $result.ExitCode | Should -Be 255
            Should -Invoke Invoke-SSHWithKey -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    It 'secures the key for SCP and preserves authentication failure without retrying' {
        InModuleScope $moduleName {
            Mock scp.exe {
                Should -Invoke Set-SshPrivateKeyPermissions -Times 1 -Exactly
                Write-Error 'Bad permissions'
                Write-Error 'close - IO is still pending on closed socket'
                $global:LASTEXITCODE = 255
            }
            Invoke-SCPWithKey -Source 'C:\file' -Target 'remote@host:/tmp/file' | Should -Be 'Bad permissions'
            $LASTEXITCODE | Should -Be 255
            Should -Invoke scp.exe -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    It 'fails the connection wait immediately on key rejection rather than network recovery' {
        InModuleScope $moduleName {
            Mock ssh.exe {
                Write-Error 'WARNING: UNPROTECTED PRIVATE KEY FILE!'
                $global:LASTEXITCODE = 255
            }
            { Wait-ForSshPossible -User 'remote@host' -SshKey 'C:\id_rsa' -SshTestCommand 'true' -ExpectedSshTestCommandResult 'ok' } |
                Should -Throw '*Authentication or private-key failure*'
            Should -Invoke Set-SshPrivateKeyPermissions -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\id_rsa' }
            Should -Invoke ssh.exe -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    It 'allows a successful key-based connection wait' {
        InModuleScope $moduleName {
            Mock ssh.exe {
                $global:LASTEXITCODE = 0
                '/bin/curl'
            }
            { Wait-ForSshPossible -User 'remote@host' -SshKey 'C:\id_rsa' -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl' } |
                Should -Not -Throw
            Should -Invoke ssh.exe -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    It 'does not accept matching connection-wait output from a failed SSH command' {
        InModuleScope $moduleName {
            $script:waitAttempts = 0
            Mock ssh.exe {
                $script:waitAttempts++
                $global:LASTEXITCODE = if ($script:waitAttempts -eq 1) { 1 } else { 0 }
                '/bin/curl'
            }
            Wait-ForSshPossible -User 'remote@host' -SshKey 'C:\id_rsa' -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl'
            Should -Invoke ssh.exe -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }
    }

}

Describe 'Control-plane SSH routing' -Tag 'unit', 'ci', 'vm' {
    BeforeAll {
        $startupPath = Join-Path $PSScriptRoot '..\setup\control-plane-node.module.psm1'
        $startupAst = [System.Management.Automation.Language.Parser]::ParseFile($startupPath, [ref]$null, [ref]$null)
        $startupFunction = $startupAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Start-ControlPlaneNodeOnNewVM'
            }, $true)
        $statements = @($startupFunction.Body.EndBlock.Statements)
        $assignment = $startupFunction.Find({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$sshWaitParams'
            }, $true)
        $assignmentIndex = [array]::IndexOf($statements, $assignment)
        if ($assignmentIndex -lt 0) {
            throw 'Cannot find startup SSH routing parameters.'
        }
        $startupSshWait = ($statements[$assignmentIndex..($assignmentIndex + 2)] |
                ForEach-Object { $_.Extent.Text }) -join "`n"
    }

    BeforeEach {
        InModuleScope $moduleName {
            $script:localSshAddresses = @([pscustomobject]@{
                    IPAddress = '172.19.1.1'; InterfaceIndex = 39; AddressState = 'Preferred'
                })
            $script:selectedSshRoute = @(
                [pscustomobject]@{ IPAddress = '172.19.1.1'; InterfaceIndex = 39 }
                [pscustomobject]@{
                    DestinationPrefix = '172.19.1.0/24'; NextHop = '0.0.0.0'
                    InterfaceIndex = 39; InterfaceAlias = 'vEthernet (KubeSwitch)'
                }
            )
            $script:lastSshArguments = @()
            Mock Get-NetIPAddress { $script:localSshAddresses }
            Mock Find-NetRoute { $script:selectedSshRoute }
            Mock Set-SshPrivateKeyPermissions {}
            Mock Write-Log {}
            Mock Start-Sleep {}
            Mock Get-Random { 0 }
            Mock Get-DurationInSeconds { 0 }
            Mock ssh.exe {
                $script:lastSshArguments = @($args)
                $global:LASTEXITCODE = 0
                '/bin/curl'
            }
        }
    }

    It 'accepts the preferred switch source and selected on-link route' {
        InModuleScope $moduleName {
            Test-SshRouteViaLocalAddress -RemoteIPAddress '172.19.1.100' -LocalIPAddress '172.19.1.1' |
                Should -BeTrue
            Should -Invoke Find-NetRoute -Times 1 -Exactly -ParameterFilter {
                $RemoteIPAddress -eq '172.19.1.100'
            }
        }
    }

    It 'rejects <Case>' -TestCases @(
        @{ Case = 'a missing local address' }
        @{ Case = 'an ambiguous local address' }
        @{ Case = 'a tentative local address' }
        @{ Case = 'a duplicate local address' }
        @{ Case = 'an Ethernet default route' }
        @{ Case = 'a different source interface' }
        @{ Case = 'a different route interface' }
        @{ Case = 'a gateway on the switch interface' }
        @{ Case = 'an on-link default route' }
        @{ Case = 'a missing route' }
    ) {
        param($Case)
        InModuleScope $moduleName -Parameters @{ Case = $Case } {
            switch ($Case) {
                'a missing local address' { $script:localSshAddresses = @() }
                'an ambiguous local address' { $script:localSshAddresses += $script:localSshAddresses[0] }
                'a tentative local address' { $script:localSshAddresses[0].AddressState = 'Tentative' }
                'a duplicate local address' { $script:localSshAddresses[0].AddressState = 'Duplicate' }
                'an Ethernet default route' {
                    $script:selectedSshRoute[0].IPAddress = '172.29.29.130'
                    $script:selectedSshRoute[0].InterfaceIndex = 10
                    $script:selectedSshRoute[1].DestinationPrefix = '0.0.0.0/0'
                    $script:selectedSshRoute[1].NextHop = '172.29.29.1'
                    $script:selectedSshRoute[1].InterfaceIndex = 10
                    $script:selectedSshRoute[1].InterfaceAlias = 'Ethernet'
                }
                'a different source interface' { $script:selectedSshRoute[0].InterfaceIndex = 10 }
                'a different route interface' { $script:selectedSshRoute[1].InterfaceIndex = 10 }
                'a gateway on the switch interface' { $script:selectedSshRoute[1].NextHop = '172.19.1.254' }
                'an on-link default route' { $script:selectedSshRoute[1].DestinationPrefix = '0.0.0.0/0' }
                'a missing route' { $script:selectedSshRoute = @() }
            }

            Test-SshRouteViaLocalAddress -RemoteIPAddress '172.19.1.100' -LocalIPAddress '172.19.1.1' |
                Should -BeFalse
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Messages -like '*SSH-Routing*' }
        }
    }

    It 'logs route-query errors rather than attempting an unguarded connection' {
        InModuleScope $moduleName {
            Mock Find-NetRoute { Write-Error 'Route lookup unavailable' }
            Test-SshRouteViaLocalAddress -RemoteIPAddress '172.19.1.100' -LocalIPAddress '172.19.1.1' |
                Should -BeFalse
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
                $Messages -like '*Route lookup unavailable*'
            }
        }
    }

    It 'surfaces unexpected address-query failures' {
        InModuleScope $moduleName {
            Mock Get-NetIPAddress { throw 'Address query denied' }
            { Test-SshRouteViaLocalAddress -RemoteIPAddress '172.19.1.100' -LocalIPAddress '172.19.1.1' } |
                Should -Throw '*Address query denied*'
            Should -Invoke Find-NetRoute -Times 0 -Exactly
        }
    }

    It 'waits through Ethernet fallback and requires the trusted key without using unsupported source binding' {
        InModuleScope $moduleName {
            $script:routeChecks = 0
            Mock Test-SshRouteViaLocalAddress {
                $script:routeChecks++
                return $script:routeChecks -gt 3
            }
            Wait-ForSshPossible -User 'remote@172.19.1.100' -SshKey 'C:\key with spaces\id_rsa' `
                -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl' -LocalIPAddress '172.19.1.1'

            Should -Invoke Test-SshRouteViaLocalAddress -Times 4 -Exactly -ParameterFilter {
                $RemoteIPAddress -eq '172.19.1.100' -and $LocalIPAddress -eq '172.19.1.1'
            }
            Should -Invoke ssh.exe -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 3 -Exactly
            $script:lastSshArguments | Should -Not -Contain '-b'
            $script:lastSshArguments | Should -Not -Contain '-B'
            $script:lastSshArguments | Should -Contain 'StrictHostKeyChecking=yes'
            $script:lastSshArguments | Should -Not -Contain 'StrictHostKeyChecking=no'
            $script:lastSshArguments | Should -Contain 'C:\key with spaces\id_rsa'
            $script:lastSshArguments | Should -Contain 'which curl'
            $script:lastSshArguments | Should -Contain '-n'
        }
    }

    It 'rechecks routing after an SSH timeout and skips attempts while the route falls back again' {
        InModuleScope $moduleName {
            $script:routeChecks = 0
            Mock Test-SshRouteViaLocalAddress {
                $script:routeChecks++
                return $script:routeChecks -eq 1 -or $script:routeChecks -eq 4
            }
            Mock ssh.exe {
                if ($script:routeChecks -eq 1) {
                    $global:LASTEXITCODE = 255
                    'ssh: connect to host 172.19.1.100 port 22: Connection timed out'
                }
                else {
                    $global:LASTEXITCODE = 0
                    '/bin/curl'
                }
            }
            Wait-ForSshPossible -User 'remote@172.19.1.100' -SshKey 'C:\id_rsa' `
                -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl' -LocalIPAddress '172.19.1.1'

            Should -Invoke Test-SshRouteViaLocalAddress -Times 4 -Exactly
            Should -Invoke ssh.exe -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 3 -Exactly
        }
    }

    It 'times out explicitly without SSH or VM recovery when the switch route never becomes usable' {
        InModuleScope $moduleName {
            Mock Test-SshRouteViaLocalAddress { $false }
            Mock Stop-VM {}
            Mock Disconnect-VMNetworkAdapter {}
            { Wait-ForSshPossible -User 'remote@172.19.1.100' -SshKey 'C:\id_rsa' `
                    -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl' -LocalIPAddress '172.19.1.1' } |
                Should -Throw '*Unable to SSH login into VM after 80 attempts*'
            Should -Invoke Test-SshRouteViaLocalAddress -Times 80 -Exactly
            Should -Invoke ssh.exe -Times 0 -Exactly
            Should -Invoke Start-Sleep -Times 79 -Exactly
            Should -Invoke Stop-VM -Times 0 -Exactly
            Should -Invoke Disconnect-VMNetworkAdapter -Times 0 -Exactly
        }
    }

    It 'retries a rejected host key only when the route changed during the SSH attempt' {
        InModuleScope $moduleName {
            $script:routeChecks = 0
            Mock Test-SshRouteViaLocalAddress {
                $script:routeChecks++
                return $script:routeChecks -ne 2
            }
            $script:sshAttempts = 0
            Mock ssh.exe {
                $script:sshAttempts++
                if ($script:sshAttempts -eq 1) {
                    $global:LASTEXITCODE = 255
                    'Host key verification failed.'
                }
                else {
                    $global:LASTEXITCODE = 0
                    '/bin/curl'
                }
            }
            Wait-ForSshPossible -User 'remote@172.19.1.100' -SshKey 'C:\id_rsa' `
                -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl' -LocalIPAddress '172.19.1.1'

            Should -Invoke Test-SshRouteViaLocalAddress -Times 3 -Exactly
            Should -Invoke ssh.exe -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
                $Console -and $Messages -like '*route changed*Host key verification failed*'
            }
        }
    }

    It 'bounds retries when the route keeps changing during host-key verification' {
        InModuleScope $moduleName {
            $script:routeChecks = 0
            Mock Test-SshRouteViaLocalAddress {
                $script:routeChecks++
                return $script:routeChecks % 2 -eq 1
            }
            Mock ssh.exe {
                $global:LASTEXITCODE = 255
                'Host key verification failed.'
            }
            { Wait-ForSshPossible -User 'remote@172.19.1.100' -SshKey 'C:\id_rsa' `
                    -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl' -LocalIPAddress '172.19.1.1' } |
                Should -Throw '*Unable to SSH login into VM after 80 attempts*'
            Should -Invoke ssh.exe -Times 80 -Exactly
            Should -Invoke Test-SshRouteViaLocalAddress -Times 160 -Exactly
            Should -Invoke Start-Sleep -Times 79 -Exactly
        }
    }

    It 'does not reclassify a private-key or authentication rejection when routing changes' -TestCases @(
        @{ Failure = 'remote@172.19.1.100: Permission denied (publickey).' }
        @{ Failure = 'WARNING: UNPROTECTED PRIVATE KEY FILE!' }
    ) {
        param($Failure)
        InModuleScope $moduleName -Parameters @{ Failure = $Failure } {
            $script:routeChecks = 0
            Mock Test-SshRouteViaLocalAddress {
                $script:routeChecks++
                return $script:routeChecks -eq 1
            }
            Mock ssh.exe {
                $global:LASTEXITCODE = 255
                $Failure
            }
            { Wait-ForSshPossible -User 'remote@172.19.1.100' -SshKey 'C:\id_rsa' `
                    -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl' -LocalIPAddress '172.19.1.1' } |
                Should -Throw '*Authentication or private-key failure*'
            Should -Invoke Test-SshRouteViaLocalAddress -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    It 'still fails immediately for <Failure> on the intended route' -TestCases @(
        @{ Failure = 'remote@172.19.1.100: Permission denied (publickey).' }
        @{ Failure = 'WARNING: UNPROTECTED PRIVATE KEY FILE!' }
    ) {
        param($Failure)
        InModuleScope $moduleName -Parameters @{ Failure = $Failure } {
            Mock ssh.exe {
                $global:LASTEXITCODE = 255
                $Failure
            }
            { Wait-ForSshPossible -User 'remote@172.19.1.100' -SshKey 'C:\id_rsa' `
                    -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl' -LocalIPAddress '172.19.1.1' } |
                Should -Throw '*Authentication or private-key failure*'
            Should -Invoke ssh.exe -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    It 'reports safe trust remediation for <Case> without retrying on the intended route' -TestCases @(
        @{
            Case = 'a missing known host key'
            Failure = 'No ED25519 host key is known for 172.19.1.100 and you have requested strict checking.' + "`nHost key verification failed."
        }
        @{
            Case = 'a changed known host key'
            Failure = 'WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!' + "`nHost key verification failed."
        }
    ) {
        param($Failure)
        InModuleScope $moduleName -Parameters @{ Failure = $Failure } {
            Mock ssh.exe {
                $global:LASTEXITCODE = 255
                $Failure
            }
            { Wait-ForSshPossible -User 'remote@172.19.1.100' -SshKey 'C:\id_rsa' `
                    -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl' -LocalIPAddress '172.19.1.1' } |
                Should -Throw '*Control-plane host-key verification failed*known_hosts*Verify the VM host-key fingerprint*SSH diagnostic:*'
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
                $Console -and $Messages -like "*profile '$env:USERPROFILE'*" -and
                $Messages -like '*another trusted channel*' -and
                $Messages -like '*Do not disable host-key checking*'
            }
            Should -Invoke ssh.exe -Times 1 -Exactly
            Should -Invoke Find-NetRoute -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    It 'preserves existing unguarded behavior with Nested=<Nested>' -TestCases @(
        @{ Nested = $false }
        @{ Nested = $true }
    ) {
        param($Nested)
        InModuleScope $moduleName -Parameters @{ Nested = $Nested } {
            Wait-ForSshPossible -User 'remote@host' -SshKey 'C:\id_rsa' -Nested:$Nested `
                -SshTestCommand 'which curl' -ExpectedSshTestCommandResult '/bin/curl'
            Should -Invoke Find-NetRoute -Times 0 -Exactly
            Should -Invoke Get-NetIPAddress -Times 0 -Exactly
            $script:lastSshArguments | Should -Not -Contain '-b'
            $script:lastSshArguments | Should -Contain 'StrictHostKeyChecking=no'
            ($script:lastSshArguments -contains '-n') | Should -Be (-not $Nested)
        }
    }

    It 'rejects a local binding for the password-based path explicitly' {
        InModuleScope $moduleName {
            { Wait-ForSshPossible -User 'remote@host' -UserPwd 'fixture' -LocalIPAddress '172.19.1.1' `
                    -SshTestCommand 'true' -ExpectedSshTestCommandResult 'ok' } |
                Should -Throw '*only be specified for key-based SSH*'
            Should -Invoke ssh.exe -Times 0 -Exactly
        }
    }

    It 'forwards the route guard through the control-plane key wrapper' {
        InModuleScope $moduleName {
            Mock Wait-ForSshPossible {}
            Wait-ForSSHConnectionToLinuxVMViaSshKey -LocalIPAddress '172.19.1.1'
            Should -Invoke Wait-ForSshPossible -Times 1 -Exactly -ParameterFilter {
                $LocalIPAddress -eq '172.19.1.1' -and $SshKey -eq $key -and $User -eq $remoteUser
            }
        }
    }

    It 'enables the startup route guard only for Hyper-V (WSL=<Wsl>)' -TestCases @(
        @{ Wsl = $false; ExpectedLocalAddress = '172.19.1.1' }
        @{ Wsl = $true; ExpectedLocalAddress = '' }
    ) {
        param($Wsl, $ExpectedLocalAddress)
        InModuleScope $moduleName -Parameters @{
            Wsl = $Wsl; ExpectedLocalAddress = $ExpectedLocalAddress; StartupSshWait = $startupSshWait
        } {
            $WSL = $Wsl
            $windowsHostIpAddress = '172.19.1.1'
            Mock Wait-ForSSHConnectionToLinuxVMViaSshKey {}
            & ([scriptblock]::Create($StartupSshWait))
            Should -Invoke Wait-ForSSHConnectionToLinuxVMViaSshKey -Times 1 -Exactly -ParameterFilter {
                [string]$LocalIPAddress -eq $ExpectedLocalAddress
            }
        }
    }
}

Describe 'SSH key ACL integration' -Tag 'unit', 'ci', 'vm' {
    It 'persists the restricted ACL and lets Windows OpenSSH read the unchanged key' -Skip:(
        -not ([System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [System.Security.Principal.WindowsBuiltInRole]::Administrator))
    ) {
        $keyPath = Join-Path $TestDrive 'id_ed25519'
        & ssh-keygen.exe -t ed25519 -f $keyPath -N '""' -q
        $LASTEXITCODE | Should -Be 0
        $hashBefore = (Get-FileHash -LiteralPath $keyPath).Hash
        $expectedPublicKey = ((Get-Content -LiteralPath "$keyPath.pub") -split ' ')[0..1] -join ' '

        Set-SshPrivateKeyPermissions -Path $keyPath
        $acl = Get-Acl -LiteralPath $keyPath
        $acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]'Access, Owner') |
            Should -Be 'O:BAD:PAI(A;;FA;;;SY)(A;;FA;;;BA)'
        (Get-FileHash -LiteralPath $keyPath).Hash | Should -Be $hashBefore
        $publicKey = & ssh-keygen.exe -y -f $keyPath
        $LASTEXITCODE | Should -Be 0
        (($publicKey -split ' ')[0..1] -join ' ') | Should -Be $expectedPublicKey
        Mock Set-Acl {} -ModuleName $moduleName
        Set-SshPrivateKeyPermissions -Path $keyPath
        Should -Invoke Set-Acl -ModuleName $moduleName -Times 0 -Exactly
    }
}
