# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Stages scripts/clusterip-webhook-auth.sh of the K2s installation on the Linux control-plane node and runs its
# commands there, detached from the SSH connection, so that a lost connection neither ends nor duplicates a run.
#
# Remote layout, owned by root with mode 0700:
#   /var/lib/k2s/webhook-auth/bin/clusterip-webhook-auth.sh   staged script (LF line endings, SHA-256 verified)
#   /var/lib/k2s/webhook-auth/runs/<run id>/                   verified copy of the script that the run executes,
#                                                              pid, alive, run.log (script output), exit (written
#                                                              last), or abandoned for a run that must never start;
#                                                              removed 30 days after the run ended (see PrepareSnippet)
#   /var/lib/k2s/webhook-auth/.lock                            serializes staging, the start of runs, the claim of a
#                                                              run by its runner and the abandonment of a run
# Nothing of this layout is repaired or adopted, because another user may have written into a directory with other
# permissions: an existing directory is used only if it is owned by root with mode 0700, and the lock file only if it is a
# regular root-owned file with one link. Symbolic links in the runs directory are never followed for a decision or a
# write: the busy scan ignores them, a runner refuses a linked run directory and an abandoned marker in any form, the
# poll reports a linked run directory as invalid, and an existing marker is never written again.
#
# A run is claimed by its runner (PID written) or abandoned, never both: both happen under the lock, and the runner
# refuses an abandoned run. Only a claimed run executes the script, so a run that is abandoned never starts, however
# late its runner is. Before claiming, the runner locks the file alive; every process of the run inherits that open
# file, so the lock is held until the last process of the run has ended. A claimed run without exit file is therefore
# alive exactly while that lock is held, also if its runner was killed or a child is between fork and exec.
#
# SSH reads no configuration file (-F none), so no ProxyCommand, Match exec or similar setting of the Windows account
# can run a local command, and verifies the control-plane host key against the known_hosts files of the account
# (StrictHostKeyChecking=yes). The generic SSH and SCP helpers of vm.module are not used: they disable that check.
# Remote steps report their outcome with K2S-* marker lines; the exit code of ssh.exe alone is never trusted
# (Windows OpenSSH can report an error for a command that succeeded, and a lost connection says nothing about
# the remote process).

$infraModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$vmModule = "$PSScriptRoot\..\vm\vm.module.psm1"
Import-Module $infraModule, $vmModule

$script:ScriptRelativePath = 'lib\modules\windows\node\k2s.node.module\linuxnode\distros\scripts\clusterip-webhook-auth.sh'
$script:RemoteScriptPath = '/var/lib/k2s/webhook-auth/bin/clusterip-webhook-auth.sh'
$script:RemoteRunsDirectory = '/var/lib/k2s/webhook-auth/runs'
$script:PollIntervalSeconds = 5
# Limit for one ssh.exe or scp.exe call; the local ssh.exe is stopped when it passes, the remote run is not affected.
$script:ProcessTimeoutSeconds = 120
# A run that its runner has not claimed after this time is abandoned on the node, which proves that it never starts.
$script:StartGraceSeconds = 120
$script:LogLimitBytes = 1048576
$script:LogTailLines = 20
$script:RunIdPattern = '\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z'
$script:UploadDirectoryPattern = '\A/tmp/k2s-webhook-auth-stage\.[A-Za-z0-9]{10}\z'
$script:Sha256Pattern = '\A[0-9a-f]{64}\z'
# Random value of each poll that frames the log in its answer, so that log content cannot end the frame.
$script:NoncePattern = '\A[0-9a-f]{32}\z'
$script:LockMessage = 'another clusterip-webhook-auth.sh run holds the lock'
# ensure-apiserver logs the backup of the kube-apiserver manifest just before replacing it.
$script:ManifestSwapPattern = "\] backed up '[^']*/kube-apiserver\.yaml'|\] updated '[^']*/kube-apiserver\.yaml'|restoring the previous manifest"
# renew logs these lines after installing a new client certificate and after verifying webhook authentication with it
# (contract with clusterip-webhook-auth.sh, pinned by test/clusterip-webhook-auth.output.txt).
$script:RenewedPattern = "\A\[ClusterIPWebhookAuth\] renewed kube-apiserver client certificate '[^']*/client\.crt'\z"
$script:RenewedVerifiedLine = '[ClusterIPWebhookAuth] webhook authentication works with the renewed client certificate'
$script:WarningPattern = '\A\[ClusterIPWebhookAuth\] WARNING: '

# Remote shell snippets. They run as root (sudo -n /bin/sh -c '<snippet>' <name> <arguments>), receive all variable
# data as single-quoted positional arguments and contain no quote characters, so no value becomes shell code.
$script:RunIdCase = ('[0-9]' * 8) + 'T' + ('[0-9]' * 6) + 'Z-' + ('[0-9a-f]' * 8)
$script:UploadDirectoryCase = '/tmp/k2s-webhook-auth-stage.' + ('[A-Za-z0-9]' * 10)
# Run directories are removed this long after the run ended or was abandoned (30 days).
$script:RunRetentionSeconds = 30 * 86400
# Start of a test that refuses the lock file unless it is missing or a regular file of root (uid and gid 0) with one
# link: root opens it for writing, which would follow a symbolic link and truncate its target. Any error refuses.
$script:LockFileTest = 'if [ -L $b/.lock ] || { [ -e $b/.lock ] && { [ ! -f $b/.lock ] || ! [ x$(stat -c %u:%g:%h $b/.lock) = x0:0:1 ]; }; }; then'

# $1 upload directory, $2 expected SHA-256. Verifies the upload, installs it as a non-executable temporary file next
# to the target, verifies it again and only then makes it executable and renames it atomically into place. Creates the
# missing directories of the layout and refuses existing ones that are not owned by root with mode 0700.
$script:PromoteSnippet = @(
    'set -eu'
    'umask 077'
    'u=$1'
    'h=$2'
    ('case $u in ' + $script:UploadDirectoryCase + ') ;; *) echo K2S-STAGE-ERROR:upload-directory; exit 31;; esac')
    'cleanup() { rm -rf -- $u; }'
    'trap cleanup EXIT'
    'case x$h in x|x*[!0-9a-f]*) echo K2S-STAGE-ERROR:checksum-format; exit 32;; esac'
    '[ ${#h} -eq 64 ] || { echo K2S-STAGE-ERROR:checksum-format; exit 32; }'
    'f=$u/clusterip-webhook-auth.sh'
    'if [ -L $f ] || [ ! -f $f ]; then echo K2S-STAGE-ERROR:upload-missing; exit 33; fi'
    's=$(sha256sum < $f)'
    's=${s%% *}'
    '[ x$s = x$h ] || { echo K2S-STAGE-ERROR:upload-checksum:$s; exit 34; }'
    'mkdir -p /var/lib/k2s'
    'o=$(stat -c %U:%a /var/lib/k2s)'
    'case $o in root:?[0145][0145]) ;; *) echo K2S-STAGE-ERROR:insecure-parent:$o; exit 35;; esac'
    'b=/var/lib/k2s/webhook-auth'
    'for d in $b $b/bin $b/runs; do if [ -L $d ] || { [ -e $d ] && [ ! -d $d ]; }; then echo K2S-STAGE-ERROR:not-a-directory:$d; exit 36; fi; [ -d $d ] || install -d -m 0700 -o root -g root $d; o=$(stat -c %U:%G:%a $d); [ x$o = xroot:root:700 ] || { echo K2S-STAGE-ERROR:directory-permissions:$d:$o; exit 37; }; done'
    ($script:LockFileTest + ' echo K2S-STAGE-ERROR:lock-file; exit 40; fi')
    'command exec 9>$b/.lock || { echo K2S-STAGE-ERROR:lock; exit 40; }'
    'flock -w 60 9 || { echo K2S-STAGE-ERROR:lock; exit 40; }'
    'rm -f -- $b/bin/.clusterip-webhook-auth.sh.*'
    't=$(mktemp $b/bin/.clusterip-webhook-auth.sh.XXXXXXXXXX)'
    'cp -- $f $t'
    's=$(sha256sum < $t)'
    's=${s%% *}'
    '[ x$s = x$h ] || { rm -f -- $t; echo K2S-STAGE-ERROR:temporary-checksum:$s; exit 38; }'
    'chown root:root $t'
    'chmod 0700 $t'
    'mv -f -- $t $b/bin/clusterip-webhook-auth.sh'
    's=$(sha256sum < $b/bin/clusterip-webhook-auth.sh)'
    's=${s%% *}'
    'o=$(stat -c %U:%G:%a $b/bin/clusterip-webhook-auth.sh)'
    'if [ x$s != x$h ] || [ x$o != xroot:root:700 ]; then rm -f -- $b/bin/clusterip-webhook-auth.sh; echo K2S-STAGE-ERROR:final:$s:$o; exit 39; fi'
    'echo K2S-STAGE-OK:$h'
) -join '; '

