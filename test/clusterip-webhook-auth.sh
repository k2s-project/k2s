#!/bin/bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# Hermetic tests for clusterip-webhook-auth.sh. Every root directory is below a temporary directory; cluster
# access (k2s_wa_kubectl), kube-apiserver process states and sleep are mocked; openssl and kubectl --local are
# real. TLS probes of verify (openssl s_client through timeout) replay captured OpenSSL outputs, except for the
# real-TLS cases against openssl s_server on loopback. Never runs sudo and never touches /etc/kubernetes or a
# cluster. Needs GNU userland (Linux or WSL).
# shellcheck disable=SC2317,SC2329 # setup functions and mocks are invoked indirectly (run_with, function overrides)
set -euo pipefail
exec 2>&1
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/lib/modules/windows/node/k2s.node.module/linuxnode/distros/scripts/clusterip-webhook-auth.sh"
MANIFESTS="$REPO_ROOT/lib/manifests/clusterip-webhook"
for tool in openssl kubectl flock find stat date comm sort sha256sum mkfifo timeout awk base64 seq cmp sync; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'missing test prerequisite: %s\n' "$tool"
        exit 1
    fi
done
# shellcheck source=SCRIPTDIR/../lib/modules/windows/node/k2s.node.module/linuxnode/distros/scripts/clusterip-webhook-auth.sh
source "$SCRIPT"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
trap 'printf "ABORTED at line %s: %s\n" "$LINENO" "$BASH_COMMAND"' ERR

sudo() { printf 'tests must never run sudo\n'; return 1; }
# Simulated time: SECONDS is made a plain variable (unset removes its special meaning), so it advances only when the
# script sleeps. A full K2S_WA_WAIT_TIMEOUT elapses without waiting, and the number of polls does not depend on the
# load of the machine.
unset SECONDS
SECONDS=0
sleep() { SECONDS=$((SECONDS + ${1%%.*})); }
eval "real_$(declare -f k2s_wa_require_root)"
eval "real_$(declare -f k2s_wa_apiserver_process_states)"
eval "real_$(declare -f k2s_wa_kubectl)"
k2s_wa_require_root() { :; }

# kube-apiserver processes follow the flag in the case manifest, like the kubelet restarting the static Pod.
# APISERVER: healthy, unready (/readyz fails), down (no process), flag-crashes (no process while the flag is
# set), flag-breaks-cluster (no process after the flag was set once, even after a restore).
k2s_wa_apiserver_process_states() {
    local configured=noflag
    if [[ -f "$K2S_WA_MANIFEST" ]] && grep -q -F -- "$K2S_WA_FLAG" "$K2S_WA_MANIFEST"; then configured=flag; fi
    case "$APISERVER" in
        healthy | unready) K2S_WA_PROC_STATES="$configured" ;;
        down) K2S_WA_PROC_STATES='' ;;
        stale) K2S_WA_PROC_STATES=noflag ;;
        flag-crashes) if [[ "$configured" == flag ]]; then K2S_WA_PROC_STATES=''; else K2S_WA_PROC_STATES=noflag; fi ;;
        flag-breaks-cluster)
            if [[ "$configured" == flag ]]; then : > "$CASE_DIR/broken"; fi
            if [[ -e "$CASE_DIR/broken" ]]; then K2S_WA_PROC_STATES=''; else K2S_WA_PROC_STATES="$configured"; fi ;;
        *) printf 'unknown APISERVER mode %s\n' "$APISERVER"; return 1 ;;
    esac
}

# Cluster access. Every call is logged to $CASE_DIR/kubectl.log. GET_FAIL makes calls containing that word fail.
k2s_wa_kubectl() {
    printf '%s\n' "$*" >> "$CASE_DIR/kubectl.log"
    if [[ -n "$GET_FAIL" && " $* " == *" $GET_FAIL "* ]]; then printf 'error: injected failure\n' >&2; return 1; fi
    case "$1" in
        apply)
            [[ "$KUBECTL_APPLY" == ok ]] || { printf 'error: injected apply failure\n'; return 1; }
            cp -- "${!#}" "$CASE_DIR/applied.yaml" ;;
        get)
            case "$2" in
                --raw=/readyz)
                    case "$APISERVER" in unready | down) printf 'readyz check failed'; return 1 ;; esac
                    printf '%s' "$READYZ_OUTPUT"
                    return "$READYZ_RC" ;;
                --raw=/metrics) mock_metrics ;;
                configmap)
                    [[ "$KUBECTL_GET" == ok ]] || { printf 'error: injected get failure\n'; return 1; }
                    if [[ "${!#}" == yaml ]]; then
                        command -p cat -- "${SERVED:-$CASE_DIR/applied.yaml}"
                    else
                        mock_get "${SERVED:-$CASE_DIR/applied.yaml}" "$@"
                    fi ;;
                mutatingwebhookconfiguration) mock_get "$MWC_FILE" "$@" ;;
                deployment) mock_get "$DEPLOY_FILE" "$@" ;;
                service) mock_get "$SVC_FILE" "$@" ;;
                endpointslices) printf '%s' "$EPS_OUTPUT" ;;
                mutatingwebhookconfigurations,validatingwebhookconfigurations) printf '%s' "$RULES_OUTPUT" ;;
                *) printf 'error: injected get failure\n'; return 1 ;;
            esac ;;
        create) mock_create "$@" ;;
        *) printf 'unexpected kubectl call: %s\n' "$*"; return 1 ;;
    esac
}
# kubectl get <kind> <name> -o <format> for the object in file $1 (absent if empty or missing), rendered by the
# real kubectl. Lists are answered with pre-rendered template output (EPS_OUTPUT, RULES_OUTPUT).
mock_get() {
    local file="$1"
    shift
    if [[ -z "$file" || ! -f "$file" ]]; then
        if [[ " $* " == *' --ignore-not-found '* ]]; then return 0; fi
        printf 'Error from server (NotFound): %s "%s" not found\n' "$2" "$3" >&2
        return 1
    fi
    KUBERC=off KUBECONFIG=/dev/null command kubectl patch --local -f "$file" --type=json -p '[]' -o "${!#}"
}
# kube-apiserver metrics with the counters of the webhook from $CASE_DIR/metrics (successful, failed and
# fail-open calls, rejections) and series of other webhooks as noise. METRICS_MODE: fail, notype (no kube-apiserver
# metrics), reset (every second snapshot after a kube-apiserver restart).
mock_metrics() {
    local good=0 failed=0 open=0 rejected=0 calls=0 series
    if [[ -f "$CASE_DIR/metrics" ]]; then read -r good failed open rejected < "$CASE_DIR/metrics"; fi
    if [[ -f "$CASE_DIR/metrics-calls" ]]; then calls=$(<"$CASE_DIR/metrics-calls"); fi
    printf '%s\n' "$((calls + 1))" > "$CASE_DIR/metrics-calls"
    case "$METRICS_MODE" in
        fail) printf 'error: injected metrics failure\n' >&2; return 1 ;;
        reset) if (( calls % 2 == 1 )); then good=1 failed=0 open=0 rejected=0; fi ;;
        vanish) if (( calls % 2 == 1 )); then failed=0 open=0; fi ;;
    esac
    series='name="clusterip.k2s.io",operation="CREATE"'
    if [[ "$METRICS_MODE" != notype ]]; then printf '# HELP apiserver_request_total Requests\n# TYPE apiserver_request_total counter\n'; fi
    printf '%s\n' 'apiserver_request_total{code="200",verb="GET"} 42' \
        'apiserver_admission_webhook_request_total{code="200",name="workload.clusterip.k2s.io",operation="CREATE",rejected="false",type="admit"} 9' \
        'apiserver_admission_webhook_request_total{code="500",name="other.example.io",operation="CREATE",rejected="false",type="admit"} 3' \
        'apiserver_admission_webhook_fail_open_count{name="other.example.io",type="admit"} 3' \
        'apiserver_admission_webhook_admission_duration_seconds_count{name="clusterip.k2s.io",operation="CREATE",rejected="true",type="admit"} 8'
    if (( good > 0 )); then printf 'apiserver_admission_webhook_request_total{code="200",%s,rejected="false",type="admit"} %s\n' "$series" "$good"; fi
    if (( failed > 0 )); then printf 'apiserver_admission_webhook_request_total{code="500",%s,rejected="false",type="admit"} %s\n' "$series" "$failed"; fi
    if (( open > 0 )); then printf 'apiserver_admission_webhook_fail_open_count{name="clusterip.k2s.io",type="admit"} %s\n' "$open"; fi
    if (( rejected > 0 )); then
        printf 'apiserver_admission_webhook_request_total{code="403",%s,rejected="true",type="admit"} %s\n' "$series" "$rejected"
        printf 'apiserver_admission_webhook_rejection_count{error_type="no_error",%s,rejection_code="403",type="admit"} %s\n' "$series" "$rejected"
    fi
}
metrics_add() {
    local good=0 failed=0 open=0 rejected=0
    if [[ -f "$CASE_DIR/metrics" ]]; then read -r good failed open rejected < "$CASE_DIR/metrics"; fi
    printf '%s %s %s %s\n' "$((good + $1))" "$((failed + $2))" "$((open + $3))" "$((rejected + $4))" > "$CASE_DIR/metrics"
}
cert_trusted() { [[ -z "$TLS_TRUSTED_SHA" || "$(sha256sum < "$1" | cut -c1-64)" == "$TLS_TRUSTED_SHA" ]]; }
# The server-side dry-run of the probe Service: records the manifest, counts the webhook calls like kube-apiserver
# and prints the clusterIP. ADMISSION lists the outcome of each call (the last one repeats); trusted-cert behaves
# like ok if kube-apiserver's client certificate on disk is trusted (TLS_TRUSTED_SHA), else like fail-open.
mock_create() {
    local count=0 outcome
    local -a outcomes
    if [[ "$*" != 'create --dry-run=server -f - -o go-template=clusterIP={{.spec.clusterIP}}{{"\n"}}' ]]; then
        printf 'unexpected kubectl call: %s\n' "$*"
        return 1
    fi
    if [[ -f "$CASE_DIR/creates" ]]; then count=$(<"$CASE_DIR/creates"); fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$CASE_DIR/creates"
    command -p cat > "$CASE_DIR/dry-run-$count.yaml"
    read -r -a outcomes <<< "$ADMISSION"
    outcome="${outcomes[count - 1]:-${outcomes[-1]}}"
    if [[ "$outcome" == trusted-cert ]]; then
        if cert_trusted "$K2S_WA_AUTH_DIR/client.crt"; then outcome=ok; else outcome=fail-open; fi
    fi
    case "$outcome" in
        ok) metrics_add 1 0 0 0; printf 'clusterIP=172.21.0.50\n' ;;
        warning) metrics_add 1 0 0 0; printf 'Warning: unrelated admission warning\n' >&2; printf 'clusterIP=172.21.0.254\n' ;;
        reinvoked) metrics_add 2 0 0 0; printf 'clusterIP=172.21.0.51\n' ;;
        concurrent-ok) metrics_add 3 0 0 0; printf 'clusterIP=172.21.0.52\n' ;;
        concurrent-failure) metrics_add 1 1 1 0; printf 'clusterIP=172.21.0.53\n' ;;
        below-range) metrics_add 1 0 0 0; printf 'clusterIP=172.21.0.49\n' ;;
        fail-open) metrics_add 0 1 1 0; printf 'clusterIP=172.21.0.0\n' ;;
        not-called) printf 'clusterIP=172.21.0.0\n' ;;
        no-ip) metrics_add 1 0 0 0; printf 'clusterIP=172.21.0.0\n' ;;
        failed) metrics_add 0 1 0 0; printf 'clusterIP=172.21.0.0\n' ;;
        noisy) metrics_add 2 1 1 0; printf 'clusterIP=172.21.0.0\n' ;;
        denied)
            metrics_add 0 0 0 1
            printf 'Error from server (Forbidden): error when creating "STDIN": admission webhook "clusterip.k2s.io" denied the request: failed to allocate ClusterIP for linux service: no free IPs\n' >&2
            return 1 ;;
        refused) printf 'Error from server (InternalError): error when creating "STDIN": Internal error occurred: unrelated\n' >&2; return 1 ;;
        *) printf 'unknown ADMISSION outcome %s\n' "$outcome"; return 1 ;;
    esac
}
GET_FAIL='' MWC_FILE='' DEPLOY_FILE='' SVC_FILE='' EPS_OUTPUT='' RULES_OUTPUT='' METRICS_MODE='' ADMISSION=ok
TLS_NOCERT=rejected TLS_CERT=answered TLS_TRUSTED_SHA='' TLS_MODE=replay

passed=0
failed=0
pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$*"; }
fail() { failed=$((failed + 1)); printf 'FAIL: %s\n' "$*"; }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
not() { ! "$@"; }
quiet() { "$@" > /dev/null 2>&1; }
expect_rc() {
    if [[ "$RC" == "$1" ]]; then pass "$2"; return 0; fi
    fail "$2 (exit $RC, expected $1)"
    printf '%s\n' "$OUTPUT" | sed 's/^/    | /'
}
output_has() { [[ "$OUTPUT" == *"$1"* ]]; }
output_lacks() { [[ "$OUTPUT" != *"$1"* ]]; }
reason_has() { [[ "$K2S_WA_REASON" == *"$1"* ]]; }
marker_is() { [[ "${OUTPUT##*$'\n'}" == "K2S-WEBHOOK-AUTH-OK:$1" ]]; }
no_marker() { output_lacks 'K2S-WEBHOOK-AUTH-OK'; }

CASE=0
new_case() {
    CASE=$((CASE + 1))
    CASE_DIR="$TEST_DIR/case$CASE"
    mkdir -p -- "$CASE_DIR/etc/manifests"
    k2s_wa_init_paths "$CASE_DIR/etc"
    APISERVER=healthy KUBECTL_APPLY=ok KUBECTL_GET=ok READYZ_OUTPUT=ok READYZ_RC=0 SERVED=''
    K2S_WA_LOCK_TIMEOUT=300
    unset -f openssl
}
run() { RC=0; OUTPUT=$(main "$@" < /dev/null 2>&1) || RC=$?; }
# Runs a setup function (for example an injected failure) and main in the same subshell.
run_with() { local setup="$1"; shift; RC=0; OUTPUT=$({ "$setup" && main "$@"; } < /dev/null 2>&1) || RC=$?; }
provisioned_case() {
    new_case
    run provision
    if [[ "$RC" != 0 ]]; then printf 'ABORTED: provision setup failed (%s)\n%s\n' "$RC" "$OUTPUT"; exit 1; fi
}
manifest_case() {
    new_case
    cp -- "${1:-$FIXTURE}" "$K2S_WA_MANIFEST"
    chmod 0600 -- "$K2S_WA_MANIFEST"
}

