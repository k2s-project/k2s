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
    function Invoke-CmdOnControlPlaneViaSSHKey { param($CmdToExecute, [switch] $IgnoreErrors, [switch] $NoLog, $ExecutionTimeoutSeconds) }
    function Copy-ToRemoteComputerViaSshKey { param($Source, $Target, $UserName, $IpAddress, $ExecutionTimeoutSeconds) }
    function Write-Log { param([Parameter(ValueFromPipeline)] $Message, [switch] $Console) }
    function Get-ClusterDescriptorFilePath {}
    function Update-NodeConfig { param($Name, $Updates) }
    function Get-NodeConfig { param($NodeName) }
    function Start-LinuxWorkerNode { param($NodeName, $IpAddress) }
    function Stop-LinuxWorkerNode { param($NodeName) }
    function Get-ConfigLinuxOnly {}
    function Get-KubeletConfigDir {}
    function Get-KubeBinPath {}
    function Get-KubePath {}
    function Send-ToCli { param($MessageType, $Message) }
    function New-Error { param($Severity, $Code, $Message) }
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
        # The control plane VM is a schedulable Linux node in K2s, so a Linux worker normally has another node for its pods
        $script:controlPlane = @{
            metadata = @{ name = 'kubemaster'; labels = @{ 'kubernetes.io/os' = 'linux'; 'node-role.kubernetes.io/control-plane' = '' }; annotations = @{} }
            spec = @{ podCIDR = '172.20.0.0/24' }
            status = @{ conditions = @(@{ type = 'Ready'; status = 'True' }); addresses = @(@{ type = 'InternalIP'; address = '192.0.2.1' }) }
        } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $script:nodeList = @($script:controlPlane, $script:old)
        $script:managed = [pscustomobject]@{
            Name = 'old-node'; OS = 'linux'; Role = 'worker'; NodeType = 'VM-EXISTING'
            Username = 'admin'; IpAddress = '192.0.2.2'; PodCIDR = '172.20.2.0/24'; VmName = 'unchanged-vm'
        }
        $script:descriptorPath = Join-Path $TestDrive 'cluster.json'
        @{ nodes = @($script:managed) } | ConvertTo-Json -Depth 10 | Set-Content $script:descriptorPath
        Mock Get-ClusterDescriptorFilePath { $script:descriptorPath }
        Mock Get-ConfigLinuxOnly { $false }
        Mock Write-Log {}
        Mock Invoke-NodeRenameKubectl {
            $script:events.Add(($Arguments -join ' '))
            if (($Arguments -join ' ') -eq 'get nodes -o json') {
                # The cluster no longer lists the old Node once it is deleted
                $nodes = @($script:nodeList | Where-Object { $script:events -notcontains 'delete-old' -or $_.metadata.name -ne 'old-node' })
                return @{ items = $nodes } | ConvertTo-Json -Depth 30
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
            } elseif ($Arguments[1] -eq '--raw=/api/v1/nodes/old-node') {
                $script:events.Add('delete-old')
                $Object.preconditions.uid | Should -Be 'old-uid'
            } else {
                $script:events.Add("delete-partial:$($Object.preconditions.uid)")
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
        Mock Get-NodeRenameControlPlaneRoute { $null }
        Mock Start-Sleep {}
    }

    It 'removes the temporary kubelet flags backup only after scheduling is restored' {
        Mock Remove-NodeRenameFlagsBackup { $script:events.Add('remove-flags-backup') }
        Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
        $script:events.IndexOf('remove-flags-backup') | Should -Be ($script:events.IndexOf('uncordon new-node') + 1)
    }

    It 'takes the old node out of flannel management right before deleting it, so the shared pod network route is kept' {
        Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
        $release = $script:events.IndexOf('annotate node old-node flannel.alpha.coreos.com/kube-subnet-manager-')
        $release | Should -BeGreaterThan $script:events.IndexOf('verify-certificate')
        $script:events.IndexOf('delete-old') | Should -Be ($release + 1)
    }

    It 'keeps the old node when it cannot be taken out of flannel management' {
        Mock Invoke-NodeRenameKubectl { throw 'annotate failed' } -ParameterFilter { $Arguments -contains 'flannel.alpha.coreos.com/kube-subnet-manager-' }
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*retiring old identity*annotate failed*'
        $script:events | Should -Not -Contain 'delete-old'
    }

    Context 'route of the control plane to the pod network of the worker' {
        BeforeEach {
            $script:routes = [Collections.Generic.Queue[object]]::new()
            Mock Get-NodeRenameControlPlaneRoute {
                $script:events.Add("read-route:$PodCIDR")
                if ($script:routes.Count) { $script:routes.Dequeue() }
            }
        }

        It 'reads the route before the old node is deleted and stays quiet when it is kept' {
            foreach ($route in '172.20.2.0/24 via 192.0.2.2 dev eth0', '172.20.2.0/24 via 192.0.2.2 dev eth0') { $script:routes.Enqueue($route) }
            Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
            $script:events.IndexOf('read-route:172.20.2.0/24') | Should -BeLessThan $script:events.IndexOf('delete-old')
            $script:events.LastIndexOf('read-route:172.20.2.0/24') | Should -BeGreaterThan $script:events.IndexOf('uncordon new-node')
            Should -Invoke Write-Log -Times 0 -ParameterFilter { $Message -like '*WARNING*' }
        }

        It 'completes the rename and warns when the control plane lost the route' {
            foreach ($route in '172.20.2.0/24 via 192.0.2.2 dev eth0', '') { $script:routes.Enqueue($route) }
            { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Not -Throw
            Should -Invoke Write-Log -Times 1 -ParameterFilter {
                $Console -and $Message -like '*WARNING: the control plane no longer has a route to the pod network 172.20.2.0/24 of new-node*'
            }
            Should -Invoke Write-Log -Times 1 -ParameterFilter { $Message -like '*Renamed old-node to new-node*' }
        }

        It 'does not check again when the control plane had no such route or could not be read' -ForEach @(
            @{ Before = '' }, @{ Before = $null }
        ) {
            $script:routes.Enqueue($Before)
            Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
            Should -Invoke Get-NodeRenameControlPlaneRoute -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0
            Should -Invoke Write-Log -Times 0 -ParameterFilter { $Message -like '*WARNING*' }
        }

        It 'does not warn when the route cannot be read afterwards' {
            foreach ($route in '172.20.2.0/24 via 192.0.2.2 dev eth0', $null) { $script:routes.Enqueue($route) }
            Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
            Should -Invoke Write-Log -Times 0 -ParameterFilter { $Message -like '*WARNING*' }
        }

        It 'does not read the route when the old node was already retired' {
            $script:nodeList = @($script:controlPlane, $script:ready)
            $script:managed.Name = 'new-node'
            @{ nodes = @($script:managed) } | ConvertTo-Json -Depth 10 | Set-Content $script:descriptorPath
            Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
            Should -Invoke Get-NodeRenameControlPlaneRoute -Times 0
        }
    }

    It 'removes its bookkeeping annotations from the replacement as the last change' {
        Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
        $changes = @($script:events | Where-Object { $_ -notlike 'get *' })
        $changes[$changes.Count - 1] |
            Should -Be 'annotate node new-node k2s.io/rename-source-uid- k2s.io/rename-source-name- k2s.io/rename-original-unschedulable-'
        $changes[$changes.Count - 2] | Should -Be 'uncordon new-node'
    }

    Context 'pod network range after the old node is retired' {
        BeforeEach {
            $script:joined = $script:controlPlane | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $script:joined.metadata.name = 'joined-node'
            $script:joined.metadata.labels = [pscustomobject]@{ 'kubernetes.io/os' = 'linux' }
            Mock Invoke-NodeRenameKubectl {
                $script:events.Add('read-nodes-after-retirement')
                @{ items = @($script:controlPlane, $script:ready, $script:joined) } | ConvertTo-Json -Depth 30
            } -ParameterFilter { ($Arguments -join ' ') -eq 'get nodes -o json' -and $script:events -contains 'delete-old' }
        }

        It 'fails the completed rename, names the Node that received the same range and says how to add it again' {
            $script:joined.spec.podCIDR = '172.20.2.0/24'
            { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw (
                "*failed while checking the pod network range: Pod network range conflict: Node 'joined-node' was assigned the pod network range 172.20.2.0/24, " +
                "but Node 'new-node' already uses 172.20.2.0/24. Remove it with 'k2s node remove --name joined-node' and add it again with 'k2s node add', " +
                'so that it receives a free range. The rename itself is complete and must not be retried.')
            $script:events | Should -Contain 'uncordon new-node'
            Should -Invoke Write-Log -Times 0 -ParameterFilter { $Message -like '*Renamed old-node to new-node*' }
        }

        It 'reads the Nodes only after its last change of the replacement and accepts a Node with another range' {
            $script:joined.spec.podCIDR = '172.20.3.0/24'
            Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
            $script:events.IndexOf('read-nodes-after-retirement') | Should -Be ($script:events.Count - 1)
            Should -Invoke Write-Log -Times 1 -ParameterFilter { $Message -like '*Renamed old-node to new-node*' }
        }
    }

    It 'ignores a scheduling marker left on a Node by an earlier rename' {
        $script:old.spec.unschedulable = $true
        $script:old.metadata.annotations | Add-Member -NotePropertyName 'k2s.io/rename-original-unschedulable' -NotePropertyValue 'false'
        $script:old.metadata.annotations | Add-Member -NotePropertyName 'k2s.io/rename-source-name' -NotePropertyValue 'older-node'
        Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
        $script:created.metadata.annotations.'k2s.io/rename-original-unschedulable' | Should -Be 'true'
    }

    It 'reports the PodCIDR, node type and preserved metadata' {
        $script:ready.metadata.labels | Add-Member -NotePropertyName 'team' -NotePropertyValue 'test'
        $script:ready.spec | Add-Member -NotePropertyName 'taints' -NotePropertyValue @(
            [pscustomobject]@{ key = 'dedicated'; value = 'test'; effect = 'NoSchedule' },
            [pscustomobject]@{ key = 'node.kubernetes.io/unschedulable'; effect = 'NoSchedule' })
        Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
        Should -Invoke Write-Log -Times 1 -ParameterFilter {
            $Console -and $Message -like '*Renamed old-node to new-node (linux worker, type VM-EXISTING); PodCIDR 172.20.2.0/24; Ready;*' -and
            $Message -like '*preserved labels: team=test; taints: dedicated=test:NoSchedule; unschedulable: false'
        }
    }

    It 'keeps the temporary kubelet flags backup when the rename fails' {
        Mock Repair-NodeRenameCertificates { throw 'CSR approval failed' }
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*CSR approval failed*'
        Should -Invoke Remove-NodeRenameFlagsBackup -Times 0
    }

    It 'reports but does not fail a completed rename when the backup cannot be removed' {
        Mock Remove-NodeRenameFlagsBackup { throw 'ssh unavailable' }
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Not -Throw
        $script:events | Should -Contain 'delete-old'
        Should -Invoke Write-Log -Times 1 -ParameterFilter { $Message -like '*Could not remove*ssh unavailable*' -and $Console }
    }

    It 'cordons and gracefully drains before stopping workloads or bootstrapping certificates' {
        Invoke-WorkerRename -OldName 'OLD-NODE' -NewName 'NEW-NODE'
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
        $events | Should -Contain 'uncordon new-node'
        $script:created.spec.podCIDR | Should -Be '172.20.2.0/24'
        $script:created.spec.unschedulable | Should -BeTrue
        $script:managed.VmName | Should -Be 'unchanged-vm'
    }

    It 'does not check disruption budgets when no other Linux node can run the pods, but still drains gracefully' {
        $script:nodeList = @($script:old)
        Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
        $drain = @($script:events | Where-Object { $_ -like 'drain old-node *' })
        $drain.Count | Should -Be 1
        $drain[0] | Should -Match '--ignore-daemonsets --delete-emptydir-data --disable-eviction --timeout='
        $drain[0] | Should -Not -Match '--force|--grace-period'
        Should -Invoke Write-Log -Times 1 -ParameterFilter { $Console -and $Message -like '*No other Ready linux node*PodDisruptionBudgets are not checked*' }
    }

    Context 'console output' {
        BeforeEach {
            $script:console = [Collections.Generic.List[string]]::new()
            Mock Write-Log { if ($Console) { $script:console.Add((([string]$Message) -replace '^\[NodeRename\] ', '')) } }
        }

        It 'names the Linux worker and reports every step in order' {
            Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
            $script:console[0..($script:console.Count - 2)] | Should -Be @(
                "Renaming Node 'old-node' to 'new-node'. Target: additional Linux worker on an existing VM (IP 192.0.2.2, SSH user admin, PodCIDR 172.20.2.0/24)",
                "The OS hostname of the target is 'new-node' and matches the new name",
                "Old Node 'old-node' is NotReady",
                "Cordoning old Node 'old-node'",
                "Restarting the kubelet under its old name 'old-node', so that the old Node can be drained",
                "Draining old Node 'old-node' (pod-local emptyDir data is deleted, persistent volumes are kept)",
                'Stopping the kubelet and the remaining containers on the worker',
                "Creating Node 'new-node' with PodCIDR 172.20.2.0/24",
                "Requesting a new kubelet certificate for 'new-node' on the worker",
                "Waiting for Node 'new-node' to become Ready",
                "Node 'new-node' is Ready and its kubelet certificate is issued for system:node:new-node",
                "Updating cluster.json and switching the routes of this host from 'old-node' to 'new-node'",
                "Deleting old Node 'old-node'",
                "Node 'new-node' is schedulable again")
            $script:console[$script:console.Count - 1] | Should -BeLike 'Renamed old-node to new-node (linux worker, type VM-EXISTING); PodCIDR 172.20.2.0/24; Ready;*'
        }

        It 'describes a worker on a physical host and a Ready old node' {
            $script:managed.NodeType = 'HOST'
            @{ nodes = @($script:managed) } | ConvertTo-Json -Depth 10 | Set-Content $script:descriptorPath
            $script:old.status.conditions[0].status = 'True'
            Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
            $script:console[0] | Should -BeLike '*Target: additional Linux worker on a physical host (IP 192.0.2.2,*'
            $script:console | Should -Contain "Old Node 'old-node' is Ready"
        }

        It 'shows the target before it rejects a hostname that does not match' {
            Mock Invoke-NodeRenameRemote { 'different-host' } -ParameterFilter { $Script -eq 'hostname' }
            { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*does not match*'
            $script:console.Count | Should -Be 1
            $script:console[0] | Should -BeLike "Renaming Node 'old-node' to 'new-node'. Target: additional Linux worker*"
        }

        It 'explains a self-registered replacement and the effect of --force' {
            $partial = $script:ready | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $partial.metadata | Add-Member -NotePropertyName 'uid' -NotePropertyValue 'partial-uid'
            $partial.metadata.annotations = [pscustomobject]@{}
            $partial.spec.podCIDR = '172.20.9.0/24'
            $script:nodeList += $partial
            Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' -Force
            $script:console | Should -Contain "Node 'new-node' was registered by the machine itself with PodCIDR '172.20.9.0/24'; it is replaced by a Node with PodCIDR 172.20.2.0/24"
            $script:console | Should -Contain "--force: workloads on Node 'new-node' are not checked"
            $script:console.IndexOf("Deleting the Node 'new-node' that the machine registered itself") |
                Should -Be ($script:console.IndexOf("Creating Node 'new-node' with PodCIDR 172.20.2.0/24") - 1)
        }

        It 'says when a replacement of an earlier attempt is reused and the drain is skipped' {
            $script:nodeList += $script:ready
            Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
            $script:console | Should -Contain "Node 'new-node' was created by an earlier attempt of this command and is reused"
            $script:console | Should -Contain "Node 'new-node' is already Ready; drain and certificate replacement were completed by an earlier attempt"
            $script:console | Should -Not -Contain "Draining old Node 'old-node' (pod-local emptyDir data is deleted, persistent volumes are kept)"
        }

        It 'says when the drain of an earlier attempt is not repeated and the node stays cordoned' {
            $script:old.metadata.annotations | Add-Member -NotePropertyName 'k2s.io/rename-drained' -NotePropertyValue 'true'
            $script:ready.metadata.annotations.'k2s.io/rename-original-unschedulable' = 'true'
            Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
            $script:console | Should -Contain "Old Node 'old-node' was already drained by an earlier attempt; the drain is not repeated"
            $script:console | Should -Contain "Node 'new-node' stays cordoned, as the old Node was before the rename"
            $script:console | Should -Not -Contain "Node 'new-node' is schedulable again"
        }

        It 'says when an earlier rename is only finished' {
            $script:nodeList = @($script:controlPlane, $script:ready)
            $script:managed.Name = 'new-node'
            @{ nodes = @($script:managed) } | ConvertTo-Json -Depth 10 | Set-Content $script:descriptorPath
            Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
            $script:console | Should -Contain "Old Node 'old-node' is already removed and Node 'new-node' is Ready; finishing the earlier rename"
            $script:console | Should -Not -Contain "Deleting old Node 'old-node'"
        }
    }

    It 'limits the whole rename to the given timeout' {
        Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' -TimeoutSeconds 120
        $waits = @($script:events | Where-Object { $_ -match '--timeout=(\d+)s$' } | ForEach-Object { [int]([regex]::Match($_, '--timeout=(\d+)s$').Groups[1].Value) })
        $waits.Count | Should -BeGreaterThan 2
        ($waits | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 120
        ($waits | Measure-Object -Minimum).Minimum | Should -BeGreaterThan 100
    }

    It 'stops and keeps the old node when the timeout is reached during the rename' {
        Mock Restore-NodeRenameOldIdentity { $script:nodeRenameDeadline = [DateTime]::UtcNow.AddSeconds(-1) }
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } |
            Should -Throw '*failed while restoring old kubelet identity for graceful drain: Repair timed out. Nodes may remain cordoned*'
        Should -Invoke Repair-NodeRenameCertificates -Times 0
        $script:events | Should -Not -Contain 'delete-old'
    }

    It 'never changes certificates or deletes the old node when drain is blocked' {
        Mock Invoke-NodeRenameKubectl { throw 'PDB blocks eviction' } -ParameterFilter { $Arguments[0] -eq 'drain' }
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*draining old node*PDB blocks eviction*'
        Should -Invoke Repair-NodeRenameCertificates -Times 0
        Should -Invoke Stop-NodeRenameWorkloads -Times 0
        Should -Invoke Invoke-NodeRenameObject -Times 0
    }

    It 'leaves old identity and configuration intact on certificate bootstrap failure' {
        Mock Repair-NodeRenameCertificates { throw 'CSR approval failed' }
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*bootstrapping new kubelet certificates*CSR approval failed*'
        Should -Invoke Update-NodeConfig -Times 0
        Should -Invoke Invoke-NodeRenameObject -Times 0 -ParameterFilter { $Arguments[0] -eq 'delete' }
    }

    It 'does not retire the old identity when certificate validation fails' {
        Mock Assert-NodeRenameCertificate { throw 'wrong certificate CN' }
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*wrong certificate CN*'
        Should -Invoke Update-NodeConfig -Times 0
        Should -Invoke Invoke-NodeRenameObject -Times 0 -ParameterFilter { $Arguments[0] -eq 'delete' }
    }

    It 'rejects a hostname mismatch before changing any service or Kubernetes resource' {
        Mock Invoke-NodeRenameRemote { 'different-host' } -ParameterFilter { $Script -eq 'hostname' }
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw "*failed while validating target: OS hostname 'different-host' does not match 'new-node'. No changes were made."
        Should -Invoke Restore-NodeRenameOldIdentity -Times 0
        Should -Invoke Invoke-NodeRenameKubectl -Times 0 -ParameterFilter { $Arguments[0] -ne 'get' }
        Should -Invoke Invoke-NodeRenameObject -Times 0
        Should -Invoke Invoke-NodeRenameRemote -Times 1 -Exactly
        Should -Invoke Update-NodeConfig -Times 0
    }

    It 'accepts a hostname that differs from the new name only in case' {
        Mock Invoke-NodeRenameRemote { 'New-Node' } -ParameterFilter { $Script -eq 'hostname' }
        Invoke-WorkerRename -OldName 'old-node' -NewName 'NEW-NODE'
        $script:created.metadata.name | Should -BeExactly 'new-node'
        $script:events | Should -Contain 'delete-old'
    }

    It 'rejects a replacement name that belongs to a different machine' {
        $script:ready.metadata.annotations.'k2s.io/rename-source-uid' = 'unrelated'
        $script:ready.status.addresses[0].address = '192.0.2.99'
        $script:nodeList += $script:ready
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*already in use*'
        Should -Invoke Restore-NodeRenameOldIdentity -Times 0
        Should -Invoke Invoke-NodeRenameKubectl -Times 0 -ParameterFilter { $Arguments[0] -eq 'cordon' }
    }

    It 'rejects a replacement that runs a different operating system' {
        $script:ready.metadata.annotations.'k2s.io/rename-source-uid' = 'unrelated'
        $script:ready.metadata.labels.'kubernetes.io/os' = 'windows'
        $script:nodeList += $script:ready
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*already in use*'
    }

    Context 'partially registered replacement of the same machine' {
        BeforeEach {
            $script:partial = $script:ready | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $script:partial.metadata | Add-Member -NotePropertyName 'uid' -NotePropertyValue 'partial-uid'
            $script:partial.metadata.annotations = [pscustomobject]@{}
            $script:partial.spec.podCIDR = '172.20.9.0/24'
            $script:partial.status.conditions[0].status = 'False'
            $script:nodeList += $script:partial
        }

        It 'deletes it after the old node is drained and recreates it with the old PodCIDR' {
            Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
            $events = $script:events
            $events.IndexOf('cordon new-node') | Should -BeGreaterThan -1
            $events.IndexOf('delete-partial:partial-uid') | Should -BeGreaterThan $events.IndexOf('stop-workloads')
            $events.IndexOf('create') | Should -BeGreaterThan $events.IndexOf('delete-partial:partial-uid')
            $events.IndexOf('bootstrap') | Should -BeGreaterThan $events.IndexOf('create')
            $script:created.spec.podCIDR | Should -Be '172.20.2.0/24'
        }

        It 'refuses when it carries a workload and names the recovery option' {
            Mock Invoke-NodeRenameKubectl { '{"items":[{"metadata":{"namespace":"db","name":"postgres"},"status":{"phase":"Running"}}]}' } `
                -ParameterFilter { $Arguments[1] -eq 'pods' }
            { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*carries workload db/postgres*--force*'
            Should -Invoke Restore-NodeRenameOldIdentity -Times 0
            Should -Invoke Invoke-NodeRenameObject -Times 0
        }

        It 'ignores DaemonSet and finished pods when checking for workloads' {
            Mock Invoke-NodeRenameKubectl {
                @{ items = @(
                        @{ metadata = @{ namespace = 'kube-system'; name = 'kube-proxy-x'; ownerReferences = @(@{ kind = 'DaemonSet'; controller = $true }) }; status = @{ phase = 'Running' } },
                        @{ metadata = @{ namespace = 'jobs'; name = 'done' }; status = @{ phase = 'Succeeded' } }) } | ConvertTo-Json -Depth 10
            } -ParameterFilter { $Arguments[1] -eq 'pods' }
            Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
            $script:events | Should -Contain 'delete-partial:partial-uid'
        }

        It 'deletes it together with its workloads when forced' {
            Mock Invoke-NodeRenameKubectl { '{"items":[{"metadata":{"namespace":"db","name":"postgres"},"status":{"phase":"Running"}}]}' } `
                -ParameterFilter { $Arguments[1] -eq 'pods' -and $Arguments[3] -eq '--field-selector=spec.nodeName=new-node' }
            Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' -Force
            $script:events | Should -Contain 'delete-partial:partial-uid'
            $script:events | Should -Contain 'create'
        }
    }

    It 'reuses a verified Ready replacement without draining or bootstrapping again' {
        $script:nodeList += $script:ready
        Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
        Should -Invoke Restore-NodeRenameOldIdentity -Times 0
        Should -Invoke Repair-NodeRenameCertificates -Times 0
        Should -Invoke Assert-NodeRenameCertificate -Times 1
        $script:events | Should -Contain 'cordon new-node'
        $script:events | Should -Contain 'delete-old'
    }

    It 'keeps the original scheduling state when a retry finds the old node already cordoned' {
        $script:old.spec.unschedulable = $true
        $script:old.metadata.annotations | Add-Member -NotePropertyName 'k2s.io/rename-original-unschedulable' -NotePropertyValue 'false'
        Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
        $script:created.metadata.annotations.'k2s.io/rename-original-unschedulable' | Should -Be 'false'
        $script:events | Should -Contain 'annotate node old-node k2s.io/rename-original-unschedulable=false --overwrite'
    }

    It 'restores the scheduling state recorded on the replacement' {
        $script:ready.metadata.annotations.'k2s.io/rename-original-unschedulable' = 'true'
        Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
        $script:events | Should -Contain 'cordon new-node'
        $script:events | Should -Not -Contain 'uncordon new-node'
    }

    It 'validates a drained checkpoint before retrying certificate bootstrap' {
        $script:old.metadata.annotations | Add-Member -NotePropertyName 'k2s.io/rename-drained' -NotePropertyValue 'true'
        Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
        Should -Invoke Restore-NodeRenameOldIdentity -Times 0
        Should -Invoke Stop-NodeRenameWorkloads -Times 1
        $script:events | Should -Contain 'get pods -A --field-selector=spec.nodeName=old-node -o json'
    }

    It 'refuses a previously drained worker that carries a new workload' {
        $script:old.metadata.annotations | Add-Member -NotePropertyName 'k2s.io/rename-drained' -NotePropertyValue 'true'
        Mock Invoke-NodeRenameKubectl { '{"items":[{"metadata":{"namespace":"db","name":"postgres"},"status":{"phase":"Running"}}]}' } `
            -ParameterFilter { $Arguments[1] -eq 'pods' }
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*carries workload db/postgres*'
        Should -Invoke Repair-NodeRenameCertificates -Times 0
    }

    It 'refuses a control-plane node before changing services' {
        $script:old.metadata.labels | Add-Member -NotePropertyName 'node-role.kubernetes.io/control-plane' -NotePropertyValue ''
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*is a control-plane Node*'
        Should -Invoke Restore-NodeRenameOldIdentity -Times 0
        Should -Invoke Invoke-NodeRenameKubectl -Times 0 -ParameterFilter { $Arguments[0] -eq 'cordon' }
    }

    It 'refuses an old node that does not exist and states that nothing was changed' {
        $script:nodeList = @()
        $failure = $null
        try { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } catch { $failure = $_.Exception.Message }
        $failure | Should -BeExactly '[NodeRename] Rename old-node -> new-node failed while validating target: Old node is missing and a completed replacement cannot be verified. No changes were made.'
        Should -Invoke Invoke-NodeRenameKubectl -Times 0 -ParameterFilter { $Arguments[0] -eq 'cordon' }
    }

    It 'says that nodes may remain cordoned only once something was changed' {
        Mock Invoke-NodeRenameKubectl { throw '[NodeRename] kubectl drain failed: PDB blocks eviction.' } -ParameterFilter { $Arguments[0] -eq 'drain' }
        $failure = $null
        try { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } catch { $failure = $_.Exception.Message }
        $failure | Should -BeExactly ('[NodeRename] Rename old-node -> new-node failed while draining old node: kubectl drain failed: PDB blocks eviction. ' +
            "Nodes may remain cordoned; the old Node 'old-node' still exists. Inspect target services before retrying the same command.")
    }

    It 'says that the old node may already be deleted when retiring it fails' {
        Mock Invoke-NodeRenameKubectl { throw 'connection lost' } -ParameterFilter { $Arguments[0] -eq 'wait' -and $Arguments[1] -eq '--for=delete' -and $Arguments[2] -eq 'node/old-node' }
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } |
            Should -Throw "*failed while retiring old identity: connection lost. Nodes may remain cordoned; the old Node 'old-node' may already be deleted. Inspect target services*"
    }

    It 'says that the old node is deleted and a retry finishes the rename when only the last steps fail' {
        Mock Invoke-NodeRenameKubectl { throw 'connection lost' } -ParameterFilter { $Arguments[0] -eq 'uncordon' }
        $failure = $null
        try { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } catch { $failure = $_.Exception.Message }
        $failure | Should -BeExactly ("[NodeRename] Rename old-node -> new-node failed while restoring scheduling: connection lost. " +
            "Node 'new-node' may remain cordoned; the old Node 'old-node' is already deleted. Retry the same command to finish.")
        $script:events | Should -Contain 'delete-old'
    }

    It 'says that the old node is deleted when finishing an earlier rename fails' {
        $script:nodeList = @($script:controlPlane, $script:ready)
        $script:managed.Name = 'new-node'
        @{ nodes = @($script:managed) } | ConvertTo-Json -Depth 10 | Set-Content $script:descriptorPath
        Mock Assert-NodeRenameCertificate { throw 'wrong certificate CN' }
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } |
            Should -Throw "*failed while validating replacement identity: wrong certificate CN. Node 'new-node' may remain cordoned; the old Node 'old-node' is already deleted. Retry*"
    }

    It 'reports a failure of the first change as a change' {
        Mock Invoke-NodeRenameKubectl { throw 'connection refused' } -ParameterFilter { $Arguments[0] -eq 'annotate' }
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*failed while cordoning nodes: connection refused. Nodes may remain cordoned*'
    }

    It 'refuses an old node without a PodCIDR' {
        $script:old.spec.podCIDR = ''
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*has no PodCIDR*'
        Should -Invoke Invoke-NodeRenameKubectl -Times 0 -ParameterFilter { $Arguments[0] -eq 'cordon' }
    }

    It 'does not retire the old identity if secondary PodCIDRs changed' {
        $script:ready.spec.podCIDRs += 'fd00::/64'
        { Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node' } | Should -Throw '*PodCIDRs do not match*'
        Should -Invoke Update-NodeConfig -Times 0
    }

    It 'finishes scheduling restoration when the old identity was already retired' {
        $script:nodeList = @($script:ready)
        $script:managed.Name = 'new-node'
        @{ nodes = @($script:managed) } | ConvertTo-Json -Depth 10 | Set-Content $script:descriptorPath
        Invoke-WorkerRename -OldName 'old-node' -NewName 'new-node'
        Should -Invoke Repair-NodeRenameCertificates -Times 0
        Should -Invoke Assert-NodeRenameCertificate -Times 1
        Should -Invoke Invoke-NodeRenameObject -Times 0
        $script:events | Should -Contain 'uncordon new-node'
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

        It 'gives the token creation and the upload only the time that is left, and the token revocation its own short limit' {
            $script:nodeRenameDeadline = [DateTime]::UtcNow.AddSeconds(90)
            Repair-NodeRenameCertificates -Node $script:target -NewName 'new-node' -Socket 'unix:///run/crio/crio.sock'
            Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -Exactly -ParameterFilter {
                $CmdToExecute -like 'sudo kubeadm token create*' -and $ExecutionTimeoutSeconds -ge 85 -and $ExecutionTimeoutSeconds -le 90
            }
            Should -Invoke Copy-ToRemoteComputerViaSshKey -Times 1 -Exactly -ParameterFilter {
                $ExecutionTimeoutSeconds -ge 85 -and $ExecutionTimeoutSeconds -le 90
            }
            Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -Exactly -ParameterFilter {
                $CmdToExecute -like 'sudo kubeadm token delete*' -and $ExecutionTimeoutSeconds -eq 30
            }
        }

        It 'still revokes the token within its own limit when the upload used up the time' {
            Mock Copy-ToRemoteComputerViaSshKey {
                $script:nodeRenameDeadline = [DateTime]::UtcNow.AddSeconds(-1)
                throw '[SCP] Copying timed out'
            }
            { Repair-NodeRenameCertificates -Node $script:target -NewName 'new-node' -Socket 'unix:///run/crio/crio.sock' } |
                Should -Throw '*Copying timed out*'
            Should -Invoke Invoke-NodeRenameRemote -Times 0
            Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -Exactly -ParameterFilter {
                $CmdToExecute -eq 'sudo kubeadm token delete abcdef' -and $ExecutionTimeoutSeconds -eq 30
            }
            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly -ParameterFilter {
                $CmdToExecute -like "rm -f -- '/tmp/k2s-node-rename.ABC123xy/join.json'*" -and $ExecutionTimeoutSeconds -eq 10
            }
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

Describe 'Rename timeout' -Tag 'unit', 'ci', 'node-rename' {
    BeforeEach {
        Mock Write-Log {}
        Mock Invoke-Kubectl { [pscustomobject]@{ Success = $true; Output = 'ok' } }
    }

    It 'gives every cluster call only the time that is left' {
        $script:nodeRenameDeadline = [DateTime]::UtcNow.AddSeconds(90)
        Invoke-NodeRenameKubectl @('get', 'nodes') | Should -Be 'ok'
        Should -Invoke Invoke-Kubectl -Times 1 -Exactly -ParameterFilter {
            $Params[0] -match '^--request-timeout=(\d+)s$' -and [int]$Matches[1] -le 90 -and [int]$Matches[1] -ge 85 -and
            $Params[1] -eq 'get' -and $Params[2] -eq 'nodes'
        }
    }

    It 'stops with a timeout error and makes no further cluster call once the time is used up' {
        $script:nodeRenameDeadline = [DateTime]::UtcNow.AddSeconds(-1)
        { Get-NodeRenameRemainingSeconds } | Should -Throw '*Repair timed out*'
        { Invoke-NodeRenameKubectl @('cordon', 'old-node') } | Should -Throw '*Repair timed out*'
        Should -Invoke Invoke-Kubectl -Times 0
    }

    It 'does not start a remote step on the worker once the time is used up' {
        $script:nodeRenameDeadline = [DateTime]::UtcNow.AddSeconds(-1)
        Mock Invoke-CmdOnVmViaSSHKey {}
        { Invoke-NodeRenameRemote -Node ([pscustomobject]@{ Username = 'admin'; IpAddress = '192.0.2.2' }) -Script 'hostname' } | Should -Throw '*Repair timed out*'
        Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 0
    }

    It 'waits for a Windows service at most <Max> seconds when <Left> seconds are left' -ForEach @(
        @{ Left = 20; Min = 15; Max = 20 },
        @{ Left = 600; Min = 60; Max = 60 }
    ) {
        $script:nodeRenameDeadline = [DateTime]::UtcNow.AddSeconds($Left)
        $script:serviceWait = $null
        Mock Get-Service {
            [pscustomobject]@{ Name = "$Name" } |
                Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($Status, $Timeout) $script:serviceWait = "$Status", $Timeout } -PassThru
        }
        Wait-NodeRenameWindowsService -Name 'kubelet'
        $script:serviceWait[0] | Should -Be 'Running'
        $script:serviceWait[1].TotalSeconds | Should -BeGreaterOrEqual $Min
        $script:serviceWait[1].TotalSeconds | Should -BeLessOrEqual $Max
    }

    It 'does not wait for a Windows service once the time is used up' {
        $script:nodeRenameDeadline = [DateTime]::UtcNow.AddSeconds(-1)
        Mock Get-Service {}
        { Wait-NodeRenameWindowsService -Name 'kubelet' } | Should -Throw '*Repair timed out*'
        Should -Invoke Get-Service -Times 0
    }
}

Describe 'Rename command result for the CLI' -Tag 'unit', 'ci', 'node-rename' {
    BeforeEach {
        $script:savedKubeconfig = $env:KUBECONFIG
        $script:root = Join-Path $TestDrive "install-$([guid]::NewGuid().ToString('N'))"
        New-Item -Path $script:root -ItemType Directory | Out-Null
        Set-Content -Path (Join-Path $script:root 'config') -Value 'kubeconfig'
        $script:sent = [Collections.Generic.List[object]]::new()
        Mock Get-KubePath { $script:root }
        Mock Write-Log {}
        Mock New-Error { [pscustomobject]@{ Severity = "$Severity"; Code = $Code; Message = $Message } }
        Mock Send-ToCli { $script:sent.Add([pscustomobject]@{ MessageType = $MessageType; Message = $Message }) }
        Mock Invoke-WorkerRename {}
    }

    AfterEach {
        $env:KUBECONFIG = $script:savedKubeconfig
    }

    It 'reports a failed rename to the CLI as an error instead of ending quietly' {
        Mock Invoke-WorkerRename { throw "[NodeRename] Rename a -> b failed while validating target: Node 'a' does not exist. No changes were made." }
        { Invoke-WorkerRenameCommand -OldName 'a' -NewName 'b' -EncodeStructuredOutput -MessageType 'CmdResult' } | Should -Not -Throw
        $script:sent.Count | Should -Be 1
        $script:sent[0].MessageType | Should -Be 'CmdResult'
        $script:sent[0].Message.Error.Severity | Should -Be 'Error'
        $script:sent[0].Message.Error.Code | Should -Be 'node-rename-failed'
        $script:sent[0].Message.Error.Message | Should -BeExactly "Rename a -> b failed while validating target: Node 'a' does not exist. No changes were made."
        Should -Invoke Write-Log -Times 1 -ParameterFilter { $Message -like '`[NodeRename`] Rename a -> b failed*' -and $Message -notlike '*`[NodeRename`]*`[NodeRename`]*' }
    }

    It 'reports a completed rename to the CLI without an error' {
        Invoke-WorkerRenameCommand -OldName 'a' -NewName 'b' -EncodeStructuredOutput -MessageType 'CmdResult'
        $script:sent.Count | Should -Be 1
        $script:sent[0].MessageType | Should -Be 'CmdResult'
        $script:sent[0].Message.ContainsKey('Error') | Should -BeTrue
        $script:sent[0].Message.Error | Should -BeNullOrEmpty
    }

    It 'fails with a terminating error when it is run without the CLI' {
        Mock Invoke-WorkerRename { throw '[NodeRename] Rename a -> b failed while draining old node: blocked.' }
        { Invoke-WorkerRenameCommand -OldName 'a' -NewName 'b' } | Should -Throw '*failed while draining old node: blocked*'
        $script:sent.Count | Should -Be 0
    }

    It 'sends nothing after a completed rename that is run without the CLI' {
        Invoke-WorkerRenameCommand -OldName 'a' -NewName 'b'
        $script:sent.Count | Should -Be 0
    }

    It 'reports a missing installation kubeconfig as a failure and does not start the rename' {
        Remove-Item -LiteralPath (Join-Path $script:root 'config')
        Invoke-WorkerRenameCommand -OldName 'a' -NewName 'b' -EncodeStructuredOutput -MessageType 'CmdResult'
        $script:sent[0].Message.Error.Message | Should -BeExactly 'The installation kubeconfig is missing'
        Should -Invoke Invoke-WorkerRename -Times 0
    }

    It 'passes the names, timeout and force option on and uses the installation kubeconfig' {
        Invoke-WorkerRenameCommand -OldName 'OLD' -NewName 'NEW' -TimeoutSeconds 120 -Force
        Should -Invoke Invoke-WorkerRename -Times 1 -Exactly -ParameterFilter { $OldName -eq 'OLD' -and $NewName -eq 'NEW' -and $TimeoutSeconds -eq 120 -and $Force }
        $env:KUBECONFIG | Should -Be (Join-Path $script:root 'config')
    }
}

Describe 'Control plane route check' -Tag 'unit', 'ci', 'node-rename' {
    It 'only reads the route and returns it trimmed' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey { [pscustomobject]@{ Success = $true; Output = @('172.20.2.0/24 via 192.0.2.2 dev eth0 ', '') } }
        Get-NodeRenameControlPlaneRoute -PodCIDR '172.20.2.0/24' | Should -BeExactly '172.20.2.0/24 via 192.0.2.2 dev eth0'
        Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -Exactly -ParameterFilter { $CmdToExecute -ceq 'ip route show 172.20.2.0/24' -and $IgnoreErrors }
    }

    It 'returns an empty text when the control plane has no such route' {
        Mock Invoke-CmdOnControlPlaneViaSSHKey { [pscustomobject]@{ Success = $true; Output = '' } }
        $route = Get-NodeRenameControlPlaneRoute -PodCIDR '172.20.2.0/24'
        $null -eq $route | Should -BeFalse
        $route | Should -BeExactly ''
    }

    It 'returns nothing when the route cannot be read' -ForEach @(
        @{ Case = 'failed command'; Mock = { [pscustomobject]@{ Success = $false; Output = 'ssh: connect failed' } } },
        @{ Case = 'exception'; Mock = { throw 'ssh unavailable' } }
    ) {
        Mock Invoke-CmdOnControlPlaneViaSSHKey $Mock
        $null -eq (Get-NodeRenameControlPlaneRoute -PodCIDR '172.20.2.0/24') | Should -BeTrue
    }

    It 'does not contact the control plane for a value that is not a pod network range' -ForEach @(
        @{ Value = '172.20.2.0/24; reboot' }, @{ Value = '$(reboot)' }, @{ Value = 'fd00::/64' }, @{ Value = '' }
    ) {
        Mock Invoke-CmdOnControlPlaneViaSSHKey {}
        $null -eq (Get-NodeRenameControlPlaneRoute -PodCIDR $Value) | Should -BeTrue
        Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 0
    }
}

Describe 'Other node for the pods of a renamed worker' -Tag 'unit', 'ci', 'node-rename' {
    BeforeAll {
        function New-TestNode {
            param([string] $Name, [string] $OS = 'linux', [string] $Ready = 'True', [bool] $Unschedulable = $false, $Taints = @())
            return @{
                metadata = @{ name = $Name; labels = @{ 'kubernetes.io/os' = $OS } }
                spec = @{ unschedulable = $Unschedulable; taints = @($Taints) }
                status = @{ conditions = @(@{ type = 'Ready'; status = $Ready }) }
            } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        }
    }

    BeforeEach {
        $script:old = New-TestNode -Name 'old-node'
    }

    It 'finds a Ready, schedulable node of the same operating system' {
        Test-NodeRenameOtherNodeAvailable -Nodes @($script:old, (New-TestNode -Name 'kubemaster')) -Old $script:old -NewName 'new-node' | Should -BeTrue
    }

    It 'accepts a node whose taints do not keep pods away' {
        $other = New-TestNode -Name 'kubemaster' -Taints @(@{ key = 'example.org/hint'; effect = 'PreferNoSchedule' })
        Test-NodeRenameOtherNodeAvailable -Nodes @($script:old, $other) -Old $script:old -NewName 'new-node' | Should -BeTrue
    }

    It 'accepts a node that carries the same taint as the renamed node, as K2s Windows nodes do' {
        $osTaint = @{ key = 'OS'; value = 'Windows'; effect = 'NoSchedule' }
        $oldWindows = New-TestNode -Name 'old-host' -OS 'windows' -Taints @($osTaint)
        $otherWindows = New-TestNode -Name 'second-windows' -OS 'windows' -Taints @($osTaint)
        Test-NodeRenameOtherNodeAvailable -Nodes @($oldWindows, $otherWindows) -Old $oldWindows -NewName 'new-host' | Should -BeTrue
    }

    It 'does not count a node whose taint differs in value from the taint of the renamed node' {
        $oldNode = New-TestNode -Name 'old-node' -Taints @(@{ key = 'dedicated'; value = 'team-a'; effect = 'NoSchedule' })
        $other = New-TestNode -Name 'kubemaster' -Taints @(@{ key = 'dedicated'; value = 'team-b'; effect = 'NoSchedule' })
        Test-NodeRenameOtherNodeAvailable -Nodes @($oldNode, $other) -Old $oldNode -NewName 'new-node' | Should -BeFalse
    }

    It 'does not count <Case>' -ForEach @(
        @{ Case = 'the old node itself'; Other = @{ Name = 'old-node' } },
        @{ Case = 'the replacement of the same machine'; Other = @{ Name = 'new-node' } },
        @{ Case = 'a node of another operating system'; Other = @{ Name = 'windows-host'; OS = 'windows' } },
        @{ Case = 'a node that is not Ready'; Other = @{ Name = 'kubemaster'; Ready = 'Unknown' } },
        @{ Case = 'a cordoned node'; Other = @{ Name = 'kubemaster'; Unschedulable = $true } },
        @{ Case = 'a node with a NoSchedule taint'; Other = @{ Name = 'kubemaster'; Taints = @(@{ key = 'node-role.kubernetes.io/control-plane'; effect = 'NoSchedule' }) } },
        @{ Case = 'a node with a NoExecute taint'; Other = @{ Name = 'kubemaster'; Taints = @(@{ key = 'dedicated'; effect = 'NoExecute' }) } }
    ) {
        Test-NodeRenameOtherNodeAvailable -Nodes @($script:old, (New-TestNode @Other)) -Old $script:old -NewName 'new-node' | Should -BeFalse
    }

    It 'finds none when the old node is the only node' {
        Test-NodeRenameOtherNodeAvailable -Nodes @($script:old) -Old $script:old -NewName 'new-node' | Should -BeFalse
    }
}

Describe 'Worker rename target resolution' -Tag 'unit', 'ci', 'node-rename' {
    BeforeAll {
        function Set-TestDescriptor {
            param($Nodes)
            @{ nodes = @($Nodes) } | ConvertTo-Json -Depth 10 | Set-Content $script:descriptorPath
        }
        function New-TestManagedNode {
            param([hashtable] $Overrides = @{})
            $node = @{ Name = 'Old-Node'; OS = 'linux'; Role = 'worker'; NodeType = 'HOST'; Username = 'admin'; IpAddress = '192.0.2.2'; PodCIDR = '172.20.2.0/24' }
            foreach ($key in $Overrides.Keys) { $node[$key] = $Overrides[$key] }
            return [pscustomobject]$node
        }
    }

    BeforeEach {
        $script:descriptorPath = Join-Path $TestDrive 'cluster.json'
        Remove-Item -LiteralPath $script:descriptorPath -Force -ErrorAction SilentlyContinue
        Mock Get-ClusterDescriptorFilePath { $script:descriptorPath }
        Mock Get-ConfigLinuxOnly { $false }
        Mock Get-NodeRenameLocalHostname { 'NEW-HOST' }
        Mock Get-NodeRenameLocalIPs { @('172.20.1.2', '10.0.0.5') }
        $script:windowsNode = @{
            metadata = @{ name = 'old-host'; labels = @{ 'kubernetes.io/os' = 'windows' } }
            spec = @{ podCIDR = '172.20.1.0/24' }
            status = @{ addresses = @(@{ type = 'Hostname'; address = 'old-host' }, @{ type = 'InternalIP'; address = '172.20.1.2' }) }
        } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $script:linuxNode = @{
            metadata = @{ name = 'old-node'; labels = @{ 'kubernetes.io/os' = 'linux' } }
            spec = @{ podCIDR = '172.20.2.0/24' }
            status = @{ addresses = @(@{ type = 'InternalIP'; address = '192.0.2.2' }) }
        } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    }

    It 'resolves a managed Linux worker from the cluster descriptor, ignoring the case of the stored name' {
        Set-TestDescriptor (New-TestManagedNode)
        $target = Resolve-NodeRenameTarget -OldName 'old-node' -NewName 'new-node' -Old $script:linuxNode -Replacement $null
        $target.Kind | Should -Be 'linux'
        $target.Name | Should -Be 'Old-Node'
        $target.IpAddress | Should -Be '192.0.2.2'
        $target.Username | Should -Be 'admin'
        $target.NodeType | Should -Be 'HOST'
    }

    It 'resolves a managed Linux worker that is already stored under its new name' {
        Set-TestDescriptor (New-TestManagedNode @{ Name = 'new-node'; NodeType = 'VM-EXISTING' })
        (Resolve-NodeRenameTarget -OldName 'old-node' -NewName 'new-node' -Old $null -Replacement $script:linuxNode).NodeType | Should -Be 'VM-EXISTING'
    }

    It 'resolves the local Windows worker when the old Node is not an additional node' {
        Set-TestDescriptor (New-TestManagedNode @{ Name = 'another-worker' })
        $target = Resolve-NodeRenameTarget -OldName 'old-host' -NewName 'new-host' -Old $script:windowsNode -Replacement $null
        $target.Kind | Should -Be 'windows'
        $target.OS | Should -Be 'windows'
        $target.Name | Should -Be 'old-host'
        $target.IpAddress | Should -Be '172.20.1.2'
        $target.PodCIDR | Should -Be '172.20.1.0/24'
    }

    It 'resolves the local Windows worker without a cluster descriptor' {
        (Resolve-NodeRenameTarget -OldName 'old-host' -NewName 'new-host' -Old $script:windowsNode -Replacement $null).Kind | Should -Be 'windows'
    }

    It 'rejects the local Windows host of a Linux-only installation' {
        Mock Get-ConfigLinuxOnly { $true }
        { Resolve-NodeRenameTarget -OldName 'old-host' -NewName 'new-host' -Old $null -Replacement $null } | Should -Throw '*Linux-only installation*'
    }

    It 'still resolves a managed Linux worker of a Linux-only installation' {
        Mock Get-ConfigLinuxOnly { $true }
        Set-TestDescriptor (New-TestManagedNode)
        (Resolve-NodeRenameTarget -OldName 'old-node' -NewName 'new-node' -Old $script:linuxNode -Replacement $null).Kind | Should -Be 'linux'
    }

    It 'rejects a Linux Node that was not added through k2s node add' {
        { Resolve-NodeRenameTarget -OldName 'old-node' -NewName 'new-node' -Old $script:linuxNode -Replacement $null } | Should -Throw '*is not managed by K2s*'
    }

    It 'rejects a Windows Node that is not this host' {
        Mock Get-NodeRenameLocalIPs { @('10.0.0.5') }
        { Resolve-NodeRenameTarget -OldName 'old-host' -NewName 'new-host' -Old $script:windowsNode -Replacement $null } |
            Should -Throw '*not the local K2s worker host*additional Windows workers are not supported*'
    }

    It 'rejects an additional Windows worker registered in the cluster descriptor' {
        Set-TestDescriptor (New-TestManagedNode @{ OS = 'windows' })
        { Resolve-NodeRenameTarget -OldName 'old-node' -NewName 'new-node' -Old $script:windowsNode -Replacement $null } |
            Should -Throw '*Additional windows workers are not supported*'
    }

    It 'rejects an unsupported node type or role' -ForEach @(
        @{ Overrides = @{ NodeType = 'VM-NEW' } },
        @{ Overrides = @{ Role = 'control-plane' } }
    ) {
        Set-TestDescriptor (New-TestManagedNode $Overrides)
        { Resolve-NodeRenameTarget -OldName 'old-node' -NewName 'new-node' -Old $script:linuxNode -Replacement $null } | Should -Throw '*Unsupported node type*'
    }

    It 'rejects a managed worker with incomplete metadata' -ForEach @(
        @{ Overrides = @{ Username = '' } },
        @{ Overrides = @{ PodCIDR = '' } },
        @{ Overrides = @{ IpAddress = 'not-an-ip' } }
    ) {
        Set-TestDescriptor (New-TestManagedNode $Overrides)
        { Resolve-NodeRenameTarget -OldName 'old-node' -NewName 'new-node' -Old $script:linuxNode -Replacement $null } | Should -Throw '*incomplete connection or PodCIDR metadata*'
    }

    It 'rejects a rename when both names are registered as managed workers' {
        Set-TestDescriptor @((New-TestManagedNode), (New-TestManagedNode @{ Name = 'new-node'; IpAddress = '192.0.2.3' }))
        { Resolve-NodeRenameTarget -OldName 'old-node' -NewName 'new-node' -Old $script:linuxNode -Replacement $null } | Should -Throw '*Both the old and the new name*'
    }

    It 'reports an unknown Node that is neither managed nor present in the cluster' {
        { Resolve-NodeRenameTarget -OldName 'ghost' -NewName 'new-host' -Old $null -Replacement $null } | Should -Throw "*Node 'ghost' does not exist*"
    }
}

Describe 'Local Windows worker rename lifecycle' -Tag 'unit', 'ci', 'node-rename' {
    BeforeEach {
        $script:events = [Collections.Generic.List[string]]::new()
        $script:old = @{
            metadata = @{
                name = 'old-host'; uid = 'old-uid'
                labels = @{ 'kubernetes.io/os' = 'windows'; 'kubernetes.io/role' = 'worker'; team = 'test' }; annotations = @{}
            }
            spec = @{ podCIDR = '172.20.1.0/24'; podCIDRs = @('172.20.1.0/24'); unschedulable = $false }
            status = @{ conditions = @(@{ type = 'Ready'; status = 'Unknown' }); addresses = @(@{ type = 'InternalIP'; address = '172.20.1.2' }) }
        } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $script:ready = @{
            metadata = @{
                name = 'new-host'
                labels = @{ 'kubernetes.io/os' = 'windows'; 'kubernetes.io/role' = 'worker'; team = 'test' }
                annotations = @{
                    'k2s.io/rename-source-name' = 'old-host'; 'k2s.io/rename-source-uid' = 'old-uid'
                    'k2s.io/rename-original-unschedulable' = 'false'
                }
            }
            spec = @{ podCIDR = '172.20.1.0/24'; podCIDRs = @('172.20.1.0/24'); unschedulable = $true }
            status = @{ conditions = @(@{ type = 'Ready'; status = 'True' }); addresses = @(@{ type = 'InternalIP'; address = '172.20.1.2' }) }
        } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $script:nodeList = @($script:old)
        $script:descriptorPath = Join-Path $TestDrive 'cluster.json'
        @{ nodes = @([pscustomobject]@{ Name = 'linux-worker'; OS = 'linux'; Role = 'worker'; NodeType = 'HOST'; Username = 'admin'; IpAddress = '192.0.2.2'; PodCIDR = '172.20.2.0/24' }) } |
            ConvertTo-Json -Depth 10 | Set-Content $script:descriptorPath
        $script:descriptorBefore = Get-Content -Raw $script:descriptorPath
        Mock Get-ClusterDescriptorFilePath { $script:descriptorPath }
        Mock Get-ConfigLinuxOnly { $false }
        Mock Get-NodeRenameLocalHostname { 'NEW-HOST' }
        Mock Get-NodeRenameLocalIPs { @('172.20.1.2', '192.168.1.10') }
        Mock Write-Log {}
        Mock Invoke-NodeRenameKubectl {
            $command = $Arguments -join ' '
            $script:events.Add($command)
            if ($command -eq 'get nodes -o json') {
                # The cluster no longer lists the old Node once it is deleted
                $nodes = @($script:nodeList | Where-Object { $script:events -notcontains 'delete-old' -or $_.metadata.name -ne 'old-host' })
                return @{ items = $nodes } | ConvertTo-Json -Depth 30
            }
            if ($command -eq 'get node new-host -o json') { return $script:ready | ConvertTo-Json -Depth 30 }
            if ($Arguments[1] -eq 'pods') { return '{"items":[]}' }
        }
        Mock Invoke-NodeRenameObject {
            if ($Arguments[0] -eq 'create') {
                $script:events.Add('create')
                $script:created = $Object
            } elseif ($Arguments[1] -eq '--raw=/api/v1/nodes/old-host') {
                $script:events.Add('delete-old')
                $Object.preconditions.uid | Should -Be 'old-uid'
            } else {
                $script:events.Add("delete-partial:$($Object.preconditions.uid)")
            }
        }
        Mock Restore-NodeRenameWindowsOldIdentity { $script:events.Add("restore-old:$OldName") }
        Mock Restore-NodeRenameWindowsKubeletName { $script:events.Add('unpin-kubelet-name') }
        Mock Stop-NodeRenameWindowsServices { $script:events.Add('stop-services') }
        Mock Set-NodeRenameWindowsIdentity { $script:events.Add("set-identity:$NewName") }
        Mock Backup-NodeRenameWindowsCredentials { $script:events.Add("backup-credentials:$NewName") }
        Mock Start-NodeRenameWindowsServices { $script:events.Add('start-services') }
        Mock Wait-NodeRenameWindowsCertificate { $script:events.Add("wait-certificate:$NewName") }
        Mock Get-NodeRenameWindowsCertificateSubject { 'CN=system:node:new-host, O=system:nodes' }
        Mock Assert-NodeRenameWindowsServices { $script:events.Add('assert-services') }
        Mock Invoke-NodeRenameRemote {}
        Mock Repair-NodeRenameCertificates {}
        Mock Remove-NodeRenameFlagsBackup {}
        Mock Get-NodeRenameControlPlaneRoute { $null }
        Mock Start-Sleep {}
        Mock Update-NodeConfig {}
        Mock Start-LinuxWorkerNode {}
        Mock Stop-LinuxWorkerNode {}
    }

    It 'drains the old node gracefully under its old kubelet name before registering under the new name' {
        Invoke-WorkerRename -OldName 'OLD-HOST' -NewName 'New-Host'
        $events = $script:events
        $drain = @($events | Where-Object { $_ -like 'drain old-host *' })
        $expectedOrder = @(
            'cordon old-host', 'restore-old:old-host', 'wait --for=condition=Ready node/old-host*', 'drain old-host *', 'stop-services', 'unpin-kubelet-name',
            'annotate node old-host k2s.io/rename-drained=true --overwrite', 'set-identity:new-host', 'backup-credentials:new-host', 'create',
            'start-services', 'wait-certificate:new-host', 'wait --for=condition=Ready node/new-host*', 'assert-services',
            'annotate node old-host flannel.alpha.coreos.com/kube-subnet-manager-', 'delete-old', 'uncordon new-host',
            'annotate node new-host k2s.io/rename-source-uid- k2s.io/rename-source-name- k2s.io/rename-original-unschedulable-')
        $previous = -1
        foreach ($expected in $expectedOrder) {
            $index = -1
            for ($i = 0; $i -lt $events.Count; $i++) { if ($events[$i] -like $expected) { $index = $i; break } }
            $index | Should -BeGreaterThan $previous -Because "'$expected' must follow the previous step"
            $previous = $index
        }
        $drain.Count | Should -Be 1
        # This host is the only Windows node, so budgets cannot be satisfied and are not checked
        $drain[0] | Should -Match '--ignore-daemonsets --delete-emptydir-data --disable-eviction --timeout='
        $drain[0] | Should -Not -Match '--force|--grace-period|--dry-run'
        $script:created.metadata.name | Should -Be 'new-host'
        $script:created.spec.podCIDR | Should -Be '172.20.1.0/24'
        $script:created.spec.unschedulable | Should -BeTrue
        $script:created.metadata.labels.team | Should -Be 'test'
        $script:created.metadata.labels.'kubernetes.io/role' | Should -Be 'worker'
        $script:created.metadata.labels.ContainsKey('kubernetes.io/os') | Should -BeFalse
    }

    It 'respects disruption budgets when another Windows node can run the pods' {
        $osTaint = [pscustomobject]@{ key = 'OS'; value = 'Windows'; effect = 'NoSchedule' }
        $script:old.spec | Add-Member -NotePropertyName 'taints' -NotePropertyValue @($osTaint)
        $other = $script:ready | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $other.metadata.name = 'second-windows'
        $other.metadata.annotations = [pscustomobject]@{}
        $other.spec.unschedulable = $false
        $other.spec.podCIDR = '172.20.3.0/24'
        $other.spec.podCIDRs = @('172.20.3.0/24')
        $other.spec | Add-Member -NotePropertyName 'taints' -NotePropertyValue @($osTaint)
        $other.status.addresses[0].address = '192.0.2.50'
        $script:nodeList += $other
        Invoke-WorkerRename -OldName 'old-host' -NewName 'new-host'
        $drain = @($script:events | Where-Object { $_ -like 'drain old-host *' })
        $drain[0] | Should -Match '--ignore-daemonsets --delete-emptydir-data --timeout='
        $drain[0] | Should -Not -Match '--disable-eviction'
        Should -Invoke Write-Log -Times 0 -ParameterFilter { $Message -like '*PodDisruptionBudgets are not checked*' }
    }

    It 'names the Windows host and reports every step in order on the console' {
        $script:console = [Collections.Generic.List[string]]::new()
        Mock Write-Log { if ($Console) { $script:console.Add((([string]$Message) -replace '^\[NodeRename\] ', '')) } }
        Invoke-WorkerRename -OldName 'old-host' -NewName 'new-host'
        $script:console[0..($script:console.Count - 2)] | Should -Be @(
            "Renaming Node 'old-host' to 'new-host'. Target: local Windows worker host (IP 172.20.1.2, PodCIDR 172.20.1.0/24)",
            "The OS hostname of the target is 'NEW-HOST' and matches the new name",
            "Old Node 'old-host' is NotReady",
            "Cordoning old Node 'old-host'",
            "Restarting the kubelet under its old name 'old-host', so that the old Node can be drained",
            'No other Ready windows node can run the pods of old-host, so PodDisruptionBudgets are not checked; pods are still shut down gracefully',
            "Draining old Node 'old-host' (pod-local emptyDir data is deleted, persistent volumes are kept)",
            'Stopping kubeproxy, kubelet, the remaining containers and flanneld on this host',
            "Setting 'new-host' in the kubeproxy and flanneld services and the kubelet flags file; moving the old kubelet certificates to a backup folder",
            "Creating Node 'new-host' with PodCIDR 172.20.1.0/24",
            "Restarting containerd and starting flanneld, kubelet and kubeproxy on this host; the kubelet requests a certificate for 'new-host'",
            "Waiting for Node 'new-host' to become Ready",
            "Node 'new-host' is Ready and its kubelet certificate is issued for system:node:new-host",
            "Deleting old Node 'old-host'",
            "Node 'new-host' is schedulable again")
        $script:console[$script:console.Count - 1] | Should -BeLike 'Renamed old-host to new-host (windows worker, type WINDOWS-HOST); PodCIDR 172.20.1.0/24; Ready;*'
    }

    It 'does not use SSH, the cluster descriptor or Linux worker routes' {
        Invoke-WorkerRename -OldName 'old-host' -NewName 'new-host'
        Should -Invoke Invoke-NodeRenameRemote -Times 0
        Should -Invoke Repair-NodeRenameCertificates -Times 0
        Should -Invoke Remove-NodeRenameFlagsBackup -Times 0
        Should -Invoke Update-NodeConfig -Times 0
        Should -Invoke Start-LinuxWorkerNode -Times 0
        Should -Invoke Stop-LinuxWorkerNode -Times 0
        Get-Content -Raw $script:descriptorPath | Should -Be $script:descriptorBefore
    }

    It 'reports the Windows host in the summary' {
        Invoke-WorkerRename -OldName 'old-host' -NewName 'new-host'
        Should -Invoke Write-Log -Times 1 -ParameterFilter {
            $Console -and $Message -like '*Renamed old-host to new-host (windows worker, type WINDOWS-HOST); PodCIDR 172.20.1.0/24; Ready;*'
        }
    }

    It 'makes no change when the Windows hostname differs from the new name' {
        Mock Get-NodeRenameLocalHostname { 'SOMETHING-ELSE' }
        { Invoke-WorkerRename -OldName 'old-host' -NewName 'new-host' } | Should -Throw "*OS hostname 'SOMETHING-ELSE' does not match 'new-host'*"
        Should -Invoke Stop-NodeRenameWindowsServices -Times 0
        Should -Invoke Restore-NodeRenameWindowsOldIdentity -Times 0
        Should -Invoke Invoke-NodeRenameKubectl -Times 0 -ParameterFilter { $Arguments[0] -ne 'get' }
        Should -Invoke Invoke-NodeRenameObject -Times 0
        Should -Invoke Set-NodeRenameWindowsIdentity -Times 0
    }

    It 'leaves the node services running and unpins the kubelet name when the drain is blocked' {
        Mock Invoke-NodeRenameKubectl { throw 'Cannot evict pod as it would violate the pod''s disruption budget' } -ParameterFilter { $Arguments[0] -eq 'drain' }
        { Invoke-WorkerRename -OldName 'old-host' -NewName 'new-host' } | Should -Throw '*draining old node*disruption budget*'
        Should -Invoke Stop-NodeRenameWindowsServices -Times 0
        Should -Invoke Set-NodeRenameWindowsIdentity -Times 0
        Should -Invoke Backup-NodeRenameWindowsCredentials -Times 0
        Should -Invoke Invoke-NodeRenameObject -Times 0
        $script:events | Should -Contain 'unpin-kubelet-name'
        $script:events | Should -Not -Contain 'annotate node old-host k2s.io/rename-drained=true --overwrite'
    }

    It 'unpins the kubelet name when the old kubelet identity cannot be restored' {
        Mock Restore-NodeRenameWindowsOldIdentity { throw 'unexpected start script' }
        { Invoke-WorkerRename -OldName 'old-host' -NewName 'new-host' } | Should -Throw '*restoring old kubelet identity for graceful drain*unexpected start script*'
        $script:events | Should -Contain 'unpin-kubelet-name'
        Should -Invoke Invoke-NodeRenameKubectl -Times 0 -ParameterFilter { $Arguments[0] -eq 'drain' }
        Should -Invoke Set-NodeRenameWindowsIdentity -Times 0
    }

    It 'does not change the identity when the local services cannot be stopped' {
        Mock Stop-NodeRenameWindowsServices { throw 'crictl failed' }
        { Invoke-WorkerRename -OldName 'old-host' -NewName 'new-host' } | Should -Throw '*stopping old workload containers*crictl failed*'
        Should -Invoke Set-NodeRenameWindowsIdentity -Times 0
        Should -Invoke Backup-NodeRenameWindowsCredentials -Times 0
        $script:events | Should -Contain 'unpin-kubelet-name'
        $script:events | Should -Not -Contain 'annotate node old-host k2s.io/rename-drained=true --overwrite'
        $script:events | Should -Not -Contain 'delete-old'
    }

    It 'does not drain again after a retry finds the old node already drained' {
        $script:old.metadata.annotations | Add-Member -NotePropertyName 'k2s.io/rename-drained' -NotePropertyValue 'true'
        Invoke-WorkerRename -OldName 'old-host' -NewName 'new-host'
        Should -Invoke Restore-NodeRenameWindowsOldIdentity -Times 0
        Should -Invoke Invoke-NodeRenameKubectl -Times 0 -ParameterFilter { $Arguments[0] -eq 'drain' }
        $events = $script:events
        $events | Should -Contain 'get pods -A --field-selector=spec.nodeName=old-host -o json'
        $events.IndexOf('stop-services') | Should -BeGreaterThan $events.IndexOf('unpin-kubelet-name')
        $events.IndexOf('set-identity:new-host') | Should -BeGreaterThan $events.IndexOf('stop-services')
        $events | Should -Contain 'delete-old'
    }

    It 'refuses an already drained node that carries a workload again' {
        $script:old.metadata.annotations | Add-Member -NotePropertyName 'k2s.io/rename-drained' -NotePropertyValue 'true'
        Mock Invoke-NodeRenameKubectl { '{"items":[{"metadata":{"namespace":"app","name":"web"},"status":{"phase":"Running"}}]}' } `
            -ParameterFilter { $Arguments[1] -eq 'pods' }
        { Invoke-WorkerRename -OldName 'old-host' -NewName 'new-host' } | Should -Throw '*carries workload app/web*'
        Should -Invoke Stop-NodeRenameWindowsServices -Times 0
        Should -Invoke Set-NodeRenameWindowsIdentity -Times 0
    }

    It 'keeps the old node when <Step> fails' -ForEach @(
        @{ Step = 'the certificate wait'; Function = 'Wait-NodeRenameWindowsCertificate'; Phase = 'waiting for the new kubelet certificate' },
        @{ Step = 'the service start'; Function = 'Start-NodeRenameWindowsServices'; Phase = 'starting local Windows services' },
        @{ Step = 'the service check'; Function = 'Assert-NodeRenameWindowsServices'; Phase = 'verifying local Windows services' }
    ) {
        Mock $Function { throw 'injected failure' }
        { Invoke-WorkerRename -OldName 'old-host' -NewName 'new-host' } | Should -Throw "*$Phase*injected failure*"
        $script:events | Should -Not -Contain 'delete-old'
        $script:events | Should -Not -Contain 'uncordon new-host'
    }

    It 'keeps the old node when the kubelet certificate is not issued for the new name' {
        Mock Get-NodeRenameWindowsCertificateSubject { 'CN=system:node:old-host, O=system:nodes' }
        { Invoke-WorkerRename -OldName 'old-host' -NewName 'new-host' } | Should -Throw '*does not identify system:node:new-host*'
        $script:events | Should -Not -Contain 'delete-old'
        $script:events | Should -Not -Contain 'assert-services'
    }

    It 'recreates a Node that the host registered by itself with a different PodCIDR' {
        $partial = $script:ready | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $partial.metadata | Add-Member -NotePropertyName 'uid' -NotePropertyValue 'partial-uid'
        $partial.metadata.annotations = [pscustomobject]@{}
        $partial.spec.podCIDR = '172.20.3.0/24'
        $script:nodeList += $partial
        Invoke-WorkerRename -OldName 'old-host' -NewName 'new-host'
        $script:events.IndexOf('delete-partial:partial-uid') | Should -BeGreaterThan $script:events.IndexOf('stop-services')
        $script:events.IndexOf('create') | Should -BeGreaterThan $script:events.IndexOf('delete-partial:partial-uid')
        $script:events.IndexOf('start-services') | Should -BeGreaterThan $script:events.IndexOf('create')
        $script:created.spec.podCIDR | Should -Be '172.20.1.0/24'
    }

    It 'finishes a rename whose old node was already retired' {
        $script:nodeList = @($script:ready)
        Invoke-WorkerRename -OldName 'old-host' -NewName 'new-host'
        Should -Invoke Stop-NodeRenameWindowsServices -Times 0
        Should -Invoke Invoke-NodeRenameObject -Times 0
        $script:events | Should -Contain 'assert-services'
        $script:events | Should -Contain 'uncordon new-host'
    }
}

Describe 'Windows worker identity settings' -Tag 'unit', 'ci', 'node-rename' {
    BeforeEach {
        $script:settings = @{
            'kubeproxy/AppParameters' = '--proxy-mode=kernelspace --hostname-override=old-host --kubeconfig="C:\Program Files\k2s\config" --enable-dsr=false '
            'flanneld/AppEnvironmentExtra' = [string[]]@('NODE_NAME=old-host', 'HTTP_PROXY=http://172.19.1.1:8181', 'NO_PROXY=.local')
        }
        $script:written = @{}
        Mock Get-NodeRenameServiceSetting { $script:settings["$Service/$Name"] }
        Mock Set-NodeRenameServiceSetting { $script:written["$Service/$Name"] = $Value }
        $script:kubeletDirectory = Join-Path $TestDrive "kubelet-$([guid]::NewGuid().ToString('N'))"
        New-Item -Path $script:kubeletDirectory -ItemType Directory | Out-Null
        $script:flagsPath = Join-Path $script:kubeletDirectory 'kubeadm-flags.env'
        Mock Get-KubeletConfigDir { $script:kubeletDirectory }
    }

    It 'changes only the hostname parameter of kubeproxy' {
        Set-NodeRenameWindowsIdentity -NewName 'new-host'
        $script:written['kubeproxy/AppParameters'] |
            Should -BeExactly '--proxy-mode=kernelspace --hostname-override=new-host --kubeconfig="C:\Program Files\k2s\config" --enable-dsr=false '
    }

    It 'replaces a hostname parameter that is written with a space or quotes' -ForEach @(
        @{ Parameters = '--hostname-override old-host --enable-dsr=false' },
        @{ Parameters = '--hostname-override="old-host" --enable-dsr=false' }
    ) {
        $script:settings['kubeproxy/AppParameters'] = $Parameters
        Set-NodeRenameWindowsIdentity -NewName 'new-host'
        $script:written['kubeproxy/AppParameters'] | Should -BeExactly '--hostname-override=new-host --enable-dsr=false'
    }

    It 'replaces NODE_NAME of flanneld in place and keeps its other variables' {
        Set-NodeRenameWindowsIdentity -NewName 'new-host'
        $value = $script:written['flanneld/AppEnvironmentExtra']
        , $value | Should -BeOfType [string[]]
        $value | Should -Be @('NODE_NAME=new-host', 'HTTP_PROXY=http://172.19.1.1:8181', 'NO_PROXY=.local')
    }

    It 'writes nothing when kubeproxy has no hostname parameter' {
        $script:settings['kubeproxy/AppParameters'] = '--proxy-mode=kernelspace'
        { Set-NodeRenameWindowsIdentity -NewName 'new-host' } | Should -Throw '*kubeproxy has no --hostname-override*'
        Should -Invoke Set-NodeRenameServiceSetting -Times 0
    }

    It 'writes nothing when flanneld has no NODE_NAME' {
        $script:settings['flanneld/AppEnvironmentExtra'] = [string[]]@('NO_PROXY=.local')
        { Set-NodeRenameWindowsIdentity -NewName 'new-host' } | Should -Throw '*flanneld has no single NODE_NAME*'
        Should -Invoke Set-NodeRenameServiceSetting -Times 0
    }

    It 'replaces the old name in the kubelet flags file and keeps the other flags' {
        [IO.File]::WriteAllText($script:flagsPath, "KUBELET_KUBEADM_ARGS=`"--hostname-override=OLD-HOST --node-ip=172.20.1.2 --config-dir=C:\\etc\\kubernetes\\kubelet.conf.d`"`n")
        Set-NodeRenameWindowsIdentity -NewName 'new-host'
        [IO.File]::ReadAllText($script:flagsPath) |
            Should -BeExactly "KUBELET_KUBEADM_ARGS=`"--hostname-override=new-host --node-ip=172.20.1.2 --config-dir=C:\\etc\\kubernetes\\kubelet.conf.d`"`n"
        [IO.File]::ReadAllBytes($script:flagsPath)[0] | Should -Be ([byte][char]'K')
    }

    It 'leaves a kubelet flags file without a hostname entry untouched' {
        $content = "KUBELET_KUBEADM_ARGS=`"--node-ip=172.20.1.2`"`n"
        [IO.File]::WriteAllText($script:flagsPath, $content)
        $writtenAt = (Get-Item $script:flagsPath).LastWriteTimeUtc
        Set-NodeRenameWindowsIdentity -NewName 'new-host'
        [IO.File]::ReadAllText($script:flagsPath) | Should -BeExactly $content
        (Get-Item $script:flagsPath).LastWriteTimeUtc | Should -Be $writtenAt
    }
}

Describe 'Windows service settings in the registry' -Tag 'unit', 'ci', 'node-rename' {
    BeforeEach {
        $script:hive = [Microsoft.Win32.Registry]::CurrentUser
        $script:service = "k2s-node-rename-test-$([guid]::NewGuid().ToString('N'))"
        $script:servicesPath = 'SYSTEM\CurrentControlSet\Services'
        $script:createdAncestors = @()
        $ancestor = ''
        foreach ($part in $script:servicesPath.Split('\')) {
            $ancestor = if ($ancestor) { "$ancestor\$part" } else { $part }
            $existing = $script:hive.OpenSubKey($ancestor)
            if ($existing) { $existing.Dispose() } else { $script:createdAncestors += $ancestor }
        }
        $key = $script:hive.CreateSubKey("$script:servicesPath\$script:service\Parameters")
        $key.SetValue('AppParameters', '--kubeconfig="%ProgramFiles%\k2s\config" --hostname-override=old', [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $key.SetValue('AppEnvironmentExtra', [string[]]@('NODE_NAME=old', 'NO_PROXY=.local'), [Microsoft.Win32.RegistryValueKind]::MultiString)
        $key.Dispose()
    }

    AfterEach {
        $script:hive.DeleteSubKeyTree("$script:servicesPath\$script:service", $false)
        [array]::Reverse($script:createdAncestors)
        foreach ($ancestor in $script:createdAncestors) { $script:hive.DeleteSubKey($ancestor, $false) }
    }

    It 'reads an expandable value unexpanded and writes it back with the same kind' {
        $value = Get-NodeRenameServiceSetting -Service $script:service -Name 'AppParameters' -Hive $script:hive
        $value | Should -BeExactly '--kubeconfig="%ProgramFiles%\k2s\config" --hostname-override=old'
        Set-NodeRenameServiceSetting -Service $script:service -Name 'AppParameters' -Value ($value -replace '=old$', '=new') -Hive $script:hive
        $key = $script:hive.OpenSubKey("$script:servicesPath\$script:service\Parameters")
        try {
            $key.GetValueKind('AppParameters') | Should -Be ([Microsoft.Win32.RegistryValueKind]::ExpandString)
            $key.GetValue('AppParameters', $null, 'DoNotExpandEnvironmentNames') | Should -BeExactly '--kubeconfig="%ProgramFiles%\k2s\config" --hostname-override=new'
        } finally {
            $key.Dispose()
        }
    }

    It 'keeps a multi-string value a multi-string' {
        $value = @(Get-NodeRenameServiceSetting -Service $script:service -Name 'AppEnvironmentExtra' -Hive $script:hive)
        $value | Should -Be @('NODE_NAME=old', 'NO_PROXY=.local')
        Set-NodeRenameServiceSetting -Service $script:service -Name 'AppEnvironmentExtra' -Value ([string[]]@('NODE_NAME=new', 'NO_PROXY=.local')) -Hive $script:hive
        $key = $script:hive.OpenSubKey("$script:servicesPath\$script:service\Parameters")
        try {
            $key.GetValueKind('AppEnvironmentExtra') | Should -Be ([Microsoft.Win32.RegistryValueKind]::MultiString)
            $key.GetValue('AppEnvironmentExtra') | Should -Be @('NODE_NAME=new', 'NO_PROXY=.local')
        } finally {
            $key.Dispose()
        }
    }

    It 'fails for a service without parameters' {
        { Get-NodeRenameServiceSetting -Service 'k2s-node-rename-missing' -Name 'AppParameters' -Hive $script:hive } | Should -Throw '*has no service parameters*'
        { Set-NodeRenameServiceSetting -Service 'k2s-node-rename-missing' -Name 'AppParameters' -Value 'x' -Hive $script:hive } | Should -Throw '*has no service parameters*'
    }

    It 'rewrites the kubeproxy and flanneld identity through real registry values' {
        $script:realGet = ${function:Get-NodeRenameServiceSetting}
        $script:realSet = ${function:Set-NodeRenameServiceSetting}
        $key = $script:hive.OpenSubKey("$script:servicesPath\$script:service\Parameters", $true)
        $key.SetValue('AppEnvironmentExtra', [string[]]@('KUBE_NETWORK=cbr0', 'NODE_NAME=old', 'NO_PROXY=.local'), [Microsoft.Win32.RegistryValueKind]::MultiString)
        $key.Dispose()
        Mock Get-NodeRenameServiceSetting { & $script:realGet -Service $script:service -Name $Name -Hive $script:hive }
        Mock Set-NodeRenameServiceSetting { & $script:realSet -Service $script:service -Name $Name -Value $Value -Hive $script:hive }
        Mock Get-KubeletConfigDir { $TestDrive }

        Set-NodeRenameWindowsIdentity -NewName 'new-host'

        $key = $script:hive.OpenSubKey("$script:servicesPath\$script:service\Parameters")
        try {
            $key.GetValueKind('AppParameters') | Should -Be ([Microsoft.Win32.RegistryValueKind]::ExpandString)
            $key.GetValue('AppParameters', $null, 'DoNotExpandEnvironmentNames') | Should -BeExactly '--kubeconfig="%ProgramFiles%\k2s\config" --hostname-override=new-host'
            $key.GetValueKind('AppEnvironmentExtra') | Should -Be ([Microsoft.Win32.RegistryValueKind]::MultiString)
            $key.GetValue('AppEnvironmentExtra') | Should -Be @('KUBE_NETWORK=cbr0', 'NODE_NAME=new-host', 'NO_PROXY=.local')
        } finally {
            $key.Dispose()
        }
    }
}

Describe 'Windows kubelet credentials' -Tag 'unit', 'ci', 'node-rename' {
    BeforeAll {
        function New-TestCertificatePem {
            param([string] $Subject)
            $key = [System.Security.Cryptography.RSA]::Create(2048)
            try {
                $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
                    $Subject, $key, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(1))
                $encoded = [Convert]::ToBase64String($certificate.RawData, 'InsertLineBreaks')
                return "-----BEGIN CERTIFICATE-----`n$encoded`n-----END CERTIFICATE-----`n-----BEGIN RSA PRIVATE KEY-----`nAAAA`n-----END RSA PRIVATE KEY-----`n"
            } finally {
                $key.Dispose()
            }
        }
    }

    BeforeEach {
        $script:kubeletDirectory = Join-Path $TestDrive "kubelet-$([guid]::NewGuid().ToString('N'))"
        $script:pki = Join-Path $script:kubeletDirectory 'pki'
        New-Item -Path $script:pki -ItemType Directory | Out-Null
        Mock Get-KubeletConfigDir { $script:kubeletDirectory }
        Mock Write-Log {}
    }

    It 'reads the subject of the current client certificate from a file that also holds the private key' {
        Set-Content -Path (Join-Path $script:pki 'kubelet-client-current.pem') -Value (New-TestCertificatePem 'CN=system:node:new-host, O=system:nodes') -NoNewline
        $subject = Get-NodeRenameWindowsCertificateSubject
        Test-NodeRenameCertificateSubject -Subject $subject -NodeName 'new-host' | Should -BeTrue
        Test-NodeRenameCertificateSubject -Subject $subject -NodeName 'old-host' | Should -BeFalse
    }

    It 'returns nothing when the certificate is missing or unreadable' {
        Get-NodeRenameWindowsCertificateSubject | Should -BeNullOrEmpty
        Set-Content -Path (Join-Path $script:pki 'kubelet-client-current.pem') -Value 'not a certificate'
        Get-NodeRenameWindowsCertificateSubject | Should -BeNullOrEmpty
    }

    It 'accepts only the exact node name in the system:nodes organization' -ForEach @(
        @{ Subject = 'CN=system:node:new-host, O=system:nodes'; Expected = $true },
        @{ Subject = 'O=system:nodes,CN=system:node:new-host'; Expected = $true },
        @{ Subject = 'CN=system:node:new-host-2, O=system:nodes'; Expected = $false },
        @{ Subject = 'CN=system:node:new-host, O=other'; Expected = $false },
        @{ Subject = 'CN=kubernetes-admin, O=system:masters'; Expected = $false },
        @{ Subject = ''; Expected = $false }
    ) {
        Test-NodeRenameCertificateSubject -Subject $Subject -NodeName 'new-host' | Should -Be $Expected
    }

    It 'moves the old client and serving credentials into a backup folder and leaves other files alone' {
        Set-Content -Path (Join-Path $script:pki 'kubelet-client-2026-01-01-00-00-00.pem') -Value (New-TestCertificatePem 'CN=system:node:old-host, O=system:nodes') -NoNewline
        Copy-Item (Join-Path $script:pki 'kubelet-client-2026-01-01-00-00-00.pem') (Join-Path $script:pki 'kubelet-client-current.pem')
        foreach ($name in @('kubelet.crt', 'kubelet.key', 'kubelet-server-2026-01-01.pem', 'unrelated.txt')) { Set-Content -Path (Join-Path $script:pki $name) -Value $name }
        Backup-NodeRenameWindowsCredentials -NewName 'new-host'
        (Get-ChildItem $script:pki).Name | Should -Be @('unrelated.txt')
        $backup = @(Get-ChildItem $script:kubeletDirectory -Directory -Filter 'k2s-identity-backup.*')
        $backup.Count | Should -Be 1
        (Get-ChildItem $backup[0].FullName).Name | Sort-Object |
            Should -Be (@('kubelet-client-2026-01-01-00-00-00.pem', 'kubelet-client-current.pem', 'kubelet-server-2026-01-01.pem', 'kubelet.crt', 'kubelet.key') | Sort-Object)
    }

    It 'removes the link to the current certificate and keeps the certificate it points to' {
        $dated = Join-Path $script:pki 'kubelet-client-2026-01-01-00-00-00.pem'
        Set-Content -Path $dated -Value (New-TestCertificatePem 'CN=system:node:old-host, O=system:nodes') -NoNewline
        try {
            New-Item -ItemType SymbolicLink -Path (Join-Path $script:pki 'kubelet-client-current.pem') -Value $dated -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because 'creating a symbolic link requires elevation or developer mode'
            return
        }
        Backup-NodeRenameWindowsCredentials -NewName 'new-host'
        Get-ChildItem $script:pki -Force | Should -BeNullOrEmpty
        $backup = @(Get-ChildItem $script:kubeletDirectory -Directory -Filter 'k2s-identity-backup.*')
        (Get-ChildItem $backup[0].FullName -Force).Name | Should -Be @('kubelet-client-2026-01-01-00-00-00.pem')
    }

    It 'keeps credentials that are already issued for the new name' {
        Set-Content -Path (Join-Path $script:pki 'kubelet-client-current.pem') -Value (New-TestCertificatePem 'CN=system:node:new-host, O=system:nodes') -NoNewline
        Set-Content -Path (Join-Path $script:pki 'kubelet.crt') -Value 'serving'
        Backup-NodeRenameWindowsCredentials -NewName 'new-host'
        (Get-ChildItem $script:pki).Name | Sort-Object | Should -Be (@('kubelet-client-current.pem', 'kubelet.crt') | Sort-Object)
        Get-ChildItem $script:kubeletDirectory -Directory -Filter 'k2s-identity-backup.*' | Should -BeNullOrEmpty
    }

    It 'creates no backup folder when there are no credentials' {
        Backup-NodeRenameWindowsCredentials -NewName 'new-host'
        Get-ChildItem $script:kubeletDirectory -Directory -Filter 'k2s-identity-backup.*' | Should -BeNullOrEmpty
    }

    It 'waits until the kubelet holds a certificate for the new name' {
        $script:nodeRenameDeadline = [DateTime]::UtcNow.AddMinutes(5)
        $script:subjects = [Collections.Generic.Queue[string]]::new()
        foreach ($subject in @('', 'CN=system:node:old-host, O=system:nodes', 'CN=system:node:new-host, O=system:nodes')) { $script:subjects.Enqueue($subject) }
        Mock Get-NodeRenameWindowsCertificateSubject { $script:subjects.Dequeue() }
        Mock Start-Sleep {}
        Wait-NodeRenameWindowsCertificate -NewName 'new-host'
        Should -Invoke Get-NodeRenameWindowsCertificateSubject -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'gives up at the deadline and points to the pending certificate requests' {
        $script:nodeRenameDeadline = [DateTime]::UtcNow.AddSeconds(-1)
        Mock Get-NodeRenameWindowsCertificateSubject { 'CN=system:node:old-host, O=system:nodes' }
        { Wait-NodeRenameWindowsCertificate -NewName 'new-host' } | Should -Throw '*Timed out waiting for the kubelet client certificate of system:node:new-host*kubectl get csr*'
    }
}

Describe 'Local Windows service handling' -Tag 'unit', 'ci', 'node-rename' {
    BeforeEach {
        $script:events = [Collections.Generic.List[string]]::new()
        $script:statuses = @{}
        Mock Stop-Service { $script:events.Add("stop:$Name") }
        Mock Start-Service { $script:events.Add("start:$Name") }
        Mock Restart-Service { $script:events.Add("restart:$Name") }
        Mock Get-Service {
            $status = if ($script:statuses.ContainsKey("$Name")) { $script:statuses["$Name"] } else { 'Running' }
            [pscustomobject]@{ Name = "$Name"; Status = $status }
        }
        Mock Wait-NodeRenameWindowsService { $script:events.Add("wait:$Name") }
        Mock Invoke-NodeRenameCrictl {
            $script:events.Add("crictl:$($Arguments -join ' ')")
            if ($Arguments[0] -eq 'pods') { 'WARN[0000] runtime connect warning'; 'aaaaaaaaaaaa1111'; 'bbbbbbbbbbbb2222' }
        }
    }

    It 'stops the node services and every pod sandbox, but not the host helper services' {
        Stop-NodeRenameWindowsServices
        $script:events | Should -Be @('stop:kubeproxy', 'stop:kubelet', 'crictl:pods -q', 'crictl:stopp aaaaaaaaaaaa1111', 'crictl:stopp bbbbbbbbbbbb2222', 'stop:flanneld')
    }

    It 'starts containerd first when it is not running, so that the sandboxes can be stopped' {
        $script:statuses['containerd'] = 'Stopped'
        Stop-NodeRenameWindowsServices
        $script:events[0..4] | Should -Be @('stop:kubeproxy', 'stop:kubelet', 'start:containerd', 'wait:containerd', 'crictl:pods -q')
    }

    It 'does not stop flanneld when a sandbox cannot be stopped' {
        Mock Invoke-NodeRenameCrictl { throw 'stopp failed' } -ParameterFilter { $Arguments[0] -eq 'stopp' }
        { Stop-NodeRenameWindowsServices } | Should -Throw '*stopp failed*'
        $script:events | Should -Not -Contain 'stop:flanneld'
    }

    It 'restarts only containerd and starts the other services in the K2s order without restarting the shared helper services' {
        Start-NodeRenameWindowsServices
        $script:events | Should -Be @(
            'restart:containerd', 'wait:containerd', 'start:httpproxy', 'wait:httpproxy', 'start:flanneld', 'wait:flanneld',
            'start:kubelet', 'wait:kubelet', 'start:kubeproxy', 'wait:kubeproxy', 'start:dnsproxy', 'wait:dnsproxy')
        Should -Invoke Restart-Service -Times 0 -ParameterFilter { $Name -in @('httpproxy', 'dnsproxy') }
        Should -Invoke Stop-Service -Times 0
    }

    It 'names the service that is not running' {
        $script:statuses['kubeproxy'] = 'Stopped'
        { Assert-NodeRenameWindowsServices } | Should -Throw "*Service 'kubeproxy' is not running*"
    }

    It 'accepts the node when all six services are running' {
        { Assert-NodeRenameWindowsServices } | Should -Not -Throw
        Should -Invoke Get-Service -Times 6 -Exactly
    }

    It 'pins the old kubelet name and restarts the kubelet with the services it needs' {
        Mock Set-NodeRenameWindowsKubeletName { $script:events.Add("pin:$Name") }
        Restore-NodeRenameWindowsOldIdentity -OldName 'old-host'
        $script:events | Should -Be @(
            'pin:old-host', 'stop:kubeproxy', 'stop:kubelet', 'start:containerd', 'wait:containerd', 'start:httpproxy', 'wait:httpproxy',
            'start:flanneld', 'wait:flanneld', 'start:kubelet', 'wait:kubelet', 'start:kubeproxy', 'wait:kubeproxy')
    }

    It 'does not restart the kubelet when its name cannot be pinned' {
        Mock Set-NodeRenameWindowsKubeletName { throw 'unexpected start script' }
        { Restore-NodeRenameWindowsOldIdentity -OldName 'old-host' } | Should -Throw '*unexpected start script*'
        $script:events | Should -BeNullOrEmpty
    }
}

Describe 'Windows kubelet start script' -Tag 'unit', 'ci', 'node-rename' {
    BeforeEach {
        $script:root = Join-Path $TestDrive "install-$([guid]::NewGuid().ToString('N'))"
        $script:kubeletDirectory = Join-Path $script:root 'kubelet'
        New-Item -Path (Join-Path $script:root 'smallsetup\common'), $script:kubeletDirectory -ItemType Directory | Out-Null
        $script:startScript = Join-Path $script:root 'smallsetup\common\StartKubelet.ps1'
        $script:backup = Join-Path $script:kubeletDirectory 'k2s-rename-StartKubelet.ps1'
        $script:original = "Set-Location `$PSScriptRoot`r`n    `$FileContent = Get-Content -Path `"C:\var\lib\kubelet\kubeadm-flags.env`"`r`n" +
            "    `$hn = (`$(hostname)).ToLower()`r`n    `$cmd = `"&'C:\k2s\bin\kube\kubelet.exe' --hostname-override=`$hn `"`r`n`r`n    Invoke-Expression `$cmd`r`n"
        [IO.File]::WriteAllText($script:startScript, $script:original, [Text.Encoding]::ASCII)
        Mock Get-KubePath { $script:root }
        Mock Get-KubeletConfigDir { $script:kubeletDirectory }
    }

    It 'replaces only the host name lookup with the old name and keeps a copy of the original' {
        Set-NodeRenameWindowsKubeletName -Name 'old-host'
        [IO.File]::ReadAllText($script:startScript) | Should -BeExactly $script:original.Replace('$hn = ($(hostname)).ToLower()', "`$hn = 'old-host'")
        [IO.File]::ReadAllBytes($script:startScript)[0] | Should -Be ([byte][char]'S')
        [IO.File]::ReadAllText($script:backup) | Should -BeExactly $script:original
    }

    It 'makes the script use the pinned name when it runs' {
        Set-NodeRenameWindowsKubeletName -Name 'old-host'
        $pinned = [IO.File]::ReadAllText($script:startScript) -replace 'Invoke-Expression \$cmd', '$cmd' -replace '(?m)^.*(Get-Content|Set-Location).*$', ''
        (& ([scriptblock]::Create($pinned)) | Select-Object -Last 1) | Should -Match '--hostname-override=old-host $'
    }

    It 'restores the original script byte for byte and removes the copy' {
        $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:startScript))
        Set-NodeRenameWindowsKubeletName -Name 'old-host'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:startScript)) | Should -Not -Be $before
        Restore-NodeRenameWindowsKubeletName
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:startScript)) | Should -BeExactly $before
        Test-Path -LiteralPath $script:backup | Should -BeFalse
    }

    It 'does nothing on restore when the name was never pinned' {
        $writtenAt = (Get-Item $script:startScript).LastWriteTimeUtc
        Restore-NodeRenameWindowsKubeletName
        (Get-Item $script:startScript).LastWriteTimeUtc | Should -Be $writtenAt
        [IO.File]::ReadAllText($script:startScript) | Should -BeExactly $script:original
    }

    It 'starts from the original script when an interrupted attempt left the name pinned' {
        Set-NodeRenameWindowsKubeletName -Name 'first-name'
        Set-NodeRenameWindowsKubeletName -Name 'old-host'
        [IO.File]::ReadAllText($script:startScript) | Should -Match "\`$hn = 'old-host'"
        [IO.File]::ReadAllText($script:backup) | Should -BeExactly $script:original
        Restore-NodeRenameWindowsKubeletName
        [IO.File]::ReadAllText($script:startScript) | Should -BeExactly $script:original
    }

    It 'changes nothing when the script does not read the host name as expected' -ForEach @(
        @{ Content = "`$cmd = `"kubelet.exe --hostname-override=`$env:COMPUTERNAME`"`r`n" },
        @{ Content = "`$hn = (`$(hostname)).ToLower()`r`n`$hn = (`$(hostname)).ToLower()`r`n" }
    ) {
        [IO.File]::WriteAllText($script:startScript, $Content, [Text.Encoding]::ASCII)
        { Set-NodeRenameWindowsKubeletName -Name 'old-host' } | Should -Throw '*does not read the host name in the expected way*'
        [IO.File]::ReadAllText($script:startScript) | Should -BeExactly $Content
        Test-Path -LiteralPath $script:backup | Should -BeFalse
    }
}
