# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

Describe 'Wait-KubeadmJoinProcess' -Tag 'unit', 'ci', 'cluster' {
BeforeAll {
    $modulePath = "$PSScriptRoot/setupcluster.module.psm1"
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    $waitFunction = $moduleAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-KubeadmJoinProcess'
    }, $false)
    . ([scriptblock]::Create($waitFunction.Extent.Text))

    $script:kubeToolsPath = 'C:\k'
    function Write-Log { param($Message, [switch]$Console) }
    function Stop-Process { [CmdletBinding()] param($Id, [switch]$Force) }
    function Get-Service { [CmdletBinding()] param($Name) }
}

Describe 'Linux join readiness monitoring' -Tag 'unit', 'ci', 'cluster' {
    BeforeAll {
        $parseErrors = $null
        $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot\setupcluster.module.psm1", [ref]$null, [ref]$parseErrors)
        if ($parseErrors) { throw ($parseErrors | Out-String) }
        $linuxJoin = $moduleAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Join-LinuxNode'
        }, $false)
        $windowsJoin = $moduleAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Join-WindowsNode'
        }, $false)
        if ($null -eq $linuxJoin -or $null -eq $windowsJoin) { throw 'Join functions missing from module.' }
    }

    It 'does not invoke the Windows process-monitor helper during Linux join' {
        $windowsMonitorCalls = @($linuxJoin.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.Extent.Text -match '\bWait-ForNodesReady\b'
        }, $true))

        $windowsMonitorCalls | Should -BeNullOrEmpty
    }

    It 'retains remote kubeadm join followed by the node-status check' {
        $remoteJoin = @($linuxJoin.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Invoke-CmdOnVmViaSSHKey' -and
                $node.Extent.Text -match '-CmdToExecute \$joinCommand\b'
        }, $true))
        $statusChecks = @($linuxJoin.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.Extent.Text -match '\bget node \$NodeName\b'
        }, $true))

        $remoteJoin.Count | Should -Be 1
        $statusChecks.Count | Should -Be 1
        $statusChecks[0].Extent.StartLineNumber | Should -BeGreaterThan $remoteJoin[0].Extent.StartLineNumber
    }

    It 'preserves the Windows monitor with its actual local kubeadm process ID' {
        $windowsMonitor = @($windowsJoin.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Start-Job' -and
                $node.Extent.Text -match '\bWait-ForNodesReady\b'
        }, $true))

        $windowsMonitor.Count | Should -Be 1
        $windowsMonitor[0].Extent.Text | Should -Match '-ArgumentList \$controlPlaneHostName, \$joinProcess\.Id'
    }
}

    BeforeEach {
        Mock Write-Log {}
        Mock Stop-Process {}
        Mock Get-Service {}
    }

    It 'returns the process exit code when kubeadm finishes in time' {
        $process = [pscustomobject]@{
            Handle = [intptr]::Zero
            Id = 42
            ExitCode = 0
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) return $true }

        $result = Wait-KubeadmJoinProcess -Process $process -StandardOutputPath 'missing.stdout' -StandardErrorPath 'missing.stderr'

        $result | Should -Be 0
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'terminates only the timed-out kubeadm process and throws' {
        $process = [pscustomobject]@{
            Handle = [intptr]::Zero
            Id = 73
            ExitCode = -1
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            param($milliseconds)
            if ($null -eq $milliseconds) { return }
            return $false
        }

        {
            Wait-KubeadmJoinProcess -Process $process -StandardOutputPath 'missing.stdout' `
                -StandardErrorPath 'missing.stderr' -TimeoutSeconds 1
        } | Should -Throw '*timed out after 1 seconds*'

        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 73 -and $Force }
    }
}
