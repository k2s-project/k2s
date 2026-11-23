# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Helper of test/clusterip-webhook-auth-remote.sh. Loads the definitions of clusterip-webhook-auth.module.psm1 (its
# $script: assignments and functions, without importing the modules it depends on) and either prints the remote commands
# that the module sends over SSH, built by its own functions for placeholder values (-Mode Commands), or classifies
# recorded answers of the poll command with the module's own parser and outcome mapping (-Mode Classify).
param(
    [Parameter(Mandatory = $true)][ValidateSet('Commands', 'Classify')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$ModulePath,
    [Parameter(Mandatory = $false)][string]$CasesPath
)
$ErrorActionPreference = 'Stop'

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ModulePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "cannot parse '$ModulePath': $($errors[0].Message)" }
$definitions = foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $statement.Extent.Text }
    elseif ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and $statement.Left.Extent.Text -clike '$script:*') { $statement.Extent.Text }
}
$module = New-Module -Name 'clusterip-webhook-auth-remote-test' -ScriptBlock ([scriptblock]::Create(($definitions -join "`n") + "`nfunction Write-Log { }"))

function ConvertTo-Base64 {
    param([AllowEmptyString()][string]$Text)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}

if ($Mode -ceq 'Commands') {
    # Placeholders that test/clusterip-webhook-auth-remote.sh replaces with real values: run id, SHA-256, upload
    # directory and nonce, each valid for the checks of the module.
    $commands = & $module {
        $id = '20000101T000000Z-0000aaaa'
        $sha = '0' * 64
        $upload = '/tmp/k2s-webhook-auth-stage.AAAAAAAAAA'
        [ordered]@{
            upload               = Get-WebhookAuthUploadDirectoryCommand
            promote              = Get-WebhookAuthPromoteCommand -UploadDirectory $upload -Sha256 $sha
            cleanup              = Get-WebhookAuthCleanupCommand -UploadDirectory $upload
            'start-verify'       = Get-WebhookAuthStartCommand -RunId $id -Sha256 $sha -Arguments @('verify')
            'start-renew-force'  = Get-WebhookAuthStartCommand -RunId $id -Sha256 $sha -Arguments @('renew', '--force')
            'prepare-verify'     = Get-WebhookAuthPrepareCommand -RunId $id -Sha256 $sha -Arguments @('verify')
            'runner-verify'      = Get-WebhookAuthRunnerCommand -RunId $id -Arguments @('verify')
            waitstart            = Get-WebhookAuthWaitStartCommand -RunId $id
            poll                 = Get-WebhookAuthPollCommand -RunId $id -Nonce ('f' * 32)
            abandon              = Get-WebhookAuthAbandonCommand -RunId $id
        }
    }
    foreach ($name in $commands.Keys) {
        & $module { param($Command) Assert-WebhookAuthRemoteCommand -RemoteCommand $Command } $commands[$name]
        "$name`t$(ConvertTo-Base64 $commands[$name])"
    }
    "log-limit`t$(ConvertTo-Base64 ([string](& $module { $script:LogLimitBytes })))"
    return
}

# Classify: every line of the cases file is <name> TAB <arguments> TAB <nonce> TAB <base64 of the poll answer>. The answer
# is read like the output of ssh.exe (Read-WebhookAuthProcessOutput). Prints <name> TAB <state>|<exit status>|<log
# complete>|<status>|<reason>|<marker found>|<log lines>, with status, reason and marker '-' for a state that the module
# does not treat as final.
$answerFile = [System.IO.Path]::GetTempFileName()
try {
    foreach ($line in [System.IO.File]::ReadAllLines($CasesPath)) {
        if (-not $line) { continue }
        $name, $arguments, $nonce, $answer = $line.Split("`t")
        [System.IO.File]::WriteAllBytes($answerFile, [Convert]::FromBase64String($answer))
        $summary = & $module {
            param($Arguments, $Nonce, $AnswerFile)
            $state = ConvertFrom-WebhookAuthRunState -Output (Read-WebhookAuthProcessOutput -Path $AnswerFile) -Nonce $Nonce
            $status = '-'
            $reason = '-'
            $marker = '-'
            if ($state.State -in @('exited', 'vanished', 'abandoned', 'invalid-pid', 'invalid-directory', 'invalid-state')) {
                $result = New-WebhookAuthResult -Arguments ($Arguments -split ' ') -Attempt 1
                $result.RunId = '20000101T000000Z-0000aaaa'
                $result.RunDirectory = '/var/lib/k2s/webhook-auth/runs/20000101T000000Z-0000aaaa'
                $result = Complete-WebhookAuthRun -Result $result -Start ([pscustomobject]@{ RemotePid = $null }) -Wait ([pscustomobject]@{ Final = $true; State = $state; LastProblem = '' })
                $status = $result.Status
                $reason = $result.Reason
                $marker = $result.MarkerFound
            }
            '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $state.State, $state.ExitCode, $state.LogComplete, $status, $reason, $marker, @($state.Log).Count
        } $arguments $nonce $answerFile
        "$name`t$summary"
    }
}
finally {
    Remove-Item -LiteralPath $answerFile -Force -ErrorAction SilentlyContinue
}
