# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $modulePath = "$PSScriptRoot\common-setup.module.psm1"
    $moduleName = (Import-Module $modulePath -PassThru -Force).Name
}

Describe 'Linux worker artifacts by architecture' -Tag 'unit', 'ci' {
    BeforeEach {
        InModuleScope $moduleName {
            Mock Write-Log {}
            Mock Copy-DebPackagesFromWindowsHostToRemoteComputer {}
            Mock Get-KubernetesArtifactsFromInternet {}
            Mock Get-BuildahDebPackagesFromInternet {}
            Mock Test-DebPackageArchitecture { $false }
            Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $true; Output = '' } }
            Mock Assert-ProvisioningCommandResult {}
            Mock Copy-KubernetesImagesFromControlPlaneNodeToWindowsHost {}
        }
    }

    It 'downloads Kubernetes and buildah packages for an architecture that differs from the control plane' {
        InModuleScope $moduleName {
            Add-KubernetesArtifactsToRemoteComputer -UserName worker -IpAddress '172.19.1.101' -SourcePath 'C:\linuxnode\packages\debian13' -TargetPath '/tmp/kubernetes' -InstalledDistribution debian13 -Architecture arm64 -ControlPlaneArchitecture amd64
            Add-BuildahArtifactsToRemoteComputer -UserName worker -IpAddress '172.19.1.101' -SourcePath 'C:\linuxnode\packages\debian13' -TargetPath '/tmp/buildah' -InstalledDistribution debian13 -Architecture arm64 -ControlPlaneArchitecture amd64

            Should -Invoke Copy-DebPackagesFromWindowsHostToRemoteComputer -Times 0 -Exactly
            Should -Invoke Get-KubernetesArtifactsFromInternet -Times 1 -Exactly
            Should -Invoke Get-BuildahDebPackagesFromInternet -Times 1 -Exactly
        }
    }

    It 'uses the explicitly supplied node package for its worker architecture' {
        InModuleScope $moduleName {
            Mock Test-Path { $true }
            Mock Test-DebPackageArchitecture { $true }
            Add-KubernetesArtifactsToRemoteComputer -UserName worker -IpAddress '172.19.1.101' -SourcePath 'C:\linuxnode\packages\debian13' -TargetPath '/tmp/kubernetes' -InstalledDistribution debian13 -Architecture arm64 -ControlPlaneArchitecture amd64 -UseNodePackageArtifacts
            Add-BuildahArtifactsToRemoteComputer -UserName worker -IpAddress '172.19.1.101' -SourcePath 'C:\linuxnode\packages\debian13' -TargetPath '/tmp/buildah' -InstalledDistribution debian13 -Architecture arm64 -ControlPlaneArchitecture amd64 -UseNodePackageArtifacts

            Should -Invoke Copy-DebPackagesFromWindowsHostToRemoteComputer -Times 2 -Exactly
            Should -Invoke Get-KubernetesArtifactsFromInternet -Times 0 -Exactly
            Should -Invoke Get-BuildahDebPackagesFromInternet -Times 0 -Exactly
        }
    }

    It 'pulls Kubernetes and flannel images on a worker with a different architecture' {
        InModuleScope $moduleName {
            Copy-KubernetesImagesFromControlPlaneToRemoteComputer -UserName worker -IpAddress '172.19.1.101' -Architecture arm64 -ControlPlaneArchitecture amd64

            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 3 -Exactly
            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly -ParameterFilter {
                $CmdToExecute -like '*--cri-socket unix:///run/crio/crio.sock*'
            }
            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 2 -Exactly -ParameterFilter {
                $CmdToExecute -like '*--runtime-endpoint unix:///run/crio/crio.sock*'
            }
            Should -Invoke Assert-ProvisioningCommandResult -Times 3 -Exactly
            Should -Invoke Copy-KubernetesImagesFromControlPlaneNodeToWindowsHost -Times 0 -Exactly
        }
    }

    It 'imports the supplied node package images instead of pulling for a different architecture' {
        InModuleScope $moduleName {
            Mock Get-DirectoryOfKubenodeImagesOnWindowsHost { 'C:\linuxnode\images\arm64' }
            Mock Get-ChildItem { @([pscustomobject]@{ FullName = 'C:\linuxnode\images\arm64\kube-apiserver.tar' }) }
            Mock Copy-ToRemoteComputerViaSshKey {}

            Copy-KubernetesImagesFromControlPlaneToRemoteComputer -UserName worker -IpAddress '172.19.1.101' -Architecture arm64 -ControlPlaneArchitecture amd64 -UseNodePackageArtifacts

            Should -Invoke Copy-ToRemoteComputerViaSshKey -Times 1 -Exactly -ParameterFilter {
                $Source -eq 'C:\linuxnode\images\arm64\kube-apiserver.tar' -and $Target -eq '/tmp/import.tar'
            }
            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 2 -Exactly -ParameterFilter {
                $CmdToExecute -like '*buildah pull oci-archive:/tmp/import.tar*' -or
                $CmdToExecute -eq 'cd /tmp && sudo rm -rf import.tar'
            }
            Should -Invoke Copy-KubernetesImagesFromControlPlaneNodeToWindowsHost -Times 0 -Exactly
        }
    }

    It 'fails rather than falling back online when an explicit node package has no images' {
        InModuleScope $moduleName {
            Mock Get-DirectoryOfKubenodeImagesOnWindowsHost { 'C:\linuxnode\images\arm64' }
            Mock Get-ChildItem { @() }

            {
                Copy-KubernetesImagesFromControlPlaneToRemoteComputer -UserName worker -IpAddress '172.19.1.101' -Architecture arm64 -ControlPlaneArchitecture amd64 -UseNodePackageArtifacts
            } | Should -Throw '*Explicit node package contains no usable images*'

            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 0 -Exactly
            Should -Invoke Copy-KubernetesImagesFromControlPlaneNodeToWindowsHost -Times 0 -Exactly
        }
    }
}