# $1 run id, $2 expected SHA-256 of the staged script, $3... script arguments. Under the lock that also serializes
# staging: refuses to start while another run is active (its runner or a process of its script is alive, or it was
# prepared less than 120 s ago and its runner has not claimed it yet), marks older unclaimed runs as abandoned so that
# their runners refuse to start, removes old finished runs (see below), then creates the private run directory with a
# verified copy of the staged script, which is what the run executes, so that a later staging cannot change it.
# Retention: a run directory is removed only if the run ended (pid and a numeric exit status) or was abandoned (marker
# only) more than RunRetentionSeconds ago, no process of the run is alive, and it contains nothing but the regular files
# that a run creates; the files are removed by name and the directory with rmdir. Anything else is kept for inspection.
$script:PrepareSnippet = @(
    'umask 077'
    'id=$1'
    'h=$2'
    'shift 2'
    ('case $id in ' + $script:RunIdCase + ') ;; *) echo K2S-RUN-ERROR:run-id; exit 41;; esac')
    'case x$h in x|x*[!0-9a-f]*) echo K2S-RUN-ERROR:checksum-format; exit 42;; esac'
    '[ ${#h} -eq 64 ] || { echo K2S-RUN-ERROR:checksum-format; exit 42; }'
    'case $# in 1) case $1 in provision|ensure-apiserver|publish|verify|renew) ;; *) echo K2S-RUN-ERROR:command; exit 43;; esac;; 2) if [ x$1 != xrenew ] || [ x$2 != x--force ]; then echo K2S-RUN-ERROR:command; exit 43; fi;; *) echo K2S-RUN-ERROR:command; exit 43;; esac'
    'b=/var/lib/k2s/webhook-auth'
    'for d in $b $b/bin $b/runs; do if [ -L $d ] || [ ! -d $d ]; then echo K2S-RUN-ERROR:directory:$d; exit 46; fi; o=$(stat -c %U:%G:%a $d); [ x$o = xroot:root:700 ] || { echo K2S-RUN-ERROR:directory:$d:$o; exit 46; }; done'
    ($script:LockFileTest + ' echo K2S-RUN-ERROR:lock-file; exit 48; fi')
    'command exec 9>$b/.lock || { echo K2S-RUN-ERROR:lock; exit 48; }'
    'flock -w 60 9 || { echo K2S-RUN-ERROR:lock; exit 48; }'
    'now=$(date +%s)'
    'case x$now in x|x*[!0-9]*) echo K2S-RUN-ERROR:clock; exit 50;; esac'
    ('for d in $b/runs/*; do if [ -L $d ] || [ ! -d $d ]; then continue; fi; r=${d##*/}; case $r in ' + $script:RunIdCase + ') ;; *) continue;; esac; [ -f $d/exit ] && continue; ' +
        'if [ -f $d/pid ]; then if { [ -f $d/alive ] && [ ! -L $d/alive ] && ! flock -n $d/alive true; } || grep -q -s -z -x -F -- K2S_WEBHOOK_AUTH_RUN=$r /proc/[0-9]*/environ; then n=$(head -c 16 $d/pid); case x$n in x|x*[!0-9]*) n=0;; esac; if grep -q -s -z -x -F -- $r /proc/$n/cmdline; then echo K2S-RUN-BUSY:$r:$n; else echo K2S-RUN-BUSY:$r:orphaned; fi; exit 10; fi; ' +
        'elif [ ! -e $d/abandoned ] && [ ! -L $d/abandoned ]; then m=$(stat -c %Y $d); case x$m in x|x*[!0-9]*) echo K2S-RUN-BUSY:$r:starting; exit 10;; esac; a=$((now - m)); if [ $a -ge 0 ] && [ $a -lt 120 ]; then echo K2S-RUN-BUSY:$r:starting; exit 10; fi; : > $d/abandoned || { echo K2S-RUN-ERROR:abandon; exit 49; }; fi; done')
    ('for d in $b/runs/*; do if [ -L $d ] || [ ! -d $d ]; then continue; fi; r=${d##*/}; case $r in ' + $script:RunIdCase + ') ;; *) continue;; esac; ' +
        'if [ -f $d/exit ] && [ ! -L $d/exit ] && [ -f $d/pid ] && [ ! -L $d/pid ] && [ ! -e $d/abandoned ] && [ ! -L $d/abandoned ]; then v=$(head -c 16 $d/exit); case x$v in x|x*[!0-9]*) continue;; esac; f=$d/exit; ' +
        'elif [ -f $d/abandoned ] && [ ! -L $d/abandoned ] && [ ! -e $d/pid ] && [ ! -L $d/pid ] && [ ! -e $d/exit ] && [ ! -L $d/exit ]; then f=$d/abandoned; else continue; fi; ' +
        'm=$(stat -c %Y $f); case x$m in x|x*[!0-9]*) continue;; esac; [ $((now - m)) -gt ' + $script:RunRetentionSeconds + ' ] || continue; ' +
        'if { [ -f $d/alive ] && [ ! -L $d/alive ] && ! flock -n $d/alive true; } || grep -q -s -z -x -F -- K2S_WEBHOOK_AUTH_RUN=$r /proc/[0-9]*/environ; then continue; fi; ' +
        'k=0; for e in $d/* $d/.[!.]* $d/..?*; do if [ ! -e $e ] && [ ! -L $e ]; then continue; fi; case ${e##*/} in clusterip-webhook-auth.sh|pid|alive|run.log|exit|abandoned) if [ -L $e ] || [ ! -f $e ]; then k=1; fi;; *) k=1;; esac; done; ' +
        'if [ $k -eq 0 ] && rm -f -- $d/clusterip-webhook-auth.sh $d/run.log $d/alive && rm -f -- $d/pid $d/exit $d/abandoned && rmdir -- $d; then echo K2S-RUN-REMOVED:$r; else echo K2S-RUN-KEPT:$r; fi; done')
    'p=$b/bin/clusterip-webhook-auth.sh'
    'x=$b/runs/$id/clusterip-webhook-auth.sh'
    'mkdir -m 0700 -- $b/runs/$id || { echo K2S-RUN-ERROR:run-directory; exit 47; }'
    'if [ -L $p ] || [ ! -f $p ] || ! cp -- $p $x; then rm -rf -- $b/runs/$id; echo K2S-RUN-ERROR:script-missing; exit 44; fi'
    's=$(sha256sum < $x)'
    's=${s%% *}'
    '[ x$s = x$h ] || { rm -rf -- $b/runs/$id; echo K2S-RUN-ERROR:script-checksum; exit 45; }'
    'chmod 0700 $x'
    'echo K2S-RUN-PREPARED:$id'
) -join '; '

# $1 run id, $2... script arguments. Runs detached (setsid) as root. Under the lock, it locks the file alive of the run
# and claims the run by writing its PID, unless the run was abandoned (a marker in any form, also a symbolic link) or its
# run path is a symbolic link; then it releases the lock (no other process inherits it), runs the verified copy of the
# script with its output in run.log and writes the exit status last, each with an atomic rename. The script and all its
# children inherit the locked file alive, and also K2S_WEBHOOK_AUTH_RUN=<run id>. The run id is an argument of this
# process, which identifies it in /proc/<pid>/cmdline even if the PID is later reused.
$script:RunnerSnippet = @(
    'umask 077'
    ('case $1 in ' + $script:RunIdCase + ') ;; *) exit 1;; esac')
    'id=$1'
    'b=/var/lib/k2s/webhook-auth'
    'r=$b/runs/$id'
    'shift'
    'if [ -L $r ] || [ ! -d $r ]; then exit 1; fi'
    ($script:LockFileTest + ' exit 1; fi')
    'command exec 9>$b/.lock || exit 1'
    'flock -w 60 9 || exit 1'
    'if [ -e $r/abandoned ] || [ -L $r/abandoned ] || [ -e $r/pid ]; then exit 1; fi'
    'command exec 8>$r/alive || exit 1'
    'flock -n 8 || exit 1'
    'echo $$ > $r/pid.tmp && mv -f $r/pid.tmp $r/pid || exit 1'
    'command exec 9>&-'
    'K2S_WEBHOOK_AUTH_RUN=$id $r/clusterip-webhook-auth.sh $* < /dev/null > $r/run.log 2>&1'
    'c=$?'
    'echo $c > $r/exit.tmp && mv -f $r/exit.tmp $r/exit'
) -join '; '

# $1 run id. Waits up to 5 s for the PID of the detached run.
$script:WaitStartSnippet = @(
    ('case $1 in ' + $script:RunIdCase + ') ;; *) echo K2S-RUN-ERROR:run-id; exit 41;; esac')
    'r=/var/lib/k2s/webhook-auth/runs/$1'
    'i=0'
    'while [ ! -s $r/pid ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done'
    'if [ -s $r/pid ]; then echo K2S-RUN-STARTED:$(head -c 16 $r/pid); else echo K2S-RUN-STARTED:unknown; fi'
) -join '; '

# $1 run id, $2 maximum log bytes, $3 nonce of this poll. Reports the state of a run (missing, starting, abandoned,
# running:<pid>, orphaned:<pid> when the runner ended but a process of the run still runs, exited:<status>,
# vanished:<pid>, invalid-pid, invalid-directory when the run path is a symbolic link or no directory) and the end of its
# log between markers that contain the nonce; the end marker follows only a complete read of the log. A claimed run is
# alive while its file alive is locked (or a process carries its K2S_WEBHOOK_AUTH_RUN); only a regular file is tested,
# so the poll creates no file and never waits for a FIFO. The exit file is checked again after a negative check because
# the run may just have finished. An abandoned marker in any form, also a symbolic link, means abandoned.
$script:PollSnippet = @(
    ('case $1 in ' + $script:RunIdCase + ') ;; *) echo K2S-RUN-ERROR:run-id; exit 41;; esac')
    'case x$2 in x|x*[!0-9]*) echo K2S-RUN-ERROR:log-limit; exit 42;; esac'
    'case x$3 in x|x*[!0-9a-f]*) echo K2S-RUN-ERROR:nonce; exit 43;; esac'
    '[ ${#3} -eq 32 ] || { echo K2S-RUN-ERROR:nonce; exit 43; }'
    'r=/var/lib/k2s/webhook-auth/runs/$1'
    'if [ -L $r ] || { [ -e $r ] && [ ! -d $r ]; }; then echo K2S-RUN-STATE:invalid-directory; exit 0; fi'
    'if [ ! -d $r ]; then echo K2S-RUN-STATE:missing; exit 0; fi'
    'if [ -f $r/pid ]; then echo K2S-RUN-PID:$(head -c 16 $r/pid); fi'
    'if [ -f $r/exit ]; then st=exited:$(head -c 16 $r/exit); elif [ -f $r/pid ]; then n=$(head -c 16 $r/pid); case x$n in x|x*[!0-9]*) st=invalid-pid;; *) if { [ -f $r/alive ] && [ ! -L $r/alive ] && ! flock -n $r/alive true; } || grep -q -s -z -x -F -- K2S_WEBHOOK_AUTH_RUN=$1 /proc/[0-9]*/environ; then if grep -q -s -z -x -F -- $1 /proc/$n/cmdline; then st=running:$n; else st=orphaned:$n; fi; elif [ -f $r/exit ]; then st=exited:$(head -c 16 $r/exit); else st=vanished:$n; fi;; esac; elif [ -e $r/abandoned ] || [ -L $r/abandoned ]; then st=abandoned; else st=starting; fi'
    'echo K2S-RUN-STATE:$st'
    'if [ -f $r/run.log ]; then echo K2S-RUN-LOG-SIZE:$(stat -c %s $r/run.log); echo K2S-RUN-LOG-BEGIN:$3; if tail -c $2 $r/run.log; then echo; echo K2S-RUN-LOG-END:$3; fi; else echo K2S-RUN-LOG-SIZE:none; fi'
) -join '; '

