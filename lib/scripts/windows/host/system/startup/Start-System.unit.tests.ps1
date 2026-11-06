# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        "$PSScriptRoot\Start-System.ps1", [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw ($parseErrors | Out-String)
    }
    $functionNames = @(
        'Select-K2sIsRunning',
        'Get-MissingWindowsPodRoutesOnControlPlane',
        'Restore-ControlPlaneTransitRoute',
        'Wait-ForControlPlaneTransitReachability',
        'Restart-FlannelDaemonSetWithWindowsRouteRepair',
        'Stop-StartupNetworkingServices',
        'Initialize-StartupWindowsNetwork',
        'Start-K8sNetworkingServices'
    )
    foreach ($function in $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $functionNames
            }, $true)) {
        Invoke-Expression $function.Extent.Text
    }

    function Write-Log { param($Messages, [switch]$Console) }
    function Invoke-CmdOnControlPlaneViaSSHKey { param($CmdToExecute, [switch]$IgnoreErrors, [switch]$NoLog) }
    function Get-LoopbackAdapterCIDR { }
    function Get-ConfiguredKubeSwitchIP { }
    function Get-WindowsWorkerNodeRoutes { param($KubeConfigPath) }
    function Invoke-KubectlWithKubeConfig { param($KubeConfigPath, $Params) }
    function Test-DefaultSwitch { param([switch]$ResolveConflict, $SwitchObservationSeconds) }
    function Wait-ForServiceStopped { param($ServiceName, $MaxRetries, $SleepSeconds) }
    function Wait-ForServiceRunning { param($ServiceName) }
    function Confirm-LoopbackAdapterIP {}
    function Remove-FlannelConflictingRoutesOnLoopback {}
    function Wait-NetworkL2BridgeReady { param($PodSubnetworkNumber) }
    function Add-HostBridgeIpReservation { param($PodSubnetworkNumber) }
    function Get-KubeBinPath {}
    function Get-KubePath {}
    function Get-ConfigControlPlaneNodeHostname {}
    $logUseCase = 'Start-System'
}

Describe 'Startup CLI operation guard' -Tag 'unit', 'ci', 'startup' {
    BeforeEach {
        Mock Write-Log {}
        Mock Get-CimInstance { @() }
    }

    It 'allows recovery when no CLI process is running' {
        Select-K2sIsRunning | Should -BeFalse
    }

    It 'allows recovery during unrelated CLI command <CommandLine>' -TestCases @(
        @{ CommandLine = 'C:\k2s\k2s.exe image import -d C:\temp\images -o' }
        @{ CommandLine = 'C:\k2s\k2s.exe node exec -c echo ready' }
        @{ CommandLine = 'C:\k2s\k2s.exe status' }
        @{ CommandLine = 'C:\k2s\k2s.exe image import -d C:\install\start' }
        @{ CommandLine = 'C:\k2s\k2s.exe node exec -c "k2s start"' }
        @{ CommandLine = 'C:\k2s\k2s.exe startup' }
        @{ CommandLine = 'C:\k2s\k2s.exe system proxy show' }
        @{ CommandLine = 'C:\k2s\k2s.exe system proxy get' }
        @{ CommandLine = 'C:\k2s\k2s.exe system proxy override ls' }
        @{ CommandLine = 'C:\k2s\k2s.exe node exec -c "k2s system proxy reset"' }
        @{ CommandLine = 'C:\k2s\k2s.exe system proxy settings' }
        @{ CommandLine = $null }
    ) {
        param($CommandLine)
        Mock Get-CimInstance { [pscustomobject]@{ Name = 'k2s.exe'; CommandLine = $CommandLine } }
        Select-K2sIsRunning | Should -BeFalse
    }

    It 'defers recovery during lifecycle command <CommandLine>' -TestCases @(
        @{ CommandLine = 'C:\k2s\k2s.exe install --output' }
        @{ CommandLine = 'C:\k2s\k2s.exe start' }
        @{ CommandLine = '"C:\Program Files\K2s\k2s.exe" start --output' }
        @{ CommandLine = '"C:\Program Files\K2s\k2s.exe" INSTALL --output' }
        @{ CommandLine = 'C:\k2s\k2s.exe system proxy set http://test-proxy:8080' }
        @{ CommandLine = 'C:\k2s\k2s.exe system proxy reset' }
        @{ CommandLine = 'C:\k2s\k2s.exe system proxy override add test.local' }
        @{ CommandLine = 'C:\k2s\k2s.exe system proxy override delete test.local' }
        @{ CommandLine = '"C:\Program Files\K2s\k2s.exe" SYSTEM PROXY RESET' }
    ) {
        param($CommandLine)
        Mock Get-CimInstance { [pscustomobject]@{ Name = 'k2s.exe'; CommandLine = $CommandLine } }
        Select-K2sIsRunning | Should -BeTrue
    }

    It 'checks all CLI processes for a lifecycle operation' {
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ Name = 'k2s.exe'; CommandLine = 'C:\k2s\k2s.exe image import -d C:\temp' }
                [pscustomobject]@{ Name = 'k2s.exe'; CommandLine = 'C:\k2s\k2s.exe start -o' }
            )
        }
        Select-K2sIsRunning | Should -BeTrue
    }

    It 'does not defer recovery for an unrelated executable' {
        Mock Get-CimInstance { [pscustomobject]@{ Name = 'other.exe'; CommandLine = 'other.exe start' } }
        Select-K2sIsRunning | Should -BeFalse
    }

    It 'does not stop networking services during proxy reconfiguration' {
        Mock Get-CimInstance {
            [pscustomobject]@{ Name = 'k2s.exe'; CommandLine = 'C:\k2s\k2s.exe system proxy set http://test-proxy:8080' }
        }
        Mock Stop-Service {}
        Mock Test-DefaultSwitch {}
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot\Start-System.ps1", [ref]$tokens, [ref]$parseErrors)
        $startup = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] } | Select-Object -Last 1
        $guard = $startup.Body.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and
            $_.Clauses[0].Item1.Extent.Text -eq '$k2sRunning'
        } | Select-Object -First 1
        $prefix = $ast.Extent.Text.Substring(
            $startup.Body.Extent.StartOffset + 1,
            $guard.Extent.EndOffset - $startup.Body.Extent.StartOffset - 1)

        & ([scriptblock]::Create($prefix + "`nStop-StartupNetworkingServices"))

        Should -Invoke Stop-Service -Times 0 -Exactly
    }
}

