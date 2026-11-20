# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        "$PSScriptRoot\vmnode.module.psm1", [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ($errors | Out-String) }
    foreach ($function in $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -in @('Start-VirtualMachine', 'Stop-VirtualMachine', 'Wait-ForDesiredVMState')
    }, $true)) {
        Invoke-Expression $function.Extent.Text
    }
    function Write-Log { param($Messages, [switch]$Console, [switch]$Progress) }
}

Describe 'Hyper-V start error reporting' -Tag 'unit', 'ci', 'vm' {
    BeforeEach {
        Mock Write-Log {}
        Mock Get-VM { [pscustomobject]@{ Name = 'KubeMaster'; Id = 'vm-id'; State = 'Off' } }
        Mock Get-WmiObject { [pscustomobject]@{ FreePhysicalMemory = 8880144; FreeVirtualMemory = 11627396 } }
        Mock Start-Sleep {}
        Mock Wait-ForDesiredVMState {}
        $script:startAttempts = 0
    }

    It 'logs each original error and preserves the final exception as the cause' {
        Mock Start-VM {
            $script:startAttempts++
            throw [System.InvalidOperationException]::new("Hyper-V refused attempt $script:startAttempts")
        }
        $caught = $null
        try { Start-VirtualMachine -VmName 'KubeMaster' -Wait }
        catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -BeLike '*after 4 retries*Hyper-V refused attempt 4*'
        $caught.Exception.InnerException.Message | Should -Be 'Hyper-V refused attempt 4'
        foreach ($attempt in 1..4) {
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
                $Messages -like "*id: vm-id, attempt: $attempt/4*error id:*category:*Hyper-V refused attempt $attempt"
            }
        }
        Should -Invoke Start-VM -Times 4 -Exactly -ParameterFilter { $Name -eq 'KubeMaster' -and $ErrorAction -eq 'Stop' }
        Should -Invoke Start-Sleep -Times 4 -Exactly -ParameterFilter { $Seconds -eq 20 }
        Should -Invoke Wait-ForDesiredVMState -Times 0 -Exactly
    }

    It 'does not let failed memory diagnostics replace the Hyper-V failure' {
        Mock Start-VM { throw 'Hyper-V worker failed' }
        Mock Get-WmiObject { throw 'WMI unavailable' }
        { Start-VirtualMachine -VmName 'KubeMaster' } | Should -Throw '*Last Hyper-V error: Hyper-V worker failed*'
        Should -Invoke Start-VM -Times 4 -Exactly
        Should -Invoke Write-Log -Times 4 -Exactly -ParameterFilter { $Messages -like '*Failed to collect memory diagnostics*WMI unavailable*' }
    }

    It 'still succeeds after a transient failure and confirms the running state' {
        Mock Start-VM {
            $script:startAttempts++
            if ($script:startAttempts -eq 1) { throw 'VMMS temporarily busy' }
        }
        Start-VirtualMachine -VmName 'KubeMaster' -Wait
        Should -Invoke Start-VM -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
        Should -Invoke Wait-ForDesiredVMState -Times 1 -Exactly -ParameterFilter { $VmName -eq 'KubeMaster' -and $State -eq 'running' }
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Messages -like '*VMMS temporarily busy' }
    }

    It 'does not collect failure diagnostics or wait when startup succeeds without Wait' {
        Mock Start-VM {}
        Start-VirtualMachine -VmName 'KubeMaster'
        Should -Invoke Start-VM -Times 1 -Exactly
        Should -Invoke Get-WmiObject -Times 0 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Wait-ForDesiredVMState -Times 0 -Exactly
    }
}