# $1 run id. Under the lock, makes sure that a run that its runner has not claimed never starts: marks its directory as
# abandoned, creating it if the run was never prepared, so that a late preparation of the run fails. Reports claimed if
# the runner has already written its PID. An existing marker in any form already means abandoned and is not written.
$script:AbandonSnippet = @(
    'umask 077'
    ('case $1 in ' + $script:RunIdCase + ') ;; *) echo K2S-RUN-ABANDON:error:run-id; exit 41;; esac')
    'b=/var/lib/k2s/webhook-auth'
    'r=$b/runs/$1'
    'for d in $b $b/runs; do if [ -L $d ] || [ ! -d $d ]; then echo K2S-RUN-ABANDON:error:directory; exit 46; fi; o=$(stat -c %U:%G:%a $d); [ x$o = xroot:root:700 ] || { echo K2S-RUN-ABANDON:error:directory; exit 46; }; done'
    ($script:LockFileTest + ' echo K2S-RUN-ABANDON:error:lock-file; exit 48; fi')
    'command exec 9>$b/.lock || { echo K2S-RUN-ABANDON:error:lock; exit 48; }'
    'flock -w 10 9 || { echo K2S-RUN-ABANDON:error:lock; exit 48; }'
    'if [ -L $r ] || { [ -e $r ] && [ ! -d $r ]; }; then echo K2S-RUN-ABANDON:error:run-directory; exit 47; fi'
    'if [ -e $r/pid ] || [ -e $r/exit ]; then echo K2S-RUN-ABANDON:claimed; exit 0; fi'
    'if [ ! -d $r ]; then mkdir -m 0700 -- $r || { echo K2S-RUN-ABANDON:error:run-directory; exit 47; }; fi'
    'if [ -e $r/abandoned ] || [ -L $r/abandoned ]; then echo K2S-RUN-ABANDON:done; exit 0; fi'
    ': > $r/abandoned || { echo K2S-RUN-ABANDON:error:marker; exit 49; }'
    'echo K2S-RUN-ABANDON:done'
) -join '; '

# --- logging ---

# Logging is best effort: a failure to write the K2s log never changes the course or the result of an operation, so the
# caller always gets the result of a run that may have started, and an approved retry still happens. The message is
# then shown as a warning; if that fails too, it is dropped. A stopped pipeline (Ctrl+C) is never absorbed.
function Write-WebhookAuthLog {
    param([Parameter(Mandatory = $true, Position = 0)][string]$Message)
    try {
        Write-Log $Message
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        throw
    }
    catch {
        $logError = $_.Exception.Message
        try {
            Microsoft.PowerShell.Utility\Write-Warning -Message "[WebhookAuth] Cannot write to the K2s log ($logError): $Message" -WarningAction Continue
        }
        catch [System.Management.Automation.PipelineStoppedException] {
            throw
        }
        catch {
            # Neither the K2s log nor the warning stream takes the message; returning the result matters more.
            $null = $_
        }
    }
}

# --- remote commands ---

# Quotes a value for the remote shell. Only values from a restricted character set are accepted.
function ConvertTo-WebhookAuthShellWord {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -cnotmatch '\A[A-Za-z0-9._/:@=+-]+\z') {
        throw "[WebhookAuth] Refusing to pass '$Value' to the remote shell"
    }
    return "'$Value'"
}

function Assert-WebhookAuthRunId {
    param([string]$RunId)
    if ($RunId -cnotmatch $script:RunIdPattern) { throw "[WebhookAuth] Invalid run id '$RunId'" }
}

function Assert-WebhookAuthSha256 {
    param([string]$Sha256)
    if ($Sha256 -cnotmatch $script:Sha256Pattern) { throw "[WebhookAuth] Invalid SHA-256 '$Sha256'" }
}

function Assert-WebhookAuthUploadDirectory {
    param([string]$UploadDirectory)
    if ($UploadDirectory -cnotmatch $script:UploadDirectoryPattern) {
        throw "[WebhookAuth] Unexpected remote upload directory '$UploadDirectory'"
    }
}

function Assert-WebhookAuthArgumentList {
    param([string[]]$Arguments)
    $list = @($Arguments)
    $valid = ($list.Count -eq 1 -and $list[0] -cin @('provision', 'ensure-apiserver', 'publish', 'verify', 'renew')) -or
        ($list.Count -eq 2 -and $list[0] -ceq 'renew' -and $list[1] -ceq '--force')
    if (-not $valid) {
        throw "[WebhookAuth] Unsupported clusterip-webhook-auth.sh arguments '$($list -join ' ')'"
    }
}

# Windows PowerShell 5.1 cannot pass double quotes or line breaks to native programs reliably.
function Assert-WebhookAuthRemoteCommand {
    param([Parameter(Mandatory = $true)][string]$RemoteCommand)
    if ($RemoteCommand.IndexOfAny([char[]]@('"', "`r", "`n")) -ge 0 -or $RemoteCommand.EndsWith('\')) {
        throw '[WebhookAuth] Internal error: the remote command contains characters that cannot be passed to ssh.exe safely'
    }
}

function Get-WebhookAuthUploadDirectoryCommand {
    return 'umask 077 && mktemp -d /tmp/k2s-webhook-auth-stage.XXXXXXXXXX'
}

function Get-WebhookAuthCleanupCommand {
    param([Parameter(Mandatory = $true)][string]$UploadDirectory)
    Assert-WebhookAuthUploadDirectory -UploadDirectory $UploadDirectory
    return "rm -rf -- $(ConvertTo-WebhookAuthShellWord $UploadDirectory)"
}

function Get-WebhookAuthPromoteCommand {
    param(
        [Parameter(Mandatory = $true)][string]$UploadDirectory,
        [Parameter(Mandatory = $true)][string]$Sha256
    )
    Assert-WebhookAuthUploadDirectory -UploadDirectory $UploadDirectory
    Assert-WebhookAuthSha256 -Sha256 $Sha256
    return "sudo -n /bin/sh -c '$($script:PromoteSnippet)' k2s-webhook-auth $(ConvertTo-WebhookAuthShellWord $UploadDirectory) $(ConvertTo-WebhookAuthShellWord $Sha256)"
}

# Prepares the run as root (PrepareSnippet).
function Get-WebhookAuthPrepareCommand {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    Assert-WebhookAuthRunId -RunId $RunId
    Assert-WebhookAuthSha256 -Sha256 $Sha256
    Assert-WebhookAuthArgumentList -Arguments $Arguments
    $words = @($Arguments | ForEach-Object { ConvertTo-WebhookAuthShellWord $_ }) -join ' '
    return "sudo -n /bin/sh -c '$($script:PrepareSnippet)' k2s-webhook-auth $(ConvertTo-WebhookAuthShellWord $RunId) $(ConvertTo-WebhookAuthShellWord $Sha256) $words"
}

# Starts the runner as root in a new session, with all standard streams detached from the SSH channel (RunnerSnippet).
function Get-WebhookAuthRunnerCommand {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    Assert-WebhookAuthRunId -RunId $RunId
    Assert-WebhookAuthArgumentList -Arguments $Arguments
    $words = @($Arguments | ForEach-Object { ConvertTo-WebhookAuthShellWord $_ }) -join ' '
    return "sudo -n setsid -f /bin/sh -c '$($script:RunnerSnippet)' k2s-webhook-auth $(ConvertTo-WebhookAuthShellWord $RunId) $words < /dev/null > /dev/null 2>&1"
}

# Waits briefly for the PID of the runner (WaitStartSnippet).
function Get-WebhookAuthWaitStartCommand {
    param([Parameter(Mandatory = $true)][string]$RunId)
    Assert-WebhookAuthRunId -RunId $RunId
    return "sudo -n /bin/sh -c '$($script:WaitStartSnippet)' k2s-webhook-auth $(ConvertTo-WebhookAuthShellWord $RunId)"
}

# Prepares the run, starts the runner, then waits briefly for its PID, all in one SSH call. A failing step ends the chain.
function Get-WebhookAuthStartCommand {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    return ((Get-WebhookAuthPrepareCommand -RunId $RunId -Sha256 $Sha256 -Arguments $Arguments) +
        ' && ' + (Get-WebhookAuthRunnerCommand -RunId $RunId -Arguments $Arguments) +
        ' && ' + (Get-WebhookAuthWaitStartCommand -RunId $RunId))
}

function Get-WebhookAuthPollCommand {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Nonce
    )
    Assert-WebhookAuthRunId -RunId $RunId
    if ($Nonce -cnotmatch $script:NoncePattern) { throw "[WebhookAuth] Invalid nonce '$Nonce'" }
    return ("sudo -n /bin/sh -c '$($script:PollSnippet)' k2s-webhook-auth $(ConvertTo-WebhookAuthShellWord $RunId) " +
        "$(ConvertTo-WebhookAuthShellWord ([string]$script:LogLimitBytes)) $(ConvertTo-WebhookAuthShellWord $Nonce)")
}

function Get-WebhookAuthAbandonCommand {
    param([Parameter(Mandatory = $true)][string]$RunId)
    Assert-WebhookAuthRunId -RunId $RunId
    return "sudo -n /bin/sh -c '$($script:AbandonSnippet)' k2s-webhook-auth $(ConvertTo-WebhookAuthShellWord $RunId)"
}

