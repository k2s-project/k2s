# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $moduleName = (Import-Module "$PSScriptRoot\kubelet-overrides.module.psm1" -PassThru -Force).Name
}

Describe 'Get-K2sKubeletOverrideContent' -Tag 'unit', 'ci', 'kubelet-overrides' {
    It 'renders supported values deterministically' {
        $configPath = Join-Path $TestDrive 'effective.json'
        $json = '{"kubeletOverrides":{"linuxControlPlane":{"enabled":true,"config":{"maxPods":100,"systemReserved":{"cpu":"500m","memory":"1Gi"},"kubeReserved":{"cpu":"250m","memory":"512Mi"}}}}}'
        [System.IO.File]::WriteAllText($configPath, $json, [System.Text.UTF8Encoding]::new($false))

        $actual = Get-K2sKubeletOverrideContent -EffectiveInstallConfigPath $configPath -Role 'linuxControlPlane'

        $expected = "# This file is managed by K2s. Do not edit.`napiVersion: kubelet.config.k8s.io/v1beta1`nkind: KubeletConfiguration`nmaxPods: 100`nsystemReserved:`n  cpu: `"500m`"`n  memory: `"1Gi`"`nkubeReserved:`n  cpu: `"250m`"`n  memory: `"512Mi`"`n"
        $actual | Should -BeExactly $expected
    }

    It 'returns no content for an omitted role' {
        $configPath = Join-Path $TestDrive 'effective.json'
        [System.IO.File]::WriteAllText($configPath, '{"kind":"k2s"}', [System.Text.UTF8Encoding]::new($false))

        Get-K2sKubeletOverrideContent -EffectiveInstallConfigPath $configPath -Role 'windowsWorker' | Should -BeNullOrEmpty
    }

    It 'fails when the internal snapshot is missing' {
        { Get-K2sKubeletOverrideContent -EffectiveInstallConfigPath (Join-Path $TestDrive 'missing.json') -Role 'windowsWorker' } | Should -Throw '*not found*'
    }
}

Describe 'Set-K2sWindowsKubeletOverride' -Tag 'unit', 'ci', 'kubelet-overrides' {
    BeforeEach {
        $script:configPath = Join-Path $TestDrive 'effective.json'
        $script:targetPath = Join-Path $TestDrive 'drop-ins\20-k2s-install-config.conf'
        Remove-Item -LiteralPath (Split-Path -Path $targetPath -Parent) -Recurse -Force -ErrorAction SilentlyContinue
        Mock -ModuleName $moduleName Get-Service { $null }
        Mock -ModuleName $moduleName Restart-Service { }
    }

    It 'creates only the managed target and reports a change' {
        [System.IO.File]::WriteAllText($configPath, '{"kubeletOverrides":{"windowsWorker":{"enabled":true,"config":{"maxPods":64}}}}', [System.Text.UTF8Encoding]::new($false))

        Set-K2sWindowsKubeletOverride -EffectiveInstallConfigPath $configPath -TargetPath $targetPath | Should -BeTrue
        (Get-Content -LiteralPath $targetPath -TotalCount 1) | Should -Be '# This file is managed by K2s. Do not edit.'
        Should -Invoke Restart-Service -ModuleName $moduleName -Exactly 0
    }

    It 'does not replace or restart when content is unchanged' {
        [System.IO.File]::WriteAllText($configPath, '{"kubeletOverrides":{"windowsWorker":{"enabled":true,"config":{"maxPods":64}}}}', [System.Text.UTF8Encoding]::new($false))
        Set-K2sWindowsKubeletOverride -EffectiveInstallConfigPath $configPath -TargetPath $targetPath | Should -BeTrue

        Set-K2sWindowsKubeletOverride -EffectiveInstallConfigPath $configPath -TargetPath $targetPath | Should -BeFalse
        Should -Invoke Restart-Service -ModuleName $moduleName -Exactly 0
    }

    It 'refuses to replace an unmanaged collision' {
        $targetDirectory = Split-Path -Path $targetPath -Parent
        $null = New-Item -Path $targetDirectory -ItemType Directory -Force
        [System.IO.File]::WriteAllText($targetPath, 'manual content', [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($configPath, '{"kubeletOverrides":{"windowsWorker":{"enabled":true,"config":{"maxPods":64}}}}', [System.Text.UTF8Encoding]::new($false))

        { Set-K2sWindowsKubeletOverride -EffectiveInstallConfigPath $configPath -TargetPath $targetPath } | Should -Throw '*unmanaged*'
        (Get-Content -LiteralPath $targetPath -Raw) | Should -BeExactly 'manual content'
    }

    It 'removes a managed target when the role is disabled' {
        $targetDirectory = Split-Path -Path $targetPath -Parent
        $null = New-Item -Path $targetDirectory -ItemType Directory -Force
        [System.IO.File]::WriteAllText($targetPath, "# This file is managed by K2s. Do not edit.`nkind: KubeletConfiguration`n", [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($configPath, '{"kubeletOverrides":{"windowsWorker":{"enabled":false,"config":{}}}}', [System.Text.UTF8Encoding]::new($false))

        Set-K2sWindowsKubeletOverride -EffectiveInstallConfigPath $configPath -TargetPath $targetPath | Should -BeTrue
        Test-Path -LiteralPath $targetPath | Should -BeFalse
    }

    It 'refuses a directory collision when the role is disabled' {
        $targetDirectory = Split-Path -Path $targetPath -Parent
        $null = New-Item -Path $targetDirectory -ItemType Directory -Force
        $null = New-Item -Path $targetPath -ItemType Directory -Force
        [System.IO.File]::WriteAllText($configPath, '{"kubeletOverrides":{"windowsWorker":{"enabled":false,"config":{}}}}', [System.Text.UTF8Encoding]::new($false))

        { Set-K2sWindowsKubeletOverride -EffectiveInstallConfigPath $configPath -TargetPath $targetPath } |
            Should -Throw '*non-regular kubelet drop-in collision*'
        Test-Path -LiteralPath $targetPath -PathType Container | Should -BeTrue
    }
}
