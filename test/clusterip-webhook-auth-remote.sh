#!/bin/bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# Real-shell tests of the remote protocol of clusterip-webhook-auth.module.psm1. The remote commands that the module
# sends over SSH (staging, start, claim, poll, abandonment, retention of run directories) are built by the module's own
# functions (test/clusterip-webhook-auth-remote.ps1) and executed with /bin/sh against a fake clusterip-webhook-auth.sh,
# as root in private user, mount and PID namespaces: /var/lib and /tmp are private tmpfs mounts, and only the processes
# of the test are visible. The answers of the poll command are classified by the module's own parser and outcome mapping.
# sudo is a shim that runs the command (the namespaces have no working sudo); SSH, sshd and the login shell are not
# involved. Never touches the real /var/lib/k2s, never signals a process it did not start.
# Needs Linux with unshare (util-linux), setsid, flock, and PowerShell (pwsh, or powershell.exe through WSL interop).
# Exit status 77: skipped, with the reason printed.
# shellcheck disable=SC2317,SC2329 # scenario functions and predicates are invoked indirectly
# shellcheck disable=SC2016 # check ... eval '<test>' expands the test when the check runs
set -uo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$REPO_ROOT/lib/modules/windows/node/k2s.node.module/linuxnode/distros/clusterip-webhook-auth.module.psm1"
HELPER="$REPO_ROOT/test/clusterip-webhook-auth-remote.ps1"

skip() { printf 'SKIP: %s\n' "$*"; exit 77; }

passed=0
failed=0
pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$*"; }
fail() { failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
not() { ! "$@"; }

# --- outside the namespaces: prerequisites, commands of the module, classification of the poll answers ---
outer() {
    local tool ps='' module="$MODULE" helper="$HELPER" cases rc=0 name expected actual
    local -a ns
    [[ "$(uname -s)" == Linux ]] || skip 'needs Linux: the remote commands run in Linux user, mount and PID namespaces'
    for tool in unshare setsid flock mount sha256sum stat base64 mktemp timeout head tail od touch mkfifo; do
        command -v "$tool" > /dev/null 2>&1 || skip "missing tool: $tool"
    done
    if command -v pwsh > /dev/null 2>&1; then
        ps=pwsh
    elif command -v powershell.exe > /dev/null 2>&1 && command -v wslpath > /dev/null 2>&1; then
        ps=powershell.exe module=$(wslpath -w "$MODULE") helper=$(wslpath -w "$HELPER")
    else
        skip 'no PowerShell (pwsh, or powershell.exe through WSL interop): the remote commands are built by the module itself'
    fi
    # The work directory must stay visible below the private /tmp of the namespaces.
    WORK=$(mktemp -d /var/tmp/k2s-webhook-auth-remote.XXXXXXXX) || skip 'cannot create a work directory in /var/tmp'
    trap 'rm -rf -- "$WORK"' EXIT
    if ! "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$helper" -Mode Commands -ModulePath "$module" \
        < /dev/null > "$WORK/commands.raw" 2> "$WORK/commands.err"; then
        printf 'FAIL: the module did not build its remote commands\n'
        cat -- "$WORK/commands.err" "$WORK/commands.raw"
        exit 1
    fi
    tr -d '\r' < "$WORK/commands.raw" > "$WORK/commands"
    ns=(unshare --user --map-root-user --mount --pid --fork --mount-proc)
    if (( EUID == 0 )); then ns=(unshare --mount --pid --fork --mount-proc); fi
    if ! "${ns[@]}" /bin/sh -c 'mount -t tmpfs tmpfs /var/lib && mount -t tmpfs tmpfs /tmp' > "$WORK/unshare.log" 2>&1; then
        skip "cannot run as root with private /var/lib and /tmp (${ns[*]}): $(head -c 300 -- "$WORK/unshare.log")"
    fi
    # unshare --fork of util-linux before 2.38 leaves SIGINT and SIGTERM ignored in the child; the processes of a run on
    # a node start with the default dispositions.
    # shellcheck disable=SC2054 # one argument with a comma-separated list of signals
    if env --default-signal=INT,TERM true > /dev/null 2>&1; then ns+=(env --default-signal=INT,TERM); fi
    "${ns[@]}" bash "${BASH_SOURCE[0]}" --in-namespaces "$WORK" < /dev/null || rc=$?
    if [[ ! -f "$WORK/counts" ]]; then
        printf 'FAIL: the tests in the namespaces ended unexpectedly (exit status %s)\n' "$rc"
        exit 1
    fi
    read -r passed failed < "$WORK/counts"
    # The poll answers recorded in the namespaces, classified by the module.
    cases="$WORK/cases.tsv"
    [[ "$ps" != powershell.exe ]] || cases=$(wslpath -w "$WORK/cases.tsv")
    if ! "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$helper" -Mode Classify -ModulePath "$module" -CasesPath "$cases" \
        < /dev/null > "$WORK/classified.raw" 2> "$WORK/classified.err"; then
        fail 'the module classifies the recorded poll answers'
        cat -- "$WORK/classified.err"
    fi
    tr -d '\r' < "$WORK/classified.raw" > "$WORK/classified"
    while IFS=$'\t' read -r name expected; do
        actual=$(grep -m 1 -F -- "$name"$'\t' "$WORK/classified" | cut -f 2)
        # shellcheck disable=SC2053 # the expectation may contain * for a field that is not checked
        if [[ -n "$actual" && "$actual" == $expected ]]; then
            pass "module classification of '$name': $actual"
        else
            fail "module classification of '$name': '$actual', expected '$expected'"
        fi
    done < "$WORK/expected.tsv"
    printf 'Passed=%s Failed=%s (clusterip-webhook-auth-remote.sh; remote commands of the module run with /bin/sh as root in private namespaces)\n' \
        "$passed" "$failed"
    (( failed == 0 ))
}

# --- inside the namespaces ---
B=/var/lib/k2s/webhook-auth
ID_PLACEHOLDER=20000101T000000Z-0000aaaa
SHA_PLACEHOLDER=0000000000000000000000000000000000000000000000000000000000000000
UPLOAD_PLACEHOLDER=/tmp/k2s-webhook-auth-stage.AAAAAAAAAA
NONCE_PLACEHOLDER=ffffffffffffffffffffffffffffffff
declare -A CMD
RUN='' SHA='' UPLOAD='' NONCE='' STATE='' OUT='' ERR='' RC=0 DECOY=''

# remote <command>: runs the command line of the module like sshd with the login shell, here /bin/sh.
remote() {
    local c="${CMD[$1]}"
    c="${c//"$ID_PLACEHOLDER"/$RUN}"
    c="${c//"$SHA_PLACEHOLDER"/$SHA}"
    c="${c//"$UPLOAD_PLACEHOLDER"/$UPLOAD}"
    c="${c//"$NONCE_PLACEHOLDER"/$NONCE}"
    timeout 120 /bin/sh -c "$c"
}
# run_remote <command>: standard output in OUT (what the module parses), error output in ERR, exit status in RC.
run_remote() { RC=0; OUT=$(remote "$1" 2> "$WORK/stderr") || RC=$?; ERR=$(< "$WORK/stderr"); }
new_id() { printf '20261121T080000Z-%s' "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; }
new_nonce() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
# poll <run id>: the answer of the poll command in $WORK/poll.out, its state in STATE.
poll() {
    RUN="$1" NONCE=$(new_nonce)
    remote poll > "$WORK/poll.out" 2> "$WORK/poll.err"
    STATE=$(sed -n -e '/^K2S-RUN-LOG-BEGIN:/q' -e 's/^K2S-RUN-STATE://p' "$WORK/poll.out")
}
# expect_class <name> <arguments> <expected>: the last poll answer, classified by the module after the namespaces ended.
expect_class() {
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$NONCE" "$(base64 -w0 < "$WORK/poll.out")" >> "$WORK/cases.tsv"
    printf '%s\t%s\n' "$1" "$3" >> "$WORK/expected.tsv"
}
state_is() { [[ "$STATE" == "$1" ]] && return 0; printf 'state %s, expected %s\n' "$STATE" "$1"; return 1; }
out_is() { [[ "$OUT" == "$1" ]] && return 0; printf 'output:\n%s\nerror output:\n%s\nexpected:\n%s\n' "$OUT" "$ERR" "$1"; return 1; }
out_has() { [[ "$OUT" == *"$1"* ]] && return 0; printf 'output:\n%s\nerror output:\n%s\n' "$OUT" "$ERR"; return 1; }
rc_is() { [[ "$RC" == "$1" ]] && return 0; printf 'exit status %s, expected %s\n' "$RC" "$1"; return 1; }
owner_mode_is() { [[ "$(stat -c '%U:%G:%a' -- "$2")" == "$1" ]] && return 0; printf '%s: %s\n' "$2" "$(stat -c '%U:%G:%a' -- "$2")"; return 1; }
listing_is() { [[ "$(find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" == "$2 " ]]; }
wait_until() {
    local limit=$(($1 * 20)) i=0
    shift
    while ! "$@"; do
        i=$((i + 1))
        (( i <= limit )) || return 1
        sleep 0.05
    done
}
# Whether any process has $1 as an argument (the runner of a run) or $2 in its environment (the script of a run).
# Reads /proc with builtins only, so that the test does not find its own helper processes.
process_with() {
    local f a
    local -a words
    for f in /proc/[0-9]*/"$1"; do
        { mapfile -d '' -t words < "$f"; } 2> /dev/null || continue
        for a in ${words[@]+"${words[@]}"}; do [[ "$a" != "$2" ]] || return 0; done
    done
    return 1
}
run_ended() { ! process_with cmdline "$1" && ! process_with environ "K2S_WEBHOOK_AUTH_RUN=$1"; }
# Whether process $1 has ended (a zombie that its parent has not reaped yet has an empty command line).
gone() { local c; { c=$(tr -d '\0' < "/proc/$1/cmdline"); } 2> /dev/null || return 0; [[ -z "$c" ]]; }
# Whether process $1 has no open pipe or socket (the start command of the module runs it detached from the SSH channel).
detached() {
    local fd target
    [[ -d "/proc/$1/fd" ]] || { printf 'process %s not found\n' "$1"; return 1; }
    for fd in /proc/"$1"/fd/*; do
        target=$(readlink -- "$fd") || continue
        case "$target" in pipe:* | socket:*) printf 'process %s: %s -> %s\n' "$1" "${fd##*/}" "$target"; return 1 ;; esac
    done
}
# shellcheck disable=SC2086 # the fields of /proc/<pid>/stat after the command name are split on purpose
session_of() { local stat; stat=$(< "/proc/$1/stat") && stat="${stat##*) }" && set -- $stat && printf '%s\n' "$4"; }
mode() { printf '%s\n' "$1" > "$WORK/control/mode"; }
release() { : > "$WORK/control/release.$1"; }
ran_count() { if [[ -f "$WORK/control/ran.$1" ]]; then wc -l < "$WORK/control/ran.$1"; else printf '0\n'; fi; }
# make_run <id> <kind> <age in days>: a run directory as a run leaves it. kind: completed, abandoned, vanished.
make_run() {
    local d="$B/runs/$1" marker
    mkdir -m 0700 -- "$d"
    case "$2" in
        completed)
            cp -- "$B/bin/clusterip-webhook-auth.sh" "$d/clusterip-webhook-auth.sh"
            : > "$d/alive"
            printf '4242\n' > "$d/pid"
            printf 'old log\n' > "$d/run.log"
            printf '0\n' > "$d/exit"
            marker="$d/exit" ;;
        abandoned) : > "$d/abandoned"; marker="$d/abandoned" ;;
        vanished) : > "$d/alive"; printf '4242\n' > "$d/pid"; marker="$d/pid" ;;
    esac
    touch -d "@$(($(date +%s) - $3 * 86400))" -- "$marker"
}