# --- transport ---

# Builds the command line of a native program: Start-Process joins its arguments without quoting. Arguments with white
# space are quoted; arguments that cannot be quoted safely for the program's argument parser are refused.
function Join-WebhookAuthProcessArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$ArgumentList)
    $quoted = foreach ($value in $ArgumentList) {
        if ($value.Contains('"')) {
            throw '[WebhookAuth] Internal error: an argument for ssh.exe or scp.exe contains a double quote'
        }
        if ($value -ne '' -and $value -notmatch '\s') {
            $value
        }
        elseif ($value.EndsWith('\')) {
            throw '[WebhookAuth] Internal error: an argument for ssh.exe or scp.exe ends with a backslash'
        }
        else {
            '"' + $value + '"'
        }
    }
    return @($quoted) -join ' '
}

# Reads the lines of a redirected output file; FileShare.ReadWrite tolerates handles that other processes still hold.
function Read-WebhookAuthProcessOutput {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false))
    try {
        $lines = [System.Collections.Generic.List[string]]::new()
        while ($null -ne ($line = $reader.ReadLine())) { $lines.Add($line) }
        return , $lines.ToArray()
    }
    finally {
        $reader.Dispose()
    }
}

# Runs a native program for at most TimeoutSeconds and returns its exit code, standard output and error output (SSH
# socket noise removed). A program that does not finish in time is stopped; its exit code is then $null.
function Invoke-WebhookAuthProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = $script:ProcessTimeoutSeconds
    )
    $commandLine = Join-WebhookAuthProcessArgument -ArgumentList $ArgumentList
    $outputFile = [System.IO.Path]::GetTempFileName()
    $errorFile = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $commandLine -NoNewWindow -PassThru -RedirectStandardOutput $outputFile -RedirectStandardError $errorFile -ErrorAction Stop
        # Windows PowerShell returns no ExitCode unless the handle is cached while the process runs (https://github.com/PowerShell/PowerShell/issues/20716)
        $null = $process.Handle
        $exitCode = $null
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            try {
                $process.Kill()
                $null = $process.WaitForExit(10000)
            }
            catch {
                Write-WebhookAuthLog "[WebhookAuth] Cannot stop '$FilePath' after its time limit: $($_.Exception.Message)"
            }
        }
        else {
            $exitCode = $process.ExitCode
        }
        $output = Read-WebhookAuthProcessOutput -Path $outputFile
        $errors = @((Read-WebhookAuthProcessOutput -Path $errorFile) | Where-Object { $_ -and $_ -notmatch 'IO is still pending|^Connection .* closed' })
        if ($timedOut) {
            $errors += "$(Split-Path -Path $FilePath -Leaf) did not finish within $TimeoutSeconds seconds and was stopped"
        }
    }
    finally {
        Remove-Item -LiteralPath $outputFile, $errorFile -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = [string[]]$output; Errors = [string[]]$errors }
}

# The K2s control-plane key, user and IP; host keys are checked against the known_hosts files of the Windows account.
function Get-WebhookAuthConnection {
    $key = Get-SSHKeyControlPlane
    if ([string]::IsNullOrWhiteSpace($key) -or -not (Test-Path -LiteralPath $key -PathType Leaf)) {
        throw '[WebhookAuth] The SSH key for the control-plane node was not found; is K2s installed?'
    }
    Set-SshPrivateKeyPermissions -Path $key
    $user = Get-ControlPlaneRemoteUser
    if ($user -cnotmatch '\A[a-z_][a-z0-9_-]*@[0-9A-Za-z.:-]+\z') {
        throw "[WebhookAuth] Unexpected control-plane SSH destination '$user'"
    }
    return [pscustomobject]@{
        User = $user
        Key  = $key
        Ssh  = (Get-Command 'ssh.exe' -ErrorAction Stop).Source
        Scp  = (Get-Command 'scp.exe' -ErrorAction Stop).Source
    }
}

# Options of every ssh.exe and scp.exe call. -F none: no configuration file is read, so no setting of the Windows
# account (ProxyCommand, Match exec, KnownHostsCommand, LocalCommand ...) can run a local command or redirect the
# connection. The other options state the security-relevant settings explicitly.
function Get-WebhookAuthSshOptionList {
    param([Parameter(Mandatory = $true)]$Connection)
    return @('-F', 'none', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15',
        '-o', 'ServerAliveCountMax=4', '-o', 'IdentitiesOnly=yes', '-o', 'ForwardAgent=no', '-o', 'ForwardX11=no',
        '-o', 'ClearAllForwardings=yes', '-o', 'ControlMaster=no', '-o', 'ControlPath=none', '-o', 'PermitLocalCommand=no',
        '-i', $Connection.Key)
}

function Invoke-WebhookAuthSsh {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$RemoteCommand,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = $script:ProcessTimeoutSeconds
    )
    Assert-WebhookAuthRemoteCommand -RemoteCommand $RemoteCommand
    $arguments = @('-n', '-T') + (Get-WebhookAuthSshOptionList -Connection $Connection) + @($Connection.User, $RemoteCommand)
    return Invoke-WebhookAuthProcess -FilePath $Connection.Ssh -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds
}

# scp gets no -T: for scp it disables the check of the file names returned by the server.
function Invoke-WebhookAuthScp {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$RemotePath
    )
    $arguments = (Get-WebhookAuthSshOptionList -Connection $Connection) + @($LocalPath, "$($Connection.User):$RemotePath")
    return Invoke-WebhookAuthProcess -FilePath $Connection.Scp -ArgumentList $arguments -TimeoutSeconds $script:ProcessTimeoutSeconds
}

# Describes a failed SSH or SCP step; host-key failures get the guidance of Wait-ForSshPossible.
function Get-WebhookAuthTransportMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)]$Result
    )
    $diagnostic = (@($Result.Errors) + @($Result.Output) | Where-Object { $_ } | Select-Object -Last 5) -join ' | '
    if ($diagnostic -match 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED') {
        return "[WebhookAuth] Cannot $Step`: control-plane host-key verification failed. The host key may be missing or changed in this Windows account's known_hosts files (profile '$env:USERPROFILE'). " +
            'Verify the VM host-key fingerprint through its console or another trusted channel, add or update only the verified entry and retry. ' +
            "Do not disable host-key checking. SSH diagnostic: $diagnostic"
    }
    $exitCode = if ($null -eq $Result.ExitCode) { 'none' } else { $Result.ExitCode }
    return "[WebhookAuth] Cannot $Step (ssh exit code $exitCode): $diagnostic"
}

# --- staging ---

function Get-WebhookAuthSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha256.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha256.Dispose()
    }
}

# Returns the script bytes with LF line endings and without a UTF-8 byte order mark. Content that is not a UTF-8
# shell script (UTF-16, NUL bytes, carriage returns outside CRLF) is refused rather than converted.
function ConvertTo-WebhookAuthLfContent {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )
    if ($Bytes.Length -ge 2 -and (($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) -or ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF))) {
        throw "[WebhookAuth] '$SourcePath' is UTF-16 encoded; expected a UTF-8 shell script"
    }
    $start = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $start = 3 }
    $stream = [System.IO.MemoryStream]::new($Bytes.Length)
    try {
        for ($i = $start; $i -lt $Bytes.Length; $i++) {
            $byte = $Bytes[$i]
            if ($byte -eq 0) { throw "[WebhookAuth] '$SourcePath' contains NUL bytes; expected a UTF-8 shell script" }
            if ($byte -eq 13) {
                if ($i + 1 -lt $Bytes.Length -and $Bytes[$i + 1] -eq 10) { continue }
                throw "[WebhookAuth] '$SourcePath' contains a carriage return that does not end a line"
            }
            $stream.WriteByte($byte)
        }
        $normalized = $stream.ToArray()
    }
    finally {
        $stream.Dispose()
    }
    if ($normalized.Length -lt 2 -or $normalized[0] -ne 0x23 -or $normalized[1] -ne 0x21) {
        throw "[WebhookAuth] '$SourcePath' does not start with '#!'; expected a shell script"
    }
    return , $normalized
}

# Reads the script from the K2s installation and returns its LF-normalized bytes with their SHA-256.
function Get-WebhookAuthScriptContent {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$InstallationPath)
    if ([string]::IsNullOrWhiteSpace($InstallationPath)) {
        throw '[WebhookAuth] The K2s installation path is empty'
    }
    # A relative path would be resolved differently by Test-Path (PowerShell location) and .NET (process directory).
    if ($InstallationPath -notmatch '\A(?:[A-Za-z]:\\|\\\\[^\\])') {
        throw "[WebhookAuth] The K2s installation path '$InstallationPath' is not an absolute path"
    }
    $sourcePath = Join-Path $InstallationPath $script:ScriptRelativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "[WebhookAuth] '$sourcePath' not found: the K2s installation '$InstallationPath' does not contain the webhook authentication script"
    }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($sourcePath)
    }
    catch {
        throw "[WebhookAuth] Cannot read '$sourcePath': $($_.Exception.Message)"
    }
    $normalized = ConvertTo-WebhookAuthLfContent -Bytes $bytes -SourcePath $sourcePath
    return [pscustomobject]@{
        SourcePath = $sourcePath
        Bytes      = $normalized
        Sha256     = (Get-WebhookAuthSha256 -Bytes $normalized)
    }
}