Describe 'Worker image cache paths' -Tag 'unit', 'ci' {
    It 'returns an architecture-specific path when requested and the shared path otherwise' {
        $basePath = Join-Path $TestDrive 'images'
        InModuleScope $moduleName -Parameters @{ BasePath = $basePath } {
            param($BasePath)
            $directoryOfKubenodeImagesOnWindowsHost = $BasePath

            Get-DirectoryOfKubenodeImagesOnWindowsHost -Architecture arm64 | Should -Be (Join-Path $BasePath 'arm64')
            Get-DirectoryOfKubenodeImagesOnWindowsHost | Should -Be $BasePath
        }
    }
}

Describe 'Get-RemoteArchitecture' -Tag 'unit', 'ci' {
    It 'reports failed SSH architecture lookups instead of treating output as an architecture' {
        InModuleScope $moduleName {
            Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $false; Output = 'SSH unavailable' } }
            {
                Get-RemoteArchitecture -UserName worker -IpAddress '172.19.1.101'
            } | Should -Throw '*SSH unavailable*'
        }
    }
}

Describe 'Deb package cache architecture validation' -Tag 'unit', 'ci' {
    It 'rejects incompatible packages but accepts architecture-independent packages' {
        $packageCache = Join-Path $TestDrive 'deb-cache'
        New-Item -Path $packageCache -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $packageCache 'kubelet_1.37.3_amd64.deb') -ItemType File -Force | Out-Null
        New-Item -Path (Join-Path $packageCache 'ca-certificates_2025.1_all.deb') -ItemType File -Force | Out-Null

        InModuleScope $moduleName -Parameters @{ PackageCache = $packageCache } {
            param($PackageCache)
            Test-DebPackageArchitecture -SourcePath $PackageCache -Architecture arm64 | Should -BeFalse
            Remove-Item -Path (Join-Path $PackageCache 'kubelet_1.37.3_amd64.deb') -Force
            Test-DebPackageArchitecture -SourcePath $PackageCache -Architecture arm64 | Should -BeTrue
        }
    }
}