# --- end of helpers ---

write_fake_script() {
    cat > "$1" <<'EOF'
#!/bin/sh
# Fake clusterip-webhook-auth.sh of test/clusterip-webhook-auth-remote.sh: $K2S_TEST_CONTROL/mode.<run id>, else
# $K2S_TEST_CONTROL/mode, selects what it does.
c=$K2S_TEST_CONTROL
r=$K2S_WEBHOOK_AUTH_RUN
echo $$ >> "$c/ran.$r"
mode=$(cat "$c/mode.$r" 2>/dev/null || cat "$c/mode")
echo "[ClusterIPWebhookAuth] fake run $r: $*"
release() { : > "$c/waiting.$r"; while [ ! -e "$c/release.$r" ]; do sleep 0.05; done; }
case $mode in
    ok) echo "K2S-WEBHOOK-AUTH-OK:$1"; exit 0 ;;
    fail) echo '[ClusterIPWebhookAuth] ERROR: injected failure'; exit 1 ;;
    wait) release; echo "K2S-WEBHOOK-AUTH-OK:$1"; exit 0 ;;
    forge) release; cat "$c/forge.$r"; exit 1 ;;
    state-lines) printf '%s\n' 'K2S-RUN-STATE:exited:0' 'K2S-RUN-PID:1' "K2S-WEBHOOK-AUTH-OK:$1"; release; exit 1 ;;
    marker-then-text) echo "K2S-WEBHOOK-AUTH-OK:$1"; echo '[ClusterIPWebhookAuth] output after the marker'; exit 0 ;;
    no-newline) printf 'K2S-WEBHOOK-AUTH-OK:%s' "$1"; exit 0 ;;
    big) head -c 1100000 /dev/zero | tr '\0' x; echo; echo "K2S-WEBHOOK-AUTH-OK:$1"; exit 0 ;;
    child) sleep 600 & echo $! > "$c/child.$r"; echo "K2S-WEBHOOK-AUTH-OK:$1"; exit 0 ;;
    child-noenv) env -u K2S_WEBHOOK_AUTH_RUN sleep 600 & echo $! > "$c/child.$r"; release; echo "K2S-WEBHOOK-AUTH-OK:$1"; exit 0 ;;
    child-nolock) sleep 600 8>&- & echo $! > "$c/child.$r"; release; echo "K2S-WEBHOOK-AUTH-OK:$1"; exit 0 ;;
esac
echo "unknown mode $mode"
exit 99
EOF
}