# Copies the exact bytes to a private upload directory, then lets PromoteSnippet verify and install them as root.
# Throws unless the node confirms the installation of a script with the expected SHA-256.
function Copy-WebhookAuthScriptToNode {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)]$Content
    )
    $localDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('k2s-webhook-auth-' + [guid]::NewGuid().ToString('N'))
    $uploadDirectory = $null
    $staged = $false
    try {
        New-Item -ItemType Directory -Path $localDirectory -ErrorAction Stop | Out-Null
        $localFile = Join-Path $localDirectory 'clusterip-webhook-auth.sh'
        [System.IO.File]::WriteAllBytes($localFile, [byte[]]$Content.Bytes)

        $result = Invoke-WebhookAuthSsh -Connection $Connection -RemoteCommand (Get-WebhookAuthUploadDirectoryCommand)
        $candidates = @($result.Output | Where-Object { $_ -cmatch $script:UploadDirectoryPattern })
        if ($candidates.Count -ne 1) {
            throw (Get-WebhookAuthTransportMessage -Step 'create a private upload directory on the control-plane node' -Result $result)
        }
        $uploadDirectory = $candidates[0]

        $copy = Invoke-WebhookAuthScp -Connection $Connection -LocalPath $localFile -RemotePath "$uploadDirectory/clusterip-webhook-auth.sh"
        if ($copy.ExitCode -ne 0) {
            $message = Get-WebhookAuthTransportMessage -Step 'copy the webhook authentication script to the control-plane node' -Result $copy
            if ($message -match 'host-key verification failed') { throw $message }
            Write-WebhookAuthLog "$message; the remote checksum decides whether the copy is complete"
        }

        $result = Invoke-WebhookAuthSsh -Connection $Connection -RemoteCommand (Get-WebhookAuthPromoteCommand -UploadDirectory $uploadDirectory -Sha256 $Content.Sha256)
        if (@($result.Output) -ccontains "K2S-STAGE-OK:$($Content.Sha256)") {
            $staged = $true
            return
        }
        $refusal = @($result.Output | Where-Object { $_ -cmatch '\AK2S-STAGE-ERROR:' }) | Select-Object -First 1
        if ($refusal) {
            $detail = $refusal.Substring(16)
            $hint = ''
            if ($detail -cmatch '\A(insecure-parent|not-a-directory|directory-permissions|lock-file)') {
                $hint = '. Nothing below /var/lib/k2s is repaired automatically, because another user may have written into it: /var/lib/k2s must be owned by root and writable only by root; ' +
                    '/var/lib/k2s/webhook-auth, its bin and runs must be directories owned by root:root with mode 0700 and its .lock a regular root-owned file. ' +
                    'Inspect the directory; if another user may have changed it, remove /var/lib/k2s/webhook-auth after making sure that no run is active'
            }
            throw "[WebhookAuth] The control-plane node refused to install the webhook authentication script ($detail); nothing was installed or executed$hint"
        }
        throw (Get-WebhookAuthTransportMessage -Step 'verify and install the webhook authentication script on the control-plane node' -Result $result)
    }
    finally {
        Remove-Item -LiteralPath $localDirectory -Recurse -Force -ErrorAction SilentlyContinue
        if ($uploadDirectory -and -not $staged) {
            try {
                $null = Invoke-WebhookAuthSsh -Connection $Connection -RemoteCommand (Get-WebhookAuthCleanupCommand -UploadDirectory $uploadDirectory)
            }
            catch {
                Write-WebhookAuthLog "[WebhookAuth] Cannot remove the upload directory '$uploadDirectory': $($_.Exception.Message)"
            }
        }
    }
}

<#
.SYNOPSIS
Stages clusterip-webhook-auth.sh of the K2s installation on the Linux control-plane node.

.DESCRIPTION
Reads the script from the K2s installation, converts CRLF to LF, computes the SHA-256 of these bytes and copies them
to a private upload directory. As root, the node verifies the checksum, installs the bytes as a non-executable
temporary file next to /var/lib/k2s/webhook-auth/bin/clusterip-webhook-auth.sh, verifies them again, sets mode 0700
and renames the file into place; then it verifies checksum, owner and mode of the result. Safe to repeat: staging is
serialized on the node, and every run executes its own verified copy of the script. Missing directories are created;
existing ones that are not owned by root with mode 0700, or a lock file that is not a regular root-owned file, are
refused and never repaired.

.OUTPUTS
Object with SourcePath, Sha256, RemotePath and Size. Throws if the script cannot be staged and verified.
#>
function Copy-ClusterIPWebhookAuthScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, HelpMessage = 'K2s installation directory that contains the script')]
        [string]$InstallationPath = (Get-KubePath)
    )
    $content = Get-WebhookAuthScriptContent -InstallationPath $InstallationPath
    $connection = Get-WebhookAuthConnection
    Copy-WebhookAuthScriptToNode -Connection $connection -Content $content
    Write-WebhookAuthLog "[WebhookAuth] Staged '$($content.SourcePath)' as '$script:RemoteScriptPath' (SHA-256 $($content.Sha256))"
    return [pscustomobject]@{
        SourcePath = $content.SourcePath
        Sha256     = $content.Sha256
        RemotePath = $script:RemoteScriptPath
        Size       = $content.Bytes.Length
    }
}

# --- execution ---

function Get-WebhookAuthUtcNow { return [DateTime]::UtcNow }

# Monotonic time in seconds for the observation deadline; changes of the system clock do not affect it.
function Get-WebhookAuthClock { return [System.Diagnostics.Stopwatch]::GetTimestamp() / [double][System.Diagnostics.Stopwatch]::Frequency }

# Lower-case hex string of $Count random bytes.
function Get-WebhookAuthRandomHex {
    param([Parameter(Mandatory = $true)][int]$Count)
    $bytes = New-Object byte[] $Count
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
    }
    finally {
        $random.Dispose()
    }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function New-WebhookAuthRunId {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only computes an identifier')]
    param()
    $stamp = (Get-WebhookAuthUtcNow).ToString("yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    return $stamp + '-' + (Get-WebhookAuthRandomHex -Count 4)
}

# Local observation deadline; the remote process is never stopped when it passes. ensure-apiserver and renew may wait
# for the lock and then several times for kube-apiserver or the webhook (bounded in clusterip-webhook-auth.sh: a renewal
# with rollback verifies three times), so they are observed for 30 minutes.
function Get-WebhookAuthTimeout {
    param([Parameter(Mandatory = $true)][string]$Command)
    if ($Command -cin @('ensure-apiserver', 'renew')) { return 1800 }
    return 600
}

# Starts the detached run. State: Started, Busy (another run is active: OtherRunId, RemotePid if known, Detail),
# Refused (a check before the start failed, nothing runs) or Unconfirmed (no reliable answer: the run state must be
# polled before any decision).
function Start-WebhookAuthRun {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal step; Invoke-ClusterIPWebhookAuth decides whether a run is started')]
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $command = Get-WebhookAuthStartCommand -RunId $RunId -Sha256 $Sha256 -Arguments $Arguments
    try {
        $result = Invoke-WebhookAuthSsh -Connection $Connection -RemoteCommand $command
    }
    catch {
        return [pscustomobject]@{ State = 'Unconfirmed'; RemotePid = $null; OtherRunId = $null; Detail = $_.Exception.Message }
    }
    $lines = @($result.Output)
    # Retention of old runs (PrepareSnippet); a kept run is left for inspection and does not prevent the start.
    $removed = @($lines | Where-Object { $_ -cmatch '\AK2S-RUN-REMOVED:[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z' })
    if ($removed.Count -gt 0) {
        Write-WebhookAuthLog "[WebhookAuth] Removed $($removed.Count) run directories of runs that ended more than 30 days ago"
    }
    foreach ($kept in @($lines | Where-Object { $_ -cmatch '\AK2S-RUN-KEPT:[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z' })) {
        Write-WebhookAuthLog "[WebhookAuth] Kept the run directory $script:RemoteRunsDirectory/$($kept.Substring(13)) for inspection: the run ended more than 30 days ago, but the directory contains unexpected entries or cannot be removed"
    }
    foreach ($line in $lines) {
        if ($line -cmatch '\AK2S-RUN-BUSY:([0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}):([0-9]{1,10}|starting|orphaned)\z') {
            $otherRunId = $Matches[1]
            $activity = $Matches[2]
            if ($activity -ceq 'starting') {
                return [pscustomobject]@{ State = 'Busy'; RemotePid = $null; OtherRunId = $otherRunId; Detail = 'is being started' }
            }
            if ($activity -ceq 'orphaned') {
                return [pscustomobject]@{ State = 'Busy'; RemotePid = $null; OtherRunId = $otherRunId; Detail = 'is still running (its runner ended, a process of the run is alive)' }
            }
            return [pscustomobject]@{ State = 'Busy'; RemotePid = [long]$activity; OtherRunId = $otherRunId; Detail = "(PID $activity) is still running" }
        }
    }
    $refusal = @($lines | Where-Object { $_ -cmatch '\AK2S-RUN-ERROR:' }) | Select-Object -First 1
    if ($refusal) {
        return [pscustomobject]@{ State = 'Refused'; RemotePid = $null; OtherRunId = $null; Detail = $refusal.Substring(14) }
    }
    $prepared = $lines -ccontains "K2S-RUN-PREPARED:$RunId"
    $started = @($lines | Where-Object { $_ -cmatch '\AK2S-RUN-STARTED:([0-9]{1,10}|unknown)\z' }) | Select-Object -First 1
    if ($prepared -and $started) {
        $remotePid = $null
        if ($started -cmatch '\AK2S-RUN-STARTED:([0-9]{1,10})\z') { $remotePid = [long]$Matches[1] }
        return [pscustomobject]@{ State = 'Started'; RemotePid = $remotePid; OtherRunId = $null; Detail = '' }
    }
    return [pscustomobject]@{
        State      = 'Unconfirmed'
        RemotePid  = $null
        OtherRunId = $null
        Detail     = (Get-WebhookAuthTransportMessage -Step 'confirm the start of the remote run' -Result $result)
    }
}

# State of a run as read by a poll; 'unreachable' as long as no answer of the node shows a state.
function New-WebhookAuthRunState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only creates an in-memory object')]
    param([string]$Detail = '')
    return [pscustomobject]@{ State = 'unreachable'; RemotePid = $null; ExitCode = $null; Log = @(); LogComplete = $false; Detail = $Detail }
}