Describe 'Bounded Hyper-V stop' -Tag 'unit', 'ci', 'vm' {
    BeforeEach {
        Mock Write-Log {}
        Mock Get-VM { [pscustomobject]@{ Name = 'KubeMaster'; Id = 'vm-id'; State = 'Running'; Status = 'Operating normally' } }
        $script:job = [pscustomobject]@{ State = 'Completed'; JobStateInfo = [pscustomobject]@{ Reason = $null } }
        Mock Stop-VM { $script:job }
        Mock Wait-Job { $script:job } -RemoveParameterType Job
        Mock Receive-Job {} -RemoveParameterType Job
        Mock Remove-Job {} -RemoveParameterType Job
        Mock Wait-ForDesiredVMState {}
    }

    It 'retains shutdown policy but waits for an asynchronous stop job' {
        Stop-VirtualMachine -VmName 'KubeMaster' -Wait
        Should -Invoke Stop-VM -Times 1 -Exactly -ParameterFilter { $Name -eq 'KubeMaster' -and $Force -and $AsJob -and -not $TurnOff -and $ErrorAction -eq 'Stop' }
        Should -Invoke Wait-Job -Times 1 -Exactly -ParameterFilter { $Timeout -gt 0 -and $Timeout -le 360 }
        Should -Invoke Wait-ForDesiredVMState -Times 1 -Exactly -ParameterFilter { $State -eq 'off' -and $TimeoutInSeconds -lt 360 }
        Should -Invoke Remove-Job -Times 1 -Exactly
    }

    It 'still awaits stop completion when Wait is omitted' {
        Stop-VirtualMachine -VmName 'KubeMaster'
        Should -Invoke Wait-Job -Times 1 -Exactly
        Should -Invoke Wait-ForDesiredVMState -Times 0 -Exactly
    }

    It 'uses only the remaining stop budget for Off-state confirmation' {
        Mock Wait-Job {
            [System.Threading.Thread]::Sleep(1200)
            $script:job
        } -RemoveParameterType Job
        Stop-VirtualMachine -VmName 'KubeMaster' -Wait -TimeoutInSeconds 3
        Should -Invoke Wait-ForDesiredVMState -Times 1 -Exactly -ParameterFilter { $TimeoutInSeconds -le 1 }
    }

    It 'fails a stalled job within the configured wait rather than claiming success' {
        $script:job.State = 'Running'
        Mock Wait-Job { $null } -RemoveParameterType Job
        { Stop-VirtualMachine -VmName 'KubeMaster' -Wait -TimeoutInSeconds 2 } | Should -Throw '*stop operation exceeded 2s*'
        Should -Invoke Wait-Job -Times 1 -Exactly -ParameterFilter { $Timeout -le 2 }
        Should -Invoke Wait-ForDesiredVMState -Times 0 -Exactly
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Messages -like "*stopped after*" }
        Should -Invoke Remove-Job -Times 0 -Exactly
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Messages -like '*Retaining unfinished stop job*' }
    }

    It 'propagates Hyper-V submission failures' {
        Mock Stop-VM { throw 'VMMS unavailable' }
        { Stop-VirtualMachine -VmName 'KubeMaster' } | Should -Throw '*VMMS unavailable*'
        Should -Invoke Wait-Job -Times 0 -Exactly
        Should -Invoke Remove-Job -Times 0 -Exactly
    }

    It 'propagates failed job errors before state validation' {
        Mock Receive-Job { throw 'KubeMaster failed to change state' } -RemoveParameterType Job
        { Stop-VirtualMachine -VmName 'KubeMaster' -Wait } | Should -Throw '*failed to change state*'
        Should -Invoke Wait-ForDesiredVMState -Times 0 -Exactly
        Should -Invoke Remove-Job -Times 1 -Exactly
    }

    It 'rejects a failed job even when Receive-Job reports no error' {
        $script:job.State = 'Failed'
        $script:job.JobStateInfo.Reason = 'Shutdown rejected'
        { Stop-VirtualMachine -VmName 'KubeMaster' } | Should -Throw '*Failed*Shutdown rejected*'
    }

    It 'skips an already-off VM without issuing another stop' {
        Mock Get-VM { [pscustomobject]@{ Name = 'KubeMaster'; State = 'Off' } }
        Stop-VirtualMachine -VmName 'KubeMaster' -Wait
        Should -Invoke Stop-VM -Times 0 -Exactly
    }

    It 'skips stop when VM cannot be found (count is 0)' {
        Mock Get-VM { @() }
        Stop-VirtualMachine -VmName 'KubeMaster'
        Should -Invoke Stop-VM -Times 0 -Exactly
    }

    It 'fails explicitly when more than one VM is found' {
        Mock Get-VM { @(
            [pscustomobject]@{ Name = 'KubeMaster'; State = 'Running' },
            [pscustomobject]@{ Name = 'KubeMaster'; State = 'Running' }
        ) }
        { Stop-VirtualMachine -VmName 'KubeMaster' } | Should -Throw '*More than one VM found*'
        Should -Invoke Stop-VM -Times 0 -Exactly
    }

    It 'does not let cleanup errors replace the stop failure' {
        $script:job.State = 'Failed'
        Mock Receive-Job { throw 'Shutdown rejected' } -RemoveParameterType Job
        Mock Remove-Job { throw 'Job removal failed' } -RemoveParameterType Job
        { Stop-VirtualMachine -VmName 'KubeMaster' -TimeoutInSeconds 1 } | Should -Throw '*Shutdown rejected*'
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Messages -like '*Failed to remove stop job*' }
    }

    It 'rejects a missing stop job' {
        Mock Stop-VM { $null }
        { Stop-VirtualMachine -VmName 'KubeMaster' } | Should -Throw '*no stop job*'
        Should -Invoke Wait-Job -Times 0 -Exactly
    }

    It 'rejects a stopped job instead of reporting successful shutdown' {
        $script:job.State = 'Stopped'
        { Stop-VirtualMachine -VmName 'KubeMaster' } | Should -Throw '*ended with state*Stopped*'
        Should -Invoke Remove-Job -Times 1 -Exactly -ParameterFilter { -not $Force }
    }

    It 'propagates a failed Off-state confirmation and removes the completed job' {
        Mock Wait-ForDesiredVMState { throw 'VM remained Stopping' }
        { Stop-VirtualMachine -VmName 'KubeMaster' -Wait } | Should -Throw '*VM remained Stopping*'
        Should -Invoke Remove-Job -Times 1 -Exactly
    }
}