Describe 'Invoke-Debian13NodeHardening' -Tag 'unit', 'ci' {
    BeforeEach {
        InModuleScope $moduleName {
            Mock Get-LinuxScriptPath { 'C:\k2s\cfg\nodeextension\debian13\scripts' }
            Mock Invoke-RemoteScript {}
        }
    }

    It 'passes <Stage> with password <Password> to the bundled script without retries' -ForEach @(
        @{ Stage = 'prepare'; Password = 'image-password' }
        @{ Stage = 'cleanup'; Password = 'image-password' }
        @{ Stage = 'prepare'; Password = '' }
        @{ Stage = 'cleanup'; Password = '' }
    ) {
        InModuleScope $moduleName -Parameters @{ Stage = $Stage; Password = $Password } {
            param($Stage, $Password)
            Invoke-Debian13NodeHardening -Stage $Stage -InstalledDistribution debian13 -UserName remote -IpAddress '172.19.1.101' -UserPwd $Password

            Should -Invoke Invoke-RemoteScript -Times 1 -Exactly -ParameterFilter {
                $LocalScriptPath -eq 'C:\k2s\cfg\nodeextension\debian13\scripts\harden-node.sh' -and
                $UserName -eq 'remote' -and $IpAddress -eq '172.19.1.101' -and $UserPwd -eq $Password -and
                $Arguments.Count -eq 1 -and $Arguments[0] -eq $Stage -and $Retries -eq 0 -and $CleanupAfterExecution
            }
        }
    }

    It 'skips <Distribution> at <Stage> without resolving or invoking a remote script' -ForEach @(
        @{ Distribution = 'debian12'; Stage = 'prepare' }
        @{ Distribution = 'debian12'; Stage = 'cleanup' }
        @{ Distribution = 'ubuntu24.04'; Stage = 'prepare' }
        @{ Distribution = 'ubuntu24.04'; Stage = 'cleanup' }
    ) {
        InModuleScope $moduleName -Parameters @{ Distribution = $Distribution; Stage = $Stage } {
            param($Distribution, $Stage)
            Invoke-Debian13NodeHardening -Stage $Stage -InstalledDistribution $Distribution -UserName remote -IpAddress '172.19.1.101'
            Should -Invoke Get-LinuxScriptPath -Times 0 -Exactly
            Should -Invoke Invoke-RemoteScript -Times 0 -Exactly
        }
    }

    It 'propagates remote script errors' {
        InModuleScope $moduleName {
            Mock Invoke-RemoteScript { throw 'unsafe cleanup refused' }
            { Invoke-Debian13NodeHardening -Stage cleanup -InstalledDistribution debian13 -UserName remote -IpAddress '172.19.1.101' } |
                Should -Throw '*unsafe cleanup refused*'
        }
    }
}

