# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot 'common-setup.module.psm1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "Failed to parse '$modulePath': $($parseErrors[0].Message)"
    }

    foreach ($name in @('Assert-ProvisioningCommandResult', 'Install-Tools', 'Get-KubernetesImages', 'Get-FlannelImages', 'Get-ClusterIPWebhookImages', 'AddRegistryMirrors')) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        if ($null -eq $functionAst) {
            throw "Function '$name' not found in '$modulePath'"
        }
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    function Get-IsValidIPv4Address { param($Address) $true }
    function Write-Log { param([Parameter(ValueFromPipeline)]$Message) process {} }
    function Invoke-CmdOnControlPlaneViaUserAndPwd { param($CmdToExecute, $RemoteUser, $RemoteUserPwd, [switch]$IgnoreErrors, $RepairCmd, $Retries) }
    function Get-BuildahDebPackagesPath { param($UserName) '/packages/buildah' }
    function Get-BuildahDebPackagesFromInternet { param($UserName, $UserPwd, $IpAddress, $TargetPath) }
    function Install-BuildahDebPackages { param($UserName, $UserPwd, $IpAddress, $SourcePath) }
    function Get-RegistryToken { 'test-token' }
    function Install-CliToolsOnKubeMaster { param($UserName, $UserPwd, $IpAddress) }
    function Get-MirrorRegistries { @([pscustomobject]@{ registry = 'docker.io'; mirror = 'mirror.example' }) }
    $controlPlaneUserName = 'remote'
    $bashPath = 'C:\Program Files\Git\bin\bash.exe'
}