render_local() { KUBECONFIG=/dev/null kubectl patch --local -f "$1" --type=json -p '[]' -o "go-template=$2"; }
new_key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null; }
key_id() { openssl pkey -in "$1" -pubout 2>/dev/null | sha256sum | cut -c1-64; }
cert_days() {
    local start end
    start=$(openssl x509 -in "$1" -noout -startdate) && end=$(openssl x509 -in "$1" -noout -enddate) || return 1
    printf '%s\n' $((($(date -u -d "${end#notAfter=}" +%s) - $(date -u -d "${start#notBefore=}" +%s)) / 86400))
}
# make_cert <out> <key> <issuer certificate|self> <issuer key> <client|server|noeku|ca_cert> <start> <end>
make_cert() {
    local out="$1" key="$2" issuer="$3" issuer_key="$4" ext="$5" start="$6" end="$7" dir
    local -a signer=(-cert "$issuer" -keyfile "$issuer_key")
    [[ "$issuer" != self ]] || signer=(-selfsign -keyfile "$key")
    dir=$(mktemp -d "$TEST_DIR/openssl-ca.XXXXXX")
    : > "$dir/index.txt"
    printf '01\n' > "$dir/serial"
    printf '%s\n' '[ca]' 'default_ca = test_ca' '[test_ca]' "database = $dir/index.txt" "new_certs_dir = $dir" \
        "serial = $dir/serial" 'default_md = sha256' 'policy = policy_any' 'unique_subject = no' 'copy_extensions = none' \
        '[policy_any]' 'commonName = supplied' \
        '[client]' 'basicConstraints = critical,CA:FALSE' 'keyUsage = critical,digitalSignature' 'extendedKeyUsage = clientAuth' \
        '[server]' 'basicConstraints = critical,CA:FALSE' 'keyUsage = critical,digitalSignature' 'extendedKeyUsage = serverAuth' \
        '[noeku]' 'basicConstraints = critical,CA:FALSE' 'keyUsage = critical,digitalSignature' \
        '[webhook_server]' 'basicConstraints = critical,CA:FALSE' 'keyUsage = critical,digitalSignature' \
        'extendedKeyUsage = serverAuth' "subjectAltName = DNS:$K2S_WA_SERVICE_HOST" \
        '[ca_cert]' 'basicConstraints = critical,CA:TRUE,pathlen:0' 'keyUsage = critical,keyCertSign,cRLSign' \
        'subjectKeyIdentifier = hash' > "$dir/openssl.cnf"
    if ! openssl req -new -key "$key" -subj "/CN=k2s-test-$ext" -out "$dir/request.csr" > "$dir/log" 2>&1 ||
        ! openssl ca -batch -notext -config "$dir/openssl.cnf" "${signer[@]}" -extensions "$ext" -in "$dir/request.csr" \
            -out "$out" -startdate "$(date -u -d "$start" +%Y%m%d%H%M%SZ)" -enddate "$(date -u -d "$end" +%Y%m%d%H%M%SZ)" \
            >> "$dir/log" 2>&1; then
        printf 'ABORTED: cannot create test certificate %s\n' "$out"
        cat -- "$dir/log"
        exit 1
    fi
}
# Files with inode, mode, size and mtime; directories with mode. The lock file is opened by every run.
snapshot() {
    find "$K2S_WA_ROOT" \( -type f ! -name .k2s-webhook-auth.lock -printf '%p %y %i %m %s %T@\n' \) -o \
        \( ! -type f -printf '%p %y %m\n' \) | LC_ALL=C sort
}
modes_are() {
    local actual
    while (( $# > 0 )); do
        actual=$(stat -c %a -- "$2")
        [[ "$actual" == "$1" ]] || { printf 'mode of %s is %s, expected %s\n' "$2" "$actual" "$1"; return 1; }
        shift 2
    done
}
listing_is() { [[ "$(find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" == "$2 " ]]; }
no_leftovers() {
    local left
    left=$(find "$K2S_WA_ROOT" \( -name '*.tmp.*' -o -name '.kube-apiserver.yaml.k2s-webhook-auth.*' \) -print)
    [[ -z "$left" ]] || { printf 'leftovers: %s\n' "$left"; return 1; }
}
manifest_state_is() { k2s_wa_manifest_state "$K2S_WA_MANIFEST" > /dev/null && [[ "$K2S_WA_STATE" == "$1" ]]; }
only_readyz_calls() {
    [[ ! -s "$CASE_DIR/kubectl.log" ]] || not grep -q -v -x -F -- 'get --raw=/readyz --request-timeout=5s' "$CASE_DIR/kubectl.log"
}
# Compares two manifests like the script: no line may be lost, the sorted added lines must equal $3.
added_lines_are() {
    local lost added
    lost=$(LC_ALL=C comm -23 <(grep -v '^[[:space:]]*$' "$1" | LC_ALL=C sort) <(grep -v '^[[:space:]]*$' "$2" | LC_ALL=C sort))
    added=$(LC_ALL=C comm -13 <(grep -v '^[[:space:]]*$' "$1" | LC_ALL=C sort) <(grep -v '^[[:space:]]*$' "$2" | LC_ALL=C sort))
    [[ -z "$lost" && "$added" == "$(printf '%s\n' "$3" | LC_ALL=C sort)" ]] || { printf 'lost:\n%s\nadded:\n%s\n' "$lost" "$added"; return 1; }
}

# kube-apiserver static Pod manifest as written by kubeadm (canonical kubectl YAML: sorted keys).
FIXTURE="$TEST_DIR/kube-apiserver.yaml"
cat > "$FIXTURE" <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  annotations:
    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: 172.19.1.100:6443
  labels:
    component: kube-apiserver
    tier: control-plane
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --advertise-address=172.19.1.100
    - --allow-privileged=true
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --enable-admission-plugins=NodeRestriction
    - --enable-bootstrap-token-auth=true
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --etcd-servers=https://127.0.0.1:2379
    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
    - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
    - --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt
    - --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key
    - --requestheader-allowed-names=front-proxy-client
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --requestheader-extra-headers-prefix=X-Remote-Extra-
    - --requestheader-group-headers=X-Remote-Group
    - --requestheader-username-headers=X-Remote-User
    - --secure-port=6443
    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
    - --service-cluster-ip-range=172.21.0.0/16
    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    env:
    - name: HTTPS_PROXY
      value: http://172.19.1.1:8181
    - name: NO_PROXY
      value: '*.local,localhost,127.0.0.1,172.19.1.0/24'
    image: registry.k8s.io/kube-apiserver:v1.37.2
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 172.19.1.100
        path: /livez
        port: probe-port
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    name: kube-apiserver
    ports:
    - containerPort: 6443
      name: probe-port
      protocol: TCP
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 172.19.1.100
        path: /readyz
        port: probe-port
        scheme: HTTPS
      periodSeconds: 1
      timeoutSeconds: 15
    resources:
      requests:
        cpu: 250m
    startupProbe:
      failureThreshold: 24
      httpGet:
        host: 172.19.1.100
        path: /livez
        port: probe-port
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ca-certs
      readOnly: true
    - mountPath: /etc/ca-certificates
      name: etc-ca-certificates
      readOnly: true
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
    - mountPath: /usr/local/share/ca-certificates
      name: usr-local-share-ca-certificates
      readOnly: true
    - mountPath: /usr/share/ca-certificates
      name: usr-share-ca-certificates
      readOnly: true
  hostNetwork: true
  priority: 2000001000
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - hostPath:
      path: /etc/ssl/certs
      type: DirectoryOrCreate
    name: ca-certs
  - hostPath:
      path: /etc/ca-certificates
      type: DirectoryOrCreate
    name: etc-ca-certificates
  - hostPath:
      path: /etc/kubernetes/pki
      type: DirectoryOrCreate
    name: k8s-certs
  - hostPath:
      path: /usr/local/share/ca-certificates
      type: DirectoryOrCreate
    name: usr-local-share-ca-certificates
  - hostPath:
      path: /usr/share/ca-certificates
      type: DirectoryOrCreate
    name: usr-share-ca-certificates
status: {}
EOF
if ! KUBECONFIG=/dev/null kubectl patch --local -f "$FIXTURE" --type=json -p '[]' -o yaml | cmp -s - "$FIXTURE"; then
    printf 'ABORTED: the fixture is not canonical for this kubectl version\n'
    exit 1
fi
pass 'kubeadm-style fixture round-trips unchanged through kubectl'
FOREIGN_KEY="$TEST_DIR/foreign-ca.key"
FOREIGN_CRT="$TEST_DIR/foreign-ca.crt"
new_key "$FOREIGN_KEY"
make_cert "$FOREIGN_CRT" "$FOREIGN_KEY" self '' ca_cert '-1 day' '+1000 days'

# --- rendered configuration for the production root /etc/kubernetes ---
(
    k2s_wa_init_paths /etc/kubernetes
    k2s_wa_render_kubeconfig > "$TEST_DIR/kubeconfig"
    k2s_wa_render_admission_config > "$TEST_DIR/admission-config.yaml"
    k2s_wa_render_patch > "$TEST_DIR/patch.json"
)
cat > "$TEST_DIR/kubeconfig.golden" <<'EOF'
# Generated by clusterip-webhook-auth.sh. kube-apiserver presents this client certificate only to the
# clusterip-webhook Service: there is intentionally no wildcard user and no current-context.
apiVersion: v1
kind: Config
users:
- name: "clusterip-webhook.k2s-webhook.svc:443"
  user:
    client-certificate: /etc/kubernetes/k2s-webhook-auth/client.crt
    client-key: /etc/kubernetes/k2s-webhook-auth/client.key
EOF
cat > "$TEST_DIR/admission-config.golden" <<'EOF'
# Generated by clusterip-webhook-auth.sh.
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: MutatingAdmissionWebhook
  configuration:
    apiVersion: apiserver.config.k8s.io/v1
    kind: WebhookAdmissionConfiguration
    kubeConfigFile: /etc/kubernetes/k2s-webhook-auth/kubeconfig
EOF
cat > "$TEST_DIR/patch.golden" <<'EOF'
[
  {"op": "test", "path": "/spec/containers/0/name", "value": "kube-apiserver"},
  {"op": "add", "path": "/spec/containers/0/command/-", "value": "--admission-control-config-file=/etc/kubernetes/k2s-webhook-auth/admission-config.yaml"},
  {"op": "add", "path": "/spec/containers/0/volumeMounts/-", "value": {"name": "k2s-webhook-auth", "mountPath": "/etc/kubernetes/k2s-webhook-auth", "readOnly": true}},
  {"op": "add", "path": "/spec/volumes/-", "value": {"name": "k2s-webhook-auth", "hostPath": {"path": "/etc/kubernetes/k2s-webhook-auth", "type": "Directory"}}}
]
EOF
check 'kubeconfig has a single user for the webhook Service and no wildcard or context' cmp -s -- "$TEST_DIR/kubeconfig.golden" "$TEST_DIR/kubeconfig"
check 'AdmissionConfiguration only points MutatingAdmissionWebhook to the kubeconfig' cmp -s -- "$TEST_DIR/admission-config.golden" "$TEST_DIR/admission-config.yaml"
check 'kubeadm patch adds the flag, a read-only mount and the host directory' cmp -s -- "$TEST_DIR/patch.golden" "$TEST_DIR/patch.json"
out=$(KUBECONFIG=/dev/null kubectl config view --kubeconfig "$TEST_DIR/kubeconfig" -o 'go-template={{range .users}}U|{{.name}}|{{index .user "client-certificate"}}|{{index .user "client-key"}}{{"\n"}}{{end}}{{if .clusters}}clusters{{"\n"}}{{end}}{{if .contexts}}contexts{{"\n"}}{{end}}C|{{index . "current-context"}}')
check 'kubectl parses the kubeconfig as exactly one user without clusters or contexts' [ "$out" = 'U|clusterip-webhook.k2s-webhook.svc:443|/etc/kubernetes/k2s-webhook-auth/client.crt|/etc/kubernetes/k2s-webhook-auth/client.key
C|' ]
out=$(render_local "$TEST_DIR/admission-config.yaml" '{{.apiVersion}}|{{.kind}}{{range .plugins}}|{{.name}}|{{.configuration.apiVersion}}|{{.configuration.kind}}|{{.configuration.kubeConfigFile}}{{end}}')
check 'kubectl parses the AdmissionConfiguration' [ "$out" = 'apiserver.config.k8s.io/v1|AdmissionConfiguration|MutatingAdmissionWebhook|apiserver.config.k8s.io/v1|WebhookAdmissionConfiguration|/etc/kubernetes/k2s-webhook-auth/kubeconfig' ]

# kube-apiserver selects the kubeconfig user named <service>.<namespace>.svc:<port> of each webhook.
out=$(render_local "$MANIFESTS/webhook-config.yaml" '{{range .webhooks}}{{.name}}|{{with .clientConfig.service}}{{.name}}.{{.namespace}}.svc:{{with .port}}{{.}}{{else}}443{{end}}{{end}}|{{with .clientConfig.url}}url{{end}}{{"\n"}}{{end}}')
check 'both admission webhooks target exactly the credential name' [ "$out" = "clusterip.k2s.io|$K2S_WA_CREDENTIAL_NAME|
workload.clusterip.k2s.io|$K2S_WA_CREDENTIAL_NAME|" ]
# shellcheck disable=SC2016 # Go template variables, not shell expansions
out=$(render_local "$MANIFESTS/deployment.yaml" '{{.kind}}|{{.metadata.namespace}}|{{.metadata.name}}{{if eq .kind "Deployment"}}{{range .spec.template.spec.volumes}}|{{range $k, $v := .}}{{if ne $k "name"}}{{$k}}{{end}}{{end}}:{{.name}}{{with .configMap}}={{.name}}{{range .items}}/{{.key}}>{{.path}}{{end}}{{end}}{{end}}{{end}}{{if eq .kind "Service"}}{{range .spec.ports}}|{{.port}}>{{.targetPort}}{{end}}{{end}}{{"\n"}}')
check 'webhook Pod mounts only ca.crt of the published ConfigMap and serves on Service port 443' [ "$out" = "Deployment|$K2S_WA_NAMESPACE|clusterip-webhook|emptyDir:tls-certs|configMap:client-ca=$K2S_WA_CONFIGMAP/ca.crt>ca.crt
Service|$K2S_WA_NAMESPACE|clusterip-webhook|$K2S_WA_SERVICE_PORT>8443" ]
check 'webhook Pod references neither host paths nor the CA key' not grep -q -e hostPath -e 'ca\.key' -e 'k2s-webhook-auth' -- "$MANIFESTS/deployment.yaml"

# --- fresh provisioning ---
new_case
rm -r -- "$K2S_WA_ROOT"
run provision
expect_rc 0 'provision creates the root directory and all credentials'
check 'provision prints its success marker last' marker_is provision
check 'provision reports a new client CA' output_has "created client CA '$K2S_WA_CA_DIR'"
check 'credential permissions' modes_are 755 "$K2S_WA_ROOT" 700 "$K2S_WA_CA_DIR" 600 "$K2S_WA_CA_DIR/ca.key" \
    644 "$K2S_WA_CA_DIR/ca.crt" 755 "$K2S_WA_AUTH_DIR" 600 "$K2S_WA_AUTH_DIR/client.key" 600 "$K2S_WA_AUTH_DIR/kubeconfig" \
    644 "$K2S_WA_AUTH_DIR/client.crt" 644 "$K2S_WA_AUTH_DIR/admission-config.yaml" 755 "$K2S_WA_PATCH_DIR" 644 "$K2S_WA_PATCH_FILE"
check 'CA directory holds only the CA pair' listing_is "$K2S_WA_CA_DIR" 'ca.crt ca.key'
check 'kube-apiserver credential directory holds no CA material' listing_is "$K2S_WA_AUTH_DIR" 'admission-config.yaml client.crt client.key kubeconfig'
check 'patch directory holds only the kube-apiserver patch' listing_is "$K2S_WA_PATCH_DIR" 'kube-apiserver+json.json'
out=$(grep -r -l -F -- 'PRIVATE KEY' "$K2S_WA_ROOT" | LC_ALL=C sort | tr '\n' ' ')
check 'private keys exist only as ca.key and client.key' [ "$out" = "$K2S_WA_CA_DIR/ca.key $K2S_WA_AUTH_DIR/client.key " ]
check 'client key differs from the CA key' [ "$(key_id "$K2S_WA_AUTH_DIR/client.key")" != "$(key_id "$K2S_WA_CA_DIR/ca.key")" ]
check 'rendered kubeconfig is installed' cmp -s -- "$K2S_WA_AUTH_DIR/kubeconfig" "$TEST_DIR/kubeconfig.golden"
check 'rendered AdmissionConfiguration is installed' cmp -s -- "$K2S_WA_AUTH_DIR/admission-config.yaml" "$TEST_DIR/admission-config.golden"
check 'rendered kubeadm patch points to the host credential directory' \
    cmp -s -- "$K2S_WA_PATCH_FILE" <(sed "s#\"path\": \"/etc/kubernetes/k2s-webhook-auth\"#\"path\": \"$K2S_WA_AUTH_DIR\"#" "$TEST_DIR/patch.golden")
check 'no temporary files remain' no_leftovers

ca="$K2S_WA_CA_DIR/ca.crt"
crt="$K2S_WA_AUTH_DIR/client.crt"
check 'CA subject' [ "$(openssl x509 -in "$ca" -noout -subject)" = 'subject=CN = k2s-clusterip-webhook-client-ca' ]
out=$(openssl x509 -in "$ca" -noout -ext basicConstraints,keyUsage)
check 'CA is a critical pathlen:0 CA limited to certificate and CRL signing' \
    [ "$out" = $'X509v3 Basic Constraints: critical\n    CA:TRUE, pathlen:0\nX509v3 Key Usage: critical\n    Certificate Sign, CRL Sign' ]
check 'CA validity is 3650 days' [ "$(cert_days "$ca")" = 3650 ]
check 'CA key is EC P-256' grep -q -F 'ASN1 OID: prime256v1' <(openssl pkey -in "$K2S_WA_CA_DIR/ca.key" -noout -text)
check 'client subject' [ "$(openssl x509 -in "$crt" -noout -subject)" = 'subject=CN = k2s-kube-apiserver-clusterip-webhook-client' ]
check 'client issuer is the client CA' [ "$(openssl x509 -in "$crt" -noout -issuer)" = 'issuer=CN = k2s-clusterip-webhook-client-ca' ]
out=$(openssl x509 -in "$crt" -noout -ext basicConstraints,keyUsage,extendedKeyUsage)
check 'client certificate is a non-CA certificate for TLS client authentication only' \
    [ "$out" = $'X509v3 Basic Constraints: critical\n    CA:FALSE\nX509v3 Key Usage: critical\n    Digital Signature\nX509v3 Extended Key Usage: \n    TLS Web Client Authentication' ]
ski=$(openssl x509 -in "$ca" -noout -ext subjectKeyIdentifier | sed -n '2s/^ *//p')
check 'client authority key identifier is the CA key identifier' grep -q -F -- "$ski" <(openssl x509 -in "$crt" -noout -ext authorityKeyIdentifier)
check 'client validity is 365 days' [ "$(cert_days "$crt")" = 365 ]
check 'client key is EC P-256' grep -q -F 'ASN1 OID: prime256v1' <(openssl pkey -in "$K2S_WA_AUTH_DIR/client.key" -noout -text)
check 'client certificate verifies for TLS client use' quiet openssl verify -trusted "$ca" -purpose sslclient "$crt"
check 'client certificate is unusable as a server certificate' not quiet openssl verify -trusted "$ca" -purpose sslserver "$crt"
check 'client certificate does not verify against the kubeadm-style foreign CA' not quiet openssl verify -trusted "$FOREIGN_CRT" "$crt"
check 'script validation accepts the CA' k2s_wa_check_ca "$K2S_WA_CA_DIR"
check 'script validation accepts the client certificate' k2s_wa_check_client_cert "$crt" "$K2S_WA_AUTH_DIR/client.key" "$ca"

# --- idempotency and permissions ---
before=$(snapshot)
run provision
expect_rc 0 'provision rerun succeeds'
check 'provision rerun reuses the client CA' output_has "reusing client CA '$K2S_WA_CA_DIR'"
check 'provision rerun reuses the client certificate' output_has "reusing kube-apiserver client certificate '$K2S_WA_AUTH_DIR/client.crt'"
check 'provision rerun rewrites no file' output_lacks 'wrote '
check 'provision rerun leaves every file untouched' [ "$(snapshot)" = "$before" ]
run provision
check 'third provision run leaves every file untouched' [ "$RC:$(snapshot)" = "0:$before" ]
chmod 0755 "$K2S_WA_CA_DIR"
chmod 0644 "$K2S_WA_CA_DIR/ca.key" "$K2S_WA_AUTH_DIR/client.key" "$K2S_WA_AUTH_DIR/kubeconfig"
chmod 0600 "$K2S_WA_AUTH_DIR/client.crt" "$K2S_WA_PATCH_FILE"
chmod 0777 "$K2S_WA_AUTH_DIR" "$K2S_WA_PATCH_DIR"
run provision
expect_rc 0 'provision accepts loosened permissions'
check 'provision restores every permission' modes_are 700 "$K2S_WA_CA_DIR" 600 "$K2S_WA_CA_DIR/ca.key" \
    600 "$K2S_WA_AUTH_DIR/client.key" 600 "$K2S_WA_AUTH_DIR/kubeconfig" 644 "$K2S_WA_AUTH_DIR/client.crt" \
    644 "$K2S_WA_PATCH_FILE" 755 "$K2S_WA_AUTH_DIR" 755 "$K2S_WA_PATCH_DIR"

# --- required tools (a PATH with only the declared tools) ---
BIN="$TEST_DIR/bin"
mkdir -- "$BIN"
for tool in cmp cp find flock grep mkdir mktemp mv rm sed chmod sort comm chown id stat; do ln -s -- "$(command -v "$tool")" "$BIN/$tool"; done
run_path() { RC=0; OUTPUT=$(PATH="$BIN"; hash -r; main "$@" < /dev/null 2>&1) || RC=$?; }
new_case
rm -r -- "$K2S_WA_ROOT"
run_path provision
expect_rc 4 'provision without openssl is refused'
check 'provision names the missing openssl' output_has 'missing required tools: openssl'
check 'refused provision creates no root directory' [ ! -e "$K2S_WA_ROOT" ]
ln -s -- "$(command -v openssl)" "$BIN/openssl"
for cmd in publish ensure-apiserver; do
    run_path "$cmd"
    expect_rc 4 "$cmd without kubectl is refused"
    check "$cmd names the missing kubectl" output_has 'missing required tools: kubectl'
done
check 'refused commands create no root directory' [ ! -e "$K2S_WA_ROOT" ]
ln -s -- "$(command -v kubectl)" "$BIN/kubectl"
mkdir -p -- "$K2S_WA_MANIFEST_DIR"
cp -- "$FIXTURE" "$K2S_WA_MANIFEST"
run_path ensure-apiserver
expect_rc 4 'ensure-apiserver without sync is refused'
check 'ensure-apiserver names the missing sync' output_has 'missing required tools: sync'
check 'refused ensure-apiserver leaves the manifest unchanged' cmp -s -- "$FIXTURE" "$K2S_WA_MANIFEST"
run_path verify
expect_rc 4 'verify without timeout, awk and base64 is refused'
check 'verify names its missing tools' output_has 'missing required tools: timeout awk base64'
check 'refused verify prints no result line' output_lacks 'K2S-WEBHOOK-AUTH-VERIFY'
run_path renew
expect_rc 4 'renew without timeout, awk, base64 and sync is refused'
check 'renew names its missing tools' output_has 'missing required tools: timeout awk base64 sync'
ln -s -- "$(command -v sync)" "$BIN/sync"
for cmd in provision ensure-apiserver publish; do
    run_path "$cmd"
    expect_rc 0 "$cmd needs only its declared tools"
done

# --- injected openssl failures ---
fail_ca_cert() { openssl() { if [[ "$1 $2 $3" == 'req -new -x509' ]]; then printf 'injected failure\n' >&2; return 1; fi; command openssl "$@"; }; }
fail_genpkey() { openssl() { if [[ "$1" == genpkey ]]; then printf 'injected failure\n' >&2; return 1; fi; command openssl "$@"; }; }
fail_signing() { openssl() { if [[ "$1 $2" == 'x509 -req' ]]; then printf 'injected failure\n' >&2; return 1; fi; command openssl "$@"; }; }
for injected in fail_ca_cert:'CA certificate generation failed: injected failure' fail_genpkey:'key generation failed: injected failure'; do
    new_case
    run_with "${injected%%:*}" provision
    expect_rc 1 "${injected%%:*}: CA generation failure fails provisioning"
    check "${injected%%:*}: reports the openssl error" output_has "client CA generation failed: ${injected#*:}"
    check "${injected%%:*}: no success marker" no_marker
    check "${injected%%:*}: no partial CA or credentials" [ ! -e "$K2S_WA_CA_DIR" -a ! -e "$K2S_WA_AUTH_DIR" ]
    check "${injected%%:*}: no temporary files remain" no_leftovers
    run provision
    expect_rc 0 "${injected%%:*}: the next provision run recovers"
done
provisioned_case
rm -- "$K2S_WA_AUTH_DIR/client.crt" "$K2S_WA_AUTH_DIR/client.key"
run_with fail_genpkey provision
expect_rc 1 'client key generation failure fails provisioning'
check 'client key generation failure is reported' output_has 'cannot issue the kube-apiserver client certificate: key generation failed: injected failure'
check 'no client certificate or key is installed' [ ! -e "$K2S_WA_AUTH_DIR/client.crt" -a ! -e "$K2S_WA_AUTH_DIR/client.key" ]
check 'no temporary files remain after the client key failure' no_leftovers
run provision
expect_rc 0 'provision recovers after the client key failure'
provisioned_case
key="$K2S_WA_AUTH_DIR/client.key"
make_cert "$K2S_WA_AUTH_DIR/client.crt" "$key" "$K2S_WA_CA_DIR/ca.crt" "$K2S_WA_CA_DIR/ca.key" client '-1 day' '+10 days'
cp -p -- "$K2S_WA_AUTH_DIR/client.crt" "$CASE_DIR/old.crt"
cp -p -- "$key" "$CASE_DIR/old.key"
run_with fail_signing provision
expect_rc 1 'failed renewal fails provisioning'
check 'failed renewal is reported' output_has 'cannot issue the kube-apiserver client certificate: client certificate signing failed: injected failure'
check 'failed renewal keeps the previous certificate and key' cmp -s -- "$CASE_DIR/old.crt" "$K2S_WA_AUTH_DIR/client.crt"
check 'failed renewal keeps the previous key' cmp -s -- "$CASE_DIR/old.key" "$key"
check 'no temporary files remain after the failed renewal' no_leftovers
run provision
expect_rc 0 'renewal succeeds once signing works'
check 'renewal keeps the existing key' cmp -s -- "$CASE_DIR/old.key" "$key"
check 'renewal replaces the certificate' not cmp -s -- "$CASE_DIR/old.crt" "$K2S_WA_AUTH_DIR/client.crt"
check 'renewed certificate is valid' k2s_wa_check_client_cert "$K2S_WA_AUTH_DIR/client.crt" "$key" "$K2S_WA_CA_DIR/ca.crt"

# --- invalid client certificates and keys are replaced ---
corrupt_cert() { printf 'garbage\n' > "$CRT"; }
bundle_cert() { cat -- "$CA_CRT" >> "$CRT"; }
embedded_key() { cat -- "$KEY" >> "$CRT"; }
near_expiry() { make_cert "$CRT" "$KEY" "$CA_CRT" "$CA_KEY" client '-1 day' '+10 days'; }
expired_cert() { make_cert "$CRT" "$KEY" "$CA_CRT" "$CA_KEY" client '-20 days' '-1 day'; }
future_cert() { make_cert "$CRT" "$KEY" "$CA_CRT" "$CA_KEY" client '+1 day' '+100 days'; }
server_auth_cert() { make_cert "$CRT" "$KEY" "$CA_CRT" "$CA_KEY" server '-1 day' '+100 days'; }
no_eku_cert() { make_cert "$CRT" "$KEY" "$CA_CRT" "$CA_KEY" noeku '-1 day' '+100 days'; }
foreign_cert() { make_cert "$CRT" "$KEY" "$FOREIGN_CRT" "$FOREIGN_KEY" client '-1 day' '+100 days'; }
mismatched_cert() { new_key "$CASE_DIR/other.key"; make_cert "$CRT" "$CASE_DIR/other.key" "$CA_CRT" "$CA_KEY" client '-1 day' '+100 days'; }
ca_as_client() { cp -- "$CA_CRT" "$CRT"; }
corrupt_key() { printf 'garbage\n' > "$KEY"; }
ca_key_as_client_key() { cp -- "$CA_KEY" "$KEY"; }
ca_key_symlink() { rm -- "$KEY"; ln -s -- "$CA_KEY" "$KEY"; }
while IFS='|' read -r setup key_mode reason; do
    provisioned_case
    CRT="$K2S_WA_AUTH_DIR/client.crt" KEY="$K2S_WA_AUTH_DIR/client.key" CA_CRT="$K2S_WA_CA_DIR/ca.crt" CA_KEY="$K2S_WA_CA_DIR/ca.key"
    old_key=$(key_id "$KEY")
    cp -p -- "$CA_KEY" "$CASE_DIR/ca.key.orig"
    cp -p -- "$CA_CRT" "$CASE_DIR/ca.crt.orig"
    "$setup"
    run provision
    expect_rc 0 "$setup: provision issues a new client certificate"
    check "$setup: reports why" output_has "issuing kube-apiserver client certificate: $reason"
    check "$setup: new certificate is valid for the client key and CA" k2s_wa_check_client_cert "$CRT" "$KEY" "$CA_CRT"
    check "$setup: client key is a regular file" [ -f "$KEY" -a ! -L "$KEY" ]
    if [[ "$key_mode" == kept ]]; then
        check "$setup: client key is kept" [ "$(key_id "$KEY")" = "$old_key" ]
    else
        check "$setup: client key is replaced" [ "$(key_id "$KEY")" != "$old_key" ]
    fi
    check "$setup: client key is not the CA key" [ "$(key_id "$KEY")" != "$(key_id "$CA_KEY")" ]
    check "$setup: client CA is unchanged" cmp -s -- "$CASE_DIR/ca.key.orig" "$CA_KEY"
    check "$setup: client CA certificate is unchanged" cmp -s -- "$CASE_DIR/ca.crt.orig" "$CA_CRT"
    check "$setup: credential directory holds only the expected files" listing_is "$K2S_WA_AUTH_DIR" 'admission-config.yaml client.crt client.key kubeconfig'
    check "$setup: no temporary files remain" no_leftovers
done <<'EOF'
corrupt_cert|kept|client certificate is not a single PEM certificate
bundle_cert|kept|client certificate is not a single PEM certificate
embedded_key|kept|client certificate is not a single PEM certificate
near_expiry|kept|client certificate expires within 30 days
expired_cert|kept|client certificate is not valid for the client CA: 
future_cert|kept|client certificate is not valid for the client CA: 
server_auth_cert|kept|client certificate is not valid for the client CA: 
no_eku_cert|kept|client certificate lacks the clientAuth extended key usage
foreign_cert|kept|client certificate is not valid for the client CA: 
mismatched_cert|kept|client key does not belong to the client certificate
ca_as_client|kept|client certificate 
corrupt_key|new|client key is not a valid unencrypted private key
ca_key_as_client_key|new|client key is the client CA key
ca_key_symlink|new|client key is the client CA key
EOF
# openssl verify reasons for certificates that do not chain or are not usable now.
for variant in expired_cert:'certificate has expired' future_cert:'certificate is not yet valid' \
    server_auth_cert:'unsupported certificate purpose' foreign_cert:'unable to get local issuer certificate'; do
    provisioned_case
    CRT="$K2S_WA_AUTH_DIR/client.crt" KEY="$K2S_WA_AUTH_DIR/client.key" CA_CRT="$K2S_WA_CA_DIR/ca.crt" CA_KEY="$K2S_WA_CA_DIR/ca.key"
    "${variant%%:*}"
    check "${variant%%:*}: rejected as '${variant#*:}'" not k2s_wa_check_client_cert "$CRT" "$KEY" "$CA_CRT"
    check "${variant%%:*}: reason names '${variant#*:}'" reason_has "${variant#*:}"
done

# --- an unusable client CA is never replaced automatically ---
corrupt_ca() { printf 'garbage\n' > "$CA_CRT"; }
mismatched_ca_key() { new_key "$CA_KEY"; }
expired_ca() { make_cert "$CA_CRT" "$CA_KEY" self '' ca_cert '-3000 days' '-1 day'; }
expiring_ca() { make_cert "$CA_CRT" "$CA_KEY" self '' ca_cert '-1 day' '+100 days'; }
missing_ca_key() { rm -- "$CA_KEY"; }
non_ca() { make_cert "$CA_CRT" "$CA_KEY" self '' client '-1 day' '+1000 days'; }
encrypted_ca_key() { openssl pkey -in "$CA_KEY" -aes256 -passout pass:secret -out "$CASE_DIR/encrypted.key"; mv -- "$CASE_DIR/encrypted.key" "$CA_KEY"; }
symlinked_ca_dir() { mv -- "$K2S_WA_CA_DIR" "$CASE_DIR/real-ca"; ln -s -- "$CASE_DIR/real-ca" "$K2S_WA_CA_DIR"; }
file_ca_dir() { rm -r -- "$K2S_WA_CA_DIR"; printf 'x\n' > "$K2S_WA_CA_DIR"; }
while IFS='|' read -r setup reason; do
    provisioned_case
    CA_CRT="$K2S_WA_CA_DIR/ca.crt" CA_KEY="$K2S_WA_CA_DIR/ca.key"
    "$setup"
    before=$(snapshot)
    run provision
    expect_rc 1 "$setup: provision refuses the client CA"
    check "$setup: reports why" output_has "$reason"
    if [[ "$reason" == 'is not a directory' ]]; then
        check "$setup: names the CA path" output_has "'$K2S_WA_CA_DIR' is not a directory"
    else
        check "$setup: names the CA directory" output_has "existing client CA in '$K2S_WA_CA_DIR' is not usable: $reason"
        check "$setup: explains that the CA is never replaced automatically" output_has 'it is never replaced automatically'
    fi
    check "$setup: nothing changed" [ "$(snapshot)" = "$before" ]
    check "$setup: no success marker" no_marker
done <<'EOF'
corrupt_ca|ca.crt is not a single PEM certificate
mismatched_ca_key|ca.key does not belong to ca.crt
expired_ca|ca.crt is not valid: 
expiring_ca|ca.crt expires within 395 days
missing_ca_key|ca.crt or ca.key is missing
non_ca|ca.crt is not a CA certificate
encrypted_ca_key|ca.key is not a valid unencrypted private key
symlinked_ca_dir|is not a directory
file_ca_dir|is not a directory
EOF
provisioned_case
CA_CRT="$K2S_WA_CA_DIR/ca.crt" CA_KEY="$K2S_WA_CA_DIR/ca.key"
expired_ca
check 'an expired CA is reported by openssl' not k2s_wa_check_ca "$K2S_WA_CA_DIR"
check 'expired CA reason' reason_has 'certificate has expired'
corrupt_ca
cp -- "$FIXTURE" "$K2S_WA_MANIFEST"
run publish
expect_rc 1 'publish refuses an invalid client CA'
check 'publish asks to provision first' output_has 'is missing or invalid (ca.crt is not a single PEM certificate); run provision first'
check 'publish does not contact the cluster with an invalid CA' [ ! -e "$CASE_DIR/kubectl.log" ]
run ensure-apiserver
expect_rc 1 'ensure-apiserver refuses an invalid client CA'
check 'ensure-apiserver leaves the manifest unchanged with an invalid CA' cmp -s -- "$FIXTURE" "$K2S_WA_MANIFEST"
check 'ensure-apiserver creates no backup with an invalid CA' [ ! -e "$K2S_WA_BACKUP_DIR" ]
check 'ensure-apiserver does not contact the cluster with an invalid CA' [ ! -e "$CASE_DIR/kubectl.log" ]

# --- the credential directory is mounted into kube-apiserver and must hold only the expected files ---
for entry in extra-file subdirectory ca-key-copy symlink; do
    provisioned_case
    case "$entry" in
        extra-file) printf 'x\n' > "$K2S_WA_AUTH_DIR/$entry" ;;
        subdirectory) mkdir -- "$K2S_WA_AUTH_DIR/$entry" ;;
        ca-key-copy) cp -- "$K2S_WA_CA_DIR/ca.key" "$K2S_WA_AUTH_DIR/$entry" ;;
        symlink) ln -s -- "$K2S_WA_CA_DIR/ca.key" "$K2S_WA_AUTH_DIR/$entry" ;;
    esac
    run provision
    expect_rc 1 "$entry in the credential directory is refused"
    check "$entry is named" output_has "unexpected entries in '$K2S_WA_AUTH_DIR', which is mounted into kube-apiserver: $K2S_WA_AUTH_DIR/$entry"
    check "$entry: no success marker" no_marker
done

# --- leftovers of an interrupted run are removed; unrelated files are kept ---
provisioned_case
mkdir -p -- "$K2S_WA_BACKUP_DIR" "$K2S_WA_ROOT/.k2s-webhook-auth-ca.tmp.Ab12Cd"
printf 'x\n' > "$K2S_WA_ROOT/.k2s-webhook-auth-ca.tmp.Ab12Cd/ca.key"
printf 'x\n' > "$K2S_WA_AUTH_DIR/.client.key.tmp.Ab12Cd"
printf 'x\n' > "$K2S_WA_PATCH_DIR/.kube-apiserver+json.json.tmp.Ab12Cd"
printf 'x\n' > "$K2S_WA_BACKUP_DIR/.kube-apiserver.yaml.tmp.Ab12Cd"
printf 'x\n' > "$K2S_WA_MANIFEST_DIR/.kube-apiserver.yaml.k2s-webhook-auth.Ab12Cd"
printf 'keep\n' > "$K2S_WA_MANIFEST_DIR/etcd.yaml"
printf 'keep\n' > "$K2S_WA_PATCH_DIR/etcd+json.json"
run provision
expect_rc 0 'provision after an interrupted run succeeds'
check 'leftovers of the interrupted run are removed' no_leftovers
check 'unrelated manifests and patches are kept' [ "$(cat -- "$K2S_WA_MANIFEST_DIR/etcd.yaml" "$K2S_WA_PATCH_DIR/etcd+json.json")" = $'keep\nkeep' ]

# --- damaged or missing rendered files and credentials are repaired ---
remove_auth_dir() { rm -r -- "$K2S_WA_AUTH_DIR"; }
remove_cert() { rm -- "$K2S_WA_AUTH_DIR/client.crt"; }
remove_key() { rm -- "$K2S_WA_AUTH_DIR/client.key"; }
remove_kubeconfig() { rm -- "$K2S_WA_AUTH_DIR/kubeconfig"; }
tamper_kubeconfig() { printf 'current-context: other\n' >> "$K2S_WA_AUTH_DIR/kubeconfig"; }
symlink_kubeconfig() { cp -- "$K2S_WA_AUTH_DIR/kubeconfig" "$CASE_DIR/kubeconfig"; ln -sf -- "$CASE_DIR/kubeconfig" "$K2S_WA_AUTH_DIR/kubeconfig"; }
tamper_admission_config() { printf 'kind: Other\n' > "$K2S_WA_AUTH_DIR/admission-config.yaml"; }
remove_patch_dir() { rm -r -- "$K2S_WA_PATCH_DIR"; }
tamper_patch() { printf '[]\n' > "$K2S_WA_PATCH_FILE"; }
for damage in remove_auth_dir remove_cert remove_key remove_kubeconfig tamper_kubeconfig symlink_kubeconfig \
    tamper_admission_config remove_patch_dir tamper_patch; do
    provisioned_case
    "$damage"
    run provision
    expect_rc 0 "$damage: provision repairs the credentials"
    check "$damage: client certificate is valid" k2s_wa_check_client_cert "$K2S_WA_AUTH_DIR/client.crt" "$K2S_WA_AUTH_DIR/client.key" "$K2S_WA_CA_DIR/ca.crt"
    check "$damage: kubeconfig is restored" cmp -s -- "$K2S_WA_AUTH_DIR/kubeconfig" "$TEST_DIR/kubeconfig.golden"
    check "$damage: kubeconfig is a regular file" [ -f "$K2S_WA_AUTH_DIR/kubeconfig" -a ! -L "$K2S_WA_AUTH_DIR/kubeconfig" ]
    check "$damage: AdmissionConfiguration is restored" cmp -s -- "$K2S_WA_AUTH_DIR/admission-config.yaml" "$TEST_DIR/admission-config.golden"
    check "$damage: kubeadm patch is restored" cmp -s -- "$K2S_WA_PATCH_FILE" <(k2s_wa_render_patch)
    check "$damage: credential directory holds only the expected files" listing_is "$K2S_WA_AUTH_DIR" 'admission-config.yaml client.crt client.key kubeconfig'
    check "$damage: permissions" modes_are 755 "$K2S_WA_AUTH_DIR" 600 "$K2S_WA_AUTH_DIR/client.key" 600 "$K2S_WA_AUTH_DIR/kubeconfig" \
        644 "$K2S_WA_AUTH_DIR/client.crt" 644 "$K2S_WA_AUTH_DIR/admission-config.yaml" 644 "$K2S_WA_PATCH_FILE"
    check "$damage: no temporary files remain" no_leftovers
done

# --- kube-apiserver static Pod manifest: configuration ---
expected_added() {
    printf '%s\n' "    - $K2S_WA_FLAG" "    - mountPath: $K2S_WA_POD_DIR" "      name: $K2S_WA_VOLUME" '      readOnly: true' \
        '  - hostPath:' "      path: $K2S_WA_AUTH_DIR" '      type: Directory' "    name: $K2S_WA_VOLUME"
}
manifest_case
check 'fixture has no admission configuration' manifest_state_is absent
run ensure-apiserver
expect_rc 0 'ensure-apiserver configures kube-apiserver'
check 'ensure-apiserver prints its success marker last' marker_is ensure-apiserver
check 'ensure-apiserver backs up the manifest' output_has "backed up '$K2S_WA_MANIFEST' to '$K2S_WA_BACKUP_FILE'"
check 'ensure-apiserver waits for kube-apiserver with the configuration' output_has 'kube-apiserver is ready with the admission configuration'
check 'backup is the original manifest' cmp -s -- "$FIXTURE" "$K2S_WA_BACKUP_FILE"
check 'backup is private' modes_are 700 "$K2S_WA_BACKUP_DIR" 600 "$K2S_WA_BACKUP_FILE"
check 'manifest keeps its permissions' modes_are 600 "$K2S_WA_MANIFEST"
check 'manifests directory holds only the manifest' listing_is "$K2S_WA_MANIFEST_DIR" 'kube-apiserver.yaml'
check 'manifest gains exactly the flag, the read-only mount and the volume' added_lines_are "$FIXTURE" "$K2S_WA_MANIFEST" "$(expected_added)"
check 'manifest equals the kubeadm patch result' cmp -s -- "$K2S_WA_MANIFEST" \
    <(KUBECONFIG=/dev/null kubectl patch --local -f "$FIXTURE" --type=json --patch-file "$K2S_WA_PATCH_FILE" -o yaml)
check 'manifest is configured' manifest_state_is configured
check 'only kube-apiserver readiness was queried' only_readyz_calls
check 'no temporary files remain' no_leftovers
inode=$(stat -c %i -- "$K2S_WA_MANIFEST")
backup=$(stat -c '%i %Y' -- "$K2S_WA_BACKUP_FILE")
run ensure-apiserver
expect_rc 0 'ensure-apiserver rerun succeeds'
check 'ensure-apiserver rerun detects the configuration' output_has 'kube-apiserver manifest already contains the admission configuration'
check 'ensure-apiserver rerun does not rewrite the manifest' [ "$(stat -c %i -- "$K2S_WA_MANIFEST")" = "$inode" ]
check 'ensure-apiserver rerun keeps the backup of the original manifest' [ "$(stat -c '%i %Y' -- "$K2S_WA_BACKUP_FILE")" = "$backup" ]
check 'ensure-apiserver rerun takes no new backup' output_lacks 'backed up'

# --- kube-apiserver static Pod manifest: foreign or incomplete configuration is never changed ---
flag_op='{"op":"add","path":"/spec/containers/0/command/-","value":"@FLAG@"}'
mount_op='{"op":"add","path":"/spec/containers/0/volumeMounts/-","value":{"name":"k2s-webhook-auth","mountPath":"@POD@","readOnly":true}}'
volume_op='{"op":"add","path":"/spec/volumes/-","value":{"name":"k2s-webhook-auth","hostPath":{"path":"@AUTH@","type":"Directory"}}}'
while IFS='|' read -r conflict state ops; do
    manifest_case
    ops="${ops//@FLAG_OP@/$flag_op}"
    ops="${ops//@MOUNT_OP@/$mount_op}"
    ops="${ops//@VOLUME_OP@/$volume_op}"
    ops="${ops//@FLAG@/$K2S_WA_FLAG}"
    ops="${ops//@POD@/$K2S_WA_POD_DIR}"
    ops="${ops//@AUTH@/$K2S_WA_AUTH_DIR}"
    KUBECONFIG=/dev/null kubectl patch --local -f "$FIXTURE" --type=json -p "[$ops]" -o yaml > "$K2S_WA_MANIFEST"
    cp -p -- "$K2S_WA_MANIFEST" "$CASE_DIR/original.yaml"
    check "$conflict: manifest is $state" manifest_state_is "$state"
    run ensure-apiserver
    expect_rc 3 "$conflict: ensure-apiserver refuses the manifest"
    if [[ "$state" == custom ]]; then
        check "$conflict: reports the foreign configuration" output_has 'kube-apiserver already uses another --admission-control-config-file'
    else
        check "$conflict: reports the incomplete configuration" output_has 'contains an incomplete clusterip-webhook admission configuration'
    fi
    check "$conflict: manifest is unchanged" cmp -s -- "$CASE_DIR/original.yaml" "$K2S_WA_MANIFEST"
    check "$conflict: no backup is taken" [ ! -e "$K2S_WA_BACKUP_DIR" ]
    check "$conflict: the cluster is not contacted" [ ! -e "$CASE_DIR/kubectl.log" ]
    check "$conflict: no temporary files remain" no_leftovers
done <<'EOF'
custom-flag|custom|{"op":"add","path":"/spec/containers/0/command/-","value":"--admission-control-config-file=/etc/kubernetes/custom.yaml"}
separate-argument|custom|{"op":"add","path":"/spec/containers/0/command/-","value":"--admission-control-config-file"},{"op":"add","path":"/spec/containers/0/command/-","value":"/etc/kubernetes/custom.yaml"}
args-flag|custom|{"op":"add","path":"/spec/containers/0/args","value":["@FLAG@"]},@MOUNT_OP@,@VOLUME_OP@
other-container-flag|custom|{"op":"add","path":"/spec/containers/-","value":{"name":"sidecar","image":"sidecar","command":["@FLAG@"]}}
duplicate-flag|partial|@FLAG_OP@,@FLAG_OP@,@MOUNT_OP@,@VOLUME_OP@
flag-only|partial|@FLAG_OP@
mount-only|partial|@MOUNT_OP@
volume-only|partial|@VOLUME_OP@
writable-mount|partial|@FLAG_OP@,{"op":"add","path":"/spec/containers/0/volumeMounts/-","value":{"name":"k2s-webhook-auth","mountPath":"@POD@","readOnly":false}},@VOLUME_OP@
other-host-path|partial|@FLAG_OP@,@MOUNT_OP@,{"op":"add","path":"/spec/volumes/-","value":{"name":"k2s-webhook-auth","hostPath":{"path":"/var/lib/other","type":"Directory"}}}
annotation|partial|{"op":"add","path":"/metadata/annotations/example.com~1note","value":"k2s-webhook-auth"}
EOF
manifest_case
sed 's/^    - --allow-privileged=true$/    - "--allow-privileged=true"/' "$FIXTURE" > "$K2S_WA_MANIFEST"
cp -p -- "$K2S_WA_MANIFEST" "$CASE_DIR/original.yaml"
run ensure-apiserver
expect_rc 3 'a manifest that kubectl would rewrite is refused'
check 'the rewritten line is reported' output_has $'Affected lines:\n        - "--allow-privileged=true"'
check 'the manifest that kubectl would rewrite is unchanged' cmp -s -- "$CASE_DIR/original.yaml" "$K2S_WA_MANIFEST"
check 'no backup is taken for a manifest that kubectl would rewrite' [ ! -e "$K2S_WA_BACKUP_DIR" ]
check 'no temporary files remain after the refused rewrite' no_leftovers
# A kubectl version that emits an additional line while patching (here: a duplicated argument).
extra_patched_line() {
    eval "real_$(declare -f k2s_wa_kubectl_local)"
    k2s_wa_kubectl_local() {
        if [[ " $* " != *' --patch-file '* ]]; then real_k2s_wa_kubectl_local "$@"; return; fi
        real_k2s_wa_kubectl_local "$@" | sed 's/^    - --allow-privileged=true$/&\n&/'
    }
}
manifest_case
run_with extra_patched_line ensure-apiserver
expect_rc 1 'a patch that adds unexpected lines is refused'
check 'the unexpected number of added lines is reported' output_has 'added 9 lines instead of 8. Nothing was changed.'
check 'the manifest is unchanged after unexpected added lines' cmp -s -- "$FIXTURE" "$K2S_WA_MANIFEST"
check 'no backup is taken after unexpected added lines' [ ! -e "$K2S_WA_BACKUP_DIR" ]
check 'no temporary files remain after unexpected added lines' no_leftovers

# --- kube-apiserver static Pod manifest: failures, restore and recovery ---
manifest_case
sed 's/^    name: kube-apiserver$/    name: apiserver/' "$FIXTURE" > "$K2S_WA_MANIFEST"
cp -p -- "$K2S_WA_MANIFEST" "$CASE_DIR/original.yaml"
run ensure-apiserver
expect_rc 1 'a manifest without the kube-apiserver container is not patched'
check 'the failed patch is reported' output_has "cannot apply '$K2S_WA_PATCH_FILE' to '$K2S_WA_MANIFEST'"
check 'the unpatchable manifest is unchanged' cmp -s -- "$CASE_DIR/original.yaml" "$K2S_WA_MANIFEST"
check 'no backup is taken for the unpatchable manifest' [ ! -e "$K2S_WA_BACKUP_DIR" ]
check 'no temporary files remain after the failed patch' no_leftovers
for mode in unready down; do
    manifest_case
    APISERVER="$mode"
    run ensure-apiserver
    expect_rc 1 "kube-apiserver $mode before the change: ensure-apiserver fails"
    check "kube-apiserver $mode before the change: reported" output_has 'kube-apiserver is not ready; its manifest was not changed'
    check "kube-apiserver $mode before the change: waits with progress messages" output_has 'waiting for kube-apiserver (noflag)'
    check "kube-apiserver $mode before the change: manifest unchanged" cmp -s -- "$FIXTURE" "$K2S_WA_MANIFEST"
    check "kube-apiserver $mode before the change: no backup" [ ! -e "$K2S_WA_BACKUP_DIR" ]
    check "kube-apiserver $mode before the change: no success marker" no_marker
done
manifest_case
APISERVER=flag-crashes
run ensure-apiserver
expect_rc 5 'kube-apiserver failing with the configuration: previous manifest restored'
check 'the failed restart is reported' output_has 'kube-apiserver did not become ready with the admission configuration; restoring the previous manifest'
check 'the recovery is reported' output_has 'previous kube-apiserver manifest restored; kube-apiserver recovered'
check 'the original manifest is restored' cmp -s -- "$FIXTURE" "$K2S_WA_MANIFEST"
check 'the restored manifest keeps its permissions' modes_are 600 "$K2S_WA_MANIFEST"
check 'the backup is kept after the restore' cmp -s -- "$FIXTURE" "$K2S_WA_BACKUP_FILE"
check 'no success marker after the restore' no_marker
check 'no temporary files remain after the restore' no_leftovers
check 'only kube-apiserver readiness was queried during the restore' only_readyz_calls
manifest_case
APISERVER=flag-breaks-cluster
run ensure-apiserver
expect_rc 6 'kube-apiserver not recovering after the restore: recovery not verified'
check 'the missing recovery is reported' output_has 'previous kube-apiserver manifest restored, but kube-apiserver did not recover'
check 'the original manifest is restored although kube-apiserver did not recover' cmp -s -- "$FIXTURE" "$K2S_WA_MANIFEST"
check 'no success marker without recovery' no_marker
fail_restore() { k2s_wa_restore_manifest() { return 1; }; }
manifest_case
APISERVER=flag-crashes
run_with fail_restore ensure-apiserver
expect_rc 6 'a failed restore is reported as unrecovered'
check 'the failed restore names the backup' output_has "cannot restore '$K2S_WA_MANIFEST' from '$K2S_WA_BACKUP_FILE'; restore it manually"
check 'the backup of the original manifest is available after the failed restore' cmp -s -- "$FIXTURE" "$K2S_WA_BACKUP_FILE"
check 'the manifest is left configured after the failed restore' manifest_state_is configured
check 'no success marker after the failed restore' no_marker
# Something else writes the manifest right after the restore (for example a concurrent kubeadm run).
concurrent_write_after_restore() {
    mv() {
        command mv "$@" || return
        if [[ "${!#}" == "$K2S_WA_MANIFEST" ]] && ! grep -q -F -- "$K2S_WA_FLAG" "$K2S_WA_MANIFEST"; then
            printf '# written concurrently\n' >> "$K2S_WA_MANIFEST"
        fi
    }
}
manifest_case
APISERVER=flag-crashes
run_with concurrent_write_after_restore ensure-apiserver
expect_rc 6 'a restored manifest that differs from the backup is reported as unrecovered'
check 'the unverified restore names the backup' output_has "cannot restore '$K2S_WA_MANIFEST' from '$K2S_WA_BACKUP_FILE'; restore it manually"
check 'the backup is kept after the unverified restore' cmp -s -- "$FIXTURE" "$K2S_WA_BACKUP_FILE"
check 'no success marker after the unverified restore' no_marker
manifest_case
run ensure-apiserver
expect_rc 0 'ensure-apiserver setup for a configured manifest'
inode=$(stat -c %i -- "$K2S_WA_MANIFEST")
APISERVER=down
run ensure-apiserver
expect_rc 1 'configured manifest with kube-apiserver down: ensure-apiserver fails'
check 'configured manifest with kube-apiserver down: reported with the backup path' \
    output_has "kube-apiserver is not ready with the admission configuration; the manifest was not changed (backup of the manifest before this script last changed it: '$K2S_WA_BACKUP_FILE')"
check 'configured manifest with kube-apiserver down: never restored automatically' [ "$(stat -c %i -- "$K2S_WA_MANIFEST")" = "$inode" ]
check 'configured manifest with kube-apiserver down: still configured' manifest_state_is configured
new_case
run ensure-apiserver
expect_rc 1 'ensure-apiserver without a kube-apiserver manifest fails'
check 'the missing manifest is reported' output_has "kube-apiserver manifest '$K2S_WA_MANIFEST' not found"

# --- interruptions: signals and lost output around the manifest replacement ---
# The run signals itself at fixed points (kill to $BASHPID is handled before kill returns), so no timing is
# involved. kube-apiserver is mocked: the tests show that the script keeps control until the replaced manifest
# is confirmed or the previous one restored, not that a real kube-apiserver recovers. SIGQUIT is never sent
# (core dump); like SIGINT and SIGTERM it is checked through the dispositions that started commands inherit.
child_sigign() {
    local status line
    status=$(command -p cat /proc/self/status) || return 1
    while IFS= read -r line; do
        if [[ "$line" =~ ^SigIgn:[[:space:]]*([0-9a-f]+)$ ]]; then
            printf '%d\n' "$((16#${BASH_REMATCH[1]}))"
            return 0
        fi
    done <<< "$status"
    return 1
}
SIG_HUP_PIPE=$((0x1001))
SIG_INT_TERM_QUIT=$((0x4006))
SIG_WATCHED=$((SIG_HUP_PIPE | SIG_INT_TERM_QUIT))
BASE_SIGIGN=$(child_sigign)
CAT_BIN=$(type -P cat)
HOOK_POINT='' HOOK_SIGNAL='' OUTPUT_READER=''
# ignored_signals_are <file written by child_sigign> <mask>: compares SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM.
ignored_signals_are() {
    local actual
    actual=$(<"$1") || return 1
    (( (actual & SIG_WATCHED) == ($2 & SIG_WATCHED) )) && return 0
    printf 'ignored signals 0x%x, expected 0x%x\n' "$((actual & SIG_WATCHED))" "$(($2 & SIG_WATCHED))"
    return 1
}
# The kubelet runs every file in the manifests directory except dot-files.
kubelet_sees_only_the_manifest() {
    local files
    files=$(find "$K2S_WA_MANIFEST_DIR" -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%f\n') || return 1
    [[ "$files" == kube-apiserver.yaml ]] || { printf 'manifests directory: %s\n' "${files//$'\n'/ }"; return 1; }
}
# At HOOK_POINT (once per case): records the ignored signals, then sends HOOK_SIGNAL to the run or, without
# HOOK_SIGNAL, ends the reader of the run's output (a lost SSH session) and writes a probe line.
hook_fire() {
    [[ "$1" == "$HOOK_POINT" && ! -e "$CASE_DIR/hook-fired" ]] || return 0
    : > "$CASE_DIR/hook-fired"
    child_sigign > "$CASE_DIR/sigign-$1"
    if [[ -n "$HOOK_SIGNAL" ]]; then
        kill -s "$HOOK_SIGNAL" "$BASHPID"
    else
        kill -s KILL "$OUTPUT_READER"
        wait "$OUTPUT_READER" 2>/dev/null || :
        printf 'output probe\n' 2>/dev/null || : > "$CASE_DIR/output-lost"
    fi
    : > "$CASE_DIR/survived"
}
# Points: before (polling kube-apiserver before the change), backup (copying the manifest to the backup),
# swapped (manifest replaced), waiting (polling with the replaced manifest), restore (copying the backup back),
# recovery (polling after the restore).
interruption_hooks() {
    eval "hooked_$(declare -f k2s_wa_apiserver_process_states)"
    k2s_wa_apiserver_process_states() {
        if [[ -e "$CASE_DIR/restored" ]]; then
            hook_fire recovery
        elif grep -q -F -- "$K2S_WA_FLAG" "$K2S_WA_MANIFEST"; then
            hook_fire waiting
        else
            hook_fire before
        fi
        hooked_k2s_wa_apiserver_process_states
    }
    cp() {
        case "${!#}" in
            "$K2S_WA_BACKUP_DIR"/.kube-apiserver.yaml.tmp.*) hook_fire backup ;;
            "$K2S_WA_MANIFEST_DIR"/.kube-apiserver.yaml.k2s-webhook-auth.*) hook_fire restore ;;
        esac
        command cp "$@"
    }
    mv() {
        command mv "$@" || return
        if [[ "${!#}" == "$K2S_WA_MANIFEST" ]]; then
            if grep -q -F -- "$K2S_WA_FLAG" "$K2S_WA_MANIFEST"; then hook_fire swapped; else : > "$CASE_DIR/restored"; fi
        fi
        return 0
    }
}
# Like run_with; also records the signals ignored after main returned.
run_signals() {
    local setup="$1"
    shift
    RC=0
    # Without a SIGINT trap, bash ends itself when a command substitution is ended by SIGINT.
    trap ':' INT
    OUTPUT=$({ "$setup" || exit; main "$@"; rc=$?; child_sigign > "$CASE_DIR/sigign-after"; exit "$rc"; } < /dev/null 2>&1) || RC=$?
    trap - INT
}
# Runs main with its output going through a FIFO to a reader that hook_fire ends.
run_output_lost() {
    RC=0
    mkfifo -- "$CASE_DIR/output"
    OUTPUT=$({
        "$CAT_BIN" > "$CASE_DIR/delivered" 2>/dev/null < "$CASE_DIR/output" &
        OUTPUT_READER=$!
        interruption_hooks
        rc=0
        main "$@" > "$CASE_DIR/output" 2>&1 || rc=$?
        wait "$OUTPUT_READER" 2>/dev/null || :
        exit "$rc"
    } < /dev/null 2>&1) || RC=$?
    OUTPUT="$OUTPUT$(<"$CASE_DIR/delivered")"
}
# point|signal|kube-apiserver|exit code|outcome. SIGINT, SIGTERM and SIGQUIT are ignored from swapped to recovery.
while IFS='|' read -r point signal mode want outcome; do
    desc="SIG$signal at $point ($mode)"
    protected=0
    case "$point" in swapped | waiting | restore | recovery) protected=$SIG_INT_TERM_QUIT ;; esac
    case "$signal" in HUP) bit=$((0x1)) ;; INT) bit=$((0x2)) ;; PIPE) bit=$((0x1000)) ;; TERM) bit=$((0x4000)) ;; esac
    if (( want > 128 && (BASE_SIGIGN & bit) != 0 )); then
        printf 'SKIP: %s (the tests run with SIG%s ignored)\n' "$desc" "$signal"
        continue
    fi
    manifest_case
    APISERVER="$mode" HOOK_POINT="$point" HOOK_SIGNAL="$signal"
    run_signals interruption_hooks ensure-apiserver
    check "$desc: the signal was sent" [ -e "$CASE_DIR/hook-fired" ]
    expect_rc "$want" "$desc: exit code $want"
    check "$desc: ignored signals at that point" \
        ignored_signals_are "$CASE_DIR/sigign-$point" $((BASE_SIGIGN | SIG_HUP_PIPE | protected))
    check "$desc: the kubelet sees only the kube-apiserver manifest" kubelet_sees_only_the_manifest
    case "$outcome" in
        configured)
            check "$desc: the manifest is configured" manifest_state_is configured
            check "$desc: the backup is the original manifest" cmp -s -- "$FIXTURE" "$K2S_WA_BACKUP_FILE"
            check "$desc: success marker" marker_is ensure-apiserver ;;
        restored)
            check "$desc: the original manifest is restored" cmp -s -- "$FIXTURE" "$K2S_WA_MANIFEST"
            check "$desc: the backup is kept" cmp -s -- "$FIXTURE" "$K2S_WA_BACKUP_FILE"
            check "$desc: no success marker" no_marker ;;
        unchanged)
            check "$desc: the manifest is unchanged" cmp -s -- "$FIXTURE" "$K2S_WA_MANIFEST"
            check "$desc: no success marker" no_marker ;;
    esac
    if (( want > 128 )); then
        check "$desc: the signal ended the run" [ ! -e "$CASE_DIR/survived" ]
        run ensure-apiserver
        expect_rc 0 "$desc: a rerun succeeds"
        check "$desc: the rerun configures the manifest" manifest_state_is configured
        check "$desc: the rerun removes the temporary files of the ended run" no_leftovers
    else
        check "$desc: the run continued after the signal" [ -e "$CASE_DIR/survived" ]
        check "$desc: ignored signals after the run" ignored_signals_are "$CASE_DIR/sigign-after" $((BASE_SIGIGN | SIG_HUP_PIPE))
        check "$desc: no temporary files remain" no_leftovers
        if [[ "$outcome" == configured ]]; then
            run ensure-apiserver
            expect_rc 0 "$desc: a rerun succeeds"
            check "$desc: the rerun keeps the configured manifest" output_has 'kube-apiserver manifest already contains the admission configuration'
        fi
    fi