Describe 'Debian13 hardening remote execution' -Tag 'unit', 'ci' {
    BeforeEach {
        InModuleScope $moduleName {
            Mock Write-Log {}
            Mock Test-Path { $true }
            Mock Copy-ToRemoteComputerViaUserAndPwd {}
            Mock Copy-ToRemoteComputerViaSshKey {}
            Mock Invoke-CmdOnControlPlaneViaUserAndPwd { [pscustomobject]@{ Success = $true; Output = '' } }
            Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $true; Output = '' } }
        }
    }

    It 'uses the selected transport and removes the script with password <Password>' -ForEach @(
        @{ Password = 'image-password' }
        @{ Password = '' }
    ) {
        InModuleScope $moduleName -Parameters @{ Password = $Password } {
            param($Password)
            Invoke-Debian13NodeHardening -Stage prepare -InstalledDistribution debian13 -UserName remote -IpAddress '172.19.1.101' -UserPwd $Password
            if ($Password) {
                Should -Invoke Copy-ToRemoteComputerViaUserAndPwd -Times 1 -Exactly -ParameterFilter { $UserPwd -eq $Password }
                Should -Invoke Copy-ToRemoteComputerViaSshKey -Times 0 -Exactly
                Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 0 -Exactly
                Should -Invoke Invoke-CmdOnControlPlaneViaUserAndPwd -Times 1 -Exactly -ParameterFilter {
                    $CmdToExecute -eq "chmod +x /tmp/harden-node.sh && /tmp/harden-node.sh 'prepare'" -and $Retries -eq 0 -and $RemoteUserPwd -eq $Password
                }
                Should -Invoke Invoke-CmdOnControlPlaneViaUserAndPwd -Times 1 -Exactly -ParameterFilter { $CmdToExecute -eq 'rm /tmp/harden-node.sh' }
            }
            else {
                Should -Invoke Copy-ToRemoteComputerViaSshKey -Times 1 -Exactly
                Should -Invoke Copy-ToRemoteComputerViaUserAndPwd -Times 0 -Exactly
                Should -Invoke Invoke-CmdOnControlPlaneViaUserAndPwd -Times 0 -Exactly
                Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly -ParameterFilter {
                    $CmdToExecute -eq "chmod +x /tmp/harden-node.sh && /tmp/harden-node.sh 'prepare'" -and $Retries -eq 0
                }
                Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly -ParameterFilter { $CmdToExecute -eq 'rm /tmp/harden-node.sh' }
            }
        }
    }

    It 'throws failed remote results with password <Password>' -ForEach @(
        @{ Password = 'image-password' }
        @{ Password = '' }
    ) {
        InModuleScope $moduleName -Parameters @{ Password = $Password } {
            param($Password)
            Mock Invoke-CmdOnControlPlaneViaUserAndPwd { [pscustomobject]@{ Success = $false; Output = 'unsafe cleanup refused' } } -ParameterFilter { $CmdToExecute -like 'chmod *' }
            Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $false; Output = 'unsafe cleanup refused' } } -ParameterFilter { $CmdToExecute -like 'chmod *' }

            { Invoke-Debian13NodeHardening -Stage cleanup -InstalledDistribution debian13 -UserName remote -IpAddress '172.19.1.101' -UserPwd $Password } |
                Should -Throw '*unsafe cleanup refused*'
        }
    }
}

Describe 'Debian13 shared image hardening order' -Tag 'unit', 'ci' {
    BeforeEach {
        InModuleScope $moduleName {
            $script:hardeningEvents = [System.Collections.Generic.List[string]]::new()
            $script:failedHardeningStage = ''
            Mock Write-Log {}
            Mock Get-VmIpForProvisioningKubeNode { '172.19.1.101' }
            Mock Get-DefaultUserNameKubeNode { 'remote' }
            Mock Get-DefaultUserPwdKubeNode { 'image-password' }
            Mock Get-IsValidIPv4Address { $true }
            Mock Test-Path { $true }
            Mock Get-LinuxScriptPath { 'C:\k2s\cfg\nodeextension\debian13\scripts' }
            Mock Copy-ToRemoteComputerViaUserAndPwd {}
            Mock Invoke-CmdOnVmViaSSHKey { throw 'image must use password authentication' }
            Mock Invoke-CmdOnControlPlaneViaUserAndPwd {
                if ($CmdToExecute -like 'chmod +x /tmp/harden-node.sh*') {
                    $stage = if ($CmdToExecute -like "*'prepare'") { 'prepare' } else { 'cleanup' }
                    $script:hardeningEvents.Add($stage)
                    if ($stage -eq $script:failedHardeningStage) {
                        return [pscustomobject]@{ Success = $false; Output = 'unsafe hardening refused' }
                    }
                }
                [pscustomobject]@{ Success = $true; Output = '' }
            }
            Mock New-KubenodeBaseImage {
                & $Hook
                $script:hardeningEvents.Add('seal')
            }
            Mock New-KubernetesNode { $script:hardeningEvents.Add('kubernetes') }
            Mock AddRegistryMirrors { $script:hardeningEvents.Add('mirrors') }
            Mock Get-KubernetesImages { $script:hardeningEvents.Add('images') }
            Mock Install-DnsServer { $script:hardeningEvents.Add('dns') }
            Mock Get-BuildahDebPackagesPath { '/tmp/buildah' }
            Mock Get-BuildahDebPackagesFromInternet {}
            Mock Install-BuildahDebPackages { $script:hardeningEvents.Add('buildah') }
            Mock Get-RegistryToken { 'test-token' }
            Mock Install-CliToolsOnKubeMaster { $script:hardeningEvents.Add('cli') }
            Mock Get-FlannelImages { $script:hardeningEvents.Add('flannel') }
            Mock Get-ClusterIPWebhookImages { $script:hardeningEvents.Add('webhook') }
            Mock Add-SupportForWSL { $script:hardeningEvents.Add('wsl') }
        }
    }

    It 'executes prepare before Kubernetes and cleanup after all additions before sealing' {
        InModuleScope $moduleName {
            New-VmImageForKubernetesNode -VmImageOutputPath 'C:\Temp\node.vhdx' -DnsIpAddresses '172.19.1.1'

            ($script:hardeningEvents -join ',') | Should -Be 'prepare,kubernetes,mirrors,images,dns,buildah,cli,flannel,webhook,wsl,cleanup,seal'
            Should -Invoke Invoke-CmdOnControlPlaneViaUserAndPwd -Times 0 -Exactly -ParameterFilter { $CmdToExecute -match 'apt-get autoremove' }
            Should -Invoke Invoke-CmdOnControlPlaneViaUserAndPwd -Times 2 -Exactly -ParameterFilter {
                $CmdToExecute -like 'chmod +x /tmp/harden-node.sh*' -and $RemoteUser -eq 'remote@172.19.1.101' -and
                $RemoteUserPwd -eq 'image-password' -and $Retries -eq 0
            }
        }
    }

    It 'does not seal when remote <Stage> fails' -ForEach @(
        @{ Stage = 'prepare' }
        @{ Stage = 'cleanup' }
    ) {
        InModuleScope $moduleName -Parameters @{ Stage = $Stage } {
            param($Stage)
            $script:failedHardeningStage = $Stage

            { New-VmImageForKubernetesNode -VmImageOutputPath 'C:\Temp\node.vhdx' -DnsIpAddresses '172.19.1.1' } |
                Should -Throw '*unsafe hardening refused*'

            $script:hardeningEvents | Should -Not -Contain 'seal'
            if ($Stage -eq 'prepare') {
                ($script:hardeningEvents -join ',') | Should -Be 'prepare'
                Should -Invoke New-KubernetesNode -Times 0 -Exactly
            }
            else {
                ($script:hardeningEvents -join ',') | Should -Be 'prepare,kubernetes,mirrors,images,dns,buildah,cli,flannel,webhook,wsl,cleanup'
            }
        }
    }
}

