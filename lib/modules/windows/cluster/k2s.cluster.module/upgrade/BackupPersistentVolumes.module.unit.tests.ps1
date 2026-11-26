# SPDX-FileCopyrightText:  2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module "$PSScriptRoot\BackupPersistentVolumes.psm1" -PassThru -Force).Name
}

Describe 'ConvertFrom-PVList' -Tag 'unit', 'ci', 'backup-pv' {
    It 'converts valid PV data correctly' {
        $pvListJson = @{
            items = @(@{
                metadata = @{ name = 'test-pv' }
                spec = @{
                    capacity = @{ storage = '10Gi' }
                    local = @{ path = '/data' }
                    claimRef = @{
                        namespace = 'default'
                        name = 'test-pvc'
                    }
                    persistentVolumeReclaimPolicy = 'Retain'
                }
                status = @{ phase = 'Bound' }
            })
        } | ConvertTo-Json -Depth 10 -Compress

        InModuleScope $moduleName -Parameters @{ pvListJson = $pvListJson } {
            param($pvListJson)
            $result = ConvertFrom-PVList -PVListJson $pvListJson
            
            $result | Should -Not -BeNullOrEmpty           
            $result.Name | Should -Be 'test-pv'
            $result.Type | Should -Be 'local'
            $result.Path | Should -Be '/data'
            $result.Capacity | Should -Be '10Gi'
            $result.ClaimNamespace | Should -Be 'default'
            $result.ClaimName | Should -Be 'test-pvc'
            $result.ReclaimPolicy | Should -Be 'Retain'
            $result.Status | Should -Be 'Bound'
        }
    }

    It 'throws error when required fields are missing' {
        $invalidItems = @(
            @{ metadata = @{ }; spec = @{ capacity = @{ storage = '10Gi' }; local = @{ path = '/data' } }; status = @{ phase = 'Bound' } },
            @{ metadata = @{ name = 'pv2' }; spec = @{ capacity = @{ }; local = @{ path = '/data' } }; status = @{ phase = 'Bound' } },
            @{ metadata = @{ name = 'pv3' }; spec = @{ capacity = @{ storage = '10Gi' }; local = @{ path = '/data' } }; status = @{ } },
            @{ metadata = @{ name = 'pv4' }; spec = @{ capacity = @{ storage = '10Gi' }; local = @{ } }; status = @{ phase = 'Bound' } },
            @{ metadata = @{ name = 'pv5' }; spec = @{ capacity = @{ storage = '10Gi' }; hostPath = @{ } }; status = @{ phase = 'Bound' } }
        )

        InModuleScope $moduleName -Parameters @{ invalidItems = $invalidItems } {
            param($invalidItems)
            
            # Test item 1 - missing metadata.name
            $json1 = (@{ items = @($invalidItems[0]) } | ConvertTo-Json -Depth 10 -Compress)
            try { ConvertFrom-PVList -PVListJson $json1 } catch { $errorMsg1 = $_.Exception.Message }
            $errorMsg1 | Should -BeLike '*metadata.name*'
            
            # Test item 2 - missing spec.capacity.storage
            $json2 = (@{ items = @($invalidItems[1]) } | ConvertTo-Json -Depth 10 -Compress)
            try { ConvertFrom-PVList -PVListJson $json2 } catch { $errorMsg2 = $_.Exception.Message }
            $errorMsg2 | Should -BeLike '*spec.capacity.storage*'
            
            # Test item 3 - missing status.phase
            $json3 = (@{ items = @($invalidItems[2]) } | ConvertTo-Json -Depth 10 -Compress)
            try { ConvertFrom-PVList -PVListJson $json3 } catch { $errorMsg3 = $_.Exception.Message }
            $errorMsg3 | Should -BeLike '*status.phase*'
            
            # Test item 4 - missing spec.local.path
            $json4 = (@{ items = @($invalidItems[3]) } | ConvertTo-Json -Depth 10 -Compress)
            try { ConvertFrom-PVList -PVListJson $json4 } catch { $errorMsg4 = $_.Exception.Message }
            $errorMsg4 | Should -BeLike '*spec.local.path*'
            
            # Test item 5 - missing spec.hostPath.path
            $json5 = (@{ items = @($invalidItems[4]) } | ConvertTo-Json -Depth 10 -Compress)
            try { ConvertFrom-PVList -PVListJson $json5 } catch { $errorMsg5 = $_.Exception.Message }
            $errorMsg5 | Should -BeLike '*spec.hostPath.path*'
        }
    }
}