done <<'EOF'
before|HUP|healthy|0|configured
before|PIPE|healthy|0|configured
before|INT|healthy|130|unchanged
before|TERM|healthy|143|unchanged
backup|INT|healthy|130|unchanged
backup|TERM|healthy|143|unchanged
swapped|HUP|healthy|0|configured
swapped|INT|healthy|0|configured
swapped|TERM|healthy|0|configured
swapped|TERM|flag-crashes|5|restored
waiting|HUP|flag-crashes|5|restored
waiting|PIPE|flag-crashes|5|restored
waiting|INT|flag-crashes|5|restored
waiting|TERM|flag-crashes|5|restored
waiting|INT|healthy|0|configured
restore|HUP|flag-crashes|5|restored
restore|INT|flag-crashes|5|restored
restore|TERM|flag-crashes|5|restored
recovery|HUP|flag-crashes|5|restored
recovery|INT|flag-crashes|5|restored
recovery|TERM|flag-crashes|5|restored
recovery|INT|flag-breaks-cluster|6|restored
EOF
# point|kube-apiserver|exit code|outcome|message that must not reach the lost output
while IFS='|' read -r point mode want outcome message; do
    desc="output lost at $point ($mode)"
    manifest_case
    APISERVER="$mode" HOOK_POINT="$point" HOOK_SIGNAL=''
    run_output_lost ensure-apiserver
    check "$desc: the output was lost" [ -e "$CASE_DIR/output-lost" ]
    expect_rc "$want" "$desc: exit code $want"
    check "$desc: the run continued without output" [ -e "$CASE_DIR/survived" ]
    check "$desc: later messages were not delivered" not grep -q -F -- "$message" "$CASE_DIR/delivered"
    check "$desc: the kubelet sees only the kube-apiserver manifest" kubelet_sees_only_the_manifest
    check "$desc: no temporary files remain" no_leftovers
    if [[ "$outcome" == configured ]]; then
        check "$desc: the manifest is configured" manifest_state_is configured
    else
        check "$desc: the manifest is the original manifest" cmp -s -- "$FIXTURE" "$K2S_WA_MANIFEST"
    fi
    if [[ "$outcome" == unchanged ]]; then
        run ensure-apiserver
        expect_rc 0 "$desc: a rerun configures the manifest"
    fi