Describe 'Get-KubenodeNoProxy' -Tag 'unit', 'ci', 'proxy' {
    It 'derives K2s network entries from configured values' {
        InModuleScope $moduleName {
            Mock Get-ConfiguredIPControlPlane { '172.19.1.100' }
            Mock Get-ConfiguredKubeSwitchIP { '172.19.1.1' }
            Mock Get-ConfiguredClusterCIDR { '10.20.0.0/16' }
            Mock Get-ConfiguredClusterCIDRServices { '10.21.0.0/16' }
            Mock Get-ConfiguredKubeDnsServiceIP { '10.21.0.10' }

            $entries = (Get-KubenodeNoProxy) -split ','

            $entries | Should -Contain '172.19.1.100'
            $entries | Should -Contain '172.19.1.1'
            $entries | Should -Contain '10.20.0.0/16'
            $entries | Should -Contain '10.21.0.0/16'
            $entries | Should -Contain '10.21.0.10'
            $entries | Should -Contain '.cluster.local'
            $entries | Should -Contain '.svc'
        }
    }
}

Describe 'Assert-GeneralComputerPrerequisites' -Tag 'unit', 'ci', 'provisioning' {
    BeforeEach {
        Mock Write-Log {} -ModuleName $moduleName
        Mock Get-IsValidIPv4Address { $true } -ModuleName $moduleName
    }

    It 'requests bounded retries only for the read-only hostname command' {
        InModuleScope $moduleName {
            Mock Invoke-CmdOnControlPlaneViaUserAndPwd {
                [pscustomobject]@{ Success = $true; Output = 'kubenode' }
            }

            { Assert-GeneralComputerPrerequisites -UserName 'remote' -UserPwd 'fixture' -IpAddress '172.18.12.22' } | Should -Not -Throw

            Should -Invoke Invoke-CmdOnControlPlaneViaUserAndPwd -Times 1 -Exactly -ParameterFilter {
                $CmdToExecute -eq 'hostname' -and $RemoteUser -eq 'remote@172.18.12.22' -and
                $RemoteUserPwd -eq 'fixture' -and $Retries -eq 3 -and $Timeout -eq 3 -and -not $IgnoreErrors
            }
        }
    }

    It 'reports exhausted SSH failures instead of validating their output as hostnames' {
        InModuleScope $moduleName {
            Mock Invoke-CmdOnControlPlaneViaUserAndPwd {
                [pscustomobject]@{ Success = $false; Output = 'FATAL ERROR: Network error: Software caused connection abort' }
            }

            { Assert-GeneralComputerPrerequisites -UserName 'remote' -UserPwd 'fixture' -IpAddress '172.18.12.22' } |
                Should -Throw "*SSH command 'hostname' failed after retrying*Software caused connection abort*"
        }
    }

    It 'does not accept valid-looking output from an unsuccessful command' {
        InModuleScope $moduleName {
            Mock Invoke-CmdOnControlPlaneViaUserAndPwd {
                [pscustomobject]@{ Success = $false; Output = 'kubenode' }
            }

            { Assert-GeneralComputerPrerequisites -UserName 'remote' -UserPwd 'fixture' -IpAddress '172.18.12.22' } |
                Should -Throw "*SSH command 'hostname' failed*"
        }
    }

    It 'retains empty and invalid hostname validation after successful SSH' -ForEach @(
        @{ Hostname = ''; Message = '*could not be retrieved*' },
        @{ Hostname = 'InvalidName'; Message = '*contains not allowed characters*' }
    ) {
        InModuleScope $moduleName -Parameters @{ Hostname = $Hostname; Message = $Message } {
            param($Hostname, $Message)
            Mock Invoke-CmdOnControlPlaneViaUserAndPwd {
                [pscustomobject]@{ Success = $true; Output = $Hostname }
            }

            { Assert-GeneralComputerPrerequisites -UserName 'remote' -UserPwd 'fixture' -IpAddress '172.18.12.22' } |
                Should -Throw $Message
        }
    }
}