# Parses the output of PollSnippet for the nonce of the poll. State 'unreachable' means that the output contains no
# state. The log is complete only if the end marker with the nonce follows the begin marker with the nonce and the log
# fits into the limit; log content cannot contain the nonce, which is chosen after the log was written.
function ConvertFrom-WebhookAuthRunState {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Output,
        [Parameter(Mandatory = $true)][string]$Nonce
    )
    $lines = @($Output)
    $state = New-WebhookAuthRunState
    $logSize = $null
    $begin = [Array]::IndexOf($lines, "K2S-RUN-LOG-BEGIN:$Nonce")
    $headerCount = if ($begin -ge 0) { $begin } else { $lines.Count }
    for ($i = 0; $i -lt $headerCount; $i++) {
        $line = $lines[$i]
        if ($line -cmatch '\AK2S-RUN-PID:([0-9]{1,10})\z') { $state.RemotePid = [long]$Matches[1] }
        elseif ($line -cmatch '\AK2S-RUN-STATE:(missing|starting|abandoned|invalid-pid|invalid-directory)\z') { $state.State = $Matches[1] }
        elseif ($line -cmatch '\AK2S-RUN-STATE:(running|orphaned|vanished):([0-9]{1,10})\z') {
            $state.State = $Matches[1]
            $state.RemotePid = [long]$Matches[2]
        }
        elseif ($line -cmatch '\AK2S-RUN-STATE:exited:([0-9]{1,3})\z') {
            $state.State = 'exited'
            $state.ExitCode = [int]$Matches[1]
        }
        elseif ($line -cmatch '\AK2S-RUN-STATE:') { $state.State = 'invalid-state' }
        elseif ($line -cmatch '\AK2S-RUN-LOG-SIZE:([0-9]{1,12})\z') { $logSize = [long]$Matches[1] }
    }
    if ($begin -ge 0) {
        $end = if ($begin + 1 -lt $lines.Count) { [Array]::IndexOf($lines, "K2S-RUN-LOG-END:$Nonce", $begin + 1) } else { -1 }
        if ($end -gt $begin) {
            # The last line before the end marker comes from the echo after tail: empty if the log ends with a line break.
            $last = $end - 1
            if ($last -gt $begin -and $lines[$last] -eq '') { $last-- }
            if ($last -gt $begin) { $state.Log = @($lines[($begin + 1)..$last]) }
            $state.LogComplete = ($null -ne $logSize -and $logSize -le $script:LogLimitBytes)
        }
    }
    return $state
}

function Get-WebhookAuthRunState {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = $script:ProcessTimeoutSeconds
    )
    try {
        $nonce = Get-WebhookAuthRandomHex -Count 16
        $command = Get-WebhookAuthPollCommand -RunId $RunId -Nonce $nonce
        $result = Invoke-WebhookAuthSsh -Connection $Connection -RemoteCommand $command -TimeoutSeconds $TimeoutSeconds
    }
    catch {
        return (New-WebhookAuthRunState -Detail $_.Exception.Message)
    }
    $state = ConvertFrom-WebhookAuthRunState -Output $result.Output -Nonce $nonce
    if ($state.State -eq 'unreachable') {
        $state.Detail = Get-WebhookAuthTransportMessage -Step 'read the state of the remote run' -Result $result
    }
    return $state
}

# Time limit for an ssh.exe call that must end by the observation deadline.
function Get-WebhookAuthCallTimeout {
    param([Parameter(Mandatory = $true)][double]$RemainingSeconds)
    return [int][Math]::Max(1, [Math]::Min($script:ProcessTimeoutSeconds, [Math]::Ceiling($RemainingSeconds)))
}

# Makes sure that a run that its runner has not claimed never starts (AbandonSnippet). State: Revoked (the run is
# abandoned and can no longer start), Claimed (its runner has written its PID: keep polling) or Unknown.
function Revoke-WebhookAuthRunStart {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    try {
        $command = Get-WebhookAuthAbandonCommand -RunId $RunId
        $result = Invoke-WebhookAuthSsh -Connection $Connection -RemoteCommand $command -TimeoutSeconds $TimeoutSeconds
    }
    catch {
        return [pscustomobject]@{ State = 'Unknown'; Detail = $_.Exception.Message }
    }
    $lines = @($result.Output)
    if ($lines -ccontains 'K2S-RUN-ABANDON:done') { return [pscustomobject]@{ State = 'Revoked'; Detail = '' } }
    if ($lines -ccontains 'K2S-RUN-ABANDON:claimed') { return [pscustomobject]@{ State = 'Claimed'; Detail = '' } }
    $prefix = 'K2S-RUN-ABANDON:error:'
    $refusal = @($lines | Where-Object { $_.StartsWith($prefix, [System.StringComparison]::Ordinal) }) | Select-Object -First 1
    if ($refusal) {
        return [pscustomobject]@{ State = 'Unknown'; Detail = "the control-plane node cannot mark the run as abandoned ($($refusal.Substring($prefix.Length)))" }
    }
    return [pscustomobject]@{ State = 'Unknown'; Detail = (Get-WebhookAuthTransportMessage -Step 'mark the remote run as abandoned' -Result $result) }
}

# Polls the run every PollIntervalSeconds with a new SSH connection until it is no longer running, until it is proven
# that it never starts, or until the observation deadline passes. Never stops the remote process. The deadline is
# measured with a monotonic clock. No call starts at or after the deadline, every call gets at most the remaining time,
# and a result that arrives after the deadline is kept for diagnosis but not accepted (Final is false), so nothing is
# decided or repeated after the deadline. A run that its runner has not claimed StartGraceSeconds after the start is
# abandoned on the node, which proves that it never starts.
function Wait-WebhookAuthRun {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][double]$StartedAt,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $deadline = $StartedAt + $TimeoutSeconds
    $last = $null
    $lastProblem = ''
    $reported = ''
    while ($true) {
        $remaining = $deadline - (Get-WebhookAuthClock)
        if ($remaining -le 0) {
            return [pscustomobject]@{ Final = $false; State = $last; LastProblem = $lastProblem }
        }
        $state = Get-WebhookAuthRunState -Connection $Connection -RunId $RunId -TimeoutSeconds (Get-WebhookAuthCallTimeout -RemainingSeconds $remaining)
        $now = Get-WebhookAuthClock
        if ($state.State -ne 'unreachable') {
            $last = $state
            if ($now -ge $deadline) {
                return [pscustomobject]@{ Final = $false; State = $last; LastProblem = $lastProblem }
            }
            if ($state.State -ne $reported) {
                $description = if ($state.State -eq 'orphaned') { 'running (its runner ended, a process of the run is alive)' } else { $state.State }
                Write-WebhookAuthLog "[WebhookAuth] Run $RunId`: $description$(if ($state.RemotePid) { " (PID $($state.RemotePid))" })"
                $reported = $state.State
            }
            if ($state.State -in @('exited', 'vanished', 'abandoned', 'invalid-pid', 'invalid-directory', 'invalid-state')) {
                return [pscustomobject]@{ Final = $true; State = $state; LastProblem = $lastProblem }
            }
            if ($state.State -in @('missing', 'starting') -and ($now - $StartedAt) -ge $script:StartGraceSeconds) {
                # Reading the clock again: no request starts at or after the deadline, also if logging took time.
                $remaining = $deadline - (Get-WebhookAuthClock)
                if ($remaining -le 0) {
                    return [pscustomobject]@{ Final = $false; State = $last; LastProblem = $lastProblem }
                }
                $revoke = Revoke-WebhookAuthRunStart -Connection $Connection -RunId $RunId -TimeoutSeconds (Get-WebhookAuthCallTimeout -RemainingSeconds $remaining)
                if ((Get-WebhookAuthClock) -ge $deadline) {
                    $lastProblem = "the answer to marking the run as abandoned ($($revoke.State)) arrived after the local deadline"
                    return [pscustomobject]@{ Final = $false; State = $last; LastProblem = $lastProblem }
                }
                if ($revoke.State -eq 'Revoked') {
                    Write-WebhookAuthLog "[WebhookAuth] Run $RunId`: not started within $($script:StartGraceSeconds) seconds; marked as abandoned, it can no longer start"
                    $state.State = 'abandoned'
                    return [pscustomobject]@{ Final = $true; State = $state; LastProblem = $lastProblem }
                }
                if ($revoke.State -eq 'Claimed') {
                    Write-WebhookAuthLog "[WebhookAuth] Run $RunId`: its runner has started; polling continues"
                }
                else {
                    $lastProblem = $revoke.Detail
                    Write-WebhookAuthLog "[WebhookAuth] Run $RunId`: cannot make sure that the run does not start; polling continues. $lastProblem"
                }
            }
        }
        else {
            $lastProblem = $state.Detail
            Write-WebhookAuthLog "[WebhookAuth] Run $RunId`: no state from the control-plane node; the run is not affected. $lastProblem"
        }
        $remaining = $deadline - (Get-WebhookAuthClock)
        if ($remaining -le 0) {
            return [pscustomobject]@{ Final = $false; State = $last; LastProblem = $lastProblem }
        }
        Start-Sleep -Seconds ([int][Math]::Min($script:PollIntervalSeconds, [Math]::Ceiling($remaining)))
    }
}

# --- outcome ---

function New-WebhookAuthResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only creates an in-memory object')]
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$Attempt
    )
    return [pscustomobject]@{
        Command            = $Arguments[0]
        Arguments          = $Arguments
        Status             = 'Unknown'
        Succeeded          = $false
        Reason             = ''
        Message            = ''
        ExitCode           = $null
        ExpectedMarker     = "K2S-WEBHOOK-AUTH-OK:$($Arguments[0])"
        MarkerFound        = $false
        Renewed            = $null
        Warnings           = @()
        RunId              = $null
        RunDirectory       = $null
        RemotePid          = $null
        RemoteProcessState = 'NotStarted'
        Log                = @()
        LogTail            = @()
        LogComplete        = $false
        ScriptSha256       = $null
        BusyRunId          = $null
        BusyPid            = $null
        Attempt            = $Attempt
        PreviousAttempt    = $null
    }
}

