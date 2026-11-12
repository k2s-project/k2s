# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    # Rename.ps1 runs the rename when invoked, so load only its function definitions
    $parseErrors = $null
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\Rename.ps1", [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    $renameFunctions = @($scriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $false))
    if ($renameFunctions.Count -eq 0) { throw 'Rename.ps1 defines no functions.' }
    . ([scriptblock]::Create(($renameFunctions.Extent.Text -join "`n")))
    function Invoke-Kubectl { param($Params) }
    function Invoke-CmdOnVmViaSSHKey { param($UserName, $IpAddress, $CmdToExecute, $ExecutionTimeoutSeconds) }
    function Invoke-CmdOnControlPlaneViaSSHKey { param($CmdToExecute) }
    function Copy-ToRemoteComputerViaSshKey { param($Source, $Target, $UserName, $IpAddress) }
    function Write-Log { param([Parameter(ValueFromPipeline)] $Message, [switch] $Console) }
    function Get-ClusterDescriptorFilePath {}
    function Update-NodeConfig { param($Name, $Updates) }
    function Get-NodeConfig { param($NodeName) }
    function Start-LinuxWorkerNode { param($NodeName, $IpAddress) }
    function Stop-LinuxWorkerNode { param($NodeName) }
}

Describe 'Linux worker rename lifecycle' -Tag 'unit', 'ci', 'node-rename' {
    BeforeEach {
        $script:events = [Collections.Generic.List[string]]::new()
        $script:old = @{
            metadata = @{
                name = 'old-node'; uid = 'old-uid'
                labels = @{ 'kubernetes.io/os' = 'linux'; team = 'test' }; annotations = @{}
            }
            spec = @{ podCIDR = '172.20.2.0/24'; podCIDRs = @('172.20.2.0/24'); unschedulable = $false }
            status = @{ conditions = @(@{ type = 'Ready'; status = 'Unknown' }); addresses = @(@{ type = 'InternalIP'; address = '192.0.2.2' }) }
        } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $script:ready = @{
            metadata = @{
                name = 'new-node'
                labels = @{ 'kubernetes.io/os' = 'linux' }
                annotations = @{
                    'k2s.io/rename-source-name' = 'old-node'; 'k2s.io/rename-source-uid' = 'old-uid'
                    'k2s.io/rename-original-unschedulable' = 'false'
                }
            }
            spec = @{ podCIDR = '172.20.2.0/24'; podCIDRs = @('172.20.2.0/24'); unschedulable = $true }
            status = @{ conditions = @(@{ type = 'Ready'; status = 'True' }); addresses = @(@{ type = 'InternalIP'; address = '192.0.2.2' }) }
        } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $script:nodeList = @($script:old)
        $script:managed = [pscustomobject]@{
            Name = 'old-node'; OS = 'linux'; Role = 'worker'; NodeType = 'VM-EXISTING'
            Username = 'admin'; IpAddress = '192.0.2.2'; PodCIDR = '172.20.2.0/24'; VmName = 'unchanged-vm'
        }
        $script:descriptorPath = Join-Path $TestDrive 'cluster.json'
        @{ nodes = @($script:managed) } | ConvertTo-Json -Depth 10 | Set-Content $script:descriptorPath
        Mock Get-ClusterDescriptorFilePath { $script:descriptorPath }
        Mock Write-Log {}
        Mock Invoke-NodeRenameKubectl {
            $script:events.Add(($Arguments -join ' '))
            if (($Arguments -join ' ') -eq 'get nodes -o json') {
                return @{ items = $script:nodeList } | ConvertTo-Json -Depth 30
            }
            if (($Arguments -join ' ') -eq 'get node new-node -o json') {
                return $script:ready | ConvertTo-Json -Depth 30
            }
            if ($Arguments[1] -eq 'pods') { return '{"items":[]}' }
        }
        Mock Invoke-NodeRenameRemote {
            if ($Script -eq 'hostname') { return 'new-node' }
            return 'unix:///run/crio/crio.sock'
        }
        Mock Restore-NodeRenameOldIdentity { $script:events.Add('restore-old') }
        Mock Stop-NodeRenameWorkloads { $script:events.Add('stop-workloads') }
        Mock Repair-NodeRenameCertificates { $script:events.Add('bootstrap') }
        Mock Assert-NodeRenameCertificate { $script:events.Add('verify-certificate') }
        Mock Invoke-NodeRenameObject {
            if ($Arguments[0] -eq 'create') {
                $script:events.Add('create')
                $script:created = $Object
            } else {
                $script:events.Add('delete-old')
                $Object.preconditions.uid | Should -Be 'old-uid'
            }
        }
        Mock Stop-LinuxWorkerNode { $script:events.Add('stop-routes') }
        Mock Start-LinuxWorkerNode { $script:events.Add('start-routes') }
        Mock Update-NodeConfig {
            $script:events.Add('persist')
            $script:managed.Name = $Updates.Name
        }
        Mock Get-NodeConfig { $script:managed }
        Mock Remove-NodeRenameFlagsBackup {}
    }

    It 'removes the temporary kubelet flags backup only after scheduling is restored' {
        Mock Remove-NodeRenameFlagsBackup { $script:events.Add('remove-flags-backup') }
        Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node'
        $script:events[$script:events.Count - 2] | Should -Be 'uncordon new-node'
        $script:events[$script:events.Count - 1] | Should -Be 'remove-flags-backup'
    }

    It 'keeps the temporary kubelet flags backup when the rename fails' {
        Mock Repair-NodeRenameCertificates { throw 'CSR approval failed' }
        { Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*CSR approval failed*'
        Should -Invoke Remove-NodeRenameFlagsBackup -Times 0
    }

    It 'reports but does not fail a completed rename when the backup cannot be removed' {
        Mock Remove-NodeRenameFlagsBackup { throw 'ssh unavailable' }
        { Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Not -Throw
        $script:events | Should -Contain 'delete-old'
        Should -Invoke Write-Log -Times 1 -ParameterFilter { $Message -like '*Could not remove*ssh unavailable*' -and $Console }
    }

    It 'cordons and gracefully drains before stopping workloads or bootstrapping certificates' {
        Invoke-LinuxWorkerRename -OldName 'OLD-NODE' -NewName 'NEW-NODE'
        $events = $script:events
        $cordon = $events.IndexOf('cordon old-node')
        $drain = @($events | Where-Object { $_ -like 'drain old-node *' })[0]
        $cordon | Should -BeGreaterThan -1
        $events.IndexOf('restore-old') | Should -BeGreaterThan $cordon
        $events.IndexOf($drain) | Should -BeGreaterThan $events.IndexOf('restore-old')
        $events.IndexOf('stop-workloads') | Should -BeGreaterThan $events.IndexOf($drain)
        $events.IndexOf('bootstrap') | Should -BeGreaterThan $events.IndexOf('stop-workloads')
        $events.IndexOf('verify-certificate') | Should -BeGreaterThan $events.IndexOf('bootstrap')
        $events.IndexOf('delete-old') | Should -BeGreaterThan $events.IndexOf('verify-certificate')
        $drain | Should -Match '--ignore-daemonsets --delete-emptydir-data'
        $drain | Should -Not -Match '--force|--disable-eviction'
        $events[$events.Count - 1] | Should -Be 'uncordon new-node'
        $script:created.spec.podCIDR | Should -Be '172.20.2.0/24'
        $script:created.spec.unschedulable | Should -BeTrue
        $script:managed.VmName | Should -Be 'unchanged-vm'
    }

    It 'never changes certificates or deletes the old node when drain is blocked' {
        Mock Invoke-NodeRenameKubectl { throw 'PDB blocks eviction' } -ParameterFilter { $Arguments[0] -eq 'drain' }
        { Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*draining old node*PDB blocks eviction*'
        Should -Invoke Repair-NodeRenameCertificates -Times 0
        Should -Invoke Stop-NodeRenameWorkloads -Times 0
        Should -Invoke Invoke-NodeRenameObject -Times 0
    }

    It 'leaves old identity and configuration intact on certificate bootstrap failure' {
        Mock Repair-NodeRenameCertificates { throw 'CSR approval failed' }
        { Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*bootstrapping new kubelet certificates*CSR approval failed*'
        Should -Invoke Update-NodeConfig -Times 0
        Should -Invoke Invoke-NodeRenameObject -Times 0 -ParameterFilter { $Arguments[0] -eq 'delete' }
    }

    It 'does not retire the old identity when certificate validation fails' {
        Mock Assert-NodeRenameCertificate { throw 'wrong certificate CN' }
        { Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*wrong certificate CN*'
        Should -Invoke Update-NodeConfig -Times 0
        Should -Invoke Invoke-NodeRenameObject -Times 0 -ParameterFilter { $Arguments[0] -eq 'delete' }
    }

    It 'rejects a hostname mismatch without cordoning or changing credentials' {
        Mock Invoke-NodeRenameRemote { 'different-host' } -ParameterFilter { $Script -eq 'hostname' }
        { Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*OS hostname*does not match*'
        Should -Invoke Restore-NodeRenameOldIdentity -Times 0
        Should -Invoke Invoke-NodeRenameKubectl -Times 0 -ParameterFilter { $Arguments[0] -eq 'cordon' }
    }

    It 'rejects a replacement name owned by a different node' {
        $script:ready.metadata.annotations.'k2s.io/rename-source-uid' = 'unrelated'
        $script:nodeList += $script:ready
        { Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*already in use*'
        Should -Invoke Restore-NodeRenameOldIdentity -Times 0
    }

    It 'reuses a verified Ready replacement without draining or bootstrapping again' {
        $script:nodeList += $script:ready
        Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node'
        Should -Invoke Restore-NodeRenameOldIdentity -Times 0
        Should -Invoke Repair-NodeRenameCertificates -Times 0
        Should -Invoke Assert-NodeRenameCertificate -Times 1
        $script:events | Should -Contain 'cordon new-node'
        $script:events | Should -Contain 'delete-old'
    }

    It 'preserves an originally cordoned worker across retries' {
        $script:old.metadata.annotations | Add-Member -NotePropertyName 'k2s.io/rename-original-unschedulable' -NotePropertyValue 'true'
        $script:ready.metadata.annotations.'k2s.io/rename-original-unschedulable' = 'true'
        Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node'
        $script:events[$script:events.Count - 1] | Should -Be 'cordon new-node'
    }

    It 'validates a drained checkpoint before retrying certificate bootstrap' {
        $script:old.metadata.annotations | Add-Member -NotePropertyName 'k2s.io/rename-drained' -NotePropertyValue 'true'
        Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node'
        Should -Invoke Restore-NodeRenameOldIdentity -Times 0
        Should -Invoke Stop-NodeRenameWorkloads -Times 1
        $script:events | Should -Contain 'get pods -A --field-selector=spec.nodeName=old-node -o json'
    }

    It 'refuses a previously drained worker that carries a new workload' {
        $script:old.metadata.annotations | Add-Member -NotePropertyName 'k2s.io/rename-drained' -NotePropertyValue 'true'
        Mock Invoke-NodeRenameKubectl { '{"items":[{"metadata":{"namespace":"db","name":"postgres"},"status":{"phase":"Running"}}]}' } `
            -ParameterFilter { $Arguments[1] -eq 'pods' }
        { Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*carries workload db/postgres*'
        Should -Invoke Repair-NodeRenameCertificates -Times 0
    }

    It 'refuses a control-plane node before changing services' {
        $script:old.metadata.labels | Add-Member -NotePropertyName 'node-role.kubernetes.io/control-plane' -NotePropertyValue ''
        { Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*not the expected managed Linux worker*'
        Should -Invoke Restore-NodeRenameOldIdentity -Times 0
    }

    It 'does not retire the old identity if secondary PodCIDRs changed' {
        $script:ready.spec.podCIDRs += 'fd00::/64'
        { Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*PodCIDRs do not match*'
        Should -Invoke Update-NodeConfig -Times 0
    }

    It 'finishes scheduling restoration when the old identity was already retired' {
        $script:nodeList = @($script:ready)
        $script:managed.Name = 'new-node'
        @{ nodes = @($script:managed) } | ConvertTo-Json -Depth 10 | Set-Content $script:descriptorPath
        Invoke-LinuxWorkerRename -OldName 'old-node' -NewName 'new-node'
        Should -Invoke Repair-NodeRenameCertificates -Times 0
        Should -Invoke Assert-NodeRenameCertificate -Times 1
        Should -Invoke Invoke-NodeRenameObject -Times 0
        $script:events[$script:events.Count - 1] | Should -Be 'uncordon new-node'
    }
}

Describe 'Node rename certificate and command helpers' -Tag 'unit', 'ci', 'node-rename' {
    BeforeEach {
        $script:nodeRenameDeadline = [DateTime]::UtcNow.AddMinutes(15)
        $script:target = [pscustomobject]@{ Username = 'admin'; IpAddress = '192.0.2.2' }
        Mock Write-Log {}
    }

    It 'requires the new client certificate CN and the system:nodes organization' {
        Mock Invoke-NodeRenameRemote { 'subject=O=system:nodes,CN=system:node:new-node' }
        { Assert-NodeRenameCertificate -Node $script:target -NewName 'new-node' } | Should -Not -Throw
    }

    It 'rejects a certificate belonging to another identity or organization' -ForEach @(
        @{ Subject = 'subject=O=system:nodes,CN=system:node:old-node' },
        @{ Subject = 'subject=O=system:nodes,CN=system:node:new-node-extra' },
        @{ Subject = 'subject=O=other,CN=system:node:new-node' }
    ) {
        Mock Invoke-NodeRenameRemote { $Subject }
        { Assert-NodeRenameCertificate -Node $script:target -NewName 'new-node' } | Should -Throw '*does not identify*'
    }

    It 'surfaces remote errors with bootstrap tokens redacted' {
        Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $false; ExitCode = 1; Output = 'failure token abcdef.0123456789abcdef' } }
        $failure = $null
        $token = ConvertTo-SecureString -String 'abcdef.0123456789abcdef' -AsPlainText -Force
        try {
            Invoke-NodeRenameRemote -Node $script:target -Script 'true' -Token $token
        } catch {
            $failure = $_
        } finally {
            $token.Dispose()
        }
        $failure | Should -Not -BeNullOrEmpty
        $failure.Exception.Message | Should -Match 'exit code 1.*failure token \[REDACTED\]'
        $failure.Exception.Message | Should -Not -Match 'abcdef\.0123456789abcdef'
    }

    It 'uses the existing certificate to restore the old name before restarting kubelet' {
        Mock Invoke-NodeRenameRemote {}
        Restore-NodeRenameOldIdentity -Node $script:target -OldName 'old-node'
        Should -Invoke Invoke-NodeRenameRemote -Times 1 -ParameterFilter {
            $Script -match 'openssl x509' -and $Script -match 'CN=system:node:old-node' -and
            $Script -match '--hostname-override=old-node' -and $Script -match 'systemctl restart kubelet' -and
            $Script -notmatch 'kubeadm reset|rm -rf'
        }
    }

    Describe 'Node rename credential bootstrap' -Tag 'unit', 'ci', 'node-rename' {
        BeforeEach {
            $script:nodeRenameDeadline = [DateTime]::UtcNow.AddMinutes(15)
            $script:target = [pscustomobject]@{ Username = 'admin'; IpAddress = '192.0.2.2' }
            $script:bootstrapConfiguration = $null
            $script:bootstrapScript = ''
            $script:temporaryConfigurationPath = ''
            Mock Write-Log {}
            Mock Invoke-CmdOnControlPlaneViaSSHKey {
                return [pscustomobject]@{
                    Success = $true
                    Output = "kubeadm join 192.0.2.1:6443 --token abcdef.0123456789abcdef --discovery-token-ca-cert-hash sha256:$('a' * 64)"
                }
            }
            Mock Invoke-CmdOnVmViaSSHKey {
                return [pscustomobject]@{ Success = $true; Output = '/tmp/k2s-node-rename.ABC123xy' }
            }
            Mock Copy-ToRemoteComputerViaSshKey {
                $script:temporaryConfigurationPath = $Source
                $script:bootstrapConfiguration = Get-Content -LiteralPath $Source -Raw | ConvertFrom-Json
            }
            Mock Invoke-NodeRenameRemote {
                $script:bootstrapScript = $Script
                return 'Certificate bootstrap complete'
            }
        }

        It 'bootstraps the requested name and runtime using a short-lived CA-pinned token without resetting the worker' {
            Repair-NodeRenameCertificates -Node $script:target -NewName 'new-node' -Socket 'unix:///run/crio/crio.sock'
            $script:bootstrapConfiguration.nodeRegistration.name | Should -Be 'new-node'
            $script:bootstrapConfiguration.nodeRegistration.criSocket | Should -Be 'unix:///run/crio/crio.sock'
            $script:bootstrapConfiguration.discovery.bootstrapToken.caCertHashes[0] | Should -Be "sha256:$('a' * 64)"
            $script:bootstrapScript | Should -Match 'kubeadm join phase kubelet-start --config'
            $script:bootstrapScript | Should -Match 'k2s-identity-backup'
            $script:bootstrapScript | Should -Match 'CN=system:node:new-node'
            $script:bootstrapScript | Should -Not -Match 'kubeadm reset|rm -rf|/etc/cni|/var/lib/containers'
            $script:bootstrapScript | Should -Not -Match 'abcdef\.0123456789abcdef'
            Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -ParameterFilter { $CmdToExecute -match '^sudo kubeadm token create --ttl \d+s --print-join-command$' }
            Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -ParameterFilter { $CmdToExecute -eq 'sudo kubeadm token delete abcdef' }
            Test-Path -LiteralPath $script:temporaryConfigurationPath | Should -BeFalse
        }

        It 'cleans temporary configuration and revokes the token even when bootstrap fails' {
            Mock Invoke-NodeRenameRemote { throw 'bootstrap refused' }
            { Repair-NodeRenameCertificates -Node $script:target -NewName 'new-node' -Socket 'unix:///run/containerd/containerd.sock' } |
                Should -Throw '*bootstrap refused*'
            Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -ParameterFilter { $CmdToExecute -eq 'sudo kubeadm token delete abcdef' }
            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -ParameterFilter { $CmdToExecute -like "rm -f -- '/tmp/k2s-node-rename.ABC123xy/join.json'*" }
            Test-Path -LiteralPath $script:temporaryConfigurationPath | Should -BeFalse
        }
    }

    It 'stops kubelet and pod sandboxes without assuming that stopping the runtime stops containers' {
        Mock Invoke-NodeRenameRemote {}
        Stop-NodeRenameWorkloads -Node $script:target -Socket 'unix:///run/crio/crio.sock'
        Should -Invoke Invoke-NodeRenameRemote -Times 1 -ParameterFilter {
            $Script -match 'systemctl stop kubelet' -and $Script -match 'crictl --runtime-endpoint.*stopp' -and
            $Script -notmatch 'systemctl stop crio|kubeadm reset'
        }
    }

    It 'removes only the temporary kubelet flags backup from the worker' {
        Mock Invoke-NodeRenameRemote {}
        Remove-NodeRenameFlagsBackup -Node $script:target
        Should -Invoke Invoke-NodeRenameRemote -Times 1 -ParameterFilter {
            $Script -match 'rm -f -- /var/lib/kubelet/k2s-rename-kubeadm-flags\.env' -and
            $Script -notmatch 'rm -rf|k2s-identity-backup|/var/lib/kubelet/kubeadm-flags\.env'
        }
    }

    It 'keeps user metadata and PodCIDRs but regenerates hostname and flannel metadata' {
        $old = @{
            metadata = @{
                name = 'old-node'; uid = 'old-uid'
                labels = @{ team = 'test'; 'kubernetes.io/hostname' = 'old-node'; 'kubernetes.io/role' = 'worker' }
                annotations = @{ 'custom.example/note' = 'keep'; 'flannel.alpha.coreos.com/public-ip' = '192.0.2.2' }
            }
            spec = @{
                podCIDR = '172.20.2.0/24'; podCIDRs = @('172.20.2.0/24')
                taints = @(@{ key = 'dedicated'; value = 'test'; effect = 'NoSchedule' }, @{ key = 'node.kubernetes.io/unreachable'; effect = 'NoExecute' })
            }
        } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $replacement = New-NodeRenameReplacement -OldNode $old -NewName 'new-node' -Unschedulable $false
        $replacement.metadata.labels.team | Should -Be 'test'
        $replacement.metadata.labels.ContainsKey('kubernetes.io/hostname') | Should -BeFalse
        $replacement.metadata.annotations.'custom.example/note' | Should -Be 'keep'
        $replacement.metadata.annotations.ContainsKey('flannel.alpha.coreos.com/public-ip') | Should -BeFalse
        $replacement.spec.taints.Count | Should -Be 1
        $replacement.spec.podCIDRs | Should -Be @('172.20.2.0/24')
    }
}