# 1. Staging: private upload directory, copy (what scp does), verified promotion as root.
scenario_staging() {
    local upload_dir staged_sha
    run_remote upload
    UPLOAD="$OUT"
    check 'staging: the upload directory is a new private directory in /tmp' \
        eval '[[ "$UPLOAD" =~ ^/tmp/k2s-webhook-auth-stage\.[A-Za-z0-9]{10}$ && "$(stat -c %a -- "$UPLOAD")" == 700 ]]'
    cp -- "$WORK/fake.sh" "$UPLOAD/clusterip-webhook-auth.sh"
    run_remote promote
    check 'staging: the script is promoted after its checksum was verified' out_is "K2S-STAGE-OK:$SHA"
    check 'staging: /var/lib/k2s/webhook-auth, bin and runs are root:root 0700' \
        eval 'owner_mode_is root:root:700 "$B" && owner_mode_is root:root:700 "$B/bin" && owner_mode_is root:root:700 "$B/runs"'
    check 'staging: the staged script is root:root 0700 with the expected checksum' \
        eval 'owner_mode_is root:root:700 "$B/bin/clusterip-webhook-auth.sh" && [[ "$(sha256sum < "$B/bin/clusterip-webhook-auth.sh" | cut -c1-64)" == "$SHA" ]]'
    check 'staging: the lock file is a regular root file with one link' eval '[[ -f "$B/.lock" && ! -L "$B/.lock" && "$(stat -c %u:%g:%h -- "$B/.lock")" == 0:0:1 ]]'
    check 'staging: the upload directory is removed' not test -e "$UPLOAD"
    check 'staging: no temporary file remains in bin' listing_is "$B/bin" 'clusterip-webhook-auth.sh'
    # A tampered upload is refused, removed and never installed.
    run_remote upload
    UPLOAD="$OUT"
    upload_dir="$UPLOAD"
    printf '#!/bin/sh\necho tampered\n' > "$UPLOAD/clusterip-webhook-auth.sh"
    run_remote promote
    check 'staging: a tampered upload is refused' eval '[[ "$RC" == 34 && "$OUT" == K2S-STAGE-ERROR:upload-checksum:* ]]'
    staged_sha=$(sha256sum < "$B/bin/clusterip-webhook-auth.sh" | cut -c1-64)
    check 'staging: the refused upload is not installed' test "$staged_sha" = "$SHA"
    check 'staging: the refused upload directory is removed' not test -e "$upload_dir"
    # The cleanup command removes an upload directory that was not promoted.
    run_remote upload
    UPLOAD="$OUT"
    run_remote cleanup
    check 'staging: the cleanup command removes the upload directory' not test -e "$UPLOAD"
    # A layout directory with other permissions is refused and never repaired.
    chmod 0755 -- "$B/runs"
    UPLOAD=$(remote upload)
    cp -- "$WORK/fake.sh" "$UPLOAD/clusterip-webhook-auth.sh"
    run_remote promote
    check 'staging: a layout directory with other permissions is refused' eval "rc_is 37 && out_is K2S-STAGE-ERROR:directory-permissions:$B/runs:root:root:755"
    check 'staging: the refused directory is not repaired' owner_mode_is root:root:755 "$B/runs"
    chmod 0700 -- "$B/runs"
}

# Every run executes its own copy, verified against the checksum of its start: a start with the checksum of an earlier
# staging is refused after a new staging.
scenario_verified_copy() {
    local old_sha="$SHA" id
    printf '# changed\n' >> "$WORK/fake.sh"
    SHA=$(sha256sum < "$WORK/fake.sh" | cut -c1-64)
    UPLOAD=$(remote upload)
    cp -- "$WORK/fake.sh" "$UPLOAD/clusterip-webhook-auth.sh"
    run_remote promote
    check 'verified copy: a changed script is staged' out_is "K2S-STAGE-OK:$SHA"
    id=$(new_id)
    RUN="$id" SHA="$old_sha"
    run_remote start-verify
    check 'verified copy: a start with the checksum of the earlier staging is refused' eval 'rc_is 45 && out_is K2S-RUN-ERROR:script-checksum'
    check 'verified copy: the refused start leaves no run directory' not test -e "$B/runs/$id"
    sed -i '$d' -- "$WORK/fake.sh"
    SHA="$old_sha"
    UPLOAD=$(remote upload)
    cp -- "$WORK/fake.sh" "$UPLOAD/clusterip-webhook-auth.sh"
    run_remote promote
    check 'verified copy: the original script is staged again' out_is "K2S-STAGE-OK:$SHA"
}

# 2, 5, 6. A detached start, polls while the run is running and after it ended.
scenario_start() {
    local id pid
    mode wait
    id=$(new_id)
    RUN="$id"
    run_remote start-verify
    pid=$(head -c 16 -- "$B/runs/$id/pid" 2>/dev/null)
    check 'start: the run is prepared and its runner started' out_is "K2S-RUN-PREPARED:$id
K2S-RUN-STARTED:$pid"
    check 'start: the start command returns while the run is still running' eval '[[ "$RC" == 0 && ! -e "$B/runs/$id/exit" ]]'
    check 'start: the script of the run runs' wait_until 10 test -e "$WORK/control/waiting.$id"
    check 'start: the runner leads its own session' test "$(session_of "$pid")" = "$pid"
    check 'start: the runner and the script hold no pipe or socket, so nothing ties them to the SSH channel' \
        eval 'detached "$pid" && detached "$(head -n 1 -- "$WORK/control/ran.$id")"'
    check 'start: the command line of the runner carries the run id' process_with cmdline "$id"
    check 'start: the script of the run carries K2S_WEBHOOK_AUTH_RUN' process_with environ "K2S_WEBHOOK_AUTH_RUN=$id"
    check 'start: the run executes its own verified copy of the staged script' \
        eval 'cmp -s -- "$B/runs/$id/clusterip-webhook-auth.sh" "$WORK/fake.sh" && owner_mode_is root:root:700 "$B/runs/$id/clusterip-webhook-auth.sh"'
    check 'start: the run directory is root:root 0700' owner_mode_is root:root:700 "$B/runs/$id"
    poll "$id"
    check 'poll while running: running with the PID of the runner' state_is "running:$pid"
    check 'poll while running: the log is framed with the nonce of this poll' \
        eval 'grep -q -x -F -- "K2S-RUN-LOG-BEGIN:$NONCE" "$WORK/poll.out" && grep -q -x -F -- "K2S-RUN-LOG-END:$NONCE" "$WORK/poll.out"'
    expect_class 'poll while running' verify 'running||True|-|-|-|1'
    release "$id"
    check 'completion: the exit status is written' wait_until 10 test -e "$B/runs/$id/exit"
    poll "$id"
    check 'poll after completion: exited with status 0' state_is exited:0
    expect_class 'poll after completion' verify 'exited|0|True|Succeeded|Completed|True|2'
    check 'completion: the run directory holds exactly the files of a run' listing_is "$B/runs/$id" 'alive clusterip-webhook-auth.sh exit pid run.log'
    check 'completion: no process of the run remains' wait_until 10 run_ended "$id"
}