done <<'EOF'
before|healthy|1|unchanged|backed up
swapped|healthy|0|configured|K2S-WEBHOOK-AUTH-OK
waiting|flag-crashes|5|restored|restoring the previous manifest
restore|flag-crashes|5|restored|kube-apiserver recovered
recovery|flag-breaks-cluster|6|restored|did not recover
EOF
# A failure after the signals were set to be ignored resets them as well.
fail_chown() { chown() { printf 'injected chown failure\n'; return 1; }; }
manifest_case
run_signals fail_chown ensure-apiserver
expect_rc 1 'a manifest that cannot be replaced fails ensure-apiserver'
check 'the failed replacement is reported' output_has "cannot replace '$K2S_WA_MANIFEST'"
check 'the manifest is unchanged after the failed replacement' cmp -s -- "$FIXTURE" "$K2S_WA_MANIFEST"
check 'no success marker after the failed replacement' no_marker
check 'no temporary files remain after the failed replacement' no_leftovers
check 'SIGINT, SIGTERM and SIGQUIT are reset after the failed replacement' \
    ignored_signals_are "$CASE_DIR/sigign-after" $((BASE_SIGIGN | SIG_HUP_PIPE))
new_case
for cmd in provision publish; do
    run_signals : "$cmd"
    expect_rc 0 "$cmd succeeds with recorded signal dispositions"
    check "$cmd ignores SIGHUP and SIGPIPE only" ignored_signals_are "$CASE_DIR/sigign-after" $((BASE_SIGIGN | SIG_HUP_PIPE))
done

# --- durability: backups and staged files reach the disk before a rename, the directory after it ---
order_hooks() {
    sync() { printf 'sync %s\n' "$*" >> "$CASE_DIR/order.log"; command sync "$@"; }
    mv() { printf 'mv %s\n' "$*" >> "$CASE_DIR/order.log"; command mv "$@"; }
}
# Fails sync for paths matching the glob SYNC_FAIL (after the manifest replacement only if SYNC_FAIL_SWAPPED is set).
SYNC_FAIL='' SYNC_FAIL_SWAPPED=''
failing_sync() {
    order_hooks
    sync() {
        printf 'sync %s\n' "$*" >> "$CASE_DIR/order.log"
        # shellcheck disable=SC2053 # SYNC_FAIL is a glob pattern
        if [[ "${!#}" == $SYNC_FAIL ]] && { [[ -z "$SYNC_FAIL_SWAPPED" ]] || grep -q -F -- "$K2S_WA_FLAG" "$K2S_WA_MANIFEST"; }; then
            printf 'injected sync failure\n'
            return 1
        fi
        command sync "$@"
    }
}
# order.log with the random parts of temporary names replaced.
order_is() {
    local actual
    actual=$(sed -E -e 's/\.tmp\.[A-Za-z0-9]{6}/.tmp.X/g' -e 's/\.k2s-webhook-auth\.[A-Za-z0-9]{6}/.k2s-webhook-auth.X/g' \
        -e "s|$K2S_WA_ROOT|<root>|g" "$CASE_DIR/order.log")
    [[ "$actual" == "$1" ]] && return 0
    printf 'order:\n%s\nexpected:\n%s\n' "$actual" "$1"
    return 1
}
# provision checks and flushes the CA, the credentials, the patch and their directories (k2s_wa_flush_credentials).
FLUSH_SYNC='sync -- <root>/k2s-webhook-auth-ca/ca.key <root>/k2s-webhook-auth-ca/ca.crt <root>/k2s-webhook-auth/client.key <root>/k2s-webhook-auth/client.crt <root>/k2s-webhook-auth/kubeconfig <root>/k2s-webhook-auth/admission-config.yaml <root>/k2s-kubeadm-patches/kube-apiserver+json.json <root>/k2s-webhook-auth-ca <root>/k2s-webhook-auth <root>/k2s-kubeadm-patches <root>'
SWAP_ORDER="$FLUSH_SYNC"'
sync -- <root>/k2s-webhook-auth-backup/.kube-apiserver.yaml.tmp.X
mv -f -- <root>/k2s-webhook-auth-backup/.kube-apiserver.yaml.tmp.X <root>/k2s-webhook-auth-backup/kube-apiserver.yaml
sync -- <root>/k2s-webhook-auth-backup
sync -- <root>/manifests/.kube-apiserver.yaml.k2s-webhook-auth.X
mv -f -- <root>/manifests/.kube-apiserver.yaml.k2s-webhook-auth.X <root>/manifests/kube-apiserver.yaml
sync -- <root>/manifests'
manifest_case
run provision
run_with order_hooks ensure-apiserver
expect_rc 0 'durability: ensure-apiserver succeeds'
check 'durability: backup file and directory, then the staged manifest are flushed before the rename, the directory after it' \
    order_is "$SWAP_ORDER"
manifest_case
run provision
APISERVER=flag-crashes
run_with order_hooks ensure-apiserver
expect_rc 5 'durability: a failed configuration is restored'
check 'durability: the restored manifest is flushed before its rename, the directory after it' order_is "$SWAP_ORDER
sync -- <root>/manifests/.kube-apiserver.yaml.k2s-webhook-auth.X
mv -f -- <root>/manifests/.kube-apiserver.yaml.k2s-webhook-auth.X <root>/manifests/kube-apiserver.yaml
sync -- <root>/manifests"
while IFS='|' read -r pattern swapped rc state message; do
    manifest_case
    run provision
    SYNC_FAIL="$K2S_WA_ROOT/$pattern" SYNC_FAIL_SWAPPED="$swapped"
    [[ "$rc" != 5 ]] || APISERVER=flag-crashes
    run_signals failing_sync ensure-apiserver
    expect_rc "$rc" "failing sync of $pattern: ensure-apiserver exits $rc"
    check "failing sync of $pattern: $message is reported" output_has "$message"
    case "$state" in
        unchanged) check "failing sync of $pattern: the manifest is unchanged" cmp -s -- "$FIXTURE" "$K2S_WA_MANIFEST" ;;
        configured) check "failing sync of $pattern: the manifest is configured" manifest_state_is configured ;;
        restored) check "failing sync of $pattern: the previous manifest is restored" cmp -s -- "$FIXTURE" "$K2S_WA_MANIFEST" ;;
    esac
    if [[ "$rc" == 0 ]]; then check "failing sync of $pattern: success marker" marker_is ensure-apiserver; else check "failing sync of $pattern: no success marker" no_marker; fi
    check "failing sync of $pattern: no temporary files remain" no_leftovers
    check "failing sync of $pattern: SIGINT, SIGTERM and SIGQUIT are reset" \
        ignored_signals_are "$CASE_DIR/sigign-after" $((BASE_SIGIGN | SIG_HUP_PIPE))
done <<'EOF'
k2s-webhook-auth-backup/.kube-apiserver.yaml.tmp.*||1|unchanged|cannot back up
k2s-webhook-auth-backup||1|unchanged|cannot back up
manifests/.kube-apiserver.yaml.k2s-webhook-auth.*||1|unchanged|cannot replace
manifests||0|configured|WARNING: cannot flush
manifests*|swapped|5|restored|WARNING: cannot flush
EOF
SYNC_FAIL='' SYNC_FAIL_SWAPPED=''

# --- durability of the credentials before the manifest references them ---
# order.log with temporary names replaced, one entry per line.
normalized_order() {
    sed -E -e 's/\.tmp\.[A-Za-z0-9]{6}/.tmp.X/g' -e 's/\.k2s-webhook-auth\.[A-Za-z0-9]{6}/.k2s-webhook-auth.X/g' \
        -e "s|$K2S_WA_ROOT|<root>|g" "$CASE_DIR/order.log"
}
# Line number of the first entry of order.log equal to $1 (0 if none).
order_line() { normalized_order | grep -n -x -F -- "$1" | head -n 1 | cut -d: -f1 || :; }
SWAP_MV='mv -f -- <root>/manifests/.kube-apiserver.yaml.k2s-webhook-auth.X <root>/manifests/kube-apiserver.yaml'
# The flush follows every rename that creates a credential, the CA or the patch, and precedes the manifest replacement.
credentials_flushed_before_swap() {
    local flush swap last
    flush=$(order_line "$FLUSH_SYNC")
    swap=$(order_line "$SWAP_MV")
    [[ -n "$flush" && -n "$swap" ]] || { printf 'flush line %s, manifest replacement line %s\n' "${flush:-missing}" "${swap:-missing}"; return 1; }
    last=$(normalized_order | grep -n -E '^mv .* <root>/(k2s-webhook-auth-ca|k2s-webhook-auth/|k2s-kubeadm-patches/)' | tail -n 1 | cut -d: -f1)
    [[ -n "$last" ]] || { printf 'no credential was created\n'; return 1; }
    (( last < flush && flush < swap )) && return 0
    printf 'last credential rename %s, flush %s, manifest replacement %s\n' "$last" "$flush" "$swap"
    normalized_order
    return 1
}
manifest_case
run_with order_hooks ensure-apiserver
expect_rc 0 'fresh node: ensure-apiserver provisions and configures kube-apiserver'
check 'fresh node: the new CA, credentials and patch are flushed with their directories after they are created and before the manifest is replaced' \
    credentials_flushed_before_swap