function Set-WebhookAuthStatus {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only changes an in-memory object')]
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $Result.Status = $Status
    $Result.Reason = $Reason
    $Result.Message = $Message
    $Result.Succeeded = ($Status -ceq 'Succeeded')
}

function Get-WebhookAuthLastLogLine {
    param([AllowEmptyCollection()][string[]]$Log)
    $lines = @($Log)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if (-not [string]::IsNullOrEmpty($lines[$i])) { return $lines[$i] }
    }
    return $null
}

# Whether the manifest swap of ensure-apiserver may have started. Only the complete log of a run can prove that it did
# not: clusterip-webhook-auth.sh logs the backup of the manifest before it changes the manifest, so a complete log
# without such a line shows that the manifest was never replaced. An incomplete log never proves it.
function Test-WebhookAuthManifestSwapStarted {
    param(
        [AllowEmptyCollection()][string[]]$Log,
        [Parameter(Mandatory = $true)][bool]$LogComplete
    )
    if (-not $LogComplete) { return $true }
    return [bool](@($Log) | Where-Object { $_ -match $script:ManifestSwapPattern } | Select-Object -First 1)
}

# Whether a renew run installed a new client certificate. $true only if the run succeeded and its log shows the
# installation and the successful verification of the new certificate; $false if no new certificate is in use: the run
# did not start, or it ended with a known status and its complete log shows no installation, or the previous
# certificate was restored and verified (exit status 5); $null if that cannot be established (unknown outcome, exit
# status 6, a failure after the installation, an incomplete log) and for all other commands.
function Get-WebhookAuthRenewed {
    param([Parameter(Mandatory = $true)]$Result)
    if ($Result.Command -cne 'renew') { return $null }
    if ($Result.RemoteProcessState -ceq 'NotStarted') { return $false }
    if ($Result.RemoteProcessState -cne 'Exited') { return $null }
    $log = @($Result.Log)
    $installed = [bool]($log | Where-Object { $_ -cmatch $script:RenewedPattern } | Select-Object -First 1)
    if ($Result.Succeeded) {
        if ($installed -and $log -ccontains $script:RenewedVerifiedLine) { return $true }
        if (-not $installed -and $Result.LogComplete) { return $false }
        return $null
    }
    if ($Result.ExitCode -eq 5) { return $false }
    if ($Result.ExitCode -in @(1, 2, 3, 4) -and -not $installed -and $Result.LogComplete) { return $false }
    return $null
}

# Maps the exit status of clusterip-webhook-auth.sh (see its header) to the result. Success requires exit status 0 and
# the success marker as the last non-empty log line.
function Set-WebhookAuthExitOutcome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only changes an in-memory object')]
    param([Parameter(Mandatory = $true)]$Result)
    $commandLine = $Result.Arguments -join ' '
    $where = "run $($Result.RunId), log $($Result.RunDirectory)/run.log on the control-plane node"
    $lastLine = Get-WebhookAuthLastLogLine -Log $Result.Log
    $Result.MarkerFound = ($lastLine -ceq $Result.ExpectedMarker)
    $code = $Result.ExitCode
    if ($code -eq 0 -and $Result.MarkerFound) {
        Set-WebhookAuthStatus -Result $Result -Status 'Succeeded' -Reason 'Completed' -Message "'$commandLine' succeeded ($where)"
    }
    elseif ($code -eq 0) {
        Set-WebhookAuthStatus -Result $Result -Status 'Unknown' -Reason 'MarkerMissing' -Message "'$commandLine' exited with status 0, but its last log line is not '$($Result.ExpectedMarker)'; the outcome is unknown ($where)"
    }
    elseif ($code -eq 1 -and $lastLine -and $lastLine.Contains($script:LockMessage)) {
        Set-WebhookAuthStatus -Result $Result -Status 'Busy' -Reason 'Locked' -Message "'$commandLine' did not run: another clusterip-webhook-auth.sh run holds the lock on the control-plane node. Wait until it has finished ($where)"
    }
    elseif ($code -eq 1) {
        Set-WebhookAuthStatus -Result $Result -Status 'Failed' -Reason 'CommandFailed' -Message "'$commandLine' failed: $lastLine ($where)"
    }
    elseif ($code -eq 2) {
        Set-WebhookAuthStatus -Result $Result -Status 'InvalidUsage' -Reason 'InvalidUsage' -Message "clusterip-webhook-auth.sh rejected the arguments '$commandLine' ($where)"
    }
    elseif ($code -eq 3) {
        Set-WebhookAuthStatus -Result $Result -Status 'Refused' -Reason 'Conflict' -Message "'$commandLine' was refused: the kube-apiserver configuration on the control-plane node is custom or incomplete and was not changed. Correct it manually ($where)"
    }
    elseif ($code -eq 4) {
        Set-WebhookAuthStatus -Result $Result -Status 'PrerequisiteMissing' -Reason 'PrerequisiteMissing' -Message "'$commandLine' did not run: root rights or a required tool are missing on the control-plane node ($where)"
    }
    elseif ($code -eq 5 -and $Result.Command -ceq 'ensure-apiserver') {
        Set-WebhookAuthStatus -Result $Result -Status 'Recovered' -Reason 'RolledBack' -Message "'$commandLine' failed: kube-apiserver did not become ready with the admission configuration; the previous manifest was restored and kube-apiserver recovered ($where)"
    }
    elseif ($code -eq 5 -and $Result.Command -ceq 'renew') {
        Set-WebhookAuthStatus -Result $Result -Status 'Recovered' -Reason 'RolledBack' -Message "'$commandLine' failed: webhook authentication did not work with the renewed client certificate; the previous certificate was restored and verified ($where)"
    }
    elseif ($code -eq 6 -and $Result.Command -ceq 'ensure-apiserver') {
        Set-WebhookAuthStatus -Result $Result -Status 'RecoveryUnconfirmed' -Reason 'RecoveryUnconfirmed' -Message ("'$commandLine' failed and the recovery of kube-apiserver could not be confirmed. Check kube-apiserver on the control-plane node now; if it does not start, restore the previous manifest: " +
            "sudo cp -p /etc/kubernetes/k2s-webhook-auth-backup/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml ($where)")
    }
    elseif ($code -eq 6 -and $Result.Command -ceq 'renew') {
        Set-WebhookAuthStatus -Result $Result -Status 'RecoveryUnconfirmed' -Reason 'RecoveryUnconfirmed' -Message ("'$commandLine' failed and the restore of the previous client certificate could not be confirmed. Check webhook authentication on the control-plane node now; " +
            "the previous certificate is kept as /etc/kubernetes/k2s-webhook-auth-backup/client.crt ($where)")
    }
    elseif ($code -eq 130 -or $code -eq 143) {
        Set-WebhookAuthStatus -Result $Result -Status 'Unknown' -Reason 'Interrupted' -Message "'$commandLine' was ended by a signal (exit status $code); its effect is unknown ($where)"
    }
    else {
        Set-WebhookAuthStatus -Result $Result -Status 'Unknown' -Reason 'UnexpectedExitCode' -Message "'$commandLine' ended with the unexpected exit status $code; its effect is unknown ($where)"
    }
    if ($Result.MarkerFound -and -not $Result.Succeeded) {
        $Result.Message += '. Its success marker is not accepted because the exit status is not 0.'
    }
}

# Builds the result of a started run from the last observed state.
function Complete-WebhookAuthRun {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$Start,
        [Parameter(Mandatory = $true)]$Wait
    )
    $state = $Wait.State
    if ($state) {
        $Result.Log = @($state.Log)
        $Result.LogComplete = $state.LogComplete
        if ($state.RemotePid) { $Result.RemotePid = $state.RemotePid }
    }
    # Warnings of the script (for example a failed flush after the manifest was replaced) are kept with every result.
    $Result.Warnings = @($Result.Log | Where-Object { $_ -cmatch $script:WarningPattern })
    if (-not $Result.RemotePid -and $Start.RemotePid) { $Result.RemotePid = $Start.RemotePid }
    $Result.LogTail = @($Result.Log | Select-Object -Last $script:LogTailLines)
    $commandLine = $Result.Arguments -join ' '
    $remotePid = if ($Result.RemotePid) { $Result.RemotePid } else { 'unknown' }
    $where = "run $($Result.RunId), PID $remotePid, log $($Result.RunDirectory)/run.log on the control-plane node"
    if (-not $Wait.Final) {
        $reason = 'NoAnswer'
        $Result.RemoteProcessState = 'Undetermined'
        $note = ''
        if ($state -and $state.State -in @('running', 'orphaned')) {
            $reason = 'Timeout'
            $Result.RemoteProcessState = 'Running'
        }
        elseif ($state -and $state.State -in @('missing', 'starting')) {
            $reason = 'StartUnconfirmed'
            $note = 'It had not started, and it could not be confirmed before the deadline that it can no longer start, so it may still start. '
        }
        elseif ($state) {
            # A final state that was read only after the deadline is not accepted; its log is kept for diagnosis.
            $reason = 'LateResult'
            $note = "A state read after the deadline ($($state.State)$(if ($null -ne $state.ExitCode) { ":$($state.ExitCode)" })) is not accepted. "
        }
        Set-WebhookAuthStatus -Result $Result -Status 'Unknown' -Reason $reason -Message ("The outcome of '$commandLine' is unknown: no result before the local deadline. The remote run may still be running ($where); it was not stopped. " +
            "$note" + "Do not start '$commandLine' again before it has finished. $($Wait.LastProblem)").Trim()
        return $Result
    }
    if ($state.State -eq 'exited') {
        $Result.RemoteProcessState = 'Exited'
        $Result.ExitCode = $state.ExitCode
        Set-WebhookAuthExitOutcome -Result $Result
        if ($Result.Succeeded -and $Result.Warnings.Count -gt 0) {
            # A success with warnings is never reported as a plain success.
            $Result.Message += ". Warnings: $($Result.Warnings -join ' | ')"
        }
    }
    elseif ($state.State -eq 'vanished') {
        $Result.RemoteProcessState = 'Vanished'
        Set-WebhookAuthStatus -Result $Result -Status 'Unknown' -Reason 'ProcessVanished' -Message "The remote run of '$commandLine' ended without an exit status (killed, or the node restarted); its effect is unknown ($where)"
    }
    elseif ($state.State -eq 'abandoned') {
        $Result.RemoteProcessState = 'NotStarted'
        Set-WebhookAuthStatus -Result $Result -Status 'NotStarted' -Reason 'NotStarted' -Message "'$commandLine' did not start on the control-plane node and can no longer start: the run was abandoned before its runner claimed it ($where)"
    }
    else {
        $Result.RemoteProcessState = 'Undetermined'
        Set-WebhookAuthStatus -Result $Result -Status 'Unknown' -Reason 'InvalidRemoteState' -Message "The state of the remote run of '$commandLine' cannot be determined ($($state.State)); it may still be running ($where)"
    }
    return $Result
}