# 3. Concurrent starts: exactly one run starts, the other is refused as busy and leaves nothing behind.
scenario_concurrent_starts() {
    local i a b job_a winner loser started busy=0 single=0
    mode wait
    for i in 1 2 3 4 5 6; do
        a=$(new_id) b=$(new_id)
        (RUN="$a"; remote start-verify > "$WORK/start.$a" 2>&1; printf '%s\n' "$?" > "$WORK/rc.$a") &
        job_a=$!
        (RUN="$b"; remote start-verify > "$WORK/start.$b" 2>&1; printf '%s\n' "$?" > "$WORK/rc.$b") &
        wait "$job_a" "$!"
        started=$(cat -- "$WORK/start.$a" "$WORK/start.$b" | grep -c '^K2S-RUN-PREPARED:')
        if grep -q '^K2S-RUN-PREPARED:' "$WORK/start.$a"; then winner="$a" loser="$b"; else winner="$b" loser="$a"; fi
        (( started == 1 )) && single=$((single + 1))
        if [[ "$(< "$WORK/rc.$loser")" == 10 && "$(< "$WORK/start.$loser")" =~ ^K2S-RUN-BUSY:$winner:([0-9]+|starting)$ && ! -e "$B/runs/$loser" ]]; then
            busy=$((busy + 1))
        else
            printf 'round %s: winner %s, loser %s: %s (exit status %s)\n' "$i" "$winner" "$loser" "$(< "$WORK/start.$loser")" "$(< "$WORK/rc.$loser")"
        fi
        wait_until 10 test -e "$WORK/control/waiting.$winner"
        release "$winner"
        wait_until 10 test -e "$B/runs/$winner/exit"
        wait_until 10 run_ended "$winner"
    done
    check 'concurrent starts: exactly one of two simultaneous starts runs (6 rounds)' test "$single" = 6
    check 'concurrent starts: the other is refused as busy with the run id of the winner and creates no run directory' test "$busy" = 6
}

# The same run claimed by several runners at once: exactly one claims it, and the script runs once.
scenario_double_claim() {
    local i id once=0
    local -a jobs
    mode ok
    for i in 1 2 3 4 5 6 7 8; do
        id=$(new_id)
        RUN="$id"
        run_remote prepare-verify
        [[ "$OUT" == *"K2S-RUN-PREPARED:$id" ]] || { fail "double claim: the run $id was not prepared: $OUT"; continue; }
        jobs=()
        for _ in 1 2 3 4; do remote runner-verify & jobs+=("$!"); done
        wait "${jobs[@]}"
        wait_until 10 test -e "$B/runs/$id/exit"
        wait_until 10 run_ended "$id"
        if [[ "$(ran_count "$id")" == 1 && "$(head -c 16 -- "$B/runs/$id/exit")" == 0 ]] && grep -q -x '[0-9]*' "$B/runs/$id/pid"; then
            once=$((once + 1))
        else
            printf 'run %s: script ran %s times\n' "$id" "$(ran_count "$id")"
        fi
    done
    check 'claim: of four simultaneous runners for one run, exactly one claims it and the script runs once (8 runs)' test "$once" = 8
}

# 4. Claim against abandonment: a run is claimed by its runner or abandoned, never both, and an abandoned run never runs.
check_claim_or_abandon() {
    local id="$1" answer="$2" d="$B/runs/$1"
    if [[ "$answer" == K2S-RUN-ABANDON:done ]]; then
        [[ -f "$d/abandoned" && ! -e "$d/pid" && ! -e "$d/exit" && ! -e "$d/run.log" && "$(ran_count "$id")" == 0 ]] && return 0
    elif [[ "$answer" == K2S-RUN-ABANDON:claimed ]]; then
        [[ ! -e "$d/abandoned" && -f "$d/pid" && "$(head -c 16 -- "$d/exit" 2>/dev/null)" == 0 && "$(ran_count "$id")" == 1 ]] && return 0
    fi
    printf 'run %s: answer %s, entries: %s, script ran %s times\n' "$id" "$answer" "$(find "$d" -mindepth 1 -maxdepth 1 -printf '%f ')" "$(ran_count "$id")"
    return 1
}
scenario_claim_or_abandon() {
    local i id answer job consistent=0 claimed=0 abandoned=0
    mode ok
    for i in $(seq 1 20); do
        id=$(new_id)
        RUN="$id"
        run_remote prepare-verify
        # Random delays of up to 0.19 s on both sides vary which of the two takes the lock first.
        (RUN="$id"; sleep "$(printf '0.%02d' $((RANDOM % 20)))"; remote abandon > "$WORK/abandon.$id" 2>&1) &
        job=$!
        (sleep "$(printf '0.%02d' $((RANDOM % 20)))"; remote runner-verify) &
        wait "$job" "$!"
        wait_until 10 run_ended "$id"
        answer=$(< "$WORK/abandon.$id")
        if check_claim_or_abandon "$id" "$answer"; then consistent=$((consistent + 1)); fi
        [[ "$answer" != K2S-RUN-ABANDON:done ]] || abandoned=$((abandoned + 1))
        [[ "$answer" != K2S-RUN-ABANDON:claimed ]] || claimed=$((claimed + 1))
    done
    check "claim against abandonment: every one of 20 races ends claimed (and ran once) or abandoned (and never ran), never both ($claimed claimed, $abandoned abandoned)" \
        test "$consistent" = 20
    # Abandoned first: a late runner never starts the run.
    id=$(new_id)
    RUN="$id"
    run_remote prepare-verify
    run_remote abandon
    check 'abandonment: an unclaimed run is marked as abandoned' out_is K2S-RUN-ABANDON:done
    run_remote runner-verify
    wait_until 10 run_ended "$id"
    check 'abandonment: a late runner refuses the abandoned run and the script never runs' check_claim_or_abandon "$id" K2S-RUN-ABANDON:done
    run_remote abandon
    check 'abandonment: abandoning again changes nothing' eval 'out_is K2S-RUN-ABANDON:done && listing_is "$B/runs/$id" "abandoned clusterip-webhook-auth.sh"'
    poll "$id"
    check 'abandonment: the poll reports the run as abandoned' state_is abandoned
    expect_class 'abandoned run' verify 'abandoned||False|NotStarted|NotStarted|False|0'
    # Never prepared: abandoning creates the run directory with the marker, so a late preparation fails.
    id=$(new_id)
    RUN="$id"
    run_remote abandon
    run_remote prepare-verify
    check 'abandonment: a run abandoned before its preparation can no longer be prepared' eval 'rc_is 47 && out_is K2S-RUN-ERROR:run-directory'
    # A run that its runner has not claimed for 120 s is abandoned by the next start, and its late runner never starts it.
    id=$(new_id)
    RUN="$id"
    run_remote prepare-verify
    RUN=$(new_id)
    run_remote start-verify
    check 'abandonment: a start within 120 s of an unclaimed preparation is refused' eval "rc_is 10 && out_is K2S-RUN-BUSY:$id:starting"
    touch -d "@$(($(date +%s) - 200))" -- "$B/runs/$id"
    RUN=$(new_id)
    run_remote start-verify
    check 'abandonment: the next start marks an unclaimed run older than 120 s as abandoned and starts' \
        eval "out_has K2S-RUN-PREPARED:$RUN && [[ -f $B/runs/$id/abandoned ]]"
    wait_until 10 run_ended "$RUN"
    RUN="$id"
    run_remote runner-verify
    wait_until 10 run_ended "$id"
    check 'abandonment: the late runner of the abandoned run never starts it' check_claim_or_abandon "$id" K2S-RUN-ABANDON:done
    # Claimed first: abandoning reports the claim and changes nothing.
    mode wait
    id=$(new_id)
    RUN="$id"
    run_remote start-verify
    wait_until 10 test -e "$WORK/control/waiting.$id"
    run_remote abandon
    check 'abandonment: a claimed run is reported as claimed and not marked' eval 'out_is K2S-RUN-ABANDON:claimed && [[ ! -e "$B/runs/$id/abandoned" ]]'
    check 'abandonment: the claimed run keeps running' process_with environ "K2S_WEBHOOK_AUTH_RUN=$id"
    release "$id"
    wait_until 10 run_ended "$id"
    poll "$id"
    expect_class 'claimed run after an abandonment attempt' verify 'exited|0|True|Succeeded|Completed|True|2'
}