check 'fresh node: the manifest is configured' manifest_state_is configured
new_case
run_with order_hooks provision
expect_rc 0 'provision flushes the credentials'
check 'provision ends with flushing the CA, the credentials, the patch and their directories' [ "$(normalized_order | tail -n 1)" = "$FLUSH_SYNC" ]
# A failed flush or an unexpected owner or mode stops ensure-apiserver before the manifest is changed.
flush_fails() { SYNC_FAIL="$K2S_WA_ROOT"; failing_sync; }
eval "real_$(declare -f k2s_wa_check_auth_dir)"
mode_changed() { order_hooks; k2s_wa_check_auth_dir() { real_k2s_wa_check_auth_dir && chmod 0640 -- "$K2S_WA_AUTH_DIR/client.key"; }; }
# A credential replaced by a symbolic link (to a file with the expected owner and mode) after the directory check.
link_planted() {
    order_hooks
    k2s_wa_check_auth_dir() {
        real_k2s_wa_check_auth_dir && command mv -- "$K2S_WA_AUTH_DIR/admission-config.yaml" "$CASE_DIR/planted-admission-config.yaml" &&
            command ln -s -- "$CASE_DIR/planted-admission-config.yaml" "$K2S_WA_AUTH_DIR/admission-config.yaml"
    }
}
uid_gid="$EUID:$(id -g)"
while IFS='|' read -r setup prepared message; do
    manifest_case
    if [[ "$prepared" == provisioned ]]; then run provision; fi
    message=${message//<auth-dir>/$K2S_WA_AUTH_DIR}
    run_with "$setup" ensure-apiserver
    expect_rc 1 "$setup ($prepared): ensure-apiserver fails"
    check "$setup ($prepared): reports '$message'" output_has "$message"
    check "$setup ($prepared): the manifest is unchanged" cmp -s -- "$FIXTURE" "$K2S_WA_MANIFEST"
    check "$setup ($prepared): no backup of the manifest is taken" [ ! -e "$K2S_WA_BACKUP_FILE" ]
    check "$setup ($prepared): the manifest is not replaced" [ "$(order_line "$SWAP_MV")" = '' ]
    check "$setup ($prepared): no success marker" no_marker
    check "$setup ($prepared): no temporary files remain" no_leftovers
done <<EOF
flush_fails|fresh|cannot flush the credentials to disk; the kube-apiserver manifest was not changed
flush_fails|provisioned|cannot flush the credentials to disk; the kube-apiserver manifest was not changed
mode_changed|fresh|has owner, group and mode $uid_gid:640 instead of $uid_gid:600; the kube-apiserver manifest was not changed
link_planted|fresh|cannot check the owner and mode of '<auth-dir>/admission-config.yaml'; the kube-apiserver manifest was not changed
EOF
new_case
run_with flush_fails provision
expect_rc 1 'provision fails if the credentials cannot be flushed'
check 'provision reports the failed flush' output_has 'cannot flush the credentials to disk'
check 'provision with a failed flush prints no success marker' no_marker
SYNC_FAIL=''

# --- publication of the client CA certificate ---
# shellcheck disable=SC2053 # $1 is a glob pattern
log_matches() { [[ "$(<"$CASE_DIR/kubectl.log")" == $1 ]]; }
provisioned_case
run publish
expect_rc 0 'publish succeeds'
check 'publish prints its success marker last' marker_is publish
check 'publish reports the ConfigMap' output_has "published the client CA certificate to ConfigMap $K2S_WA_NAMESPACE/$K2S_WA_CONFIGMAP"
check 'publish applies server-side with its field manager and reads the ConfigMap back' log_matches \
    "apply --server-side --force-conflicts --field-manager=$K2S_WA_FIELD_MANAGER -f $K2S_WA_ROOT/.k2s-webhook-auth-publish.tmp.*/configmap.yaml
get configmap $K2S_WA_CONFIGMAP -n $K2S_WA_NAMESPACE -o yaml"
# shellcheck disable=SC2016 # Go template variables, not shell expansions
out=$(render_local "$CASE_DIR/applied.yaml" '{{.kind}}|{{.metadata.namespace}}/{{.metadata.name}}|{{index .metadata.labels "app.kubernetes.io/name"}}|{{index .metadata.labels "app.kubernetes.io/part-of"}}|{{range $k, $v := .data}}{{$k}};{{end}}|{{if .binaryData}}binaryData{{end}}')
check 'published ConfigMap is labelled and holds only ca.crt' [ "$out" = "ConfigMap|$K2S_WA_NAMESPACE/$K2S_WA_CONFIGMAP|clusterip-webhook|k2s|ca.crt;|" ]
out=$(render_local "$CASE_DIR/applied.yaml" '{{index .data "ca.crt"}}')
check 'published ca.crt is the client CA certificate' [ "$out" = "$(<"$K2S_WA_CA_DIR/ca.crt")" ]
check 'published ConfigMap contains no private key' not grep -q -F -- 'PRIVATE KEY' "$CASE_DIR/applied.yaml"
check 'no temporary files remain after publishing' no_leftovers
new_case
run publish
expect_rc 1 'publish without a client CA fails'
check 'publish without a client CA asks to provision first' output_has 'is missing or invalid (ca.crt or ca.key is missing); run provision first'
check 'publish without a client CA does not contact the cluster' [ ! -e "$CASE_DIR/kubectl.log" ]
provisioned_case
KUBECTL_APPLY=fail
run publish
expect_rc 1 'a failed apply fails publish'
check 'the failed apply is reported' output_has "cannot publish ConfigMap $K2S_WA_NAMESPACE/$K2S_WA_CONFIGMAP"
check 'nothing is read back after a failed apply' not grep -q '^get ' "$CASE_DIR/kubectl.log"
check 'no success marker after a failed apply' no_marker
check 'no temporary files remain after a failed apply' no_leftovers
provisioned_case
KUBECTL_GET=fail
run publish
expect_rc 1 'a failed read-back fails publish'
check 'the failed read-back is reported' output_has "cannot read back ConfigMap $K2S_WA_NAMESPACE/$K2S_WA_CONFIGMAP"
check 'no success marker after a failed read-back' no_marker
check 'no temporary files remain after a failed read-back' no_leftovers
other_cert() { mkdir -- "$CASE_DIR/other"; cp -- "$FOREIGN_CRT" "$CASE_DIR/other/ca.crt"; K2S_WA_CA_DIR="$CASE_DIR/other" k2s_wa_render_configmap; }
extra_key() { k2s_wa_render_configmap; printf '  extra: value\n'; }
binary_data() { k2s_wa_render_configmap; printf 'binaryData:\n  blob: AAAA\n'; }
private_key() { k2s_wa_render_configmap; sed 's/^/    /' "$K2S_WA_CA_DIR/ca.key"; }
wrong_name() { k2s_wa_render_configmap | sed "s/^  name: .*/  name: other/"; }
wrong_namespace() { k2s_wa_render_configmap | sed "s/^  namespace: .*/  namespace: default/"; }
while IFS='|' read -r served reason; do
    provisioned_case
    SERVED="$CASE_DIR/served.yaml"
    "$served" > "$SERVED"
    run publish
    expect_rc 1 "$served: publish detects the unexpected ConfigMap"
    check "$served: reports why" output_has "published ConfigMap $K2S_WA_NAMESPACE/$K2S_WA_CONFIGMAP is not the client CA certificate: $reason"
    check "$served: no success marker" no_marker
done <<'EOF'
other_cert|ca.crt differs from the local CA certificate
extra_key|unexpected object or keys: ConfigMap|k2s-webhook|clusterip-webhook-client-ca data/ca.crt data/extra
binary_data|unexpected object or keys: ConfigMap|k2s-webhook|clusterip-webhook-client-ca data/ca.crt binaryData/blob
private_key|ca.crt differs from the local CA certificate
wrong_name|unexpected object or keys: ConfigMap|k2s-webhook|other data/ca.crt
wrong_namespace|unexpected object or keys: ConfigMap|default|clusterip-webhook-client-ca data/ca.crt
EOF

# --- command line and root directory ---
for args in '' bogus 'provision extra' 'verify extra' 'renew extra' 'renew --bogus' 'renew --force extra' '--force renew'; do
    new_case
    # shellcheck disable=SC2086 # intentionally split into arguments
    run $args
    expect_rc 2 "arguments '$args' are rejected"
    check "arguments '$args': usage is printed" output_has 'provision|ensure-apiserver|publish|verify|renew [--force]'
    check "arguments '$args': nothing is created" listing_is "$K2S_WA_ROOT" 'manifests'
done
for args in '' bogus; do
    RC=0
    # shellcheck disable=SC2086 # intentionally split into arguments
    OUTPUT=$(bash "$SCRIPT" $args 2>&1) || RC=$?
    expect_rc 2 "running the script with arguments '$args' is rejected"
    check "running the script with arguments '$args' prints the usage" \
        [ "$OUTPUT" = 'Usage: clusterip-webhook-auth.sh provision|ensure-apiserver|publish|verify|renew [--force]' ]
done
while IFS= read -r root; do
    RC=0
    OUTPUT=$(k2s_wa_init_paths "$root") || RC=$?
    expect_rc 2 "root directory '$root' is rejected"
    check "root directory '$root' is reported" output_has "invalid root directory '$root'"
done <<'EOF'
relative/path
/
/tmp/trailing/
/tmp/with space
/tmp/x;rm -rf
/tmp/$(id)
/tmp/new*glob
EOF
OUTPUT=$(k2s_wa_init_paths /etc/kubernetes && printf '%s\n' "$K2S_WA_AUTH_DIR" "$K2S_WA_CA_DIR" "$K2S_WA_PATCH_FILE" \
    "$K2S_WA_BACKUP_FILE" "$K2S_WA_MANIFEST" "$K2S_WA_ADMIN_KUBECONFIG" "$K2S_WA_LOCK_FILE")
check 'the default root directory is /etc/kubernetes' [ "$OUTPUT" = '/etc/kubernetes/k2s-webhook-auth
/etc/kubernetes/k2s-webhook-auth-ca
/etc/kubernetes/k2s-kubeadm-patches/kube-apiserver+json.json
/etc/kubernetes/k2s-webhook-auth-backup/kube-apiserver.yaml
/etc/kubernetes/manifests/kube-apiserver.yaml
/etc/kubernetes/admin.conf
/etc/kubernetes/.k2s-webhook-auth.lock' ]
check 'the credential directory is mounted at the same path in kube-apiserver' \
    [ "$(k2s_wa_init_paths /etc/kubernetes && printf '%s' "$K2S_WA_AUTH_DIR")" = "$K2S_WA_POD_DIR" ]

# --- kube-apiserver readiness ---
new_case
check '/readyz ok means ready' k2s_wa_apiserver_ready
READYZ_OUTPUT='[+]ping ok'
check '/readyz with other output is not ready' not k2s_wa_apiserver_ready
READYZ_OUTPUT='ok' READYZ_RC=1
check 'a failed /readyz request is not ready' not k2s_wa_apiserver_ready
READYZ_RC=0 APISERVER=unready
check 'an unready kube-apiserver is not ready' not k2s_wa_apiserver_ready
check 'readiness uses /readyz with a request timeout' only_readyz_calls

# --- kube-apiserver process states (real implementation on a fake /proc) ---
proc_entry() {
    local dir="$K2S_WA_PROC_DIR/$1"
    mkdir -p -- "$dir"
    printf '%s\n' "$2" > "$dir/comm"
    shift 2
    : > "$dir/cmdline"
    if (( $# > 0 )); then printf '%s\0' "$@" > "$dir/cmdline"; fi
}
proc_states_are() {
    real_k2s_wa_apiserver_process_states
    [[ "$K2S_WA_PROC_STATES" == "$1" ]] || { printf 'process states "%s", expected "%s"\n' "$K2S_WA_PROC_STATES" "$1"; return 1; }
}
new_case
K2S_WA_PROC_DIR="$CASE_DIR/proc"
mkdir -p -- "$K2S_WA_PROC_DIR"
check 'no processes: no kube-apiserver state' proc_states_are ''
proc_entry 100 kubelet /usr/bin/kubelet --config=/var/lib/kubelet/config.yaml "$K2S_WA_FLAG"
proc_entry self kube-apiserver kube-apiserver "$K2S_WA_FLAG"
proc_entry 101 kube-apiserver
mkdir -p -- "$K2S_WA_PROC_DIR/102/comm"
mkdir -p -- "$K2S_WA_PROC_DIR/103"
printf 'kube-apiserver\n' > "$K2S_WA_PROC_DIR/103/comm"
check 'other processes, /proc/self, empty command lines and unreadable entries are ignored' proc_states_are ''
proc_entry 110 kube-apiserver kube-apiserver --advertise-address=172.19.1.100 --allow-privileged=true
check 'kube-apiserver without the flag' proc_states_are noflag
proc_entry 111 kube-apiserver kube-apiserver --allow-privileged=true "$K2S_WA_FLAG" --authorization-mode=Node,RBAC
check 'kube-apiserver with and without the flag during a restart' proc_states_are 'flag noflag'
rm -rf -- "$K2S_WA_PROC_DIR/110"
check 'kube-apiserver with the flag' proc_states_are flag
proc_entry 111 kube-apiserver kube-apiserver "$K2S_WA_FLAG.bak" --admission-control-config-file=/etc/kubernetes/other.yaml
check 'a different admission configuration file is not the flag' proc_states_are noflag
printf 'kube-apiserver' > "$K2S_WA_PROC_DIR/111/comm"
check 'a process name without a trailing newline is recognized' proc_states_are noflag

# --- waiting for kube-apiserver (polls every 2 s, needs 3 consecutive ready checks within 300 s) ---
# wait_with <want> <process state> <readiness results...>: prints 'ready' or 'timeout' and the number of polls.
wait_with() {
    local want="$1" state="$2"
    shift 2
    (
        results=("$@") polls=0 checks=0
        k2s_wa_apiserver_process_states() { polls=$((polls + 1)); K2S_WA_PROC_STATES="$state"; }
        k2s_wa_apiserver_ready() { checks=$((checks + 1)); return "${results[checks - 1]:-1}"; }
        if k2s_wa_wait_apiserver "$want" > "$CASE_DIR/wait.log"; then printf 'ready %s\n' "$polls"; else printf 'timeout %s\n' "$polls"; fi
    )
}
polls_between() { local n="${OUTPUT#timeout }"; [[ "$OUTPUT" == timeout* ]] && (( n >= $1 && n <= $2 )); }
new_case
OUTPUT=$(wait_with flag flag 0 0 0)
check 'three consecutive ready checks are enough' [ "$OUTPUT" = 'ready 3' ]
OUTPUT=$(wait_with flag flag 0 0 1 0 0 0)
check 'a failed ready check restarts the count' [ "$OUTPUT" = 'ready 6' ]
OUTPUT=$(wait_with noflag noflag 0 0 0)
check 'waiting for kube-apiserver without the flag' [ "$OUTPUT" = 'ready 3' ]
OUTPUT=$(wait_with flag flag 1)
check 'a never ready kube-apiserver times out after about 300 s' polls_between 140 150
check 'waiting reports progress' grep -q -F -- 'waiting for kube-apiserver (flag); running: flag' "$CASE_DIR/wait.log"
OUTPUT=$(wait_with flag 'flag noflag' 0 0 0)
check 'old and new kube-apiserver processes are not a finished restart' polls_between 140 150
check 'waiting reports both process states' grep -q -F -- 'running: flag noflag' "$CASE_DIR/wait.log"
OUTPUT=$(wait_with flag noflag 0 0 0)
check 'a kube-apiserver without the flag is not accepted' polls_between 140 150
OUTPUT=$(wait_with flag '' 0 0 0)
check 'no kube-apiserver process is not accepted' polls_between 140 150
check 'waiting reports missing processes' grep -q -F -- 'running: none' "$CASE_DIR/wait.log"

# --- verify and renew: fixtures and mocks ---
# Serving CA and certificate of the webhook (as its init-cert container creates them), for the caBundle and real TLS.
SERVER_CA_KEY="$TEST_DIR/server-ca.key" SERVER_CA_CRT="$TEST_DIR/server-ca.crt"
SERVER_KEY="$TEST_DIR/server.key" SERVER_CRT="$TEST_DIR/server.crt"
new_key "$SERVER_CA_KEY"
make_cert "$SERVER_CA_CRT" "$SERVER_CA_KEY" self '' ca_cert '-1 day' '+100 days'
new_key "$SERVER_KEY"
make_cert "$SERVER_CRT" "$SERVER_KEY" "$SERVER_CA_CRT" "$SERVER_CA_KEY" webhook_server '-1 day' '+100 days'
mkdir -- "$TEST_DIR/other-ca"
cp -- "$SERVER_CA_CRT" "$TEST_DIR/other-ca/ca.crt"
CA_BUNDLE=$(base64 -w0 < "$SERVER_CA_CRT")
# The shipped MutatingWebhookConfiguration with the caBundle set by the webhook, and the shipped Deployment (line
# endings normalized: a Windows checkout may convert them).
MWC_FIXTURE="$TEST_DIR/webhook-config.yaml"
tr -d '\r' < "$MANIFESTS/webhook-config.yaml" | sed "s|caBundle: \"\"|caBundle: \"$CA_BUNDLE\"|" > "$MWC_FIXTURE"
DEPLOY_FIXTURE="$TEST_DIR/deployment.yaml"
tr -d '\r' < "$MANIFESTS/deployment.yaml" | awk 'found { next } /^---/ { if (doc ~ /\nkind: Deployment\n/) found = 1; else doc = ""; next }
    { doc = doc $0 "\n" } END { if (found || doc ~ /\nkind: Deployment\n/) printf "%s", doc }' > "$DEPLOY_FIXTURE"
service_yaml() {
    printf '%s\n' 'apiVersion: v1' 'kind: Service' 'metadata:' '  name: clusterip-webhook' '  namespace: k2s-webhook' 'spec:' \
        "  clusterIP: $1" '  ports:' '  - name: https' "    port: $2" '    targetPort: 8443'
}
SVC_FIXTURE="$TEST_DIR/service.yaml"
service_yaml 172.21.0.12 443 > "$SVC_FIXTURE"
# kubectl get prints a List; the list templates are rendered per item by the real kubectl.
item_template() { local t="${1#'{{range .items}}'}"; printf '%s' "${t%'{{end}}'}"; }
EPS_FIXTURE="$TEST_DIR/endpointslice.yaml"
printf '%s\n' 'apiVersion: discovery.k8s.io/v1' 'kind: EndpointSlice' 'metadata:' '  name: clusterip-webhook-x1' \
    '  namespace: k2s-webhook' '  labels:' '    kubernetes.io/service-name: clusterip-webhook' 'addressType: IPv4' 'ports:' \
    '- name: https' '  port: 8443' '  protocol: TCP' 'endpoints:' '- addresses: [172.20.0.10]' '  conditions:' '    ready: true' \
    '- addresses: [172.20.0.11]' '  conditions:' '    ready: false' '- addresses: [172.20.0.12]' '  conditions:' \
    '    ready: false' '    terminating: true' > "$EPS_FIXTURE"
EPS_DEFAULT="$(render_local "$EPS_FIXTURE" "$(item_template "$K2S_WA_ENDPOINTS_TEMPLATE")")"$'\n'
RULES_DEFAULT="$(render_local "$MWC_FIXTURE" "$(item_template "$K2S_WA_RULES_TEMPLATE")")"$'\n'
check 'fixture: the caBundle is set for both shipped webhooks' [ "$(grep -c -F -- "caBundle: \"$CA_BUNDLE\"" "$MWC_FIXTURE")" = 2 ]
check 'fixture: the shipped webhook Deployment passes --linux-subnet and --reserved-ips' \
    [ "$(render_local "$DEPLOY_FIXTURE" "$K2S_WA_ARGS_TEMPLATE" | grep -c -x -e 'A|--linux-subnet=172.21.0.0/24' -e 'A|--reserved-ips=50')" = 2 ]
check 'fixture: one ready endpoint' [ "$EPS_DEFAULT" = $'E|172.20.0.10|8443\n' ]
check 'fixture: the shipped webhooks declare no side effects' [ "$RULES_DEFAULT" = \
    $'W|k2s-webhook|clusterip.k2s.io|None|[]|[v1]|[services]|[CREATE]\nW|k2s-webhook|workload.clusterip.k2s.io|NoneOnDryRun|[apps]|[v1]|[deployments][statefulsets][daemonsets]|[CREATE]\n' ]
# openssl s_client replay; outputs captured with OpenSSL 3.0.2 against a Go server requiring client certificates.
TLS_HANDSHAKE='CONNECTION ESTABLISHED
Protocol version: TLSv1.3
Ciphersuite: TLS_AES_128_GCM_SHA256
Peer certificate: CN = clusterip-webhook.k2s-webhook.svc
Hash used: SHA256
Signature type: ECDSA
Verification: OK
Verified peername: clusterip-webhook.k2s-webhook.svc
Server Temp Key: X25519, 253 bits'
tls_alert() {
    printf '%s\n40772A0DCB790000:error:0A000415:SSL routines:ssl3_read_bytes:%s:../ssl/record/rec_layer_s3.c:1584:SSL alert number %s\n' \
        "$TLS_HANDSHAKE" "$1" "$2"
    return 1
}
tls_output() {
    case "$1" in
        rejected) tls_alert 'tlsv13 alert certificate required' 116 ;;
        rejected-tls12)
            printf '%s\n' '4047916EFC750000:error:0A000410:SSL routines:ssl3_read_bytes:sslv3 alert handshake failure:../ssl/record/rec_layer_s3.c:1584:SSL alert number 40'
            return 1 ;;
        bad-certificate) tls_alert 'sslv3 alert bad certificate' 42 ;;
        expired) tls_alert 'sslv3 alert certificate expired' 45 ;;
        unknown-ca) tls_alert 'tlsv1 alert unknown ca' 48 ;;
        answered)
            printf '%s\n' "$TLS_HANDSHAKE"
            printf '%s\r\n' 'HTTP/1.1 404 Not Found' 'Content-Type: text/plain; charset=utf-8' 'X-Content-Type-Options: nosniff' \
                'Content-Length: 19' 'Connection: close' ''
            printf '404 page not found\n' ;;
        mixed) tls_output answered; tls_alert 'sslv3 alert bad record mac' 20 ;;
        timeout) return 124 ;;
        refused)
            printf '%s\n' '40579B804E790000:error:8000006F:system library:BIO_connect:Connection refused:../crypto/bio/bio_sock2.c:125:calling connect()' \
                '40579B804E790000:error:10000067:BIO routines:BIO_connect:connect error:../crypto/bio/bio_sock2.c:127:' 'connect:errno=111'
            return 1 ;;
        reset) printf '%s\n%s\n' "$TLS_HANDSHAKE" 'read:errno=104'; return 1 ;;
        untrusted | hostname)
            if [[ "$1" == untrusted ]]; then set -- 'num=20:unable to get local issuer certificate'; else set -- 'num=62:hostname mismatch'; fi
            printf '%s\n' 'depth=0 CN = clusterip-webhook.k2s-webhook.svc' "verify error:$1" \
                '407762F8BC7F0000:error:0A000086:SSL routines:tls_post_process_server_certificate:certificate verify failed:../ssl/statem/statem_clnt.c:1883:'
            return 1 ;;
        plain-http) printf '%s\n' '40770AD1CD730000:error:0A00010B:SSL routines:ssl3_get_record:wrong version number:../ssl/record/ssl3_record.c:354:'; return 1 ;;
        eof) printf '%s\n' '40671EDEE57D0000:error:0A000126:SSL routines:ssl3_read_n:unexpected eof while reading:../ssl/record/rec_layer_s3.c:308:'; return 1 ;;
        *) printf 'unknown TLS outcome %s\n' "$1"; return 1 ;;
    esac
}
# The script runs openssl s_client through timeout. Unless TLS_MODE is real, the probes are answered from TLS_NOCERT
# and TLS_CERT, or TLS_NOCERT__<target> and TLS_CERT__<target> (non-alphanumerics replaced by _): the outcome of each
# probe of a target, the last one repeats. trusted-cert answers if the presented certificate is trusted (TLS_TRUSTED_SHA).
timeout() {
    if [[ "$TLS_MODE" == real || "${2-}" != openssl || "${3-}" != s_client ]]; then command timeout "$@"; return; fi
    shift 3
    fake_s_client "$@"
}
fake_s_client() {
    local all="$*" target='' cert_file='' cafile='' kind=nocert key var spec count=0 outcome ca=bad
    local -a outcomes
    command -p cat > /dev/null
    while (( $# > 0 )); do
        case "$1" in
            -connect) target="$2"; shift ;;
            -cert) cert_file="$2"; shift ;;
            -CAfile) cafile="$2"; shift ;;
        esac
        shift
    done
    if [[ -n "$cert_file" ]]; then kind=cert spec="$TLS_CERT"; else spec="$TLS_NOCERT"; fi
    key="${target//[^A-Za-z0-9]/_}"
    var="TLS_${kind^^}__$key"
    if [[ -n "${!var-}" ]]; then spec="${!var}"; fi
    if [[ -f "$CASE_DIR/tls-$kind-$key" ]]; then count=$(<"$CASE_DIR/tls-$kind-$key"); fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$CASE_DIR/tls-$kind-$key"
    read -r -a outcomes <<< "$spec"
    outcome="${outcomes[count - 1]:-${outcomes[-1]}}"
    if [[ "$outcome" == trusted-cert ]]; then
        if cert_trusted "$cert_file"; then outcome=answered; else outcome=unknown-ca; fi
    fi
    if cmp -s -- "$cafile" "$SERVER_CA_CRT"; then ca=ok; fi
    printf '%s %s %s ca=%s\n' "$kind" "$target" "$outcome" "$ca" >> "$CASE_DIR/s_client.log"
    printf '%s %s\n' "$kind" "$all" >> "$CASE_DIR/s_client-args.log"
    tls_output "$outcome"
}
verify_reset() {
    MWC_FILE="$MWC_FIXTURE" DEPLOY_FILE="$DEPLOY_FIXTURE" SVC_FILE="$SVC_FIXTURE" EPS_OUTPUT="$EPS_DEFAULT"
    RULES_OUTPUT="$RULES_DEFAULT" METRICS_MODE='' ADMISSION=ok GET_FAIL='' SERVED='' APISERVER=healthy KUBECTL_GET=ok
    TLS_NOCERT=rejected TLS_CERT=answered TLS_TRUSTED_SHA='' TLS_MODE=replay K2S_WA_VERIFY_TIMEOUT=10 K2S_WA_LOCK_TIMEOUT=300
    unset "${!TLS_NOCERT__@}" "${!TLS_CERT__@}"
    rm -f -- "$CASE_DIR/kubectl.log" "$CASE_DIR/s_client.log" "$CASE_DIR/s_client-args.log" "$CASE_DIR/metrics-calls" \
        "$CASE_DIR/creates" "$CASE_DIR"/tls-* "$CASE_DIR"/dry-run-*.yaml "$CASE_DIR/order.log"
    printf '5 0 0 0\n' > "$CASE_DIR/metrics"
}
# A configured kube-apiserver manifest and the published client CA. The first call creates them; later calls
# restore that state into the same case directory (the rendered files contain the absolute root path).
VERIFY_CASE_DIR=''
verify_case() {
    if [[ -z "$VERIFY_CASE_DIR" ]]; then
        manifest_case
        run ensure-apiserver
        if [[ "$RC" != 0 ]]; then printf 'ABORTED: ensure-apiserver setup failed (%s)\n%s\n' "$RC" "$OUTPUT"; exit 1; fi
        run publish
        if [[ "$RC" != 0 ]]; then printf 'ABORTED: publish setup failed (%s)\n%s\n' "$RC" "$OUTPUT"; exit 1; fi
        VERIFY_CASE_DIR="$CASE_DIR"
        cp -a -- "$K2S_WA_ROOT" "$TEST_DIR/verify-root"
        cp -p -- "$CASE_DIR/applied.yaml" "$TEST_DIR/verify-applied.yaml"
    else
        CASE_DIR="$VERIFY_CASE_DIR"
        k2s_wa_init_paths "$CASE_DIR/etc"
        APISERVER=healthy KUBECTL_APPLY=ok KUBECTL_GET=ok READYZ_OUTPUT=ok READYZ_RC=0 SERVED=''
        unset -f openssl
        rm -rf -- "$K2S_WA_ROOT" "$CASE_DIR/saved"
        cp -a -- "$TEST_DIR/verify-root" "$K2S_WA_ROOT"
        cp -p -- "$TEST_DIR/verify-applied.yaml" "$CASE_DIR/applied.yaml"
    fi
    verify_reset
    CRT="$K2S_WA_AUTH_DIR/client.crt" KEY="$K2S_WA_AUTH_DIR/client.key" CA_CRT="$K2S_WA_CA_DIR/ca.crt" CA_KEY="$K2S_WA_CA_DIR/ca.key"
}
save_local() { rm -rf -- "$CASE_DIR/saved"; cp -a -- "$K2S_WA_ROOT" "$CASE_DIR/saved"; }
restore_local() { rm -rf -- "$K2S_WA_ROOT"; cp -a -- "$CASE_DIR/saved" "$K2S_WA_ROOT"; }
verify_result_is() {
    if [[ "$1" == ok ]]; then
        [[ "$OUTPUT" == *$'\nK2S-WEBHOOK-AUTH-VERIFY:ok\nK2S-WEBHOOK-AUTH-OK:verify' ]]
    else
        [[ "${OUTPUT##*$'\n'}" == "K2S-WEBHOOK-AUTH-VERIFY:$1" ]] && no_marker
    fi
}
expect_verify() {
    expect_rc "$1" "$3"
    check "$3: result $2" verify_result_is "$2"
}
s_client_log_is() {
    [[ "$(<"$CASE_DIR/s_client.log")" == "$1" ]] && return 0
    printf 's_client.log:\n%s\n' "$(<"$CASE_DIR/s_client.log")"
    return 1
}
probes_are() {
    local n=0
    if [[ -f "$CASE_DIR/s_client.log" ]]; then n=$(grep -c "^$1 " "$CASE_DIR/s_client.log" || :); fi
    [[ "$n" == "$2" ]] || { printf '%s %s probes, expected %s\n' "$n" "$1" "$2"; return 1; }
}
dry_runs_are() {
    local n=0
    if [[ -f "$CASE_DIR/creates" ]]; then n=$(<"$CASE_DIR/creates"); fi
    [[ "$n" == "$1" ]] || { printf '%s dry-runs, expected %s\n' "$n" "$1"; return 1; }
}
# Every cluster call reads, except the server-side dry-run create of the probe Service.
only_reads_and_dry_runs() {
    local line
    [[ -f "$CASE_DIR/kubectl.log" ]] || return 0
    while IFS= read -r line; do
        case "$line" in
            'get '* | 'create --dry-run=server -f - -o go-template=clusterIP={{.spec.clusterIP}}{{"\n"}}') ;;
            *) printf 'unexpected kubectl call: %s\n' "$line"; return 1 ;;
        esac
    done < "$CASE_DIR/kubectl.log"
}
PROBE_SERVICE=$(printf '%s\n' 'apiVersion: v1' 'kind: Service' 'metadata:' '  generateName: k2s-webhook-auth-probe-' \
    '  namespace: default' '  labels:' '    app.kubernetes.io/managed-by: k2s-clusterip-webhook-auth' 'spec:' '  ports:' \
    '  - port: 1' '    protocol: TCP')
dry_runs_are_probe_services() {
    local file
    for file in "$CASE_DIR"/dry-run-*.yaml; do
        [[ "$(<"$file")" == "$PROBE_SERVICE" ]] || { printf '%s:\n%s\n' "$file" "$(<"$file")"; return 1; }
    done
}
# The probes verify the serving certificate for the Service host with the caBundle; only cert probes present a certificate.
probe_args_ok() {
    local kind args head=' -servername clusterip-webhook.k2s-webhook.svc -verify_hostname clusterip-webhook.k2s-webhook.svc -verify_return_error -CAfile /dev/fd/'
    local cert_args=" -cert $K2S_WA_AUTH_DIR/client.crt -key $K2S_WA_AUTH_DIR/client.key"
    while read -r kind args; do
        case "$kind" in
            nocert) [[ "$args" == '-brief -connect '*"$head"*' -ign_eof' ]] || { printf 'nocert probe: %s\n' "$args"; return 1; } ;;
            cert) [[ "$args" == '-brief -connect '*"$head"*" -ign_eof$cert_args" ]] || { printf 'cert probe: %s\n' "$args"; return 1; } ;;
            *) return 1 ;;
        esac
    done < "$CASE_DIR/s_client-args.log"
    grep -q -v ' ca=ok$' "$CASE_DIR/s_client.log" && { printf 'a probe did not use the caBundle\n'; return 1; }
    return 0
}

# --- verify: success, side effects and read-only operation ---
verify_case
snap=$(snapshot)
lock_state=$(stat -c '%i %s %Y' -- "$K2S_WA_LOCK_FILE")
run verify
expect_verify 0 ok 'verify succeeds when authentication and admission work'
check 'verify reports the failurePolicy Ignore of the webhook' output_has 'has failurePolicy Ignore'
check 'verify reports the clusterIP the webhook assigned and the metrics' \
    output_has 'assigned 172.21.0.50 to the dry-run Service (calls 1, failed 0, failed open 0, rejected 0, reset 0)'
check 'verify changes no file' [ "$(snapshot)" = "$snap" ]
check 'verify does not write the lock file' [ "$(stat -c '%i %s %Y' -- "$K2S_WA_LOCK_FILE")" = "$lock_state" ]
check 'verify only reads from the cluster, apart from the dry-run' only_reads_and_dry_runs
check 'verify sends exactly one dry-run' dry_runs_are 1
check 'the dry-run is a selector-less Service in the default namespace, never a workload' dry_runs_are_probe_services
check 'verify probes the Service and its ready endpoint without, then with the client certificate' s_client_log_is \
    $'nocert 172.21.0.12:443 rejected ca=ok\nnocert 172.20.0.10:8443 rejected ca=ok\ncert 172.21.0.12:443 answered ca=ok\ncert 172.20.0.10:8443 answered ca=ok'
check 'the probes verify the serving certificate with the caBundle and present the certificate only when intended' probe_args_ok
check 'verify keeps the webhook in its initial state for workloads (no workload dry-run)' not grep -q -i -e deployment -e statefulset -e daemonset "$CASE_DIR"/dry-run-*.yaml
rm -- "$K2S_WA_LOCK_FILE"
verify_reset
run verify
expect_verify 0 ok 'verify succeeds without a lock file'
check 'verify does not create the lock file' [ ! -e "$K2S_WA_LOCK_FILE" ]
check 'verify without a lock file changes no file' [ "$(snapshot)" = "$snap" ]

# --- verify: local credentials, kube-apiserver and published CA (no probe, no dry-run) ---
unconfigured_manifest() { cp -- "$FIXTURE" "$K2S_WA_MANIFEST"; }
missing_manifest() { rm -- "$K2S_WA_MANIFEST"; }
stale_apiserver() { APISERVER=stale; }
down_apiserver() { APISERVER=down; }
unready_apiserver() { APISERVER=unready; }
missing_configmap() { SERVED="$CASE_DIR/absent.yaml"; }
other_ca_configmap() { K2S_WA_CA_DIR="$TEST_DIR/other-ca" k2s_wa_render_configmap > "$CASE_DIR/other.yaml"; SERVED="$CASE_DIR/other.yaml"; }
extra_key_configmap() { { k2s_wa_render_configmap; printf '  extra: value\n'; } > "$CASE_DIR/extra.yaml"; SERVED="$CASE_DIR/extra.yaml"; }
failing_configmap_get() { GET_FAIL=configmap; }
extra_auth_file() { printf 'x\n' > "$K2S_WA_AUTH_DIR/extra"; }
missing_admission_config() { rm -- "$K2S_WA_AUTH_DIR/admission-config.yaml"; }
symlinked_auth_dir() { mv -- "$K2S_WA_AUTH_DIR" "$CASE_DIR/real-auth"; ln -s -- "$CASE_DIR/real-auth" "$K2S_WA_AUTH_DIR"; }
save_local
while IFS='|' read -r setup result message; do
    verify_reset
    "$setup"
    run verify
    expect_verify 1 "$result" "verify with $setup"
    check "verify with $setup: reports '$message'" output_has "$message"
    check "verify with $setup: no probe" [ ! -e "$CASE_DIR/s_client.log" ]
    check "verify with $setup: no dry-run" dry_runs_are 0
    check "verify with $setup: the result line is last" verify_result_is "$result"
    restore_local
