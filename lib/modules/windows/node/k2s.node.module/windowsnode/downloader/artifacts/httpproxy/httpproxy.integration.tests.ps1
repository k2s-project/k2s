# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Describe 'WinHttpProxy NSSM Integration' -Tag 'integration', 'setup-required', 'invasive', 'httpproxy' {
    BeforeDiscovery {
        $isHttpProxyInstalled = $null -ne (Get-Service -Name 'httpproxy' -ErrorAction SilentlyContinue)
    }

    BeforeAll {
        Import-Module "$PSScriptRoot\httpproxy.module.psm1" -Force
        $script:endpointInfo = Get-HttpProxyReadinessEndpoint -Port 8181
        $script:foreignListener = $null
    }

    Context 'when httpproxy service is installed' -Skip:(-not $isHttpProxyInstalled) {
        AfterEach {
            if ($null -ne $script:foreignListener) {
                try {
                    $script:foreignListener.Stop()
                }
                catch {
                }
                $script:foreignListener = $null
            }

            Start-WinHttpProxy -OnlyProxy
        }

        AfterAll {
            if ($null -ne (Get-Service -Name 'httpproxy' -ErrorAction SilentlyContinue)) {
                Start-WinHttpProxy -OnlyProxy
            }
        }

        It 'starts httpproxy via NSSM from stopped state and verifies port 8181 ownership and TCP readiness' {
            $stopResult = Invoke-HttpProxyRecoveryStop -ServiceName 'httpproxy' -TimeoutSeconds 15
            $stopResult.Stopped | Should -BeTrue
            (Get-Service -Name 'httpproxy').Status | Should -Be 'Stopped'
            (Test-HttpProxyTcpReadiness -TargetHost $script:endpointInfo.Host -Port 8181 -ConnectTimeoutMs 500).Success | Should -BeFalse

            Start-WinHttpProxy -OnlyProxy

            (Get-Service -Name 'httpproxy').Status | Should -Be 'Running'
            $ownership = Get-HttpProxyListenerOwnership -Port 8181
            $ownership.IsOwned | Should -BeTrue
            $ownership.MatchedProcessName | Should -Be 'httpproxy.exe'
            (Test-HttpProxyTcpReadiness -TargetHost $script:endpointInfo.Host -Port 8181 -ConnectTimeoutMs 1500).Success | Should -BeTrue
        }

        It 'accepts an already-running healthy httpproxy without restarting it' {
            Start-WinHttpProxy -OnlyProxy

            $beforeOwnership = Get-HttpProxyListenerOwnership -Port 8181
            $beforeOwnership.IsOwned | Should -BeTrue
            $beforeOwnership.MatchedPid | Should -BeGreaterThan 0
            $beforeOwnership.ServicePid | Should -BeGreaterThan 0

            Start-WinHttpProxy -OnlyProxy

            $afterOwnership = Get-HttpProxyListenerOwnership -Port 8181
            $afterOwnership.IsOwned | Should -BeTrue
            $afterOwnership.MatchedPid | Should -Be $beforeOwnership.MatchedPid
            $afterOwnership.ServicePid | Should -Be $beforeOwnership.ServicePid
        }

        It 'recovers when the child httpproxy.exe process is terminated' {
            Start-WinHttpProxy -OnlyProxy

            $beforeOwnership = Get-HttpProxyListenerOwnership -Port 8181
            $beforeOwnership.IsOwned | Should -BeTrue
            $initialChildPid = $beforeOwnership.MatchedPid

            Stop-Process -Id $initialChildPid -Force
            Wait-Process -Id $initialChildPid -Timeout 10 -ErrorAction SilentlyContinue

            Start-WinHttpProxy -OnlyProxy

            (Get-Service -Name 'httpproxy').Status | Should -Be 'Running'
            $afterOwnership = Get-HttpProxyListenerOwnership -Port 8181
            $afterOwnership.IsOwned | Should -BeTrue
            $afterOwnership.MatchedPid | Should -Not -Be $initialChildPid
            (Test-HttpProxyTcpReadiness -TargetHost $script:endpointInfo.Host -Port 8181 -ConnectTimeoutMs 1500).Success | Should -BeTrue
        }

        It 'rejects a foreign listener on port 8181 without killing it' {
            $stopResult = Invoke-HttpProxyRecoveryStop -ServiceName 'httpproxy' -TimeoutSeconds 15
            $stopResult.Stopped | Should -BeTrue

            $bindAddress = [System.Net.IPAddress]::Parse($script:endpointInfo.Host)
            $script:foreignListener = [System.Net.Sockets.TcpListener]::new($bindAddress, 8181)
            $script:foreignListener.Start()

            {
                Start-WinHttpProxy -OnlyProxy -MaxAttempts 1 -ReadinessTimeoutSeconds 2 -PollIntervalSeconds 1 -ConnectTimeoutMs 500
            } | Should -Throw '*not owned*'

            $script:foreignListener.Server.IsBound | Should -BeTrue
        }
    }
}