# 7, 8, 9, 10. Killed runner, missing exit status, stale PID and reused PID.
scenario_process_identity() {
    local id other pid d kind child
    sleep 600 &
    DECOY=$!
    mode wait
    id=$(new_id)
    RUN="$id"
    run_remote start-verify
    wait_until 10 test -e "$WORK/control/waiting.$id"
    pid=$(head -c 16 -- "$B/runs/$id/pid")
    kill -KILL "$pid"
    check 'killed runner: the runner is gone' wait_until 10 gone "$pid"
    check 'killed runner: the script still holds the lock on alive that it inherited' not flock -n "$B/runs/$id/alive" true
    poll "$id"
    check 'killed runner: the poll reports a run whose runner ended while a process of the run is alive' state_is "orphaned:$pid"
    expect_class 'killed runner, script alive' verify 'orphaned||True|-|-|-|1'
    other=$(new_id)
    RUN="$other"
    run_remote start-verify
    check 'killed runner: a new run is refused while a process of the orphaned run is alive' eval "rc_is 10 && out_is 'K2S-RUN-BUSY:$id:orphaned'"
    check 'killed runner: the refused run leaves no run directory' not test -e "$B/runs/$other"
    # PID reuse: the PID file names an unrelated process while the script of the run is still alive.
    printf '%s\n' "$DECOY" > "$B/runs/$id/pid"
    poll "$id"
    check 'reused PID: an unrelated process with the PID of the runner is not taken for the runner' state_is "orphaned:$DECOY"
    release "$id"
    check 'killed runner: the script ends' wait_until 10 run_ended "$id"
    printf '%s\n' "$pid" > "$B/runs/$id/pid"
    poll "$id"
    check 'missing exit status: a run without exit status and without live process has vanished' state_is "vanished:$pid"
    check 'missing exit status: the log of the vanished run contains the success marker of the script' grep -q -x -F K2S-WEBHOOK-AUTH-OK:verify "$WORK/poll.out"
    expect_class 'vanished run with a success marker in its log' verify 'vanished||True|Unknown|ProcessVanished|False|2'
    # Stale PID reused by an unrelated process after the run ended: neither running nor busy.
    printf '%s\n' "$DECOY" > "$B/runs/$id/pid"
    poll "$id"
    check 'reused PID: a run whose PID now belongs to an unrelated process has vanished' state_is "vanished:$DECOY"
    expect_class 'stale PID reused by an unrelated process' verify 'vanished||True|Unknown|ProcessVanished|False|2'
    # A stale PID of a process that no longer exists.
    d="$B/runs/$(new_id)"
    make_run "${d##*/}" vanished 0
    printf '999999\n' > "$d/pid"
    poll "${d##*/}"
    check 'stale PID: a run with the PID of a process that no longer exists has vanished' state_is vanished:999999
    mode ok
    other=$(new_id)
    RUN="$other"
    run_remote start-verify
    check 'stale and reused PIDs: a new run starts' out_has "K2S-RUN-PREPARED:$other"
    wait_until 10 run_ended "$other"
    # Either mark of a process of the run suffices: the lock on alive (child without the environment marker) and the
    # environment marker (child that closed alive).
    for kind in child-noenv child-nolock; do
        id=$(new_id)
        printf '%s\n' "$kind" > "$WORK/control/mode.$id"
        RUN="$id"
        run_remote start-verify
        wait_until 10 test -e "$WORK/control/waiting.$id"
        pid=$(head -c 16 -- "$B/runs/$id/pid")
        child=$(< "$WORK/control/child.$id")
        kill -KILL "$pid"
        wait_until 10 gone "$pid"
        release "$id"
        wait_until 10 gone "$(head -n 1 -- "$WORK/control/ran.$id")"
        poll "$id"
        if [[ "$kind" == child-noenv ]]; then
            check 'process of the run without environment marker: found by the lock on alive that it inherited' state_is "orphaned:$pid"
        else
            check 'process of the run that closed alive: found by its environment marker' state_is "orphaned:$pid"
        fi
        other=$(new_id)
        RUN="$other"
        run_remote start-verify
        check "$kind: no new run starts while the last process of the run is alive" eval "rc_is 10 && out_is K2S-RUN-BUSY:$id:orphaned"
        kill -KILL "$child"
        wait_until 10 gone "$child"
        poll "$id"
        check "$kind: the run has vanished once its last process ended" state_is "vanished:$pid"
    done
    check 'reused PID: the unrelated process is not signalled' not gone "$DECOY"
}

# 11, 12. Log framing with a new random nonce per poll; log content can never end the frame or forge a result.
scenario_log_framing() {
    local id first first_frame
    mode wait
    id=$(new_id)
    RUN="$id"
    run_remote start-verify
    wait_until 10 test -e "$WORK/control/waiting.$id"
    poll "$id"
    first="$NONCE"
    first_frame=$(sed -n 's/^K2S-RUN-LOG-BEGIN://p' "$WORK/poll.out")
    poll "$id"
    check 'framing: every poll frames the log with the nonce that it was given' \
        test "$first_frame|$(sed -n 's/^K2S-RUN-LOG-BEGIN://p' "$WORK/poll.out")" = "$first|$NONCE"
    check 'framing: the nonces of two polls differ' test "$first" != "$NONCE"
    check 'framing: the end marker follows the complete log' eval '[[ "$(tail -n 1 "$WORK/poll.out")" == "K2S-RUN-LOG-END:$NONCE" ]]'
    release "$id"
    wait_until 10 run_ended "$id"
    # The script writes lines of the poll protocol with the nonce of an earlier poll, then fails.
    id=$(new_id)
    printf 'forge\n' > "$WORK/control/mode.$id"
    RUN="$id"
    run_remote start-verify
    wait_until 10 test -e "$WORK/control/waiting.$id"
    poll "$id"
    first="$NONCE"
    printf '%s\n' "K2S-RUN-LOG-END:$first" 'K2S-RUN-STATE:exited:0' "K2S-RUN-LOG-BEGIN:$first" 'K2S-WEBHOOK-AUTH-OK:verify' > "$WORK/control/forge.$id"
    release "$id"
    wait_until 10 test -e "$B/runs/$id/exit"
    poll "$id"
    check 'forged frame: the state comes from the exit status, not from the log' state_is exited:1
    expect_class 'log with a forged frame and success marker, exit status 1' verify 'exited|1|True|Failed|CommandFailed|True|5'
    # State lines and a success marker in the log of a run that is still running.
    id=$(new_id)
    printf 'state-lines\n' > "$WORK/control/mode.$id"
    RUN="$id"
    run_remote start-verify
    wait_until 10 test -e "$WORK/control/waiting.$id"
    poll "$id"
    check 'forged state: a run that is running is reported as running although its log says exited' state_is "running:$(head -c 16 -- "$B/runs/$id/pid")"
    expect_class 'running run whose log contains state lines and a success marker' verify 'running||True|-|-|-|4'
    release "$id"
    wait_until 10 test -e "$B/runs/$id/exit"
    poll "$id"
    expect_class 'log ending with a success marker, exit status 1' verify 'exited|1|True|Failed|CommandFailed|True|4'
    # A marker followed by more output, a log without final line break, and a log beyond the limit of the poll.
    for mode in marker-then-text no-newline big; do
        id=$(new_id)
        printf '%s\n' "$mode" > "$WORK/control/mode.$id"
        RUN="$id"
        run_remote start-verify
        wait_until 10 test -e "$B/runs/$id/exit"
        wait_until 10 run_ended "$id"
        poll "$id"
        case "$mode" in
            marker-then-text) expect_class 'success marker followed by output, exit status 0' verify 'exited|0|True|Unknown|MarkerMissing|False|3' ;;
            no-newline) expect_class 'log without final line break' verify 'exited|0|True|Succeeded|Completed|True|2' ;;
            big)
                check 'framing: the poll sends at most the log limit of the module' \
                    eval '(( $(sed -n "s/^K2S-RUN-LOG-SIZE://p" "$WORK/poll.out") > 1048576 && $(wc -c < "$WORK/poll.out") < 1048576 + 2048 ))'
                expect_class 'log larger than the limit' verify 'exited|0|False|Succeeded|Completed|True|*' ;;
        esac
    done
}

