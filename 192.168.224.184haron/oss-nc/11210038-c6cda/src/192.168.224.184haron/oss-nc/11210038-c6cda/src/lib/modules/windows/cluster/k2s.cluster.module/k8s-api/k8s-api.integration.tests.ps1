# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Describe 'Invoke-Kubectl' -Tag 'integration', 'setup-required', 'read-only' {
    BeforeDiscovery {
        $isKubectlInstalled = $false

        try {
            $kubectlInfo = Get-Command kubectl -ErrorAction SilentlyContinue
            if ($kubectlInfo.Name -eq 'kubectl.exe') {
                $isKubectlInstalled = $true
            }
        }
        catch {
        }        
    }

    BeforeAll {
        $sut = "$PSScriptRoot\k8s-api.module.psm1"
    
        Import-Module $sut -Force
    }

    Context "kubectl' is installed" -Skip:($isKubectlInstalled -ne $true) {
        Context 'successful call' {
            It 'prints the client version info' {
                $result = Invoke-Kubectl -Params 'version', '--client'

                $result.Success | Should -BeTrue

                $resultString = $result.Output | Out-String

                $resultString | Should -Match 'Client Version: v*.*.*'
                $resultString | Should -Match 'Kustomize Version: v*.*.*'
            }
        }
        
        Context 'call fails' {
            It 'returns failure' {
                $result = Invoke-Kubectl -Params 1234 

                $result.Success | Should -BeFalse
                $result.Output | Should -Match 'error'
            }
        }
    }
}