Describe 'Get-PersistentVolumes and Backup-AllPersistentVolumes PV discovery' -Tag 'unit', 'ci', 'backup-pv' {
    BeforeAll {
        # kubectl is replaced by a function so that no real cluster is needed
        function global:kubectl { $global:LASTEXITCODE = $global:K2sTestKubectlExitCode; $global:K2sTestKubectlOutput }
        Mock -ModuleName $moduleName Write-Log {}
        Mock -ModuleName $moduleName Export-PersistentVolume { return $true }
    }

    AfterAll {
        Remove-Item -Path function:global:kubectl -ErrorAction SilentlyContinue
        Remove-Variable -Name K2sTestKubectlExitCode, K2sTestKubectlOutput -Scope Global -ErrorAction SilentlyContinue
    }

    It 'throws instead of returning an empty PV list when kubectl fails' {
        $global:K2sTestKubectlExitCode = 1
        $global:K2sTestKubectlOutput = 'The connection to the server 172.19.1.100:6443 was refused'

        InModuleScope $moduleName {
            { Get-PersistentVolumes } | Should -Throw '*Failed to query PersistentVolumes*connection to the server*was refused*'
        }
    }

    It 'throws when the kubectl output cannot be parsed' {
        $global:K2sTestKubectlExitCode = 0
        $global:K2sTestKubectlOutput = '{ not valid json'

        InModuleScope $moduleName {
            { Get-PersistentVolumes } | Should -Throw '*Failed to query PersistentVolumes*'
        }
    }

    It 'returns an empty result when the cluster has no PVs' {
        $global:K2sTestKubectlExitCode = 0
        $global:K2sTestKubectlOutput = '{ "apiVersion": "v1", "kind": "List", "items": [] }'

        InModuleScope $moduleName {
            $result = Get-PersistentVolumes
            @($result).Count | Should -Be 0
        }
    }

    It 'propagates a discovery failure from Backup-AllPersistentVolumes instead of reporting no PVs' {
        $global:K2sTestKubectlExitCode = 1
        $global:K2sTestKubectlOutput = 'Unable to connect to the server'

        { Backup-AllPersistentVolumes -ExportPath (Join-Path $TestDrive 'pv') } | Should -Throw '*Failed to query PersistentVolumes*Unable to connect*'
        Should -Invoke -ModuleName $moduleName Export-PersistentVolume -Exactly 0 -Scope It
    }

    It 'returns an empty report from Backup-AllPersistentVolumes when discovery succeeds without PVs' {
        $global:K2sTestKubectlExitCode = 0
        $global:K2sTestKubectlOutput = '{ "apiVersion": "v1", "kind": "List", "items": [] }'

        $result = Backup-AllPersistentVolumes -ExportPath (Join-Path $TestDrive 'pv')

        @($result.Discovered).Count | Should -Be 0
        @($result.Excluded).Count | Should -Be 0
        @($result.Unsupported).Count | Should -Be 0
        $result.Results | Should -BeOfType [hashtable]
        $result.Results.Count | Should -Be 0
    }

    It 'returns a per-PV result for each discovered local PV' {
        $global:K2sTestKubectlExitCode = 0
        $global:K2sTestKubectlOutput = @{
            items = @(
                @{ metadata = @{ name = 'pv-a' }; spec = @{ capacity = @{ storage = '1Gi' }; local = @{ path = '/data/a' } }; status = @{ phase = 'Bound' } },
                @{ metadata = @{ name = 'pv-b' }; spec = @{ capacity = @{ storage = '1Gi' }; hostPath = @{ path = '/data/b' } }; status = @{ phase = 'Bound' } }
            )
        } | ConvertTo-Json -Depth 10 -Compress
        Mock -ModuleName $moduleName Export-PersistentVolume { return ($PVName -ne 'pv-b') }

        $result = Backup-AllPersistentVolumes -ExportPath (Join-Path $TestDrive 'pv')

        $result.Results.Count | Should -Be 2
        $result.Results['pv-a'] | Should -BeTrue
        $result.Results['pv-b'] | Should -BeFalse
        @($result.Discovered).Count | Should -Be 2
    }

    It 'reports a single discovered PV' {
        $global:K2sTestKubectlExitCode = 0
        $global:K2sTestKubectlOutput = @{
            items = @(
                @{ metadata = @{ name = 'pv-a' }; spec = @{ capacity = @{ storage = '1Gi' }; local = @{ path = '/data/a' } }; status = @{ phase = 'Bound' } }
            )
        } | ConvertTo-Json -Depth 10 -Compress

        $result = Backup-AllPersistentVolumes -ExportPath (Join-Path $TestDrive 'pv')

        @($result.Discovered).Count | Should -Be 1
        $result.Results['pv-a'] | Should -BeTrue
    }

    It 'separates excluded and unsupported PVs from attempted backups and logs unsupported PV names and types' {
        $global:K2sTestKubectlExitCode = 0
        $global:K2sTestKubectlOutput = @{
            items = @(
                @{ metadata = @{ name = 'pv-local' }; spec = @{ capacity = @{ storage = '1Gi' }; local = @{ path = '/data/a' } }; status = @{ phase = 'Bound' } },
                @{ metadata = @{ name = 'pv-host' }; spec = @{ capacity = @{ storage = '1Gi' }; hostPath = @{ path = '/data/b' } }; status = @{ phase = 'Bound' } },
                @{ metadata = @{ name = 'pv-nfs' }; spec = @{ capacity = @{ storage = '1Gi' }; accessModes = @('ReadWriteMany'); nfs = @{ server = 'srv'; path = '/export' } }; status = @{ phase = 'Bound' } },
                @{ metadata = @{ name = 'pv-csi' }; spec = @{ capacity = @{ storage = '1Gi' }; csi = @{ driver = 'smb.csi.k8s.io'; volumeHandle = 'h' } }; status = @{ phase = 'Bound' } },
                @{ metadata = @{ name = 'pv-excluded' }; spec = @{ capacity = @{ storage = '1Gi' }; local = @{ path = '/data/c' } }; status = @{ phase = 'Bound' } }
            )
        } | ConvertTo-Json -Depth 10 -Compress

        $result = Backup-AllPersistentVolumes -ExportPath (Join-Path $TestDrive 'pv') -ExcludeNames @('pv-excluded')

        @($result.Discovered).Count | Should -Be 5
        $result.Excluded | Should -Be @('pv-excluded')
        @($result.Unsupported | ForEach-Object { "$($_.Name)=$($_.Type)" } | Sort-Object) | Should -Be @('pv-csi=csi (smb.csi.k8s.io)', 'pv-nfs=nfs')
        @($result.Results.Keys | Sort-Object) | Should -Be @('pv-host', 'pv-local')
        Should -Invoke -ModuleName $moduleName Export-PersistentVolume -Exactly 2 -Scope It
        Should -Invoke -ModuleName $moduleName Export-PersistentVolume -Exactly 0 -Scope It -ParameterFilter { $PVName -in @('pv-nfs', 'pv-csi', 'pv-excluded') }
        Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "PV 'pv-nfs' cannot be backed up: unsupported volume type 'nfs'" }
        Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -match "PV 'pv-csi' cannot be backed up: unsupported volume type 'csi \(smb\.csi\.k8s\.io\)'" }
    }
}