# 16. States that do not allow a decision.
scenario_unknown_states() {
    local id d
    id=$(new_id)
    poll "$id"
    check 'unknown: a run that does not exist is missing' state_is missing
    expect_class 'missing run' verify 'missing||False|-|-|-|0'
    RUN="$id"
    run_remote prepare-verify
    poll "$id"
    check 'unknown: a prepared run that its runner has not claimed is starting' state_is starting
    expect_class 'prepared, not claimed' verify 'starting||False|-|-|-|0'
    run_remote abandon
    d="$B/runs/$(new_id)"
    make_run "${d##*/}" vanished 0
    printf 'x1\n' > "$d/pid"
    poll "${d##*/}"
    check 'unknown: a non-numeric PID is reported as invalid' state_is invalid-pid
    expect_class 'invalid PID' verify 'invalid-pid||False|Unknown|InvalidRemoteState|False|0'
    d="$B/runs/$(new_id)"
    make_run "${d##*/}" completed 0
    printf 'zero\n' > "$d/exit"
    poll "${d##*/}"
    check 'unknown: a non-numeric exit status is reported as it is' state_is exited:zero
    expect_class 'non-numeric exit status' verify 'invalid-state||True|Unknown|InvalidRemoteState|False|1'
    id=$(new_id)
    printf 'not a directory\n' > "$B/runs/$id"
    poll "$id"
    check 'unknown: a run path that is no directory is invalid' state_is invalid-directory
    expect_class 'run path that is a file' verify 'invalid-directory||False|Unknown|InvalidRemoteState|False|0'
    rm -f -- "$B/runs/$id"
}

# 13. Planted symbolic links are never followed for a decision or a write.
scenario_symlinks() {
    local id target before
    # The target looks like a run that its runner has not claimed yet, with a copy of the script.
    mkdir -p /var/lib/k2s-planted/run
    cp -- "$B/bin/clusterip-webhook-auth.sh" /var/lib/k2s-planted/run/clusterip-webhook-auth.sh
    before=$(find /var/lib/k2s-planted -printf '%p %y %s %T@\n' | LC_ALL=C sort)
    id=$(new_id)
    ln -s /var/lib/k2s-planted/run "$B/runs/$id"
    poll "$id"
    check 'symlink: a linked run directory is reported as invalid, its target is not read' state_is invalid-directory
    expect_class 'linked run directory' verify 'invalid-directory||False|Unknown|InvalidRemoteState|False|0'
    RUN="$id"
    run_remote runner-verify
    sleep 1
    run_remote abandon
    check 'symlink: abandoning a linked run directory is refused' eval 'rc_is 47 && out_is K2S-RUN-ABANDON:error:run-directory'
    mode ok
    RUN=$(new_id)
    run_remote start-verify
    check 'symlink: the busy scan ignores a linked run directory' out_has "K2S-RUN-PREPARED:$RUN"
    wait_until 10 run_ended "$RUN"
    check 'symlink: the runner, the abandonment and the busy scan wrote nothing through the linked run directory' \
        test "$(find /var/lib/k2s-planted -printf '%p %y %s %T@\n' | LC_ALL=C sort)" = "$before"
    check 'symlink: the script never ran for the linked run' test "$(ran_count "$id")" = 0
    # A dangling symbolic link as abandoned marker means abandoned and is never written through.
    id=$(new_id)
    RUN="$id"
    run_remote prepare-verify
    ln -s /var/lib/k2s-nowhere "$B/runs/$id/abandoned"
    run_remote runner-verify
    sleep 1
    check 'symlink: a runner refuses a run whose abandoned marker is a dangling link' eval '[[ ! -e "$B/runs/$id/pid" && "$(ran_count "$id")" == 0 ]]'
    poll "$id"
    check 'symlink: the poll reports a dangling abandoned marker as abandoned' state_is abandoned
    run_remote abandon
    check 'symlink: abandoning again does not write through the dangling marker' eval 'out_is K2S-RUN-ABANDON:done && [[ -L "$B/runs/$id/abandoned" && ! -e /var/lib/k2s-nowhere ]]'
    # alive as a link to a FIFO and as a FIFO: never opened, so no poll or start can hang on it.
    mkfifo /var/lib/k2s-fifo
    id=$(new_id)
    make_run "$id" vanished 0
    rm -f -- "$B/runs/$id/alive"
    ln -s /var/lib/k2s-fifo "$B/runs/$id/alive"
    poll "$id"
    check 'symlink: alive linked to a FIFO is not opened; the run has vanished' state_is vanished:4242
    target=$(new_id)
    make_run "$target" vanished 0
    rm -f -- "$B/runs/$target/alive"
    mkfifo "$B/runs/$target/alive"
    poll "$target"
    check 'symlink: a FIFO alive is not opened; the run has vanished' state_is vanished:4242
    RUN=$(new_id)
    run_remote start-verify
    check 'symlink: the busy scan does not hang on FIFOs and starts a new run' out_has "K2S-RUN-PREPARED:$RUN"
    wait_until 10 run_ended "$RUN"
}