done <<'EOF'
corrupt_ca|ca-invalid|ca.crt is not a single PEM certificate
expired_ca|ca-invalid|ca.crt is not valid
mismatched_ca_key|ca-invalid|ca.key does not belong to ca.crt
expired_cert|client-cert-expired|has expired; run renew
corrupt_cert|client-cert-invalid|client certificate is not a single PEM certificate
mismatched_cert|client-cert-invalid|client key does not belong to the client certificate
server_auth_cert|client-cert-invalid|client certificate is not valid for the client CA
future_cert|client-cert-invalid|client certificate is not valid for the client CA
foreign_cert|client-cert-invalid|client certificate is not valid for the client CA
corrupt_key|client-cert-invalid|client key is not a valid unencrypted private key
ca_key_as_client_key|client-cert-invalid|client key is the client CA key
tamper_kubeconfig|admission-config-invalid|kubeconfig' is missing or differs from the expected content
symlink_kubeconfig|admission-config-invalid|unexpected entries
tamper_admission_config|admission-config-invalid|admission-config.yaml' is missing or differs
missing_admission_config|admission-config-invalid|admission-config.yaml' is missing or differs
tamper_patch|admission-config-invalid|kube-apiserver+json.json' is missing or differs
extra_auth_file|admission-config-invalid|unexpected entries
symlinked_auth_dir|admission-config-invalid|is not the expected credential directory
unconfigured_manifest|apiserver-not-configured|is absent; run ensure-apiserver
missing_manifest|apiserver-not-configured|not found
stale_apiserver|apiserver-not-configured|runs without the admission configuration
down_apiserver|apiserver-unavailable|no kube-apiserver process is running
unready_apiserver|apiserver-unavailable|kube-apiserver is not ready
missing_configmap|ca-mismatch|does not exist; run publish
other_ca_configmap|ca-mismatch|ca.crt differs from the local CA certificate; run publish, then restart the webhook
extra_key_configmap|ca-mismatch|unexpected object or keys
failing_configmap_get|apiserver-unavailable|cannot read ConfigMap k2s-webhook/clusterip-webhook-client-ca
EOF
verify_reset
near_expiry
run verify
expect_verify 0 ok 'verify accepts a client certificate that expires within 30 days'
check 'verify warns about a client certificate that expires within 30 days' output_has 'WARNING: client certificate expires within 30 days; run renew'
restore_local
new_case
rm -r -- "$K2S_WA_ROOT"
verify_reset
run verify
expect_verify 1 ca-invalid 'verify without a root directory'
check 'verify without a root directory creates nothing' [ ! -e "$K2S_WA_ROOT" ]

# --- verify: webhook configuration, side effects of the dry-run and probe targets ---
verify_case
mwc_variant() { sed "$1" "$MWC_FIXTURE" > "$CASE_DIR/mwc.yaml"; MWC_FILE="$CASE_DIR/mwc.yaml"; }
deploy_variant() { sed -E "$1" "$DEPLOY_FIXTURE" > "$CASE_DIR/deploy.yaml"; DEPLOY_FILE="$CASE_DIR/deploy.yaml"; }
missing_mwc() { MWC_FILE=''; }
renamed_webhook() { mwc_variant 's/name: clusterip.k2s.io$/name: other.k2s.io/'; }
duplicate_webhook() { mwc_variant 's/name: workload.clusterip.k2s.io$/name: clusterip.k2s.io/'; }
url_webhook() { mwc_variant 's|^        port: 443$|        port: 443\n      url: https://webhook.example:8443/mutate|'; }
other_namespace() { mwc_variant '0,/namespace: k2s-webhook$/s//namespace: other/'; }
other_port() { mwc_variant 's/^        port: 443$/        port: 8443/'; }
wrong_path() { mwc_variant 's|path: /mutate$|path: /mutate-workload|'; }
empty_ca_bundle() { MWC_FILE="$MANIFESTS/webhook-config.yaml"; }
missing_deployment() { DEPLOY_FILE=''; }
renamed_container() { deploy_variant 's/^( *- name:) webhook$/\1 other/'; }
no_reserved_ips() { deploy_variant 's/--reserved-ips=50$/--reserved-ips=0/'; }
ipv6_subnet() { deploy_variant 's|--linux-subnet=172.21.0.0/24$|--linux-subnet=fd00::/120|'; }
small_subnet() { deploy_variant 's|--linux-subnet=172.21.0.0/24$|--linux-subnet=172.21.0.0/26|; s/--reserved-ips=50$/--reserved-ips=62/'; }
failing_mwc_get() { GET_FAIL=mutatingwebhookconfiguration; }
failing_deployment_get() { GET_FAIL=deployment; }
failing_rules_get() { GET_FAIL=mutatingwebhookconfigurations,validatingwebhookconfigurations; }
while IFS='|' read -r setup result message; do
    verify_reset
    "$setup"
    run verify
    expect_verify 1 "$result" "verify with $setup"
    check "verify with $setup: reports '$message'" output_has "$message"
    check "verify with $setup: no probe" [ ! -e "$CASE_DIR/s_client.log" ]
    check "verify with $setup: no dry-run" dry_runs_are 0
done <<'EOF'
missing_mwc|webhook-config-invalid|does not exist or does not contain webhook clusterip.k2s.io exactly once
renamed_webhook|webhook-config-invalid|does not exist or does not contain webhook clusterip.k2s.io exactly once
duplicate_webhook|webhook-config-invalid|does not exist or does not contain webhook clusterip.k2s.io exactly once
url_webhook|webhook-config-invalid|does not call Service k2s-webhook/clusterip-webhook on port 443
other_namespace|webhook-config-invalid|does not call Service k2s-webhook/clusterip-webhook on port 443
other_port|webhook-config-invalid|does not call Service k2s-webhook/clusterip-webhook on port 443
wrong_path|webhook-config-invalid|calls path '/mutate-workload' instead of /mutate
empty_ca_bundle|webhook-config-invalid|the caBundle of webhook clusterip.k2s.io is not a certificate
missing_deployment|webhook-config-invalid|Deployment k2s-webhook/clusterip-webhook with container webhook not found
renamed_container|webhook-config-invalid|Deployment k2s-webhook/clusterip-webhook with container webhook not found
no_reserved_ips|webhook-config-invalid|verify needs --reserved-ips between 1 and 999999999, not '0'
ipv6_subnet|webhook-config-invalid|unsupported --linux-subnet 'fd00::/120'
small_subnet|webhook-config-invalid|--linux-subnet '172.21.0.0/26' is too small for --reserved-ips 62
failing_mwc_get|apiserver-unavailable|cannot read MutatingWebhookConfiguration k2s-webhook
failing_deployment_get|apiserver-unavailable|cannot read Deployment k2s-webhook/clusterip-webhook
failing_rules_get|apiserver-unavailable|cannot read the admission webhook configurations
EOF
verify_reset
deploy_variant 's|^( *- )--linux-subnet=172.21.0.0/24$|\1--linux-subnet\n\110.9.0.0/24|; s|^( *- )--reserved-ips=50$|\1-reserved-ips\n\1100|'
run verify
expect_verify 1 admission-failed 'verify reads --linux-subnet and -reserved-ips given as two arguments'
check 'verify computes the Linux range from both arguments' output_has 'assigned no clusterIP from 10.9.0.100-10.9.0.254'
unsafe_webhook() { RULES_OUTPUT+=$'W|other|any.example.io|Some|[*]|[*]|[*/*]|[*]\n'; }
unsafe_subresource() { RULES_OUTPUT+=$'W|val|v.example.io|Unknown|[]|[v1]|[services/*]|[CREATE]\n'; }
undeclared_side_effects() { RULES_OUTPUT+=$'W|val|v.example.io|<no value>|[]|[*]|[*]|[CREATE]\n'; }
unrelated_unsafe_webhooks() {
    RULES_OUTPUT+=$'W|o|pods.example.io|Some|[]|[v1]|[pods]|[CREATE]\nW|o|update.example.io|Some|[]|[v1]|[services]|[UPDATE][DELETE]\n'
    RULES_OUTPUT+=$'W|o|apps.example.io|Unknown|[apps]|[*]|[*]|[*]\nW|o|v2.example.io|Some|[]|[v2]|[services]|[CREATE]\n'
    RULES_OUTPUT+=$'W|o|status.example.io|Some|[]|[v1]|[services/status]|[*]\n'
}
safe_other_webhook() { RULES_OUTPUT+=$'W|linkerd|proxy-injector.linkerd.io|None|[]|[v1]|[pods][services]|[CREATE]\n'; }
while IFS='|' read -r setup rc result message dry_runs; do
    verify_reset
    "$setup"
    run verify
    expect_verify "$rc" "$result" "verify with $setup"
    check "verify with $setup: reports '$message'" output_has "$message"
    check "verify with $setup: $dry_runs dry-run(s)" dry_runs_are "$dry_runs"
    check "verify with $setup: the webhook is probed" probes_are nocert 2
done <<'EOF'
unsafe_webhook|1|unsafe-side-effects|no dry-run Service sent: webhooks matching Services declare side effects: other/any.example.io (sideEffects Some)|0
unsafe_subresource|1|unsafe-side-effects|val/v.example.io (sideEffects Unknown)|0
undeclared_side_effects|1|unsafe-side-effects|val/v.example.io (sideEffects <no value>)|0
unrelated_unsafe_webhooks|0|ok|assigned 172.21.0.50 to the dry-run Service|1
safe_other_webhook|0|ok|also sent to webhooks declaring no side effects: linkerd/proxy-injector.linkerd.io|1
EOF
no_endpoints() { EPS_OUTPUT=''; }
missing_service() { SVC_FILE=''; }
headless_service() { service_yaml None 443 > "$CASE_DIR/svc.yaml"; SVC_FILE="$CASE_DIR/svc.yaml"; }
failing_service_get() { GET_FAIL=service; }
failing_endpoints_get() { GET_FAIL=endpointslices; }
while IFS='|' read -r setup result message; do
    verify_reset
    "$setup"
    run verify
    expect_verify 1 "$result" "verify with $setup"
    check "verify with $setup: reports '$message'" output_has "$message"
    check "verify with $setup: retries" output_has 'retrying in 5s'
    check "verify with $setup: no probe" [ ! -e "$CASE_DIR/s_client.log" ]
    check "verify with $setup: no dry-run" dry_runs_are 0
done <<'EOF'
no_endpoints|webhook-unavailable|Service k2s-webhook/clusterip-webhook has no ready endpoint
missing_service|webhook-unavailable|Service k2s-webhook/clusterip-webhook not found or without clusterIP and https port
headless_service|webhook-unavailable|Service k2s-webhook/clusterip-webhook not found or without clusterIP and https port
failing_service_get|apiserver-unavailable|cannot read Service k2s-webhook/clusterip-webhook
failing_endpoints_get|apiserver-unavailable|cannot read the endpoints of Service k2s-webhook/clusterip-webhook
EOF
verify_reset
EPS_OUTPUT=$'E|172.20.0.10|8443\nE|fd00::10|8443\nE|172.20.0.13|0\nE|not-an-ip|8443\n'
run verify
expect_verify 0 ok 'verify probes every ready endpoint'
check 'an IPv6 endpoint is probed in brackets' grep -q -x -F 'nocert [fd00::10]:8443 rejected ca=ok' "$CASE_DIR/s_client.log"
check 'endpoints without https port or address are ignored and reported' output_has "WARNING: ignoring endpoint '172.20.0.13' port '0'"
check 'the Service and both valid endpoints are probed' probes_are nocert 3

# --- verify: TLS checks (a refused handshake is required; connection failures never count as refusals) ---
# Retried checks run every 5 s of simulated time for K2S_WA_VERIFY_TIMEOUT=10 s: 3 rounds of 2 targets.
probes_between() {
    local n=0
    if [[ -f "$CASE_DIR/s_client.log" ]]; then n=$(grep -c "^$1 " "$CASE_DIR/s_client.log" || :); fi
    (( n >= $2 && n <= $3 )) || { printf '%s %s probes, expected %s to %s\n' "$n" "$1" "$2" "$3"; return 1; }
}
while IFS='|' read -r nocert cert rc result message min max; do
    verify_reset
    TLS_NOCERT="$nocert" TLS_CERT="$cert"
    run verify
    expect_verify "$rc" "$result" "verify with probes $nocert/$cert"
    check "verify with probes $nocert/$cert: reports '$message'" output_has "$message"
    check "verify with probes $nocert/$cert: $min to $max probes without certificate" probes_between nocert "$min" "$max"
    if [[ "$rc" != 0 ]]; then check "verify with probes $nocert/$cert: no dry-run" dry_runs_are 0; fi
done <<'EOF'
rejected-tls12|answered|0|ok|assigned 172.21.0.50|2|2
bad-certificate|answered|0|ok|assigned 172.21.0.50|2|2
answered|answered|1|unauthenticated-accepted|172.21.0.12:443 answered a client without certificate (http:404)|1|1
plain-http|answered|1|inconclusive|172.21.0.12:443: unexpected result without client certificate (unknown)|6|6
eof|answered|1|inconclusive|unexpected result without client certificate (unknown)|6|6
mixed|answered|1|inconclusive|unexpected result without client certificate (unknown)|6|6
expired|answered|1|inconclusive|unexpected result without client certificate (alert:45)|6|6
timeout|answered|1|webhook-unavailable|172.21.0.12:443: no TLS connection (unreachable:timeout)|6|6
refused|answered|1|webhook-unavailable|172.21.0.12:443: no TLS connection (unreachable)|6|6
reset|answered|1|webhook-unavailable|172.21.0.12:443: no TLS connection (unreachable)|6|6
untrusted|untrusted|1|webhook-tls-untrusted|172.21.0.12:443: serving certificate not trusted through the caBundle|6|6
hostname|hostname|1|webhook-tls-untrusted|serving certificate not trusted through the caBundle|6|6
rejected|unknown-ca|1|client-cert-rejected|172.21.0.12:443 refused the client certificate (alert:48, unknown CA: run publish, then restart the webhook)|6|6
rejected|expired|1|client-cert-rejected|refused the client certificate (alert:45, certificate expired)|6|6
rejected|bad-certificate|1|client-cert-rejected|refused the client certificate (alert:42, bad certificate)|6|6
rejected|rejected|1|client-cert-rejected|refused the client certificate (alert:116, TLS alert)|6|6
rejected|timeout|1|webhook-unavailable|no TLS connection (unreachable:timeout)|6|6
rejected|plain-http|1|inconclusive|unexpected result with the client certificate (unknown)|6|6
EOF
verify_reset
# shellcheck disable=SC2034 # read indirectly by fake_s_client
TLS_NOCERT__172_20_0_10_8443=answered
run verify
expect_verify 1 unauthenticated-accepted 'verify detects an endpoint that answers a client without certificate'
check 'the answering endpoint is reported' output_has '172.20.0.10:8443 answered a client without certificate (http:404)'
check 'an answered unauthenticated client fails at once (no retry, no dry-run)' output_lacks 'retrying'
check 'no dry-run after an unauthenticated answer' dry_runs_are 0
verify_reset
# shellcheck disable=SC2034 # read indirectly by fake_s_client
TLS_NOCERT__172_20_0_10_8443=refused
TLS_CERT='unknown-ca'
run verify
expect_verify 1 webhook-unavailable 'the first failing check of a round is reported'
verify_reset
TLS_CERT='unknown-ca unknown-ca answered'
run verify
expect_verify 0 ok 'verify waits for a webhook that is rolling out'
check 'the rollout is reported while waiting' output_has 'not verified yet (client-cert-rejected:'
check 'verify probes again after a rejected client certificate' probes_are cert 6
verify_reset
TLS_NOCERT=refused K2S_WA_VERIFY_TIMEOUT=120
run verify
expect_verify 1 webhook-unavailable 'verify gives up on an unreachable webhook'
check 'by default verify retries for 120 s (25 rounds)' probes_between nocert 50 50

# --- verify: admission through kube-apiserver (dry-run Service and admission metrics) ---
while IFS='|' read -r admission rc result message dry_runs; do
    verify_reset
    ADMISSION="$admission"
    run verify
    expect_verify "$rc" "$result" "verify with admission '$admission'"
    check "verify with admission '$admission': reports '$message'" output_has "$message"
    check "verify with admission '$admission': $dry_runs dry-run(s)" dry_runs_are "$dry_runs"
    check "verify with admission '$admission': only reads and dry-runs" only_reads_and_dry_runs
    check "verify with admission '$admission': only probe Services" dry_runs_are_probe_services
