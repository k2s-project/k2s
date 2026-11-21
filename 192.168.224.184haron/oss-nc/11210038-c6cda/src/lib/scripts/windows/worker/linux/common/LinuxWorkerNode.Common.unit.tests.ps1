# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    . "$PSScriptRoot\LinuxWorkerNode.Common.ps1"
    function Write-Log {}
    function Invoke-CmdOnVmViaSSHKey {}
    function Get-InstalledDistribution {}
    function Test-SupportedWorkerOS {}
    function Get-RemoteArchitecture {}
    function Invoke-Kubectl {}
}

Describe 'Get-LinuxWorkerNodeProvisioningContext architecture validation' -Tag 'unit', 'ci' {
    BeforeEach {
        Mock Write-Log {}
        Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Output = 'worker'; Success = $true } }
        Mock Get-InstalledDistribution { 'debian13' }
        Mock Test-SupportedWorkerOS {}
        Mock Get-RemoteArchitecture { $TestArchitecture }
        Mock Invoke-Kubectl { [pscustomobject]@{ Output = ''; Success = $true } }
    }

    It 'rejects unsupported architectures before checking cluster membership' {
        $TestArchitecture = 'armv7l'

        {
            Get-LinuxWorkerNodeProvisioningContext -UserName worker -IpAddress '192.0.2.10'
        } | Should -Throw '*Unsupported worker architecture*'

        Should -Invoke Invoke-Kubectl -Times 0 -Exactly
    }
}