# 14. The lock serializes staging, preparation and abandonment; the poll never takes it; a planted lock file is refused.
scenario_lock() {
    local id locker job content
    # One process holds the lock, so that ending it releases the lock.
    (exec 9> "$B/.lock" && flock 9 && exec sleep 300) &
    locker=$!
    wait_until 10 not flock -n "$B/.lock" true
    id=$(new_id)
    (RUN="$id"; remote prepare-verify > "$WORK/prepare.$id" 2>&1) &
    job=$!
    sleep 1
    check 'lock: the preparation waits while another step holds the lock' eval '[[ ! -e "$B/runs/$id" ]] && kill -0 "$job"'
    poll "$id"
    check 'lock: the poll does not wait for the lock' state_is missing
    RUN="$id"
    run_remote abandon
    check 'lock: abandoning gives up after its lock timeout and changes nothing' eval 'rc_is 48 && out_is K2S-RUN-ABANDON:error:lock && [[ ! -e "$B/runs/$id" ]]'
    kill -KILL "$locker"
    wait "$job"
    check 'lock: the preparation continues once the lock is released' \
        eval '[[ "$(< "$WORK/prepare.$id")" == *"K2S-RUN-PREPARED:$id" ]] || { printf "preparation: %s\n" "$(< "$WORK/prepare.$id")"; false; }'
    RUN="$id"
    run_remote abandon
    # A lock file that another user could have planted is refused, and its target is never truncated.
    printf 'precious\n' > /var/lib/k2s-target
    rm -f -- "$B/.lock"
    ln -s /var/lib/k2s-target "$B/.lock"
    RUN=$(new_id)
    run_remote prepare-verify
    check 'lock: a symbolic link as lock file is refused by the preparation' eval 'rc_is 48 && out_is K2S-RUN-ERROR:lock-file'
    run_remote abandon
    check 'lock: a symbolic link as lock file is refused by the abandonment' eval 'rc_is 48 && out_is K2S-RUN-ABANDON:error:lock-file'
    UPLOAD=$(remote upload)
    cp -- "$WORK/fake.sh" "$UPLOAD/clusterip-webhook-auth.sh"
    run_remote promote
    check 'lock: a symbolic link as lock file is refused by the staging' eval 'rc_is 40 && out_is K2S-STAGE-ERROR:lock-file'
    content=$(< /var/lib/k2s-target)
    check 'lock: the target of the planted lock file is not truncated' test "$content" = precious
    rm -f -- "$B/.lock"
    : > "$B/.lock"
    ln -- "$B/.lock" /var/lib/k2s-hardlink
    RUN=$(new_id)
    run_remote prepare-verify
    check 'lock: a lock file with a second hard link is refused' eval 'rc_is 48 && out_is K2S-RUN-ERROR:lock-file'
    rm -f -- /var/lib/k2s-hardlink
    UPLOAD=$(remote upload)
    cp -- "$WORK/fake.sh" "$UPLOAD/clusterip-webhook-auth.sh"
    run_remote promote
    check 'lock: staging works again with the regular lock file' out_is "K2S-STAGE-OK:$SHA"
}

# 15. Retention (F5): only finished runs older than 30 days are removed, under the lock, file by file.
retained() { [[ -d "$B/runs/$1" && ! -L "$B/runs/$1" ]]; }
scenario_retention() {
    local old_done new_done old_abandoned new_abandoned old_vanished bad_exit both claimed_abandoned linked unexpected hidden
    local subdir linked_log
    local child_run active id out pid i job removed=0 kept=0
    # A finished run whose child process still holds the inherited lock on alive, and an active run. Both are started
    # before the old runs exist, because every start applies the retention.
    child_run=$(new_id)
    printf 'child\n' > "$WORK/control/mode.$child_run"
    RUN="$child_run"
    run_remote start-verify
    wait_until 10 test -e "$B/runs/$child_run/exit"
    touch -d "@$(($(date +%s) - 31 * 86400))" -- "$B/runs/$child_run/exit"
    check 'retention: the child of a finished run still holds the inherited lock on alive' not flock -n "$B/runs/$child_run/alive" true
    mode wait
    active=$(new_id)
    RUN="$active"
    run_remote start-verify
    wait_until 10 test -e "$WORK/control/waiting.$active"
    touch -d "@$(($(date +%s) - 31 * 86400))" -- "$B/runs/$active" "$B/runs/$active/pid"
    old_done=$(new_id) new_done=$(new_id) old_abandoned=$(new_id) new_abandoned=$(new_id) old_vanished=$(new_id)
    bad_exit=$(new_id) both=$(new_id) claimed_abandoned=$(new_id) linked=$(new_id) unexpected=$(new_id) hidden=$(new_id)
    subdir=$(new_id) linked_log=$(new_id)
    make_run "$old_done" completed 31
    make_run "$new_done" completed 29
    make_run "$old_abandoned" abandoned 31
    make_run "$new_abandoned" abandoned 29
    make_run "$old_vanished" vanished 31
    make_run "$bad_exit" completed 31
    printf 'x\n' > "$B/runs/$bad_exit/exit"
    touch -d "@$(($(date +%s) - 31 * 86400))" -- "$B/runs/$bad_exit/exit"
    make_run "$both" completed 31
    : > "$B/runs/$both/abandoned"
    # Abandoned and also claimed, without exit status: inconsistent, so the state is unknown.
    make_run "$claimed_abandoned" abandoned 31
    printf '4242\n' > "$B/runs/$claimed_abandoned/pid"
    mkdir -p /var/lib/k2s-planted/old
    make_run "$linked" completed 31
    cp -a -- "$B/runs/$linked/." /var/lib/k2s-planted/old/
    rm -rf -- "${B:?}/runs/$linked"
    ln -s /var/lib/k2s-planted/old "$B/runs/$linked"
    make_run "$unexpected" completed 31
    printf 'core\n' > "$B/runs/$unexpected/core"
    make_run "$hidden" completed 31
    : > "$B/runs/$hidden/.hidden"
    make_run "$subdir" completed 31
    mkdir -- "$B/runs/$subdir/run.log.d"
    make_run "$linked_log" completed 31
    rm -f -- "$B/runs/$linked_log/run.log"
    printf 'precious\n' > /var/lib/k2s-planted/log
    ln -s /var/lib/k2s-planted/log "$B/runs/$linked_log/run.log"
    mkdir -m 0700 -- "$B/runs/not-a-run-id" "$B/runs/20261121T080000Z-0123ABCD"
    for id in not-a-run-id 20261121T080000Z-0123ABCD; do
        printf '0\n' > "$B/runs/$id/exit"
        printf '1\n' > "$B/runs/$id/pid"
        touch -d "@$(($(date +%s) - 31 * 86400))" -- "$B/runs/$id/exit"
    done
    # An active run older than 30 days blocks the start, and nothing is removed while it is active.
    mode ok
    RUN=$(new_id)
    run_remote start-verify
    check 'retention: no start and no removal while a run is active, even an old one' \
        eval "rc_is 10 && [[ \$OUT == K2S-RUN-BUSY:$active:* ]] && retained $old_done && retained $old_abandoned || { printf 'output: %s\n' \"\$OUT\"; false; }"
    release "$active"
    wait_until 10 run_ended "$active"
    # Two simultaneous starts: the retention runs under the lock, so every old run is removed exactly once.
    id=$(new_id)
    (RUN="$id"; remote start-verify > "$WORK/start.$id" 2>&1) &
    job=$!
    RUN=$(new_id)
    remote start-verify > "$WORK/start.$RUN" 2>&1 &
    wait "$job" "$!"
    out=$(cat -- "$WORK/start.$id" "$WORK/start.$RUN")
    for i in "$old_done" "$old_abandoned"; do
        [[ "$(grep -c -x -F -- "K2S-RUN-REMOVED:$i" <<< "$out")" == 1 ]] && removed=$((removed + 1))
    done
    for i in "$unexpected" "$hidden" "$subdir" "$linked_log"; do
        [[ "$(grep -c -x -F -- "K2S-RUN-KEPT:$i" <<< "$out")" -ge 1 ]] && kept=$((kept + 1))
    done
    check 'retention: completed and abandoned runs older than 30 days are removed exactly once by two simultaneous starts' \
        eval "[[ $removed == 2 ]] && ! retained $old_done && ! retained $old_abandoned"
    check 'retention: only the old runs are reported as removed' test "$(grep -c '^K2S-RUN-REMOVED:' <<< "$out")" = 2
    check 'retention: old runs with unexpected entries are kept for inspection and reported' test "$kept" = 4
    check 'retention: completed and abandoned runs newer than 30 days are kept' eval "retained $new_done && retained $new_abandoned"
    check 'retention: a run without exit status (vanished, state unknown) is kept' retained "$old_vanished"
    check 'retention: a run with a non-numeric exit status is kept' retained "$bad_exit"
    check 'retention: a run that is both finished and abandoned is kept' retained "$both"
    check 'retention: an abandoned run that also has a PID (state unknown) is kept' retained "$claimed_abandoned"
    check 'retention: a finished run whose child holds the inherited lock on alive is kept' retained "$child_run"
    check 'retention: directories that are not named like a run are kept' eval 'retained not-a-run-id && retained 20261121T080000Z-0123ABCD'
    check 'retention: a linked run directory is kept, and its target is untouched' \
        eval "[[ -L $B/runs/$linked ]] && listing_is /var/lib/k2s-planted/old 'alive clusterip-webhook-auth.sh exit pid run.log'"
    check 'retention: kept runs keep all their entries' eval "listing_is $B/runs/$unexpected 'alive clusterip-webhook-auth.sh core exit pid run.log' && listing_is $B/runs/$subdir 'alive clusterip-webhook-auth.sh exit pid run.log run.log.d'"
    check 'retention: a linked entry is not followed: its target is untouched' eval '[[ "$(< /var/lib/k2s-planted/log)" == precious && -L "$B/runs/$linked_log/run.log" ]]'
    check 'retention: a start that keeps runs for inspection still starts' eval "grep -q '^K2S-RUN-PREPARED:' <<< \"\$out\""
    pid=$(< "$WORK/control/child.$child_run")
    kill -KILL "$pid"
    wait_until 10 run_ended "$child_run"
    mode ok
    RUN=$(new_id)
    run_remote start-verify
    check 'retention: the old finished run is removed once its last process has ended' eval "[[ \$OUT == *K2S-RUN-REMOVED:$child_run* ]] && ! retained $child_run"
    wait_until 10 run_ended "$RUN"
}