Describe 'Offline base-image provisioning' -Tag 'unit', 'ci', 'offline' {
    BeforeEach {
        $script:commands = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-CmdOnControlPlaneViaUserAndPwd {
            $script:commands.Add($CmdToExecute)
            [pscustomobject]@{ Success = $true; Output = 'ok' }
        }
        Mock Get-BuildahDebPackagesFromInternet {}
        Mock Install-BuildahDebPackages {}
        Mock Install-CliToolsOnKubeMaster {}
    }

    It 'writes quoted registry names through Windows native argument parsing and Bash, and is idempotent' {
        if (!(Test-Path $bashPath)) {
            Set-ItResult -Skipped -Because 'Git Bash is required for the native argument parsing regression.'
            return
        }
        Install-Tools -UserName 'remote' -UserPwd 'test-password' -IpAddress '172.19.1.100'
        $registryCommand = @($script:commands | Where-Object { $_ -match 'unqualified-search-registries' })
        $registryCommand.Count | Should -Be 1
        $registryCommand[0] | Should -Not -Match '"'

        $registryPath = Join-Path $TestDrive 'registries.conf'
        Set-Content -LiteralPath $registryPath -Value '# Packaged registry configuration' -Encoding Ascii
        $shellPath = (& $bashPath -c 'cygpath -u "$1"' -- $registryPath).Trim()
        $LASTEXITCODE | Should -Be 0
        $command = $registryCommand[0].Replace('/etc/containers/registries.conf', "'$shellPath'").Replace('sudo tee', 'tee')
        & $bashPath -c $command | Out-Null
        $LASTEXITCODE | Should -Be 0
        & $bashPath -c $command | Out-Null
        $LASTEXITCODE | Should -Be 0
        $content = Get-Content -LiteralPath $registryPath
        $content[0] | Should -BeExactly '# Packaged registry configuration'
        @($content | Where-Object { $_ -match '^unqualified-search-registries' }).Count | Should -Be 1
        $content[-1] | Should -BeExactly 'unqualified-search-registries = ["docker.io", "quay.io"]'

        Set-Content -LiteralPath $registryPath -Value 'unqualified-search-registries = ["custom.example"]' -Encoding Ascii
        & $bashPath -c $command | Out-Null
        $LASTEXITCODE | Should -Be 0
        (Get-Content -LiteralPath $registryPath) | Should -BeExactly 'unqualified-search-registries = ["custom.example"]'
    }

    It 'installs bundled Buildah before registry repair and verifies CRI-O before continuing' {
        Install-Tools -UserName 'remote' -UserPwd 'test-password' -IpAddress '172.19.1.100'
        Should -Invoke Install-BuildahDebPackages -Exactly 1
        $script:commands.IndexOf('sudo buildah -v') | Should -BeLessThan $script:commands.IndexOf('sudo systemctl daemon-reload')
        $script:commands[-1] | Should -BeExactly 'sudo crictl --runtime-endpoint unix:///var/run/crio/crio.sock info'
        Should -Invoke Install-CliToolsOnKubeMaster -Exactly 1
    }

    It 'stops tool provisioning on failure of <FailurePattern>' -TestCases @(
        @{ FailurePattern = 'base64 -d' }
        @{ FailurePattern = 'systemctl restart crio' }
        @{ FailurePattern = 'crictl --runtime-endpoint' }
    ) {
        param($FailurePattern)
        Mock Invoke-CmdOnControlPlaneViaUserAndPwd {
            $script:commands.Add($CmdToExecute)
            [pscustomobject]@{ Success = ($CmdToExecute -notlike "*$FailurePattern*"); Output = 'remote result' }
        }
        { Install-Tools -UserName 'remote' -UserPwd 'test-password' -IpAddress '172.19.1.100' } |
            Should -Throw '*Remote provisioning command failed*'
        Should -Invoke Install-CliToolsOnKubeMaster -Exactly 0
        $script:commands[-1] | Should -BeLike "*$FailurePattern*"
    }

    It 'collects service diagnostics on restart failure' {
        Install-Tools -UserName 'remote' -UserPwd 'test-password' -IpAddress '172.19.1.100'
        $command = $script:commands | Where-Object { $_ -match 'systemctl restart crio' }
        $command | Should -Match 'systemctl status crio --no-pager -l'
        $command | Should -Match 'journalctl -u crio -b --no-pager -n 100; exit 1'
    }

    It 'fails preparation when <FunctionName> fails instead of accepting logged errors' -TestCases @(
        @{ FunctionName = 'Get-KubernetesImages' }
        @{ FunctionName = 'Get-FlannelImages' }
        @{ FunctionName = 'Get-ClusterIPWebhookImages' }
        @{ FunctionName = 'AddRegistryMirrors' }
    ) {
        param($FunctionName)
        Mock Invoke-CmdOnControlPlaneViaUserAndPwd {
            [pscustomobject]@{ Success = $false; Output = 'runtime unavailable' }
        }
        $parameters = @{ UserName = 'remote'; UserPwd = 'test-password'; IpAddress = '172.19.1.100' }
        if ($FunctionName -eq 'Get-KubernetesImages') {
            $parameters.K8sVersion = 'v1.36.5'
        }
        { & $FunctionName @parameters } | Should -Throw '*Remote provisioning command failed*'
        Should -Invoke Invoke-CmdOnControlPlaneViaUserAndPwd -Exactly 1
    }

    It 'configures all mirror registries and restarts CRI-O only once' {
        Mock Get-MirrorRegistries {
            @(
                [pscustomobject]@{ registry = 'docker.io'; mirror = '10.81.79.18' },
                [pscustomobject]@{ registry = 'ghcr.io'; mirror = '10.81.79.18' },
                [pscustomobject]@{ registry = 'quay.io'; mirror = '10.81.79.18' }
            )
        }
        AddRegistryMirrors -UserName 'remote' -UserPwd 'test-password' -IpAddress '172.19.1.100'

        $mkdirCommands = @($script:commands | Where-Object { $_ -eq 'mkdir -p /etc/containers/registries.conf.d' })
        $mkdirCommands.Count | Should -Be 1

        $restartCommands = @($script:commands | Where-Object { $_ -match 'systemctl restart crio' })
        $restartCommands.Count | Should -Be 1

        $lastConfigIndex = [Math]::Max(
            $script:commands.FindLastIndex([Predicate[string]]{ param($c) $c -match 'docker.io.conf' }),
            $script:commands.FindLastIndex([Predicate[string]]{ param($c) $c -match 'quay.io.conf' })
        )
        $restartIndex = $script:commands.FindIndex([Predicate[string]]{ param($c) $c -match 'systemctl restart crio' })
        $restartIndex | Should -BeGreaterThan $lastConfigIndex
    }

    It 'skips mirror setup when no mirror registries are configured' {
        Mock Get-MirrorRegistries { @() }
        AddRegistryMirrors -UserName 'remote' -UserPwd 'test-password' -IpAddress '172.19.1.100'
        $script:commands.Count | Should -Be 0
    }
}
