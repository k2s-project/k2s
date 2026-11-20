# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $repositoryRoot = (Resolve-Path "$PSScriptRoot\..\..\..\..\..").Path

    function Read-RepositoryFile {
        param(
            [Parameter(Mandatory = $true)]
            [string] $RelativePath
        )

        return Get-Content -LiteralPath (Join-Path $repositoryRoot $RelativePath) -Raw
    }
}

Describe 'kubelet override install orchestration' -Tag 'unit', 'ci', 'kubelet-overrides' {
    It 'passes the effective snapshot to both host topology roles' {
        $installScript = Read-RepositoryFile 'lib\scripts\windows\host\install\Install.ps1'

        $installScript | Should -Match '\[string\]\s+\$EffectiveInstallConfigPath'
        ([regex]::Matches($installScript, 'EffectiveInstallConfigPath\s*=\s*\$EffectiveInstallConfigPath')).Count | Should -Be 2
    }

    It 'passes the same snapshot through Hyper-V and WSL control-plane setup' {
        $controlPlaneScript = Read-RepositoryFile 'lib\modules\windows\node\k2s.node.module\linuxnode\setup\control-plane-node.module.psm1'

        $controlPlaneScript | Should -Match 'if \(\$WSL\)'
        $controlPlaneScript | Should -Match 'EffectiveInstallConfigPath\s*=\s*\$EffectiveInstallConfigPath'
        $controlPlaneScript.IndexOf('EffectiveInstallConfigPath = $EffectiveInstallConfigPath') | Should -BeLessThan $controlPlaneScript.IndexOf('Set-UpMasterNode @masterNodeParams')
    }

    It 'passes the effective snapshot through build-only control-plane setup' {
        $buildOnlyScript = Read-RepositoryFile 'lib\scripts\windows\buildonly\install\Install.ps1'

        $buildOnlyScript | Should -Match '\[string\]\s+\$EffectiveInstallConfigPath'
        $buildOnlyScript | Should -Match 'EffectiveInstallConfigPath\s*=\s*\$EffectiveInstallConfigPath'
    }

    It 'declares the additional hooks parameter on the full-upgrade function' {
        $upgradeScript = Read-RepositoryFile 'lib\scripts\windows\host\system\upgrade\Start-ClusterUpgrade.ps1'

        $upgradeScript | Should -Match '(?s)function Start-ClusterUpgrade\s*\{\s*param\(.*?\[string\]\s+\$AdditionalHooksDir'
        $upgradeScript | Should -Match 'Start-ClusterUpgrade .* -AdditionalHooksDir \$AdditionalHooksDir'
    }

    It 'applies the Linux override before kubeadm initialization' {
        $commonSetup = Read-RepositoryFile 'lib\modules\windows\node\k2s.node.module\linuxnode\distros\common-setup.module.psm1'

        $applyIndex = $commonSetup.IndexOf('Set-K2sLinuxKubeletOverride -EffectiveInstallConfigPath $EffectiveInstallConfigPath')
        $kubeadmIndex = $commonSetup.IndexOf("`$initCmd = 'sudo kubeadm init")
        $applyIndex | Should -BeGreaterThan -1
        $kubeadmIndex | Should -BeGreaterThan $applyIndex
        $expectedNodeRegistration = @'
nodeRegistration:
  kubeletExtraArgs:
    - name: "config-dir"
      value: "/etc/kubernetes/kubelet.conf.d"
'@
        $commonSetup | Should -Match ([regex]::Escape($expectedNodeRegistration))
    }

    It 'applies the Windows override after service installation and before cluster join' {
        $workerModule = Read-RepositoryFile 'lib\modules\windows\node\k2s.node.module\windowsnode\setup\windows-worker-node.module.psm1'

        $initializeIndex = $workerModule.IndexOf('Initialize-WinNode -KubernetesVersion')
        $applyIndex = $workerModule.IndexOf('Set-K2sWindowsKubeletOverride -EffectiveInstallConfigPath $EffectiveInstallConfigPath')
        $joinIndex = $workerModule.IndexOf('Initialize-KubernetesCluster -AdditionalHooksDir')
        $initializeIndex | Should -BeGreaterThan -1
        $applyIndex | Should -BeGreaterThan $initializeIndex
        $joinIndex | Should -BeGreaterThan $applyIndex
    }

    It 'warns and skips the Windows role for a Windows-host linux-only install' {
        $linuxOnlyScript = Read-RepositoryFile 'lib\scripts\windows\linuxonly\install\Install.ps1'

        $linuxOnlyScript | Should -Match "Get-K2sKubeletOverrideContent .* -Role 'windowsWorker'"
        $linuxOnlyScript | Should -Match 'Windows worker overrides are ignored because linux-only installation was requested'
        $linuxOnlyScript | Should -Not -Match 'worker\\windows\\windows-host\\Install.ps1'
    }
}