Describe 'Get-GpuContainerImages' -Tag 'unit', 'ci', 'gpu' {
    It 'reads the GPU addon manifest from the package root' {
        InModuleScope $moduleName {
            Mock Test-Path { return $false }

            { Get-GpuContainerImages -UserName 'admin' -UserPwd 'password' -IpAddress '172.19.1.101' } |
                Should -Throw '*GPU addon manifest not found at:*addons\gpu-node\addon.manifest.yaml'
        }
    }
}

Describe 'Invoke-RemoteScript' -Tag 'unit', 'ci', 'provisioning' {
    BeforeEach {
        Mock Write-Log {} -ModuleName $moduleName
        Mock Test-Path { $true } -ModuleName $moduleName
        Mock Copy-ToRemoteComputerViaSshKey {} -ModuleName $moduleName
        Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $true; Output = '' } } -ModuleName $moduleName
    }

    It 'passes every argument as a single-quoted shell word' {
        InModuleScope $moduleName {
            Invoke-RemoteScript -LocalScriptPath 'C:\k\setproxy.sh' -UserName 'remote' -IpAddress '172.19.1.100' -Arguments @('http://proxy:8080', 'two words', '')

            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly -ParameterFilter {
                $CmdToExecute -eq "chmod +x /tmp/setproxy.sh && /tmp/setproxy.sh 'http://proxy:8080' 'two words' ''"
            }
        }
    }

    It 'escapes single quotes so that an argument cannot inject shell commands' {
        InModuleScope $moduleName {
            Invoke-RemoteScript -LocalScriptPath 'C:\k\setproxy.sh' -UserName 'remote' -IpAddress '172.19.1.100' -Arguments @("http://x'; id; '")

            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly -ParameterFilter {
                $CmdToExecute -eq "chmod +x /tmp/setproxy.sh && /tmp/setproxy.sh 'http://x'\''; id; '\'''"
            }
        }
    }

    It 'runs the script without arguments when none are given' {
        InModuleScope $moduleName {
            Invoke-RemoteScript -LocalScriptPath 'C:\k\setproxy.sh' -UserName 'remote' -IpAddress '172.19.1.100'

            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly -ParameterFilter {
                $CmdToExecute -eq 'chmod +x /tmp/setproxy.sh && /tmp/setproxy.sh '
            }
        }
    }
}