Describe 'Startup route inspection and repair' -Tag 'unit', 'ci', 'startup' {
    BeforeEach {
        $nodeRoutes = @([pscustomobject]@{ PodCIDR = '172.20.1.0/24'; InternalIP = '172.22.1.2'; NodeName = 'windows' })
        Mock Write-Log {}
        Mock Start-Sleep {}
        Mock Get-LoopbackAdapterCIDR { '172.22.1.0/24' }
        Mock Get-ConfiguredKubeSwitchIP { '172.19.1.1' }
        Mock Invoke-CmdOnControlPlaneViaSSHKey { [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '' } }
    }

    It 'does not classify failed SSH output as a missing pod route' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $false; ExitCode = 255; Output = 'UNPROTECTED PRIVATE KEY FILE!' }
        }
        { Get-MissingWindowsPodRoutesOnControlPlane -WindowsNodeRoutes $nodeRoutes } |
            Should -Throw '*Cannot inspect Windows pod route*UNPROTECTED PRIVATE KEY FILE*'
    }

    It 'does not accept matching route text from a failed command' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $false; ExitCode = 1; Output = '172.20.1.0/24 via 172.22.1.2' }
        }
        { Get-MissingWindowsPodRoutesOnControlPlane -WindowsNodeRoutes $nodeRoutes } |
            Should -Throw '*Cannot inspect Windows pod route*'
    }

    It 'recognizes a successful existing pod route' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '172.20.1.0/24 via 172.22.1.2 dev eth0' }
        }
        @(Get-MissingWindowsPodRoutesOnControlPlane -WindowsNodeRoutes $nodeRoutes).Count | Should -Be 0
    }

    It 'reports genuinely missing or incorrect pod routes after successful SSH' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '172.20.1.0/24 via 172.22.1.99' }
        }
        $missing = @(Get-MissingWindowsPodRoutesOnControlPlane -WindowsNodeRoutes $nodeRoutes)
        $missing.Count | Should -Be 1
        $missing[0].PodCIDR | Should -Be '172.20.1.0/24'
    }

    It 'does not attempt transit route replacement when inspection fails' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $false; ExitCode = 255; Output = 'Permission denied (publickey)' }
        }
        { Restore-ControlPlaneTransitRoute } | Should -Throw '*Cannot inspect transit route*Permission denied*'
        Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 0 -Exactly -ParameterFilter { $CmdToExecute -like 'sudo ip route replace*' }
    }

    It 'leaves a correct transit route untouched' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $true; ExitCode = 0; Output = '172.22.1.0/24 via 172.19.1.1' }
        }
        Restore-ControlPlaneTransitRoute
        Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -Exactly
    }

    It 'restores a missing transit route after successful inspection' {
        Restore-ControlPlaneTransitRoute
        Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -Exactly -ParameterFilter {
            $CmdToExecute -eq 'sudo ip route replace 172.22.1.0/24 via 172.19.1.1'
        }
    }

    It 'reports a failed transit route replacement' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $false; ExitCode = 2; Output = 'Network is unreachable' }
        } -ParameterFilter { $CmdToExecute -like 'sudo ip route replace*' }
        { Restore-ControlPlaneTransitRoute } | Should -Throw '*Failed to restore transit route*Network is unreachable*'
    }

    It 'stops flannel repair before restarts when transit inspection fails' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $false; ExitCode = 255; Output = 'Bad permissions' }
        }
        Mock Invoke-KubectlWithKubeConfig {}
        { Restart-FlannelDaemonSetWithWindowsRouteRepair -KubeConfigPath 'C:\k2s\config' } |
            Should -Throw '*Cannot inspect transit route*'
        Should -Invoke Invoke-KubectlWithKubeConfig -Times 0 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'does not start reachability polling when SSH is unavailable' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $false; ExitCode = 255; Output = 'Bad permissions' }
        }
        { Wait-ForControlPlaneTransitReachability -WindowsNodeRoutes $nodeRoutes } |
            Should -Throw '*control-plane SSH failed*Bad permissions*'
        Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'stops polling if SSH fails during a ping' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            [pscustomobject]@{ Success = $false; ExitCode = 255; Output = 'Permission denied' }
        } -ParameterFilter { $CmdToExecute -like 'ping*' }
        { Wait-ForControlPlaneTransitReachability -WindowsNodeRoutes $nodeRoutes } |
            Should -Throw '*SSH or the ping command failed*'
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'retries a real ping reachability failure rather than treating it as an SSH error' {
        $script:pingAttempts = 0
        Mock Invoke-CmdOnControlPlaneViaSSHKey {
            $script:pingAttempts++
            [pscustomobject]@{ Success = ($script:pingAttempts -gt 1); ExitCode = $(if ($script:pingAttempts -eq 1) { 1 } else { 0 }); Output = '' }
        } -ParameterFilter { $CmdToExecute -like 'ping*' }
        Wait-ForControlPlaneTransitReachability -WindowsNodeRoutes $nodeRoutes | Should -BeTrue
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'fails startup when required Windows pod routes remain missing' {
        Mock Get-WindowsWorkerNodeRoutes { [pscustomobject]@{ Success = $true; Routes = $nodeRoutes } }
        Mock Invoke-KubectlWithKubeConfig { [pscustomobject]@{ Success = $true; Output = 'rolled out' } }
        Mock Wait-ForControlPlaneTransitReachability { $true }
        { Restart-FlannelDaemonSetWithWindowsRouteRepair -KubeConfigPath 'C:\k2s\config' -MaxAttempts 2 } |
            Should -Throw '*Could not repair flannel*after 2 attempts*'
        Should -Invoke Invoke-KubectlWithKubeConfig -Times 2 -Exactly -ParameterFilter { $Params[1] -eq 'restart' }
    }

    It 'does not accept an unsuccessful rollout even if routes are present' {
        Mock Get-WindowsWorkerNodeRoutes { [pscustomobject]@{ Success = $true; Routes = $nodeRoutes } }
        Mock Invoke-KubectlWithKubeConfig { [pscustomobject]@{ Success = ($Params[1] -eq 'restart'); Output = 'rollout pending' } }
        Mock Wait-ForControlPlaneTransitReachability { $true }
        Mock Get-MissingWindowsPodRoutesOnControlPlane { @() }
        { Restart-FlannelDaemonSetWithWindowsRouteRepair -KubeConfigPath 'C:\k2s\config' -MaxAttempts 1 } |
            Should -Throw '*Could not repair flannel*'
    }

    It 'fails when the Windows route inventory cannot be queried' {
        Mock Get-WindowsWorkerNodeRoutes { [pscustomobject]@{ Success = $false; Routes = @() } }
        Mock Invoke-KubectlWithKubeConfig {}
        { Restart-FlannelDaemonSetWithWindowsRouteRepair -KubeConfigPath 'C:\k2s\config' -MaxAttempts 1 } |
            Should -Throw '*Cannot validate Windows pod routes*'
        Should -Invoke Invoke-KubectlWithKubeConfig -Times 0 -Exactly
    }

    It 'accepts a successful rollout with validated routes' {
        Mock Get-WindowsWorkerNodeRoutes { [pscustomobject]@{ Success = $true; Routes = $nodeRoutes } }
        Mock Invoke-KubectlWithKubeConfig { [pscustomobject]@{ Success = $true; Output = 'rolled out' } }
        Mock Wait-ForControlPlaneTransitReachability { $true }
        Mock Get-MissingWindowsPodRoutesOnControlPlane { @() }
        { Restart-FlannelDaemonSetWithWindowsRouteRepair -KubeConfigPath 'C:\k2s\config' } | Should -Not -Throw
        Should -Invoke Invoke-KubectlWithKubeConfig -Times 2 -Exactly
    }
}

