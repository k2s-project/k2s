# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

Describe 'clusterip-webhook-auth.module' -Tag 'unit', 'ci', 'webhook-auth' {
    BeforeAll {
        $modulePath = "$PSScriptRoot\clusterip-webhook-auth.module.psm1"
        $moduleName = (Import-Module $modulePath -PassThru -Force).Name
        $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('k2s-webhook-auth-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
        # Output of clusterip-webhook-auth.sh in real runs, recorded and kept current by test/clusterip-webhook-auth.sh.
        $scriptOutputPath = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\..\..\..\..\..\..\test\clusterip-webhook-auth.output.txt")
        $scriptLogs = @{}
        $scriptExitCodes = @{}
        $section = $null
        foreach ($line in [System.IO.File]::ReadAllLines($scriptOutputPath)) {
            if ($line -cmatch '\A=== (\S+) exit=([0-9]+)\z') {
                $section = $Matches[1]
                $scriptLogs[$section] = [System.Collections.Generic.List[string]]::new()
                $scriptExitCodes[$section] = [int]$Matches[2]
            }
            elseif ($null -ne $section) { $scriptLogs[$section].Add($line) }
        }

        InModuleScope $moduleName -Parameters @{ FixtureRoot = $fixtureRoot; ScriptLogs = $scriptLogs; ScriptExitCodes = $scriptExitCodes } {
            param($FixtureRoot, $ScriptLogs, $ScriptExitCodes)
            $script:fixtureRoot = $FixtureRoot
            $script:scriptLogs = @{}
            foreach ($name in $ScriptLogs.Keys) { $script:scriptLogs[$name] = [string[]]$ScriptLogs[$name].ToArray() }
            $script:scriptExitCodes = $ScriptExitCodes
            # Logs of renew runs, named by what they show.
            $script:renewLogs = @{
                Renewed                = $script:scriptLogs['renew/forced']
                RenewedNearExpiry      = $script:scriptLogs['renew/renewed']
                NotRenewed             = $script:scriptLogs['renew/verified']
                FailedBeforeInstall    = $script:scriptLogs['renew/current-certificate-not-working']
                SigningFailed          = $script:scriptLogs['renew/signing-failed']
                VerifyFailedNotRenewed = $script:scriptLogs['renew/verify-failed']
                FailedAfterInstall     = $script:scriptLogs['renew/unverified-without-backup']
                RolledBack             = $script:scriptLogs['renew/rolled-back']
                RestoreUnverified      = $script:scriptLogs['renew/restore-unverified']
                RestoreFailed          = $script:scriptLogs['renew/restore-failed']
                Refused                = $script:scriptLogs['renew/custom']
                Locked                 = $script:scriptLogs['renew/locked']
                Empty                  = [string[]]@()
                RenewedUnverified      = [string[]]@($script:scriptLogs['renew/forced'] | Where-Object { $_ -cne $script:RenewedVerifiedLine })
                # Exit status 6 never proves that no new certificate is in use, whatever the log shows.
                RestoreFailedWithoutInstallLine = [string[]]@($script:scriptLogs['renew/restore-failed'] | Where-Object { $_ -cnotmatch $script:RenewedPattern })
            }

            # Fake control-plane node: answers the remote commands of the module from scripted answers and records every
            # invocation of ssh.exe and scp.exe. Time is simulated; nothing sleeps.
            function script:Reset-FakeNode {
                param([byte[]]$ScriptBytes = [System.Text.Encoding]::UTF8.GetBytes("#!/bin/bash`r`necho fixture`r`n"))
                $script:calls = [System.Collections.Generic.List[object]]::new()
                $script:logs = [System.Collections.Generic.List[string]]::new()
                $script:sleeps = [System.Collections.Generic.List[int]]::new()
                $script:runIds = [System.Collections.Generic.List[string]]::new()
                $script:now = [datetime]::new(2026, 11, 21, 8, 0, 0, [DateTimeKind]::Utc)
                $script:uploaded = $null
                $script:uploadedFile = $null
                $script:uploadAnswer = $null
                $script:scpAnswer = $null
                $script:promoteAnswer = $null
                $script:startAnswers = [System.Collections.Generic.Queue[object]]::new()
                $script:pollAnswers = [System.Collections.Generic.Queue[object]]::new()
                $script:lastPoll = $null
                # Only tests that expect many identical polls let the last answer repeat; any other unscripted poll
                # fails the test (see AfterEach), so that extra polls or starts cannot go unnoticed.
                $script:repeatLastPoll = $false
                $script:pollExhausted = $false
                $script:startDelaySeconds = 0
                # Simulated duration of every poll, to move the clock while ssh.exe runs.
                $script:pollDelaySeconds = 0
                # Answers of AbandonSnippet; without a scripted answer the run is abandoned (K2S-RUN-ABANDON:done).
                $script:abandonAnswers = [System.Collections.Generic.Queue[object]]::new()
                # Nonces of all polls, in order.
                $script:nonces = [System.Collections.Generic.List[string]]::new()
                $script:installation = Join-Path $script:fixtureRoot ([guid]::NewGuid().ToString('N'))
                $script:source = Join-Path $script:installation $script:ScriptRelativePath
                New-Item -ItemType Directory -Path (Split-Path $script:source) -Force | Out-Null
                [System.IO.File]::WriteAllBytes($script:source, $ScriptBytes)
            }

            function script:New-FakeAnswer {
                param([int]$ExitCode = 0, [string[]]$Output = @(), [string[]]$Errors = @(), [int]$DelaySeconds = 0)
                return [pscustomobject]@{ ExitCode = $ExitCode; Output = $Output; Errors = $Errors; DelaySeconds = $DelaySeconds }
            }

            # Output of PollSnippet for a state such as running:4242, exited:0 or vanished:4242. {NONCE} is replaced by
            # the nonce of the poll that receives the answer.
            function script:New-PollAnswer {
                param([string]$State, [string[]]$Log = @(), [long]$LogSize = -1, [int]$DelaySeconds = 0)
                $lines = [System.Collections.Generic.List[string]]::new()
                if ($State -match '\A(running|orphaned|vanished):([0-9]+)\z') { $lines.Add("K2S-RUN-PID:$($Matches[2])") }
                elseif ($State -like 'exited:*') { $lines.Add('K2S-RUN-PID:4242') }
                $lines.Add("K2S-RUN-STATE:$State")
                if ($State -notin @('missing', 'starting', 'abandoned')) {
                    $size = if ($LogSize -ge 0) { $LogSize } else { ($Log -join "`n").Length + 1 }
                    $lines.Add("K2S-RUN-LOG-SIZE:$size")
                    $lines.Add('K2S-RUN-LOG-BEGIN:{NONCE}')
                    foreach ($line in $Log) { $lines.Add($line) }
                    $lines.Add('')
                    $lines.Add('K2S-RUN-LOG-END:{NONCE}')
                }
                return New-FakeAnswer -Output $lines.ToArray() -DelaySeconds $DelaySeconds
            }

            function script:Add-PollAnswer {
                param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Answers)
                foreach ($answer in $Answers) { $script:pollAnswers.Enqueue($answer) }
            }

            function script:Invoke-FakeNode {
                param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSeconds)
                $script:calls.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = @($ArgumentList); TimeoutSeconds = $TimeoutSeconds })
                if ($FilePath -eq 'scp.exe') {
                    $script:uploadedFile = $ArgumentList[-2]
                    $script:uploaded = [System.IO.File]::ReadAllBytes($ArgumentList[-2])
                    if ($script:scpAnswer) { return $script:scpAnswer }
                    return New-FakeAnswer
                }
                $remote = $ArgumentList[-1]
                if ($remote -ceq 'umask 077 && mktemp -d /tmp/k2s-webhook-auth-stage.XXXXXXXXXX') {
                    if ($script:uploadAnswer) { return $script:uploadAnswer }
                    return New-FakeAnswer -Output @('/tmp/k2s-webhook-auth-stage.AbCdEf0123')
                }
                if ($remote -clike 'rm -rf -- *') { return New-FakeAnswer }
                if ($remote -clike '*K2S-STAGE-OK*') {
                    if ($script:promoteAnswer) { return $script:promoteAnswer }
                    $expected = [regex]::Match($remote, "'([0-9a-f]{64})'\z").Groups[1].Value
                    $actual = Get-WebhookAuthSha256 -Bytes $script:uploaded
                    if ($actual -ceq $expected) { return New-FakeAnswer -Output @("K2S-STAGE-OK:$expected") }
                    return New-FakeAnswer -ExitCode 34 -Output @("K2S-STAGE-ERROR:upload-checksum:$actual")
                }
                if ($remote -clike '*K2S-RUN-PREPARED*') {
                    $runId = [regex]::Match($remote, "k2s-webhook-auth '([0-9]{8}T[0-9]{6}Z-[0-9a-f]{8})'").Groups[1].Value
                    $script:runIds.Add($runId)
                    $script:now = $script:now.AddSeconds($script:startDelaySeconds)
                    if ($script:startAnswers.Count -gt 0) {
                        $answer = $script:startAnswers.Dequeue()
                        if ($answer -is [scriptblock]) { return (& $answer $runId) }
                        return $answer
                    }
                    return New-FakeAnswer -Output @("K2S-RUN-PREPARED:$runId", 'K2S-RUN-STARTED:4242')
                }
                if ($remote -clike '*K2S-RUN-STATE*') {
                    $script:now = $script:now.AddSeconds($script:pollDelaySeconds)
                    if ($script:pollAnswers.Count -gt 0) {
                        $script:lastPoll = $script:pollAnswers.Dequeue()
                    }
                    elseif (-not $script:repeatLastPoll -or $null -eq $script:lastPoll) {
                        $script:pollExhausted = $true
                        throw 'no poll answer scripted'
                    }
                    $nonce = [regex]::Match($remote, "'([0-9a-f]{32})'\z").Groups[1].Value
                    if (-not $nonce) { throw "poll without nonce: $remote" }
                    $script:nonces.Add($nonce)
                    if ($script:lastPoll.PSObject.Properties['DelaySeconds']) { $script:now = $script:now.AddSeconds($script:lastPoll.DelaySeconds) }
                    return [pscustomobject]@{
                        ExitCode = $script:lastPoll.ExitCode
                        Output   = @($script:lastPoll.Output | ForEach-Object { $_.Replace('{NONCE}', $nonce) })
                        Errors   = $script:lastPoll.Errors
                    }
                }
                if ($remote -clike '*K2S-RUN-ABANDON*') {
                    if ($script:abandonAnswers.Count -gt 0) {
                        $answer = $script:abandonAnswers.Dequeue()
                        if ($answer.PSObject.Properties['DelaySeconds']) { $script:now = $script:now.AddSeconds($answer.DelaySeconds) }
                        return $answer
                    }
                    return New-FakeAnswer -Output @('K2S-RUN-ABANDON:done')
                }
                throw "unexpected remote command: $remote"
            }

            # -BeLike pattern that matches the literal text (the snippets contain [, ], ? and *).
            function script:Get-LikeFragment {
                param([string]$Text)
                return '*' + [System.Management.Automation.WildcardPattern]::Escape($Text) + '*'
            }

            # Returns the matching calls as one array, so that .Count also works for a single call (PowerShell 5.1).
            function script:Get-FakeCall {
                param([ValidateSet('upload', 'scp', 'promote', 'cleanup', 'start', 'poll', 'abandon', 'ssh')][string]$Kind)
                return , @($script:calls | Where-Object {
                        # Inside switch, $_ is the switch value; keep the call in its own variable.
                        $call = $_
                        $remote = $call.Arguments[-1]
                        $ssh = $call.FilePath -eq 'ssh.exe'
                        switch ($Kind) {
                            'scp' { $call.FilePath -eq 'scp.exe' }
                            'ssh' { $ssh }
                            'upload' { $ssh -and $remote -clike '*mktemp -d*' }
                            'promote' { $ssh -and $remote -clike '*K2S-STAGE-OK*' }
                            'cleanup' { $ssh -and $remote -clike 'rm -rf -- *' }
                            'start' { $ssh -and $remote -clike '*K2S-RUN-PREPARED*' }
                            'poll' { $ssh -and $remote -clike '*K2S-RUN-STATE*' }
                            'abandon' { $ssh -and $remote -clike '*K2S-RUN-ABANDON*' }
                        }
                    })
            }
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        InModuleScope $moduleName {
            Mock Write-Log { $script:logs.Add((@($Messages) -join ' ')) }
            Mock Get-WebhookAuthConnection { [pscustomobject]@{ User = 'remote@172.19.1.100'; Key = 'C:\fixture\.ssh\k2s\id_rsa'; Ssh = 'ssh.exe'; Scp = 'scp.exe' } }
            Mock Invoke-WebhookAuthProcess { Invoke-FakeNode -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds }
            Mock Get-WebhookAuthUtcNow { $script:now }
            # The monotonic clock of the deadline, in seconds since the start of the test.
            Mock Get-WebhookAuthClock { ($script:now - [datetime]::new(2026, 11, 21, 8, 0, 0, [DateTimeKind]::Utc)).TotalSeconds }
            Mock Start-Sleep { $script:now = $script:now.AddSeconds($Seconds); $script:sleeps.Add($Seconds) }
            Reset-FakeNode
        }
    }

    AfterEach {
        InModuleScope $moduleName {
            $script:pollExhausted | Should -BeFalse -Because 'every poll of a test must have a scripted answer'
        }
    }

    # --- staging ---

    Describe 'Copy-ClusterIPWebhookAuthScript' -Tag 'unit', 'ci', 'webhook-auth' {
        It 'stages the script of the K2s installation returned by Get-KubePath' {
            InModuleScope $moduleName {
                Mock Get-KubePath { $script:installation }
                $result = Copy-ClusterIPWebhookAuthScript
                $result.SourcePath | Should -Be (Join-Path $script:installation 'lib\modules\windows\node\k2s.node.module\linuxnode\distros\scripts\clusterip-webhook-auth.sh')
                $result.RemotePath | Should -BeExactly '/var/lib/k2s/webhook-auth/bin/clusterip-webhook-auth.sh'
                Should -Invoke Get-KubePath -Times 1 -Exactly
            }
        }

        It 'fails without any SSH call when the installation has no script' {
            InModuleScope $moduleName {
                Remove-Item -LiteralPath $script:source
                { Copy-ClusterIPWebhookAuthScript -InstallationPath $script:installation } | Should -Throw '*not found*does not contain the webhook authentication script*'
                $script:calls.Count | Should -Be 0
            }
        }

        It 'refuses a relative installation path' -TestCases @(
            @{ Path = 'k' }
            @{ Path = '.\k' }
            @{ Path = 'C:k' }
            @{ Path = '\k' }
        ) {
            param($Path)
            InModuleScope $moduleName -Parameters @{ Path = $Path } {
                param($Path)
                { Copy-ClusterIPWebhookAuthScript -InstallationPath $Path } | Should -Throw '*is not an absolute path*' -Because "'$Path' is relative"
                $script:calls.Count | Should -Be 0
            }
        }

        It 'transfers LF line endings without byte order mark and the SHA-256 of exactly these bytes' {
            InModuleScope $moduleName {
                $bom = [byte[]](0xEF, 0xBB, 0xBF)
                $nonAscii = [string][char]0x00E4
                Reset-FakeNode -ScriptBytes ($bom + [System.Text.Encoding]::UTF8.GetBytes("#!/bin/bash`r`necho '$nonAscii'`r`n`r`nexit 0`r`n"))
                $expected = [System.Text.Encoding]::UTF8.GetBytes("#!/bin/bash`necho '$nonAscii'`n`nexit 0`n")
                $result = Copy-ClusterIPWebhookAuthScript -InstallationPath $script:installation
                [System.Convert]::ToBase64String($script:uploaded) | Should -BeExactly ([System.Convert]::ToBase64String($expected))
                $sha256 = [System.Security.Cryptography.SHA256]::Create()
                $result.Sha256 | Should -BeExactly ((($sha256.ComputeHash($expected)) | ForEach-Object { $_.ToString('x2') }) -join '')
                $sha256.Dispose()
                $result.Size | Should -Be $expected.Length
                (Get-FakeCall promote)[0].Arguments[-1] | Should -BeLike "*'$($result.Sha256)'"
            }
        }

        It 'refuses content that is not a UTF-8 shell script instead of converting it' -TestCases @(
            @{ Name = 'UTF-16 LE'; Bytes = [byte[]](0xFF, 0xFE, 0x23, 0x00, 0x21, 0x00); Message = '*UTF-16*' }
            @{ Name = 'UTF-16 BE'; Bytes = [byte[]](0xFE, 0xFF, 0x00, 0x23, 0x00, 0x21); Message = '*UTF-16*' }
            @{ Name = 'NUL bytes'; Bytes = [byte[]](0x23, 0x21, 0x00, 0x0A); Message = '*NUL*' }
            @{ Name = 'bare CR'; Bytes = [byte[]](0x23, 0x21, 0x0D, 0x65, 0x0A); Message = '*carriage return*' }
            @{ Name = 'no #! line'; Bytes = [System.Text.Encoding]::UTF8.GetBytes("echo x`n"); Message = "*does not start with '#!'*" }
        ) {
            param($Bytes, $Message)
            InModuleScope $moduleName -Parameters @{ Bytes = $Bytes; Message = $Message } {
                param($Bytes, $Message)
                Reset-FakeNode -ScriptBytes $Bytes
                { Copy-ClusterIPWebhookAuthScript -InstallationPath $script:installation } | Should -Throw $Message
                $script:calls.Count | Should -Be 0
            }
        }

        It 'never executes an upload whose remote checksum differs' {
            InModuleScope $moduleName {
                $script:promoteAnswer = New-FakeAnswer -ExitCode 34 -Output @("K2S-STAGE-ERROR:upload-checksum:$('0' * 64)")
                $err = { Copy-ClusterIPWebhookAuthScript -InstallationPath $script:installation } | Should -Throw '*refused to install*upload-checksum*nothing was installed or executed*' -PassThru
                $err.Exception.Message | Should -Not -BeLike '*repaired automatically*'
                (Get-FakeCall start).Count | Should -Be 0
                (Get-FakeCall cleanup).Count | Should -Be 1
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'StagingFailed'
                $result.Succeeded | Should -BeFalse
                (Get-FakeCall start).Count | Should -Be 0
            }
        }

        It 'promotes the upload only after verifying it, as a non-executable temporary file renamed atomically' {
            InModuleScope $moduleName {
                $promote = Get-WebhookAuthPromoteCommand -UploadDirectory '/tmp/k2s-webhook-auth-stage.AbCdEf0123' -Sha256 ('a' * 64)
                $steps = @(
                    '[ x$s = x$h ] || { echo K2S-STAGE-ERROR:upload-checksum'
                    't=$(mktemp $b/bin/.clusterip-webhook-auth.sh.XXXXXXXXXX)'
                    'cp -- $f $t'
                    '[ x$s = x$h ] || { rm -f -- $t; echo K2S-STAGE-ERROR:temporary-checksum'
                    'chown root:root $t'
                    'chmod 0700 $t'
                    'mv -f -- $t $b/bin/clusterip-webhook-auth.sh'
                    'o=$(stat -c %U:%G:%a $b/bin/clusterip-webhook-auth.sh)'
                    'rm -f -- $b/bin/clusterip-webhook-auth.sh; echo K2S-STAGE-ERROR:final'
                    'echo K2S-STAGE-OK:$h'
                )
                $previous = -1
                foreach ($step in $steps) {
                    $index = $promote.IndexOf($step, [System.StringComparison]::Ordinal)
                    $index | Should -BeGreaterThan $previous -Because "'$step' follows the previous step"
                    $previous = $index
                }
                $promote | Should -BeLike "sudo -n /bin/sh -c 'set -eu; umask 077; *' k2s-webhook-auth '/tmp/k2s-webhook-auth-stage.AbCdEf0123' '$('a' * 64)'"
            }
        }

        It 'installs root-owned directories and script with mode 0700 and refuses insecure locations' {
            InModuleScope $moduleName {
                $promote = Get-WebhookAuthPromoteCommand -UploadDirectory '/tmp/k2s-webhook-auth-stage.AbCdEf0123' -Sha256 ('a' * 64)
                $promote | Should -BeLike (Get-LikeFragment '[ -d $d ] || install -d -m 0700 -o root -g root $d; o=$(stat -c %U:%G:%a $d); [ x$o = xroot:root:700 ] || { echo K2S-STAGE-ERROR:directory-permissions')
                $promote | Should -BeLike (Get-LikeFragment 'if [ x$s != x$h ] || [ x$o != xroot:root:700 ]; then rm -f -- $b/bin/clusterip-webhook-auth.sh;')
                $promote | Should -BeLike (Get-LikeFragment 'case $o in root:?[0145][0145]) ;; *) echo K2S-STAGE-ERROR:insecure-parent')
                $promote | Should -BeLike (Get-LikeFragment 'if [ -L $d ] || { [ -e $d ] && [ ! -d $d ]; }; then echo K2S-STAGE-ERROR:not-a-directory')
                $promote | Should -BeLike (Get-LikeFragment 'if [ -L $f ] || [ ! -f $f ]; then echo K2S-STAGE-ERROR:upload-missing')
                ([regex]::Matches($promote, 'chmod ([0-7]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) | Should -Be @('0700')
            }
        }

        It 'creates only missing directories and never repairs or adopts an existing one with other permissions' {
            InModuleScope $moduleName {
                $promote = Get-WebhookAuthPromoteCommand -UploadDirectory '/tmp/k2s-webhook-auth-stage.AbCdEf0123' -Sha256 ('a' * 64)
                # install -d would change owner and mode of an existing directory, but keep what another user wrote into it.
                @([regex]::Matches($promote, '\binstall\b[^;]*') | ForEach-Object { $_.Value }) | Should -Be @('install -d -m 0700 -o root -g root $d')
                $promote | Should -BeLike (Get-LikeFragment '[ -e $d ] && [ ! -d $d ]; }; then echo K2S-STAGE-ERROR:not-a-directory:$d; exit 36; fi; [ -d $d ] || install -d -m 0700 -o root -g root $d; o=$(stat')
                @([regex]::Matches($promote, '\b(chown|chmod)\b[^;]*') | ForEach-Object { $_.Value }) | Should -Be @('chown root:root $t', 'chmod 0700 $t')
            }
        }

        It 'refuses a layout that another user may have changed and explains how to correct it (<Detail>)' -TestCases @(
            @{ Detail = 'lock-file' }
            @{ Detail = 'directory-permissions:/var/lib/k2s/webhook-auth:remote:remote:777' }
            @{ Detail = 'not-a-directory:/var/lib/k2s/webhook-auth/bin' }
            @{ Detail = 'insecure-parent:root:777' }
        ) {
            param($Detail)
            InModuleScope $moduleName -Parameters @{ Detail = $Detail } {
                param($Detail)
                $script:promoteAnswer = New-FakeAnswer -ExitCode 40 -Output @("K2S-STAGE-ERROR:$Detail")
                { Copy-ClusterIPWebhookAuthScript -InstallationPath $script:installation } |
                    Should -Throw ('*refused to install the webhook authentication script (' + [System.Management.Automation.WildcardPattern]::Escape($Detail) + '); nothing was installed or executed. ' +
                        'Nothing below /var/lib/k2s is repaired automatically*remove /var/lib/k2s/webhook-auth after making sure that no run is active')
                (Get-FakeCall start).Count | Should -Be 0
            }
        }

        It 'can be repeated: every staging uses a new private upload directory and removes stale temporary files' {
            InModuleScope $moduleName {
                $first = Copy-ClusterIPWebhookAuthScript -InstallationPath $script:installation
                $second = Copy-ClusterIPWebhookAuthScript -InstallationPath $script:installation
                $second.Sha256 | Should -BeExactly $first.Sha256
                (Get-FakeCall upload).Count | Should -Be 2
                (Get-FakeCall promote).Count | Should -Be 2
                foreach ($call in (Get-FakeCall promote)) {
                    $call.Arguments[-1] | Should -BeLike (Get-LikeFragment 'rm -f -- $b/bin/.clusterip-webhook-auth.sh.*; t=$(mktemp')
                }
                foreach ($call in (Get-FakeCall upload)) {
                    $call.Arguments[-1] | Should -BeExactly 'umask 077 && mktemp -d /tmp/k2s-webhook-auth-stage.XXXXXXXXXX'
                }
                (Get-FakeCall cleanup).Count | Should -Be 0
                Test-Path -LiteralPath (Split-Path $script:uploadedFile) | Should -BeFalse
            }
        }

        It 'reports a failed SSH connection without copying anything' {
            InModuleScope $moduleName {
                $script:uploadAnswer = New-FakeAnswer -ExitCode 255 -Errors @('ssh: connect to host 172.19.1.100 port 22: Connection timed out')
                { Copy-ClusterIPWebhookAuthScript -InstallationPath $script:installation } | Should -Throw '*Cannot create a private upload directory*255*Connection timed out*'
                (Get-FakeCall scp).Count | Should -Be 0
            }
        }

        It 'stops at a host-key failure of scp and gives the known_hosts guidance' {
            InModuleScope $moduleName {
                $script:scpAnswer = New-FakeAnswer -ExitCode 255 -Errors @('Host key verification failed.')
                { Copy-ClusterIPWebhookAuthScript -InstallationPath $script:installation } | Should -Throw '*host-key verification failed*known_hosts*Do not disable host-key checking*'
                (Get-FakeCall promote).Count | Should -Be 0
                (Get-FakeCall cleanup).Count | Should -Be 1
            }
        }

        It 'lets the remote checksum decide after an scp error and removes the upload directory on failure' {
            InModuleScope $moduleName {
                $script:scpAnswer = New-FakeAnswer -ExitCode 1 -Errors @('scp: write: No space left on device')
                $script:promoteAnswer = New-FakeAnswer -ExitCode 33 -Output @('K2S-STAGE-ERROR:upload-missing')
                { Copy-ClusterIPWebhookAuthScript -InstallationPath $script:installation } | Should -Throw '*refused to install*upload-missing*'
                $script:logs | Where-Object { $_ -like '*No space left on device*the remote checksum decides*' } | Should -Not -BeNullOrEmpty
                (Get-FakeCall cleanup).Count | Should -Be 1
                (Get-FakeCall cleanup)[0].Arguments[-1] | Should -BeExactly "rm -rf -- '/tmp/k2s-webhook-auth-stage.AbCdEf0123'"
            }
        }

        It 'refuses an unexpected upload directory name from the node' {
            InModuleScope $moduleName {
                $script:uploadAnswer = New-FakeAnswer -Output @('/tmp/k2s-webhook-auth-stage.AbCdEf0123; rm -rf /')
                { Copy-ClusterIPWebhookAuthScript -InstallationPath $script:installation } | Should -Throw '*Cannot create a private upload directory*'
                $script:calls.Count | Should -Be 1
            }
        }

        It 'restricts the private key before using it and checks the SSH destination' {
            InModuleScope $moduleName {
                $key = Join-Path $script:fixtureRoot 'id_rsa'
                Set-Content -LiteralPath $key -Value 'fixture'
                Mock Get-SSHKeyControlPlane { $key }
                Mock Set-SshPrivateKeyPermissions {}
                Mock Get-ControlPlaneRemoteUser { 'remote@172.19.1.100' }
                $connection = & (Get-Command Get-WebhookAuthConnection -CommandType Function).ScriptBlock
                $connection.User | Should -BeExactly 'remote@172.19.1.100'
                $connection.Key | Should -BeExactly $key
                Should -Invoke Set-SshPrivateKeyPermissions -Times 1 -Exactly -ParameterFilter { $Path -eq $key }
                Mock Get-ControlPlaneRemoteUser { 'remote@172.19.1.100 -oProxyCommand=x' }
                { & (Get-Command Get-WebhookAuthConnection -CommandType Function).ScriptBlock } | Should -Throw '*Unexpected control-plane SSH destination*'
            }
        }
    }

    # --- execution ---

    Describe 'Invoke-ClusterIPWebhookAuth execution' -Tag 'unit', 'ci', 'webhook-auth' {
        It 'uses non-interactive SSH with strict host-key checking and a new connection for every step' {
            InModuleScope $moduleName {
                Add-PollAnswer (New-PollAnswer -State 'exited:0' -Log @('K2S-WEBHOOK-AUTH-VERIFY:ok', 'K2S-WEBHOOK-AUTH-OK:verify'))
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Succeeded'
                $result.Succeeded | Should -BeTrue
                (Get-FakeCall ssh).Count | Should -Be 4
                foreach ($call in (Get-FakeCall ssh)) {
                    $call.Arguments[0..1] | Should -Be @('-n', '-T')
                    ($call.Arguments[2..($call.Arguments.Count - 2)] -join ' ') | Should -BeExactly ('-F none -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 ' +
                        '-o ServerAliveCountMax=4 -o IdentitiesOnly=yes -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o ControlMaster=no ' +
                        '-o ControlPath=none -o PermitLocalCommand=no -i C:\fixture\.ssh\k2s\id_rsa remote@172.19.1.100')
                }
            }
        }

        It 'starts the command detached as root in a private run directory and reports its PID' {
            InModuleScope $moduleName {
                Add-PollAnswer (New-PollAnswer -State 'exited:0' -Log @('K2S-WEBHOOK-AUTH-OK:provision'))
                $result = Invoke-ClusterIPWebhookAuth -Command provision -InstallationPath $script:installation
                $result.RunId | Should -Match '\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z'
                $result.RunDirectory | Should -BeExactly "/var/lib/k2s/webhook-auth/runs/$($result.RunId)"
                $result.RemotePid | Should -Be 4242
                $result.RemoteProcessState | Should -BeExactly 'Exited'
                $result.ExitCode | Should -Be 0
                $start = (Get-FakeCall start)[0].Arguments[-1]
                $start | Should -BeLike ("sudo -n /bin/sh -c '*' k2s-webhook-auth '$($result.RunId)' '$($result.ScriptSha256)' 'provision'" +
                    " && sudo -n setsid -f /bin/sh -c '*' k2s-webhook-auth '$($result.RunId)' 'provision' < /dev/null > /dev/null 2>&1" +
                    " && sudo -n /bin/sh -c '*' k2s-webhook-auth '$($result.RunId)'")
                $start | Should -BeLike (Get-LikeFragment 'mkdir -m 0700 -- $b/runs/$id ||')
                $start | Should -BeLike (Get-LikeFragment ('command exec 9>$b/.lock || exit 1; flock -w 60 9 || exit 1; if [ -e $r/abandoned ] || [ -L $r/abandoned ] || [ -e $r/pid ]; then exit 1; fi; ' +
                        'command exec 8>$r/alive || exit 1; flock -n 8 || exit 1; echo $$ > $r/pid.tmp && mv -f $r/pid.tmp $r/pid || exit 1; command exec 9>&-; ' +
                        'K2S_WEBHOOK_AUTH_RUN=$id $r/clusterip-webhook-auth.sh $* < /dev/null > $r/run.log 2>&1; c=$?; echo $c > $r/exit.tmp && mv -f $r/exit.tmp $r/exit'))
                (Get-FakeCall poll)[0].Arguments[-1] | Should -BeLike "* k2s-webhook-auth '$($result.RunId)' '1048576' '$($script:nonces[0])'"
            }
        }

        It 'polls every 5 seconds with a new SSH connection and a new nonce until the exit status is written' {
            InModuleScope $moduleName {
                Add-PollAnswer (New-PollAnswer running:4242) (New-PollAnswer running:4242) (New-PollAnswer exited:0 -Log @('K2S-WEBHOOK-AUTH-OK:publish'))
                $result = Invoke-ClusterIPWebhookAuth -Command publish -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Succeeded'
                (Get-FakeCall poll).Count | Should -Be 3
                $script:sleeps | Should -Be @(5, 5)
                $script:nonces | Should -HaveCount 3
                @($script:nonces | Select-Object -Unique) | Should -HaveCount 3
                foreach ($nonce in $script:nonces) { $nonce | Should -Match '\A[0-9a-f]{32}\z' }
            }
        }

        It 'observes <Name> for <Seconds> seconds, then reports an unknown outcome without stopping or repeating the run' -TestCases @(
            @{ Name = 'ensure-apiserver'; Command = 'ensure-apiserver'; Force = $false; Seconds = 1800 }
            @{ Name = 'renew'; Command = 'renew'; Force = $false; Seconds = 1800 }
            @{ Name = 'renew --force'; Command = 'renew'; Force = $true; Seconds = 1800 }
            @{ Name = 'provision'; Command = 'provision'; Force = $false; Seconds = 600 }
            @{ Name = 'publish'; Command = 'publish'; Force = $false; Seconds = 600 }
            @{ Name = 'verify'; Command = 'verify'; Force = $false; Seconds = 600 }
        ) {
            param($Command, $Force, $Seconds)
            InModuleScope $moduleName -Parameters @{ Command = $Command; Force = $Force; Seconds = $Seconds } {
                param($Command, $Force, $Seconds)
                $script:repeatLastPoll = $true
                Add-PollAnswer (New-PollAnswer running:4242 -Log @('[ClusterIPWebhookAuth] waiting for kube-apiserver (flag); running: none'))
                $result = Invoke-ClusterIPWebhookAuth -Command $Command -Force:$Force -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'Timeout'
                $result.RemoteProcessState | Should -BeExactly 'Running'
                $result.RemotePid | Should -Be 4242
                $result.Succeeded | Should -BeFalse
                $result.RunId | Should -Match '\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z'
                $result.RunDirectory | Should -BeExactly "/var/lib/k2s/webhook-auth/runs/$($result.RunId)"
                $result.Message | Should -BeLike "*may still be running (run $($result.RunId), PID 4242, log /var/lib/k2s/webhook-auth/runs/$($result.RunId)/run.log*it was not stopped*Do not start*"
                $result.LogTail | Should -Contain '[ClusterIPWebhookAuth] waiting for kube-apiserver (flag); running: none'
                $result.Attempt | Should -Be 1
                ($null -eq $result.Renewed) | Should -BeTrue -Because 'an unknown outcome never establishes whether a certificate was renewed'
                $polls = Get-FakeCall poll
                $polls.Count | Should -Be ($Seconds / 5)
                ($script:sleeps | Measure-Object -Sum).Sum | Should -Be $Seconds
                # Every poll gets at most the remaining time; no poll starts at the deadline.
                $polls[0].TimeoutSeconds | Should -Be 120
                $polls[-12].TimeoutSeconds | Should -Be 60
                $polls[-1].TimeoutSeconds | Should -Be 5
                (Get-FakeCall start).Count | Should -Be 1
                (Get-FakeCall abandon).Count | Should -Be 0
                $script:calls | Where-Object { $_.Arguments[-1] -match '\b(kill|pkill)\b' } | Should -BeNullOrEmpty
            }
        }

        It 'observes <Command> for <Seconds> seconds' -TestCases @(
            @{ Command = 'ensure-apiserver'; Seconds = 1800 }
            @{ Command = 'renew'; Seconds = 1800 }
            @{ Command = 'provision'; Seconds = 600 }
            @{ Command = 'publish'; Seconds = 600 }
            @{ Command = 'verify'; Seconds = 600 }
        ) {
            param($Command, $Seconds)
            InModuleScope $moduleName -Parameters @{ Command = $Command; Seconds = $Seconds } {
                param($Command, $Seconds)
                Get-WebhookAuthTimeout -Command $Command | Should -Be $Seconds
            }
        }

        It 'starts no poll after the deadline and shortens the last wait to the remaining time' {
            InModuleScope $moduleName {
                $script:repeatLastPoll = $true
                $script:startDelaySeconds = 2
                Add-PollAnswer (New-PollAnswer running:4242)
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $result.Reason | Should -BeExactly 'Timeout'
                $script:sleeps[-1] | Should -Be 3
                ($script:sleeps | Measure-Object -Sum).Sum | Should -Be 598
                (Get-FakeCall poll).Count | Should -Be 120
                (Get-FakeCall poll)[-1].TimeoutSeconds | Should -Be 3
                $script:now | Should -Be ([datetime]::new(2026, 11, 21, 8, 10, 0, [DateTimeKind]::Utc))
            }
        }

        It 'never starts a poll at or after the deadline, also when polls are slow' {
            InModuleScope $moduleName {
                $script:repeatLastPoll = $true
                $script:pollDelaySeconds = 4
                Add-PollAnswer (New-PollAnswer running:4242)
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $result.Reason | Should -BeExactly 'Timeout'
                $deadline = [datetime]::new(2026, 11, 21, 8, 10, 0, [DateTimeKind]::Utc)
                # Polls start at 0, 9, 18 ... 594 s (4 s poll, 5 s pause); the last one ends at 598 s, followed by a 2 s pause.
                (Get-FakeCall poll).Count | Should -Be 67
                $script:sleeps[-1] | Should -Be 2
                $script:now | Should -Be $deadline
            }
        }

        It 'uses a final state read by the last poll before the deadline' {
            InModuleScope $moduleName {
                foreach ($i in 1..119) { Add-PollAnswer (New-PollAnswer running:4242) }
                Add-PollAnswer (New-PollAnswer exited:0 -Log @('K2S-WEBHOOK-AUTH-OK:verify'))
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Succeeded'
                (Get-FakeCall poll).Count | Should -Be 120
                (Get-FakeCall poll)[-1].TimeoutSeconds | Should -Be 5
            }
        }

        It 'does not accept a final state <State> that a poll reads only after the deadline, and does not retry' -TestCases @(
            @{ State = 'exited:0'; Log = @('K2S-WEBHOOK-AUTH-OK:publish'); Note = '*(exited:0) is not accepted*' }
            @{ State = 'exited:1'; Log = @('[ClusterIPWebhookAuth] ERROR: cannot publish'); Note = '*(exited:1) is not accepted*' }
            @{ State = 'vanished:4242'; Log = @('[ClusterIPWebhookAuth] waiting'); Note = '*(vanished) is not accepted*' }
            @{ State = 'abandoned'; Log = @(); Note = '*(abandoned) is not accepted*' }
        ) {
            param($State, $Log, $Note)
            InModuleScope $moduleName -Parameters @{ State = $State; Log = $Log; Note = $Note } {
                param($State, $Log, $Note)
                foreach ($i in 1..119) { Add-PollAnswer (New-PollAnswer running:4242) }
                # The last poll starts at 595 s with 5 s left and answers after the deadline.
                Add-PollAnswer (New-PollAnswer $State -Log $Log -DelaySeconds 7)
                $result = Invoke-ClusterIPWebhookAuth -Command publish -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'LateResult'
                $result.Succeeded | Should -BeFalse
                $result.ExitCode | Should -BeNullOrEmpty
                $result.RemoteProcessState | Should -BeExactly 'Undetermined'
                $result.Message | Should -BeLike $Note
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
                (Get-FakeCall poll).Count | Should -Be 120
            }
        }

        It 'does not accept an abandonment that is confirmed only after the deadline' {
            InModuleScope $moduleName {
                $script:repeatLastPoll = $true
                Add-PollAnswer (New-PollAnswer starting)
                $script:abandonAnswers.Enqueue((New-FakeAnswer -Output @('K2S-RUN-ABANDON:done') -DelaySeconds 481))
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'StartUnconfirmed'
                $result.Message | Should -BeLike '*could not be confirmed before the deadline that it can no longer start*arrived after the local deadline*'
                (Get-FakeCall abandon).Count | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
            }
        }

        It 'starts no abandonment after the deadline, also when time passes after the poll' {
            InModuleScope $moduleName {
                # The start takes 125 s, so the first poll finds the run unclaimed after the grace period; reporting that
                # state takes until after the deadline.
                $script:startDelaySeconds = 125
                Mock Write-Log {
                    $text = @($Messages) -join ' '
                    $script:logs.Add($text)
                    if ($text -like '*: starting') { $script:now = $script:now.AddSeconds(500) }
                }
                Add-PollAnswer (New-PollAnswer starting)
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'StartUnconfirmed'
                (Get-FakeCall poll).Count | Should -Be 1
                (Get-FakeCall abandon).Count | Should -Be 0
                (Get-FakeCall start).Count | Should -Be 1
            }
        }

        It 'keeps polling and returns an unknown outcome with run id and PID when no nonce can be generated' {
            InModuleScope $moduleName {
                Mock Get-WebhookAuthRandomHex { throw 'the random number generator failed' } -ParameterFilter { $Count -eq 16 }
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'NoAnswer'
                $result.RemoteProcessState | Should -BeExactly 'Undetermined'
                $result.RunId | Should -Match '\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z'
                $result.RemotePid | Should -Be 4242
                $result.Message | Should -BeLike '*may still be running*it was not stopped*the random number generator failed'
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
                (Get-FakeCall poll).Count | Should -Be 0
                ($script:sleeps | Measure-Object -Sum).Sum | Should -Be 1800
            }
        }

        It 'returns an unknown outcome with run id and PID instead of an exception when <Step> fails, and does not retry' -TestCases @(
            @{ Step = 'Wait-WebhookAuthRun' }
            @{ Step = 'Complete-WebhookAuthRun' }
        ) {
            param($Step)
            InModuleScope $moduleName -Parameters @{ Step = $Step } {
                param($Step)
                if ($Step -eq 'Wait-WebhookAuthRun') {
                    Mock Wait-WebhookAuthRun { throw 'unexpected local failure' }
                }
                else {
                    # A confirmed failure that would be retried if its result could be built.
                    Add-PollAnswer (New-PollAnswer exited:1 -Log @('[ClusterIPWebhookAuth] ERROR: cannot publish'))
                    Mock Complete-WebhookAuthRun { throw 'unexpected local failure' }
                }
                $result = Invoke-ClusterIPWebhookAuth -Command publish -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'LocalError'
                $result.Succeeded | Should -BeFalse
                $result.RemoteProcessState | Should -BeExactly 'Undetermined'
                $result.RemotePid | Should -Be 4242
                $result.Message | Should -BeLike ("*observing the remote run failed locally (unexpected local failure)*run $($result.RunId), PID 4242, " +
                    "log /var/lib/k2s/webhook-auth/runs/$($result.RunId)/run.log*it was not stopped. Do not start 'publish' again before it has finished.")
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
            }
        }

        It 'returns the result and performs an approved retry when the K2s log cannot be written after the start' {
            InModuleScope $moduleName {
                $script:failLogging = $false
                $script:warnings = [System.Collections.Generic.List[string]]::new()
                Mock Write-Warning { $script:warnings.Add($Message) }
                Mock Write-Log {
                    if ($script:failLogging) { throw 'the log file is locked' }
                    $script:logs.Add((@($Messages) -join ' '))
                }
                # Logging works until the first run has started, then every message fails.
                $script:startAnswers.Enqueue({ param($runId) $script:failLogging = $true; New-FakeAnswer -Output @("K2S-RUN-PREPARED:$runId", 'K2S-RUN-STARTED:4242') })
                Add-PollAnswer (New-PollAnswer running:4242) (New-PollAnswer exited:1 -Log @('[ClusterIPWebhookAuth] ERROR: cannot publish')) `
                    (New-PollAnswer exited:0 -Log @('K2S-WEBHOOK-AUTH-OK:publish'))
                $result = Invoke-ClusterIPWebhookAuth -Command publish -InstallationPath $script:installation
                $script:failLogging = $false
                $result.Status | Should -BeExactly 'Succeeded'
                $result.Attempt | Should -Be 2
                $result.PreviousAttempt.Status | Should -BeExactly 'Failed'
                (Get-FakeCall start).Count | Should -Be 2
                (Get-FakeCall poll).Count | Should -Be 3
                @($script:logs | Where-Object { $_ -like "*Starting 'publish' as run *(attempt 1)" }) | Should -HaveCount 1
                @($script:warnings | Where-Object { $_.Contains('Cannot write to the K2s log (the log file is locked): [WebhookAuth] Succeeded:') }) | Should -HaveCount 1
                @($script:warnings | Where-Object { $_.Contains("retrying once as 'publish'") }) | Should -HaveCount 1
            }
        }

        It 'returns the result and performs an approved retry when neither the K2s log nor the warning stream can be written' {
            InModuleScope $moduleName {
                $script:failLogging = $false
                $script:warningAttempts = 0
                Mock Write-Warning {
                    $script:warningAttempts++
                    if ($script:failLogging) { throw 'the warning stream is broken' }
                }
                Mock Write-Log {
                    if ($script:failLogging) { throw 'the log file is locked' }
                    $script:logs.Add((@($Messages) -join ' '))
                }
                $script:startAnswers.Enqueue({ param($runId) $script:failLogging = $true; New-FakeAnswer -Output @("K2S-RUN-PREPARED:$runId", 'K2S-RUN-STARTED:4242') })
                Add-PollAnswer (New-PollAnswer exited:1 -Log @('[ClusterIPWebhookAuth] ERROR: cannot publish')) (New-PollAnswer exited:0 -Log @('K2S-WEBHOOK-AUTH-OK:publish'))
                $result = Invoke-ClusterIPWebhookAuth -Command publish -InstallationPath $script:installation
                $script:failLogging = $false
                $result.Status | Should -BeExactly 'Succeeded'
                $result.Attempt | Should -Be 2
                $result.PreviousAttempt.Status | Should -BeExactly 'Failed'
                (Get-FakeCall start).Count | Should -Be 2
                $script:warningAttempts | Should -BeGreaterThan 2
            }
        }

        It 'never absorbs a stopped pipeline while logging' {
            InModuleScope $moduleName {
                # Throwing PipelineStoppedException would stop the test run itself, so the structure is checked: each try
                # statement of the logging wrapper rethrows it before its general catch.
                $function = (Get-Command Write-WebhookAuthLog -CommandType Function).ScriptBlock.Ast
                $tries = @($function.FindAll({ param($node) $node -is [System.Management.Automation.Language.TryStatementAst] }, $true))
                $tries | Should -HaveCount 2
                foreach ($try in $tries) {
                    $try.CatchClauses | Should -HaveCount 2
                    @($try.CatchClauses[0].CatchTypes | ForEach-Object { $_.TypeName.FullName }) | Should -Be @('System.Management.Automation.PipelineStoppedException')
                    $try.CatchClauses[0].Body.Extent.Text | Should -Match '\A\{\s*throw\s*\}\z'
                    $try.CatchClauses[1].IsCatchAll | Should -BeTrue
                }
                $function.Extent.Text | Should -BeLike '*Microsoft.PowerShell.Utility\Write-Warning -Message *'
            }
        }

        It 'measures the deadline with a monotonic clock, not with the system time' {
            InModuleScope $moduleName {
                Mock Get-WebhookAuthUtcNow { [datetime]::new(2001, 1, 1, 0, 0, 0, [DateTimeKind]::Utc) }
                $script:repeatLastPoll = $true
                Add-PollAnswer (New-PollAnswer running:4242)
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $result.Reason | Should -BeExactly 'Timeout'
                $result.RunId | Should -BeLike '20010101T000000Z-*'
                (Get-FakeCall poll).Count | Should -Be 120
                ($script:sleeps | Measure-Object -Sum).Sum | Should -Be 600
                (Get-Command Get-WebhookAuthClock -CommandType Function).ScriptBlock.ToString() | Should -BeLike '*Stopwatch]::GetTimestamp()*'
            }
        }

        It 'keeps polling while the runner ended but a process of the run still runs, and never retries such a run' {
            InModuleScope $moduleName {
                Add-PollAnswer (New-PollAnswer running:4242) (New-PollAnswer orphaned:4242) (New-PollAnswer orphaned:4242) (New-PollAnswer vanished:4242 -Log @('[ClusterIPWebhookAuth] ERROR: x'))
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'ProcessVanished'
                $result.Attempt | Should -Be 1
                (Get-FakeCall poll).Count | Should -Be 4
                (Get-FakeCall start).Count | Should -Be 1
                @($script:logs | Where-Object { $_ -like '*: running (its runner ended, a process of the run is alive) (PID 4242)' }) | Should -HaveCount 1
            }
        }

        It 'reports a run with a process that still runs after its runner ended as running at the deadline' {
            InModuleScope $moduleName {
                $script:repeatLastPoll = $true
                Add-PollAnswer (New-PollAnswer orphaned:4242)
                $result = Invoke-ClusterIPWebhookAuth -Command provision -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'Timeout'
                $result.RemoteProcessState | Should -BeExactly 'Running'
                (Get-FakeCall start).Count | Should -Be 1
            }
        }

        It 'follows a run whose start ssh.exe ended with exit code <SshExitCode> instead of starting it again' -TestCases @(
            @{ SshExitCode = 255 }
            @{ SshExitCode = 130 }
            @{ SshExitCode = 143 }
        ) {
            param($SshExitCode)
            InModuleScope $moduleName -Parameters @{ SshExitCode = $SshExitCode } {
                param($SshExitCode)
                $script:startAnswers.Enqueue((New-FakeAnswer -ExitCode $SshExitCode -Errors @('Connection reset by 172.19.1.100 port 22')))
                Add-PollAnswer (New-FakeAnswer -ExitCode 255 -Errors @('ssh: connect to host 172.19.1.100 port 22: Connection timed out')) `
                    (New-PollAnswer running:4242) (New-PollAnswer exited:0 -Log @('K2S-WEBHOOK-AUTH-OK:ensure-apiserver'))
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Succeeded'
                $result.RemotePid | Should -Be 4242
                (Get-FakeCall start).Count | Should -Be 1
                $script:logs | Where-Object { $_ -like "*start of run $($result.RunId) was not confirmed; its state is polled before any decision*(ssh exit code $SshExitCode)*" } | Should -Not -BeNullOrEmpty
            }
        }

        It 'accepts the answer of a poll even if ssh.exe reports exit code 255 for it' {
            InModuleScope $moduleName {
                $answer = New-PollAnswer exited:0 -Log @('K2S-WEBHOOK-AUTH-OK:publish')
                $answer.ExitCode = 255
                $answer.Errors = @('close - IO is still pending on closed socket. read:0, write:0')
                Add-PollAnswer $answer
                (Invoke-ClusterIPWebhookAuth -Command publish -InstallationPath $script:installation).Status | Should -BeExactly 'Succeeded'
            }
        }

        It 'reports an unknown outcome and never relaunches when the node cannot be reached until the deadline' {
            InModuleScope $moduleName {
                $script:repeatLastPoll = $true
                $script:startAnswers.Enqueue((New-FakeAnswer -ExitCode 255 -Errors @('Connection reset by 172.19.1.100 port 22')))
                Add-PollAnswer (New-FakeAnswer -ExitCode 255 -Errors @('ssh: connect to host 172.19.1.100 port 22: Connection timed out'))
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'NoAnswer'
                $result.RemoteProcessState | Should -BeExactly 'Undetermined'
                $result.Message | Should -BeLike "*may still be running (run $($result.RunId), PID unknown*Connection timed out*"
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
                (Get-FakeCall poll).Count | Should -Be 360
                (Get-FakeCall abandon).Count | Should -Be 0
            }
        }

        It 'reports a run that ended without exit status as unknown, never as success' {
            InModuleScope $moduleName {
                Add-PollAnswer (New-PollAnswer running:4242) (New-PollAnswer vanished:4242 -Log @("[ClusterIPWebhookAuth] backed up '/etc/kubernetes/manifests/kube-apiserver.yaml' to '/etc/kubernetes/k2s-webhook-auth-backup/kube-apiserver.yaml'"))
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'ProcessVanished'
                $result.RemoteProcessState | Should -BeExactly 'Vanished'
                $result.ExitCode | Should -BeNullOrEmpty
                $result.Succeeded | Should -BeFalse
                (Get-FakeCall start).Count | Should -Be 1
            }
        }

        It 'does not start a run while a previous run still runs' {
            InModuleScope $moduleName {
                $script:startAnswers.Enqueue((New-FakeAnswer -ExitCode 10 -Output @('K2S-RUN-BUSY:20261120T230000Z-0123abcd:777')))
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Busy'
                $result.Reason | Should -BeExactly 'RunInProgress'
                $result.BusyRunId | Should -BeExactly '20261120T230000Z-0123abcd'
                $result.BusyPid | Should -Be 777
                $result.RemoteProcessState | Should -BeExactly 'NotStarted'
                $result.Message | Should -BeLike '*run 20261120T230000Z-0123abcd (PID 777) is still running*'
                (Get-FakeCall start).Count | Should -Be 1
                (Get-FakeCall poll).Count | Should -Be 0
                $prepare = (Get-FakeCall start)[0].Arguments[-1]
                $prepare | Should -BeLike (Get-LikeFragment ('if [ -f $d/pid ]; then if { [ -f $d/alive ] && [ ! -L $d/alive ] && ! flock -n $d/alive true; } || grep -q -s -z -x -F -- K2S_WEBHOOK_AUTH_RUN=$r /proc/[0-9]*/environ; then n=$(head -c 16 $d/pid); case x$n in x|x*[!0-9]*) n=0;; esac; ' +
                        'if grep -q -s -z -x -F -- $r /proc/$n/cmdline; then echo K2S-RUN-BUSY:$r:$n; else echo K2S-RUN-BUSY:$r:orphaned; fi; exit 10; fi; '))
                $prepare | Should -BeLike (Get-LikeFragment ('elif [ ! -e $d/abandoned ] && [ ! -L $d/abandoned ]; then m=$(stat -c %Y $d); case x$m in x|x*[!0-9]*) echo K2S-RUN-BUSY:$r:starting; exit 10;; esac; ' +
                        'a=$((now - m)); if [ $a -ge 0 ] && [ $a -lt 120 ]; then echo K2S-RUN-BUSY:$r:starting; exit 10; fi; : > $d/abandoned || { echo K2S-RUN-ERROR:abandon; exit 49; }; fi; done'))
            }
        }

        It 'does not start a run while another run <Name>' -TestCases @(
            @{ Name = 'is being started'; Activity = 'starting'; Message = '*run 20261120T230000Z-0123abcd is being started on the control-plane node*' }
            @{ Name = 'runs without its runner'; Activity = 'orphaned'; Message = '*run 20261120T230000Z-0123abcd is still running (its runner ended, a process of the run is alive)*' }
        ) {
            param($Activity, $Message)
            InModuleScope $moduleName -Parameters @{ Activity = $Activity; Message = $Message } {
                param($Activity, $Message)
                $script:startAnswers.Enqueue((New-FakeAnswer -ExitCode 10 -Output @("K2S-RUN-BUSY:20261120T230000Z-0123abcd:$Activity")))
                $result = Invoke-ClusterIPWebhookAuth -Command renew -Force -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Busy'
                $result.BusyRunId | Should -BeExactly '20261120T230000Z-0123abcd'
                $result.BusyPid | Should -BeNullOrEmpty
                $result.Message | Should -BeLike $Message
                (Get-FakeCall start).Count | Should -Be 1
                (Get-FakeCall poll).Count | Should -Be 0
            }
        }

        It 'abandons a run that its runner has not claimed after the grace period, which proves that it never starts' {
            InModuleScope $moduleName {
                $script:repeatLastPoll = $true
                $script:startAnswers.Enqueue({ param($runId) New-FakeAnswer -ExitCode 1 -Output @("K2S-RUN-PREPARED:$runId") })
                Add-PollAnswer (New-PollAnswer starting)
                $result = Invoke-ClusterIPWebhookAuth -Command publish -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'NotStarted'
                $result.Reason | Should -BeExactly 'NotStarted'
                $result.RemoteProcessState | Should -BeExactly 'NotStarted'
                $result.Message | Should -BeLike '*can no longer start: the run was abandoned before its runner claimed it*'
                $result.Attempt | Should -Be 1
                $result.PreviousAttempt | Should -BeNullOrEmpty
                (Get-FakeCall start).Count | Should -Be 1
                # Polls at 0, 5, ... 120 s; at 120 s the grace period has passed.
                (Get-FakeCall poll).Count | Should -Be 25
                $abandon = Get-FakeCall abandon
                $abandon.Count | Should -Be 1
                $abandon[0].Arguments[-1] | Should -BeExactly "sudo -n /bin/sh -c '$($script:AbandonSnippet)' k2s-webhook-auth '$($result.RunId)'"
                $abandon[0].TimeoutSeconds | Should -Be 120
            }
        }

        It 'abandons a run whose start was not confirmed and whose directory never appeared' {
            InModuleScope $moduleName {
                $script:repeatLastPoll = $true
                $script:startAnswers.Enqueue((New-FakeAnswer -ExitCode 255 -Errors @('Connection reset by 172.19.1.100 port 22')))
                Add-PollAnswer (New-PollAnswer missing)
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'NotStarted'
                $result.RemoteProcessState | Should -BeExactly 'NotStarted'
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
                (Get-FakeCall abandon).Count | Should -Be 1
            }
        }

        It 'keeps polling a run whose runner claimed it just before it would have been abandoned' {
            InModuleScope $moduleName {
                foreach ($i in 1..25) { Add-PollAnswer (New-PollAnswer starting) }
                Add-PollAnswer (New-PollAnswer running:4242) (New-PollAnswer exited:0 -Log @('K2S-WEBHOOK-AUTH-OK:verify'))
                $script:abandonAnswers.Enqueue((New-FakeAnswer -Output @('K2S-RUN-ABANDON:claimed')))
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Succeeded'
                (Get-FakeCall abandon).Count | Should -Be 1
                (Get-FakeCall poll).Count | Should -Be 27
                @($script:logs | Where-Object { $_ -like '*its runner has started; polling continues' }) | Should -HaveCount 1
            }
        }

        It 'never reports a run as not started while it cannot be abandoned (<Name>)' -TestCases @(
            @{ Name = 'refused'; Answer = @{ ExitCode = 48; Output = @('K2S-RUN-ABANDON:error:lock') }; Detail = '*cannot mark the run as abandoned (lock)*' }
            @{ Name = 'no answer'; Answer = @{ ExitCode = 255; Errors = @('ssh: connect to host 172.19.1.100 port 22: Connection timed out') }; Detail = '*Connection timed out*' }
        ) {
            param($Answer, $Detail)
            InModuleScope $moduleName -Parameters @{ Answer = $Answer; Detail = $Detail } {
                param($Answer, $Detail)
                $script:repeatLastPoll = $true
                Add-PollAnswer (New-PollAnswer starting)
                foreach ($i in 1..200) { $script:abandonAnswers.Enqueue((New-FakeAnswer @Answer)) }
                $result = Invoke-ClusterIPWebhookAuth -Command provision -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'StartUnconfirmed'
                $result.RemoteProcessState | Should -BeExactly 'Undetermined'
                $result.Message | Should -BeLike '*could not be confirmed before the deadline that it can no longer start, so it may still start*'
                $result.Message | Should -BeLike $Detail
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
                # Every poll from 120 s on tries again: polls at 120, 125, ... 595 s.
                (Get-FakeCall abandon).Count | Should -Be 96
            }
        }

        It 'reports a run that another start has abandoned as not started without abandoning it again' {
            InModuleScope $moduleName {
                Add-PollAnswer (New-PollAnswer starting) (New-PollAnswer abandoned)
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'NotStarted'
                $result.RemoteProcessState | Should -BeExactly 'NotStarted'
                (Get-FakeCall abandon).Count | Should -Be 0
                (Get-FakeCall start).Count | Should -Be 1
            }
        }

        It 'does not run a staged script whose checksum differs from the staged one' {
            InModuleScope $moduleName {
                $script:startAnswers.Enqueue((New-FakeAnswer -ExitCode 45 -Output @('K2S-RUN-ERROR:script-checksum')))
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'NotStarted'
                $result.Reason | Should -BeExactly 'StartRefused'
                $result.Message | Should -BeLike '*refused the run (script-checksum)*'
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
                (Get-FakeCall poll).Count | Should -Be 0
            }
        }

        It 'does not start a run while the lock file on the node is not a regular root-owned file' {
            InModuleScope $moduleName {
                $script:startAnswers.Enqueue((New-FakeAnswer -ExitCode 48 -Output @('K2S-RUN-ERROR:lock-file')))
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'NotStarted'
                $result.Reason | Should -BeExactly 'StartRefused'
                $result.Message | Should -BeLike '*refused the run (lock-file)*'
                (Get-FakeCall start).Count | Should -Be 1
                (Get-FakeCall poll).Count | Should -Be 0
            }
        }
        It 'reports a run directory whose state cannot be established as unknown and does not retry (<Answer>)' -TestCases @(
            @{ Answer = 'invalid-pid' }
            @{ Answer = 'exited:abc' }
            @{ Answer = 'exited:' }
            @{ Answer = 'paused:1' }
            @{ Answer = 'invalid-directory' }
        ) {
            param($Answer)
            InModuleScope $moduleName -Parameters @{ Answer = $Answer } {
                param($Answer)
                Add-PollAnswer (New-PollAnswer $Answer -Log @('K2S-WEBHOOK-AUTH-OK:publish'))
                $result = Invoke-ClusterIPWebhookAuth -Command publish -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'InvalidRemoteState'
                $result.RemoteProcessState | Should -BeExactly 'Undetermined'
                $result.Succeeded | Should -BeFalse
                $result.Message | Should -BeLike '*cannot be determined*it may still be running*'
                (Get-FakeCall start).Count | Should -Be 1
            }
        }
    }

    # --- exit status ---

    Describe 'Exit status and success marker' -Tag 'unit', 'ci', 'webhook-auth' {
        It 'maps exit status <ExitCode> of <Arguments> with last log line <Last> to <Status> (<Reason>)' -TestCases @(
            @{ Arguments = @('provision'); ExitCode = 0; Last = 'K2S-WEBHOOK-AUTH-OK:provision'; Status = 'Succeeded'; Reason = 'Completed' }
            @{ Arguments = @('ensure-apiserver'); ExitCode = 0; Last = 'K2S-WEBHOOK-AUTH-OK:ensure-apiserver'; Status = 'Succeeded'; Reason = 'Completed' }
            @{ Arguments = @('publish'); ExitCode = 0; Last = 'K2S-WEBHOOK-AUTH-OK:publish'; Status = 'Succeeded'; Reason = 'Completed' }
            @{ Arguments = @('verify'); ExitCode = 0; Last = 'K2S-WEBHOOK-AUTH-OK:verify'; Status = 'Succeeded'; Reason = 'Completed' }
            @{ Arguments = @('renew'); ExitCode = 0; Last = 'K2S-WEBHOOK-AUTH-OK:renew'; Status = 'Succeeded'; Reason = 'Completed' }
            @{ Arguments = @('renew', '--force'); ExitCode = 0; Last = 'K2S-WEBHOOK-AUTH-OK:renew'; Status = 'Succeeded'; Reason = 'Completed' }
            @{ Arguments = @('renew', '--force'); ExitCode = 0; Last = 'K2S-WEBHOOK-AUTH-OK:renew --force'; Status = 'Unknown'; Reason = 'MarkerMissing' }
            @{ Arguments = @('publish'); ExitCode = 0; Last = '[ClusterIPWebhookAuth] published'; Status = 'Unknown'; Reason = 'MarkerMissing' }
            @{ Arguments = @('publish'); ExitCode = 0; Last = 'K2S-WEBHOOK-AUTH-OK:provision'; Status = 'Unknown'; Reason = 'MarkerMissing' }
            @{ Arguments = @('publish'); ExitCode = 0; Last = 'K2S-WEBHOOK-AUTH-OK:publish '; Status = 'Unknown'; Reason = 'MarkerMissing' }
            @{ Arguments = @('publish'); ExitCode = 0; Last = ' K2S-WEBHOOK-AUTH-OK:publish'; Status = 'Unknown'; Reason = 'MarkerMissing' }
            @{ Arguments = @('publish'); ExitCode = 0; Last = 'k2s-webhook-auth-ok:publish'; Status = 'Unknown'; Reason = 'MarkerMissing' }
            @{ Arguments = @('publish'); ExitCode = 0; Last = 'x K2S-WEBHOOK-AUTH-OK:publish'; Status = 'Unknown'; Reason = 'MarkerMissing' }
            @{ Arguments = @('verify'); ExitCode = 1; Last = '[ClusterIPWebhookAuth] ERROR: verify failed: webhook-unavailable'; Status = 'Failed'; Reason = 'CommandFailed' }
            @{ Arguments = @('verify'); ExitCode = 1; Last = 'K2S-WEBHOOK-AUTH-OK:verify'; Status = 'Failed'; Reason = 'CommandFailed' }
            @{ Arguments = @('ensure-apiserver'); ExitCode = 1; Last = '[ClusterIPWebhookAuth] ERROR: another clusterip-webhook-auth.sh run holds the lock'; Status = 'Busy'; Reason = 'Locked' }
            @{ Arguments = @('verify'); ExitCode = 2; Last = 'usage: clusterip-webhook-auth.sh provision|ensure-apiserver|publish|renew [--force]|verify'; Status = 'InvalidUsage'; Reason = 'InvalidUsage' }
            @{ Arguments = @('ensure-apiserver'); ExitCode = 3; Last = '[ClusterIPWebhookAuth] ERROR: kube-apiserver already uses another --admission-control-config-file'; Status = 'Refused'; Reason = 'Conflict' }
            @{ Arguments = @('provision'); ExitCode = 4; Last = '[ClusterIPWebhookAuth] ERROR: must run as root'; Status = 'PrerequisiteMissing'; Reason = 'PrerequisiteMissing' }
            @{ Arguments = @('ensure-apiserver'); ExitCode = 5; Last = '[ClusterIPWebhookAuth] ERROR: previous kube-apiserver manifest restored; kube-apiserver recovered'; Status = 'Recovered'; Reason = 'RolledBack' }
            @{ Arguments = @('renew'); ExitCode = 5; Last = '[ClusterIPWebhookAuth] ERROR: previous client certificate restored'; Status = 'Recovered'; Reason = 'RolledBack' }
            @{ Arguments = @('renew', '--force'); ExitCode = 5; Last = '[ClusterIPWebhookAuth] ERROR: previous client certificate restored'; Status = 'Recovered'; Reason = 'RolledBack' }
            @{ Arguments = @('provision'); ExitCode = 5; Last = '[ClusterIPWebhookAuth] ERROR: x'; Status = 'Unknown'; Reason = 'UnexpectedExitCode' }
            @{ Arguments = @('ensure-apiserver'); ExitCode = 6; Last = '[ClusterIPWebhookAuth] ERROR: previous kube-apiserver manifest restored, but kube-apiserver did not recover'; Status = 'RecoveryUnconfirmed'; Reason = 'RecoveryUnconfirmed' }
            @{ Arguments = @('renew', '--force'); ExitCode = 6; Last = '[ClusterIPWebhookAuth] ERROR: cannot restore the previous client certificate'; Status = 'RecoveryUnconfirmed'; Reason = 'RecoveryUnconfirmed' }
            @{ Arguments = @('publish'); ExitCode = 6; Last = '[ClusterIPWebhookAuth] ERROR: x'; Status = 'Unknown'; Reason = 'UnexpectedExitCode' }
            @{ Arguments = @('ensure-apiserver'); ExitCode = 130; Last = '[ClusterIPWebhookAuth] waiting'; Status = 'Unknown'; Reason = 'Interrupted' }
            @{ Arguments = @('ensure-apiserver'); ExitCode = 143; Last = 'K2S-WEBHOOK-AUTH-OK:ensure-apiserver'; Status = 'Unknown'; Reason = 'Interrupted' }
            @{ Arguments = @('verify'); ExitCode = 137; Last = '[ClusterIPWebhookAuth] waiting'; Status = 'Unknown'; Reason = 'UnexpectedExitCode' }
            @{ Arguments = @('verify'); ExitCode = 254; Last = '[ClusterIPWebhookAuth] waiting'; Status = 'Unknown'; Reason = 'UnexpectedExitCode' }
            @{ Arguments = @('verify'); ExitCode = 255; Last = 'K2S-WEBHOOK-AUTH-OK:verify'; Status = 'Unknown'; Reason = 'UnexpectedExitCode' }
            @{ Arguments = @('verify'); ExitCode = 999; Last = '[ClusterIPWebhookAuth] waiting'; Status = 'Unknown'; Reason = 'UnexpectedExitCode' }
        ) {
            param($Arguments, $ExitCode, $Last, $Status, $Reason)
            InModuleScope $moduleName -Parameters @{ Arguments = $Arguments; ExitCode = $ExitCode; Last = $Last; Status = $Status; Reason = $Reason } {
                param($Arguments, $ExitCode, $Last, $Status, $Reason)
                $result = New-WebhookAuthResult -Arguments $Arguments -Attempt 1
                $result.RunId = '20261121T080000Z-0123abcd'
                $result.RunDirectory = '/var/lib/k2s/webhook-auth/runs/20261121T080000Z-0123abcd'
                $result.ExitCode = $ExitCode
                $result.Log = @('[ClusterIPWebhookAuth] started', $Last)
                Set-WebhookAuthExitOutcome -Result $result
                $result.Status | Should -BeExactly $Status
                $result.Reason | Should -BeExactly $Reason
                $result.Succeeded | Should -Be ($Status -eq 'Succeeded')
                $result.Message | Should -BeLike '*run 20261121T080000Z-0123abcd, log /var/lib/k2s/webhook-auth/runs/20261121T080000Z-0123abcd/run.log*'
                if ($Last -ceq $result.ExpectedMarker -and $ExitCode -ne 0) {
                    $result.Message | Should -BeLike '*success marker is not accepted because the exit status is not 0*'
                }
            }
        }

        It 'expects the marker of the command itself, also for renew --force' {
            InModuleScope $moduleName {
                (New-WebhookAuthResult -Arguments @('renew', '--force') -Attempt 1).ExpectedMarker | Should -BeExactly 'K2S-WEBHOOK-AUTH-OK:renew'
                (New-WebhookAuthResult -Arguments @('ensure-apiserver') -Attempt 1).ExpectedMarker | Should -BeExactly 'K2S-WEBHOOK-AUTH-OK:ensure-apiserver'
            }
        }

        It 'does not accept a marker that is followed by another non-empty line (<Name>)' -TestCases @(
            @{ Name = 'text'; Following = '[ClusterIPWebhookAuth] ERROR: late output' }
            @{ Name = 'blanks'; Following = '   ' }
            @{ Name = 'tab'; Following = "`t" }
        ) {
            param($Following)
            InModuleScope $moduleName -Parameters @{ Following = $Following } {
                param($Following)
                Add-PollAnswer (New-PollAnswer exited:0 -Log @('K2S-WEBHOOK-AUTH-OK:verify', $Following, ''))
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'MarkerMissing'
                $result.MarkerFound | Should -BeFalse
                $result.Succeeded | Should -BeFalse
                $result.Attempt | Should -Be 1
                $result.PreviousAttempt | Should -BeNullOrEmpty
            }
        }

        It 'ignores empty lines after the marker' {
            InModuleScope $moduleName {
                Add-PollAnswer (New-PollAnswer exited:0 -Log @('K2S-WEBHOOK-AUTH-OK:verify', '', ''))
                (Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation).Status | Should -BeExactly 'Succeeded'
            }
        }

        It 'reads the log lines between the log markers of the poll exactly' -TestCases @(
            @{ Name = 'line break at the end'; Output = @('K2S-RUN-LOG-BEGIN:{N}', 'a', 'b', '', 'K2S-RUN-LOG-END:{N}'); Log = @('a', 'b') }
            @{ Name = 'no line break at the end'; Output = @('K2S-RUN-LOG-BEGIN:{N}', 'a', 'b', 'K2S-RUN-LOG-END:{N}'); Log = @('a', 'b') }
            @{ Name = 'empty last line'; Output = @('K2S-RUN-LOG-BEGIN:{N}', 'a', '', '', 'K2S-RUN-LOG-END:{N}'); Log = @('a', '') }
            @{ Name = 'markers without the nonce in the log'; Output = @('K2S-RUN-LOG-BEGIN:{N}', 'K2S-RUN-LOG-END', 'K2S-RUN-LOG-END:0123', 'K2S-RUN-STATE:exited:0', '', 'K2S-RUN-LOG-END:{N}'); Log = @('K2S-RUN-LOG-END', 'K2S-RUN-LOG-END:0123', 'K2S-RUN-STATE:exited:0') }
        ) {
            param($Output, $Log)
            InModuleScope $moduleName -Parameters @{ Output = $Output; Log = $Log } {
                param($Output, $Log)
                $nonce = 'a' * 32
                $lines = @('K2S-RUN-PID:7', 'K2S-RUN-STATE:running:7', 'K2S-RUN-LOG-SIZE:4') + @($Output | ForEach-Object { $_.Replace('{N}', $nonce) })
                $state = ConvertFrom-WebhookAuthRunState -Output $lines -Nonce $nonce
                $state.State | Should -BeExactly 'running'
                $state.LogComplete | Should -BeTrue
                ($state.Log -join '|') | Should -BeExactly ($Log -join '|')
                $state.Log.Count | Should -Be $Log.Count
            }
        }

        It 'never takes the run state from the log' {
            InModuleScope $moduleName {
                $nonce = 'b' * 32
                $state = ConvertFrom-WebhookAuthRunState -Nonce $nonce -Output @('K2S-RUN-PID:7', 'K2S-RUN-STATE:running:7', 'K2S-RUN-LOG-SIZE:40', "K2S-RUN-LOG-BEGIN:$nonce",
                    'K2S-RUN-STATE:exited:0', 'K2S-WEBHOOK-AUTH-OK:verify', '', "K2S-RUN-LOG-END:$nonce")
                $state.State | Should -BeExactly 'running'
                $state.ExitCode | Should -BeNullOrEmpty
            }
        }

        It 'treats a log without its end marker, its size or within the limit as incomplete (<Name>)' -TestCases @(
            @{ Name = 'answer ends in the log'; Output = @('K2S-RUN-LOG-SIZE:40', 'K2S-RUN-LOG-BEGIN:{N}', 'a') }
            @{ Name = 'answer ends after an end marker without nonce'; Output = @('K2S-RUN-LOG-SIZE:40', 'K2S-RUN-LOG-BEGIN:{N}', 'K2S-WEBHOOK-AUTH-OK:verify', 'K2S-RUN-LOG-END') }
            @{ Name = 'answer ends after an end marker of another nonce'; Output = @('K2S-RUN-LOG-SIZE:40', 'K2S-RUN-LOG-BEGIN:{N}', 'K2S-WEBHOOK-AUTH-OK:verify', "K2S-RUN-LOG-END:$('d' * 32)") }
            @{ Name = 'markers of another nonce'; Output = @('K2S-RUN-LOG-SIZE:40', "K2S-RUN-LOG-BEGIN:$('d' * 32)", 'K2S-WEBHOOK-AUTH-OK:verify', "K2S-RUN-LOG-END:$('d' * 32)") }
            @{ Name = 'end marker before the begin marker'; Output = @('K2S-RUN-LOG-SIZE:40', 'K2S-RUN-LOG-END:{N}', 'K2S-RUN-LOG-BEGIN:{N}', 'K2S-WEBHOOK-AUTH-OK:verify') }
            @{ Name = 'no size'; Output = @('K2S-RUN-LOG-BEGIN:{N}', 'a', '', 'K2S-RUN-LOG-END:{N}') }
            @{ Name = 'log larger than the limit'; Output = @('K2S-RUN-LOG-SIZE:1048577', 'K2S-RUN-LOG-BEGIN:{N}', 'a', '', 'K2S-RUN-LOG-END:{N}') }
        ) {
            param($Output)
            InModuleScope $moduleName -Parameters @{ Output = $Output } {
                param($Output)
                $nonce = 'c' * 32
                $lines = @('K2S-RUN-PID:7', 'K2S-RUN-STATE:exited:0') + @($Output | ForEach-Object { $_.Replace('{N}', $nonce) })
                $state = ConvertFrom-WebhookAuthRunState -Output $lines -Nonce $nonce
                $state.State | Should -BeExactly 'exited'
                $state.LogComplete | Should -BeFalse
            }
        }

        It 'does not accept a success marker from a log whose answer was cut off' {
            InModuleScope $moduleName {
                $cut = New-FakeAnswer -Output @('K2S-RUN-PID:4242', 'K2S-RUN-STATE:exited:0', 'K2S-RUN-LOG-SIZE:60', 'K2S-RUN-LOG-BEGIN:{NONCE}',
                    'K2S-WEBHOOK-AUTH-OK:ensure-apiserver', 'K2S-RUN-LOG-END')
                Add-PollAnswer $cut
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Succeeded | Should -BeFalse
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'MarkerMissing'
                $result.LogComplete | Should -BeFalse
                $result.Attempt | Should -Be 1
            }
        }

        It 'does not accept exit status 0 with an empty log' {
            InModuleScope $moduleName {
                Add-PollAnswer (New-PollAnswer exited:0 -Log @())
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Reason | Should -BeExactly 'MarkerMissing'
                $result.Succeeded | Should -BeFalse
                $result.Attempt | Should -Be 1
            }
        }

        It 'reports the exit status and the end of the log of a failed run' {
            InModuleScope $moduleName {
                $log = @(1..30 | ForEach-Object { "[ClusterIPWebhookAuth] line $_" }) + @('[ClusterIPWebhookAuth] ERROR: cannot apply the kubeadm patch')
                Add-PollAnswer (New-PollAnswer exited:3 -Log $log)
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Refused'
                $result.ExitCode | Should -Be 3
                $result.LogTail.Count | Should -Be 20
                $result.LogTail[-1] | Should -BeExactly '[ClusterIPWebhookAuth] ERROR: cannot apply the kubeadm patch'
                $result.LogTail[0] | Should -BeExactly '[ClusterIPWebhookAuth] line 12'
                (Get-FakeCall start).Count | Should -Be 1
            }
        }
    }

    # --- retry ---

    Describe 'Retry' -Tag 'unit', 'ci', 'webhook-auth' {
        It 'retries <Command> once with a new run after the first run failed and ended' -TestCases @(
            @{ Command = 'provision' }
            @{ Command = 'publish' }
            @{ Command = 'verify' }
        ) {
            param($Command)
            InModuleScope $moduleName -Parameters @{ Command = $Command } {
                param($Command)
                Add-PollAnswer (New-PollAnswer exited:1 -Log @('[ClusterIPWebhookAuth] ERROR: cannot read the CA')) (New-PollAnswer exited:0 -Log @("K2S-WEBHOOK-AUTH-OK:$Command"))
                $result = Invoke-ClusterIPWebhookAuth -Command $Command -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Succeeded'
                $result.Attempt | Should -Be 2
                $result.PreviousAttempt.Status | Should -BeExactly 'Failed'
                $result.PreviousAttempt.ExitCode | Should -Be 1
                $result.PreviousAttempt.RemoteProcessState | Should -BeExactly 'Exited'
                $result.PreviousAttempt.RunId | Should -Not -BeExactly $result.RunId
                (Get-FakeCall start).Count | Should -Be 2
                (Get-FakeCall promote).Count | Should -Be 2
                $script:runIds | Should -HaveCount 2
            }
        }

        It 'retries at most once' {
            InModuleScope $moduleName {
                Add-PollAnswer (New-PollAnswer exited:1 -Log @('[ClusterIPWebhookAuth] ERROR: cannot read the CA')) (New-PollAnswer exited:1 -Log @('[ClusterIPWebhookAuth] ERROR: cannot read the CA'))
                $result = Invoke-ClusterIPWebhookAuth -Command publish -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Failed'
                $result.Attempt | Should -Be 2
                $result.PreviousAttempt.PreviousAttempt | Should -BeNullOrEmpty
                (Get-FakeCall start).Count | Should -Be 2
                @($script:logs | Where-Object { $_ -like '*retrying once*' }) | Should -HaveCount 1
            }
        }

        It 'retries only a failure confirmed by the exit status of the first run (<Arguments>)' -TestCases @(
            @{ Arguments = 'provision'; Retry = 'provision' }
            @{ Arguments = 'publish'; Retry = 'publish' }
            @{ Arguments = 'verify'; Retry = 'verify' }
            @{ Arguments = 'renew'; Retry = 'renew' }
            @{ Arguments = 'renew --force'; Retry = 'renew' }
            @{ Arguments = 'ensure-apiserver'; Retry = 'ensure-apiserver' }
        ) {
            param($Arguments, $Retry)
            InModuleScope $moduleName -Parameters @{ Arguments = $Arguments; Retry = $Retry } {
                param($Arguments, $Retry)
                $statuses = @('Succeeded', 'Failed', 'Unknown', 'NotStarted', 'Busy', 'Refused', 'InvalidUsage', 'PrerequisiteMissing', 'Recovered', 'RecoveryUnconfirmed', 'StagingFailed')
                foreach ($status in $statuses) {
                    foreach ($state in @('Exited', 'Vanished', 'NotStarted', 'Running', 'Undetermined')) {
                        foreach ($exitCode in @($null, 0, 1, 2, 130, 143, 255)) {
                            foreach ($attempt in 1, 2) {
                                $result = New-WebhookAuthResult -Arguments ($Arguments -split ' ') -Attempt $attempt
                                $result.Status = $status
                                $result.RemoteProcessState = $state
                                $result.ExitCode = $exitCode
                                $result.LogComplete = $true
                                $result.Log = @('[ClusterIPWebhookAuth] ERROR: kube-apiserver is not ready; its manifest was not changed')
                                $retry = Get-WebhookAuthRetryArgumentList -Result $result
                                $confirmedFailure = $attempt -eq 1 -and $status -ceq 'Failed' -and $state -ceq 'Exited' -and $exitCode -eq 1
                                if ($confirmedFailure) {
                                    ($retry -join ' ') | Should -BeExactly $Retry
                                }
                                else {
                                    ($null -eq $retry) | Should -BeTrue -Because "$Arguments with $status, $state, exit status '$exitCode', attempt $attempt is no confirmed failure"
                                }
                            }
                        }
                    }
                }
            }
        }

        It 'never retries an unknown or unconfirmed outcome (<Name>)' -TestCases @(
            @{ Name = 'interrupted'; Command = 'verify'; Answer = 'exited:130' }
            @{ Name = 'terminated'; Command = 'publish'; Answer = 'exited:143' }
            @{ Name = 'unexpected exit status'; Command = 'provision'; Answer = 'exited:255' }
            @{ Name = 'exit status 0 without marker'; Command = 'verify'; Answer = 'exited:0' }
            @{ Name = 'no exit status'; Command = 'publish'; Answer = 'vanished:4242' }
            @{ Name = 'no exit status, ensure-apiserver'; Command = 'ensure-apiserver'; Answer = 'vanished:4242' }
            @{ Name = 'interrupted ensure-apiserver before the swap'; Command = 'ensure-apiserver'; Answer = 'exited:143' }
            @{ Name = 'invalid PID'; Command = 'verify'; Answer = 'invalid-pid' }
        ) {
            param($Command, $Answer)
            InModuleScope $moduleName -Parameters @{ Command = $Command; Answer = $Answer } {
                param($Command, $Answer)
                Add-PollAnswer (New-PollAnswer $Answer -Log @('[ClusterIPWebhookAuth] waiting for kube-apiserver (noflag)'))
                $result = Invoke-ClusterIPWebhookAuth -Command $Command -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Unknown'
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
            }
        }

        It 'does not retry a run that waited in vain for the lock of another run' {
            InModuleScope $moduleName {
                Add-PollAnswer (New-PollAnswer exited:1 -Log @('[ClusterIPWebhookAuth] ERROR: another clusterip-webhook-auth.sh run holds the lock'))
                $result = Invoke-ClusterIPWebhookAuth -Command provision -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Busy'
                $result.Reason | Should -BeExactly 'Locked'
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
            }
        }

        It 'repeats a failed renew --force as renew, which verifies a valid certificate before renewing it' {
            InModuleScope $moduleName {
                Add-PollAnswer (New-PollAnswer exited:1 -Log $script:renewLogs.FailedBeforeInstall) (New-PollAnswer exited:0 -Log $script:renewLogs.Renewed)
                $result = Invoke-ClusterIPWebhookAuth -Command renew -Force -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Succeeded'
                ($result.Arguments -join ' ') | Should -BeExactly 'renew'
                ($result.PreviousAttempt.Arguments -join ' ') | Should -BeExactly 'renew --force'
                $starts = Get-FakeCall start
                $starts.Count | Should -Be 2
                $starts[0].Arguments[-1] | Should -BeLike "* 'renew' '--force' && sudo -n setsid -f /bin/sh -c * 'renew' '--force' < /dev/null > /dev/null 2>&1 && *"
                $starts[1].Arguments[-1] | Should -Not -BeLike "*'--force'*"
                $starts[1].Arguments[-1] | Should -BeLike "* 'renew' && sudo -n setsid -f /bin/sh -c * 'renew' < /dev/null > /dev/null 2>&1 && *"
            }
        }

        It 'reports <Name>: Status <Status>, Renewed <Renewed>' -TestCases @(
            @{ Name = 'a successful renew --force'; Force = $true; First = 'exited:0'; FirstLog = 'Renewed'; Second = $null; SecondLog = $null; Status = 'Succeeded'; Reason = 'Completed'; Renewed = $true; Attempt = 1; Previous = $null }
            @{ Name = 'a failed renew --force whose retry only verifies'; Force = $true; First = 'exited:1'; FirstLog = 'FailedBeforeInstall'; Second = 'exited:0'; SecondLog = 'NotRenewed'; Status = 'Failed'; Reason = 'NotRenewed'; Renewed = $false; Attempt = 2; Previous = $false }
            @{ Name = 'a renew --force failed at signing whose retry only verifies'; Force = $true; First = 'exited:1'; FirstLog = 'SigningFailed'; Second = 'exited:0'; SecondLog = 'NotRenewed'; Status = 'Failed'; Reason = 'NotRenewed'; Renewed = $false; Attempt = 2; Previous = $false }
            @{ Name = 'a failed renew --force whose retry fails'; Force = $true; First = 'exited:1'; FirstLog = 'FailedBeforeInstall'; Second = 'exited:1'; SecondLog = 'VerifyFailedNotRenewed'; Status = 'Failed'; Reason = 'CommandFailed'; Renewed = $false; Attempt = 2; Previous = $false }
            @{ Name = 'a failed renew --force whose retry renews'; Force = $true; First = 'exited:1'; FirstLog = 'FailedBeforeInstall'; Second = 'exited:0'; SecondLog = 'Renewed'; Status = 'Succeeded'; Reason = 'Completed'; Renewed = $true; Attempt = 2; Previous = $false }
            @{ Name = 'a renew --force unverified after the installation whose retry verifies'; Force = $true; First = 'exited:1'; FirstLog = 'FailedAfterInstall'; Second = 'exited:0'; SecondLog = 'NotRenewed'; Status = 'Failed'; Reason = 'NotRenewed'; Renewed = $null; Attempt = 2; Previous = $null }
            @{ Name = 'a renew --force unverified after the installation whose retry fails'; Force = $true; First = 'exited:1'; FirstLog = 'FailedAfterInstall'; Second = 'exited:1'; SecondLog = 'VerifyFailedNotRenewed'; Status = 'Failed'; Reason = 'CommandFailed'; Renewed = $null; Attempt = 2; Previous = $null }
            @{ Name = 'a renew that only verifies'; Force = $false; First = 'exited:0'; FirstLog = 'NotRenewed'; Second = $null; SecondLog = $null; Status = 'Succeeded'; Reason = 'Completed'; Renewed = $false; Attempt = 1; Previous = $null }
            @{ Name = 'a renew whose verification fails twice'; Force = $false; First = 'exited:1'; FirstLog = 'VerifyFailedNotRenewed'; Second = 'exited:1'; SecondLog = 'VerifyFailedNotRenewed'; Status = 'Failed'; Reason = 'CommandFailed'; Renewed = $false; Attempt = 2; Previous = $false }
            @{ Name = 'a renew that renews'; Force = $false; First = 'exited:0'; FirstLog = 'RenewedNearExpiry'; Second = $null; SecondLog = $null; Status = 'Succeeded'; Reason = 'Completed'; Renewed = $true; Attempt = 1; Previous = $null }
            @{ Name = 'a renew unverified after the installation whose retry verifies'; Force = $false; First = 'exited:1'; FirstLog = 'FailedAfterInstall'; Second = 'exited:0'; SecondLog = 'NotRenewed'; Status = 'Succeeded'; Reason = 'Completed'; Renewed = $null; Attempt = 2; Previous = $null }
            @{ Name = 'a renew rolled back'; Force = $true; First = 'exited:5'; FirstLog = 'RolledBack'; Second = $null; SecondLog = $null; Status = 'Recovered'; Reason = 'RolledBack'; Renewed = $false; Attempt = 1; Previous = $null }
            @{ Name = 'a renew whose rollback is unconfirmed'; Force = $true; First = 'exited:6'; FirstLog = 'RestoreFailed'; Second = $null; SecondLog = $null; Status = 'RecoveryUnconfirmed'; Reason = 'RecoveryUnconfirmed'; Renewed = $null; Attempt = 1; Previous = $null }
        ) {
            param($Force, $First, $FirstLog, $Second, $SecondLog, $Status, $Reason, $Renewed, $Attempt, $Previous)
            InModuleScope $moduleName -Parameters @{ Force = $Force; First = $First; FirstLog = $FirstLog; Second = $Second; SecondLog = $SecondLog; Status = $Status; Reason = $Reason; Renewed = $Renewed; Attempt = $Attempt; Previous = $Previous } {
                param($Force, $First, $FirstLog, $Second, $SecondLog, $Status, $Reason, $Renewed, $Attempt, $Previous)
                Add-PollAnswer (New-PollAnswer $First -Log $script:renewLogs[$FirstLog])
                if ($Second) { Add-PollAnswer (New-PollAnswer $Second -Log $script:renewLogs[$SecondLog]) }
                $result = Invoke-ClusterIPWebhookAuth -Command renew -Force:$Force -InstallationPath $script:installation
                $result.Status | Should -BeExactly $Status
                $result.Reason | Should -BeExactly $Reason
                $result.Succeeded | Should -Be ($Status -ceq 'Succeeded')
                if ($null -eq $Renewed) { ($null -eq $result.Renewed) | Should -BeTrue } else { $result.Renewed | Should -BeExactly $Renewed }
                $result.Attempt | Should -Be $Attempt
                (Get-FakeCall start).Count | Should -Be $Attempt
                if ($Attempt -eq 2) {
                    if ($null -eq $Previous) { ($null -eq $result.PreviousAttempt.Renewed) | Should -BeTrue } else { $result.PreviousAttempt.Renewed | Should -BeExactly $Previous }
                    $result.PreviousAttempt.Succeeded | Should -BeFalse
                }
                if ($Reason -ceq 'NotRenewed') {
                    $outcome = if ($Renewed -eq $false) { 'it did not renew the certificate: it only verified the current certificate' } else { 'it cannot be established that it renewed the certificate' }
                    $result.Message | Should -BeLike "*'renew --force' did not renew the kube-apiserver client certificate: run $($result.RunId) ('renew') succeeded, but $outcome*First attempt:*"
                    $result.ExitCode | Should -Be 0
                }
            }
        }

        It 'establishes Renewed from the exit status and the log of the run (<Name>)' -TestCases @(
            @{ Name = 'not started'; Command = 'renew'; State = 'NotStarted'; ExitCode = $null; Status = 'NotStarted'; Log = 'Empty'; Complete = $true; Expected = $false }
            @{ Name = 'busy'; Command = 'renew'; State = 'Exited'; ExitCode = 1; Status = 'Busy'; Log = 'Locked'; Complete = $true; Expected = $false }
            @{ Name = 'failed before the installation'; Command = 'renew'; State = 'Exited'; ExitCode = 1; Status = 'Failed'; Log = 'FailedBeforeInstall'; Complete = $true; Expected = $false }
            @{ Name = 'failed at signing, after the backup'; Command = 'renew'; State = 'Exited'; ExitCode = 1; Status = 'Failed'; Log = 'SigningFailed'; Complete = $true; Expected = $false }
            @{ Name = 'failed after the installation without a certificate to restore'; Command = 'renew'; State = 'Exited'; ExitCode = 1; Status = 'Failed'; Log = 'FailedAfterInstall'; Complete = $true; Expected = $null }
            @{ Name = 'failed with an incomplete log'; Command = 'renew'; State = 'Exited'; ExitCode = 1; Status = 'Failed'; Log = 'FailedBeforeInstall'; Complete = $false; Expected = $null }
            @{ Name = 'refused'; Command = 'renew'; State = 'Exited'; ExitCode = 3; Status = 'Refused'; Log = 'Refused'; Complete = $true; Expected = $false }
            @{ Name = 'rolled back'; Command = 'renew'; State = 'Exited'; ExitCode = 5; Status = 'Recovered'; Log = 'RolledBack'; Complete = $true; Expected = $false }
            @{ Name = 'rollback unconfirmed'; Command = 'renew'; State = 'Exited'; ExitCode = 6; Status = 'RecoveryUnconfirmed'; Log = 'RestoreFailed'; Complete = $true; Expected = $null }
            @{ Name = 'restored, verification unconfirmed'; Command = 'renew'; State = 'Exited'; ExitCode = 6; Status = 'RecoveryUnconfirmed'; Log = 'RestoreUnverified'; Complete = $true; Expected = $null }
            @{ Name = 'rollback unconfirmed, no installation line'; Command = 'renew'; State = 'Exited'; ExitCode = 6; Status = 'RecoveryUnconfirmed'; Log = 'RestoreFailedWithoutInstallLine'; Complete = $true; Expected = $null }
            @{ Name = 'interrupted'; Command = 'renew'; State = 'Exited'; ExitCode = 143; Status = 'Unknown'; Log = 'Renewed'; Complete = $true; Expected = $null }
            @{ Name = 'vanished'; Command = 'renew'; State = 'Vanished'; ExitCode = $null; Status = 'Unknown'; Log = 'Renewed'; Complete = $true; Expected = $null }
            @{ Name = 'still running'; Command = 'renew'; State = 'Running'; ExitCode = $null; Status = 'Unknown'; Log = 'Renewed'; Complete = $true; Expected = $null }
            @{ Name = 'succeeded, renewal reported'; Command = 'renew'; State = 'Exited'; ExitCode = 0; Status = 'Succeeded'; Log = 'Renewed'; Complete = $true; Expected = $true }
            @{ Name = 'succeeded, renewal of a certificate near its expiry reported'; Command = 'renew'; State = 'Exited'; ExitCode = 0; Status = 'Succeeded'; Log = 'RenewedNearExpiry'; Complete = $true; Expected = $true }
            @{ Name = 'succeeded, renewal reported without its verification'; Command = 'renew'; State = 'Exited'; ExitCode = 0; Status = 'Succeeded'; Log = 'RenewedUnverified'; Complete = $true; Expected = $null }
            @{ Name = 'succeeded without renewal'; Command = 'renew'; State = 'Exited'; ExitCode = 0; Status = 'Succeeded'; Log = 'NotRenewed'; Complete = $true; Expected = $false }
            @{ Name = 'succeeded without renewal, incomplete log'; Command = 'renew'; State = 'Exited'; ExitCode = 0; Status = 'Succeeded'; Log = 'NotRenewed'; Complete = $false; Expected = $null }
            @{ Name = 'another command'; Command = 'provision'; State = 'Exited'; ExitCode = 0; Status = 'Succeeded'; Log = 'Renewed'; Complete = $true; Expected = $null }
        ) {
            param($Command, $State, $ExitCode, $Status, $Log, $Complete, $Expected)
            InModuleScope $moduleName -Parameters @{ Command = $Command; State = $State; ExitCode = $ExitCode; Status = $Status; Log = $Log; Complete = $Complete; Expected = $Expected } {
                param($Command, $State, $ExitCode, $Status, $Log, $Complete, $Expected)
                $result = New-WebhookAuthResult -Arguments @($Command) -Attempt 1
                $result.RemoteProcessState = $State
                $result.ExitCode = $ExitCode
                Set-WebhookAuthStatus -Result $result -Status $Status -Reason 'x' -Message 'x'
                $result.Log = @($script:renewLogs[$Log])
                $result.LogComplete = $Complete
                $renewed = Get-WebhookAuthRenewed -Result $result
                if ($null -eq $Expected) { ($null -eq $renewed) | Should -BeTrue } else { $renewed | Should -BeExactly $Expected }
            }
        }

        It 'does not repeat renew --force after exit status <ExitCode>' -TestCases @(
            @{ ExitCode = 2; Status = 'InvalidUsage' }
            @{ ExitCode = 3; Status = 'Refused' }
            @{ ExitCode = 4; Status = 'PrerequisiteMissing' }
            @{ ExitCode = 5; Status = 'Recovered' }
            @{ ExitCode = 6; Status = 'RecoveryUnconfirmed' }
        ) {
            param($ExitCode, $Status)
            InModuleScope $moduleName -Parameters @{ ExitCode = $ExitCode; Status = $Status } {
                param($ExitCode, $Status)
                Add-PollAnswer (New-PollAnswer "exited:$ExitCode" -Log @('[ClusterIPWebhookAuth] ERROR: x'))
                $result = Invoke-ClusterIPWebhookAuth -Command renew -Force -InstallationPath $script:installation
                $result.Status | Should -BeExactly $Status
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
            }
        }

        It 'does not retry ensure-apiserver when its log shows that the manifest swap may have started (<Name>)' -TestCases @(
            @{ Name = 'backup reported'; State = 'exited:1'; Line = "[ClusterIPWebhookAuth] backed up '/etc/kubernetes/manifests/kube-apiserver.yaml' to '/etc/kubernetes/k2s-webhook-auth-backup/kube-apiserver.yaml'" }
            @{ Name = 'manifest replaced'; State = 'exited:1'; Line = "[ClusterIPWebhookAuth] updated '/etc/kubernetes/manifests/kube-apiserver.yaml'; waiting for kube-apiserver to restart with the admission configuration" }
            @{ Name = 'restore'; State = 'exited:1'; Line = '[ClusterIPWebhookAuth] ERROR: kube-apiserver did not become ready with the admission configuration; restoring the previous manifest' }
            @{ Name = 'interrupted'; State = 'exited:130'; Line = "[ClusterIPWebhookAuth] backed up '/etc/kubernetes/manifests/kube-apiserver.yaml' to '/x'" }
            @{ Name = 'vanished'; State = 'vanished:4242'; Line = "[ClusterIPWebhookAuth] backed up '/etc/kubernetes/manifests/kube-apiserver.yaml' to '/x'" }
            @{ Name = 'no marker'; State = 'exited:0'; Line = "[ClusterIPWebhookAuth] backed up '/etc/kubernetes/manifests/kube-apiserver.yaml' to '/x'" }
        ) {
            param($State, $Line)
            InModuleScope $moduleName -Parameters @{ State = $State; Line = $Line } {
                param($State, $Line)
                Add-PollAnswer (New-PollAnswer $State -Log @("[ClusterIPWebhookAuth] credentials ready in '/etc/kubernetes/k2s-webhook-auth'", $Line, '[ClusterIPWebhookAuth] waiting'))
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Succeeded | Should -BeFalse
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
            }
        }

        It 'retries ensure-apiserver once when it failed and its complete log shows that the manifest was not replaced (<Name>)' -TestCases @(
            @{ Name = 'kube-apiserver not ready'; Line = '[ClusterIPWebhookAuth] ERROR: kube-apiserver is not ready; its manifest was not changed' }
            @{ Name = 'no temporary file'; Line = "[ClusterIPWebhookAuth] ERROR: cannot create a temporary file in '/etc/kubernetes/manifests'" }
        ) {
            param($Line)
            InModuleScope $moduleName -Parameters @{ Line = $Line } {
                param($Line)
                Add-PollAnswer (New-PollAnswer exited:1 -Log @("[ClusterIPWebhookAuth] credentials ready in '/etc/kubernetes/k2s-webhook-auth'", $Line)) `
                    (New-PollAnswer exited:0 -Log @('K2S-WEBHOOK-AUTH-OK:ensure-apiserver'))
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Succeeded'
                $result.Attempt | Should -Be 2
                $result.PreviousAttempt.LogComplete | Should -BeTrue
                (Get-FakeCall start).Count | Should -Be 2
            }
        }

        It 'does not retry ensure-apiserver when its log is incomplete' {
            InModuleScope $moduleName {
                Add-PollAnswer (New-PollAnswer exited:1 -Log @('[ClusterIPWebhookAuth] ERROR: kube-apiserver is not ready; its manifest was not changed') -LogSize 1048577)
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Failed'
                $result.LogComplete | Should -BeFalse
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
            }
        }

        It 'does not retry ensure-apiserver when the poll could not read its log completely' {
            InModuleScope $moduleName {
                # Without the end marker (tail failed), the part of the log that was not read may show the manifest swap.
                Add-PollAnswer (New-FakeAnswer -Output @('K2S-RUN-PID:4242', 'K2S-RUN-STATE:exited:1', 'K2S-RUN-LOG-SIZE:120', 'K2S-RUN-LOG-BEGIN:{NONCE}',
                        '[ClusterIPWebhookAuth] ERROR: kube-apiserver is not ready; its manifest was not changed'))
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Failed'
                $result.LogComplete | Should -BeFalse
                $result.Log | Should -HaveCount 0
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
            }
        }

        It 'does not retry <Command> when its run never started' -TestCases @(
            @{ Command = 'ensure-apiserver' }
            @{ Command = 'verify' }
        ) {
            param($Command)
            InModuleScope $moduleName -Parameters @{ Command = $Command } {
                param($Command)
                $script:startAnswers.Enqueue((New-FakeAnswer -ExitCode 255 -Errors @('Connection reset by 172.19.1.100 port 22')))
                foreach ($i in 1..25) { Add-PollAnswer (New-PollAnswer missing) }
                $result = Invoke-ClusterIPWebhookAuth -Command $Command -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'NotStarted'
                $result.RemoteProcessState | Should -BeExactly 'NotStarted'
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
                (Get-FakeCall poll).Count | Should -Be 25
                (Get-FakeCall abandon).Count | Should -Be 1
            }
        }
    }

    # --- contract with clusterip-webhook-auth.sh ---

    Describe 'Recorded output of clusterip-webhook-auth.sh' -Tag 'unit', 'ci', 'webhook-auth' {
        It 'reads every scenario recorded by test/clusterip-webhook-auth.sh' {
            InModuleScope $moduleName {
                $expected = @('ensure-apiserver/configured', 'ensure-apiserver/already-configured', 'ensure-apiserver/configured-not-ready', 'ensure-apiserver/custom',
                    'ensure-apiserver/not-ready-before-change', 'ensure-apiserver/credentials-not-flushed', 'ensure-apiserver/backup-failed', 'ensure-apiserver/replace-failed',
                    'ensure-apiserver/configured-with-warning', 'ensure-apiserver/rolled-back', 'ensure-apiserver/recovery-unconfirmed', 'ensure-apiserver/restore-failed',
                    'ensure-apiserver/locked', 'provision', 'publish', 'verify/ok', 'verify/failed', 'renew/verified', 'renew/verify-failed', 'renew/forced', 'renew/renewed',
                    'renew/renewed-without-backup', 'renew/unverified-without-backup', 'renew/current-certificate-not-working', 'renew/signing-failed', 'renew/rolled-back',
                    'renew/restore-unverified', 'renew/restore-failed', 'renew/custom', 'renew/locked')
                (@($script:scriptLogs.Keys | Sort-Object) -join ',') | Should -BeExactly (@($expected | Sort-Object) -join ',')
                foreach ($name in $expected) { $script:scriptLogs[$name].Count | Should -BeGreaterThan 0 -Because $name }
            }
        }

        It 'finds the success marker only as the last line of a run with exit status 0 (<Name>)' -TestCases @(
            @{ Name = 'ensure-apiserver/configured'; Command = 'ensure-apiserver' }
            @{ Name = 'ensure-apiserver/configured-with-warning'; Command = 'ensure-apiserver' }
            @{ Name = 'provision'; Command = 'provision' }
            @{ Name = 'publish'; Command = 'publish' }
            @{ Name = 'verify/ok'; Command = 'verify' }
            @{ Name = 'renew/verified'; Command = 'renew' }
            @{ Name = 'renew/forced'; Command = 'renew' }
        ) {
            param($Name, $Command)
            InModuleScope $moduleName -Parameters @{ Name = $Name; Command = $Command } {
                param($Name, $Command)
                $script:scriptExitCodes[$Name] | Should -Be 0
                $script:scriptLogs[$Name][-1] | Should -BeExactly "K2S-WEBHOOK-AUTH-OK:$Command"
                @($script:scriptLogs[$Name] | Where-Object { $_ -clike '*K2S-WEBHOOK-AUTH-OK*' }) | Should -HaveCount 1
                foreach ($other in @($script:scriptLogs.Keys | Where-Object { $script:scriptExitCodes[$_] -ne 0 })) {
                    @($script:scriptLogs[$other] | Where-Object { $_ -clike '*K2S-WEBHOOK-AUTH-OK*' }) | Should -HaveCount 0 -Because "$other ended with exit status $($script:scriptExitCodes[$other])"
                }
            }
        }

        It 'classifies <Name>: <Status> (<Reason>), manifest swap <Swap>, retry <Retry>, Renewed <Renewed>, <Warnings> warnings' -TestCases @(
            @{ Name = 'ensure-apiserver/configured'; Arguments = @('ensure-apiserver'); Status = 'Succeeded'; Reason = 'Completed'; Swap = $true; Retry = ''; Renewed = $null; Warnings = 0 }
            @{ Name = 'ensure-apiserver/already-configured'; Arguments = @('ensure-apiserver'); Status = 'Succeeded'; Reason = 'Completed'; Swap = $false; Retry = ''; Renewed = $null; Warnings = 0 }
            @{ Name = 'ensure-apiserver/configured-not-ready'; Arguments = @('ensure-apiserver'); Status = 'Failed'; Reason = 'CommandFailed'; Swap = $false; Retry = 'ensure-apiserver'; Renewed = $null; Warnings = 0 }
            @{ Name = 'ensure-apiserver/custom'; Arguments = @('ensure-apiserver'); Status = 'Refused'; Reason = 'Conflict'; Swap = $false; Retry = ''; Renewed = $null; Warnings = 0 }
            @{ Name = 'ensure-apiserver/not-ready-before-change'; Arguments = @('ensure-apiserver'); Status = 'Failed'; Reason = 'CommandFailed'; Swap = $false; Retry = 'ensure-apiserver'; Renewed = $null; Warnings = 0 }
            @{ Name = 'ensure-apiserver/credentials-not-flushed'; Arguments = @('ensure-apiserver'); Status = 'Failed'; Reason = 'CommandFailed'; Swap = $false; Retry = 'ensure-apiserver'; Renewed = $null; Warnings = 0 }
            @{ Name = 'ensure-apiserver/backup-failed'; Arguments = @('ensure-apiserver'); Status = 'Failed'; Reason = 'CommandFailed'; Swap = $false; Retry = 'ensure-apiserver'; Renewed = $null; Warnings = 0 }
            @{ Name = 'ensure-apiserver/replace-failed'; Arguments = @('ensure-apiserver'); Status = 'Failed'; Reason = 'CommandFailed'; Swap = $true; Retry = ''; Renewed = $null; Warnings = 0 }
            @{ Name = 'ensure-apiserver/configured-with-warning'; Arguments = @('ensure-apiserver'); Status = 'Succeeded'; Reason = 'Completed'; Swap = $true; Retry = ''; Renewed = $null; Warnings = 1 }
            @{ Name = 'ensure-apiserver/rolled-back'; Arguments = @('ensure-apiserver'); Status = 'Recovered'; Reason = 'RolledBack'; Swap = $true; Retry = ''; Renewed = $null; Warnings = 0 }
            @{ Name = 'ensure-apiserver/recovery-unconfirmed'; Arguments = @('ensure-apiserver'); Status = 'RecoveryUnconfirmed'; Reason = 'RecoveryUnconfirmed'; Swap = $true; Retry = ''; Renewed = $null; Warnings = 0 }
            @{ Name = 'ensure-apiserver/restore-failed'; Arguments = @('ensure-apiserver'); Status = 'RecoveryUnconfirmed'; Reason = 'RecoveryUnconfirmed'; Swap = $true; Retry = ''; Renewed = $null; Warnings = 0 }
            @{ Name = 'ensure-apiserver/locked'; Arguments = @('ensure-apiserver'); Status = 'Busy'; Reason = 'Locked'; Swap = $false; Retry = ''; Renewed = $null; Warnings = 0 }
            @{ Name = 'provision'; Arguments = @('provision'); Status = 'Succeeded'; Reason = 'Completed'; Swap = $null; Retry = ''; Renewed = $null; Warnings = 0 }
            @{ Name = 'publish'; Arguments = @('publish'); Status = 'Succeeded'; Reason = 'Completed'; Swap = $null; Retry = ''; Renewed = $null; Warnings = 0 }
            @{ Name = 'verify/ok'; Arguments = @('verify'); Status = 'Succeeded'; Reason = 'Completed'; Swap = $null; Retry = ''; Renewed = $null; Warnings = 0 }
            @{ Name = 'verify/failed'; Arguments = @('verify'); Status = 'Failed'; Reason = 'CommandFailed'; Swap = $null; Retry = 'verify'; Renewed = $null; Warnings = 0 }
            @{ Name = 'renew/verified'; Arguments = @('renew'); Status = 'Succeeded'; Reason = 'Completed'; Swap = $null; Retry = ''; Renewed = $false; Warnings = 0 }
            @{ Name = 'renew/verify-failed'; Arguments = @('renew'); Status = 'Failed'; Reason = 'CommandFailed'; Swap = $null; Retry = 'renew'; Renewed = $false; Warnings = 0 }
            @{ Name = 'renew/forced'; Arguments = @('renew', '--force'); Status = 'Succeeded'; Reason = 'Completed'; Swap = $null; Retry = ''; Renewed = $true; Warnings = 0 }
            @{ Name = 'renew/renewed'; Arguments = @('renew'); Status = 'Succeeded'; Reason = 'Completed'; Swap = $null; Retry = ''; Renewed = $true; Warnings = 1 }
            @{ Name = 'renew/renewed-without-backup'; Arguments = @('renew'); Status = 'Succeeded'; Reason = 'Completed'; Swap = $null; Retry = ''; Renewed = $true; Warnings = 0 }
            @{ Name = 'renew/unverified-without-backup'; Arguments = @('renew'); Status = 'Failed'; Reason = 'CommandFailed'; Swap = $null; Retry = 'renew'; Renewed = $null; Warnings = 0 }
            @{ Name = 'renew/current-certificate-not-working'; Arguments = @('renew', '--force'); Status = 'Failed'; Reason = 'CommandFailed'; Swap = $null; Retry = 'renew'; Renewed = $false; Warnings = 0 }
            @{ Name = 'renew/signing-failed'; Arguments = @('renew', '--force'); Status = 'Failed'; Reason = 'CommandFailed'; Swap = $null; Retry = 'renew'; Renewed = $false; Warnings = 0 }
            @{ Name = 'renew/rolled-back'; Arguments = @('renew', '--force'); Status = 'Recovered'; Reason = 'RolledBack'; Swap = $null; Retry = ''; Renewed = $false; Warnings = 0 }
            @{ Name = 'renew/restore-unverified'; Arguments = @('renew', '--force'); Status = 'RecoveryUnconfirmed'; Reason = 'RecoveryUnconfirmed'; Swap = $null; Retry = ''; Renewed = $null; Warnings = 0 }
            @{ Name = 'renew/restore-failed'; Arguments = @('renew', '--force'); Status = 'RecoveryUnconfirmed'; Reason = 'RecoveryUnconfirmed'; Swap = $null; Retry = ''; Renewed = $null; Warnings = 0 }
            @{ Name = 'renew/custom'; Arguments = @('renew', '--force'); Status = 'Refused'; Reason = 'Conflict'; Swap = $null; Retry = ''; Renewed = $false; Warnings = 0 }
            @{ Name = 'renew/locked'; Arguments = @('renew', '--force'); Status = 'Busy'; Reason = 'Locked'; Swap = $null; Retry = ''; Renewed = $false; Warnings = 0 }
        ) {
            param($Name, $Arguments, $Status, $Reason, $Swap, $Retry, $Renewed, $Warnings)
            InModuleScope $moduleName -Parameters @{ Name = $Name; Arguments = $Arguments; Status = $Status; Reason = $Reason; Swap = $Swap; Retry = $Retry; Renewed = $Renewed; Warnings = $Warnings } {
                param($Name, $Arguments, $Status, $Reason, $Swap, $Retry, $Renewed, $Warnings)
                $log = $script:scriptLogs[$Name]
                $result = New-WebhookAuthResult -Arguments $Arguments -Attempt 1
                $result.RunId = '20261121T080000Z-0123abcd'
                $result.RunDirectory = '/var/lib/k2s/webhook-auth/runs/20261121T080000Z-0123abcd'
                $state = New-WebhookAuthRunState
                $state.State = 'exited'
                $state.ExitCode = $script:scriptExitCodes[$Name]
                $state.RemotePid = 4242
                $state.Log = $log
                $state.LogComplete = $true
                $result = Complete-WebhookAuthRun -Result $result -Start ([pscustomobject]@{ RemotePid = 4242 }) -Wait ([pscustomobject]@{ Final = $true; State = $state; LastProblem = '' })
                $result.Status | Should -BeExactly $Status
                $result.Reason | Should -BeExactly $Reason
                $result.ExitCode | Should -Be $script:scriptExitCodes[$Name]
                $result.MarkerFound | Should -Be ($Status -ceq 'Succeeded')
                $result.Warnings | Should -HaveCount $Warnings
                if ($Warnings -gt 0) { $result.Message | Should -BeLike "*. Warnings: $([System.Management.Automation.WildcardPattern]::Escape($result.Warnings[0]))*" }
                if ($null -ne $Swap) {
                    Test-WebhookAuthManifestSwapStarted -Log $log -LogComplete $true | Should -Be $Swap
                    # A log that was not read completely never proves that the manifest was not replaced.
                    Test-WebhookAuthManifestSwapStarted -Log $log -LogComplete $false | Should -BeTrue
                }
                $retryArguments = Get-WebhookAuthRetryArgumentList -Result $result
                if ($Retry) { ($retryArguments -join ' ') | Should -BeExactly $Retry } else { ($null -eq $retryArguments) | Should -BeTrue }
                $renewedResult = Get-WebhookAuthRenewed -Result $result
                if ($null -eq $Renewed) { ($null -eq $renewedResult) | Should -BeTrue } else { $renewedResult | Should -BeExactly $Renewed }
            }
        }

        It 'never proves with a partly read log that the manifest of <Name> was not replaced' -TestCases @(
            @{ Name = 'ensure-apiserver/configured' }
            @{ Name = 'ensure-apiserver/replace-failed' }
            @{ Name = 'ensure-apiserver/rolled-back' }
            @{ Name = 'ensure-apiserver/recovery-unconfirmed' }
        ) {
            param($Name)
            InModuleScope $moduleName -Parameters @{ Name = $Name } {
                param($Name)
                $log = $script:scriptLogs[$Name]
                for ($count = 0; $count -le $log.Count; $count++) {
                    $part = if ($count -gt 0) { [string[]]$log[0..($count - 1)] } else { [string[]]@() }
                    Test-WebhookAuthManifestSwapStarted -Log $part -LogComplete $false | Should -BeTrue -Because "the first $count lines were read"
                    $result = New-WebhookAuthResult -Arguments @('ensure-apiserver') -Attempt 1
                    $result.Status = 'Failed'
                    $result.RemoteProcessState = 'Exited'
                    $result.ExitCode = 1
                    $result.Log = $part
                    $result.LogComplete = $false
                    ($null -eq (Get-WebhookAuthRetryArgumentList -Result $result)) | Should -BeTrue -Because "the first $count lines were read"
                }
            }
        }

        It 'does not repeat ensure-apiserver after <Name>, and repeats it once after <Repeated>' -TestCases @(
            @{ Name = 'ensure-apiserver/replace-failed'; Repeated = 'ensure-apiserver/credentials-not-flushed' }
        ) {
            param($Name, $Repeated)
            InModuleScope $moduleName -Parameters @{ Name = $Name; Repeated = $Repeated } {
                param($Name, $Repeated)
                Add-PollAnswer (New-PollAnswer exited:1 -Log $script:scriptLogs[$Name])
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Failed'
                $result.Attempt | Should -Be 1
                (Get-FakeCall start).Count | Should -Be 1
                Reset-FakeNode
                Add-PollAnswer (New-PollAnswer exited:1 -Log $script:scriptLogs[$Repeated]) (New-PollAnswer exited:0 -Log $script:scriptLogs['ensure-apiserver/configured'])
                $result = Invoke-ClusterIPWebhookAuth -Command ensure-apiserver -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Succeeded'
                $result.Attempt | Should -Be 2
                $result.PreviousAttempt.Message | Should -BeLike '*cannot flush the credentials to disk; the kube-apiserver manifest was not changed*'
                (Get-FakeCall start).Count | Should -Be 2
            }
        }
    }

    # --- security ---

    Describe 'Security' -Tag 'unit', 'ci', 'webhook-auth' {
        It 'passes exactly the hardened options to every ssh.exe and scp.exe call and only uploads files' {
            InModuleScope $moduleName {
                Add-PollAnswer (New-PollAnswer exited:1 -Log @('[ClusterIPWebhookAuth] ERROR: x')) (New-PollAnswer exited:0 -Log @('K2S-WEBHOOK-AUTH-OK:publish'))
                $null = Invoke-ClusterIPWebhookAuth -Command publish -InstallationPath $script:installation
                $script:calls.Count | Should -Be 10
                $options = ('-F none -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 ' +
                    '-o IdentitiesOnly=yes -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none ' +
                    '-o PermitLocalCommand=no -i C:\fixture\.ssh\k2s\id_rsa')
                foreach ($call in (Get-FakeCall ssh)) {
                    ($call.Arguments[0..($call.Arguments.Count - 3)] -join ' ') | Should -BeExactly "-n -T $options"
                    $call.Arguments[-2] | Should -BeExactly 'remote@172.19.1.100'
                }
                $temp = [System.Management.Automation.WildcardPattern]::Escape([System.IO.Path]::GetTempPath())
                foreach ($call in (Get-FakeCall scp)) {
                    ($call.Arguments[0..($call.Arguments.Count - 3)] -join ' ') | Should -BeExactly $options
                    $call.Arguments[-2] | Should -BeLike "${temp}k2s-webhook-auth-*\clusterip-webhook-auth.sh"
                    $call.Arguments[-1] | Should -BeExactly 'remote@172.19.1.100:/tmp/k2s-webhook-auth-stage.AbCdEf0123/clusterip-webhook-auth.sh'
                }
                (Get-FakeCall ssh).Count + (Get-FakeCall scp).Count | Should -Be $script:calls.Count
            }
        }

        It 'contains no option that weakens host-key verification' {
            $source = Get-Content -LiteralPath "$PSScriptRoot\clusterip-webhook-auth.module.psm1" -Raw
            $source | Should -Not -Match 'StrictHostKeyChecking=(?!yes)'
            $source | Should -Not -Match 'KnownHostsFile'
            $source | Should -Not -Match 'Invoke-(SSH|SCP)WithKey'
        }

        It 'reads no SSH configuration file, so that no configured command runs locally' {
            InModuleScope $moduleName {
                $connection = [pscustomobject]@{ User = 'remote@172.19.1.100'; Key = 'C:\fixture\.ssh\k2s\id_rsa'; Ssh = 'ssh.exe'; Scp = 'scp.exe' }
                $options = @(Get-WebhookAuthSshOptionList -Connection $connection)
                $options[0..1] | Should -Be @('-F', 'none')
                @($options | Where-Object { $_ -ceq '-F' }) | Should -HaveCount 1
                $options | Should -Not -Contain 'ProxyCommand'
                @($options | Where-Object { $_ -match '\A(ProxyCommand|ProxyJump|LocalCommand|KnownHostsCommand|Match)' }) | Should -HaveCount 0
            }
        }

        It 'passes the private key only as a file path and never outputs key material' {
            InModuleScope $moduleName {
                $secret = 'FIXTURE-PRIVATE-KEY-MATERIAL-0123456789'
                $script:secretKey = Join-Path $script:fixtureRoot 'id_secret'
                Set-Content -LiteralPath $script:secretKey -Value "-----BEGIN OPENSSH PRIVATE KEY-----`n$secret`n-----END OPENSSH PRIVATE KEY-----"
                Mock Get-WebhookAuthConnection { [pscustomobject]@{ User = 'remote@172.19.1.100'; Key = $script:secretKey; Ssh = 'ssh.exe'; Scp = 'scp.exe' } }
                $script:startAnswers.Enqueue((New-FakeAnswer -ExitCode 255 -Errors @("Load key `"$($script:secretKey)`": invalid format")))
                Add-PollAnswer (New-PollAnswer exited:1 -Log @('[ClusterIPWebhookAuth] ERROR: x')) (New-PollAnswer exited:0 -Log @('K2S-WEBHOOK-AUTH-OK:verify'))
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $text = (@($script:logs) + @($result.Message, $result.PreviousAttempt.Message) + @($script:calls | ForEach-Object { $_.Arguments })) -join "`n"
                $text | Should -Not -BeLike "*$secret*"
                $text | Should -Not -BeLike '*PRIVATE KEY*'
                foreach ($call in $script:calls) {
                    $index = [Array]::IndexOf($call.Arguments, '-i')
                    $index | Should -BeGreaterThan -1
                    $call.Arguments[$index + 1] | Should -BeExactly $script:secretKey
                }
            }
        }

        It 'reads only the files of its run directory on the node' {
            InModuleScope $moduleName {
                $poll = Get-WebhookAuthPollCommand -RunId '20261121T080000Z-0123abcd' -Nonce ('a' * 32)
                ([regex]::Matches($poll, '(head -c 16|tail -c \$2|stat -c %s) ([^ ;)]+)') | ForEach-Object { $_.Groups[2].Value } | Sort-Object -Unique) -join ',' |
                    Should -BeExactly '$r/exit,$r/pid,$r/run.log'
                foreach ($snippet in @($script:PromoteSnippet, $script:PrepareSnippet, $script:RunnerSnippet, $script:WaitStartSnippet, $script:PollSnippet, $script:AbandonSnippet)) {
                    $snippet | Should -Not -Match '/etc/|\bcat\b|\.key\b|\.crt\b|\bcurl\b|\bwget\b|\bkill\b'
                }
                # The poll and the start of a run only test other processes for their run id; nothing of /proc is output.
                foreach ($snippet in @($script:PrepareSnippet, $script:PollSnippet)) {
                    $paths = @([regex]::Matches($snippet, '/proc/[^ ;]+') | ForEach-Object { $_.Value } | Select-Object -Unique)
                    $paths.Count | Should -Be 2
                    $paths | Should -Contain '/proc/$n/cmdline'
                    $paths | Should -Contain '/proc/[0-9]*/environ'
                    @([regex]::Matches($snippet, 'grep [^;]*/proc/') | Where-Object { $_.Value -notlike 'grep -q -s -z -x -F -- *' }) | Should -HaveCount 0
                }
            }
        }

        It 'rejects the command <Command> before any SSH call' -TestCases @(
            @{ Command = 'Provision' }
            @{ Command = 'VERIFY' }
            @{ Command = 'provision; id' }
            @{ Command = 'verify && reboot' }
            @{ Command = "verify`nid" }
            @{ Command = 'renew --force' }
            @{ Command = 'rm' }
            @{ Command = '' }
        ) {
            param($Command)
            InModuleScope $moduleName -Parameters @{ Command = $Command } {
                param($Command)
                { Invoke-ClusterIPWebhookAuth -Command $Command -InstallationPath $script:installation } | Should -Throw -Because "'$Command' is no command of the script"
                $script:calls.Count | Should -Be 0
            }
        }

        It 'accepts -Force only with renew (<Command>)' -TestCases @(
            @{ Command = 'provision' }
            @{ Command = 'ensure-apiserver' }
            @{ Command = 'publish' }
            @{ Command = 'verify' }
        ) {
            param($Command)
            InModuleScope $moduleName -Parameters @{ Command = $Command } {
                param($Command)
                { Invoke-ClusterIPWebhookAuth -Command $Command -Force -InstallationPath $script:installation } | Should -Throw '*-Force is only valid with the renew command*' -Because "'$Command' has no -Force"
                $script:calls.Count | Should -Be 0
            }
        }

        It 'exports only the two public functions, which take no command line or remote path' {
            $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
            ((Get-Command Invoke-ClusterIPWebhookAuth).Parameters.Keys | Where-Object { $_ -notin $common } | Sort-Object) -join ',' | Should -BeExactly 'Command,Force,InstallationPath'
            ((Get-Command Copy-ClusterIPWebhookAuthScript).Parameters.Keys | Where-Object { $_ -notin $common } | Sort-Object) -join ',' | Should -BeExactly 'InstallationPath'
            ((Get-Module $moduleName).ExportedFunctions.Keys | Sort-Object) -join ',' | Should -BeExactly 'Copy-ClusterIPWebhookAuthScript,Invoke-ClusterIPWebhookAuth'
        }

        It 'refuses to pass <Name> to the remote shell' -TestCases @(
            @{ Name = 'a single quote'; Value = "a'b" }
            @{ Name = 'a double quote'; Value = 'a"b' }
            @{ Name = 'a space'; Value = 'a b' }
            @{ Name = 'a semicolon'; Value = 'a;b' }
            @{ Name = 'a command substitution'; Value = '$(id)' }
            @{ Name = 'a backtick'; Value = 'a`b' }
            @{ Name = 'a line break'; Value = "a`nb" }
            @{ Name = 'a trailing line break'; Value = "a`n" }
            @{ Name = 'a glob'; Value = 'a*' }
            @{ Name = 'a redirection'; Value = 'a>b' }
            @{ Name = 'an ampersand'; Value = 'a&b' }
            @{ Name = 'a pipe'; Value = 'a|b' }
            @{ Name = 'a backslash'; Value = 'a\b' }
            @{ Name = 'a non-ASCII letter'; Value = "a$([char]0x00E4)" }
        ) {
            param($Value)
            InModuleScope $moduleName -Parameters @{ Value = $Value } {
                param($Value)
                { ConvertTo-WebhookAuthShellWord -Value $Value } | Should -Throw '*Refusing to pass*' -Because "'$Value' is no safe shell word"
            }
        }

        It 'validates run ids, checksums, upload directories and arguments before building a remote command' {
            InModuleScope $moduleName {
                $id = '20261121T080000Z-0123abcd'
                $sha = 'a' * 64
                { Get-WebhookAuthPollCommand -RunId "$id`nid" -Nonce ('a' * 32) } | Should -Throw '*Invalid run id*'
                { Get-WebhookAuthPollCommand -RunId "$id`n" -Nonce ('a' * 32) } | Should -Throw '*Invalid run id*'
                { Get-WebhookAuthPollCommand -RunId '../../../etc' -Nonce ('a' * 32) } | Should -Throw '*Invalid run id*'
                { Get-WebhookAuthPollCommand -RunId $id -Nonce ('A' * 32) } | Should -Throw '*Invalid nonce*'
                { Get-WebhookAuthPollCommand -RunId $id -Nonce ('a' * 31) } | Should -Throw '*Invalid nonce*'
                { Get-WebhookAuthPollCommand -RunId $id -Nonce (('a' * 32) + "`n") } | Should -Throw '*Invalid nonce*'
                { Get-WebhookAuthPollCommand -RunId $id -Nonce "$('a' * 31)'" } | Should -Throw '*Invalid nonce*'
                { Get-WebhookAuthStartCommand -RunId "$id'; reboot; '" -Sha256 $sha -Arguments @('verify') } | Should -Throw '*Invalid run id*'
                { Get-WebhookAuthStartCommand -RunId '20261121T080000Z-0123ABCD' -Sha256 $sha -Arguments @('verify') } | Should -Throw '*Invalid run id*'
                { Get-WebhookAuthStartCommand -RunId $id -Sha256 ('A' * 64) -Arguments @('verify') } | Should -Throw '*Invalid SHA-256*'
                { Get-WebhookAuthStartCommand -RunId $id -Sha256 "$sha`n" -Arguments @('verify') } | Should -Throw '*Invalid SHA-256*'
                { Get-WebhookAuthStartCommand -RunId $id -Sha256 $sha -Arguments @('verify', 'x') } | Should -Throw '*Unsupported*'
                { Get-WebhookAuthStartCommand -RunId $id -Sha256 $sha -Arguments @('renew --force') } | Should -Throw '*Unsupported*'
                { Get-WebhookAuthStartCommand -RunId $id -Sha256 $sha -Arguments @('--force', 'renew') } | Should -Throw '*Unsupported*'
                { Get-WebhookAuthStartCommand -RunId $id -Sha256 $sha -Arguments @('Verify') } | Should -Throw '*Unsupported*'
                { Get-WebhookAuthCleanupCommand -UploadDirectory '/tmp/k2s-webhook-auth-stage.AbCdEf0123/../../etc' } | Should -Throw '*Unexpected remote upload directory*'
                { Get-WebhookAuthPromoteCommand -UploadDirectory '/tmp/k2s-webhook-auth-stage.AbCdEf012' -Sha256 $sha } | Should -Throw '*Unexpected remote upload directory*'
                { Get-WebhookAuthPromoteCommand -UploadDirectory "/tmp/k2s-webhook-auth-stage.AbCdEf0123`n" -Sha256 $sha } | Should -Throw '*Unexpected remote upload directory*'
                { Get-WebhookAuthPromoteCommand -UploadDirectory '/tmp/k2s-webhook-auth-stage.AbCdEf0123' -Sha256 "$sha`n" } | Should -Throw '*Invalid SHA-256*'
            }
        }

        It 'builds remote commands from fixed snippets and quoted words only' {
            InModuleScope $moduleName {
                $id = '20261121T080000Z-0123abcd'
                $sha = 'a' * 64
                $upload = '/tmp/k2s-webhook-auth-stage.AbCdEf0123'
                Get-WebhookAuthStartCommand -RunId $id -Sha256 $sha -Arguments @('renew', '--force') | Should -BeExactly (
                    "sudo -n /bin/sh -c '$($script:PrepareSnippet)' k2s-webhook-auth '$id' '$sha' 'renew' '--force'" +
                    " && sudo -n setsid -f /bin/sh -c '$($script:RunnerSnippet)' k2s-webhook-auth '$id' 'renew' '--force' < /dev/null > /dev/null 2>&1" +
                    " && sudo -n /bin/sh -c '$($script:WaitStartSnippet)' k2s-webhook-auth '$id'")
                Get-WebhookAuthPollCommand -RunId $id -Nonce ('e' * 32) | Should -BeExactly "sudo -n /bin/sh -c '$($script:PollSnippet)' k2s-webhook-auth '$id' '1048576' '$('e' * 32)'"
                Get-WebhookAuthAbandonCommand -RunId $id | Should -BeExactly "sudo -n /bin/sh -c '$($script:AbandonSnippet)' k2s-webhook-auth '$id'"
                { Get-WebhookAuthAbandonCommand -RunId "$id'; reboot; '" } | Should -Throw '*Invalid run id*'
                Get-WebhookAuthPromoteCommand -UploadDirectory $upload -Sha256 $sha | Should -BeExactly "sudo -n /bin/sh -c '$($script:PromoteSnippet)' k2s-webhook-auth '$upload' '$sha'"
                Get-WebhookAuthCleanupCommand -UploadDirectory $upload | Should -BeExactly "rm -rf -- '$upload'"
                foreach ($snippet in @($script:PromoteSnippet, $script:PrepareSnippet, $script:RunnerSnippet, $script:WaitStartSnippet, $script:PollSnippet, $script:AbandonSnippet)) {
                    $snippet.IndexOfAny([char[]]@("'", '"', '`', "`r", "`n", '\')) | Should -Be -1
                }
                foreach ($command in @(
                        (Get-WebhookAuthUploadDirectoryCommand)
                        (Get-WebhookAuthCleanupCommand -UploadDirectory $upload)
                        (Get-WebhookAuthPromoteCommand -UploadDirectory $upload -Sha256 $sha)
                        (Get-WebhookAuthStartCommand -RunId $id -Sha256 $sha -Arguments @('ensure-apiserver'))
                        (Get-WebhookAuthPollCommand -RunId $id -Nonce ('e' * 32))
                        (Get-WebhookAuthAbandonCommand -RunId $id))) {
                    { Assert-WebhookAuthRemoteCommand -RemoteCommand $command } | Should -Not -Throw
                }
                { Assert-WebhookAuthRemoteCommand -RemoteCommand 'echo "x"' } | Should -Throw '*cannot be passed to ssh.exe safely*'
                { Assert-WebhookAuthRemoteCommand -RemoteCommand "echo x`necho y" } | Should -Throw '*cannot be passed to ssh.exe safely*'
                { Assert-WebhookAuthRemoteCommand -RemoteCommand "echo x`r" } | Should -Throw '*cannot be passed to ssh.exe safely*'
                { Assert-WebhookAuthRemoteCommand -RemoteCommand 'echo x\' } | Should -Throw '*cannot be passed to ssh.exe safely*'
            }
        }

        It 'creates remote files and directories private to root' {
            InModuleScope $moduleName {
                foreach ($snippet in @($script:PromoteSnippet, $script:PrepareSnippet, $script:RunnerSnippet, $script:AbandonSnippet)) {
                    $snippet | Should -Match '(\A|; )umask 077; '
                }
                Get-WebhookAuthUploadDirectoryCommand | Should -BeExactly 'umask 077 && mktemp -d /tmp/k2s-webhook-auth-stage.XXXXXXXXXX'
                $all = @($script:PromoteSnippet, $script:PrepareSnippet, $script:RunnerSnippet, $script:WaitStartSnippet, $script:PollSnippet, $script:AbandonSnippet) -join '; '
                $allowed = @(
                    'mkdir -p /var/lib/k2s'
                    'install -d -m 0700 -o root -g root $d'
                    'mktemp $b/bin/.clusterip-webhook-auth.sh.XXXXXXXXXX)'
                    'chmod 0700 $t'
                    'chmod 0700 $x'
                    'mkdir -m 0700 -- $b/runs/$id '
                    'mkdir -m 0700 -- $r '
                )
                $found = @([regex]::Matches($all, '\b(chmod|chown|mkdir|install|mktemp|touch|tee)\b[^;|&]*') | ForEach-Object { $_.Value })
                $found | Should -Not -BeNullOrEmpty
                foreach ($value in $found) {
                    $value | Should -BeIn ($allowed + @('chown root:root $t'))
                }
                # Files created by redirection: only the markers of the claim protocol, the lock and the run files.
                @([regex]::Matches($all, '> ?(\$[^ ;]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ',' |
                    Should -BeExactly '$b/.lock,$d/abandoned,$r/abandoned,$r/alive,$r/exit.tmp,$r/pid.tmp,$r/run.log'
                $script:PromoteSnippet | Should -BeLike (Get-LikeFragment 'mkdir -p /var/lib/k2s; o=$(stat -c %U:%a /var/lib/k2s); case $o in root:?[0145][0145]) ;;')
            }
        }

        It 'serializes staging, the start, the claim and the abandonment of runs with one root-owned lock' {
            InModuleScope $moduleName {
                $lock = 'command exec 9>$b/.lock || { echo K2S-STAGE-ERROR:lock; exit 40; }; flock -w 60 9 || { echo K2S-STAGE-ERROR:lock; exit 40; }; rm -f -- $b/bin/.clusterip-webhook-auth.sh.*'
                $script:PromoteSnippet | Should -BeLike (Get-LikeFragment 'done; if [ -L $b/.lock ] || {')
                $script:PromoteSnippet | Should -BeLike (Get-LikeFragment ('exit 40; fi; ' + $lock))
                $prepare = 'command exec 9>$b/.lock || { echo K2S-RUN-ERROR:lock; exit 48; }; flock -w 60 9 || { echo K2S-RUN-ERROR:lock; exit 48; }; now=$(date +%s); case x$now in'
                $script:PrepareSnippet | Should -BeLike (Get-LikeFragment $prepare)
                # The base directories are checked before the lock file is opened in them.
                foreach ($snippet in @($script:PrepareSnippet, $script:AbandonSnippet)) {
                    $snippet.IndexOf('o=$(stat -c %U:%G:%a $d); [ x$o = xroot:root:700 ]', [System.StringComparison]::Ordinal) |
                        Should -BeLessThan $snippet.IndexOf('command exec 9>', [System.StringComparison]::Ordinal)
                }
                # The run directory is created after the busy scan, while the lock is held.
                $script:PrepareSnippet.IndexOf('mkdir -m 0700 -- $b/runs/$id', [System.StringComparison]::Ordinal) |
                    Should -BeGreaterThan $script:PrepareSnippet.IndexOf('K2S-RUN-BUSY:$r:starting', [System.StringComparison]::Ordinal)
                # The runner claims its run under the lock, refuses an abandoned run, locks the file alive that every
                # process of the run inherits, and releases the lock before the script runs.
                $claim = 'command exec 9>$b/.lock || exit 1; flock -w 60 9 || exit 1; if [ -e $r/abandoned ] || [ -L $r/abandoned ] || [ -e $r/pid ]; then exit 1; fi; ' +
                    'command exec 8>$r/alive || exit 1; flock -n 8 || exit 1; echo $$ > $r/pid.tmp && mv -f $r/pid.tmp $r/pid || exit 1; command exec 9>&-; K2S_WEBHOOK_AUTH_RUN=$id '
                $script:RunnerSnippet | Should -BeLike (Get-LikeFragment $claim)
                @([regex]::Matches($script:RunnerSnippet, 'exec 8') | ForEach-Object { $_.Value }) | Should -HaveCount 1
                $script:RunnerSnippet | Should -Not -BeLike '*8>&-*'
                # A claimed run counts as alive while its file alive is locked: an atomic check, also for children between
                # fork and exec and after the runner ended.
                $script:PollSnippet | Should -BeLike (Get-LikeFragment ('if { [ -f $r/alive ] && [ ! -L $r/alive ] && ! flock -n $r/alive true; } || grep -q -s -z -x -F -- K2S_WEBHOOK_AUTH_RUN=$1 /proc/[0-9]*/environ; then ' +
                        'if grep -q -s -z -x -F -- $1 /proc/$n/cmdline; then st=running:$n; else st=orphaned:$n; fi; elif [ -f $r/exit ]; then st=exited:$(head -c 16 $r/exit); else st=vanished:$n; fi'))
                # The end marker of the log follows only a complete read of the log.
                $script:PollSnippet | Should -BeLike (Get-LikeFragment 'echo K2S-RUN-LOG-BEGIN:$3; if tail -c $2 $r/run.log; then echo; echo K2S-RUN-LOG-END:$3; fi;')
                @([regex]::Matches($script:PollSnippet, 'K2S-RUN-LOG-END')) | Should -HaveCount 1
                $script:PollSnippet | Should -BeLike (Get-LikeFragment 'case x$3 in x|x*[!0-9a-f]*) echo K2S-RUN-ERROR:nonce; exit 43;; esac; [ ${#3} -eq 32 ] || { echo K2S-RUN-ERROR:nonce; exit 43; }')
                # A run is abandoned only under the lock and only while its runner has not claimed it.
                $abandon = 'command exec 9>$b/.lock || { echo K2S-RUN-ABANDON:error:lock; exit 48; }; flock -w 10 9 || { echo K2S-RUN-ABANDON:error:lock; exit 48; }; ' +
                    'if [ -L $r ] || { [ -e $r ] && [ ! -d $r ]; }; then echo K2S-RUN-ABANDON:error:run-directory; exit 47; fi; ' +
                    'if [ -e $r/pid ] || [ -e $r/exit ]; then echo K2S-RUN-ABANDON:claimed; exit 0; fi; ' +
                    'if [ ! -d $r ]; then mkdir -m 0700 -- $r || { echo K2S-RUN-ABANDON:error:run-directory; exit 47; }; fi; ' +
                    'if [ -e $r/abandoned ] || [ -L $r/abandoned ]; then echo K2S-RUN-ABANDON:done; exit 0; fi; ' +
                    ': > $r/abandoned || { echo K2S-RUN-ABANDON:error:marker; exit 49; }; echo K2S-RUN-ABANDON:done'
                $script:AbandonSnippet | Should -BeLike (Get-LikeFragment $abandon)
                $script:PrepareSnippet.IndexOf(': > $d/abandoned', [System.StringComparison]::Ordinal) |
                    Should -BeGreaterThan $script:PrepareSnippet.IndexOf('flock -w 60 9', [System.StringComparison]::Ordinal)
                # Only run directories are considered; a run that is abandoned stays abandoned.
                $script:PrepareSnippet | Should -BeLike (Get-LikeFragment ('r=${d##*/}; case $r in ' + $script:RunIdCase + ') ;; *) continue;; esac; [ -f $d/exit ] && continue; '))
                $script:PollSnippet | Should -BeLike (Get-LikeFragment 'elif [ -e $r/abandoned ] || [ -L $r/abandoned ]; then st=abandoned; else st=starting; fi')
            }
        }

        It 'treats symbolic links in a run directory alike in all steps: never run, never written through' {
            InModuleScope $moduleName {
                # A linked run path: the busy scan skips it, a runner refuses it and the poll reports it as invalid.
                $script:PrepareSnippet | Should -BeLike (Get-LikeFragment 'for d in $b/runs/*; do if [ -L $d ] || [ ! -d $d ]; then continue; fi;')
                $script:RunnerSnippet | Should -BeLike (Get-LikeFragment 'shift; if [ -L $r ] || [ ! -d $r ]; then exit 1; fi; if [ -L $b/.lock ]')
                $script:PollSnippet | Should -BeLike (Get-LikeFragment ('r=/var/lib/k2s/webhook-auth/runs/$1; if [ -L $r ] || { [ -e $r ] && [ ! -d $r ]; }; then echo K2S-RUN-STATE:invalid-directory; exit 0; fi; ' +
                        'if [ ! -d $r ]; then echo K2S-RUN-STATE:missing; exit 0; fi;'))
                $script:AbandonSnippet | Should -BeLike (Get-LikeFragment 'if [ -L $r ] || { [ -e $r ] && [ ! -d $r ]; }; then echo K2S-RUN-ABANDON:error:run-directory; exit 47; fi;')
                # An abandoned marker in any form, also a dangling symbolic link, means abandoned everywhere and is never
                # written through.
                $script:PrepareSnippet | Should -BeLike (Get-LikeFragment 'elif [ ! -e $d/abandoned ] && [ ! -L $d/abandoned ]; then')
                $script:RunnerSnippet | Should -BeLike (Get-LikeFragment 'if [ -e $r/abandoned ] || [ -L $r/abandoned ] || [ -e $r/pid ]; then exit 1; fi;')
                $script:PollSnippet | Should -BeLike (Get-LikeFragment 'elif [ -e $r/abandoned ] || [ -L $r/abandoned ]; then st=abandoned;')
                $script:AbandonSnippet.IndexOf('if [ -e $r/abandoned ] || [ -L $r/abandoned ]; then echo K2S-RUN-ABANDON:done; exit 0; fi', [System.StringComparison]::Ordinal) |
                    Should -BeLessThan $script:AbandonSnippet.IndexOf(': > $r/abandoned', [System.StringComparison]::Ordinal)
                (ConvertFrom-WebhookAuthRunState -Output @('K2S-RUN-STATE:invalid-directory') -Nonce ('a' * 32)).State | Should -BeExactly 'invalid-directory'
            }
        }

        It 'opens the lock file only after refusing one that another user could have planted' {
            InModuleScope $moduleName {
                $test = 'if [ -L $b/.lock ] || { [ -e $b/.lock ] && { [ ! -f $b/.lock ] || ! [ x$(stat -c %u:%g:%h $b/.lock) = x0:0:1 ]; }; }; then'
                $expected = [ordered]@{
                    PromoteSnippet = ' echo K2S-STAGE-ERROR:lock-file; exit 40; fi; command exec 9>$b/.lock || { echo K2S-STAGE-ERROR:lock; exit 40; }'
                    PrepareSnippet = ' echo K2S-RUN-ERROR:lock-file; exit 48; fi; command exec 9>$b/.lock || { echo K2S-RUN-ERROR:lock; exit 48; }'
                    RunnerSnippet  = ' exit 1; fi; command exec 9>$b/.lock || exit 1'
                    AbandonSnippet = ' echo K2S-RUN-ABANDON:error:lock-file; exit 48; fi; command exec 9>$b/.lock || { echo K2S-RUN-ABANDON:error:lock; exit 48; }'
                }
                foreach ($name in $expected.Keys) {
                    $snippet = (Get-Variable -Name $name -Scope Script).Value
                    $snippet | Should -BeLike (Get-LikeFragment ($test + $expected[$name])) -Because $name
                    @([regex]::Matches($snippet, '9>\$b/\.lock')) | Should -HaveCount 1 -Because $name
                }
                foreach ($snippet in @($script:WaitStartSnippet, $script:PollSnippet)) { $snippet | Should -Not -BeLike '*.lock*' }
            }
        }

        It 'ignores symbolic links in the busy scan and tests only a regular file alive, without creating it' {
            InModuleScope $moduleName {
                $script:PrepareSnippet | Should -BeLike (Get-LikeFragment 'for d in $b/runs/*; do if [ -L $d ] || [ ! -d $d ]; then continue; fi; r=${d##*/};')
                $script:PrepareSnippet | Should -BeLike (Get-LikeFragment 'elif [ ! -e $d/abandoned ] && [ ! -L $d/abandoned ]; then')
                $script:PrepareSnippet | Should -BeLike (Get-LikeFragment 'if { [ -f $d/alive ] && [ ! -L $d/alive ] && ! flock -n $d/alive true; } || grep')
                $script:PollSnippet | Should -BeLike (Get-LikeFragment 'if { [ -f $r/alive ] && [ ! -L $r/alive ] && ! flock -n $r/alive true; } || grep')
                foreach ($snippet in @($script:PrepareSnippet, $script:PollSnippet)) {
                    # Every lock test on alive is guarded: a regular file only, never a symbolic link or FIFO, never created.
                    $tests = @([regex]::Matches($snippet, 'flock -n \$([dr])/alive'))
                    $tests.Count | Should -BeGreaterThan 0
                    foreach ($test in $tests) {
                        $x = $test.Groups[1].Value
                        $guard = "[ -f `$$x/alive ] && [ ! -L `$$x/alive ] && ! "
                        $test.Index | Should -BeGreaterOrEqual $guard.Length
                        $snippet.Substring($test.Index - $guard.Length, $guard.Length) | Should -BeExactly $guard
                    }
                }
                @([regex]::Matches($script:PrepareSnippet, 'flock -n \$d/alive')) | Should -HaveCount 2
                @([regex]::Matches($script:PollSnippet, 'flock -n \$r/alive')) | Should -HaveCount 1
            }
        }

        It 'runs a verified copy of the script in the run directory, never the shared staged file' {
            InModuleScope $moduleName {
                $copy = 'mkdir -m 0700 -- $b/runs/$id || { echo K2S-RUN-ERROR:run-directory; exit 47; }; ' +
                    'if [ -L $p ] || [ ! -f $p ] || ! cp -- $p $x; then rm -rf -- $b/runs/$id; echo K2S-RUN-ERROR:script-missing; exit 44; fi; ' +
                    's=$(sha256sum < $x); s=${s%% *}; [ x$s = x$h ] || { rm -rf -- $b/runs/$id; echo K2S-RUN-ERROR:script-checksum; exit 45; }; ' +
                    'chmod 0700 $x; echo K2S-RUN-PREPARED:$id'
                $script:PrepareSnippet | Should -BeLike (Get-LikeFragment $copy)
                $script:PrepareSnippet | Should -BeLike (Get-LikeFragment 'x=$b/runs/$id/clusterip-webhook-auth.sh')
                $script:RunnerSnippet | Should -BeLike (Get-LikeFragment 'K2S_WEBHOOK_AUTH_RUN=$id $r/clusterip-webhook-auth.sh $* < /dev/null > $r/run.log 2>&1')
                $script:RunnerSnippet | Should -Not -BeLike '*/bin/clusterip-webhook-auth.sh*'
            }
        }

        It 'removes only finished runs older than 30 days, under the lock, file by file and never through a symbolic link' {
            InModuleScope $moduleName {
                $script:RunRetentionSeconds | Should -Be 2592000
                $prepare = $script:PrepareSnippet
                $retention = 'for d in $b/runs/*; do if [ -L $d ] || [ ! -d $d ]; then continue; fi; r=${d##*/}; case $r in ' + $script:RunIdCase + ') ;; *) continue;; esac; ' +
                    'if [ -f $d/exit ] && [ ! -L $d/exit ] && [ -f $d/pid ] && [ ! -L $d/pid ] && [ ! -e $d/abandoned ] && [ ! -L $d/abandoned ]; then v=$(head -c 16 $d/exit); case x$v in x|x*[!0-9]*) continue;; esac; f=$d/exit; ' +
                    'elif [ -f $d/abandoned ] && [ ! -L $d/abandoned ] && [ ! -e $d/pid ] && [ ! -L $d/pid ] && [ ! -e $d/exit ] && [ ! -L $d/exit ]; then f=$d/abandoned; else continue; fi; ' +
                    'm=$(stat -c %Y $f); case x$m in x|x*[!0-9]*) continue;; esac; [ $((now - m)) -gt 2592000 ] || continue; ' +
                    'if { [ -f $d/alive ] && [ ! -L $d/alive ] && ! flock -n $d/alive true; } || grep -q -s -z -x -F -- K2S_WEBHOOK_AUTH_RUN=$r /proc/[0-9]*/environ; then continue; fi; ' +
                    'k=0; for e in $d/* $d/.[!.]* $d/..?*; do if [ ! -e $e ] && [ ! -L $e ]; then continue; fi; case ${e##*/} in clusterip-webhook-auth.sh|pid|alive|run.log|exit|abandoned) if [ -L $e ] || [ ! -f $e ]; then k=1; fi;; *) k=1;; esac; done; ' +
                    'if [ $k -eq 0 ] && rm -f -- $d/clusterip-webhook-auth.sh $d/run.log $d/alive && rm -f -- $d/pid $d/exit $d/abandoned && rmdir -- $d; then echo K2S-RUN-REMOVED:$r; else echo K2S-RUN-KEPT:$r; fi; done; '
                $prepare | Should -BeLike (Get-LikeFragment $retention)
                # After the busy scan, under the lock, before the directory of the new run is created.
                $index = $prepare.IndexOf($retention, [System.StringComparison]::Ordinal)
                $index | Should -BeGreaterThan $prepare.IndexOf('flock -w 60 9', [System.StringComparison]::Ordinal)
                $index | Should -BeGreaterThan $prepare.IndexOf('K2S-RUN-BUSY:$r:starting', [System.StringComparison]::Ordinal)
                $index | Should -BeLessThan $prepare.IndexOf('mkdir -m 0700 -- $b/runs/$id', [System.StringComparison]::Ordinal)
                # Recursive removal only of the upload directory and of the new run directory, both validated.
                $all = @($script:PromoteSnippet, $prepare, $script:RunnerSnippet, $script:WaitStartSnippet, $script:PollSnippet, $script:AbandonSnippet) -join '; '
                (@([regex]::Matches($all, 'rm -[a-z]*r[a-z]* -- ([^\s;]+)') | ForEach-Object { $_.Groups[1].Value }) -join ',') | Should -BeExactly '$u,$b/runs/$id,$b/runs/$id'
                @([regex]::Matches($all, '\brmdir\b[^;]*') | ForEach-Object { $_.Value }) -join ',' | Should -BeExactly 'rmdir -- $d'
            }
        }

        It 'logs removed run directories and every run directory kept for inspection' {
            InModuleScope $moduleName {
                $script:startAnswers.Enqueue({
                        param($RunId)
                        New-FakeAnswer -Output @('K2S-RUN-REMOVED:20261001T080000Z-0000aaaa', 'K2S-RUN-REMOVED:20261002T080000Z-0000bbbb', 'K2S-RUN-KEPT:20261003T080000Z-0000cccc',
                            'K2S-RUN-KEPT:../x', 'K2S-RUN-REMOVED:x', "K2S-RUN-PREPARED:$RunId", 'K2S-RUN-STARTED:4242')
                    })
                Add-PollAnswer (New-PollAnswer exited:0 -Log @('K2S-WEBHOOK-AUTH-OK:verify'))
                $result = Invoke-ClusterIPWebhookAuth -Command verify -InstallationPath $script:installation
                $result.Status | Should -BeExactly 'Succeeded'
                @($script:logs | Where-Object { $_ -ceq '[WebhookAuth] Removed 2 run directories of runs that ended more than 30 days ago' }) | Should -HaveCount 1
                @($script:logs | Where-Object { $_ -clike '*Kept the run directory*' }) | Should -HaveCount 1
                @($script:logs | Where-Object { $_ -clike '*Kept the run directory /var/lib/k2s/webhook-auth/runs/20261003T080000Z-0000cccc for inspection*' }) | Should -HaveCount 1
            }
        }

        It 'starts a run with one SSH call that prepares the run, starts its runner and waits for its PID' {
            InModuleScope $moduleName {
                $id = '20261121T080000Z-0123abcd'
                $sha = 'a' * 64
                $arguments = @('renew', '--force')
                Get-WebhookAuthStartCommand -RunId $id -Sha256 $sha -Arguments $arguments | Should -BeExactly ((Get-WebhookAuthPrepareCommand -RunId $id -Sha256 $sha -Arguments $arguments) +
                    ' && ' + (Get-WebhookAuthRunnerCommand -RunId $id -Arguments $arguments) + ' && ' + (Get-WebhookAuthWaitStartCommand -RunId $id))
                Get-WebhookAuthWaitStartCommand -RunId $id | Should -BeExactly "sudo -n /bin/sh -c '$($script:WaitStartSnippet)' k2s-webhook-auth '$id'"
                { Get-WebhookAuthPrepareCommand -RunId '../x' -Sha256 $sha -Arguments @('verify') } | Should -Throw
                { Get-WebhookAuthPrepareCommand -RunId $id -Sha256 'x' -Arguments @('verify') } | Should -Throw
                { Get-WebhookAuthRunnerCommand -RunId $id -Arguments @('verify; id') } | Should -Throw
                { Get-WebhookAuthRunnerCommand -RunId "$id'" -Arguments @('verify') } | Should -Throw
                { Get-WebhookAuthWaitStartCommand -RunId '20261121T080000Z-0123ABCD' } | Should -Throw
            }
        }
    }

    # --- transport ---

    Describe 'Native process boundary' -Tag 'unit', 'ci', 'webhook-auth' {
        It 'quotes <Name>' -TestCases @(
            @{ Name = 'a plain argument as is'; Arguments = @('-T'); Expected = '-T' }
            @{ Name = 'an argument with spaces'; Arguments = @('a b'); Expected = '"a b"' }
            @{ Name = 'an empty argument'; Arguments = @(''); Expected = '""' }
            @{ Name = 'a path with spaces'; Arguments = @('-i', 'C:\Users\Jane Doe\.ssh\k2s\id_rsa'); Expected = '-i "C:\Users\Jane Doe\.ssh\k2s\id_rsa"' }
            @{ Name = 'a trailing backslash without spaces as is'; Arguments = @('C:\k\'); Expected = 'C:\k\' }
        ) {
            param($Arguments, $Expected)
            InModuleScope $moduleName -Parameters @{ Arguments = $Arguments; Expected = $Expected } {
                param($Arguments, $Expected)
                Join-WebhookAuthProcessArgument -ArgumentList $Arguments | Should -BeExactly $Expected
            }
        }

        It 'refuses an argument that it cannot quote safely (<Value>)' -TestCases @(
            @{ Value = 'a"b' }
            @{ Value = 'a "b"' }
            @{ Value = 'C:\Jane Doe\' }
        ) {
            param($Value)
            InModuleScope $moduleName -Parameters @{ Value = $Value } {
                param($Value)
                { Join-WebhookAuthProcessArgument -ArgumentList @('-o', $Value) } | Should -Throw '*Internal error*' -Because "'$Value' cannot be quoted"
            }
        }

        It 'passes every argument unchanged to the argument parser of ssh.exe and scp.exe' {
            InModuleScope $moduleName {
                if (-not ('K2sWebhookAuthTest.NativeMethods' -as [type])) {
                    Add-Type -Namespace K2sWebhookAuthTest -Name NativeMethods -MemberDefinition '
                        [DllImport("shell32.dll", SetLastError = true)]
                        public static extern System.IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string commandLine, out int count);
                        [DllImport("kernel32.dll")]
                        public static extern System.IntPtr LocalFree(System.IntPtr memory);'
                }
                $connection = [pscustomobject]@{ User = 'remote@172.19.1.100'; Key = 'C:\Users\Jane Doe\.ssh\k2s\id_rsa'; Ssh = 'ssh.exe'; Scp = 'scp.exe' }
                $id = '20261121T080000Z-0123abcd'
                $sha = 'a' * 64
                $upload = '/tmp/k2s-webhook-auth-stage.AbCdEf0123'
                $remoteCommands = @(
                    (Get-WebhookAuthUploadDirectoryCommand)
                    (Get-WebhookAuthPromoteCommand -UploadDirectory $upload -Sha256 $sha)
                    (Get-WebhookAuthCleanupCommand -UploadDirectory $upload)
                    (Get-WebhookAuthStartCommand -RunId $id -Sha256 $sha -Arguments @('renew', '--force'))
                    (Get-WebhookAuthPollCommand -RunId $id -Nonce ('e' * 32))
                    (Get-WebhookAuthAbandonCommand -RunId $id)
                )
                $argumentLists = @($remoteCommands | ForEach-Object { , (@('-n', '-T') + (Get-WebhookAuthSshOptionList -Connection $connection) + @($connection.User, $_)) })
                $argumentLists += , ((Get-WebhookAuthSshOptionList -Connection $connection) + @('C:\Users\Jane Doe\AppData\Local\Temp\k2s-webhook-auth-0\clusterip-webhook-auth.sh', "remote@172.19.1.100:$upload/clusterip-webhook-auth.sh"))
                foreach ($arguments in $argumentLists) {
                    $count = 0
                    $pointer = [K2sWebhookAuthTest.NativeMethods]::CommandLineToArgvW('ssh.exe ' + (Join-WebhookAuthProcessArgument -ArgumentList $arguments), [ref]$count)
                    try {
                        $parsed = @(for ($i = 1; $i -lt $count; $i++) {
                                [System.Runtime.InteropServices.Marshal]::PtrToStringUni([System.Runtime.InteropServices.Marshal]::ReadIntPtr($pointer, $i * [System.IntPtr]::Size))
                            })
                    }
                    finally {
                        $null = [K2sWebhookAuthTest.NativeMethods]::LocalFree($pointer)
                    }
                    $parsed.Count | Should -Be $arguments.Count
                    for ($i = 0; $i -lt $arguments.Count; $i++) {
                        $parsed[$i] | Should -BeExactly $arguments[$i]
                    }
                }
            }
        }

        It 'returns exit code, output and error output of the program without SSH socket noise' {
            InModuleScope $moduleName {
                $invoke = (Get-Command Invoke-WebhookAuthProcess -CommandType Function).ScriptBlock
                $result = & $invoke -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList @('/d', '/c', 'echo K2S-ONE& echo.& echo K2S-TWO& echo problem 1>&2& echo close - IO is still pending on closed socket. read:0, write:0 1>&2& exit /b 3')
                $result.ExitCode | Should -Be 3
                ($result.Output -join '|') | Should -BeExactly 'K2S-ONE||K2S-TWO'
                $result.Errors.Count | Should -Be 1
                $result.Errors[0].Trim() | Should -BeExactly 'problem'
            }
        }

        It 'stops a program that does not finish within its time limit and reports no exit code' {
            InModuleScope $moduleName {
                $invoke = (Get-Command Invoke-WebhookAuthProcess -CommandType Function).ScriptBlock
                # A loopback address of its own identifies this ping process, also when other tests run at the same time.
                $target = '127.{0}.{1}.{2}' -f (Get-Random -Minimum 1 -Maximum 255), (Get-Random -Minimum 1 -Maximum 255), (Get-Random -Minimum 1 -Maximum 255)
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                $result = & $invoke -FilePath "$env:SystemRoot\System32\PING.EXE" -ArgumentList @('-n', '60', $target) -TimeoutSeconds 1
                $watch.Stop()
                $watch.Elapsed.TotalSeconds | Should -BeLessThan 20
                $result.ExitCode | Should -BeNullOrEmpty
                $result.Errors[-1] | Should -BeExactly 'PING.EXE did not finish within 1 seconds and was stopped'
                @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'PING.EXE'" | Where-Object { $_.CommandLine -like "* $target*" }) | Should -HaveCount 0
            }
        }

        It 'runs ssh.exe and scp.exe only through the time-limited process boundary' {
            $source = Get-Content -LiteralPath "$PSScriptRoot\clusterip-webhook-auth.module.psm1" -Raw
            ([regex]::Matches($source, 'Invoke-WebhookAuthProcess -FilePath \$Connection\.(Ssh|Scp) ')).Count | Should -Be 2
            ([regex]::Matches($source, 'Invoke-WebhookAuthProcess -')).Count | Should -Be 2
            $source | Should -Not -Match '&\s*\$(Connection|FilePath)|Start-Process -FilePath \$Connection'
            $source | Should -Match '\$script:ProcessTimeoutSeconds = 120\r?\n'
        }

        It 'limits a call to the remaining observation time (<Remaining> s gives <Expected> s)' -TestCases @(
            @{ Remaining = 600; Expected = 120 }
            @{ Remaining = 120; Expected = 120 }
            @{ Remaining = 60.2; Expected = 61 }
            @{ Remaining = 5; Expected = 5 }
            @{ Remaining = 0.3; Expected = 1 }
        ) {
            param($Remaining, $Expected)
            InModuleScope $moduleName -Parameters @{ Remaining = $Remaining; Expected = $Expected } {
                param($Remaining, $Expected)
                Get-WebhookAuthCallTimeout -RemainingSeconds $Remaining | Should -Be $Expected
            }
        }

        It 'reads the answer of AbandonSnippet (<Name>)' -TestCases @(
            @{ Name = 'abandoned'; Answer = @{ Output = @('K2S-RUN-ABANDON:done') }; State = 'Revoked'; Detail = '' }
            @{ Name = 'claimed'; Answer = @{ Output = @('K2S-RUN-ABANDON:claimed') }; State = 'Claimed'; Detail = '' }
            @{ Name = 'refused'; Answer = @{ ExitCode = 49; Output = @('K2S-RUN-ABANDON:error:marker') }; State = 'Unknown'; Detail = '*cannot mark the run as abandoned (marker)' }
            @{ Name = 'no answer'; Answer = @{ ExitCode = 255; Errors = @('Connection closed by 172.19.1.100 port 22') }; State = 'Unknown'; Detail = '*Cannot mark the remote run as abandoned (ssh exit code 255)*' }
            @{ Name = 'answer in error output only'; Answer = @{ ExitCode = 0; Errors = @('K2S-RUN-ABANDON:done') }; State = 'Unknown'; Detail = '*Cannot mark the remote run as abandoned*' }
            @{ Name = 'answer not alone on its line'; Answer = @{ Output = @('x K2S-RUN-ABANDON:done') }; State = 'Unknown'; Detail = '*Cannot mark the remote run as abandoned*' }
        ) {
            param($Answer, $State, $Detail)
            InModuleScope $moduleName -Parameters @{ Answer = $Answer; State = $State; Detail = $Detail } {
                param($Answer, $State, $Detail)
                $script:abandonAnswers.Enqueue((New-FakeAnswer @Answer))
                $connection = [pscustomobject]@{ User = 'remote@172.19.1.100'; Key = 'C:\fixture\.ssh\k2s\id_rsa'; Ssh = 'ssh.exe'; Scp = 'scp.exe' }
                $revoke = Revoke-WebhookAuthRunStart -Connection $connection -RunId '20261121T080000Z-0123abcd' -TimeoutSeconds 42
                $revoke.State | Should -BeExactly $State
                $revoke.Detail | Should -BeLike $Detail
                (Get-FakeCall abandon)[0].TimeoutSeconds | Should -Be 42
            }
        }
    }
}
