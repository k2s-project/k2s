# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

Describe 'Wait-KubeadmJoinProcess' -Tag 'unit', 'ci', 'cluster' {
BeforeAll {
    $modulePath = "$PSScriptRoot/setupcluster.module.psm1"
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    $waitFunction = $moduleAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-KubeadmJoinProcess'
    }, $false)
    . ([scriptblock]::Create($waitFunction.Extent.Text))

    $script:kubeToolsPath = 'C:\k'
    function Write-Log { param($Message, [switch]$Console) }
    function Stop-Process { [CmdletBinding()] param($Id, [switch]$Force) }
    function Get-Service { [CmdletBinding()] param($Name) }
}

Describe 'Linux join readiness monitoring' -Tag 'unit', 'ci', 'cluster' {
    BeforeAll {
        $parseErrors = $null
        $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot\setupcluster.module.psm1", [ref]$null, [ref]$parseErrors)
        if ($parseErrors) { throw ($parseErrors | Out-String) }
        $linuxJoin = $moduleAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Join-LinuxNode'
        }, $false)
        $windowsJoin = $moduleAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Join-WindowsNode'
        }, $false)
        if ($null -eq $linuxJoin -or $null -eq $windowsJoin) { throw 'Join functions missing from module.' }
    }

    It 'does not invoke the Windows process-monitor helper during Linux join' {
        $windowsMonitorCalls = @($linuxJoin.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.Extent.Text -match '\bWait-ForNodesReady\b'
        }, $true))

        $windowsMonitorCalls | Should -BeNullOrEmpty
    }

    It 'retains remote kubeadm join followed by the node-status check' {
        $remoteJoin = @($linuxJoin.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Invoke-CmdOnVmViaSSHKey' -and
                $node.Extent.Text -match '-CmdToExecute \$joinCommand\b'
        }, $true))
        $statusChecks = @($linuxJoin.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.Extent.Text -match '\bget node \$NodeName\b'
        }, $true))

        $remoteJoin.Count | Should -Be 1
        $statusChecks.Count | Should -Be 1
        $statusChecks[0].Extent.StartLineNumber | Should -BeGreaterThan $remoteJoin[0].Extent.StartLineNumber
    }

    It 'preserves the Windows monitor with its actual local kubeadm process ID' {
        $windowsMonitor = @($windowsJoin.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Start-Job' -and
                $node.Extent.Text -match '\bWait-ForNodesReady\b'
        }, $true))

        $windowsMonitor.Count | Should -Be 1
        $windowsMonitor[0].Extent.Text | Should -Match '-ArgumentList \$controlPlaneHostName, \$joinProcess\.Id'
    }
}

    BeforeEach {
        Mock Write-Log {}
        Mock Stop-Process {}
        Mock Get-Service {}
    }

    It 'returns the process exit code when kubeadm finishes in time' {
        $process = [pscustomobject]@{
            Handle = [intptr]::Zero
            Id = 42
            ExitCode = 0
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) return $true }

        $result = Wait-KubeadmJoinProcess -Process $process -StandardOutputPath 'missing.stdout' -StandardErrorPath 'missing.stderr'

        $result | Should -Be 0
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'terminates only the timed-out kubeadm process and throws' {
        $process = [pscustomobject]@{
            Handle = [intptr]::Zero
            Id = 73
            ExitCode = -1
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            param($milliseconds)
            if ($null -eq $milliseconds) { return }
            return $false
        }

        {
            Wait-KubeadmJoinProcess -Process $process -StandardOutputPath 'missing.stdout' `
                -StandardErrorPath 'missing.stderr' -TimeoutSeconds 1
        } | Should -Throw '*timed out after 1 seconds*'

        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 73 -and $Force }
    }
}

BeforeDiscovery {
    $script:kubectlMissing = -not (Test-Path ([System.IO.Path]::GetFullPath("$PSScriptRoot\..\..\..\..\..\..\bin\kube\kubectl.exe")))
}

# Shared fixtures for the Add-K8sContext suites. Everything runs in an isolated temp profile;
# the real %USERPROFILE%\.kube is never touched. This file must stay ASCII-only (PS 5.1 reads
# BOM-less scripts as ANSI), so non-ASCII names are built from code points.
BeforeAll {
    $modulePath = "$PSScriptRoot/setupcluster.module.psm1"
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    $kubeconfigFunctionNames = @(
        'Add-K8sContext', 'ConvertTo-KubectlArgumentString', 'Invoke-KubeconfigKubectl', 'Invoke-KubeconfigKubectlChecked',
        'Assert-KubeconfigBytes', 'Get-KubeconfigObject', 'Get-KubeconfigNamedEntries', 'Assert-MergedKubeconfig',
        'Write-KubeconfigStagingFile', 'Publish-KubeconfigFile', 'Assert-K2sCredentialData', 'Invoke-KubeconfigFileReplace', 'Test-KubeconfigFileUnchanged')
    $kubeconfigFunctions = $moduleAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $kubeconfigFunctionNames -contains $node.Name
        }, $false)
    foreach ($function in $kubeconfigFunctions) {
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $script:realWriteKubeconfigStagingFile = ${function:Write-KubeconfigStagingFile}
    $script:realInvokeKubeconfigFileReplace = ${function:Invoke-KubeconfigFileReplace}

    function Write-Log { param($Message, [switch]$Console) }
    function Get-InstalledClusterName { 'k2s-cluster' }

    $script:realKubectlExe = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\..\..\..\..\..\bin\kube\kubectl.exe")
    $script:utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $script:k2sContextName = 'kubernetes-admin@k2s-cluster'

    function New-Base64Data([int]$Seed, [int]$Length) {
        $random = New-Object System.Random($Seed)
        $buffer = New-Object byte[] $Length
        $random.NextBytes($buffer)
        return [Convert]::ToBase64String($buffer)
    }
    # Synthetic PEM (random body) encoded as base64, like kubeadm certificate/key data.
    function New-PemData([int]$Seed, [int]$Length, [string]$Label) {
        $body = New-Base64Data -Seed $Seed -Length $Length
        $lines = for ($i = 0; $i -lt $body.Length; $i += 64) { $body.Substring($i, [Math]::Min(64, $body.Length - $i)) }
        $pem = "-----BEGIN $Label-----`n" + ($lines -join "`n") + "`n-----END $Label-----`n"
        return [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pem))
    }
    $eAcute = [string][char]0x00E9
    $uUmlaut = [string][char]0x00FC
    $oUmlaut = [string][char]0x00F6
    $tokyo = [string][char]0x6771 + [char]0x4EAC
    $script:aksClusterName = "aks-prod-m${uUmlaut}nchen"
    $script:aksUserName = "clusterUser_rg_J${oUmlaut}rg"
    $script:aksContextName = "aks-Andr${eAcute}@$tokyo"
    $script:aksNamespace = "team-${uUmlaut}${oUmlaut}${eAcute}"

    function New-K2sCluster([int]$Seed) {
        [ordered]@{ name = 'k2s-cluster'; cluster = [ordered]@{ 'certificate-authority-data' = (New-PemData -Seed $Seed -Length 800 -Label 'CERTIFICATE'); server = 'https://172.19.1.100:6443' } }
    }
    function New-K2sUser([int]$Seed) {
        [ordered]@{ name = 'kubernetes-admin'; user = [ordered]@{ 'client-certificate-data' = (New-PemData -Seed ($Seed + 1) -Length 850 -Label 'CERTIFICATE'); 'client-key-data' = (New-PemData -Seed ($Seed + 2) -Length 1190 -Label 'RSA PRIVATE KEY') } }
    }
    function New-K2sContext {
        [ordered]@{ name = $script:k2sContextName; context = [ordered]@{ cluster = 'k2s-cluster'; user = 'kubernetes-admin' } }
    }
    function New-ForeignClusters {
        @(
            [ordered]@{ name = 'docker-desktop'; cluster = [ordered]@{ 'certificate-authority-data' = (New-Base64Data -Seed 40 -Length 600); server = 'https://kubernetes.docker.internal:6443' } },
            [ordered]@{ name = $script:aksClusterName; cluster = [ordered]@{ 'certificate-authority-data' = (New-Base64Data -Seed 41 -Length 600); server = 'https://aks-prod.hcp.westeurope.azmk8s.io:443' } }
        )
    }
    function New-ForeignUsers {
        @(
            [ordered]@{ name = 'docker-desktop'; user = [ordered]@{ 'client-certificate-data' = (New-Base64Data -Seed 42 -Length 700); 'client-key-data' = (New-Base64Data -Seed 43 -Length 900) } },
            [ordered]@{ name = $script:aksUserName; user = [ordered]@{ exec = [ordered]@{ apiVersion = 'client.authentication.k8s.io/v1beta1'; command = 'kubelogin'; args = @('get-token', '--login', 'azurecli', '--server-id', '6dae42f8-4368-4678-94ff-3960e28e3630'); interactiveMode = 'IfAvailable'; provideClusterInfo = $false } } }
        )
    }
    function New-ForeignContexts {
        @(
            [ordered]@{ name = 'docker-desktop'; context = [ordered]@{ cluster = 'docker-desktop'; user = 'docker-desktop' } },
            [ordered]@{ name = $script:aksContextName; context = [ordered]@{ cluster = $script:aksClusterName; namespace = $script:aksNamespace; user = $script:aksUserName } }
        )
    }

    # Kubeconfig fixtures are written as JSON, which is valid YAML for kubectl and readable by the fake kubectl.
    function New-KubeconfigText {
        param([object[]]$Clusters = @(), [object[]]$Users = @(), [object[]]$Contexts = @(), [string]$CurrentContext = '')
        $config = [ordered]@{
            apiVersion        = 'v1'
            kind              = 'Config'
            preferences       = [ordered]@{}
            clusters          = @($Clusters)
            users             = @($Users)
            contexts          = @($Contexts)
            'current-context' = $CurrentContext
        }
        return ($config | ConvertTo-Json -Depth 32)
    }
    function New-K2sSourceText([int]$Seed = 1) {
        New-KubeconfigText -Clusters @(New-K2sCluster $Seed) -Users @(New-K2sUser $Seed) -Contexts @(New-K2sContext) -CurrentContext $script:k2sContextName
    }
    function New-UserKubeconfigText([string]$CurrentContext, [switch]$IncludeStaleK2s) {
        $clusters = @(New-ForeignClusters)
        $users = @(New-ForeignUsers)
        $contexts = @(New-ForeignContexts)
        if ($IncludeStaleK2s) {
            # Stale K2s entries (old certificates) interleaved between foreign entries.
            $clusters = @($clusters[0], (New-K2sCluster 900), $clusters[1])
            $users = @($users[0], (New-K2sUser 900), $users[1])
            $contexts = @($contexts[0], (New-K2sContext), $contexts[1])
        }
        New-KubeconfigText -Clusters $clusters -Users $users -Contexts $contexts -CurrentContext $CurrentContext
    }

    function Write-TestFile([string]$Path, [string]$Content, [System.Text.Encoding]$Encoding = $script:utf8NoBom) {
        [System.IO.File]::WriteAllText($Path, $Content, $Encoding)
    }
    function Get-FileBase64([string]$Path) {
        [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
    }

    function Initialize-KubeconfigTestProfile {
        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-kubeconfig-test-$([guid]::NewGuid().ToString('N'))"
        $script:kubePath = Join-Path $script:testRoot 'k2s'
        $script:kubeConfigDir = Join-Path $script:testRoot 'profile\.kube'
        $script:userKubeconfig = Join-Path $script:kubeConfigDir 'config'
        $script:backupKubeconfig = Join-Path $script:kubeConfigDir 'config_backup'
        $script:k2sSourcePath = Join-Path $script:kubePath 'config'
        New-Item -ItemType Directory -Path $script:kubePath -Force | Out-Null
        Write-TestFile -Path $script:k2sSourcePath -Content (New-K2sSourceText)
        $script:savedEnv = @{ KUBECONFIG = $env:KUBECONFIG; HOME = $env:HOME; USERPROFILE = $env:USERPROFILE }
        $env:HOME = Join-Path $script:testRoot 'profile'
        $env:USERPROFILE = $env:HOME
        $env:KUBECONFIG = $null
    }
    function Remove-KubeconfigTestProfile {
        $env:KUBECONFIG = $script:savedEnv.KUBECONFIG
        $env:HOME = $script:savedEnv.HOME
        $env:USERPROFILE = $script:savedEnv.USERPROFILE
        if (Test-Path $script:userKubeconfig) { (Get-Item $script:userKubeconfig).IsReadOnly = $false }
        Remove-Item -Path $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    function Initialize-ExistingUserKubeconfig([string]$Content, [System.Text.Encoding]$Encoding = $script:utf8NoBom) {
        New-Item -ItemType Directory -Path $script:kubeConfigDir -Force | Out-Null
        Write-TestFile -Path $script:userKubeconfig -Content $Content -Encoding $Encoding
        Write-TestFile -Path $script:backupKubeconfig -Content 'previous backup'
        $script:originalUserBytes = Get-FileBase64 $script:userKubeconfig
        $script:originalBackupBytes = Get-FileBase64 $script:backupKubeconfig
    }

    function Assert-NoTemporaryFiles {
        $leftovers = @(Get-ChildItem -LiteralPath $script:kubeConfigDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('config', 'config_backup') })
        $leftovers.Name | Should -BeNullOrEmpty -Because 'staging, working and lock files must be cleaned up'
    }
    function Assert-UserKubeconfigUnchanged {
        Get-FileBase64 $script:userKubeconfig | Should -BeExactly $script:originalUserBytes -Because 'the user kubeconfig must stay byte-for-byte unchanged'
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalBackupBytes -Because 'config_backup must not be touched when nothing was committed'
        Assert-NoTemporaryFiles
        $env:KUBECONFIG | Should -BeNullOrEmpty
    }

    function Assert-PortableKubeconfigBytes([byte[]]$Bytes) {
        $Bytes.Length | Should -BeGreaterThan 0
        ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) | Should -BeFalse -Because 'UTF-16LE BOM must not be written'
        ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) | Should -BeFalse -Because 'UTF-16BE BOM must not be written'
        ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) | Should -BeFalse -Because 'UTF-8 BOM must not be written'
        [array]::IndexOf($Bytes, [byte]0) | Should -Be -1 -Because 'kubeconfig must not contain NUL bytes'
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($Bytes)
        $text.Contains([string][char]0) | Should -BeFalse
        return $text
    }

    function Get-EntryJson($Config, [string]$Section, [string]$Name) {
        $matching = @($Config.$Section | Where-Object { $null -ne $_ -and $_.name -ceq $Name })
        $matching.Count | Should -Be 1 -Because "exactly one $Section entry '$Name' is expected"
        return ($matching[0] | ConvertTo-Json -Compress -Depth 64)
    }

    # Verifies the committed user kubeconfig: encoding, K2s entries from the source, foreign entries unchanged, no extras.
    function Assert-UpdatedUserKubeconfig {
        param([string]$KubectlPath, $OriginalParsed, [string[]]$ForeignContexts = @(), [string[]]$ForeignClusters = @(), [string[]]$ForeignUsers = @())
        Assert-PortableKubeconfigBytes -Bytes ([System.IO.File]::ReadAllBytes($script:userKubeconfig)) | Out-Null
        $result = Get-KubeconfigObject -KubectlPath $KubectlPath -Path $script:userKubeconfig
        $source = Get-KubeconfigObject -KubectlPath $KubectlPath -Path $script:k2sSourcePath
        $result.'current-context' | Should -BeExactly $script:k2sContextName
        Get-EntryJson $result 'clusters' 'k2s-cluster' | Should -BeExactly (Get-EntryJson $source 'clusters' 'k2s-cluster')
        Get-EntryJson $result 'users' 'kubernetes-admin' | Should -BeExactly (Get-EntryJson $source 'users' 'kubernetes-admin')
        Get-EntryJson $result 'contexts' $script:k2sContextName | Should -BeExactly (Get-EntryJson $source 'contexts' $script:k2sContextName)
        foreach ($name in $ForeignClusters) { Get-EntryJson $result 'clusters' $name | Should -BeExactly (Get-EntryJson $OriginalParsed 'clusters' $name) }
        foreach ($name in $ForeignUsers) { Get-EntryJson $result 'users' $name | Should -BeExactly (Get-EntryJson $OriginalParsed 'users' $name) }
        foreach ($name in $ForeignContexts) { Get-EntryJson $result 'contexts' $name | Should -BeExactly (Get-EntryJson $OriginalParsed 'contexts' $name) }
        @($result.clusters).Count | Should -Be ($ForeignClusters.Count + 1)
        @($result.users).Count | Should -Be ($ForeignUsers.Count + 1)
        @($result.contexts).Count | Should -Be ($ForeignContexts.Count + 1)
        return $result
    }

    $script:foreignContextNames = @('docker-desktop', $script:aksContextName)
    $script:foreignClusterNames = @('docker-desktop', $script:aksClusterName)
    $script:foreignUserNames = @('docker-desktop', $script:aksUserName)
}

# Unit suite: kubectl is replaced by an in-process fake (JSON kubeconfigs), so it runs in CI
# without bin\kube\kubectl.exe. Faults are injected at every stage of Add-K8sContext.
Describe 'Add-K8sContext safe kubeconfig merge (fake kubectl)' -Tag 'unit', 'ci', 'cluster' {
    BeforeAll {
        $script:fakeKubectlPath = 'C:\fake\kubectl.exe'

        function Read-FakeKubeconfig([string]$Path) {
            $empty = [pscustomobject][ordered]@{ kind = 'Config'; apiVersion = 'v1'; clusters = $null; users = $null; contexts = $null; 'current-context' = '' }
            if (!(Test-Path -LiteralPath $Path)) { return $empty }
            $bytes = [System.IO.File]::ReadAllBytes($Path)
            if ($bytes.Length -eq 0) { return $empty }
            $reader = New-Object System.IO.StreamReader((New-Object System.IO.MemoryStream(, $bytes)), (New-Object System.Text.UTF8Encoding($false, $true)), $true)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            if ($text.IndexOf([char]0) -ge 0) { throw 'null byte is not allowed in input' }
            return ($text | ConvertFrom-Json)
        }
        function Write-FakeKubeconfig([string]$Path, $Config) {
            [System.IO.File]::WriteAllText($Path, ($Config | ConvertTo-Json -Depth 64), $script:utf8NoBom)
        }
        function New-FakeResult([int]$ExitCode, [byte[]]$StdOut = @(), [string]$StdErr = '') {
            [pscustomobject]@{ ExitCode = $ExitCode; StdOut = [byte[]]$StdOut; StdErr = $StdErr }
        }

        function Invoke-FakeKubectl([string[]]$Arguments, [string]$KubeConfig) {
            $script:kubectlCalls.Add([pscustomobject]@{ Arguments = $Arguments; KubeConfig = $KubeConfig })
            $fault = $script:fault
            $faultHit = ($null -ne $fault) -and (& $fault.Match $Arguments $KubeConfig)
            if ($faultHit -and $fault.Mode -eq 'fail') { return (New-FakeResult -ExitCode 1 -StdErr 'injected kubectl failure') }
            if ($faultHit -and $fault.Mode -eq 'empty') { return (New-FakeResult -ExitCode 0) }
            $kubeconfigArg = $null
            for ($i = 0; $i -lt $Arguments.Count - 1; $i++) { if ($Arguments[$i] -eq '--kubeconfig') { $kubeconfigArg = $Arguments[$i + 1] } }
            try {
                $verb = $Arguments[1]
                if ($verb -eq 'view') {
                    if ($kubeconfigArg) {
                        $config = Read-FakeKubeconfig $kubeconfigArg
                    }
                    else {
                        $merged = [ordered]@{ apiVersion = 'v1'; kind = 'Config'; clusters = @(); users = @(); contexts = @(); 'current-context' = '' }
                        foreach ($file in @($KubeConfig -split ';' | Where-Object { $_ })) {
                            $part = Read-FakeKubeconfig $file
                            foreach ($section in @('clusters', 'users', 'contexts')) {
                                foreach ($entry in @($part.$section | Where-Object { $null -ne $_ })) {
                                    if (@($merged[$section] | Where-Object { $_.name -ceq $entry.name }).Count -eq 0) { $merged[$section] = @($merged[$section]) + $entry }
                                }
                            }
                            if ([string]::IsNullOrEmpty($merged['current-context']) -and $part.'current-context') { $merged['current-context'] = $part.'current-context' }
                        }
                        if ($faultHit -and $fault.Mode -eq 'dropForeign') { $merged['contexts'] = @($merged['contexts'] | Where-Object { $_.name -cne 'docker-desktop' }) }
                        $config = [pscustomobject]$merged
                    }
                    $text = ($config | ConvertTo-Json -Depth 64) + "`n"
                    if ($faultHit -and $fault.Mode -eq 'utf16') { return (New-FakeResult -ExitCode 0 -StdOut ([System.Text.Encoding]::Unicode.GetPreamble() + [System.Text.Encoding]::Unicode.GetBytes($text))) }
                    $bytes = $script:utf8NoBom.GetBytes($text)
                    if ($faultHit -and $fault.Mode -eq 'nul') { $bytes = $bytes + [byte]0 }
                    return (New-FakeResult -ExitCode 0 -StdOut $bytes)
                }
                $config = Read-FakeKubeconfig $kubeconfigArg
                $name = $Arguments[2]
                $sectionByVerb = @{ 'delete-context' = 'contexts'; 'delete-cluster' = 'clusters'; 'delete-user' = 'users' }
                if ($sectionByVerb.ContainsKey($verb)) {
                    $section = $sectionByVerb[$verb]
                    if (@($config.$section | Where-Object { $null -ne $_ -and $_.name -ceq $name }).Count -eq 0) { return (New-FakeResult -ExitCode 1 -StdErr "cannot delete $name") }
                    $config.$section = @($config.$section | Where-Object { $null -ne $_ -and $_.name -cne $name })
                }
                elseif ($verb -eq 'use-context') {
                    if (@($config.contexts | Where-Object { $null -ne $_ -and $_.name -ceq $name }).Count -eq 0) { return (New-FakeResult -ExitCode 1 -StdErr "no context exists with the name: $name") }
                    $config.'current-context' = $name
                }
                else {
                    return (New-FakeResult -ExitCode 1 -StdErr "unsupported fake command: $($Arguments -join ' ')")
                }
                Write-FakeKubeconfig $kubeconfigArg $config
                return (New-FakeResult -ExitCode 0)
            }
            catch {
                return (New-FakeResult -ExitCode 1 -StdErr "error loading config: $($_.Exception.Message)")
            }
        }
    }

    BeforeEach {
        Initialize-KubeconfigTestProfile
        $script:kubeToolsPath = Split-Path $script:fakeKubectlPath -Parent
        $script:fault = $null
        $script:kubectlCalls = New-Object System.Collections.Generic.List[object]
        Mock Invoke-KubeconfigKubectl { Invoke-FakeKubectl -Arguments $Arguments -KubeConfig $KubeConfig }
    }

    AfterEach {
        Remove-KubeconfigTestProfile
    }

    It 'never runs a mutating kubectl command against the user kubeconfig' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:k2sContextName -IncludeStaleK2s)

        Add-K8sContext

        $mutating = @($script:kubectlCalls | Where-Object { $_.Arguments[1] -notin @('view') })
        $mutating.Count | Should -BeGreaterThan 0
        foreach ($call in $mutating) {
            $call.Arguments | Should -Not -Contain $script:userKubeconfig
            $call.KubeConfig | Should -BeNullOrEmpty
        }
        @($script:kubectlCalls | Where-Object { $_.KubeConfig }) | ForEach-Object { ($_.KubeConfig -split ';') | Should -Not -Contain $script:userKubeconfig }
    }

    It 'fresh install creates a validated kubeconfig with the K2s context' {
        Add-K8sContext

        Assert-UpdatedUserKubeconfig -KubectlPath $script:fakeKubectlPath | Out-Null
        Test-Path $script:backupKubeconfig | Should -BeFalse
        Assert-NoTemporaryFiles
    }

    It 'replaces stale K2s entries, preserves foreign entries and keeps the original as config_backup (current context: <Current>)' -ForEach @(
        @{ Current = 'k2s' }, @{ Current = 'foreign' }
    ) {
        $current = if ($Current -eq 'k2s') { $script:k2sContextName } else { $script:aksContextName }
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $current -IncludeStaleK2s)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:fakeKubectlPath -Path $script:userKubeconfig

        Add-K8sContext

        Assert-UpdatedUserKubeconfig -KubectlPath $script:fakeKubectlPath -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalUserBytes
        Assert-NoTemporaryFiles
    }

    It 'repairs a UTF-16LE kubeconfig without losing entries' {
        Initialize-ExistingUserKubeconfig -Content ((New-UserKubeconfigText -CurrentContext $script:k2sContextName -IncludeStaleK2s) -replace "`r?`n", "`r`n") -Encoding ([System.Text.Encoding]::Unicode)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:fakeKubectlPath -Path $script:userKubeconfig

        Add-K8sContext

        Assert-UpdatedUserKubeconfig -KubectlPath $script:fakeKubectlPath -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
    }

    It 'repeated execution and certificate renewal stay deterministic without duplicates' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:fakeKubectlPath -Path $script:userKubeconfig

        Add-K8sContext
        $first = Get-FileBase64 $script:userKubeconfig
        Add-K8sContext
        Get-FileBase64 $script:userKubeconfig | Should -BeExactly $first

        # Renewal: same function, new K2s certificates in '<install>\config'.
        Write-TestFile -Path $script:k2sSourcePath -Content (New-K2sSourceText -Seed 77)
        Add-K8sContext
        Assert-UpdatedUserKubeconfig -KubectlPath $script:fakeKubectlPath -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
        Get-FileBase64 $script:userKubeconfig | Should -Not -BeExactly $first
        Assert-NoTemporaryFiles
    }

    It 'leaves the user kubeconfig byte-for-byte unchanged when <Stage> fails' -ForEach @(
        @{ Stage = 'parsing the K2s kubeconfig'; Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'view' -and $a[-1] -like '*\k2s\config' } }
        @{ Stage = 'parsing the user kubeconfig'; Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'view' -and $a[-1] -like '*\.kube\config' } }
        @{ Stage = 'kubectl config delete-context'; Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'delete-context' } }
        @{ Stage = 'kubectl config delete-cluster'; Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'delete-cluster' } }
        @{ Stage = 'kubectl config delete-user'; Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'delete-user' } }
        @{ Stage = 'merged config generation'; Mode = 'fail'; Match = { param($a, $k) $k -like '*;*' } }
        @{ Stage = 'merged config generation (empty output)'; Mode = 'empty'; Match = { param($a, $k) $k -like '*;*' } }
        @{ Stage = 'merged config generation (UTF-16 output)'; Mode = 'utf16'; Match = { param($a, $k) $k -like '*;*' } }
        @{ Stage = 'merged config generation (NUL byte)'; Mode = 'nul'; Match = { param($a, $k) $k -like '*;*' } }
        @{ Stage = 'merged config validation (foreign context lost)'; Mode = 'dropForeign'; Match = { param($a, $k) $k -like '*;*' } }
        @{ Stage = 'kubectl config use-context'; Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'use-context' } }
        @{ Stage = 'parsing the staged kubeconfig'; Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'view' -and $a[-1] -like '*.new' } }
        @{ Stage = 'parsing the staged kubeconfig (empty output)'; Mode = 'empty'; Match = { param($a, $k) $a[1] -eq 'view' -and $a[-1] -like '*.new' } }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $script:fault = @{ Mode = $Mode; Match = $Match }

        { Add-K8sContext } | Should -Throw '*KubeConfig*'

        Assert-UserKubeconfigUnchanged
    }

    It 'leaves the user kubeconfig byte-for-byte unchanged when <Stage> fails' -ForEach @(
        @{ Stage = 'the staging-file write'; Command = 'Write-KubeconfigStagingFile' }
        @{ Stage = 'the final validation'; Command = 'Assert-MergedKubeconfig' }
        @{ Stage = 'the replacement'; Command = 'Publish-KubeconfigFile' }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:k2sContextName -IncludeStaleK2s)
        Mock $Command { throw '[KubeConfig] injected failure' }

        { Add-K8sContext } | Should -Throw '*injected failure*'

        Assert-UserKubeconfigUnchanged
    }

    It 'keeps the original and cleans up when File.Replace is denied (read-only target)' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:k2sContextName -IncludeStaleK2s)
        (Get-Item $script:userKubeconfig).IsReadOnly = $true

        { Add-K8sContext } | Should -Throw '*denied*'

        Assert-UserKubeconfigUnchanged
    }

    It 'does not overwrite a kubeconfig that another process changed during the update' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:k2sContextName)
        $script:concurrent = New-UserKubeconfigText -CurrentContext 'docker-desktop'
        Mock Write-KubeconfigStagingFile {
            & $script:realWriteKubeconfigStagingFile -Path $Path -Bytes $Bytes
            Write-TestFile -Path $script:userKubeconfig -Content $script:concurrent
        }

        { Add-K8sContext } | Should -Throw '*modified by another process*'

        [System.IO.File]::ReadAllText($script:userKubeconfig) | Should -BeExactly $script:concurrent
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalBackupBytes
        Assert-NoTemporaryFiles
    }

    It 'fails without creating a user kubeconfig when the K2s kubeconfig is <Case>' -ForEach @(
        @{ Case = 'missing' }, @{ Case = 'empty' }
    ) {
        if ($Case -eq 'missing') { Remove-Item $script:k2sSourcePath } else { Write-TestFile -Path $script:k2sSourcePath -Content '' }

        { Add-K8sContext } | Should -Throw '*missing or empty*'

        Test-Path $script:userKubeconfig | Should -BeFalse
    }

    It 'fails and keeps the user kubeconfig when the K2s kubeconfig is <Case>' -ForEach @(
        @{ Case = 'missing' }, @{ Case = 'empty' }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:k2sContextName -IncludeStaleK2s)
        if ($Case -eq 'missing') { Remove-Item $script:k2sSourcePath } else { Write-TestFile -Path $script:k2sSourcePath -Content '' }

        { Add-K8sContext } | Should -Throw '*missing or empty*'

        Assert-UserKubeconfigUnchanged
    }

    It 'quotes native arguments with spaces, quotes and trailing backslashes' {
        ConvertTo-KubectlArgumentString -Arguments @('config', 'view', '--kubeconfig', 'C:\Users\J Doe\.kube\config') | Should -BeExactly 'config view --kubeconfig "C:\Users\J Doe\.kube\config"'
        ConvertTo-KubectlArgumentString -Arguments @('a"b', 'C:\dir with space\', '') | Should -BeExactly '"a\"b" "C:\dir with space\\" ""'
    }

    It 'repairs the user kubeconfig states observed on an affected machine (<Case>)' -ForEach @(
        @{ Case = '0-byte config'; Content = '' }
        @{ Case = 'config with null clusters/users/contexts'; Content = '{"apiVersion":"v1","clusters":null,"contexts":null,"current-context":"kubernetes-admin@k2s-cluster","kind":"Config","users":null}' }
    ) {
        Initialize-ExistingUserKubeconfig -Content $Content

        Add-K8sContext

        Assert-UpdatedUserKubeconfig -KubectlPath $script:fakeKubectlPath | Out-Null
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalUserBytes -Because 'config_backup must hold the pre-update content'
        Assert-NoTemporaryFiles
    }

    It 'fresh install does not overwrite a kubeconfig created by another process during the update' {
        $script:concurrent = New-UserKubeconfigText -CurrentContext 'docker-desktop'
        Mock Write-KubeconfigStagingFile {
            & $script:realWriteKubeconfigStagingFile -Path $Path -Bytes $Bytes
            Write-TestFile -Path $script:userKubeconfig -Content $script:concurrent
        }

        { Add-K8sContext } | Should -Throw '*created by another process*'

        [System.IO.File]::ReadAllText($script:userKubeconfig) | Should -BeExactly $script:concurrent
        Test-Path $script:backupKubeconfig | Should -BeFalse
        Assert-NoTemporaryFiles
        $env:KUBECONFIG | Should -BeNullOrEmpty
    }

    It 'leaves the user kubeconfig unchanged when it cannot be read (exclusively locked)' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $lock = New-Object System.IO.FileStream($script:userKubeconfig, 'Open', 'Read', 'None')
        try {
            { Add-K8sContext } | Should -Throw
        }
        finally {
            $lock.Dispose()
        }

        Assert-UserKubeconfigUnchanged
    }

    It 'keeps the original when another process holds the destination open for <Access> at replacement time' -ForEach @(
        @{ Access = 'Read'; Expected = '*replacing*left unchanged*' }
        @{ Access = 'ReadWrite'; Expected = '*in use by another process*' }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $script:lockAccess = $Access
        $script:lockHandle = $null
        Mock Write-KubeconfigStagingFile {
            & $script:realWriteKubeconfigStagingFile -Path $Path -Bytes $Bytes
            $script:lockHandle = New-Object System.IO.FileStream($script:userKubeconfig, 'Open', $script:lockAccess, 'ReadWrite')
        }
        try {
            { Add-K8sContext } | Should -Throw $Expected
        }
        finally {
            if ($script:lockHandle) { $script:lockHandle.Dispose() }
        }

        Assert-UserKubeconfigUnchanged
    }

    It 'blocks in-place writers between the change check and the swap' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $script:writerResult = $null
        Mock Invoke-KubeconfigFileReplace {
            try { [System.IO.File]::WriteAllText($Path, 'concurrent writer'); $script:writerResult = 'written' } catch { $script:writerResult = 'blocked' }
            & $script:realInvokeKubeconfigFileReplace -StagingPath $StagingPath -Path $Path -BackupPath $BackupPath
        }

        Add-K8sContext

        $script:writerResult | Should -Be 'blocked'
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalUserBytes
        Assert-UpdatedUserKubeconfig -KubectlPath $script:fakeKubectlPath -OriginalParsed (Get-KubeconfigObject -KubectlPath $script:fakeKubectlPath -Path $script:backupKubeconfig) `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
        Assert-NoTemporaryFiles
    }

    It 'restores the original when File.Replace fails after moving it to the backup name' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        # Simulates ERROR_UNABLE_TO_MOVE_REPLACEMENT_2: target already renamed to the backup name, replacement not moved.
        Mock Invoke-KubeconfigFileReplace {
            [System.IO.File]::Delete($BackupPath)
            [System.IO.File]::Move($Path, $BackupPath)
            throw (New-Object System.IO.IOException 'simulated ERROR_UNABLE_TO_MOVE_REPLACEMENT_2')
        }

        { Add-K8sContext } | Should -Throw '*original was restored*'

        Get-FileBase64 $script:userKubeconfig | Should -BeExactly $script:originalUserBytes
        Test-Path $script:backupKubeconfig | Should -BeFalse -Because 'ReplaceFile already overwrote the previous backup; it is moved back to config'
        Assert-NoTemporaryFiles
        $env:KUBECONFIG | Should -BeNullOrEmpty
    }

    It 'reports where the original is preserved when it cannot be moved back' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        Mock Invoke-KubeconfigFileReplace {
            [System.IO.File]::Delete($BackupPath)
            [System.IO.File]::Move($Path, $BackupPath)
            New-Item -ItemType Directory -Path $Path | Out-Null
            throw (New-Object System.IO.IOException 'simulated ERROR_UNABLE_TO_MOVE_REPLACEMENT_2')
        }

        try {
            { Add-K8sContext } | Should -Throw '*preserved in*config_backup*'
            Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalUserBytes
            @(Get-ChildItem -LiteralPath $script:kubeConfigDir -Force -Filter 'config.k2s-*').Count | Should -Be 0
        }
        finally {
            Remove-Item -LiteralPath $script:userKubeconfig -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'retries a transient ERROR_UNABLE_TO_REMOVE_REPLACED and then replaces the user kubeconfig' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $script:replaceCalls = 0
        Mock Start-Sleep {}
        Mock Invoke-KubeconfigFileReplace {
            $script:replaceCalls++
            if ($script:replaceCalls -le 2) { throw (New-Object System.IO.IOException 'Unable to remove the file to be replaced.') }
            & $script:realInvokeKubeconfigFileReplace -StagingPath $StagingPath -Path $Path -BackupPath $BackupPath
        }

        Add-K8sContext

        $script:replaceCalls | Should -Be 3
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalUserBytes
        Assert-UpdatedUserKubeconfig -KubectlPath $script:fakeKubectlPath -OriginalParsed (Get-KubeconfigObject -KubectlPath $script:fakeKubectlPath -Path $script:backupKubeconfig) `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
        Assert-NoTemporaryFiles
    }

    It 'gives up after the retry limit for a persistent IO error and keeps the user kubeconfig' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $script:replaceCalls = 0
        Mock Start-Sleep {}
        Mock Invoke-KubeconfigFileReplace { $script:replaceCalls++; throw (New-Object System.IO.IOException 'Unable to remove the file to be replaced.') }

        { Add-K8sContext } | Should -Throw '*replacing*left unchanged*Unable to remove*'

        $script:replaceCalls | Should -Be 5
        Assert-UserKubeconfigUnchanged
        Assert-NoTemporaryFiles
        $env:KUBECONFIG | Should -BeNullOrEmpty
    }

    It 'does not retry a non-transient replace error (access denied)' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $script:replaceCalls = 0
        Mock Start-Sleep {}
        Mock Invoke-KubeconfigFileReplace { $script:replaceCalls++; throw (New-Object System.UnauthorizedAccessException 'Access to the path is denied.') }

        { Add-K8sContext } | Should -Throw '*replacing*left unchanged*denied*'

        $script:replaceCalls | Should -Be 1
        Assert-UserKubeconfigUnchanged
        Assert-NoTemporaryFiles
    }

    It 'does not retry over a user kubeconfig that another process replaced after a failed attempt' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $script:replaceCalls = 0
        $script:concurrent = "apiVersion: v1`nkind: Config`ncurrent-context: other-writer`n"
        Mock Start-Sleep {}
        Mock Invoke-KubeconfigFileReplace {
            $script:replaceCalls++
            $other = "$Path.other-writer"
            [System.IO.File]::WriteAllText($other, $script:concurrent)
            [System.IO.File]::Replace($other, $Path, [NullString]::Value)
            throw (New-Object System.IO.IOException 'Unable to remove the file to be replaced.')
        }

        { Add-K8sContext } | Should -Throw '*modified by another process*'

        $script:replaceCalls | Should -Be 1
        [System.IO.File]::ReadAllText($script:userKubeconfig) | Should -BeExactly $script:concurrent
        Assert-NoTemporaryFiles
    }

    It 'rejects a K2s kubeconfig whose credential data is <Case> and keeps the user kubeconfig' -ForEach @(
        @{ Case = 'truncated PEM (valid base64)'; Expected = '*incomplete PEM*'; Mutate = { param($v) $v.Substring(0, $v.Length - 400) } }
        @{ Case = 'truncated base64'; Expected = '*not base64*'; Mutate = { param($v) $v.Substring(0, $v.Length - 3) } }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $user = New-K2sUser 1
        $user.user['client-key-data'] = & $Mutate $user.user['client-key-data']
        Write-TestFile -Path $script:k2sSourcePath -Content (New-KubeconfigText -Clusters @(New-K2sCluster 1) -Users @($user) -Contexts @(New-K2sContext) -CurrentContext $script:k2sContextName)

        { Add-K8sContext } | Should -Throw $Expected

        Assert-UserKubeconfigUnchanged
    }

    It 'rejects a K2s kubeconfig whose <Field> is <State> and keeps the user kubeconfig and backup' -ForEach @(
        foreach ($f in @('certificate-authority-data', 'client-certificate-data', 'client-key-data')) {
            foreach ($s in @('missing', 'null', 'empty', 'whitespace')) { @{ Field = $f; State = $s } }
        }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $cluster = New-K2sCluster 1
        $user = New-K2sUser 1
        $target = if ($Field -eq 'certificate-authority-data') { $cluster.cluster } else { $user.user }
        switch ($State) {
            'missing' { $target.Remove($Field) }
            'null' { $target[$Field] = $null }
            'empty' { $target[$Field] = '' }
            'whitespace' { $target[$Field] = '   ' }
        }
        Write-TestFile -Path $script:k2sSourcePath -Content (New-KubeconfigText -Clusters @($cluster) -Users @($user) -Contexts @(New-K2sContext) -CurrentContext $script:k2sContextName)

        { Add-K8sContext } | Should -Throw "*has no $Field*"

        Assert-UserKubeconfigUnchanged
    }

    It 'does not create a user kubeconfig on fresh install when client-key-data is missing' {
        $user = New-K2sUser 1
        $user.user.Remove('client-key-data')
        Write-TestFile -Path $script:k2sSourcePath -Content (New-KubeconfigText -Clusters @(New-K2sCluster 1) -Users @($user) -Contexts @(New-K2sContext) -CurrentContext $script:k2sContextName)

        { Add-K8sContext } | Should -Throw '*has no client-key-data*'

        Test-Path $script:userKubeconfig | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:kubeConfigDir -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'rejects a K2s kubeconfig without the K2s <Kind> entry and keeps the user kubeconfig' -ForEach @(
        @{ Kind = 'cluster' }, @{ Kind = 'user' }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $clusters = if ($Kind -eq 'cluster') { @() } else { @(New-K2sCluster 1) }
        $users = if ($Kind -eq 'user') { @() } else { @(New-K2sUser 1) }
        Write-TestFile -Path $script:k2sSourcePath -Content (New-KubeconfigText -Clusters $clusters -Users $users -Contexts @(New-K2sContext) -CurrentContext $script:k2sContextName)

        { Add-K8sContext } | Should -Throw "*has no $Kind*"

        Assert-UserKubeconfigUnchanged
    }

    It 'rejects K2s credential data with <Case> and keeps the user kubeconfig' -ForEach @(
        @{ Case = 'mismatched BEGIN/END labels (equal counts)'; Field = 'client-key-data'; Pem = "-----BEGIN RSA PRIVATE KEY-----`nQUJD`n-----END CERTIFICATE-----`n"; Expected = '*incomplete PEM*mismatched*' }
        @{ Case = 'labels crossed between two blocks'; Field = 'client-certificate-data'; Pem = "-----BEGIN CERTIFICATE-----`nQUJD`n-----END RSA PRIVATE KEY-----`n-----BEGIN RSA PRIVATE KEY-----`nQUJD`n-----END CERTIFICATE-----`n"; Expected = '*incomplete PEM*' }
        @{ Case = 'an unterminated second block'; Field = 'certificate-authority-data'; Pem = "-----BEGIN CERTIFICATE-----`nQUJD`n-----END CERTIFICATE-----`n-----BEGIN CERTIFICATE-----`nQUJD`n"; Expected = '*incomplete PEM*' }
        @{ Case = 'text after the END marker'; Field = 'client-certificate-data'; Pem = "-----BEGIN CERTIFICATE-----`nQUJD`n-----END CERTIFICATE-----`ngarbage`n"; Expected = '*incomplete PEM*' }
        @{ Case = 'no PEM markers'; Field = 'certificate-authority-data'; Pem = "not a certificate`n"; Expected = '*incomplete PEM*' }
        @{ Case = 'a certificate in client-key-data'; Field = 'client-key-data'; Pem = "-----BEGIN CERTIFICATE-----`nQUJD`n-----END CERTIFICATE-----`n"; Expected = '*unexpected PEM blocks*' }
        @{ Case = 'a private key in certificate-authority-data'; Field = 'certificate-authority-data'; Pem = "-----BEGIN RSA PRIVATE KEY-----`nQUJD`n-----END RSA PRIVATE KEY-----`n"; Expected = '*unexpected PEM blocks*' }
        @{ Case = 'two private keys'; Field = 'client-key-data'; Pem = "-----BEGIN RSA PRIVATE KEY-----`nQUJD`n-----END RSA PRIVATE KEY-----`n-----BEGIN RSA PRIVATE KEY-----`nQUJD`n-----END RSA PRIVATE KEY-----`n"; Expected = '*unexpected PEM blocks*' }
        @{ Case = 'a corrupt PEM body'; Field = 'client-certificate-data'; Pem = "-----BEGIN CERTIFICATE-----`nQUJ=D`n-----END CERTIFICATE-----`n"; Expected = '*corrupt PEM body*' }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $cluster = New-K2sCluster 1
        $user = New-K2sUser 1
        $target = if ($Field -eq 'certificate-authority-data') { $cluster.cluster } else { $user.user }
        $target[$Field] = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($Pem))
        Write-TestFile -Path $script:k2sSourcePath -Content (New-KubeconfigText -Clusters @($cluster) -Users @($user) -Contexts @(New-K2sContext) -CurrentContext $script:k2sContextName)

        { Add-K8sContext } | Should -Throw $Expected

        Assert-UserKubeconfigUnchanged
    }

    It 'accepts a <Label> client key and a CA bundle' -ForEach @(
        @{ Label = 'RSA PRIVATE KEY' }, @{ Label = 'EC PRIVATE KEY' }, @{ Label = 'PRIVATE KEY' }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:fakeKubectlPath -Path $script:userKubeconfig
        $cluster = New-K2sCluster 1
        $bundle = @(2, 3) | ForEach-Object { [System.Text.Encoding]::ASCII.GetString([Convert]::FromBase64String((New-PemData -Seed $_ -Length 500 -Label 'CERTIFICATE'))) }
        $cluster.cluster['certificate-authority-data'] = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(($bundle -join '')))
        $user = New-K2sUser 1
        $user.user['client-key-data'] = New-PemData -Seed 7 -Length 300 -Label $Label
        Write-TestFile -Path $script:k2sSourcePath -Content (New-KubeconfigText -Clusters @($cluster) -Users @($user) -Contexts @(New-K2sContext) -CurrentContext $script:k2sContextName)

        Add-K8sContext

        Assert-UpdatedUserKubeconfig -KubectlPath $script:fakeKubectlPath -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
    }

    It 'does not present an older config_backup as the original when the target vanished during replacement' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $script:replaceCalls = 0
        Mock Start-Sleep {}
        Mock Invoke-KubeconfigFileReplace {
            $script:replaceCalls++
            [System.IO.File]::Delete($Path)
            throw (New-Object System.IO.FileNotFoundException 'simulated: target deleted by another process')
        }

        { Add-K8sContext } | Should -Throw '*does not hold its original content*nothing was restored*'

        $script:replaceCalls | Should -Be 1
        Test-Path $script:userKubeconfig | Should -BeFalse
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalBackupBytes -Because 'the older backup must not be moved to config'
        Assert-NoTemporaryFiles
    }

    It 'does not fail after commit when the informational config view fails' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:fakeKubectlPath -Path $script:userKubeconfig
        $script:fault = @{ Mode = 'fail'; Match = { param($a, $k) $a[1] -eq 'view' -and $a -notcontains '--raw' } }

        Add-K8sContext

        $script:fault = $null
        Assert-UpdatedUserKubeconfig -KubectlPath $script:fakeKubectlPath -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalUserBytes
        Assert-NoTemporaryFiles
    }

    It 'warns when a foreign context references the K2s user name and keeps that context' {
        $clusters = @(New-ForeignClusters) + [ordered]@{ name = 'other-kubeadm'; cluster = [ordered]@{ server = 'https://10.0.0.1:6443' } }
        $contexts = @(New-ForeignContexts) + [ordered]@{ name = 'kubernetes-admin@other-kubeadm'; context = [ordered]@{ cluster = 'other-kubeadm'; user = 'kubernetes-admin' } }
        Initialize-ExistingUserKubeconfig -Content (New-KubeconfigText -Clusters (@($clusters) + (New-K2sCluster 900)) -Users (@(New-ForeignUsers) + (New-K2sUser 900)) -Contexts (@($contexts) + (New-K2sContext)) -CurrentContext 'docker-desktop')
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:fakeKubectlPath -Path $script:userKubeconfig
        $script:logMessages = New-Object System.Collections.Generic.List[string]
        Mock Write-Log { $script:logMessages.Add([string]$Message) }

        Add-K8sContext

        @($script:logMessages | Where-Object { $_ -like "*Warning: context 'kubernetes-admin@other-kubeadm'*" }).Count | Should -Be 1
        Assert-UpdatedUserKubeconfig -KubectlPath $script:fakeKubectlPath -OriginalParsed $originalParsed `
            -ForeignContexts ($script:foreignContextNames + 'kubernetes-admin@other-kubeadm') -ForeignClusters ($script:foreignClusterNames + 'other-kubeadm') -ForeignUsers $script:foreignUserNames | Out-Null
    }

    It 'ignores a caller KUBECONFIG and clears it afterwards (as before)' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $decoy = Join-Path $script:testRoot 'decoy-config'
        $env:KUBECONFIG = $decoy

        Add-K8sContext

        $env:KUBECONFIG | Should -BeNullOrEmpty
        foreach ($call in $script:kubectlCalls) {
            $call.Arguments | Should -Not -Contain $decoy
            ($call.KubeConfig -split ';') | Should -Not -Contain $decoy
        }
        Test-Path $decoy | Should -BeFalse
    }
}

# Static guards: every Windows path that refreshes the user kubeconfig goes through Add-K8sContext,
# and no PowerShell code redirects 'kubectl config view' output with '>' / Out-File / Set-Content.
Describe 'Kubeconfig callers and redirection guard' -Tag 'unit', 'ci', 'cluster' {
    BeforeAll {
        $script:repoRoot = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\..\..\..\..\..")
    }

    It '<Caller> refreshes the user kubeconfig via Copy-KubeConfigFromControlPlaneNode followed by Add-K8sContext' -ForEach @(
        @{ Caller = 'installation'; File = 'lib\modules\windows\node\k2s.node.module\linuxnode\setup\control-plane-node.module.psm1' }
        @{ Caller = 'certificate renewal'; File = 'lib\scripts\windows\host\system\certificate\renew.ps1' }
    ) {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot $File))
        $text | Should -Match '(?m)^\s*Copy-KubeConfigFromControlPlaneNode\s*\r?\n\s*Add-K8sContext\s*$'
    }

    It 'no PowerShell file writes kubectl config view output through text redirection' {
        $offenders = foreach ($dir in @('lib', 'smallsetup', 'addons')) {
            $path = Join-Path $script:repoRoot $dir
            if (!(Test-Path $path)) { continue }
            Get-ChildItem -Path $path -Recurse -File -Include '*.ps1', '*.psm1' |
                Select-String -Pattern 'config[''"]?\s*,?\s*[''"]?view[^#\r\n]*((?<![\d&])>|\|\s*(Out-File|Set-Content|Add-Content))' |
                Where-Object { $_.Line -notmatch '^\s*#' } |
                ForEach-Object { "$($_.Path):$($_.LineNumber)" }
        }
        $offenders | Should -BeNullOrEmpty
    }
}

# Integration suite: exercises Add-K8sContext with the real bin\kube\kubectl.exe (installed by the
# K2s setup / 'bgow' is not sufficient - kubectl.exe is downloaded during K2s installation). Not run
# by the CI unit job; run locally with -Tag integration.
Describe 'Add-K8sContext kubeconfig output (real kubectl)' -Tag 'integration', 'cluster' -Skip:$script:kubectlMissing {
    BeforeEach {
        Initialize-KubeconfigTestProfile
        $script:kubeToolsPath = Split-Path $script:realKubectlExe -Parent
    }

    AfterEach {
        Remove-KubeconfigTestProfile
    }

    It 'fresh install writes UTF-8 without BOM with the K2s context' {
        Add-K8sContext

        $text = Assert-PortableKubeconfigBytes -Bytes ([System.IO.File]::ReadAllBytes($script:userKubeconfig))
        $text.StartsWith('apiVersion:') | Should -BeTrue
        Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe | Out-Null
        Assert-NoTemporaryFiles
    }

    It 'merge preserves Docker Desktop/AKS entries and updates stale K2s entries (current context: <Current>)' -ForEach @(
        @{ Current = 'k2s' }, @{ Current = 'foreign' }
    ) {
        $current = if ($Current -eq 'k2s') { $script:k2sContextName } else { $script:aksContextName }
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $current -IncludeStaleK2s)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:realKubectlExe -Path $script:userKubeconfig

        Add-K8sContext

        $result = Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames
        ($result.contexts | Where-Object { $_.name -ceq $script:aksContextName }).context.namespace | Should -BeExactly $script:aksNamespace
        $text = [System.IO.File]::ReadAllText($script:userKubeconfig, $script:utf8NoBom)
        $text.Contains($script:aksContextName) | Should -BeTrue -Because 'non-ASCII names must be stored as UTF-8'
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalUserBytes
        Assert-NoTemporaryFiles
    }

    It 'repairs a <Case> kubeconfig (e.g. written by earlier K2s versions or editors)' -ForEach @(
        @{ Case = 'UTF-16LE'; Encoding = [System.Text.Encoding]::Unicode }
        @{ Case = 'UTF-8 with BOM'; Encoding = (New-Object System.Text.UTF8Encoding($true)) }
    ) {
        Initialize-ExistingUserKubeconfig -Content ((New-UserKubeconfigText -CurrentContext $script:k2sContextName -IncludeStaleK2s) -replace "`r?`n", "`r`n") -Encoding $Encoding
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:realKubectlExe -Path $script:userKubeconfig

        Add-K8sContext

        Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalUserBytes -Because 'config_backup must hold the original bytes'
        Assert-NoTemporaryFiles
    }

    It 'preserves non-ASCII content regardless of the console output code page' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:k2sContextName -IncludeStaleK2s)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:realKubectlExe -Path $script:userKubeconfig
        $savedOutputEncoding = [Console]::OutputEncoding
        try {
            # OEM code page 437 cannot represent the CJK characters of the AKS context name.
            [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(437)
            Add-K8sContext
        }
        finally {
            [Console]::OutputEncoding = $savedOutputEncoding
        }

        Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
    }

    It 'repeated execution is byte-identical and renewal updates only K2s entries' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:realKubectlExe -Path $script:userKubeconfig

        Add-K8sContext
        $first = Get-FileBase64 $script:userKubeconfig
        Add-K8sContext
        Get-FileBase64 $script:userKubeconfig | Should -BeExactly $first

        Write-TestFile -Path $script:k2sSourcePath -Content (New-K2sSourceText -Seed 77)
        Add-K8sContext
        Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
        Assert-NoTemporaryFiles
    }

    It 'keeps relative certificate paths resolvable from the .kube directory' {
        $clusters = @([ordered]@{ name = 'local-ca'; cluster = [ordered]@{ 'certificate-authority' = 'certs\ca.crt'; server = 'https://local:6443' } })
        $users = @([ordered]@{ name = 'local-user'; user = [ordered]@{ token = 'abc' } })
        $contexts = @([ordered]@{ name = 'local'; context = [ordered]@{ cluster = 'local-ca'; user = 'local-user' } })
        Initialize-ExistingUserKubeconfig -Content (New-KubeconfigText -Clusters $clusters -Users $users -Contexts $contexts -CurrentContext 'local')
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:realKubectlExe -Path $script:userKubeconfig

        Add-K8sContext

        Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe -OriginalParsed $originalParsed -ForeignContexts @('local') -ForeignClusters @('local-ca') -ForeignUsers @('local-user') | Out-Null
        [System.IO.File]::ReadAllText($script:userKubeconfig) | Should -Match 'certificate-authority: certs\\ca\.crt'
    }

    It 'leaves the user kubeconfig unchanged when <Case>' -ForEach @(
        @{ Case = 'the K2s kubeconfig is malformed'; Setup = { Write-TestFile -Path $script:k2sSourcePath -Content "apiVersion: v1`nclusters: [unterminated`n" } }
        @{ Case = 'the K2s kubeconfig lacks the K2s context'; Setup = { Write-TestFile -Path $script:k2sSourcePath -Content (New-KubeconfigText -Clusters @(New-K2sCluster 1) -Users @(New-K2sUser 1)) } }
        @{ Case = 'the user kubeconfig is malformed'; Setup = { Write-TestFile -Path $script:userKubeconfig -Content "apiVersion: v1`ncontexts: [unterminated`n"; $script:originalUserBytes = Get-FileBase64 $script:userKubeconfig } }
        @{ Case = 'the user kubeconfig is read-only'; Setup = { (Get-Item $script:userKubeconfig).IsReadOnly = $true } }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        & $Setup

        { Add-K8sContext } | Should -Throw

        Assert-UserKubeconfigUnchanged
    }

    It 'repairs the user kubeconfig states observed on an affected machine (<Case>)' -ForEach @(
        @{ Case = '0-byte config'; Content = '' }
        @{ Case = '116-byte config with null clusters/users/contexts'; Content = "apiVersion: v1`nclusters: null`ncontexts: null`ncurrent-context: kubernetes-admin@k2s-cluster`nkind: Config`nusers: null`n" }
    ) {
        Initialize-ExistingUserKubeconfig -Content $Content

        Add-K8sContext

        Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe | Out-Null
        Get-FileBase64 $script:backupKubeconfig | Should -BeExactly $script:originalUserBytes
        Assert-NoTemporaryFiles
    }

    It 'leaves the user kubeconfig unchanged when the K2s kubeconfig is truncated at <Cut>' -ForEach @(
        @{ Cut = '10%' }, @{ Cut = '50%' }, @{ Cut = '90%' }, @{ Cut = 'client-key-data+400 (valid base64)' }, @{ Cut = 'client-key-data+401' }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $yaml = $script:utf8NoBom.GetString((Invoke-KubeconfigKubectl -KubectlPath $script:realKubectlExe -Arguments @('config', 'view', '--raw', '--kubeconfig', $script:k2sSourcePath)).StdOut)
        $keyStart = $yaml.IndexOf('client-key-data: ') + 'client-key-data: '.Length
        $length = switch ($Cut) {
            '10%' { [int]($yaml.Length * 0.1) }
            '50%' { [int]($yaml.Length * 0.5) }
            '90%' { [int]($yaml.Length * 0.9) }
            'client-key-data+400 (valid base64)' { $keyStart + 400 }
            default { $keyStart + 401 }
        }
        Write-TestFile -Path $script:k2sSourcePath -Content $yaml.Substring(0, $length)

        { Add-K8sContext } | Should -Throw '*KubeConfig*'

        Assert-UserKubeconfigUnchanged
    }

    It 'leaves the user kubeconfig unchanged when the K2s <Field> is <State> (parsed by real kubectl)' -ForEach @(
        foreach ($f in @('certificate-authority-data', 'client-key-data')) {
            foreach ($s in @('missing', 'null', 'empty')) { @{ Field = $f; State = $s } }
        }
    ) {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $cluster = New-K2sCluster 1
        $user = New-K2sUser 1
        $target = if ($Field -eq 'certificate-authority-data') { $cluster.cluster } else { $user.user }
        switch ($State) {
            'missing' { $target.Remove($Field) }
            'null' { $target[$Field] = $null }
            'empty' { $target[$Field] = '' }
        }
        Write-TestFile -Path $script:k2sSourcePath -Content (New-KubeconfigText -Clusters @($cluster) -Users @($user) -Contexts @(New-K2sContext) -CurrentContext $script:k2sContextName)

        { Add-K8sContext } | Should -Throw "*has no $Field*"

        Assert-UserKubeconfigUnchanged
    }

    It 'ignores a caller KUBECONFIG pointing to another file and leaves that file untouched' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:realKubectlExe -Path $script:userKubeconfig
        $decoy = Join-Path $script:testRoot 'decoy-config'
        Write-TestFile -Path $decoy -Content (New-KubeconfigText -Clusters @([ordered]@{ name = 'decoy'; cluster = [ordered]@{ server = 'https://decoy:6443' } }) -Users @([ordered]@{ name = 'decoy'; user = [ordered]@{ token = 'decoy' } }) -Contexts @([ordered]@{ name = 'decoy'; context = [ordered]@{ cluster = 'decoy'; user = 'decoy' } }) -CurrentContext 'decoy')
        $decoyBytes = Get-FileBase64 $decoy
        $env:KUBECONFIG = $decoy

        Add-K8sContext

        Get-FileBase64 $decoy | Should -BeExactly $decoyBytes
        $env:KUBECONFIG | Should -BeNullOrEmpty
        Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe -OriginalParsed $originalParsed `
            -ForeignContexts $script:foreignContextNames -ForeignClusters $script:foreignClusterNames -ForeignUsers $script:foreignUserNames | Out-Null
    }

    It 'does not write certificate, key or token data to the log' {
        Initialize-ExistingUserKubeconfig -Content (New-UserKubeconfigText -CurrentContext $script:aksContextName -IncludeStaleK2s)
        $script:logMessages = New-Object System.Collections.Generic.List[string]
        Mock Write-Log { $script:logMessages.Add([string]$Message) }

        Add-K8sContext

        $secrets = foreach ($file in @($script:userKubeconfig, $script:backupKubeconfig, $script:k2sSourcePath)) {
            $config = Get-KubeconfigObject -KubectlPath $script:realKubectlExe -Path $file
            foreach ($entry in @($config.clusters | ForEach-Object { $_.cluster }) + @($config.users | ForEach-Object { $_.user })) {
                foreach ($property in $entry.PSObject.Properties) {
                    if ($property.Name -like '*-data' -or $property.Name -eq 'token') { $value = [string]$property.Value; $value.Substring([int]($value.Length / 2), [Math]::Min(24, $value.Length - [int]($value.Length / 2))) }
                }
            }
        }
        @($secrets).Count | Should -BeGreaterThan 0
        $logText = $script:logMessages -join "`n"
        $logText | Should -Match 'REDACTED|DATA\+OMITTED'
        foreach ($secret in $secrets) { $logText.Contains($secret) | Should -BeFalse }
    }

    It 'preserves token, basic-auth, file-based and impersonation credentials of foreign entries' {
        $clusters = @(
            [ordered]@{ name = 'proxy-cluster'; cluster = [ordered]@{ server = 'https://api.example:6443'; 'insecure-skip-tls-verify' = $true; 'proxy-url' = 'http://proxy.example:3128'; 'tls-server-name' = 'api.internal' } },
            [ordered]@{ name = 'file-ca-cluster'; cluster = [ordered]@{ server = 'https://files.example:6443'; 'certificate-authority' = 'C:\certs\ca.crt' } }
        )
        $users = @(
            [ordered]@{ name = 'token-user'; user = [ordered]@{ token = 'synthetic-token-0123456789' } },
            [ordered]@{ name = 'basic-user'; user = [ordered]@{ username = 'admin'; password = 'synthetic-password' } },
            [ordered]@{ name = 'file-cert-user'; user = [ordered]@{ 'client-certificate' = 'C:\certs\client.crt'; 'client-key' = 'C:\certs\client.key' } },
            [ordered]@{ name = 'impersonating-user'; user = [ordered]@{ token = 'synthetic-token-2'; as = 'someone'; 'as-groups' = @('g1', 'g2') } }
        )
        $contexts = @(
            [ordered]@{ name = 'token'; context = [ordered]@{ cluster = 'proxy-cluster'; user = 'token-user'; namespace = 'ns-a' } },
            [ordered]@{ name = 'basic'; context = [ordered]@{ cluster = 'proxy-cluster'; user = 'basic-user' } },
            [ordered]@{ name = 'files'; context = [ordered]@{ cluster = 'file-ca-cluster'; user = 'file-cert-user'; namespace = 'ns-b' } },
            [ordered]@{ name = 'impersonate'; context = [ordered]@{ cluster = 'file-ca-cluster'; user = 'impersonating-user' } }
        )
        Initialize-ExistingUserKubeconfig -Content (New-KubeconfigText -Clusters ($clusters + (New-K2sCluster 900)) -Users ($users + (New-K2sUser 900)) -Contexts ($contexts + (New-K2sContext)) -CurrentContext 'files')
        $originalParsed = Get-KubeconfigObject -KubectlPath $script:realKubectlExe -Path $script:userKubeconfig

        Add-K8sContext

        Assert-UpdatedUserKubeconfig -KubectlPath $script:realKubectlExe -OriginalParsed $originalParsed `
            -ForeignContexts @('token', 'basic', 'files', 'impersonate') -ForeignClusters @('proxy-cluster', 'file-ca-cluster') `
            -ForeignUsers @('token-user', 'basic-user', 'file-cert-user', 'impersonating-user') | Out-Null
    }
}