Describe 'Default Switch recreation during reboot recovery' -Tag 'unit', 'ci', 'startup' {
    BeforeEach {
        $script:recoveryAttempts = 0
        $script:startupSteps = @()
        $script:collisionMessage = '[PREREQ-FAILED] Hyper-V Default Switch subnet (172.20.128.1/20) collides with K2s network configuration podNetworkCIDR (172.20.0.0/16).'
        Mock Write-Log {}
        Mock Start-Sleep {}
        Mock Stop-Service { $script:startupSteps += "stop:$Name" }
        Mock Wait-ForServiceStopped { $script:startupSteps += "stopped:$ServiceName"; $true }
        Mock Start-Service { $script:startupSteps += "start:$Name" }
        Mock Wait-ForServiceRunning { $true }
        Mock Test-DefaultSwitch {
            if ($ResolveConflict) {
                $script:recoveryAttempts++
                $script:startupSteps += 'resolve'
            } else {
                $script:startupSteps += 'validate'
            }
        }
        Mock Confirm-LoopbackAdapterIP {}
        Mock Remove-FlannelConflictingRoutesOnLoopback {}
        Mock Wait-NetworkL2BridgeReady { $script:startupSteps += 'bridge-ready' }
        Mock Add-HostBridgeIpReservation {}
        Mock Get-KubeBinPath { 'TestDrive:\no-nssm' }
        Mock Get-KubePath { 'C:\k2s' }
        Mock Get-ConfigControlPlaneNodeHostname { 'kubemaster' }
        Mock Invoke-KubectlWithKubeConfig { [pscustomobject]@{ Success = $true; Output = 'ready' } }
        Mock Restart-FlannelDaemonSetWithWindowsRouteRepair { $script:startupSteps += 'linux-routes' }
    }

    It 'confirms services stopped before recovery and validates the bridge before Linux route repair' {
        Start-K8sNetworkingServices
        ($script:startupSteps -join ',') | Should -Be 'stop:kubeproxy,stopped:kubeproxy,stop:kubelet,stopped:kubelet,stop:flanneld,stopped:flanneld,resolve,start:flanneld,bridge-ready,validate,start:kubelet,start:kubeproxy,linux-routes'
        Should -Invoke Stop-Service -Times 3 -Exactly -ParameterFilter { $NoWait }
    }

    It 'recovers a collision introduced after an initially successful check' {
        Test-DefaultSwitch
        Mock Test-DefaultSwitch { throw $script:collisionMessage } -ParameterFilter { -not $ResolveConflict -and $script:recoveryAttempts -eq 1 }
        Start-K8sNetworkingServices
        $script:recoveryAttempts | Should -Be 2
        Should -Invoke Start-Service -Times 2 -Exactly -ParameterFilter { $Name -eq 'flanneld' }
        Should -Invoke Restart-FlannelDaemonSetWithWindowsRouteRepair -Times 1 -Exactly
    }

    It 'detects a late collision even when it prevents bridge readiness' {
        Mock Wait-NetworkL2BridgeReady { throw 'bridge timeout' } -ParameterFilter { $script:recoveryAttempts -eq 1 }
        Mock Test-DefaultSwitch { throw $script:collisionMessage } -ParameterFilter { -not $ResolveConflict -and $script:recoveryAttempts -eq 1 }
        Start-K8sNetworkingServices
        $script:recoveryAttempts | Should -Be 2
        Should -Invoke Restart-FlannelDaemonSetWithWindowsRouteRepair -Times 1 -Exactly
    }

    It 'stops after three repeated late collisions without repairing Linux routes' {
        Mock Test-DefaultSwitch { throw $script:collisionMessage } -ParameterFilter { -not $ResolveConflict }
        { Start-K8sNetworkingServices } | Should -Throw '*collides with K2s network configuration*'
        $script:recoveryAttempts | Should -Be 3
        Should -Invoke Restart-FlannelDaemonSetWithWindowsRouteRepair -Times 0 -Exactly
        $script:startupSteps[-1] | Should -Be 'stopped:flanneld'
    }

    It 'does not remove a switch if <blockedService> cannot be confirmed stopped' -ForEach @(
        @{ blockedService = 'kubeproxy'; stopCount = 1 }
        @{ blockedService = 'kubelet'; stopCount = 2 }
        @{ blockedService = 'flanneld'; stopCount = 3 }
    ) {
        Mock Wait-ForServiceStopped { $false } -ParameterFilter { $ServiceName -eq $blockedService }
        { Initialize-StartupWindowsNetwork } | Should -Throw '*did not stop*'
        Should -Invoke Stop-Service -Times $stopCount -Exactly
        Should -Invoke Test-DefaultSwitch -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly
    }

    It 'propagates service stop errors without removing the switch' {
        Mock Stop-Service { throw 'service control access denied' }
        { Initialize-StartupWindowsNetwork } | Should -Throw '*access denied*'
        Should -Invoke Test-DefaultSwitch -Times 0 -Exactly
    }

    It 'propagates failed conflict removal without starting networking' {
        Mock Test-DefaultSwitch { throw 'Automatic recovery failed after 5 attempts' } -ParameterFilter { $ResolveConflict }
        { Initialize-StartupWindowsNetwork } | Should -Throw '*Automatic recovery failed*'
        Should -Invoke Start-Service -Times 0 -Exactly
    }

    It 'does not retry unrelated inspection errors' {
        Mock Test-DefaultSwitch { throw 'cannot query Hyper-V' } -ParameterFilter { -not $ResolveConflict }
        { Initialize-StartupWindowsNetwork } | Should -Throw '*cannot query Hyper-V*'
        $script:recoveryAttempts | Should -Be 1
    }

    It 'does not retry a bridge failure without a subnet collision' {
        Mock Wait-NetworkL2BridgeReady { throw 'bridge timeout' }
        { Initialize-StartupWindowsNetwork } | Should -Throw '*bridge timeout*'
        $script:recoveryAttempts | Should -Be 1
    }

    It 'rejects flannel failing to reach Running state' {
        Mock Wait-ForServiceRunning { $false } -ParameterFilter { $ServiceName -eq 'flanneld' }
        { Start-K8sNetworkingServices } | Should -Throw '*flanneld did not start*'
        Should -Invoke Wait-NetworkL2BridgeReady -Times 0 -Exactly
        Should -Invoke Restart-FlannelDaemonSetWithWindowsRouteRepair -Times 0 -Exactly
    }

    It 'rejects a Windows networking service failing to reach Running state' {
        Mock Wait-ForServiceRunning { $false } -ParameterFilter { $ServiceName -eq 'kubeproxy' }
        { Start-K8sNetworkingServices } | Should -Throw "*Service 'kubeproxy' did not start*"
        Should -Invoke Restart-FlannelDaemonSetWithWindowsRouteRepair -Times 0 -Exactly
    }

    It 'propagates Linux kube-proxy restart failure before route repair' {
        Mock Invoke-KubectlWithKubeConfig {
            [pscustomobject]@{ Success = $false; Output = 'proxy restart denied' }
        } -ParameterFilter { $Params -contains 'daemonset/kube-proxy' }
        { Start-K8sNetworkingServices } | Should -Throw '*proxy restart denied*'
        Should -Invoke Restart-FlannelDaemonSetWithWindowsRouteRepair -Times 0 -Exactly
    }

    It 'propagates CoreDNS restart failure instead of logging completion' {
        Mock Invoke-KubectlWithKubeConfig {
            [pscustomobject]@{ Success = $false; Output = 'DNS restart denied' }
        } -ParameterFilter { $Params -contains 'deployment/coredns' }
        { Start-K8sNetworkingServices } | Should -Throw '*DNS restart denied*'
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Messages -like '*Linux-side system DaemonSet restart completed*' }
    }

    It 'propagates Linux route recovery failure instead of logging completion' {
        Mock Restart-FlannelDaemonSetWithWindowsRouteRepair { throw 'required pod route missing' }
        { Start-K8sNetworkingServices } | Should -Throw '*required pod route missing*'
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Messages -like '*Linux-side system DaemonSet restart completed*' }
    }

    It 'fails when the API server never becomes ready' {
        Mock Invoke-KubectlWithKubeConfig { [pscustomobject]@{ Success = $false; Output = 'not ready' } }
        { Start-K8sNetworkingServices } | Should -Throw '*API server not ready after 20 attempts*'
        Should -Invoke Invoke-KubectlWithKubeConfig -Times 20 -Exactly
        Should -Invoke Restart-FlannelDaemonSetWithWindowsRouteRepair -Times 0 -Exactly
    }
}