Describe 'Export-PersistentVolume backup integrity' -Tag 'unit', 'ci', 'backup-pv' {
    BeforeAll {
        # kubectl is replaced by a function: 'kubectl get pv <name> -o json' returns a single PV, 'kubectl get pv -o json' the list
        function global:kubectl {
            $global:LASTEXITCODE = 0
            if ($args.Count -ge 3 -and $args[2] -ne '-o') { $global:K2sTestPvJson[[string]$args[2]] } else { $global:K2sTestPvListJson }
        }
        function New-TestHostPathPv([string]$Name, [string]$Path) {
            @{
                metadata = @{ name = $Name }
                spec     = @{
                    capacity                      = @{ storage = '1Gi' }
                    hostPath                      = @{ path = $Path }
                    claimRef                      = @{ namespace = 'default'; name = "$Name-claim" }
                    persistentVolumeReclaimPolicy = 'Retain'
                }
                status   = @{ phase = 'Bound' }
            }
        }
        function Set-TestPvs([hashtable[]]$Pvs) {
            $global:K2sTestPvJson = @{}
            foreach ($pv in $Pvs) { $global:K2sTestPvJson[$pv.metadata.name] = $pv | ConvertTo-Json -Depth 10 }
            $global:K2sTestPvListJson = @{ items = @($Pvs) } | ConvertTo-Json -Depth 10
        }
        Mock -ModuleName $moduleName Write-Log {}
        Mock -ModuleName $moduleName Get-SSHKeyControlPlane { return 'C:\fake\id_rsa' }
        Mock -ModuleName $moduleName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
    }

    AfterAll {
        Remove-Item -Path function:global:kubectl -ErrorAction SilentlyContinue
        Remove-Variable -Name K2sTestPvJson, K2sTestPvListJson, K2sTestScpBytes, K2sTestScpExitCode, K2sTestBash -Scope Global -ErrorAction SilentlyContinue
    }

    Context 'with a mocked VM' {
        BeforeEach {
            Set-TestPvs @(New-TestHostPathPv -Name 'pv-data' -Path '/mnt/data')
            $exportPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $archivePath = Join-Path $exportPath 'pv-data-backup.tar.gz'
            $metadataPath = Join-Path $exportPath 'pv-data-backup-metadata.json'
            $global:K2sTestScpBytes = 64
            $global:K2sTestScpExitCode = 0

            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey { [pscustomobject]@{ Success = $true; Output = ''; ExitCode = 0 } }
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey { [pscustomobject]@{ Success = $true; Output = 'exists'; ExitCode = 0 } } -ParameterFilter { $CmdToExecute -like 'sudo test -d*' }
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey { [pscustomobject]@{ Success = $true; Output = '12K'; ExitCode = 0 } } -ParameterFilter { $CmdToExecute -like 'sudo du -sh*' }
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey { [pscustomobject]@{ Success = $true; Output = '64'; ExitCode = 0 } } -ParameterFilter { $CmdToExecute -like 'stat -c %s*' }
            Mock -ModuleName $moduleName scp.exe {
                $target = ([string]$args[-1]).Trim('"')
                if ($global:K2sTestScpExitCode -eq 0) { [IO.File]::WriteAllBytes($target, (New-Object byte[] $global:K2sTestScpBytes)) }
                $global:LASTEXITCODE = $global:K2sTestScpExitCode
            }
        }

        It 'backs up ordinary files and directories successfully' {
            $result = InModuleScope $moduleName -Parameters @{ ExportPath = $exportPath } { param($ExportPath) Export-PersistentVolume -PVName 'pv-data' -ExportPath $ExportPath }

            $result | Should -BeTrue
            (Get-Item -LiteralPath $archivePath).Length | Should -Be 64
            (Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json).pvName | Should -Be 'pv-data'
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Exactly 1 -Scope It -ParameterFilter { $CmdToExecute -like "*cp -r '/mnt/data'/. '/tmp/pv-backup-pv-data'/*" }
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Exactly 1 -Scope It -ParameterFilter { $CmdToExecute -eq "cd '/tmp/pv-backup-pv-data' && tar czf '/tmp/pv-backup-pv-data.tar.gz' ." }
            Should -Invoke -ModuleName $moduleName scp.exe -Exactly 1 -Scope It
            # pre-cleanup and post-transfer cleanup of the VM temporary files
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Exactly 2 -Scope It -ParameterFilter { $CmdToExecute -eq "sudo rm -rf '/tmp/pv-backup-pv-data' '/tmp/pv-backup-pv-data.tar.gz'" }
        }

        It 'copies the volume contents with /. so that top-level hidden entries are not skipped by a shell glob' {
            InModuleScope $moduleName -Parameters @{ ExportPath = $exportPath } { param($ExportPath) Export-PersistentVolume -PVName 'pv-data' -ExportPath $ExportPath } | Should -BeTrue

            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Exactly 1 -Scope It -ParameterFilter { $CmdToExecute -like "*cp -r*" -and $CmdToExecute -like "*'/mnt/data'/. *" -and $CmdToExecute -notlike '*/`**' }
        }

        It 'fails, skips archiving and cleans up when the copy command fails' {
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey { [pscustomobject]@{ Success = $false; Output = 'cp: cannot open file: Permission denied'; ExitCode = 1 } } -ParameterFilter { $CmdToExecute -like '*cp -r*' }

            $result = InModuleScope $moduleName -Parameters @{ ExportPath = $exportPath } { param($ExportPath) Export-PersistentVolume -PVName 'pv-data' -ExportPath $ExportPath }

            $result | Should -BeFalse
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Exactly 0 -Scope It -ParameterFilter { $CmdToExecute -like '*tar czf*' }
            Should -Invoke -ModuleName $moduleName scp.exe -Exactly 0 -Scope It
            Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -like "*Copying volume data from '/mnt/data' failed on VM (exit code: 1): cp: cannot open file: Permission denied*" }
            # pre-cleanup and cleanup after the error
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Exactly 2 -Scope It -ParameterFilter { $CmdToExecute -eq "sudo rm -rf '/tmp/pv-backup-pv-data' '/tmp/pv-backup-pv-data.tar.gz'" }
            Test-Path -LiteralPath $archivePath | Should -BeFalse
            Test-Path -LiteralPath $metadataPath | Should -BeFalse
        }

        It 'fails and cleans up when the tar command fails' {
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey { [pscustomobject]@{ Success = $false; Output = 'tar: ./db: Cannot open: Permission denied'; ExitCode = 2 } } -ParameterFilter { $CmdToExecute -like '*tar czf*' }

            $result = InModuleScope $moduleName -Parameters @{ ExportPath = $exportPath } { param($ExportPath) Export-PersistentVolume -PVName 'pv-data' -ExportPath $ExportPath }

            $result | Should -BeFalse
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Exactly 0 -Scope It -ParameterFilter { $CmdToExecute -like 'stat -c %s*' }
            Should -Invoke -ModuleName $moduleName scp.exe -Exactly 0 -Scope It
            Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -like "*Archiving volume data to '/tmp/pv-backup-pv-data.tar.gz' failed on VM (exit code: 2): tar: ./db: Cannot open: Permission denied*" }
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Exactly 2 -Scope It -ParameterFilter { $CmdToExecute -eq "sudo rm -rf '/tmp/pv-backup-pv-data' '/tmp/pv-backup-pv-data.tar.gz'" }
            Test-Path -LiteralPath $archivePath | Should -BeFalse
            Test-Path -LiteralPath $metadataPath | Should -BeFalse
        }

        It 'fails when the archive is missing on the VM after tar' {
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey { [pscustomobject]@{ Success = $false; Output = "stat: cannot statx '/tmp/pv-backup-pv-data.tar.gz': No such file or directory"; ExitCode = 1 } } -ParameterFilter { $CmdToExecute -like 'stat -c %s*' }

            $result = InModuleScope $moduleName -Parameters @{ ExportPath = $exportPath } { param($ExportPath) Export-PersistentVolume -PVName 'pv-data' -ExportPath $ExportPath }

            $result | Should -BeFalse
            Should -Invoke -ModuleName $moduleName scp.exe -Exactly 0 -Scope It
            Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -like "*Verifying archive '/tmp/pv-backup-pv-data.tar.gz' failed on VM (exit code: 1)*No such file or directory*" }
            Test-Path -LiteralPath $archivePath | Should -BeFalse
            Test-Path -LiteralPath $metadataPath | Should -BeFalse
        }

        It 'fails when the archive on the VM is empty' {
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey { [pscustomobject]@{ Success = $true; Output = '0'; ExitCode = 0 } } -ParameterFilter { $CmdToExecute -like 'stat -c %s*' }

            $result = InModuleScope $moduleName -Parameters @{ ExportPath = $exportPath } { param($ExportPath) Export-PersistentVolume -PVName 'pv-data' -ExportPath $ExportPath }

            $result | Should -BeFalse
            Should -Invoke -ModuleName $moduleName scp.exe -Exactly 0 -Scope It
            Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -like "*Archive '/tmp/pv-backup-pv-data.tar.gz' on VM is empty*" }
            Test-Path -LiteralPath $metadataPath | Should -BeFalse
        }

        It 'fails and removes the local file when the transferred archive is empty' {
            $global:K2sTestScpBytes = 0

            $result = InModuleScope $moduleName -Parameters @{ ExportPath = $exportPath } { param($ExportPath) Export-PersistentVolume -PVName 'pv-data' -ExportPath $ExportPath }

            $result | Should -BeFalse
            Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -like '*Transferred archive is empty*' }
            Test-Path -LiteralPath $archivePath | Should -BeFalse
            Test-Path -LiteralPath $metadataPath | Should -BeFalse
        }

        It 'fails and removes the local file when the transferred archive is truncated' {
            $global:K2sTestScpBytes = 10

            $result = InModuleScope $moduleName -Parameters @{ ExportPath = $exportPath } { param($ExportPath) Export-PersistentVolume -PVName 'pv-data' -ExportPath $ExportPath }

            $result | Should -BeFalse
            Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -like '*Transferred archive size (10 bytes) does not match archive size on VM (64 bytes)*' }
            Test-Path -LiteralPath $archivePath | Should -BeFalse
            Test-Path -LiteralPath $metadataPath | Should -BeFalse
        }

        It 'does not issue VM cleanup for undetermined paths when the export fails before the backup paths are set' {
            $global:K2sTestPvJson['pv-data'] = '{ not valid json'

            $result = InModuleScope $moduleName -Parameters @{ ExportPath = $exportPath } { param($ExportPath) Export-PersistentVolume -PVName 'pv-data' -ExportPath $ExportPath }

            $result | Should -BeFalse
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Exactly 0 -Scope It
            Should -Invoke -ModuleName $moduleName scp.exe -Exactly 0 -Scope It
        }

        Context 'when called through Backup-AllPersistentVolumes' {
            It 'reports a failed export as a failed PV result' {
                Set-TestPvs @((New-TestHostPathPv -Name 'pv-good' -Path '/mnt/good'), (New-TestHostPathPv -Name 'pv-bad' -Path '/mnt/bad'))
                Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey { [pscustomobject]@{ Success = $false; Output = 'cp: read error: Input/output error'; ExitCode = 1 } } -ParameterFilter { $CmdToExecute -like "*cp -r '/mnt/bad'/.*" }

                $report = Backup-AllPersistentVolumes -ExportPath $exportPath

                @($report.Discovered.Name | Sort-Object) | Should -Be @('pv-bad', 'pv-good')
                @($report.Unsupported).Count | Should -Be 0
                $report.Results['pv-good'] | Should -BeTrue
                $report.Results['pv-bad'] | Should -BeFalse
                Test-Path -LiteralPath (Join-Path $exportPath 'pv-good-backup.tar.gz') | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $exportPath 'pv-bad-backup.tar.gz') | Should -BeFalse
                Should -Invoke -ModuleName $moduleName Write-Log -Exactly 1 -Scope It -ParameterFilter { $Messages -like '*Success: 1 | Failed: 1*' }
            }
        }
    }

    Context 'with real cp and tar semantics (Git Bash)' {
        BeforeAll {
            $global:K2sTestBash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
            function Invoke-TestBash([string]$Command) { & $global:K2sTestBash --noprofile --norc -c "export PATH=/usr/bin:/bin; $Command" 2>&1 }
        }

        BeforeEach {
            # Runs the generated VM commands locally in Git Bash; sudo and chown to the VM user are not available there
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey {
                $command = ($CmdToExecute -replace 'sudo ', '') -replace " && chown -R \S+ '[^']*'", ''
                $output = & $global:K2sTestBash --noprofile --norc -c "export PATH=/usr/bin:/bin; $command" 2>&1
                [pscustomobject]@{ Success = ($LASTEXITCODE -eq 0); Output = $output; ExitCode = $LASTEXITCODE }
            }
            Mock -ModuleName $moduleName scp.exe {
                $source = ([string]$args[-2]).Split(':', 2)[1]
                $target = ([string]$args[-1]).Trim('"')
                $windowsSource = ([string](& $global:K2sTestBash --noprofile --norc -c "export PATH=/usr/bin:/bin; cygpath -w '$source'")).Trim()
                Copy-Item -LiteralPath $windowsSource -Destination $target
                $global:LASTEXITCODE = 0
            }

            $pvName = 'pv-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $volumePath = Join-Path $TestDrive "$pvName-volume"
            $exportPath = Join-Path $TestDrive "$pvName-export"
            New-Item -ItemType Directory -Path (Join-Path $volumePath 'subdir') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $volumePath 'data.txt') -Value 'data'
            Set-Content -LiteralPath (Join-Path $volumePath 'subdir\nested.txt') -Value 'nested'
        }

        It 'includes a top-level hidden file in the archive' {
            if (-not $global:K2sTestBash) { Set-ItResult -Skipped -Because 'Git Bash is not available'; return }
            Set-Content -LiteralPath (Join-Path $volumePath '.top-hidden') -Value 'hidden'
            Set-TestPvs @(New-TestHostPathPv -Name $pvName -Path ([string](Invoke-TestBash "cygpath -u '$volumePath'")).Trim())

            $result = InModuleScope $moduleName -Parameters @{ PVName = $pvName; ExportPath = $exportPath } { param($PVName, $ExportPath) Export-PersistentVolume -PVName $PVName -ExportPath $ExportPath }

            $result | Should -BeTrue
            $archive = ([string](Invoke-TestBash "cygpath -u '$(Join-Path $exportPath "$pvName-backup.tar.gz")'")).Trim()
            $entries = @(Invoke-TestBash "tar tzf '$archive'" | ForEach-Object { "$_" })
            $entries | Should -Contain './.top-hidden'
            $entries | Should -Contain './data.txt'
            $entries | Should -Contain './subdir/nested.txt'
        }

        It 'includes a top-level hidden directory in the archive' {
            if (-not $global:K2sTestBash) { Set-ItResult -Skipped -Because 'Git Bash is not available'; return }
            New-Item -ItemType Directory -Path (Join-Path $volumePath '.hidden-dir') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $volumePath '.hidden-dir\inner.txt') -Value 'inner'
            Set-TestPvs @(New-TestHostPathPv -Name $pvName -Path ([string](Invoke-TestBash "cygpath -u '$volumePath'")).Trim())

            $result = InModuleScope $moduleName -Parameters @{ PVName = $pvName; ExportPath = $exportPath } { param($PVName, $ExportPath) Export-PersistentVolume -PVName $PVName -ExportPath $ExportPath }

            $result | Should -BeTrue
            $archive = ([string](Invoke-TestBash "cygpath -u '$(Join-Path $exportPath "$pvName-backup.tar.gz")'")).Trim()
            $entries = @(Invoke-TestBash "tar tzf '$archive'" | ForEach-Object { "$_" })
            $entries | Should -Contain './.hidden-dir/'
            $entries | Should -Contain './.hidden-dir/inner.txt'
            $entries | Should -Contain './data.txt'
            $entries | Should -Contain './subdir/nested.txt'
        }
    }
}

