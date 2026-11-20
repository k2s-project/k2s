#!/bin/bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# Hermetic tests for clusterip-webhook-auth.sh. Every root directory is below a temporary directory; cluster
# access (k2s_wa_kubectl), kube-apiserver process states and sleep are mocked; openssl and kubectl --local are
# real. Never runs sudo and never touches /etc/kubernetes or a cluster. Needs GNU userland (Linux or WSL).
# shellcheck disable=SC2317,SC2329 # setup functions and mocks are invoked indirectly (run_with, function overrides)
set -euo pipefail
exec 2>&1
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/lib/modules/windows/node/k2s.node.module/linuxnode/distros/scripts/clusterip-webhook-auth.sh"
MANIFESTS="$REPO_ROOT/lib/manifests/clusterip-webhook"
for tool in openssl kubectl flock find stat date comm sort sha256sum; do
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
# Simulated time: a full K2S_WA_WAIT_TIMEOUT elapses without waiting.
sleep() { SECONDS=$((SECONDS + ${1%%.*})); }
eval "real_$(declare -f k2s_wa_require_root)"
eval "real_$(declare -f k2s_wa_apiserver_process_states)"
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
        flag-crashes) if [[ "$configured" == flag ]]; then K2S_WA_PROC_STATES=''; else K2S_WA_PROC_STATES=noflag; fi ;;
        flag-breaks-cluster)
            if [[ "$configured" == flag ]]; then : > "$CASE_DIR/broken"; fi
            if [[ -e "$CASE_DIR/broken" ]]; then K2S_WA_PROC_STATES=''; else K2S_WA_PROC_STATES="$configured"; fi ;;
        *) printf 'unknown APISERVER mode %s\n' "$APISERVER"; return 1 ;;
    esac
}

# Cluster access. Every call is logged to $CASE_DIR/kubectl.log.
k2s_wa_kubectl() {
    printf '%s\n' "$*" >> "$CASE_DIR/kubectl.log"
    case "$1" in
        apply)
            [[ "$KUBECTL_APPLY" == ok ]] || { printf 'error: injected apply failure\n'; return 1; }
            cp -- "${!#}" "$CASE_DIR/applied.yaml" ;;
        get)
            if [[ "$2" == --raw=/readyz ]]; then
                case "$APISERVER" in unready | down) printf 'readyz check failed'; return 1 ;; esac
                printf '%s' "$READYZ_OUTPUT"
                return "$READYZ_RC"
            fi
            [[ "$2" == configmap && "$KUBECTL_GET" == ok ]] || { printf 'error: injected get failure\n'; return 1; }
            command -p cat -- "${SERVED:-$CASE_DIR/applied.yaml}" ;;
        *) printf 'unexpected kubectl call: %s\n' "$*"; return 1 ;;
    esac
}

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
for tool in cmp cp find flock grep mkdir mktemp mv rm sed chmod sort comm chown; do ln -s -- "$(command -v "$tool")" "$BIN/$tool"; done
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
for args in '' bogus 'provision extra'; do
    new_case
    # shellcheck disable=SC2086 # intentionally split into arguments
    run $args
    expect_rc 2 "arguments '$args' are rejected"
    check "arguments '$args': usage is printed" output_has 'provision|ensure-apiserver|publish'
    check "arguments '$args': nothing is created" listing_is "$K2S_WA_ROOT" 'manifests'
done
for args in '' bogus; do
    RC=0
    # shellcheck disable=SC2086 # intentionally split into arguments
    OUTPUT=$(bash "$SCRIPT" $args 2>&1) || RC=$?
    expect_rc 2 "running the script with arguments '$args' is rejected"
    check "running the script with arguments '$args' prints the usage" \
        [ "$OUTPUT" = 'Usage: clusterip-webhook-auth.sh provision|ensure-apiserver|publish' ]
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

printf 'Passed=%s Failed=%s (clusterip-webhook-auth.sh; mocked cluster, kube-apiserver and /proc)\n' "$passed" "$failed"
(( failed == 0 )) || exit 1