Describe 'Get-CrioOfflineImageRetentionCommands' -Tag 'unit', 'ci' {
    It 'disables internal repair and installs a non-wiping pre-start hook' {
        InModuleScope $moduleName {
            $commands = @(Get-CrioOfflineImageRetentionCommands)
            $decode = { param($b64) [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
            $payloads = $commands | Where-Object { $_ -match "^echo '([^']+)' \| base64 -d" } | ForEach-Object {
                $null = $_ -match "^echo '([^']+)'"
                & $decode $Matches[1]
            }

            $payloads.Count | Should -Be 3
            ($payloads -join "`n") | Should -Not -Match "`r"
            $payloads[0] | Should -Match 'crio check --quick --repair --force'
            $payloads[0] | Should -Not -Match '--wipe'
            $payloads[0] | Should -Match 'exit 0'
            $payloads[1] | Should -Match 'internal_repair = false'
            $payloads[2] | Should -Match 'ExecStartPre=/usr/local/sbin/k2s-crio-precheck'
            $commands[-1] | Should -Be 'sudo systemctl daemon-reload'
        }
    }
}

Describe 'Set-CrioOfflineImageRetention' -Tag 'unit', 'ci' {
    It 'runs every retention command through the given script block' {
        InModuleScope $moduleName {
            Mock Write-Log {}
            $script:executed = [System.Collections.Generic.List[string]]::new()
            Set-CrioOfflineImageRetention -ExecuteRemoteCommand { param($Command) $script:executed.Add($Command) }

            $script:executed.Count | Should -Be @(Get-CrioOfflineImageRetentionCommands).Count
        }
    }
}

Describe 'Select-NewestImageRefs' -Tag 'unit', 'ci' {
    It 'keeps the highest version tag per image and handles tags without version components' {
        InModuleScope $moduleName {
            $refs = @(
                'docker.io/flannel/flannel:0.28.9', 'docker.io/flannel/flannel:v0.28.10',
                'docker.io/flannel/flannel-cni-plugin:v1.9.1-flannel3',
                'registry.k8s.io/etcd:3.6.8-0', 'registry.k8s.io/etcd:3.7.0-0',
                'registry.k8s.io/kube-apiserver:v1.37.3', 'registry.k8s.io/kube-apiserver:v1.36.4',
                'registry.k8s.io/pause:3.9', 'registry.k8s.io/pause:3.10.2',
                'registry.k8s.io/test:latest', 'registry.k8s.io/other:v1'
            )

            $expected = @(
                'docker.io/flannel/flannel-cni-plugin:v1.9.1-flannel3',
                'docker.io/flannel/flannel:v0.28.10',
                'registry.k8s.io/etcd:3.7.0-0',
                'registry.k8s.io/kube-apiserver:v1.37.3',
                'registry.k8s.io/pause:3.10.2',
                'registry.k8s.io/test:latest',
                'registry.k8s.io/other:v1'
            ) | Sort-Object

            @(Select-NewestImageRefs -ImageRefs $refs | Sort-Object) | Should -Be $expected
        }
    }
}

Describe 'Export-SystemImageArchivesToWindowsHost' -Tag 'unit', 'ci' {
    BeforeEach {
        InModuleScope $moduleName {
            Mock Write-Log {}
            Mock Copy-FromRemoteComputerViaSSHKey { 'x' | Set-Content $Target }
        }
    }

    It 'exports missing archives and removes only stale system archives' {
        $target = Join-Path $TestDrive 'images'
        New-Item -Path $target -ItemType Directory -Force | Out-Null
        'x' | Set-Content (Join-Path $target 'registry.k8s.io_kube-apiserver__v1.34.0.tar')
        'x' | Set-Content (Join-Path $target 'registry.k8s.io_kube-apiserver__v1.33.0.tar')
        'x' | Set-Content (Join-Path $target 'docker.io_myapp__1.0.tar')

        InModuleScope $moduleName -Parameters @{ Target = $target } {
            param($Target)
            Mock Invoke-CmdOnVmViaSSHKey {
                if ($CmdToExecute -like 'sudo crictl images*') {
                    return [pscustomobject]@{ Success = $true; Output = @('registry.k8s.io/kube-apiserver:v1.34.0', 'docker.io/flannel/flannel:v0.27.0') }
                }
                return [pscustomobject]@{ Success = $true; Output = '' }
            }

            Export-SystemImageArchivesToWindowsHost -TargetPath $Target

            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly -ParameterFilter {
                $CmdToExecute -like 'sudo crictl images*' -and $CmdToExecute -notmatch '"'
            }

            Should -Invoke Copy-FromRemoteComputerViaSSHKey -Times 1 -Exactly -ParameterFilter {
                $Target -like '*docker.io_flannel_flannel__v0.27.0.tar.partial'
            }
        }

        Test-Path (Join-Path $target 'docker.io_flannel_flannel__v0.27.0.tar') | Should -BeTrue
        Test-Path (Join-Path $target 'docker.io_flannel_flannel__v0.27.0.tar.partial') | Should -BeFalse
        Test-Path (Join-Path $target 'registry.k8s.io_kube-apiserver__v1.34.0.tar') | Should -BeTrue
        Test-Path (Join-Path $target 'registry.k8s.io_kube-apiserver__v1.33.0.tar') | Should -BeFalse
        Test-Path (Join-Path $target 'docker.io_myapp__1.0.tar') | Should -BeTrue
    }

    It 'archives every cached tag when old images remain on the node after an update' {
        $target = Join-Path $TestDrive 'images-after-update'
        New-Item -Path $target -ItemType Directory -Force | Out-Null
        'x' | Set-Content (Join-Path $target 'registry.k8s.io_kube-apiserver__v1.36.4.tar')

        InModuleScope $moduleName -Parameters @{ Target = $target } {
            param($Target)
            Mock Invoke-CmdOnVmViaSSHKey {
                if ($CmdToExecute -like 'sudo crictl images*') {
                    return [pscustomobject]@{ Success = $true; Output = @('registry.k8s.io/kube-apiserver:v1.36.4', 'registry.k8s.io/kube-apiserver:v1.37.3') }
                }
                return [pscustomobject]@{ Success = $true; Output = '' }
            }

            Export-SystemImageArchivesToWindowsHost -TargetPath $Target

            Should -Invoke Copy-FromRemoteComputerViaSSHKey -Times 1 -Exactly
        }

        @(Get-ChildItem -Path $target -Filter '*.tar' | Select-Object -ExpandProperty Name | Sort-Object) | Should -Be @(
            'registry.k8s.io_kube-apiserver__v1.36.4.tar',
            'registry.k8s.io_kube-apiserver__v1.37.3.tar'
        )
    }

    It 'throws when the image list cannot be read' {
        InModuleScope $moduleName -Parameters @{ Target = (Join-Path $TestDrive 'none') } {
            param($Target)
            Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $false; Output = '' } }
            { Export-SystemImageArchivesToWindowsHost -TargetPath $Target } | Should -Throw '*Could not list system images*'
        }
    }

    It 'publishes no archive when the image export fails' {
        $target = Join-Path $TestDrive 'images-pushfail'
        InModuleScope $moduleName -Parameters @{ Target = $target } {
            param($Target)
            Mock Invoke-CmdOnVmViaSSHKey {
                if ($CmdToExecute -like 'sudo crictl images*') {
                    return [pscustomobject]@{ Success = $true; Output = @('registry.k8s.io/pause:3.10') }
                }
                return [pscustomobject]@{ Success = $false; Output = 'push failed' }
            }

            { Export-SystemImageArchivesToWindowsHost -TargetPath $Target } | Should -Throw '*Could not export*'
            Should -Invoke Copy-FromRemoteComputerViaSSHKey -Times 0 -Exactly
        }

        @(Get-ChildItem -Path $target -File -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}