Describe 'VM state refresh' -Tag 'unit', 'ci', 'vm' {
    BeforeEach {
        Mock Write-Log {}
        Mock Start-Sleep {}
        $script:queries = 0
    }

    It 'requeries VM state rather than polling a stale object' {
        Mock Get-VM {
            $script:queries++
            [pscustomobject]@{ Name = 'KubeMaster'; State = $(if ($script:queries -gt 1) { 'Off' } else { 'Running' }) }
        }
        Wait-ForDesiredVMState -VmName 'KubeMaster' -State 'off' -TimeoutInSeconds 5
        Should -Invoke Get-VM -Times 2 -Exactly
    }

    It 'accepts a VM already at the desired state with no remaining timeout' {
        Mock Get-VM { [pscustomobject]@{ Name = 'KubeMaster'; State = 'Off' } }
        { Wait-ForDesiredVMState -VmName 'KubeMaster' -State 'off' -TimeoutInSeconds 0 } | Should -Not -Throw
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'accepts the refreshed desired state at the timeout boundary' {
        Mock Start-Sleep { [System.Threading.Thread]::Sleep(1100) }
        Mock Get-VM {
            $script:queries++
            [pscustomobject]@{ Name = 'KubeMaster'; State = $(if ($script:queries -gt 1) { 'Off' } else { 'Stopping' }) }
        }
        { Wait-ForDesiredVMState -VmName 'KubeMaster' -State 'off' -TimeoutInSeconds 1 } | Should -Not -Throw
        Should -Invoke Get-VM -Times 2 -Exactly
    }

    It 'reports the last state when the time budget is exhausted' {
        Mock Get-VM { [pscustomobject]@{ Name = 'KubeMaster'; State = 'Stopping'; Status = 'Shutdown in progress' } }
        { Wait-ForDesiredVMState -VmName 'KubeMaster' -State 'off' -TimeoutInSeconds 0 } |
            Should -Throw '*last state*Stopping*Shutdown in progress*'
    }

    It 'fails if the VM disappears during state confirmation' {
        Mock Get-VM {
            $script:queries++
            if ($script:queries -eq 1) { [pscustomobject]@{ Name = 'KubeMaster'; State = 'Running' } }
        }
        { Wait-ForDesiredVMState -VmName 'KubeMaster' -State 'off' -TimeoutInSeconds 5 } | Should -Throw '*VM*'
        Should -Invoke Get-VM -Times 2 -Exactly
    }
}

Describe 'Real stop-job waiting deadline without a VM' -Tag 'unit', 'ci', 'vm' {
    BeforeEach {
        Mock Write-Log {}
        Mock Get-VM { [pscustomobject]@{ Name = 'KubeMaster'; State = 'Running'; Id = 'mock-vm' } }
        Mock Stop-VM {
            $script:liveStopJob = Start-Job { Start-Sleep -Seconds 30 }
            $script:liveStopJob
        }
    }

    AfterEach {
        if ($null -ne $script:liveStopJob) {
            Stop-Job -Job $script:liveStopJob
            Remove-Job -Job $script:liveStopJob
            $script:liveStopJob = $null
        }
    }

    It 'bounds real Wait-Job and leaves the unfinished operation alone' {
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        { Stop-VirtualMachine -VmName 'KubeMaster' -Wait -TimeoutInSeconds 1 } | Should -Throw '*stop operation exceeded 1s*'
        $timer.Elapsed.TotalSeconds | Should -BeLessThan 15
        $script:liveStopJob.State | Should -Be 'Running'
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Messages -like '*Retaining unfinished stop job*' }
    }
}