Describe 'Restore-AllPersistentVolumes backup presence' -Tag 'unit', 'ci', 'backup-pv' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
        Mock -ModuleName $moduleName Restore-PersistentVolume { return $true }
    }

    BeforeEach {
        $pvDir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -Path $pvDir -ItemType Directory -Force | Out-Null
    }

    It 'throws with RequireBackups when the backup directory does not exist' {
        { Restore-AllPersistentVolumes -BackupPath (Join-Path $pvDir 'missing') -Force -RequireBackups } | Should -Throw '*PV backup directory not found*'
        Should -Invoke -ModuleName $moduleName Restore-PersistentVolume -Exactly 0 -Scope It
    }

    It 'throws with RequireBackups when the backup directory contains no archives' {
        Set-Content -Path (Join-Path $pvDir 'pv-a-backup-metadata.json') -Value '{ "pvName": "pv-a" }'

        { Restore-AllPersistentVolumes -BackupPath $pvDir -Force -RequireBackups } | Should -Throw '*No PV backup archives found*'
        Should -Invoke -ModuleName $moduleName Restore-PersistentVolume -Exactly 0 -Scope It
    }

    It 'throws with RequireBackups when no archive has readable metadata' {
        Set-Content -Path (Join-Path $pvDir 'pv-a-backup.tar.gz') -Value 'data'

        { Restore-AllPersistentVolumes -BackupPath $pvDir -Force -RequireBackups } | Should -Throw '*None of the 1 PV backup archive(s)*can be restored*'
        Should -Invoke -ModuleName $moduleName Restore-PersistentVolume -Exactly 0 -Scope It
    }

    It 'returns an empty result without RequireBackups when <Name>' -TestCases @(
        @{ Name = 'the backup directory does not exist'; Missing = $true },
        @{ Name = 'the backup directory is empty'; Missing = $false }
    ) {
        param($Missing)
        $path = if ($Missing) { Join-Path $pvDir 'missing' } else { $pvDir }

        $result = Restore-AllPersistentVolumes -BackupPath $path -Force

        $result | Should -BeOfType [hashtable]
        $result.Count | Should -Be 0
    }

    It 'restores every archive with metadata when RequireBackups is set' {
        foreach ($pvName in @('pv-a', 'pv-b')) {
            Set-Content -Path (Join-Path $pvDir "$pvName-backup.tar.gz") -Value 'data'
            Set-Content -Path (Join-Path $pvDir "$pvName-backup-metadata.json") -Value "{ `"pvName`": `"$pvName`" }"
        }

        $result = Restore-AllPersistentVolumes -BackupPath $pvDir -Force -RequireBackups

        @($result.Keys | Sort-Object) | Should -Be @('pv-a', 'pv-b')
        Should -Invoke -ModuleName $moduleName Restore-PersistentVolume -Exactly 2 -Scope It
    }
}