done <<'EOF'
reinvoked|0|ok|assigned 172.21.0.51 to the dry-run Service (calls 2, failed 0, failed open 0, rejected 0, reset 0)|1
concurrent-ok|0|ok|assigned 172.21.0.52 to the dry-run Service (calls 3, failed 0|1
warning|0|ok|assigned 172.21.0.254 to the dry-run Service|1
below-range|1|admission-failed|assigned no clusterIP from 172.21.0.50-172.21.0.254 (clusterIP '172.21.0.49'); is the range exhausted?|3
concurrent-failure|1|inconclusive|the webhook assigned 172.21.0.53, but the admission metrics are ambiguous (calls 2, failed 1, failed open 1|3
fail-open|1|admission-fail-open|failed and kube-apiserver admitted the dry-run Service without it (clusterIP '172.21.0.0', calls 1, failed 1, failed open 1|3
not-called|1|admission-not-called|kube-apiserver did not call webhook clusterip.k2s.io for the dry-run Service (clusterIP '172.21.0.0')|3
no-ip|1|admission-failed|assigned no clusterIP from 172.21.0.50-172.21.0.254 (clusterIP '172.21.0.0')|3
failed|1|admission-failed|the call of webhook clusterip.k2s.io failed (clusterIP '172.21.0.0', calls 1, failed 1, failed open 0|3
noisy|1|inconclusive|clusterIP '172.21.0.0' is outside 172.21.0.50-172.21.0.254 and the admission metrics are ambiguous|3
denied|1|admission-failed|webhook clusterip.k2s.io refused or failed the dry-run Service: Error from server (Forbidden)|3
refused|1|admission-failed|the dry-run Service was refused: Error from server (InternalError)|3
fail-open ok|0|ok|not verified yet (admission-fail-open:|2
not-called denied ok|0|ok|not verified yet (admission-failed:|3
EOF
while IFS='|' read -r mode message dry_runs; do
    verify_reset
    METRICS_MODE="$mode"
    run verify
    expect_verify 1 inconclusive "verify with metrics '$mode'"
    check "verify with metrics '$mode': reports '$message'" output_has "$message"
    check "verify with metrics '$mode': $dry_runs dry-run(s)" dry_runs_are "$dry_runs"
done <<'EOF'
fail|cannot read the admission metrics of kube-apiserver|0
notype|cannot read the admission metrics of kube-apiserver|0
reset|the webhook assigned 172.21.0.50, but the admission metrics are ambiguous (calls 0, failed 0, failed open 0, rejected 0, reset 1)|3
EOF
verify_reset
printf '5 2 2 0\n' > "$CASE_DIR/metrics"
METRICS_MODE=vanish
run verify
expect_verify 1 inconclusive 'verify with webhook metrics that disappeared (kube-apiserver restarted)'
check 'disappeared metrics count as a reset' \
    output_has 'the webhook assigned 172.21.0.50, but the admission metrics are ambiguous (calls 1, failed 0, failed open 0, rejected 0, reset 1)'
verify_reset
ADMISSION=fail-open
run verify
check 'a call that failed open is explained by the failurePolicy Ignore' output_has 'has failurePolicy Ignore'

# --- verify: lock ---
verify_reset
exec {held}>"$K2S_WA_LOCK_FILE"
flock -n "$held"
K2S_WA_LOCK_TIMEOUT=1
run verify
expect_rc 1 'verify does not run while another run holds the lock'
check 'the held lock is reported' output_has 'another clusterip-webhook-auth.sh run holds the lock'
check 'no result line while the lock is held' output_lacks 'K2S-WEBHOOK-AUTH-VERIFY'
check 'nothing is probed while the lock is held' [ ! -e "$CASE_DIR/s_client.log" ]
exec {held}>&-
exec {held}<"$K2S_WA_LOCK_FILE"
flock -s -n "$held"
run verify
expect_verify 0 ok 'verify runs while another verify holds the lock'
exec {held}<&-

# --- renew: a new certificate for the same key, restored if the webhook does not accept it ---
cert_sha() { sha256sum < "$1" | cut -c1-64; }
file_state() { stat -c '%i %Y %s %a %U %G' -- "$1" 2>/dev/null || printf 'absent\n'; }
renew_case() { verify_case; OLD_SHA=$(cert_sha "$CRT"); OLD_KEY_ID=$(key_id "$KEY"); OLD_OWNER=$(stat -c '%a %U %G' -- "$CRT"); }
new_cert_ok() {
    [[ "$(cert_sha "$CRT")" != "$OLD_SHA" && "$(key_id "$KEY")" == "$OLD_KEY_ID" ]] || { printf 'certificate not renewed or key changed\n'; return 1; }
    k2s_wa_check_client_cert "$CRT" "$KEY" "$CA_CRT" || { printf '%s\n' "$K2S_WA_REASON"; return 1; }
    [[ "$(cert_days "$CRT")" == "$K2S_WA_CERT_DAYS" && "$(stat -c '%a %U %G' -- "$CRT")" == "$OLD_OWNER" ]]
}
RENEW_ORDER='sync -- <root>/k2s-webhook-auth-backup/.client.crt.tmp.X
mv -f -- <root>/k2s-webhook-auth-backup/.client.crt.tmp.X <root>/k2s-webhook-auth-backup/client.crt
sync -- <root>/k2s-webhook-auth-backup
sync -- <root>/k2s-webhook-auth/.client.crt.tmp.X
mv -f -- <root>/k2s-webhook-auth/.client.crt.tmp.X <root>/k2s-webhook-auth/client.crt
sync -- <root>/k2s-webhook-auth'
RESTORE_ORDER='sync -- <root>/k2s-webhook-auth/.client.crt.tmp.X
mv -f -- <root>/k2s-webhook-auth/.client.crt.tmp.X <root>/k2s-webhook-auth/client.crt
sync -- <root>/k2s-webhook-auth'
# Without --force a valid certificate is only verified: renew runs once and takes only its own exclusive lock (the
# verification is the k2s_wa_verify function, not a recursive run of the script).
count_renew_calls() {
    eval "counted_$(declare -f k2s_wa_renew)"
    k2s_wa_renew() { printf 'renew %s\n' "$*" >> "$CASE_DIR/calls.log"; counted_k2s_wa_renew "$@"; }
    flock() { printf 'flock %s\n' "$*" >> "$CASE_DIR/calls.log"; command flock "$@"; }
}
renew_ran_once() {
    local calls re=$'^flock -w 300 [0-9]+\nrenew 0$'
    calls=$(<"$CASE_DIR/calls.log")
    [[ "$calls" =~ $re ]] && return 0
    printf 'calls:\n%s\n' "$calls"
    return 1
}
cert_unchanged() { [[ "$(cert_sha "$CRT")|$(file_state "$CRT")|$(stat -c %y -- "$CRT")" == "$OLD_SHA|$crt_state|$crt_mtime" ]]; }
renew_case
crt_state=$(file_state "$CRT")
crt_mtime=$(stat -c %y -- "$CRT")
run_with count_renew_calls renew
expect_rc 0 'renew of a certificate valid for more than 30 days succeeds when verification succeeds'
check 'renew without change prints its success marker last' marker_is renew
check 'renew without change reports it' output_has 'is valid for more than 30 days; not renewed (--force renews it anyway); verifying webhook authentication'
check 'renew without change verifies webhook authentication' output_has 'verified: the webhook refuses clients without certificate'
check 'renew without change probes the webhook without and with the certificate' probes_are cert 2
check 'renew without change verifies admission with one dry-run' dry_runs_are 1
check 'renew without change only reads from the cluster and sends a dry-run' only_reads_and_dry_runs
check 'renew without change keeps the certificate content, file and modification time' cert_unchanged
check 'renew without change creates no backup' [ ! -e "$K2S_WA_CERT_BACKUP_FILE" ]
check 'renew without change does not renew' output_lacks 'renewed kube-apiserver client certificate'
check 'renew without change prints no verify result line' output_lacks 'K2S-WEBHOOK-AUTH-VERIFY'
check 'renew without change runs once and takes only its own lock (no recursion)' renew_ran_once
check 'renew without change leaves no temporary files' no_leftovers
printf 'previous backup\n' > "$K2S_WA_CERT_BACKUP_FILE"
backup_state="$(file_state "$K2S_WA_CERT_BACKUP_FILE") $(stat -c %y -- "$K2S_WA_CERT_BACKUP_FILE") $(cert_sha "$K2S_WA_CERT_BACKUP_FILE")"
verify_reset
run renew
expect_rc 0 'renew without change succeeds with an existing backup'
check 'renew without change does not overwrite an existing backup' \
    [ "$(file_state "$K2S_WA_CERT_BACKUP_FILE") $(stat -c %y -- "$K2S_WA_CERT_BACKUP_FILE") $(cert_sha "$K2S_WA_CERT_BACKUP_FILE")" = "$backup_state" ]
check 'renew without change with an existing backup keeps the certificate' cert_unchanged
admission_fails_open() { ADMISSION=fail-open; }
answers_without_certificate() { TLS_NOCERT=answered; }
webhook_refuses_connections() { TLS_NOCERT=refused; }
while IFS='|' read -r setup result; do
    renew_case
    printf 'previous backup\n' > "$K2S_WA_CERT_BACKUP_FILE"
    backup_state="$(file_state "$K2S_WA_CERT_BACKUP_FILE") $(stat -c %y -- "$K2S_WA_CERT_BACKUP_FILE")"
    crt_state=$(file_state "$CRT")
    crt_mtime=$(stat -c %y -- "$CRT")
    "$setup"
    run renew
    expect_rc 1 "renew of a valid certificate fails when verification fails ($setup)"
    check "renew with $setup: the verification result is reported" \
        output_has "webhook authentication does not work with the current client certificate ($result); it is valid, so it was not renewed"
    check "renew with $setup: the verification failure is reported" output_has "verification failed ($result)"
    check "renew with $setup: no success marker" no_marker
    check "renew with $setup: the certificate is unchanged (content and modification time)" cert_unchanged
    check "renew with $setup: the existing backup is not overwritten" \
        [ "$(file_state "$K2S_WA_CERT_BACKUP_FILE") $(stat -c %y -- "$K2S_WA_CERT_BACKUP_FILE")" = "$backup_state" ]
    check "renew with $setup: no renewal is attempted" output_lacks 'renewed kube-apiserver client certificate'
    check "renew with $setup: no temporary files remain" no_leftovers
done <<'EOF'
admission_fails_open|admission-fail-open
answers_without_certificate|unauthenticated-accepted
webhook_refuses_connections|webhook-unavailable
EOF
for setup in corrupt_ca expiring_ca; do
    renew_case
    crt_state=$(file_state "$CRT")
    crt_mtime=$(stat -c %y -- "$CRT")
    "$setup"
    run renew
    expect_rc 1 "renew without --force with $setup is refused before any verification"
    check "renew without --force with $setup: the client CA is reported" output_has 'is missing or invalid'
    check "renew without --force with $setup: no cluster access" [ ! -e "$CASE_DIR/kubectl.log" ]
    check "renew without --force with $setup: the certificate is unchanged" cert_unchanged
done
renew_case
verify_reset
manifest_state=$(file_state "$K2S_WA_MANIFEST")
run_with order_hooks renew --force
expect_rc 0 'renew --force reissues a valid certificate'
check 'renew --force prints its success marker last' marker_is renew
check 'renew --force prints no verify result line' output_lacks 'K2S-WEBHOOK-AUTH-VERIFY'
check 'renew --force issues a new certificate for the same key, valid for 365 days, with the same owner and mode' new_cert_ok
check 'renew --force keeps the previous certificate as backup' [ "$(cert_sha "$K2S_WA_CERT_BACKUP_FILE")" = "$OLD_SHA" ]
check 'the certificate backup is private' modes_are 700 "$K2S_WA_BACKUP_DIR" 644 "$K2S_WA_CERT_BACKUP_FILE"
check 'renew --force verifies before and after the renewal' dry_runs_are 2
check 'renew --force flushes the backup and the new certificate before their renames, the directories after them' order_is "$RENEW_ORDER"
check 'renew --force does not touch the kube-apiserver manifest (no restart)' [ "$(file_state "$K2S_WA_MANIFEST")" = "$manifest_state" ]
check 'renew --force only reads from the cluster and sends dry-runs' only_reads_and_dry_runs
check 'renew --force leaves no temporary files' no_leftovers
renew_case
expired_cert
OLD_SHA=$(cert_sha "$CRT")
printf 'older backup\n' > "$K2S_WA_CERT_BACKUP_FILE"
backup_state=$(file_state "$K2S_WA_CERT_BACKUP_FILE")
run renew
expect_rc 0 'renew replaces an expired certificate'
check 'renew of an expired certificate prints its success marker last' marker_is renew
check 'renew of an expired certificate reports that nothing can be restored' output_has 'renewing without a certificate to restore: client certificate is not valid for the client CA'
check 'renew of an expired certificate issues a valid certificate for the same key' new_cert_ok
check 'renew of an expired certificate keeps an existing backup' [ "$(file_state "$K2S_WA_CERT_BACKUP_FILE")" = "$backup_state" ]
check 'renew of an expired certificate reports the kept backup' output_has 'is kept and not used'
check 'renew of an expired certificate verifies only afterwards' dry_runs_are 1
for setup in corrupt_cert mismatched_cert server_auth_cert foreign_cert near_expiry; do
    renew_case
    "$setup"
    OLD_SHA=$(cert_sha "$CRT")
    run renew
    expect_rc 0 "renew replaces a certificate after $setup"
    check "renew after $setup takes the renewal path, not the verification-only path" output_lacks 'not renewed (--force renews it anyway)'
    check "renew after $setup issues a valid certificate for the same key" new_cert_ok
    if [[ "$setup" == near_expiry ]]; then
        check "renew after $setup backs up the usable certificate" [ "$(cert_sha "$K2S_WA_CERT_BACKUP_FILE")" = "$OLD_SHA" ]
        check "renew after $setup verifies before and after" dry_runs_are 2
    else
        check "renew after $setup takes no backup" [ ! -e "$K2S_WA_CERT_BACKUP_FILE" ]
        check "renew after $setup verifies only afterwards" dry_runs_are 1
    fi
done
partial_manifest() { sed -i "/--admission-control-config-file=/d" "$K2S_WA_MANIFEST"; }
custom_manifest() { sed -i "s|$K2S_WA_FLAG|--admission-control-config-file=/etc/other/admission.yaml|" "$K2S_WA_MANIFEST"; }
unavailable_webhook() { TLS_NOCERT=refused; }
while IFS='|' read -r setup rc message; do
    renew_case
    "$setup"
    crt_state=$(file_state "$CRT")
    key_state=$(file_state "$KEY")
    run renew --force
    expect_rc "$rc" "renew with $setup is refused"
    check "renew with $setup: reports '$message'" output_has "$message"
    check "renew with $setup: the certificate is unchanged" [ "$(file_state "$CRT")" = "$crt_state" ]
    check "renew with $setup: the key is unchanged" [ "$(file_state "$KEY")" = "$key_state" ]
    check "renew with $setup: no backup" [ ! -e "$K2S_WA_CERT_BACKUP_FILE" ]
    check "renew with $setup: no success marker" no_marker
    check "renew with $setup: no dry-run" dry_runs_are 0
done <<'EOF'
corrupt_ca|1|renew never replaces it. Run provision first, or replace the CA manually
expiring_ca|1|ca.crt expires within 395 days
corrupt_key|1|renew keeps the key and never creates one. Run provision
unconfigured_manifest|1|kube-apiserver does not use the client certificate yet; run ensure-apiserver first
missing_manifest|1|not found; run ensure-apiserver first
partial_manifest|3|contains an incomplete clusterip-webhook admission configuration
custom_manifest|3|kube-apiserver uses another --admission-control-config-file
symlinked_auth_dir|1|is not a directory; run provision first
extra_auth_file|1|unexpected entries
unavailable_webhook|1|webhook authentication does not work with the current client certificate (webhook-unavailable); not renewing it
EOF
# Failures before the certificate is replaced leave it unchanged; a failed directory flush after it is reported only.
renew_fail_sync() { SYNC_FAIL="$1"; failing_sync; }
backup_sync() { renew_fail_sync "$K2S_WA_BACKUP_DIR/.client.crt.tmp.*"; }
backup_dir_sync() { renew_fail_sync "$K2S_WA_BACKUP_DIR"; }
new_cert_sync() { renew_fail_sync "$K2S_WA_AUTH_DIR/.client.crt.tmp.*"; }
while IFS='|' read -r setup message; do
    renew_case
    crt_state=$(file_state "$CRT")
    run_with "$setup" renew --force
    expect_rc 1 "renew with $setup fails"
    check "renew with $setup: reports '$message'" output_has "$message"
    check "renew with $setup: the certificate is unchanged" [ "$(file_state "$CRT")" = "$crt_state" ]
    check "renew with $setup: no temporary files remain" no_leftovers
    check "renew with $setup: no success marker" no_marker
done <<'EOF'
backup_sync|cannot back up
backup_dir_sync|cannot back up
new_cert_sync|cannot flush the new certificate to disk; '
fail_chown|cannot copy the owner and mode of the current certificate
fail_signing|client certificate signing failed
EOF
renew_fail_sync_dir() { renew_fail_sync "$K2S_WA_AUTH_DIR"; }
renew_case
run_with renew_fail_sync_dir renew --force
expect_rc 0 'renew succeeds if only the flush of the credential directory fails'
check 'the failed flush of the credential directory is reported' output_has "WARNING: cannot flush '$K2S_WA_AUTH_DIR' to disk"
check 'the certificate is renewed despite the failed flush' new_cert_ok

# The webhook trusts only the current certificate (TLS_TRUSTED_SHA): it refuses the renewed one in the TLS check, and
# kube-apiserver's calls with it fail open.
renew_case
TLS_TRUSTED_SHA="$OLD_SHA" TLS_CERT=trusted-cert ADMISSION=trusted-cert
run_with order_hooks renew --force
expect_rc 5 'renew restores the previous certificate when the webhook refuses the renewed one'
check 'rollback: the refusal of the renewed certificate is reported' output_has 'does not work with the renewed client certificate (client-cert-rejected); restoring the previous certificate'
check 'rollback: the verified restore is reported' output_has 'previous client certificate restored; webhook authentication works with it'
check 'rollback: the previous certificate is back' [ "$(cert_sha "$CRT")" = "$OLD_SHA" ]
check 'rollback: the restored certificate keeps owner and mode' [ "$(stat -c '%a %U %G' -- "$CRT")" = "$OLD_OWNER" ]
check 'rollback: the backup is kept' [ "$(cert_sha "$K2S_WA_CERT_BACKUP_FILE")" = "$OLD_SHA" ]
check 'rollback: the restored certificate is flushed before its rename, the directory after it' order_is "$RENEW_ORDER
$RESTORE_ORDER"
check 'rollback: no success marker' no_marker
check 'rollback: no temporary files remain' no_leftovers
check 'rollback: the restore is verified with a successful dry-run' dry_runs_are 2
backup_state=$(file_state "$K2S_WA_CERT_BACKUP_FILE")
crt_state=$(file_state "$CRT")
verify_reset
run renew
expect_rc 0 'renew after a rollback keeps the restored certificate'
check 'renew after a rollback leaves the certificate and its backup unchanged' \
    [ "$(file_state "$CRT")|$(file_state "$K2S_WA_CERT_BACKUP_FILE")" = "$crt_state|$backup_state" ]
verify_reset
run verify
expect_verify 0 ok 'verify succeeds after a rollback'
renew_case
ADMISSION='ok fail-open'
run renew --force
expect_rc 6 'renew exits 6 when the restored certificate cannot be verified either'
check 'failed recovery: reported' output_has 'previous client certificate restored, but webhook authentication could not be verified (admission-fail-open)'
check 'failed recovery: the previous certificate is back' [ "$(cert_sha "$CRT")" = "$OLD_SHA" ]
check 'failed recovery: no success marker' no_marker
check 'failed recovery: three dry-runs after the renewal and three after the restore' dry_runs_are 7
fail_restore_copy() {
    cp() {
        if [[ "${!#}" == "$K2S_WA_AUTH_DIR"/.client.crt.tmp.* ]]; then printf 'injected cp failure\n'; return 1; fi
        command cp "$@"
    }
}
renew_case
ADMISSION='ok fail-open'
run_with fail_restore_copy renew --force
expect_rc 6 'renew exits 6 when the previous certificate cannot be restored'
check 'failed restore: reported' output_has "cannot restore '$CRT' from '$K2S_WA_CERT_BACKUP_FILE'; restore it manually"
check 'failed restore: the renewed certificate stays' new_cert_ok
check 'failed restore: the backup is intact' [ "$(cert_sha "$K2S_WA_CERT_BACKUP_FILE")" = "$OLD_SHA" ]
check 'failed restore: no temporary files remain' no_leftovers
renew_case
expired_cert
OLD_SHA=$(cert_sha "$CRT")
ADMISSION=fail-open
run renew
expect_rc 1 'renew of an expired certificate fails if the renewed one cannot be verified'
check 'unverified renewal without rollback target: no restart, guidance reported' \
    output_has 'and there is no previous certificate to restore; kube-apiserver was not restarted'
check 'unverified renewal without rollback target: the renewed certificate stays' new_cert_ok
check 'unverified renewal without rollback target: no backup is created' [ ! -e "$K2S_WA_CERT_BACKUP_FILE" ]

# --- verify and renew with real TLS: openssl s_server on loopback requires client certificates like the webhook ---
TLS_SERVER_PID='' TLS_PORT=''
stop_tls_server() {
    if [[ -n "$TLS_SERVER_PID" ]]; then kill "$TLS_SERVER_PID" 2>/dev/null || :; wait "$TLS_SERVER_PID" 2>/dev/null || :; fi
    TLS_SERVER_PID=''
}
trap 'stop_tls_server; rm -rf -- "$TEST_DIR"' EXIT
# start_tls_server <client CA file, empty for no client certificate request>: sets TLS_PORT.
start_tls_server() {
    local attempt
    local -a client_auth=()
    if [[ -n "$1" ]]; then client_auth=(-CAfile "$1" -Verify 1 -verify_return_error); fi
    for attempt in 1 2 3 4 5; do
        TLS_PORT=$((20000 + RANDOM % 40000))
        openssl s_server -quiet -accept "127.0.0.1:$TLS_PORT" -cert "$SERVER_CRT" -key "$SERVER_KEY" \
            ${client_auth[@]+"${client_auth[@]}"} -www < /dev/null > "$CASE_DIR/s_server-$attempt.log" 2>&1 &
        TLS_SERVER_PID=$!
        for _ in $(seq 50); do
            kill -0 "$TLS_SERVER_PID" 2>/dev/null || break
            if (exec 3<>"/dev/tcp/127.0.0.1/$TLS_PORT") 2>/dev/null; then return 0; fi
            command sleep 0.1
        done
        stop_tls_server
    done
    return 1
}
real_tls_targets() {
    TLS_MODE=real
    service_yaml 127.0.0.1 "$TLS_PORT" > "$CASE_DIR/service-real.yaml"
    SVC_FILE="$CASE_DIR/service-real.yaml" EPS_OUTPUT="E|127.0.0.1|$TLS_PORT"$'\n'
}
verify_case
if start_tls_server "$K2S_WA_CA_DIR/ca.crt"; then
    real_tls_targets
    run verify
    expect_verify 0 ok 'real TLS: verify succeeds against a server that requires the client certificate'
    for tool in timeout awk base64; do ln -s -- "$(type -P "$tool")" "$BIN/$tool"; done
    verify_reset
    real_tls_targets
    run_path verify
    expect_verify 0 ok 'real TLS: verify needs only its declared tools'
    verify_reset
    real_tls_targets
    OLD_SHA=$(cert_sha "$CRT")
    run_path renew --force
    expect_rc 0 'real TLS: renew --force needs only its declared tools'
    check 'real TLS: the renewed certificate is accepted by the server' [ "$(cert_sha "$CRT")" != "$OLD_SHA" ]
    stop_tls_server
    start_tls_server ''
    verify_reset
    real_tls_targets
    run verify
    expect_verify 1 unauthenticated-accepted 'real TLS: verify detects a server that does not require client certificates'
    stop_tls_server
    start_tls_server "$FOREIGN_CRT"
    verify_reset
    real_tls_targets
    run verify
    expect_verify 1 client-cert-rejected 'real TLS: verify detects a server that does not trust the client CA'
    check 'real TLS: the unknown CA is reported' output_has 'alert:48, unknown CA'
    stop_tls_server
    verify_reset
    real_tls_targets
    run verify
    expect_verify 1 webhook-unavailable 'real TLS: a closed port is unavailable, not a refused handshake'
else
    printf 'SKIP: openssl s_server cannot listen on loopback; verify was tested with replayed TLS results only\n'
fi
verify_reset

# --- kubectl user preferences: every kubectl command runs with KUBERC=off ---
# A kubectl shim records the environment and arguments of every call. --local calls run the real kubectl,
# which applies kuberc preferences by default since v1.34; cluster calls are answered by the shim.
REAL_KUBECTL=$(type -P kubectl)
SHIM_BIN="$TEST_DIR/kubectl-shim"
mkdir -- "$SHIM_BIN"
cat > "$SHIM_BIN/kubectl" <<'EOF'
#!/bin/bash
printf 'KUBERC=%s|KUBECONFIG=%s|%s\n' "${KUBERC-<unset>}" "${KUBECONFIG-<unset>}" "$*" >> "$SHIM_LOG"
if [[ " $* " != *' --local '* ]]; then
    # Every request to kube-apiserver has exactly one client-side timeout; a cache directory must exist during the call.
    timeouts=0 cache=''
    for ((i = 1; i <= $#; i++)); do
        case "${!i}" in
            --request-timeout | --request-timeout=*) timeouts=$((timeouts + 1)) ;;
            --cache-dir) j=$((i + 1)); cache="${!j}" ;;
        esac
    done
    if (( timeouts != 1 )); then printf 'kubectl shim: %s request timeouts in: %s\n' "$timeouts" "$*" >&2; exit 97; fi
    if [[ -n "$cache" ]]; then
        if [[ -d "$cache" ]]; then printf '%s present\n' "$cache"; else printf '%s absent\n' "$cache"; fi >> "$SHIM_LOG.cache"
    fi
fi
# SHIM_SIGNAL_ON: the script (SHIM_SIGNAL_PID, the shell running main) receives SIGTERM during this call.
# SHIM_TIMEOUT: this call times out like kubectl.
if [[ -n "$SHIM_SIGNAL_ON" && " $* " == *" $SHIM_SIGNAL_ON "* ]]; then kill -TERM "$SHIM_SIGNAL_PID"; fi
if [[ -n "$SHIM_TIMEOUT" && " $* " == *" $SHIM_TIMEOUT "* ]]; then
    printf 'Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded while awaiting headers)\n' >&2
    exit 1
fi
if [[ -n "$SHIM_FAIL" && " $* " == *" $SHIM_FAIL "* ]]; then printf 'error: injected failure\n' >&2; exit 1; fi
render() { exec "$SHIM_KUBECTL" patch --local -f "$1" --type=json -p '[]' -o "$2"; }
case " $* " in
    *' --local '*) exec "$SHIM_KUBECTL" "$@" ;;
    *' get --raw=/readyz '*) printf 'ok' ;;
    *' apply '*) cp -- "${!#}" "$SHIM_STATE" ;;
    *' get configmap '*' -o yaml ') cat -- "$SHIM_STATE" ;;
    *' get configmap '*) render "$SHIM_STATE" "${!#}" ;;
    *' get mutatingwebhookconfiguration '*) render "$SHIM_MWC" "${!#}" ;;
    *' get deployment '*) render "$SHIM_DEPLOY" "${!#}" ;;
    *' get service '*) render "$SHIM_SVC" "${!#}" ;;
    *' get endpointslices '*) printf '%s' "$SHIM_EPS" ;;
    *' get mutatingwebhookconfigurations,validatingwebhookconfigurations '*) printf '%s' "$SHIM_RULES" ;;
    *' get --raw=/metrics '*)
        calls=$(( $(cat -- "$SHIM_STATE.metrics" 2>/dev/null || printf 0) + 1 ))
        printf '%s\n' "$calls" > "$SHIM_STATE.metrics"
        printf '# TYPE apiserver_request_total counter\n'
        if (( calls / 2 > 0 )); then
            printf 'apiserver_admission_webhook_request_total{code="200",name="clusterip.k2s.io",operation="CREATE",rejected="false",type="admit"} %s\n' "$((calls / 2))"
        fi ;;
    *' create --dry-run=server '*) cat > "$SHIM_STATE.dry-run"; printf 'clusterIP=172.21.0.50\n' ;;
    *) printf 'unexpected kubectl call: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
chmod 0755 -- "$SHIM_BIN/kubectl"
SHIM_FAIL='' SHIM_KUBERC='' SHIM_TIMEOUT='' SHIM_SIGNAL_ON=''
# Setup for run_with: the real k2s_wa_kubectl, kubectl resolved to the shim (hash -p, PATH is unchanged),
# HOME with a kuberc and, if SHIM_KUBERC is set, KUBERC exported.
kuberc_env() {
    export HOME="$CASE_DIR/home" SHIM_LOG="$CASE_DIR/kubectl-shim.log" SHIM_KUBECTL="$REAL_KUBECTL" \
        SHIM_STATE="$CASE_DIR/kubectl-shim-configmap.yaml" SHIM_FAIL SHIM_MWC="$MWC_FIXTURE" SHIM_DEPLOY="$DEPLOY_FIXTURE" \
        SHIM_SVC="$SVC_FIXTURE" SHIM_EPS="$EPS_DEFAULT" SHIM_RULES="$RULES_DEFAULT" SHIM_TIMEOUT SHIM_SIGNAL_ON
    if [[ -n "$SHIM_KUBERC" ]]; then export KUBERC="$SHIM_KUBERC"; else unset KUBERC; fi
    hash -p "$SHIM_BIN/kubectl" kubectl
    k2s_wa_kubectl() { real_k2s_wa_kubectl "$@"; }
}
# A kuberc that makes go-templates fail on missing keys (the state template ranges over the absent .args),
# and a malformed kuberc.
kuberc_case() {
    manifest_case
    mkdir -p -- "$CASE_DIR/home/.kube" "$CASE_DIR/empty-home"
    printf '%s\n' 'apiVersion: kubectl.config.k8s.io/v1beta1' 'kind: Preference' 'defaults:' '- command: patch' \
        '  options:' '  - name: allow-missing-template-keys' '    default: "false"' > "$CASE_DIR/home/.kube/kuberc"
    printf 'not: [valid\n' > "$CASE_DIR/kuberc-malformed"
}
# Renders the state of the original manifest with the real kubectl; the arguments are passed to env.
local_state_with() {
    env "$@" KUBECONFIG=/dev/null "$REAL_KUBECTL" patch --local -f "$FIXTURE" --type=json -p '[]' \
        -o "go-template=$K2S_WA_STATE_TEMPLATE" > /dev/null 2>&1
}
# Every call has KUBERC=off; --local calls KUBECONFIG=/dev/null, cluster calls the admin kubeconfig.
kubectl_calls_use_kuberc_off() {
    local line bad=0
    [[ -s "$CASE_DIR/kubectl-shim.log" ]] || { printf 'no kubectl call recorded\n'; return 1; }
    while IFS= read -r line; do
        case "$line" in
            'KUBERC=off|KUBECONFIG=/dev/null|patch --local '*) ;;
            "KUBERC=off|KUBECONFIG="*"|--kubeconfig $K2S_WA_ADMIN_KUBECONFIG "*) ;;
            *) printf 'unexpected kubectl environment: %s\n' "${line:0:160}"; bad=1 ;;
        esac
    done < "$CASE_DIR/kubectl-shim.log"
    (( bad == 0 ))
}
# The distinct kubectl commands of ensure-apiserver and publish, with temporary names replaced.
kubectl_calls_are_unchanged() {
    local line actual expected admin="--kubeconfig $K2S_WA_ADMIN_KUBECONFIG"
    actual=$(while IFS= read -r line; do
        line="${line#*|*|}"
        line="${line//"$K2S_WA_MANIFEST_DIR/.kube-apiserver.yaml.k2s-webhook-auth."??????/<staged>}"
        printf '%s\n' "${line//"$K2S_WA_ROOT/.k2s-webhook-auth-publish.tmp."??????/<work>}"
    done < "$CASE_DIR/kubectl-shim.log" | LC_ALL=C sort -u)
    expected=$(printf '%s\n' \
        "patch --local -f $K2S_WA_MANIFEST --type=json -p [] -o go-template=$K2S_WA_STATE_TEMPLATE" \
        "$admin get --raw=/readyz --request-timeout=5s" \
        "patch --local -f $K2S_WA_MANIFEST --type=json --patch-file $K2S_WA_PATCH_FILE -o yaml" \
        "patch --local -f <staged> --type=json -p [] -o go-template=$K2S_WA_STATE_TEMPLATE" \
        "patch --local -f <work>/configmap.yaml --type=json -p [] -o go-template=$K2S_WA_CONFIGMAP_TEMPLATE" \
        'patch --local -f <work>/configmap.yaml --type=json -p [] -o jsonpath={.data.ca\.crt}' \
        "$admin --request-timeout=30s apply --server-side --force-conflicts --field-manager=$K2S_WA_FIELD_MANAGER -f <work>/configmap.yaml" \
        "$admin --request-timeout=30s get configmap $K2S_WA_CONFIGMAP -n $K2S_WA_NAMESPACE -o yaml" \
        "patch --local -f <work>/published.yaml --type=json -p [] -o go-template=$K2S_WA_CONFIGMAP_TEMPLATE" \
        'patch --local -f <work>/published.yaml --type=json -p [] -o jsonpath={.data.ca\.crt}' | LC_ALL=C sort -u)
    [[ "$actual" == "$expected" ]] && return 0
    printf 'kubectl commands differ (recorded only, then expected only with a tab):\n'
    LC_ALL=C comm -3 <(printf '%s\n' "$actual") <(printf '%s\n' "$expected") | cut -c1-200
    return 1
}
kuberc_case
check 'KUBERC=off: kubectl ignores the kuberc in HOME' local_state_with HOME="$CASE_DIR/home" KUBERC=off
if local_state_with -u KUBERC HOME="$CASE_DIR/home"; then
    printf 'SKIP: this kubectl ignores kuberc (before v1.34 or disabled); KUBERC=off is checked in the recorded environment only\n'
else
    pass 'without KUBERC=off, the kuberc in HOME breaks the manifest state template'
fi
if local_state_with HOME="$CASE_DIR/empty-home" KUBERC="$CASE_DIR/kuberc-malformed"; then
    printf 'SKIP: this kubectl ignores KUBERC (before v1.34 or disabled)\n'
else
    pass 'without KUBERC=off, a malformed kuberc named by KUBERC breaks kubectl'