# --- retry ---

# One retry, only for a confirmed failure: the exit file of the first run records exit status 1 (without the lock
# message), so the run and its script have ended. provision, publish and verify are repeated; renew and renew --force
# are repeated as renew, which verifies a valid certificate before any renewal (Invoke-ClusterIPWebhookAuth does not
# report such a verification as a successful renew --force); ensure-apiserver only if its complete log proves that the
# manifest was never replaced. Unknown outcomes, runs that may still be running, runs without exit status and runs that
# did not start are never repeated.
function Get-WebhookAuthRetryArgumentList {
    param([Parameter(Mandatory = $true)]$Result)
    if ($Result.Attempt -ne 1 -or $Result.RemoteProcessState -cne 'Exited' -or $Result.Status -cne 'Failed' -or $Result.ExitCode -ne 1) {
        return $null
    }
    if ($Result.Command -cin @('provision', 'publish', 'verify')) { return , @($Result.Command) }
    if ($Result.Command -ceq 'renew') { return , @('renew') }
    if ($Result.Command -ceq 'ensure-apiserver' -and -not (Test-WebhookAuthManifestSwapStarted -Log $Result.Log -LogComplete $Result.LogComplete)) {
        return , @('ensure-apiserver')
    }
    return $null
}

function Invoke-WebhookAuthAttempt {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$InstallationPath,
        [Parameter(Mandatory = $true)][int]$Attempt
    )
    $result = New-WebhookAuthResult -Arguments $Arguments -Attempt $Attempt
    $commandLine = $Arguments -join ' '
    try {
        $content = Get-WebhookAuthScriptContent -InstallationPath $InstallationPath
        $connection = Get-WebhookAuthConnection
        Copy-WebhookAuthScriptToNode -Connection $connection -Content $content
    }
    catch {
        Set-WebhookAuthStatus -Result $result -Status 'StagingFailed' -Reason 'Staging' -Message "'$commandLine' was not started: $($_.Exception.Message)"
        return $result
    }
    $result.ScriptSha256 = $content.Sha256
    $result.RunId = New-WebhookAuthRunId
    $result.RunDirectory = "$script:RemoteRunsDirectory/$($result.RunId)"
    Write-WebhookAuthLog "[WebhookAuth] Starting '$commandLine' as run $($result.RunId) (attempt $Attempt)"
    $startedAt = Get-WebhookAuthClock
    $start = Start-WebhookAuthRun -Connection $connection -RunId $result.RunId -Sha256 $content.Sha256 -Arguments $Arguments
    if ($start.State -eq 'Busy') {
        $result.BusyRunId = $start.OtherRunId
        $result.BusyPid = $start.RemotePid
        Set-WebhookAuthStatus -Result $result -Status 'Busy' -Reason 'RunInProgress' -Message "'$commandLine' was not started: run $($start.OtherRunId) $($start.Detail) on the control-plane node. Wait until it has finished"
        return $result
    }
    if ($start.State -eq 'Refused') {
        Set-WebhookAuthStatus -Result $result -Status 'NotStarted' -Reason 'StartRefused' -Message "'$commandLine' was not started: the control-plane node refused the run ($($start.Detail))"
        return $result
    }
    # From here on the run may be running: the caller always gets a result with its run id, never an exception.
    try {
        if ($start.State -eq 'Unconfirmed') {
            Write-WebhookAuthLog "[WebhookAuth] The start of run $($result.RunId) was not confirmed; its state is polled before any decision. $($start.Detail)"
        }
        $wait = Wait-WebhookAuthRun -Connection $connection -RunId $result.RunId -StartedAt $startedAt -TimeoutSeconds (Get-WebhookAuthTimeout -Command $Arguments[0])
        return (Complete-WebhookAuthRun -Result $result -Start $start -Wait $wait)
    }
    catch {
        if (-not $result.RemotePid -and $start.RemotePid) { $result.RemotePid = $start.RemotePid }
        $remotePid = if ($result.RemotePid) { $result.RemotePid } else { 'unknown' }
        $result.RemoteProcessState = 'Undetermined'
        Set-WebhookAuthStatus -Result $result -Status 'Unknown' -Reason 'LocalError' -Message ("The outcome of '$commandLine' is unknown: observing the remote run failed locally ($($_.Exception.Message)). " +
            "The remote run may still be running (run $($result.RunId), PID $remotePid, log $($result.RunDirectory)/run.log on the control-plane node); it was not stopped. Do not start '$commandLine' again before it has finished.")
        return $result
    }
}

<#
.SYNOPSIS
Runs a command of clusterip-webhook-auth.sh on the Linux control-plane node.

.DESCRIPTION
Stages the script (see Copy-ClusterIPWebhookAuthScript), starts a verified copy of it as root in a new session on the
node, detached from the SSH connection, and polls its private run directory every 5 seconds with a new SSH connection
until the exit status is written. The local observation deadline is 30 minutes for ensure-apiserver and renew and 10
minutes otherwise; when it passes, the remote run is not stopped and the result is Unknown. A run is never started while
another run is active on the node. A command is retried at most once, and only after the exit status of the first run
shows a failure (exit status 1); unknown outcomes are never retried (see Get-WebhookAuthRetryArgumentList). With -Force,
the result is Succeeded only if a new client certificate was installed and verified: if the retry of a failed renew
--force only verified the current certificate, the result is Failed with reason NotRenewed.

.OUTPUTS
Result object. Status: Succeeded (exit status 0 and K2S-WEBHOOK-AUTH-OK:<command> as last non-empty log line), Failed,
InvalidUsage, Refused, PrerequisiteMissing, Busy, Recovered (rollback confirmed), RecoveryUnconfirmed (manual action
needed), Unknown (the outcome could not be established; RemoteProcessState tells whether the run may still be running),
NotStarted or StagingFailed. Succeeded is true only for Succeeded. RunId, RunDirectory, RemotePid, ExitCode, LogTail and
Message describe the run; Warnings holds the warnings of the script; PreviousAttempt holds the first result after a
retry. Renewed (renew only): $true if a new client certificate was installed and verified, $false if no new certificate
is in use (none was installed, or the previous one was restored), $null if that cannot be established (also for all
other commands, and after a retry if the first run may have installed the certificate that the retry found in use).
#>
function Invoke-ClusterIPWebhookAuth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('provision', 'ensure-apiserver', 'publish', 'verify', 'renew', IgnoreCase = $false)]
        [string]$Command,
        [Parameter(Mandatory = $false, HelpMessage = 'Only with renew: renew the client certificate even if it is valid for more than 30 days')]
        [switch]$Force,
        [Parameter(Mandatory = $false, HelpMessage = 'K2s installation directory that contains the script')]
        [string]$InstallationPath = (Get-KubePath)
    )
    if ($Force -and $Command -cne 'renew') {
        throw '[WebhookAuth] -Force is only valid with the renew command'
    }
    $arguments = if ($Force) { @('renew', '--force') } else { @($Command) }
    $result = Invoke-WebhookAuthAttempt -Arguments $arguments -InstallationPath $InstallationPath -Attempt 1
    $result.Renewed = Get-WebhookAuthRenewed -Result $result
    $retryArguments = Get-WebhookAuthRetryArgumentList -Result $result
    if ($null -ne $retryArguments) {
        Write-WebhookAuthLog "[WebhookAuth] Run $($result.RunId) ended with $($result.Status) ($($result.Reason)) and runs no more; retrying once as '$($retryArguments -join ' ')'"
        $retry = Invoke-WebhookAuthAttempt -Arguments $retryArguments -InstallationPath $InstallationPath -Attempt 2
        $retry.Renewed = Get-WebhookAuthRenewed -Result $retry
        if ($retry.Renewed -ne $true -and $null -eq $result.Renewed) {
            # The first run may have installed the certificate that the retry found in use.
            $retry.Renewed = $null
        }
        $retry.PreviousAttempt = $result
        $result = $retry
    }
    if ($Force -and $result.Succeeded -and $result.Renewed -ne $true) {
        # The retry of a failed renew --force is a plain renew, which only verifies a certificate that is valid for more
        # than 30 days. That verification does not fulfil the request to renew the certificate.
        $outcome = if ($result.Renewed -eq $false) { 'it did not renew the certificate: it only verified the current certificate, which stays in use' } else { 'it cannot be established that it renewed the certificate' }
        $first = if ($result.PreviousAttempt) { " First attempt: $($result.PreviousAttempt.Message)" } else { '' }
        Set-WebhookAuthStatus -Result $result -Status 'Failed' -Reason 'NotRenewed' -Message ("'renew --force' did not renew the kube-apiserver client certificate: run $($result.RunId) ('$($result.Arguments -join ' ')') succeeded, but $outcome." + $first)
    }
    Write-WebhookAuthLog "[WebhookAuth] $($result.Status): $($result.Message)"
    return $result
}

Export-ModuleMember -Function Copy-ClusterIPWebhookAuthScript, Invoke-ClusterIPWebhookAuth