Describe 'Get-BackupMetadata' -Tag 'unit', 'ci', 'backup-pv' {
    BeforeAll {
        $testDir = Join-Path $TestDrive "backup-metadata-tests"
        New-Item -Path $testDir -ItemType Directory -Force | Out-Null
        
        # Mock Write-Log to suppress error output during tests
        Mock -ModuleName $moduleName Write-Log {}
    }

    It 'loads valid backup metadata successfully' {
        
        $backupPath = Join-Path $testDir "test-pv-backup.tar.gz"
        $metadataPath = Join-Path $testDir "test-pv-backup-metadata.json"
        
       
        "mock backup data" | Set-Content -Path $backupPath -Encoding UTF8
        
        # Create metadata JSON
        $metadata = @{
            version = "1.0"
            backupType = "persistent-volume"
            pvName = "test-pv"
            volumeType = "local"
            volumePath = "/mnt/data"
            capacity = "10Gi"
            createdAt = "2024-12-15T10:00:00Z"
            sourceSize = "500MB"
            archiveSize = "250 MB"
            vmIpAddress = "172.19.1.100"
            backupFile = "test-pv-backup.tar.gz"
            claimNamespace = "default"
            claimName = "test-pvc"
            reclaimPolicy = "Retain"
        }
        $metadata | ConvertTo-Json -Depth 3 | Set-Content -Path $metadataPath -Encoding UTF8

        InModuleScope $moduleName -Parameters @{ backupPath = $backupPath } {
            param($backupPath)
            $result = Get-BackupMetadata -BackupPath $backupPath
            
            $result.Valid | Should -Be $true
            $result.Error | Should -BeNullOrEmpty
            $result.Metadata | Should -Not -BeNullOrEmpty
            $result.Metadata.pvName | Should -Be 'test-pv'
            $result.Metadata.volumeType | Should -Be 'local'
            $result.Metadata.volumePath | Should -Be '/mnt/data'
            $result.Metadata.capacity | Should -Be '10Gi'
            $result.Metadata.claimNamespace | Should -Be 'default'
            $result.Metadata.claimName | Should -Be 'test-pvc'
            $result.BackupFileSize | Should -BeGreaterThan 0
        }
    }

    It 'fails when backup file does not exist' {
        $nonExistentPath = Join-Path $testDir "nonexistent-backup.tar.gz"

        InModuleScope $moduleName -Parameters @{ nonExistentPath = $nonExistentPath } {
            param($nonExistentPath)
            $result = Get-BackupMetadata -BackupPath $nonExistentPath
            
            $result.Valid | Should -Be $false
            $result.Error | Should -BeLike '*not found*'
            $result.Metadata | Should -BeNullOrEmpty
        }
    }

    It 'fails when metadata file is missing' {
        # Create backup file without metadata
        $backupPath = Join-Path $testDir "orphaned-backup.tar.gz"
        "mock backup data" | Set-Content -Path $backupPath -Encoding UTF8

        InModuleScope $moduleName -Parameters @{ backupPath = $backupPath } {
            param($backupPath)
            $result = Get-BackupMetadata -BackupPath $backupPath
            
            $result.Valid | Should -Be $false
            $result.Error | Should -BeLike '*Metadata file not found*'
            $result.Metadata | Should -BeNullOrEmpty
        }
    }

    It 'fails when metadata JSON is invalid' {
        $backupPath = Join-Path $testDir "invalid-metadata-backup.tar.gz"
        $metadataPath = Join-Path $testDir "invalid-metadata-backup-metadata.json"
        
        "mock backup data" | Set-Content -Path $backupPath -Encoding UTF8
        "{ invalid json content" | Set-Content -Path $metadataPath -Encoding UTF8

        InModuleScope $moduleName -Parameters @{ backupPath = $backupPath } {
            param($backupPath)
            $result = Get-BackupMetadata -BackupPath $backupPath
            
            $result.Valid | Should -Be $false
            $result.Error | Should -BeLike '*Error loading metadata*'
            $result.Metadata | Should -BeNullOrEmpty
        }
    }

    It 'correctly reports backup file size' {
        $backupPath = Join-Path $testDir "size-test-backup.tar.gz"
        $metadataPath = Join-Path $testDir "size-test-backup-metadata.json"
        
        # Create larger dummy file (1KB)
        $dummyData = "x" * 1024
        $dummyData | Set-Content -Path $backupPath -Encoding ASCII -NoNewline
        
        $metadata = @{
            version = "1.0"
            pvName = "size-test-pv"
            volumePath = "/data"
        }
        $metadata | ConvertTo-Json | Set-Content -Path $metadataPath -Encoding ASCII

        InModuleScope $moduleName -Parameters @{ backupPath = $backupPath } {
            param($backupPath)
            $result = Get-BackupMetadata -BackupPath $backupPath
            
            $result.Valid | Should -Be $true
            $result.BackupFileSize | Should -Be 1024
        }
    }
}