fi
run_with kuberc_env provision
expect_rc 0 'kuberc in HOME: provision succeeds'
check 'kuberc in HOME: provision runs no kubectl command' [ ! -e "$CASE_DIR/kubectl-shim.log" ]
run_with kuberc_env ensure-apiserver
expect_rc 0 'kuberc in HOME: ensure-apiserver succeeds'
check 'kuberc in HOME: ensure-apiserver prints its success marker last' marker_is ensure-apiserver
check 'kuberc in HOME: the manifest is configured' manifest_state_is configured
run_with kuberc_env publish
expect_rc 0 'kuberc in HOME: publish succeeds'
check 'kuberc in HOME: publish prints its success marker last' marker_is publish
check 'kuberc in HOME: every kubectl command runs with KUBERC=off' kubectl_calls_use_kuberc_off
check 'kuberc in HOME: the kubectl commands are unchanged' kubectl_calls_are_unchanged
kuberc_case
SHIM_KUBERC="$CASE_DIR/kuberc-malformed"
run_with kuberc_env ensure-apiserver
expect_rc 0 'malformed kuberc in KUBERC: ensure-apiserver succeeds'
check 'malformed kuberc in KUBERC: the manifest is configured' manifest_state_is configured
run_with kuberc_env publish
expect_rc 0 'malformed kuberc in KUBERC: publish succeeds'
check 'malformed kuberc in KUBERC: every kubectl command runs with KUBERC=off' kubectl_calls_use_kuberc_off
check 'malformed kuberc in KUBERC: the kubectl commands are unchanged' kubectl_calls_are_unchanged
SHIM_KUBERC=''
kuberc_case
SHIM_FAIL=--patch-file
run_with kuberc_env ensure-apiserver
expect_rc 1 'kuberc: a failing kubectl patch still fails ensure-apiserver'
check 'kuberc: the failing patch is reported' output_has "cannot apply '$K2S_WA_PATCH_FILE' to '$K2S_WA_MANIFEST'"
check 'kuberc: the manifest is unchanged after the failing patch' cmp -s -- "$FIXTURE" "$K2S_WA_MANIFEST"
SHIM_FAIL=apply
run_with kuberc_env publish
expect_rc 1 'kuberc: a failing kubectl apply still fails publish'
check 'kuberc: the failing apply is reported' output_has "cannot publish ConfigMap $K2S_WA_NAMESPACE/$K2S_WA_CONFIGMAP"
check 'kuberc: failing kubectl commands run with KUBERC=off as well' kubectl_calls_use_kuberc_off
SHIM_FAIL=''
# verify and renew: the distinct kubectl commands are cluster reads and the server-side dry-run of the probe Service, each
# with a private cache directory (written as <cache>) and a client-side timeout.
verify_kubectl_calls_are() {
    local line actual expected admin="--kubeconfig $K2S_WA_ADMIN_KUBECONFIG" cached="--kubeconfig $K2S_WA_ADMIN_KUBECONFIG --cache-dir <cache>"
    actual=$(while IFS= read -r line; do
        line="${line#*|*|}"
        if [[ "$line" =~ ^(.*--cache-dir )[^\ ]+(\ .*)$ ]]; then line="${BASH_REMATCH[1]}<cache>${BASH_REMATCH[2]}"; fi
        printf '%s\n' "$line"
    done < "$CASE_DIR/kubectl-shim.log" | LC_ALL=C sort -u)
    expected=$(printf '%s\n' \
        "patch --local -f $K2S_WA_MANIFEST --type=json -p [] -o go-template=$K2S_WA_STATE_TEMPLATE" \
        "$cached get --raw=/readyz --request-timeout=5s" \
        "$cached --request-timeout=30s get configmap $K2S_WA_CONFIGMAP -n $K2S_WA_NAMESPACE --ignore-not-found -o go-template=$K2S_WA_CONFIGMAP_TEMPLATE" \
        "$cached --request-timeout=30s get configmap $K2S_WA_CONFIGMAP -n $K2S_WA_NAMESPACE -o "'jsonpath={.data.ca\.crt}' \
        "$cached --request-timeout=30s get mutatingwebhookconfiguration $K2S_WA_WEBHOOK_CONFIG --ignore-not-found -o go-template=$K2S_WA_WEBHOOKS_TEMPLATE" \
        "$cached --request-timeout=30s get deployment $K2S_WA_DEPLOYMENT -n $K2S_WA_NAMESPACE --ignore-not-found -o go-template=$K2S_WA_ARGS_TEMPLATE" \
        "$cached --request-timeout=30s get mutatingwebhookconfigurations,validatingwebhookconfigurations -o go-template=$K2S_WA_RULES_TEMPLATE" \
        "$cached --request-timeout=30s get service $K2S_WA_SERVICE -n $K2S_WA_NAMESPACE --ignore-not-found -o go-template=$K2S_WA_SERVICE_TEMPLATE" \
        "$cached --request-timeout=30s get endpointslices -n $K2S_WA_NAMESPACE -l kubernetes.io/service-name=$K2S_WA_SERVICE -o go-template=$K2S_WA_ENDPOINTS_TEMPLATE" \
        "$cached get --raw=/metrics --request-timeout=30s" \
        "$cached --request-timeout=30s create --dry-run=server -f - -o "'go-template=clusterIP={{.spec.clusterIP}}{{"\n"}}' | LC_ALL=C sort -u)
    [[ "$actual" == "$expected" ]] && return 0
    printf 'kubectl commands differ (recorded only, then expected only with a tab; admin kubeconfig: %s):\n' "$admin"
    LC_ALL=C comm -3 <(printf '%s\n' "$actual") <(printf '%s\n' "$expected") | cut -c1-200
    return 1
}
kuberc_case
verify_reset
run_with kuberc_env ensure-apiserver
expect_rc 0 'kuberc in HOME: ensure-apiserver succeeds before verify'
run_with kuberc_env publish
expect_rc 0 'kuberc in HOME: publish succeeds before verify'
rm -f -- "$CASE_DIR/kubectl-shim.log"
run_with kuberc_env verify
expect_verify 0 ok 'kuberc in HOME: verify succeeds'
check 'kuberc in HOME: every verify kubectl command runs with KUBERC=off' kubectl_calls_use_kuberc_off
check 'kuberc in HOME: verify only reads and sends a server-side dry-run' verify_kubectl_calls_are
check 'kuberc in HOME: the dry-run is the probe Service' [ "$(<"$CASE_DIR/kubectl-shim-configmap.yaml.dry-run")" = "$PROBE_SERVICE" ]
rm -f -- "$CASE_DIR/kubectl-shim.log"
run_with kuberc_env renew --force
expect_rc 0 'kuberc in HOME: renew --force succeeds'
check 'kuberc in HOME: renew prints its success marker last' marker_is renew
check 'kuberc in HOME: every renew kubectl command runs with KUBERC=off' kubectl_calls_use_kuberc_off
check 'kuberc in HOME: renew only reads and sends server-side dry-runs' verify_kubectl_calls_are
SHIM_KUBERC="$CASE_DIR/kuberc-malformed"
rm -f -- "$CASE_DIR/kubectl-shim.log"
run_with kuberc_env verify
expect_verify 0 ok 'malformed kuberc in KUBERC: verify succeeds'
check 'malformed kuberc in KUBERC: every verify kubectl command runs with KUBERC=off' kubectl_calls_use_kuberc_off
SHIM_KUBERC=''

# --- verification: private kubectl cache, nothing below HOME changes, every kubectl request is time-limited ---
# The shim (above) rejects a cluster call without exactly one --request-timeout and records each cache directory.
private_tmp_env() { kuberc_env; mkdir -p -- "$CASE_DIR/tmp"; export TMPDIR="$CASE_DIR/tmp" SHIM_SIGNAL_PID="$BASHPID"; }
home_state() { find "$CASE_DIR/home" -printf '%p %y %s %T@ %m\n' | LC_ALL=C sort; }
tmp_is_empty() { [[ -d "$CASE_DIR/tmp" && -z "$(ls -A -- "$CASE_DIR/tmp")" ]]; }
# Every cluster call ran with an existing cache directory in TMPDIR; $1 distinct directories, none of them remains.
cache_dirs_ok() {
    local dirs dir n re="^$CASE_DIR/tmp/k2s-webhook-auth-kubectl-cache\.[A-Za-z0-9]{8}$"
    [[ -s "$CASE_DIR/kubectl-shim.log.cache" ]] || { printf 'no cache directory recorded\n'; return 1; }
    if grep -q ' absent$' "$CASE_DIR/kubectl-shim.log.cache"; then printf 'a cache directory did not exist during a call\n'; return 1; fi
    dirs=$(cut -d' ' -f1 "$CASE_DIR/kubectl-shim.log.cache" | LC_ALL=C sort -u)
    n=$(printf '%s\n' "$dirs" | wc -l)
    [[ "$n" == "$1" ]] || { printf '%s cache directories, expected %s\n' "$n" "$1"; return 1; }
    while IFS= read -r dir; do
        [[ "$dir" =~ $re ]] || { printf 'unexpected cache directory %s\n' "$dir"; return 1; }
        [[ ! -e "$dir" ]] || { printf 'cache directory %s remains\n' "$dir"; return 1; }
    done <<< "$dirs"
}
# Every cluster call carries one timeout: the explicit ones of /readyz (5s) and /metrics (30s), otherwise the default.
cluster_call_timeouts_ok() {
    local line args
    while IFS= read -r line; do
        args="${line#*|*|}"
        [[ " $args " != *' --local '* ]] || continue
        case " $args " in
            *' get --raw=/readyz --request-timeout=5s ') [[ "$args" != *'--request-timeout=30s'* ]] || { printf 'two timeouts: %s\n' "$args"; return 1; } ;;
            *' get --raw=/metrics --request-timeout=30s ') [[ "$args" != *' --request-timeout=30s get '* ]] || { printf 'two timeouts: %s\n' "$args"; return 1; } ;;
            *" --request-timeout=$K2S_WA_REQUEST_TIMEOUT "*) ;;
            *) printf 'no default timeout: %s\n' "${args:0:160}"; return 1 ;;
        esac
    done < "$CASE_DIR/kubectl-shim.log"
}
reset_shim_logs() { rm -f -- "$CASE_DIR/kubectl-shim.log" "$CASE_DIR/kubectl-shim.log.cache"; }
kuberc_case
verify_reset
run_with kuberc_env ensure-apiserver
expect_rc 0 'private kubectl cache: ensure-apiserver succeeds before verify'
run_with kuberc_env publish
expect_rc 0 'private kubectl cache: publish succeeds before verify'
check 'ensure-apiserver and publish: every request to kube-apiserver carries one timeout' cluster_call_timeouts_ok
mkdir -p -- "$CASE_DIR/home/.kube/cache/discovery"
printf 'existing cache entry\n' > "$CASE_DIR/home/.kube/cache/discovery/entry"
home_before=$(home_state)
reset_shim_logs
run_with private_tmp_env verify
expect_verify 0 ok 'private kubectl cache: verify succeeds'
check 'verify: every kubectl call to kube-apiserver uses one private cache directory in TMPDIR, which is removed afterwards' cache_dirs_ok 1
check 'verify: every request to kube-apiserver carries one timeout; the explicit ones of /readyz and /metrics are kept' cluster_call_timeouts_ok
check 'verify: TMPDIR is empty afterwards' tmp_is_empty
check 'verify: HOME and its existing kubectl cache are unchanged' [ "$(home_state)" = "$home_before" ]
check 'verify: only reads and sends a server-side dry-run, each with the private cache and a timeout' verify_kubectl_calls_are
reset_shim_logs
run_with private_tmp_env renew --force
expect_rc 0 'private kubectl cache: renew --force succeeds'
check 'renew --force: its two verifications each use their own private cache directory, both removed' cache_dirs_ok 2
check 'renew --force: TMPDIR is empty afterwards' tmp_is_empty
check 'renew --force: HOME and its existing kubectl cache are unchanged' [ "$(home_state)" = "$home_before" ]
# A request that times out fails the verification with the category of the failed step; the cache is removed anyway.
while IFS='|' read -r call result message; do
    reset_shim_logs
    SHIM_TIMEOUT="$call"
    run_with private_tmp_env verify
    expect_verify 1 "$result" "a timed-out '$call' request fails verify"
    check "timed-out '$call': reports '$message'" output_has "$message"
    check "timed-out '$call': the kubectl timeout is reported" output_has 'Client.Timeout exceeded while awaiting headers'
    check "timed-out '$call': the private cache directory is removed" cache_dirs_ok 1
    check "timed-out '$call': TMPDIR is empty afterwards" tmp_is_empty
done <<'EOF'
configmap|apiserver-unavailable|cannot read ConfigMap k2s-webhook/clusterip-webhook-client-ca
endpointslices|apiserver-unavailable|cannot read the endpoints of Service k2s-webhook/clusterip-webhook
create|admission-failed|the dry-run Service was refused: Unable to connect to the server
--raw=/metrics|inconclusive|cannot read the admission metrics of kube-apiserver
EOF
SHIM_TIMEOUT=''
check 'verify with a timed-out request leaves HOME unchanged' [ "$(home_state)" = "$home_before" ]
reset_shim_logs
SHIM_SIGNAL_ON=endpointslices
run_with private_tmp_env verify
SHIM_SIGNAL_ON=''
expect_rc 143 'verify ends with exit status 143 when it receives SIGTERM'
check 'verify interrupted by SIGTERM: no result line and no success marker' not output_has 'K2S-WEBHOOK-AUTH-'
check 'verify interrupted by SIGTERM: the private cache directory is removed' cache_dirs_ok 1
check 'verify interrupted by SIGTERM: TMPDIR is empty afterwards' tmp_is_empty
# Without a private cache directory (TMPDIR cannot hold one), verify is inconclusive before any request is sent.
no_tmp_env() { kuberc_env; export TMPDIR="$CASE_DIR/no-such-directory"; }
reset_shim_logs
run_with no_tmp_env verify
expect_verify 1 inconclusive 'verify without a private kubectl cache directory is inconclusive'
check 'verify without a private kubectl cache directory: reported' output_has 'cannot create a private kubectl cache directory'
check 'verify without a private kubectl cache directory: no kubectl command runs' [ ! -e "$CASE_DIR/kubectl-shim.log" ]
check 'verify without a private kubectl cache directory: HOME is unchanged' [ "$(home_state)" = "$home_before" ]
# verify installs its signal handlers only for its own duration and restores the dispositions on every path.
traps_after_verify() {
    local setup="$1" out before
    before=$(trap -p INT TERM QUIT)
    out=$( { "$setup" && main verify; trap -p INT TERM QUIT; } < /dev/null 2>/dev/null ) || :
    [[ "$out" == *K2S-WEBHOOK-AUTH-VERIFY:* ]] || { printf 'verify did not return its result\n'; return 1; }
    [[ "$(grep '^trap ' <<< "$out")" == "$before" ]] && return 0
    printf 'handlers before: %s\nhandlers after: %s\n' "$before" "$(grep '^trap ' <<< "$out")"
    return 1
}
check 'verify restores the SIGINT, SIGTERM and SIGQUIT dispositions after success' traps_after_verify private_tmp_env
check 'verify restores the SIGINT, SIGTERM and SIGQUIT dispositions without a private cache directory' traps_after_verify no_tmp_env
SHIM_TIMEOUT=configmap
check 'verify restores the SIGINT, SIGTERM and SIGQUIT dispositions after a failure' traps_after_verify private_tmp_env
SHIM_TIMEOUT=''
check 'verify leaves no private cache directory after these runs' tmp_is_empty
# The wrapper adds the default timeout unless the call sets its own, in either form, and adds the cache directory only
# while a verification runs.
wrapper_call_is() {
    local expected="$1" cache="$2" actual
    shift 2
    reset_shim_logs
    (kuberc_env; K2S_WA_KUBECTL_CACHE="$cache"; real_k2s_wa_kubectl "$@") > /dev/null 2>&1 || { printf 'the kubectl command failed\n'; return 1; }
    actual=$(cut -d'|' -f3- "$CASE_DIR/kubectl-shim.log")
    [[ "$actual" == "$expected" ]] && return 0
    printf 'kubectl %s\nexpected kubectl %s\n' "$actual" "$expected"
    return 1
}
wrapper_admin="--kubeconfig $K2S_WA_ADMIN_KUBECONFIG"
mkdir -p -- "$CASE_DIR/cache"
check 'kubectl wrapper: a request without its own timeout gets the default timeout' \
    wrapper_call_is "$wrapper_admin --request-timeout=30s get --raw=/readyz" '' get --raw=/readyz
check 'kubectl wrapper: a request with --request-timeout=<value> keeps only its own timeout' \
    wrapper_call_is "$wrapper_admin get --raw=/readyz --request-timeout=7s" '' get --raw=/readyz --request-timeout=7s
check 'kubectl wrapper: a request with --request-timeout <value> keeps only its own timeout' \
    wrapper_call_is "$wrapper_admin get --raw=/readyz --request-timeout 7s" '' get --raw=/readyz --request-timeout 7s
check 'kubectl wrapper: during a verification the private cache directory is passed with the default timeout' \
    wrapper_call_is "$wrapper_admin --cache-dir $CASE_DIR/cache --request-timeout=30s get --raw=/readyz" "$CASE_DIR/cache" get --raw=/readyz
SHIM_TIMEOUT=--raw=/readyz
RC=0
OUTPUT=$( (kuberc_env; real_k2s_wa_kubectl get --raw=/readyz) 2>&1) || RC=$?
SHIM_TIMEOUT=''
expect_rc 1 'kubectl wrapper: a request that times out fails'
check 'kubectl wrapper: the timeout reported by kubectl is passed on' output_has 'Client.Timeout exceeded while awaiting headers'

# --- lock and root ---
provisioned_case
exec {held}>"$K2S_WA_LOCK_FILE"
flock -n "$held"
K2S_WA_LOCK_TIMEOUT=1
run provision
expect_rc 1 'a second run fails while another run holds the lock'
check 'the held lock is reported' output_has 'another clusterip-webhook-auth.sh run holds the lock'
check 'no success marker while the lock is held' no_marker
exec {held}>&-
run provision
expect_rc 0 'provision runs after the lock is released'
if (( EUID != 0 )); then
    RC=0
    OUTPUT=$(real_k2s_wa_require_root) || RC=$?
    expect_rc 4 'a non-root user is refused'
    check 'the refusal is reported' output_has 'must run as root'
    # Safe: the root check runs before anything below /etc/kubernetes is created or read.
    RC=0
    OUTPUT=$(bash "$SCRIPT" provision 2>&1) || RC=$?
    expect_rc 4 'running the script as a non-root user is refused'
    check 'running the script as a non-root user reports it' output_has 'must run as root'
    check 'running the script as a non-root user prints no success marker' no_marker
else
    printf 'SKIP: non-root refusal (the tests run as root)\n'
fi

# --- contract fixtures: the output of the script as the PowerShell helper reads it from run.log ---
# test/clusterip-webhook-auth.output.txt holds the output (stdout and stderr) of the scenarios below, with the test root
# replaced by /etc/kubernetes and the random parts of temporary names by X. clusterip-webhook-auth.module.unit.tests.ps1
# classifies these logs (manifest replacement, renewal, warnings, exit status, success marker). The test fails when the
# output differs from the file; K2S_WA_WRITE_FIXTURES=1 rewrites the file. Only scenarios whose output does not depend
# on the versions of kubectl and OpenSSL are recorded.
FIXTURE_FILE="$REPO_ROOT/test/clusterip-webhook-auth.output.txt"
FIXTURES="$TEST_DIR/fixtures.txt"
cat > "$FIXTURES" <<'EOF'
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Output (stdout and stderr, as in run.log on the node) of clusterip-webhook-auth.sh in scenarios of
# test/clusterip-webhook-auth.sh, which fails when the output of the script differs from this file. Each section starts
# with "=== <scenario> exit=<exit status>". The test root is replaced by /etc/kubernetes and the random parts of temporary
# names by X; lines starting with "injected" stand for the error output of a failing tool (sync, chown, openssl).
# Regenerate with: K2S_WA_WRITE_FIXTURES=1 bash test/clusterip-webhook-auth.sh
EOF
fixture() {
    local root=/etc/kubernetes text
    text="${OUTPUT//"$K2S_WA_ROOT"/$root}"
    if [[ "$text" == '=== '* || "$text" == *$'\n=== '* ]]; then fail "fixture $1: a line starts with ==="; fi
    {
        printf '=== %s exit=%s\n' "$1" "$RC"
        if [[ -n "$text" ]]; then
            printf '%s\n' "$text" | sed -E -e 's/\.tmp\.[A-Za-z0-9]{6}/.tmp.XXXXXX/g' -e 's/\.k2s-webhook-auth\.[A-Za-z0-9]{6}/.k2s-webhook-auth.XXXXXX/g'
        fi
    } >> "$FIXTURES"
}
# fixture_case <scenario> <expected exit status>: records the output of the last run.
fixture_case() {
    expect_rc "$2" "fixture $1: exit status $2"
    fixture "$1"
}
backup_fails() { SYNC_FAIL="$K2S_WA_BACKUP_DIR"; failing_sync; }
manifest_dir_flush_fails() { SYNC_FAIL="$K2S_WA_MANIFEST_DIR"; failing_sync; }
missing_cert() { rm -f -- "$CRT"; }
manifest_case
run ensure-apiserver
fixture_case ensure-apiserver/configured 0
run ensure-apiserver
fixture_case ensure-apiserver/already-configured 0
APISERVER=down
run ensure-apiserver
fixture_case ensure-apiserver/configured-not-ready 1
APISERVER=healthy
custom_manifest
run ensure-apiserver
fixture_case ensure-apiserver/custom 3
manifest_case
APISERVER=unready
run ensure-apiserver
fixture_case ensure-apiserver/not-ready-before-change 1
manifest_case
run_with flush_fails ensure-apiserver
fixture_case ensure-apiserver/credentials-not-flushed 1
manifest_case
run provision
run_with backup_fails ensure-apiserver
fixture_case ensure-apiserver/backup-failed 1
manifest_case
run_with fail_chown ensure-apiserver
fixture_case ensure-apiserver/replace-failed 1
manifest_case
run_with manifest_dir_flush_fails ensure-apiserver
fixture_case ensure-apiserver/configured-with-warning 0
manifest_case
APISERVER=flag-crashes
run ensure-apiserver
fixture_case ensure-apiserver/rolled-back 5
manifest_case
APISERVER=flag-breaks-cluster
run ensure-apiserver
fixture_case ensure-apiserver/recovery-unconfirmed 6
manifest_case
APISERVER=flag-crashes
run_with fail_restore ensure-apiserver
fixture_case ensure-apiserver/restore-failed 6
manifest_case
exec {held}>"$K2S_WA_LOCK_FILE"
flock -n "$held"
K2S_WA_LOCK_TIMEOUT=1
run ensure-apiserver
exec {held}>&-
fixture_case ensure-apiserver/locked 1
SYNC_FAIL=''
new_case
run provision
fixture_case provision 0
run publish
fixture_case publish 0
verify_case
run verify
fixture_case verify/ok 0
verify_case
TLS_NOCERT=answered
run verify
fixture_case verify/failed 1
renew_case
run renew
fixture_case renew/verified 0
renew_case
ADMISSION=fail-open
run renew
fixture_case renew/verify-failed 1
renew_case
run renew --force
fixture_case renew/forced 0
renew_case
near_expiry
run renew
fixture_case renew/renewed 0
renew_case
missing_cert
run renew
fixture_case renew/renewed-without-backup 0
renew_case
missing_cert
ADMISSION=fail-open
run renew
fixture_case renew/unverified-without-backup 1
renew_case
unavailable_webhook
run renew --force
fixture_case renew/current-certificate-not-working 1
renew_case
run_with fail_signing renew --force
fixture_case renew/signing-failed 1
renew_case
TLS_TRUSTED_SHA="$OLD_SHA" TLS_CERT=trusted-cert ADMISSION=trusted-cert
run renew --force
fixture_case renew/rolled-back 5
renew_case
ADMISSION='ok fail-open'
run renew --force
fixture_case renew/restore-unverified 6
renew_case
ADMISSION='ok fail-open'
run_with fail_restore_copy renew --force
fixture_case renew/restore-failed 6
renew_case
custom_manifest
run renew --force
fixture_case renew/custom 3
renew_case
exec {held}>"$K2S_WA_LOCK_FILE"
flock -n "$held"
K2S_WA_LOCK_TIMEOUT=1
run renew --force
exec {held}>&-
fixture_case renew/locked 1
verify_reset
check 'contract fixtures: no path of the test directory remains' not grep -q -F -- "$TEST_DIR" "$FIXTURES"
check 'contract fixtures: no trailing whitespace' not grep -q -E '[[:space:]]$' "$FIXTURES"
if [[ "${K2S_WA_WRITE_FIXTURES:-}" == 1 ]]; then
    cp -- "$FIXTURES" "$FIXTURE_FILE"
    printf 'wrote %s\n' "$FIXTURE_FILE"
fi
fixtures_match() {
    [[ -f "$FIXTURE_FILE" ]] || { printf '%s is missing\n' "$FIXTURE_FILE"; return 1; }
    cmp -s -- "$FIXTURES" "$FIXTURE_FILE" && return 0
    diff -u -- "$FIXTURE_FILE" "$FIXTURES" | head -n 80
    return 1
}
check 'contract fixtures: the output of the script equals test/clusterip-webhook-auth.output.txt' fixtures_match

printf 'Passed=%s Failed=%s (clusterip-webhook-auth.sh; mocked cluster, kube-apiserver and /proc)\n' "$passed" "$failed"
(( failed == 0 )) || exit 1