# 17. Nothing in the protocol ends a process: polls, abandonment attempts and refused starts leave a running run alone.
scenario_no_termination() {
    local name id pid script i before
    for name in "${!CMD[@]}"; do
        if [[ "${CMD[$name]}" =~ (^|[^a-z])(kill|pkill|killall)([^a-z]|$) ]]; then fail "no termination: the remote command '$name' can send signals"; fi
    done
    pass 'no termination: no remote command of the module sends signals (kill, pkill, killall)'
    mode wait
    id=$(new_id)
    RUN="$id"
    run_remote start-verify
    wait_until 10 test -e "$WORK/control/waiting.$id"
    pid=$(head -c 16 -- "$B/runs/$id/pid")
    script=$(head -n 1 -- "$WORK/control/ran.$id")
    before=$(ls -A "$B/runs")
    for i in 1 2 3 4 5; do
        poll "$id"
        RUN="$id"
        run_remote abandon
        RUN=$(new_id)
        run_remote start-verify
    done
    check 'no termination: after polls, abandonment attempts and refused starts the runner and the script of the run still run' \
        eval "! gone $pid && ! gone $script && process_with environ K2S_WEBHOOK_AUTH_RUN=$id"
    check 'no termination: the refused starts left no run directory' test "$(ls -A "$B/runs")" = "$before"
    release "$id"
    check 'no termination: the run ends normally' wait_until 10 test -e "$B/runs/$id/exit"
    poll "$id"
    check 'no termination: the run exited with status 0' state_is exited:0
    check 'no termination: the unrelated process started by the test is still running' not gone "$DECOY"
}

inner() {
    local name b64
    WORK="$1"
    if ! mount -t tmpfs -o mode=0755 tmpfs /var/lib || ! mount -t tmpfs -o mode=1777 tmpfs /tmp; then
        printf 'FAIL: cannot mount private /var/lib and /tmp\n'
        exit 1
    fi
    mkdir -p -- "$WORK/shim" "$WORK/control"
    printf '%s\n' '#!/bin/sh' '# sudo of the test namespaces, which run as root already.' 'if [ "$1" = -n ]; then shift; fi' 'exec "$@"' > "$WORK/shim/sudo"
    chmod 0755 -- "$WORK/shim/sudo"
    export PATH="$WORK/shim:$PATH" K2S_TEST_CONTROL="$WORK/control"
    while IFS=$'\t' read -r name b64; do CMD[$name]=$(printf '%s' "$b64" | base64 -d); done < "$WORK/commands"
    check 'commands: the module built every remote command with the placeholder values' commands_built
    write_fake_script "$WORK/fake.sh"
    SHA=$(sha256sum < "$WORK/fake.sh" | cut -c1-64)
    : > "$WORK/cases.tsv"
    : > "$WORK/expected.tsv"
    scenario_staging
    if [[ -f "$B/bin/clusterip-webhook-auth.sh" ]]; then
        scenario_verified_copy
        scenario_start
        scenario_concurrent_starts
        scenario_double_claim
        scenario_claim_or_abandon
        scenario_process_identity
        scenario_log_framing
        scenario_unknown_states
        scenario_symlinks
        scenario_lock
        scenario_retention
        scenario_no_termination
    else
        fail 'staging failed, so no run can start; the other scenarios were not run'
    fi
    printf '%s %s\n' "$passed" "$failed" > "$WORK/counts"
}

# The commands of the module, with the placeholders as single-quoted words.
commands_built() {
    local q="'"
    [[ "${CMD[upload]}" == 'umask 077 && mktemp -d /tmp/k2s-webhook-auth-stage.XXXXXXXXXX' &&
        "${CMD[promote]}" == *" k2s-webhook-auth ${q}${UPLOAD_PLACEHOLDER}${q} ${q}${SHA_PLACEHOLDER}${q}" &&
        "${CMD[cleanup]}" == "rm -rf -- ${q}${UPLOAD_PLACEHOLDER}${q}" &&
        "${CMD[start-verify]}" == *" k2s-webhook-auth ${q}${ID_PLACEHOLDER}${q} ${q}${SHA_PLACEHOLDER}${q} ${q}verify${q} && sudo -n setsid -f /bin/sh -c "* &&
        "${CMD[start-renew-force]}" == *" ${q}renew${q} ${q}--force${q} && sudo -n setsid -f /bin/sh -c "* &&
        "${CMD[poll]}" == *" k2s-webhook-auth ${q}${ID_PLACEHOLDER}${q} ${q}1048576${q} ${q}${NONCE_PLACEHOLDER}${q}" &&
        "${CMD[abandon]}" == *" k2s-webhook-auth ${q}${ID_PLACEHOLDER}${q}" ]] && return 0
    printf 'unexpected commands:\n'
    for q in "${!CMD[@]}"; do printf '%s: %s\n' "$q" "${CMD[$q]:0:160}"; done
    return 1
}

# --- end of scenarios ---

if [[ "${1:-}" == --in-namespaces ]]; then
    inner "$2"
else
    outer
fi
