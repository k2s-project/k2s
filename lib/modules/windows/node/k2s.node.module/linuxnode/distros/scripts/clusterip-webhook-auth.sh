#!/bin/bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Provisions the credentials with which kube-apiserver authenticates to the clusterip-webhook
# admission endpoints (mutual TLS). Runs as root on the control-plane node.
#
# Trust directions:
#   kube-apiserver verifies the webhook: serving certificate created by the webhook's init-cert
#     container and trusted through the caBundle of the MutatingWebhookConfiguration. Not handled here.
#   The webhook verifies kube-apiserver: client certificate issued by a dedicated client CA (this
#     script). The CA key stays in /etc/kubernetes/k2s-webhook-auth-ca on this node and is never mounted
#     or published. Only ca.crt is published to the ConfigMap k2s-webhook/clusterip-webhook-client-ca,
#     which the webhook loads with --client-ca-file.
#
# kube-apiserver selects the client certificate per webhook: --admission-control-config-file points to
# an AdmissionConfiguration whose MutatingAdmissionWebhook kubeConfigFile contains exactly one user,
# named after the webhook Service host and port (clusterip-webhook.k2s-webhook.svc:443), and neither a
# wildcard user nor a current-context, so no other webhook receives the certificate.
#
# Commands:
#   provision         Create or validate the CA, client certificate and key, kubeconfig,
#                     AdmissionConfiguration and kubeadm patch. Needs no cluster access.
#   ensure-apiserver  provision, then add the configuration to the kube-apiserver static Pod manifest:
#                     backup outside the manifests directory, atomic replacement, bounded readiness wait
#                     and automatic restore of the previous manifest on failure.
#   publish           Publish ca.crt to the ConfigMap and verify the published content.
#   verify            Read-only functional check of the authentication (see below).
#   renew [--force]   Reissue the client certificate with the existing CA and key when it expires within 30
#                     days, or always with --force. Without --force a certificate valid for longer is not renewed
#                     (certificate, key and backup stay untouched) but verified; the verification decides the
#                     result. Before a renewal, a usable certificate is verified and kept as
#                     k2s-webhook-auth-backup/client.crt. One atomic rename installs the new certificate.
#                     kube-apiserver is not restarted, even if the old certificate had expired: it reads the
#                     file again for new TLS connections (client-go reloads it per handshake, cached for one
#                     second, and closes its connections when the certificate changes, checked every five
#                     minutes). If verification then fails, the backup is restored and verified.
#
# verify creates and changes no files and no Kubernetes objects; kubectl caches in a private temporary directory that
# is removed afterwards. It checks the local credentials and rendered files, the kube-apiserver manifest and processes,
# the published CA, the MutatingWebhookConfiguration and the webhook Deployment. Then it connects from this node to the
# webhook Service and each ready endpoint: without a client certificate the TLS handshake must be refused, with the
# client certificate a request must be answered.
# Finally it creates a selector-less Service with server-side dry-run (never a workload, whose dry-run updates
# the webhook's OS cache): the webhook must assign a clusterIP from its Linux range, and the kube-apiserver
# admission metrics of the webhook must show successful calls only, so a call that failed open because of
# failurePolicy Ignore is detected. The webhook does not record dry-run allocations, and no admission webhook
# matching Services may declare side effects other than None or NoneOnDryRun. The last line is
# K2S-WEBHOOK-AUTH-VERIFY:<result>, followed by K2S-WEBHOOK-AUTH-OK:verify on success. Results:
#   ok                        authentication and admission work
#   ca-invalid                client CA missing, invalid or expired
#   client-cert-expired       client certificate expired (run renew)
#   client-cert-invalid       client certificate or key missing or invalid
#   admission-config-invalid  kubeconfig, AdmissionConfiguration, kubeadm patch or credential directory differ
#   apiserver-not-configured  manifest or running kube-apiserver lacks the admission configuration
#   apiserver-unavailable     kube-apiserver not running, not ready or not answering
#   ca-mismatch               ConfigMap missing or not the local client CA certificate
#   webhook-config-invalid    MutatingWebhookConfiguration or webhook arguments unexpected
#   unsafe-side-effects       another webhook matching Services declares side effects; no dry-run sent
#   webhook-unavailable       no ready endpoint, or connections fail or time out
#   webhook-tls-untrusted     serving certificate not trusted through the caBundle
#   unauthenticated-accepted  the webhook answered a client without certificate
#   client-cert-rejected      the webhook refused the client certificate
#   admission-not-called      kube-apiserver did not call the webhook
#   admission-fail-open       the call failed and kube-apiserver admitted the Service without the webhook
#   admission-failed          the call or the dry-run failed, or no clusterIP from the range was assigned
#   inconclusive              unexpected TLS result or ambiguous metrics (e.g. concurrent admissions)
# Connection failures and timeouts never count as a refused handshake. Unavoidable effects of verify: the webhook logs
# each check without a certificate as a TLS handshake error; kube-apiserver counts the dry-run call in its admission
# metrics and, if auditing is enabled, records the read requests and the dry-run create as audit events. Every kubectl
# request to kube-apiserver is limited to K2S_WA_REQUEST_TIMEOUT (30 s) unless the call sets a shorter limit.
#
# Exit codes: 0 success, 1 failure, 2 usage, 3 conflict (nothing changed), 4 missing prerequisite,
# 5 previous manifest restored and kube-apiserver recovered, 6 kube-apiserver recovery not verified.
# For renew: 5 previous client certificate restored and verified, 6 restore or its verification failed.
# Only on success the last line printed is K2S-WEBHOOK-AUTH-OK:<command>.
#
# Durability: backups and staged files are flushed with sync before an atomic rename replaces a file, and the
# directory is flushed after it; a failed flush after the rename or during a restore is only reported (as WARNING).
# provision ends by checking owner and mode of the CA, credential and patch files and flushing them and their
# directories, so ensure-apiserver replaces the manifest only when everything it references is on disk; a failed
# check or flush ends the run before the manifest is changed.
#
# Interruptions: SIGHUP and SIGPIPE are ignored for the whole run. If the output is lost (closed terminal or
# SSH session), the run stops without changing the manifest at the latest when the backup is reported, just
# before the manifest is replaced; afterwards, write errors are ignored. SIGINT, SIGTERM and SIGQUIT are
# ignored from just before the manifest is replaced until kube-apiserver is ready with it, or the previous
# manifest is restored and the recovery wait has ended (at most about twice K2S_WA_WAIT_TIMEOUT); then they
# are reset. Commands started meanwhile inherit this, except that kubectl still exits on SIGTERM or SIGQUIT,
# which only fails one readiness check. SIGKILL (also sent by service and session managers after an ignored
# SIGTERM), the OOM killer, a failure to start a command (process or memory exhaustion makes Bash abandon the
# run), or a crash or power loss of the node can still end the run after the replacement.
# A rerun never restores the previous manifest; if kube-apiserver does not start, restore it manually:
#   cp -p /etc/kubernetes/k2s-webhook-auth-backup/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml
set -euo pipefail

K2S_WA_SERVICE_HOST='clusterip-webhook.k2s-webhook.svc'
K2S_WA_SERVICE_PORT='443'
K2S_WA_CREDENTIAL_NAME="$K2S_WA_SERVICE_HOST:$K2S_WA_SERVICE_PORT"
K2S_WA_NAMESPACE='k2s-webhook'
K2S_WA_CONFIGMAP='clusterip-webhook-client-ca'
K2S_WA_FIELD_MANAGER='k2s-clusterip-webhook-auth'
# Path of the credential directory inside the kube-apiserver container (mounted read-only).
K2S_WA_POD_DIR='/etc/kubernetes/k2s-webhook-auth'
K2S_WA_FLAG="--admission-control-config-file=$K2S_WA_POD_DIR/admission-config.yaml"
K2S_WA_VOLUME='k2s-webhook-auth'
K2S_WA_CA_DAYS=3650
K2S_WA_CERT_DAYS=365
K2S_WA_RENEW_MARGIN=$((30 * 86400))
# The CA must outlive every client certificate it issues.
K2S_WA_CA_MARGIN=$(((K2S_WA_CERT_DAYS + 30) * 86400))
K2S_WA_WAIT_TIMEOUT=300
K2S_WA_WAIT_INTERVAL=2
K2S_WA_READY_STREAK=3
K2S_WA_LOCK_TIMEOUT=300
# Client-side limit of every kubectl request to kube-apiserver that has no explicit --request-timeout. The admission
# webhook itself is limited to 10 s (timeoutSeconds), so a dry-run that calls it ends well within this limit.
K2S_WA_REQUEST_TIMEOUT='30s'
# Private kubectl cache directory of a verification (see k2s_wa_verify); empty outside of it.
K2S_WA_KUBECTL_CACHE=''
K2S_WA_PROC_DIR='/proc'
K2S_WA_REASON=''
K2S_WA_STATE=''
K2S_WA_PROC_STATES=''
# One line per container argument, volume mount and volume of a static Pod manifest.
# shellcheck disable=SC2016 # Go template variables, not shell expansions
K2S_WA_STATE_TEMPLATE='{{range .spec.containers}}{{$c := .name}}{{range .command}}C|{{$c}}|{{.}}{{"\n"}}{{end}}{{range .args}}A|{{$c}}|{{.}}{{"\n"}}{{end}}{{range .volumeMounts}}M|{{$c}}|{{.name}}|{{.mountPath}}|{{.readOnly}}{{"\n"}}{{end}}{{end}}{{range .spec.volumes}}V|{{.name}}|{{with .hostPath}}{{.path}}|{{.type}}{{end}}{{"\n"}}{{end}}'
# shellcheck disable=SC2016 # Go template variables, not shell expansions
K2S_WA_CONFIGMAP_TEMPLATE='{{.kind}}|{{.metadata.namespace}}|{{.metadata.name}}{{"\n"}}{{range $k, $v := .data}}data/{{$k}}{{"\n"}}{{end}}{{range $k, $v := .binaryData}}binaryData/{{$k}}{{"\n"}}{{end}}'
# --- verify ---
K2S_WA_WEBHOOK='clusterip.k2s.io'
K2S_WA_WEBHOOK_CONFIG='k2s-webhook'
K2S_WA_SERVICE='clusterip-webhook'
K2S_WA_DEPLOYMENT='clusterip-webhook'
K2S_WA_PROBE_NAMESPACE='default'
K2S_WA_PROBE_PATH='/k2s-webhook-auth-probe'
# Defaults of --linux-subnet and --reserved-ips in cmd/clusterip-webhook.
K2S_WA_DEFAULT_LINUX_SUBNET='172.21.0.0/24'
K2S_WA_DEFAULT_RESERVED_IPS=50
K2S_WA_VERIFY_TIMEOUT=120
K2S_WA_VERIFY_INTERVAL=5
K2S_WA_VERIFY_ATTEMPTS=3
K2S_WA_PROBE_TIMEOUT=10
K2S_WA_RELOAD_WAIT=2
K2S_WA_VERIFY_RESULT=''
K2S_WA_VERIFY_DETAIL=''
K2S_WA_PROBE=''
K2S_WA_SERVER_CA=''
K2S_WA_UNSAFE_WEBHOOKS=''
K2S_WA_IP_INT=0
K2S_WA_RANGE_START=0
K2S_WA_RANGE_END=0
K2S_WA_TARGETS=()
# One line per webhook: name, failurePolicy, Service namespace, name, path and port, URL, caBundle.
K2S_WA_WEBHOOKS_TEMPLATE='{{range .webhooks}}H|{{.name}}|{{with .failurePolicy}}{{.}}{{end}}|{{with .clientConfig}}{{with .service}}{{.namespace}}|{{.name}}|{{with .path}}{{.}}{{end}}|{{with .port}}{{.}}{{end}}{{else}}|||{{end}}|{{with .url}}{{.}}{{end}}|{{with .caBundle}}{{.}}{{end}}{{else}}|||||{{end}}{{"\n"}}{{end}}'
# One line per rule of all mutating and validating webhooks.
# shellcheck disable=SC2016 # Go template variables, not shell expansions
K2S_WA_RULES_TEMPLATE='{{range .items}}{{$c := .metadata.name}}{{range .webhooks}}{{$w := .name}}{{$s := .sideEffects}}{{range .rules}}W|{{$c}}|{{$w}}|{{$s}}|{{range .apiGroups}}[{{.}}]{{end}}|{{range .apiVersions}}[{{.}}]{{end}}|{{range .resources}}[{{.}}]{{end}}|{{range .operations}}[{{.}}]{{end}}{{"\n"}}{{end}}{{end}}{{end}}'
K2S_WA_SERVICE_TEMPLATE='{{.spec.clusterIP}}|{{range .spec.ports}}{{if eq .name "https"}}{{.port}}{{end}}{{end}}'
# Addresses of ready endpoints (ready unset counts as ready) with the https port.
# shellcheck disable=SC2016 # Go template variables, not shell expansions
K2S_WA_ENDPOINTS_TEMPLATE='{{range .items}}{{$port := 0}}{{range .ports}}{{if eq .name "https"}}{{$port = .port}}{{end}}{{end}}{{range .endpoints}}{{$ready := true}}{{with .conditions}}{{if eq (printf "%v" .ready) "false"}}{{$ready = false}}{{end}}{{end}}{{if $ready}}{{range .addresses}}E|{{.}}|{{$port}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}'
K2S_WA_ARGS_TEMPLATE='{{range .spec.template.spec.containers}}{{if eq .name "webhook"}}C|{{"\n"}}{{range .command}}A|{{.}}{{"\n"}}{{end}}{{range .args}}A|{{.}}{{"\n"}}{{end}}{{end}}{{end}}'
# Prints the admission metrics of the webhook from the kube-apiserver metrics (Prometheus text format) as
# "T code operation rejected type value", "F type value" and "J error_type operation rejection_code type value".
# Fails unless the input contains kube-apiserver metrics.
# shellcheck disable=SC2016 # awk program, not shell expansions
K2S_WA_METRICS_AWK='
function label(s, k,    i, r) {
    i = index(s, "," k "=\"")
    if (i == 0) return "-"
    r = substr(s, i + length(k) + 3)
    i = index(r, "\"")
    if (i <= 1) return "-"
    return substr(r, 1, i - 1)
}
/^# TYPE apiserver_/ { valid = 1 }
/^#/ { next }
{
    i = index($0, "{")
    if (i == 0) next
    metric = substr($0, 1, i - 1)
    if (metric == "apiserver_admission_webhook_request_total") kind = "T"
    else if (metric == "apiserver_admission_webhook_fail_open_count") kind = "F"
    else if (metric == "apiserver_admission_webhook_rejection_count") kind = "J"
    else next
    rest = substr($0, i + 1)
    j = index(rest, "} ")
    if (j == 0) next
    labels = "," substr(rest, 1, j - 1)
    if (split(substr(rest, j + 2), v, " ") < 1 || label(labels, "name") != webhook) next
    if (kind == "T") print "T", label(labels, "code"), label(labels, "operation"), label(labels, "rejected"), label(labels, "type"), v[1]
    else if (kind == "F") print "F", label(labels, "type"), v[1]
    else print "J", label(labels, "error_type"), label(labels, "operation"), label(labels, "rejection_code"), label(labels, "type"), v[1]
}
END { if (!valid) exit 1 }'
# Reads two outputs of K2S_WA_METRICS_AWK separated by a line "--" and prints the increase of all calls, of
# successful calls (code 200, not rejected), of fail-open calls and of rejections, and 1 if a counter
# decreased or disappeared (kube-apiserver restarted), else 0.
# shellcheck disable=SC2016 # awk program, not shell expansions
K2S_WA_DELTA_AWK='
NF == 0 { next }
$0 == "--" { after = 1; next }
{
    k = $1
    for (i = 2; i < NF; i++) k = k " " $i
    if (after) a[k] = $NF; else b[k] = $NF
}
END {
    for (k in b) if (!(k in a)) reset = 1
    for (k in a) {
        d = a[k] - ((k in b) ? b[k] : 0)
        if (d < 0) { reset = 1; continue }
        split(k, f, " ")
        if (f[1] == "T") { calls += d; if (f[2] == "200" && f[4] == "false") good += d }
        else if (f[1] == "F") failopen += d
        else if (f[1] == "J") rejected += d
    }
    printf "%d %d %d %d %d\n", calls, good, failopen, rejected, reset
}'

k2s_wa_log() { printf '[ClusterIPWebhookAuth] %s\n' "$*"; }
k2s_wa_warn() { printf '[ClusterIPWebhookAuth] WARNING: %s\n' "$*"; }
k2s_wa_error() { printf '[ClusterIPWebhookAuth] ERROR: %s\n' "$*"; }
# Since v1.34 kubectl applies user preferences from ~/.kube/kuberc or $KUBERC by default; KUBERC=off keeps
# them from changing the commands of this script. Every request to kube-apiserver is time-limited: by
# K2S_WA_REQUEST_TIMEOUT unless the call sets --request-timeout itself. During a verification kubectl keeps its
# cache in the private directory K2S_WA_KUBECTL_CACHE instead of ~/.kube/cache.
k2s_wa_kubectl() {
    local arg
    local -a options=()
    if [[ -n "$K2S_WA_KUBECTL_CACHE" ]]; then options+=(--cache-dir "$K2S_WA_KUBECTL_CACHE"); fi
    options+=("--request-timeout=$K2S_WA_REQUEST_TIMEOUT")
    for arg in "$@"; do
        if [[ "$arg" == --request-timeout || "$arg" == --request-timeout=* ]]; then unset 'options[-1]'; break; fi
    done
    KUBERC=off kubectl --kubeconfig "$K2S_WA_ADMIN_KUBECONFIG" ${options[@]+"${options[@]}"} "$@"
}
k2s_wa_kubectl_local() { KUBERC=off KUBECONFIG=/dev/null kubectl "$@"; }
k2s_wa_usage() { printf 'Usage: %s provision|ensure-apiserver|publish|verify|renew [--force]\n' "${0##*/}"; }

k2s_wa_init_paths() {
    local root="${1:-/etc/kubernetes}" pattern='^(/[A-Za-z0-9._-]+)+$'
    if [[ ! "$root" =~ $pattern ]]; then
        k2s_wa_error "invalid root directory '$root'"
        return 2
    fi
    K2S_WA_ROOT="$root"
    K2S_WA_AUTH_DIR="$root/k2s-webhook-auth"
    K2S_WA_CA_DIR="$root/k2s-webhook-auth-ca"
    K2S_WA_PATCH_DIR="$root/k2s-kubeadm-patches"
    K2S_WA_PATCH_FILE="$K2S_WA_PATCH_DIR/kube-apiserver+json.json"
    K2S_WA_BACKUP_DIR="$root/k2s-webhook-auth-backup"
    K2S_WA_BACKUP_FILE="$K2S_WA_BACKUP_DIR/kube-apiserver.yaml"
    K2S_WA_CERT_BACKUP_FILE="$K2S_WA_BACKUP_DIR/client.crt"
    K2S_WA_MANIFEST_DIR="$root/manifests"
    K2S_WA_MANIFEST="$K2S_WA_MANIFEST_DIR/kube-apiserver.yaml"
    K2S_WA_ADMIN_KUBECONFIG="$root/admin.conf"
    K2S_WA_LOCK_FILE="$root/.k2s-webhook-auth.lock"
}

k2s_wa_require_root() {
    if (( EUID != 0 )); then
        k2s_wa_error 'must run as root'
        return 4
    fi
}

k2s_wa_require_tools() {
    local tool
    local -a missing=()
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if (( ${#missing[@]} > 0 )); then
        k2s_wa_error "missing required tools: ${missing[*]}"
        return 4
    fi
}

# --- certificate validation (failures set K2S_WA_REASON) ---

k2s_wa_is_single_cert() {
    local file="$1" line blocks=0 certificates=0
    [[ -f "$file" && -s "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            *'PRIVATE KEY'*) return 1 ;;
            '-----BEGIN CERTIFICATE-----') blocks=$((blocks + 1)); certificates=$((certificates + 1)) ;;
            '-----BEGIN '*) blocks=$((blocks + 1)) ;;
        esac
    done < "$file"
    (( blocks == 1 && certificates == 1 )) || return 1
    openssl x509 -in "$file" -noout >/dev/null 2>&1
}

k2s_wa_is_valid_key() {
    [[ -f "$1" && -s "$1" ]] && openssl pkey -in "$1" -passin pass: -noout >/dev/null 2>&1
}

k2s_wa_key_matches() {
    local certificate_key private_key
    certificate_key=$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null) || return 1
    private_key=$(openssl pkey -in "$2" -passin pass: -pubout 2>/dev/null) || return 1
    [[ -n "$certificate_key" && "$certificate_key" == "$private_key" ]]
}

k2s_wa_check_ca() {
    local dir="$1" margin="${2:-$K2S_WA_CA_MARGIN}" constraints out
    K2S_WA_REASON=''
    [[ -f "$dir/ca.crt" && -f "$dir/ca.key" ]] || { K2S_WA_REASON='ca.crt or ca.key is missing'; return 1; }
    k2s_wa_is_single_cert "$dir/ca.crt" || { K2S_WA_REASON='ca.crt is not a single PEM certificate'; return 1; }
    constraints=$(openssl x509 -in "$dir/ca.crt" -noout -ext basicConstraints 2>/dev/null) || constraints=''
    [[ "$constraints" == *'CA:TRUE'* ]] || { K2S_WA_REASON='ca.crt is not a CA certificate'; return 1; }
    if ! out=$(openssl verify -trusted "$dir/ca.crt" -check_ss_sig "$dir/ca.crt" 2>&1); then
        K2S_WA_REASON="ca.crt is not valid: ${out//$'\n'/ }"
        return 1
    fi
    if ! openssl x509 -in "$dir/ca.crt" -noout -checkend "$margin" >/dev/null 2>&1; then
        K2S_WA_REASON="ca.crt expires within $((margin / 86400)) days"
        return 1
    fi
    k2s_wa_is_valid_key "$dir/ca.key" || { K2S_WA_REASON='ca.key is not a valid unencrypted private key'; return 1; }
    k2s_wa_key_matches "$dir/ca.crt" "$dir/ca.key" || { K2S_WA_REASON='ca.key does not belong to ca.crt'; return 1; }
}

k2s_wa_check_client_cert() {
    local crt="$1" key="$2" ca="$3" margin="${4:-$K2S_WA_RENEW_MARGIN}" usage constraints out
    K2S_WA_REASON=''
    [[ -f "$crt" && -f "$key" ]] || { K2S_WA_REASON='client certificate or key is missing'; return 1; }
    k2s_wa_is_single_cert "$crt" || { K2S_WA_REASON='client certificate is not a single PEM certificate'; return 1; }
    if ! out=$(openssl verify -trusted "$ca" -purpose sslclient "$crt" 2>&1); then
        K2S_WA_REASON="client certificate is not valid for the client CA: ${out//$'\n'/ }"
        return 1
    fi
    usage=$(openssl x509 -in "$crt" -noout -ext extendedKeyUsage 2>/dev/null) || usage=''
    if [[ "$usage" != *'TLS Web Client Authentication'* ]]; then
        K2S_WA_REASON='client certificate lacks the clientAuth extended key usage'
        return 1
    fi
    constraints=$(openssl x509 -in "$crt" -noout -ext basicConstraints 2>/dev/null) || constraints=''
    [[ "$constraints" != *'CA:TRUE'* ]] || { K2S_WA_REASON='client certificate is a CA certificate'; return 1; }
    if ! openssl x509 -in "$crt" -noout -checkend "$margin" >/dev/null 2>&1; then
        K2S_WA_REASON="client certificate expires within $((margin / 86400)) days"
        return 1
    fi
    k2s_wa_is_valid_key "$key" || { K2S_WA_REASON='client key is not a valid unencrypted private key'; return 1; }
    if k2s_wa_key_matches "$ca" "$key"; then
        K2S_WA_REASON='client key is the client CA key'
        return 1
    fi
    k2s_wa_key_matches "$crt" "$key" || { K2S_WA_REASON='client key does not belong to the client certificate'; return 1; }
}

# --- generation ---

k2s_wa_generate_key() {
    local out
    if ! out=$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve \
        -out "$1" 2>&1); then
        K2S_WA_REASON="key generation failed: ${out//$'\n'/ }"
        return 1
    fi
}

k2s_wa_generate_ca() {
    local work="$1" out
    if ! printf '%s\n' '[req]' 'distinguished_name = dn' 'prompt = no' 'x509_extensions = v3_ca' \
        '[dn]' 'CN = k2s-clusterip-webhook-client-ca' \
        '[v3_ca]' 'basicConstraints = critical,CA:TRUE,pathlen:0' 'keyUsage = critical,keyCertSign,cRLSign' \
        'subjectKeyIdentifier = hash' > "$work/ca.cnf"; then
        K2S_WA_REASON='cannot write the CA configuration'
        return 1
    fi
    k2s_wa_generate_key "$work/ca.key" || return 1
    if ! out=$(openssl req -new -x509 -config "$work/ca.cnf" -key "$work/ca.key" -days "$K2S_WA_CA_DAYS" -sha256 \
        -out "$work/ca.crt" 2>&1); then
        K2S_WA_REASON="CA certificate generation failed: ${out//$'\n'/ }"
        return 1
    fi
    rm -f -- "$work/ca.cnf" || { K2S_WA_REASON='cannot remove the CA configuration'; return 1; }
}

k2s_wa_issue_client_cert() {
    local work="$1" key="$2" crt="$3" serial out
    if ! printf '%s\n' '[req]' 'distinguished_name = dn' 'prompt = no' \
        '[dn]' 'CN = k2s-kube-apiserver-clusterip-webhook-client' \
        '[v3_client]' 'basicConstraints = critical,CA:FALSE' 'keyUsage = critical,digitalSignature' \
        'extendedKeyUsage = clientAuth' 'subjectKeyIdentifier = hash' 'authorityKeyIdentifier = keyid:always' \
        > "$work/client.cnf"; then
        K2S_WA_REASON='cannot write the client certificate configuration'
        return 1
    fi
    serial=$(openssl rand -hex 16) || { K2S_WA_REASON='cannot generate a serial number'; return 1; }
    if ! out=$(openssl req -new -config "$work/client.cnf" -key "$key" -out "$work/client.csr" 2>&1); then
        K2S_WA_REASON="certificate request failed: ${out//$'\n'/ }"
        return 1
    fi
    if ! out=$(openssl x509 -req -in "$work/client.csr" -CA "$K2S_WA_CA_DIR/ca.crt" -CAkey "$K2S_WA_CA_DIR/ca.key" \
        -set_serial "0x$serial" -days "$K2S_WA_CERT_DAYS" -sha256 -extfile "$work/client.cnf" -extensions v3_client \
        -out "$crt" 2>&1); then
        K2S_WA_REASON="client certificate signing failed: ${out//$'\n'/ }"
        return 1
    fi
}

k2s_wa_ensure_ca() {
    local work
    if [[ -e "$K2S_WA_CA_DIR" || -L "$K2S_WA_CA_DIR" ]]; then
        if [[ -L "$K2S_WA_CA_DIR" || ! -d "$K2S_WA_CA_DIR" ]]; then
            k2s_wa_error "'$K2S_WA_CA_DIR' is not a directory"
            return 1
        fi
        if ! k2s_wa_check_ca "$K2S_WA_CA_DIR"; then
            k2s_wa_error "existing client CA in '$K2S_WA_CA_DIR' is not usable: $K2S_WA_REASON"
            k2s_wa_error "it is never replaced automatically. Restore it, or remove '$K2S_WA_CA_DIR' to create a new CA; a new CA must be published and the webhook restarted."
            return 1
        fi
        k2s_wa_log "reusing client CA '$K2S_WA_CA_DIR'"
        return 0
    fi
    if ! work=$(mktemp -d "$K2S_WA_ROOT/.k2s-webhook-auth-ca.tmp.XXXXXX"); then
        k2s_wa_error "cannot create a temporary directory in '$K2S_WA_ROOT'"
        return 1
    fi
    if ! k2s_wa_generate_ca "$work" || ! k2s_wa_check_ca "$work"; then
        k2s_wa_error "client CA generation failed: $K2S_WA_REASON"
        rm -rf -- "$work"
        return 1
    fi
    if ! chmod 0600 -- "$work/ca.key" || ! chmod 0644 -- "$work/ca.crt" || ! chmod 0700 -- "$work" ||
        ! mv -T -- "$work" "$K2S_WA_CA_DIR"; then
        k2s_wa_error "cannot install the client CA in '$K2S_WA_CA_DIR'"
        rm -rf -- "$work"
        return 1
    fi
    k2s_wa_log "created client CA '$K2S_WA_CA_DIR'"
}

k2s_wa_replace_client_cert() {
    local work="$1" crt="$K2S_WA_AUTH_DIR/client.crt" key="$K2S_WA_AUTH_DIR/client.key" ca="$K2S_WA_CA_DIR/ca.crt"
    local signing_key="$K2S_WA_AUTH_DIR/client.key" new_key='' new_crt
    # A usable key is kept, so renewal replaces only the certificate with one atomic rename
    # (kube-apiserver reads certificate and key separately).
    if ! k2s_wa_is_valid_key "$key" || k2s_wa_key_matches "$ca" "$key"; then
        new_key=$(mktemp "$K2S_WA_AUTH_DIR/.client.key.tmp.XXXXXX") || { K2S_WA_REASON='cannot create a temporary file'; return 1; }
        k2s_wa_generate_key "$new_key" || return 1
        signing_key="$new_key"
    fi
    new_crt=$(mktemp "$K2S_WA_AUTH_DIR/.client.crt.tmp.XXXXXX") || { K2S_WA_REASON='cannot create a temporary file'; return 1; }
    k2s_wa_issue_client_cert "$work" "$signing_key" "$new_crt" || return 1
    if ! k2s_wa_check_client_cert "$new_crt" "$signing_key" "$ca"; then
        K2S_WA_REASON="new certificate failed validation: $K2S_WA_REASON"
        return 1
    fi
    chmod 0644 -- "$new_crt" || { K2S_WA_REASON='cannot set the certificate permissions'; return 1; }
    if [[ -n "$new_key" ]]; then
        if ! chmod 0600 -- "$new_key" || ! mv -f -- "$new_key" "$key"; then
            K2S_WA_REASON='cannot install the client key'
            return 1
        fi
    fi
    mv -f -- "$new_crt" "$crt" || { K2S_WA_REASON='cannot install the client certificate'; return 1; }
}

k2s_wa_ensure_client_cert() {
    local crt="$K2S_WA_AUTH_DIR/client.crt" work rc=0
    if k2s_wa_check_client_cert "$crt" "$K2S_WA_AUTH_DIR/client.key" "$K2S_WA_CA_DIR/ca.crt"; then
        k2s_wa_log "reusing kube-apiserver client certificate '$crt'"
        return 0
    fi
    k2s_wa_log "issuing kube-apiserver client certificate: $K2S_WA_REASON"
    if ! work=$(mktemp -d "$K2S_WA_ROOT/.k2s-webhook-auth-issue.tmp.XXXXXX"); then
        k2s_wa_error "cannot create a temporary directory in '$K2S_WA_ROOT'"
        return 1
    fi
    k2s_wa_replace_client_cert "$work" || rc=$?
    rm -rf -- "$work" "$K2S_WA_AUTH_DIR"/.client.*.tmp.*
    if (( rc != 0 )); then
        k2s_wa_error "cannot issue the kube-apiserver client certificate: $K2S_WA_REASON"
        return 1
    fi
    k2s_wa_log "issued kube-apiserver client certificate '$crt'"
}

# Issues a new certificate for the existing key and installs it with one atomic rename, keeping the owner and
# mode of the current certificate. On failure client.crt is unchanged.
k2s_wa_renew_client_cert() {
    local work="$1" crt="$K2S_WA_AUTH_DIR/client.crt" key="$K2S_WA_AUTH_DIR/client.key" new_crt
    new_crt=$(mktemp "$K2S_WA_AUTH_DIR/.client.crt.tmp.XXXXXX") || { K2S_WA_REASON='cannot create a temporary file'; return 1; }
    k2s_wa_issue_client_cert "$work" "$key" "$new_crt" || return 1
    if ! k2s_wa_check_client_cert "$new_crt" "$key" "$K2S_WA_CA_DIR/ca.crt"; then
        K2S_WA_REASON="new certificate failed validation: $K2S_WA_REASON"
        return 1
    fi
    if [[ -f "$crt" ]]; then
        if ! chmod --reference="$crt" -- "$new_crt" || ! chown --reference="$crt" -- "$new_crt"; then
            K2S_WA_REASON='cannot copy the owner and mode of the current certificate'
            return 1
        fi
    elif ! chmod 0644 -- "$new_crt"; then
        K2S_WA_REASON='cannot set the certificate permissions'
        return 1
    fi
    sync -- "$new_crt" || { K2S_WA_REASON='cannot flush the new certificate to disk'; return 1; }
    mv -f -- "$new_crt" "$crt" || { K2S_WA_REASON='cannot install the client certificate'; return 1; }
    sync -- "$K2S_WA_AUTH_DIR" || k2s_wa_warn "cannot flush '$K2S_WA_AUTH_DIR' to disk"
}

k2s_wa_backup_client_cert() {
    local crt="$K2S_WA_AUTH_DIR/client.crt" tmp
    if ! mkdir -p -- "$K2S_WA_BACKUP_DIR" || ! chmod 0700 -- "$K2S_WA_BACKUP_DIR" ||
        ! tmp=$(mktemp "$K2S_WA_BACKUP_DIR/.client.crt.tmp.XXXXXX"); then
        k2s_wa_error "cannot prepare '$K2S_WA_BACKUP_DIR'"
        return 1
    fi
    if ! cp -p -- "$crt" "$tmp" || ! cmp -s -- "$crt" "$tmp" || ! sync -- "$tmp" ||
        ! mv -f -- "$tmp" "$K2S_WA_CERT_BACKUP_FILE" || ! sync -- "$K2S_WA_BACKUP_DIR"; then
        rm -f -- "$tmp"
        k2s_wa_error "cannot back up '$crt' to '$K2S_WA_CERT_BACKUP_FILE'"
        return 1
    fi
    k2s_wa_log "backed up '$crt' to '$K2S_WA_CERT_BACKUP_FILE'"
}

# A failed flush never stops the restore.
k2s_wa_restore_client_cert() {
    local crt="$K2S_WA_AUTH_DIR/client.crt" tmp
    tmp=$(mktemp "$K2S_WA_AUTH_DIR/.client.crt.tmp.XXXXXX") || return 1
    if ! cp -p -- "$K2S_WA_CERT_BACKUP_FILE" "$tmp" || ! cmp -s -- "$K2S_WA_CERT_BACKUP_FILE" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    sync -- "$tmp" || k2s_wa_warn "cannot flush '$tmp' to disk; restoring anyway"
    if ! mv -f -- "$tmp" "$crt"; then
        rm -f -- "$tmp"
        return 1
    fi
    sync -- "$K2S_WA_AUTH_DIR" || k2s_wa_warn "cannot flush '$K2S_WA_AUTH_DIR' to disk"
    cmp -s -- "$K2S_WA_CERT_BACKUP_FILE" "$crt"
}

# --- rendered files ---

k2s_wa_render_kubeconfig() {
    printf '%s\n' \
        '# Generated by clusterip-webhook-auth.sh. kube-apiserver presents this client certificate only to the' \
        '# clusterip-webhook Service: there is intentionally no wildcard user and no current-context.' \
        'apiVersion: v1' \
        'kind: Config' \
        'users:' \
        "- name: \"$K2S_WA_CREDENTIAL_NAME\"" \
        '  user:' \
        "    client-certificate: $K2S_WA_POD_DIR/client.crt" \
        "    client-key: $K2S_WA_POD_DIR/client.key"
}

k2s_wa_render_admission_config() {
    printf '%s\n' \
        '# Generated by clusterip-webhook-auth.sh.' \
        'apiVersion: apiserver.config.k8s.io/v1' \
        'kind: AdmissionConfiguration' \
        'plugins:' \
        '- name: MutatingAdmissionWebhook' \
        '  configuration:' \
        '    apiVersion: apiserver.config.k8s.io/v1' \
        '    kind: WebhookAdmissionConfiguration' \
        "    kubeConfigFile: $K2S_WA_POD_DIR/kubeconfig"
}

# kubeadm patch (also applied by ensure-apiserver) for the kube-apiserver static Pod manifest.
k2s_wa_render_patch() {
    printf '[\n'
    printf '  {"op": "test", "path": "/spec/containers/0/name", "value": "kube-apiserver"},\n'
    printf '  {"op": "add", "path": "/spec/containers/0/command/-", "value": "%s"},\n' "$K2S_WA_FLAG"
    printf '  {"op": "add", "path": "/spec/containers/0/volumeMounts/-", "value": {"name": "%s", "mountPath": "%s", "readOnly": true}},\n' \
        "$K2S_WA_VOLUME" "$K2S_WA_POD_DIR"
    printf '  {"op": "add", "path": "/spec/volumes/-", "value": {"name": "%s", "hostPath": {"path": "%s", "type": "Directory"}}}\n' \
        "$K2S_WA_VOLUME" "$K2S_WA_AUTH_DIR"
    printf ']\n'
}

k2s_wa_render_configmap() {
    printf '%s\n' \
        'apiVersion: v1' \
        'kind: ConfigMap' \
        'metadata:' \
        "  name: $K2S_WA_CONFIGMAP" \
        "  namespace: $K2S_WA_NAMESPACE" \
        '  labels:' \
        '    app.kubernetes.io/name: clusterip-webhook' \
        '    app.kubernetes.io/part-of: k2s' \
        'data:' \
        '  ca.crt: |' || return 1
    sed 's/^/    /' "$K2S_WA_CA_DIR/ca.crt"
}

# Writes the output of a render function to target; an unchanged file is left untouched.
k2s_wa_install_rendered() {
    local target="$1" mode="$2" render="$3" tmp
    if ! tmp=$(mktemp "${target%/*}/.${target##*/}.tmp.XXXXXX"); then
        k2s_wa_error "cannot create a temporary file for '$target'"
        return 1
    fi
    if ! "$render" > "$tmp" || ! chmod "$mode" -- "$tmp"; then
        rm -f -- "$tmp"
        k2s_wa_error "cannot render '$target'"
        return 1
    fi
    if [[ -f "$target" && ! -L "$target" ]] && cmp -s -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 0
    fi
    if ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        k2s_wa_error "cannot install '$target'"
        return 1
    fi
    k2s_wa_log "wrote '$target'"
}

k2s_wa_enforce_modes() {
    if ! chmod 0700 -- "$K2S_WA_CA_DIR" || ! chmod 0600 -- "$K2S_WA_CA_DIR/ca.key" ||
        ! chmod 0644 -- "$K2S_WA_CA_DIR/ca.crt" || ! chmod 0755 -- "$K2S_WA_AUTH_DIR" ||
        ! chmod 0600 -- "$K2S_WA_AUTH_DIR/client.key" "$K2S_WA_AUTH_DIR/kubeconfig" ||
        ! chmod 0644 -- "$K2S_WA_AUTH_DIR/client.crt" "$K2S_WA_AUTH_DIR/admission-config.yaml" ||
        ! chmod 0755 -- "$K2S_WA_PATCH_DIR" || ! chmod 0644 -- "$K2S_WA_PATCH_FILE"; then
        k2s_wa_error 'cannot set file permissions'
        return 1
    fi
}

# The credential directory is mounted into kube-apiserver; it must never contain the CA key.
k2s_wa_check_auth_dir() {
    local unexpected
    if ! unexpected=$(find "$K2S_WA_AUTH_DIR" -mindepth 1 -maxdepth 1 \( ! -type f -o \( ! -name client.crt \
        ! -name client.key ! -name kubeconfig ! -name admission-config.yaml \) \) -print); then
        k2s_wa_error "cannot inspect '$K2S_WA_AUTH_DIR'"
        return 1
    fi
    if [[ -n "$unexpected" ]]; then
        k2s_wa_error "unexpected entries in '$K2S_WA_AUTH_DIR', which is mounted into kube-apiserver: ${unexpected//$'\n'/ }"
        return 1
    fi
    if k2s_wa_key_matches "$K2S_WA_CA_DIR/ca.crt" "$K2S_WA_AUTH_DIR/client.key"; then
        k2s_wa_error "'$K2S_WA_AUTH_DIR/client.key' is the client CA key"
        return 1
    fi
}

k2s_wa_cleanup_stale() {
    if ! rm -rf -- "$K2S_WA_ROOT"/.k2s-webhook-auth-*.tmp.* "$K2S_WA_AUTH_DIR"/.*.tmp.* "$K2S_WA_PATCH_DIR"/.*.tmp.* \
        "$K2S_WA_BACKUP_DIR"/.*.tmp.* "$K2S_WA_MANIFEST_DIR"/.kube-apiserver.yaml.k2s-webhook-auth.*; then
        k2s_wa_error 'cannot remove temporary files of an interrupted run'
        return 1
    fi
}

# Makes the credentials durable before anything references them (see Durability in the header): kube-apiserver reads
# client.crt, client.key, the kubeconfig and the AdmissionConfiguration as soon as its manifest contains the flag, and
# the CA and the patch are needed for later renewals and kubeadm runs. Checks that every file and directory belongs to
# the user running the script with the mode set by k2s_wa_enforce_modes, then flushes them and the directories that
# contain them. Runs at the end of provision, so before ensure-apiserver changes the manifest; a failure stops it there.
k2s_wa_flush_credentials() {
    local entry path want got gid
    local -a paths=() entries=(
        "$K2S_WA_CA_DIR/ca.key|600" "$K2S_WA_CA_DIR/ca.crt|644" "$K2S_WA_AUTH_DIR/client.key|600"
        "$K2S_WA_AUTH_DIR/client.crt|644" "$K2S_WA_AUTH_DIR/kubeconfig|600" "$K2S_WA_AUTH_DIR/admission-config.yaml|644"
        "$K2S_WA_PATCH_FILE|644" "$K2S_WA_CA_DIR|700" "$K2S_WA_AUTH_DIR|755" "$K2S_WA_PATCH_DIR|755")
    if ! gid=$(id -g); then
        k2s_wa_error 'cannot determine the group of the current user'
        return 1
    fi
    for entry in "${entries[@]}"; do
        path="${entry%|*}"
        want="$EUID:$gid:${entry##*|}"
        if [[ -L "$path" ]] || ! got=$(stat -c '%u:%g:%a' -- "$path" 2>&1); then
            k2s_wa_error "cannot check the owner and mode of '$path'; the kube-apiserver manifest was not changed"
            return 1
        fi
        if [[ "$got" != "$want" ]]; then
            k2s_wa_error "'$path' has owner, group and mode $got instead of $want; the kube-apiserver manifest was not changed"
            return 1
        fi
        paths+=("$path")
    done
    if ! sync -- "${paths[@]}" "$K2S_WA_ROOT"; then
        k2s_wa_error 'cannot flush the credentials to disk; the kube-apiserver manifest was not changed'
        return 1
    fi
}

k2s_wa_provision() {
    k2s_wa_ensure_ca || return 1
    if ! mkdir -p -- "$K2S_WA_AUTH_DIR" "$K2S_WA_PATCH_DIR"; then
        k2s_wa_error "cannot create '$K2S_WA_AUTH_DIR' or '$K2S_WA_PATCH_DIR'"
        return 1
    fi
    k2s_wa_ensure_client_cert || return 1
    k2s_wa_install_rendered "$K2S_WA_AUTH_DIR/kubeconfig" 0600 k2s_wa_render_kubeconfig || return 1
    k2s_wa_install_rendered "$K2S_WA_AUTH_DIR/admission-config.yaml" 0644 k2s_wa_render_admission_config || return 1
    k2s_wa_install_rendered "$K2S_WA_PATCH_FILE" 0644 k2s_wa_render_patch || return 1
    k2s_wa_enforce_modes || return 1
    k2s_wa_check_auth_dir || return 1
    k2s_wa_flush_credentials || return 1
    k2s_wa_log "credentials ready in '$K2S_WA_AUTH_DIR'"
}

# --- kube-apiserver static Pod manifest ---

# Sets K2S_WA_STATE to absent, configured, custom (foreign --admission-control-config-file) or partial.
k2s_wa_manifest_state() {
    local manifest="$1" out line name path value raw_flags raw_names rc=0
    local -a flags=() mounts=() volumes=()
    local want_flag="C|kube-apiserver|$K2S_WA_FLAG"
    local want_mount="M|kube-apiserver|$K2S_WA_VOLUME|$K2S_WA_POD_DIR|true"
    local want_volume="V|$K2S_WA_VOLUME|$K2S_WA_AUTH_DIR|Directory"
    K2S_WA_STATE=''
    if ! out=$(k2s_wa_kubectl_local patch --local -f "$manifest" --type=json -p '[]' -o "go-template=$K2S_WA_STATE_TEMPLATE"); then
        k2s_wa_error "cannot parse '$manifest'"
        return 1
    fi
    while IFS= read -r line; do
        case "$line" in
            C\|* | A\|*)
                IFS='|' read -r _ _ value <<< "$line"
                if [[ "$value" == --admission-control-config-file* ]]; then flags+=("$line"); fi ;;
            M\|*)
                IFS='|' read -r _ _ name path _ <<< "$line"
                if [[ "$name" == "$K2S_WA_VOLUME" || "$path" == "$K2S_WA_POD_DIR" ]]; then mounts+=("$line"); fi ;;
            V\|*)
                IFS='|' read -r _ name path _ <<< "$line"
                if [[ "$name" == "$K2S_WA_VOLUME" || "$path" == "$K2S_WA_AUTH_DIR" ]]; then volumes+=("$line"); fi ;;
        esac
    done <<< "$out"
    raw_flags=$(grep -c -F -- 'admission-control-config-file' "$manifest") || rc=$?
    if (( rc <= 1 )); then
        rc=0
        raw_names=$(grep -c -F -- "$K2S_WA_VOLUME" "$manifest") || rc=$?
    fi
    if (( rc > 1 )); then
        k2s_wa_error "cannot read '$manifest'"
        return 1
    fi
    for line in "${flags[@]}"; do
        if [[ "$line" != "$want_flag" ]]; then
            K2S_WA_STATE='custom'
            return 0
        fi
    done
    if (( ${#flags[@]} == 0 && ${#mounts[@]} == 0 && ${#volumes[@]} == 0 && raw_flags == 0 && raw_names == 0 )); then
        K2S_WA_STATE='absent'
    elif (( ${#flags[@]} == 1 && ${#mounts[@]} == 1 && ${#volumes[@]} == 1 && raw_flags == 1 )) &&
        [[ "${mounts[0]}" == "$want_mount" && "${volumes[0]}" == "$want_volume" ]]; then
        K2S_WA_STATE='configured'
    else
        K2S_WA_STATE='partial'
    fi
}

# Sets K2S_WA_PROC_STATES to the sorted distinct states (flag, noflag) of running kube-apiserver processes.
k2s_wa_apiserver_process_states() {
    local comm_file name arg state has_flag=0 has_noflag=0
    local -a cmdline
    for comm_file in "$K2S_WA_PROC_DIR"/[0-9]*/comm; do
        name=''
        { read -r name < "$comm_file" || [[ -n "$name" ]]; } 2>/dev/null || continue
        [[ "$name" == 'kube-apiserver' ]] || continue
        cmdline=()
        { mapfile -d '' -t cmdline < "${comm_file%/comm}/cmdline"; } 2>/dev/null || continue
        (( ${#cmdline[@]} > 0 )) || continue
        state='noflag'
        for arg in "${cmdline[@]}"; do
            if [[ "$arg" == "$K2S_WA_FLAG" ]]; then state='flag'; break; fi
        done
        if [[ "$state" == 'flag' ]]; then has_flag=1; else has_noflag=1; fi
    done
    K2S_WA_PROC_STATES=''
    if (( has_flag )); then K2S_WA_PROC_STATES='flag'; fi
    if (( has_noflag )); then K2S_WA_PROC_STATES="${K2S_WA_PROC_STATES:+$K2S_WA_PROC_STATES }noflag"; fi
}

k2s_wa_apiserver_ready() {
    local out
    out=$(k2s_wa_kubectl get --raw=/readyz --request-timeout=5s 2>/dev/null) || return 1
    [[ "$out" == 'ok' ]]
}

# Waits at most K2S_WA_WAIT_TIMEOUT seconds until only kube-apiserver processes in the wanted state
# (flag or noflag) run and /readyz reports ok in K2S_WA_READY_STREAK consecutive checks.
k2s_wa_wait_apiserver() {
    local want="$1" streak=0 deadline=$((SECONDS + K2S_WA_WAIT_TIMEOUT)) next_log=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        k2s_wa_apiserver_process_states
        if [[ "$K2S_WA_PROC_STATES" == "$want" ]] && k2s_wa_apiserver_ready; then
            streak=$((streak + 1))
            if (( streak >= K2S_WA_READY_STREAK )); then return 0; fi
        else
            streak=0
        fi
        if (( SECONDS >= next_log )); then
            k2s_wa_log "waiting for kube-apiserver ($want); running: ${K2S_WA_PROC_STATES:-none}"
            next_log=$((SECONDS + 30))
        fi
        sleep "$K2S_WA_WAIT_INTERVAL"
    done
    return 1
}

k2s_wa_sorted_lines() {
    local rc=0
    grep -v -- '^[[:space:]]*$' "$1" > "$2.unsorted" || rc=$?
    (( rc <= 1 )) || return 1
    LC_ALL=C sort -- "$2.unsorted" > "$2"
}

# Refuses a patched manifest that drops or rewrites any existing line or adds anything but the
# 8 expected lines (flag, volume mount, volume).
k2s_wa_compare_manifests() {
    local patched="$1" work="$2"
    local -a lost=() added=()
    if ! k2s_wa_sorted_lines "$K2S_WA_MANIFEST" "$work/original" || ! k2s_wa_sorted_lines "$patched" "$work/patched" ||
        ! LC_ALL=C comm -23 "$work/original" "$work/patched" > "$work/lost" ||
        ! LC_ALL=C comm -13 "$work/original" "$work/patched" > "$work/added"; then
        k2s_wa_error 'cannot compare the kube-apiserver manifests'
        return 1
    fi
    mapfile -t lost < "$work/lost"
    mapfile -t added < "$work/added"
    if (( ${#lost[@]} > 0 )); then
        k2s_wa_error "patching '$K2S_WA_MANIFEST' would change existing lines; add the configuration manually. Nothing was changed. Affected lines:"
        printf '    %s\n' "${lost[@]}"
        return 3
    fi
    if (( ${#added[@]} != 8 )); then
        k2s_wa_error "patching '$K2S_WA_MANIFEST' added ${#added[@]} lines instead of 8. Nothing was changed."
        return 1
    fi
}

k2s_wa_backup_manifest() {
    local tmp
    if ! mkdir -p -- "$K2S_WA_BACKUP_DIR" || ! chmod 0700 -- "$K2S_WA_BACKUP_DIR" ||
        ! tmp=$(mktemp "$K2S_WA_BACKUP_DIR/.kube-apiserver.yaml.tmp.XXXXXX"); then
        k2s_wa_error "cannot prepare '$K2S_WA_BACKUP_DIR'"
        return 1
    fi
    # The backup is on disk before the manifest is replaced (see Durability in the header).
    if ! cp -p -- "$K2S_WA_MANIFEST" "$tmp" || ! cmp -s -- "$K2S_WA_MANIFEST" "$tmp" || ! sync -- "$tmp" ||
        ! mv -f -- "$tmp" "$K2S_WA_BACKUP_FILE" || ! sync -- "$K2S_WA_BACKUP_DIR"; then
        rm -f -- "$tmp"
        k2s_wa_error "cannot back up '$K2S_WA_MANIFEST' to '$K2S_WA_BACKUP_FILE'"
        return 1
    fi
    k2s_wa_log "backed up '$K2S_WA_MANIFEST' to '$K2S_WA_BACKUP_FILE'"
}

# A failed flush never stops the restore.
k2s_wa_restore_manifest() {
    local tmp
    tmp=$(mktemp "$K2S_WA_MANIFEST_DIR/.kube-apiserver.yaml.k2s-webhook-auth.XXXXXX") || return 1
    if ! cp -p -- "$K2S_WA_BACKUP_FILE" "$tmp" || ! cmp -s -- "$K2S_WA_BACKUP_FILE" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    sync -- "$tmp" || k2s_wa_warn "cannot flush '$tmp' to disk; restoring anyway"
    if ! mv -f -- "$tmp" "$K2S_WA_MANIFEST"; then
        rm -f -- "$tmp"
        return 1
    fi
    sync -- "$K2S_WA_MANIFEST_DIR" || k2s_wa_warn "cannot flush '$K2S_WA_MANIFEST_DIR' to disk"
    cmp -s -- "$K2S_WA_BACKUP_FILE" "$K2S_WA_MANIFEST"
}

# Applies the kubeadm patch to the unconfigured manifest via the staged file $1 (a dot-file in the
# manifests directory, ignored by the kubelet).
k2s_wa_patch_manifest() {
    local staged="$1" work rc=0
    if ! k2s_wa_kubectl_local patch --local -f "$K2S_WA_MANIFEST" --type=json --patch-file "$K2S_WA_PATCH_FILE" -o yaml > "$staged"; then
        k2s_wa_error "cannot apply '$K2S_WA_PATCH_FILE' to '$K2S_WA_MANIFEST'"
        return 1
    fi
    k2s_wa_manifest_state "$staged" || return 1
    if [[ "$K2S_WA_STATE" != 'configured' ]]; then
        k2s_wa_error "patched kube-apiserver manifest is $K2S_WA_STATE instead of configured"
        return 1
    fi
    if ! work=$(mktemp -d "$K2S_WA_ROOT/.k2s-webhook-auth-diff.tmp.XXXXXX"); then
        k2s_wa_error "cannot create a temporary directory in '$K2S_WA_ROOT'"
        return 1
    fi
    k2s_wa_compare_manifests "$staged" "$work" || rc=$?
    rm -rf -- "$work"
    (( rc == 0 )) || return "$rc"
    k2s_wa_backup_manifest || return 1
    # An interruption from here on could leave a manifest in place with which kube-apiserver does not start.
    # k2s_wa_ensure_apiserver resets the signals once the outcome is known (see the header).
    trap '' INT TERM QUIT
    if ! chmod --reference="$K2S_WA_MANIFEST" -- "$staged" || ! chown --reference="$K2S_WA_MANIFEST" -- "$staged" ||
        ! sync -- "$staged" || ! mv -f -- "$staged" "$K2S_WA_MANIFEST"; then
        k2s_wa_error "cannot replace '$K2S_WA_MANIFEST'"
        return 1
    fi
    # The replacement is done; a failed flush must not skip the readiness wait or the restore.
    sync -- "$K2S_WA_MANIFEST_DIR" || k2s_wa_warn "cannot flush '$K2S_WA_MANIFEST_DIR' to disk"
    k2s_wa_log "updated '$K2S_WA_MANIFEST'; waiting for kube-apiserver to restart with the admission configuration"
    if k2s_wa_wait_apiserver flag; then
        k2s_wa_log 'kube-apiserver is ready with the admission configuration'
        return 0
    fi
    k2s_wa_error 'kube-apiserver did not become ready with the admission configuration; restoring the previous manifest'
    if ! k2s_wa_restore_manifest; then
        k2s_wa_error "cannot restore '$K2S_WA_MANIFEST' from '$K2S_WA_BACKUP_FILE'; restore it manually"
        return 6
    fi
    if k2s_wa_wait_apiserver noflag; then
        k2s_wa_error 'previous kube-apiserver manifest restored; kube-apiserver recovered'
        return 5
    fi
    k2s_wa_error "previous kube-apiserver manifest restored, but kube-apiserver did not recover"
    return 6
}

k2s_wa_ensure_apiserver() {
    local staged rc=0
    k2s_wa_provision || return 1
    if [[ ! -f "$K2S_WA_MANIFEST" ]]; then
        k2s_wa_error "kube-apiserver manifest '$K2S_WA_MANIFEST' not found"
        return 1
    fi
    k2s_wa_manifest_state "$K2S_WA_MANIFEST" || return 1
    case "$K2S_WA_STATE" in
        configured)
            k2s_wa_log 'kube-apiserver manifest already contains the admission configuration'
            if ! k2s_wa_wait_apiserver flag; then
                # Never restored automatically: the backup may predate a later kubeadm upgrade.
                k2s_wa_error "kube-apiserver is not ready with the admission configuration; the manifest was not changed (backup of the manifest before this script last changed it: '$K2S_WA_BACKUP_FILE')"
                return 1
            fi
            k2s_wa_log 'kube-apiserver is ready with the admission configuration'
            return 0 ;;
        custom)
            k2s_wa_error "kube-apiserver already uses another --admission-control-config-file; add a MutatingAdmissionWebhook plugin with kubeConfigFile '$K2S_WA_POD_DIR/kubeconfig' to it manually. Nothing was changed."
            return 3 ;;
        partial)
            k2s_wa_error "'$K2S_WA_MANIFEST' contains an incomplete clusterip-webhook admission configuration; correct it manually. Nothing was changed."
            return 3 ;;
    esac
    if ! k2s_wa_wait_apiserver noflag; then
        k2s_wa_error 'kube-apiserver is not ready; its manifest was not changed'
        return 1
    fi
    if ! staged=$(mktemp "$K2S_WA_MANIFEST_DIR/.kube-apiserver.yaml.k2s-webhook-auth.XXXXXX"); then
        k2s_wa_error "cannot create a temporary file in '$K2S_WA_MANIFEST_DIR'"
        return 1
    fi
    k2s_wa_patch_manifest "$staged" || rc=$?
    rm -f -- "$staged"
    trap - INT TERM QUIT
    return "$rc"
}

# --- CA publication ---

# Checks a ConfigMap summary ($1, K2S_WA_CONFIGMAP_TEMPLATE) and its ca.crt ($2) against the local CA certificate.
k2s_wa_compare_configmap() {
    local summary="$1" value="$2" expected
    local nl=$'\n'
    expected=$(<"$K2S_WA_CA_DIR/ca.crt") || { K2S_WA_REASON='cannot read the local CA certificate'; return 1; }
    if [[ "$summary" != "ConfigMap|$K2S_WA_NAMESPACE|$K2S_WA_CONFIGMAP${nl}data/ca.crt" ]]; then
        K2S_WA_REASON="unexpected object or keys: ${summary//$nl/ }"
        return 1
    fi
    [[ "$value" == "$expected" ]] || { K2S_WA_REASON='ca.crt differs from the local CA certificate'; return 1; }
}

# Checks that the ConfigMap in file $1 is ours and contains exactly ca.crt with the local CA certificate.
k2s_wa_check_configmap() {
    local file="$1" summary value
    K2S_WA_REASON=''
    summary=$(k2s_wa_kubectl_local patch --local -f "$file" --type=json -p '[]' -o "go-template=$K2S_WA_CONFIGMAP_TEMPLATE") ||
        { K2S_WA_REASON='cannot parse the ConfigMap'; return 1; }
    value=$(k2s_wa_kubectl_local patch --local -f "$file" --type=json -p '[]' -o 'jsonpath={.data.ca\.crt}') ||
        { K2S_WA_REASON='cannot read ca.crt from the ConfigMap'; return 1; }
    k2s_wa_compare_configmap "$summary" "$value"
}

k2s_wa_publish_ca() {
    local work="$1"
    if ! k2s_wa_render_configmap > "$work/configmap.yaml"; then
        k2s_wa_error 'cannot render the ConfigMap'
        return 1
    fi
    if ! k2s_wa_check_configmap "$work/configmap.yaml"; then
        k2s_wa_error "rendered ConfigMap failed validation: $K2S_WA_REASON"
        return 1
    fi
    if ! k2s_wa_kubectl apply --server-side --force-conflicts --field-manager="$K2S_WA_FIELD_MANAGER" -f "$work/configmap.yaml"; then
        k2s_wa_error "cannot publish ConfigMap $K2S_WA_NAMESPACE/$K2S_WA_CONFIGMAP"
        return 1
    fi
    if ! k2s_wa_kubectl get configmap "$K2S_WA_CONFIGMAP" -n "$K2S_WA_NAMESPACE" -o yaml > "$work/published.yaml"; then
        k2s_wa_error "cannot read back ConfigMap $K2S_WA_NAMESPACE/$K2S_WA_CONFIGMAP"
        return 1
    fi
    if ! k2s_wa_check_configmap "$work/published.yaml"; then
        k2s_wa_error "published ConfigMap $K2S_WA_NAMESPACE/$K2S_WA_CONFIGMAP is not the client CA certificate: $K2S_WA_REASON"
        return 1
    fi
    k2s_wa_log "published the client CA certificate to ConfigMap $K2S_WA_NAMESPACE/$K2S_WA_CONFIGMAP"
}

k2s_wa_publish() {
    local work rc=0
    if ! k2s_wa_check_ca "$K2S_WA_CA_DIR"; then
        k2s_wa_error "client CA in '$K2S_WA_CA_DIR' is missing or invalid ($K2S_WA_REASON); run provision first"
        return 1
    fi
    if ! work=$(mktemp -d "$K2S_WA_ROOT/.k2s-webhook-auth-publish.tmp.XXXXXX"); then
        k2s_wa_error "cannot create a temporary directory in '$K2S_WA_ROOT'"
        return 1
    fi
    k2s_wa_publish_ca "$work" || rc=$?
    rm -rf -- "$work"
    return "$rc"
}

# --- verification (read-only) ---

k2s_wa_verify_fail() {
    K2S_WA_VERIFY_RESULT="$1"
    K2S_WA_VERIFY_DETAIL="$2"
    return 1
}

k2s_wa_matches_render() {
    K2S_WA_REASON="'$1' is missing or differs from the expected content; run provision"
    [[ -f "$1" && ! -L "$1" ]] && cmp -s -- "$1" <("$2")
}

k2s_wa_verify_local() {
    local crt="$K2S_WA_AUTH_DIR/client.crt" key="$K2S_WA_AUTH_DIR/client.key" ca="$K2S_WA_CA_DIR/ca.crt"
    if ! k2s_wa_check_ca "$K2S_WA_CA_DIR" 0; then
        k2s_wa_verify_fail ca-invalid "client CA '$K2S_WA_CA_DIR': $K2S_WA_REASON"
        return 1
    fi
    k2s_wa_check_ca "$K2S_WA_CA_DIR" || k2s_wa_warn "client CA '$K2S_WA_CA_DIR': $K2S_WA_REASON; renew is refused until the CA is replaced"
    if k2s_wa_is_single_cert "$crt" && ! openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1; then
        k2s_wa_verify_fail client-cert-expired "client certificate '$crt' has expired; run renew"
        return 1
    fi
    if ! k2s_wa_check_client_cert "$crt" "$key" "$ca" 0; then
        k2s_wa_verify_fail client-cert-invalid "'$crt': $K2S_WA_REASON"
        return 1
    fi
    k2s_wa_check_client_cert "$crt" "$key" "$ca" || k2s_wa_warn "$K2S_WA_REASON; run renew"
    if [[ -L "$K2S_WA_AUTH_DIR" ]] || ! k2s_wa_check_auth_dir; then
        k2s_wa_verify_fail admission-config-invalid "'$K2S_WA_AUTH_DIR' is not the expected credential directory"
        return 1
    fi
    if ! k2s_wa_matches_render "$K2S_WA_AUTH_DIR/kubeconfig" k2s_wa_render_kubeconfig ||
        ! k2s_wa_matches_render "$K2S_WA_AUTH_DIR/admission-config.yaml" k2s_wa_render_admission_config ||
        ! k2s_wa_matches_render "$K2S_WA_PATCH_FILE" k2s_wa_render_patch; then
        k2s_wa_verify_fail admission-config-invalid "$K2S_WA_REASON"
        return 1
    fi
}

k2s_wa_verify_apiserver() {
    if [[ ! -f "$K2S_WA_MANIFEST" ]]; then
        k2s_wa_verify_fail apiserver-not-configured "kube-apiserver manifest '$K2S_WA_MANIFEST' not found"
        return 1
    fi
    if ! k2s_wa_manifest_state "$K2S_WA_MANIFEST"; then
        k2s_wa_verify_fail apiserver-not-configured "cannot read the admission configuration from '$K2S_WA_MANIFEST'"
        return 1
    fi
    if [[ "$K2S_WA_STATE" != 'configured' ]]; then
        k2s_wa_verify_fail apiserver-not-configured "the admission configuration in '$K2S_WA_MANIFEST' is $K2S_WA_STATE; run ensure-apiserver"
        return 1
    fi
    k2s_wa_apiserver_process_states
    case "$K2S_WA_PROC_STATES" in
        flag) ;;
        '') k2s_wa_verify_fail apiserver-unavailable 'no kube-apiserver process is running'; return 1 ;;
        *) k2s_wa_verify_fail apiserver-not-configured 'a kube-apiserver process runs without the admission configuration'; return 1 ;;
    esac
    if ! k2s_wa_apiserver_ready; then
        k2s_wa_verify_fail apiserver-unavailable 'kube-apiserver is not ready'
        return 1
    fi
}

k2s_wa_verify_configmap() {
    local summary value name="ConfigMap $K2S_WA_NAMESPACE/$K2S_WA_CONFIGMAP"
    if ! summary=$(k2s_wa_kubectl get configmap "$K2S_WA_CONFIGMAP" -n "$K2S_WA_NAMESPACE" --ignore-not-found \
        -o "go-template=$K2S_WA_CONFIGMAP_TEMPLATE"); then
        k2s_wa_verify_fail apiserver-unavailable "cannot read $name"
        return 1
    fi
    if [[ -z "$summary" ]]; then
        k2s_wa_verify_fail ca-mismatch "$name does not exist; run publish"
        return 1
    fi
    if ! value=$(k2s_wa_kubectl get configmap "$K2S_WA_CONFIGMAP" -n "$K2S_WA_NAMESPACE" -o 'jsonpath={.data.ca\.crt}'); then
        k2s_wa_verify_fail apiserver-unavailable "cannot read $name"
        return 1
    fi
    if ! k2s_wa_compare_configmap "$summary" "$value"; then
        k2s_wa_verify_fail ca-mismatch "$name: $K2S_WA_REASON; run publish, then restart the webhook"
        return 1
    fi
}

k2s_wa_ipv4_int() {
    local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
    [[ "$1" =~ $re ]] || return 1
    (( 10#${BASH_REMATCH[1]} <= 255 && 10#${BASH_REMATCH[2]} <= 255 && 10#${BASH_REMATCH[3]} <= 255 &&
        10#${BASH_REMATCH[4]} <= 255 )) || return 1
    K2S_WA_IP_INT=$(( 10#${BASH_REMATCH[1]} << 24 | 10#${BASH_REMATCH[2]} << 16 | 10#${BASH_REMATCH[3]} << 8 | 10#${BASH_REMATCH[4]} ))
}

k2s_wa_int_ipv4() { printf '%d.%d.%d.%d' $(($1 >> 24 & 255)) $(($1 >> 16 & 255)) $(($1 >> 8 & 255)) $(($1 & 255)); }

# Sets K2S_WA_RANGE_START and K2S_WA_RANGE_END to the Linux clusterIP range of the webhook like subnetRange in
# cmd/clusterip-webhook/main.go: network address plus --reserved-ips up to the address before the broadcast.
k2s_wa_webhook_range() {
    local out tag value pending='' container=0 address prefix mask network
    local subnet="$K2S_WA_DEFAULT_LINUX_SUBNET" reserved="$K2S_WA_DEFAULT_RESERVED_IPS"
    local cidr_re='^([0-9.]+)/([0-9]{1,2})$' reserved_re='^[1-9][0-9]{0,8}$'
    local name="Deployment $K2S_WA_NAMESPACE/$K2S_WA_DEPLOYMENT"
    if ! out=$(k2s_wa_kubectl get deployment "$K2S_WA_DEPLOYMENT" -n "$K2S_WA_NAMESPACE" --ignore-not-found \
        -o "go-template=$K2S_WA_ARGS_TEMPLATE"); then
        k2s_wa_verify_fail apiserver-unavailable "cannot read $name"
        return 1
    fi
    while IFS='|' read -r tag value; do
        if [[ "$tag" == 'C' ]]; then container=1; continue; fi
        [[ "$tag" == 'A' ]] || continue
        case "$pending" in
            subnet) subnet="$value"; pending=''; continue ;;
            reserved) reserved="$value"; pending=''; continue ;;
        esac
        case "$value" in
            --linux-subnet=* | -linux-subnet=*) subnet="${value#*=}" ;;
            --linux-subnet | -linux-subnet) pending='subnet' ;;
            --reserved-ips=* | -reserved-ips=*) reserved="${value#*=}" ;;
            --reserved-ips | -reserved-ips) pending='reserved' ;;
        esac
    done <<< "$out"
    if (( ! container )); then
        k2s_wa_verify_fail webhook-config-invalid "$name with container webhook not found"
        return 1
    fi
    # The dry-run default clusterIP is a network address; it must stay outside the range.
    if [[ ! "$reserved" =~ $reserved_re ]]; then
        k2s_wa_verify_fail webhook-config-invalid "verify needs --reserved-ips between 1 and 999999999, not '$reserved'"
        return 1
    fi
    if [[ ! "$subnet" =~ $cidr_re ]]; then
        k2s_wa_verify_fail webhook-config-invalid "unsupported --linux-subnet '$subnet' (IPv4 CIDR expected)"
        return 1
    fi
    address="${BASH_REMATCH[1]}"
    prefix=$((10#${BASH_REMATCH[2]}))
    if (( prefix > 32 )) || ! k2s_wa_ipv4_int "$address"; then
        k2s_wa_verify_fail webhook-config-invalid "unsupported --linux-subnet '$subnet' (IPv4 CIDR expected)"
        return 1
    fi
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    network=$(( K2S_WA_IP_INT & mask ))
    K2S_WA_RANGE_START=$(( network + reserved ))
    K2S_WA_RANGE_END=$(( (network | (~mask & 0xFFFFFFFF)) - 1 ))
    if (( K2S_WA_RANGE_START >= K2S_WA_RANGE_END )); then
        k2s_wa_verify_fail webhook-config-invalid "--linux-subnet '$subnet' is too small for --reserved-ips $reserved"
        return 1
    fi
}

k2s_wa_verify_webhook_config() {
    local out tag name policy namespace service path port url bundle found=0 ours=''
    local config="MutatingWebhookConfiguration $K2S_WA_WEBHOOK_CONFIG"
    if ! out=$(k2s_wa_kubectl get mutatingwebhookconfiguration "$K2S_WA_WEBHOOK_CONFIG" --ignore-not-found \
        -o "go-template=$K2S_WA_WEBHOOKS_TEMPLATE"); then
        k2s_wa_verify_fail apiserver-unavailable "cannot read $config"
        return 1
    fi
    while IFS='|' read -r tag name policy namespace service path port url bundle; do
        [[ "$tag" == 'H' ]] || continue
        # Both webhooks must reach the same TLS server, so the checks of one cover the other.
        if [[ "$namespace/$service" != "$K2S_WA_NAMESPACE/$K2S_WA_SERVICE" || "$port" != "$K2S_WA_SERVICE_PORT" || -n "$url" ]]; then
            k2s_wa_verify_fail webhook-config-invalid "webhook $name of $config does not call Service $K2S_WA_NAMESPACE/$K2S_WA_SERVICE on port $K2S_WA_SERVICE_PORT"
            return 1
        fi
        if [[ "$name" == "$K2S_WA_WEBHOOK" ]]; then
            found=$((found + 1))
            ours="$policy|$path|$bundle"
        fi
    done <<< "$out"
    if (( found != 1 )); then
        k2s_wa_verify_fail webhook-config-invalid "$config does not exist or does not contain webhook $K2S_WA_WEBHOOK exactly once"
        return 1
    fi
    IFS='|' read -r policy path bundle <<< "$ours"
    if [[ "$path" != '/mutate' ]]; then
        k2s_wa_verify_fail webhook-config-invalid "webhook $K2S_WA_WEBHOOK calls path '$path' instead of /mutate"
        return 1
    fi
    if ! K2S_WA_SERVER_CA=$(printf '%s' "$bundle" | base64 -d 2>/dev/null) ||
        ! openssl x509 -noout >/dev/null 2>&1 <<< "$K2S_WA_SERVER_CA"; then
        k2s_wa_verify_fail webhook-config-invalid "the caBundle of webhook $K2S_WA_WEBHOOK is not a certificate (the webhook sets it when it starts)"
        return 1
    fi
    if [[ "$policy" == 'Ignore' ]]; then
        k2s_wa_log "webhook $K2S_WA_WEBHOOK has failurePolicy Ignore: kube-apiserver admits a Service without it if the call fails; the admission metrics detect this"
    fi
    k2s_wa_webhook_range
}

# Sets K2S_WA_UNSAFE_WEBHOOKS to the webhooks that may receive the dry-run Service and declare side effects other
# than None or NoneOnDryRun. Selectors, scope and match conditions are ignored, so the check is conservative.
k2s_wa_audit_side_effects() {
    local out tag config webhook effects groups versions resources operations others=''
    K2S_WA_UNSAFE_WEBHOOKS=''
    if ! out=$(k2s_wa_kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations \
        -o "go-template=$K2S_WA_RULES_TEMPLATE"); then
        k2s_wa_verify_fail apiserver-unavailable 'cannot read the admission webhook configurations'
        return 1
    fi
    while IFS='|' read -r tag config webhook effects groups versions resources operations; do
        [[ "$tag" == 'W' ]] || continue
        [[ "$groups" == *'[]'* || "$groups" == *'[*]'* ]] || continue
        [[ "$versions" == *'[v1]'* || "$versions" == *'[*]'* ]] || continue
        [[ "$resources" == *'[services]'* || "$resources" == *'[services/*]'* || "$resources" == *'[*]'* ||
            "$resources" == *'[*/*]'* ]] || continue
        [[ "$operations" == *'[CREATE]'* || "$operations" == *'[*]'* ]] || continue
        case "$effects" in
            None | NoneOnDryRun)
                if [[ "$config/$webhook" != "$K2S_WA_WEBHOOK_CONFIG/$K2S_WA_WEBHOOK" ]]; then
                    others="${others:+$others, }$config/$webhook"
                fi ;;
            *) K2S_WA_UNSAFE_WEBHOOKS="${K2S_WA_UNSAFE_WEBHOOKS:+$K2S_WA_UNSAFE_WEBHOOKS, }$config/$webhook (sideEffects $effects)" ;;
        esac
    done <<< "$out"
    if [[ -n "$others" ]]; then
        k2s_wa_log "the dry-run Service is also sent to webhooks declaring no side effects: $others"
    fi
}

k2s_wa_add_target() {
    local ip="$1" port="$2" ipv4_re='^[0-9]{1,3}(\.[0-9]{1,3}){3}$' ipv6_re='^[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*$'
    local port_re='^[1-9][0-9]{0,4}$'
    [[ "$port" =~ $port_re ]] || return 1
    if [[ "$ip" =~ $ipv4_re ]]; then
        K2S_WA_TARGETS+=("$ip:$port")
    elif [[ "$ip" =~ $ipv6_re ]]; then
        K2S_WA_TARGETS+=("[$ip]:$port")
    else
        return 1
    fi
}

# Sets K2S_WA_TARGETS to the webhook Service and each of its ready endpoints (host:port).
k2s_wa_webhook_targets() {
    local out tag ip port name="Service $K2S_WA_NAMESPACE/$K2S_WA_SERVICE"
    K2S_WA_TARGETS=()
    if ! out=$(k2s_wa_kubectl get service "$K2S_WA_SERVICE" -n "$K2S_WA_NAMESPACE" --ignore-not-found \
        -o "go-template=$K2S_WA_SERVICE_TEMPLATE"); then
        k2s_wa_verify_fail apiserver-unavailable "cannot read $name"
        return 1
    fi
    IFS='|' read -r ip port <<< "$out"
    if [[ -z "$out" ]] || ! k2s_wa_add_target "$ip" "$port"; then
        k2s_wa_verify_fail webhook-unavailable "$name not found or without clusterIP and https port"
        return 1
    fi
    if ! out=$(k2s_wa_kubectl get endpointslices -n "$K2S_WA_NAMESPACE" -l "kubernetes.io/service-name=$K2S_WA_SERVICE" \
        -o "go-template=$K2S_WA_ENDPOINTS_TEMPLATE"); then
        k2s_wa_verify_fail apiserver-unavailable "cannot read the endpoints of $name"
        return 1
    fi
    while IFS='|' read -r tag ip port; do
        if [[ "$tag" == 'E' ]]; then k2s_wa_add_target "$ip" "$port" || k2s_wa_warn "ignoring endpoint '$ip' port '$port'"; fi
    done <<< "$out"
    if (( ${#K2S_WA_TARGETS[@]} < 2 )); then
        k2s_wa_verify_fail webhook-unavailable "$name has no ready endpoint"
        return 1
    fi
}

# Connects to $1 (host:port) like kube-apiserver (SNI, serving certificate verified with the caBundle), without
# or with ($2 = 1) the client certificate, and requests a path the webhook does not serve. Sets K2S_WA_PROBE to
# http:<status>, alert:<TLS alert number>, untrusted (serving certificate), unreachable[:timeout] or unknown.
k2s_wa_probe() {
    local target="$1" out rc=0 nl=$'\n'
    local http_re="(^|$nl)HTTP/1\\.[01] ([1-5][0-9][0-9])([^0-9]|\$)" alert_re='SSL alert number ([0-9]+)'
    local -a cert=()
    if [[ "$2" == 1 ]]; then cert=(-cert "$K2S_WA_AUTH_DIR/client.crt" -key "$K2S_WA_AUTH_DIR/client.key"); fi
    out=$(printf 'GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$K2S_WA_PROBE_PATH" "$K2S_WA_SERVICE_HOST" |
        timeout "$K2S_WA_PROBE_TIMEOUT" openssl s_client -brief -connect "$target" -servername "$K2S_WA_SERVICE_HOST" \
            -verify_hostname "$K2S_WA_SERVICE_HOST" -verify_return_error -CAfile <(printf '%s\n' "$K2S_WA_SERVER_CA") \
            -ign_eof ${cert[@]+"${cert[@]}"} 2>&1) || rc=$?
    if [[ "$out" == *'verify error:num='* || "$out" == *'certificate verify failed'* ]]; then
        K2S_WA_PROBE='untrusted'
    elif [[ "$out" =~ $http_re ]]; then
        K2S_WA_PROBE="http:${BASH_REMATCH[2]}"
        if [[ "$out" =~ $alert_re ]]; then K2S_WA_PROBE='unknown'; fi
    elif [[ "$out" =~ $alert_re ]]; then
        K2S_WA_PROBE="alert:${BASH_REMATCH[1]}"
    elif (( rc == 124 )); then
        K2S_WA_PROBE='unreachable:timeout'
    elif [[ "$out" == *'errno='* ]]; then
        K2S_WA_PROBE='unreachable'
    else
        K2S_WA_PROBE='unknown'
    fi
}

# Every target must refuse the TLS handshake without a client certificate (alert certificate_required,
# handshake_failure or bad_certificate) and answer with the client certificate.
k2s_wa_probe_targets() {
    local target hint result='' detail=''
    k2s_wa_webhook_targets || return 1
    for target in "${K2S_WA_TARGETS[@]}"; do
        k2s_wa_probe "$target" 0
        case "$K2S_WA_PROBE" in
            alert:116 | alert:40 | alert:42) continue ;;
            http:*)
                k2s_wa_verify_fail unauthenticated-accepted "$target answered a client without certificate ($K2S_WA_PROBE)"
                return 1 ;;
            untrusted) k2s_wa_verify_fail webhook-tls-untrusted "$target: serving certificate not trusted through the caBundle" ;;
            unreachable*) k2s_wa_verify_fail webhook-unavailable "$target: no TLS connection ($K2S_WA_PROBE)" ;;
            *) k2s_wa_verify_fail inconclusive "$target: unexpected result without client certificate ($K2S_WA_PROBE)" ;;
        esac
        if [[ -z "$result" ]]; then result="$K2S_WA_VERIFY_RESULT"; detail="$K2S_WA_VERIFY_DETAIL"; fi
    done
    for target in "${K2S_WA_TARGETS[@]}"; do
        k2s_wa_probe "$target" 1
        case "$K2S_WA_PROBE" in
            http:*) continue ;;
            alert:*)
                case "$K2S_WA_PROBE" in
                    alert:45) hint='certificate expired' ;;
                    alert:48) hint='unknown CA: run publish, then restart the webhook' ;;
                    alert:42) hint='bad certificate' ;;
                    *) hint='TLS alert' ;;
                esac
                k2s_wa_verify_fail client-cert-rejected "$target refused the client certificate ($K2S_WA_PROBE, $hint)" ;;
            untrusted) k2s_wa_verify_fail webhook-tls-untrusted "$target: serving certificate not trusted through the caBundle" ;;
            unreachable*) k2s_wa_verify_fail webhook-unavailable "$target: no TLS connection ($K2S_WA_PROBE)" ;;
            *) k2s_wa_verify_fail inconclusive "$target: unexpected result with the client certificate ($K2S_WA_PROBE)" ;;
        esac
        if [[ -z "$result" ]]; then result="$K2S_WA_VERIFY_RESULT"; detail="$K2S_WA_VERIFY_DETAIL"; fi
    done
    [[ -n "$result" ]] || return 0
    k2s_wa_verify_fail "$result" "$detail"
}

k2s_wa_admission_metrics() {
    k2s_wa_kubectl get --raw=/metrics --request-timeout=30s | awk -v webhook="$K2S_WA_WEBHOOK" "$K2S_WA_METRICS_AWK"
}

# Creates the selector-less Service with server-side dry-run only (never persisted); prints clusterIP=<ip>.
k2s_wa_dry_run_service() {
    printf '%s\n' 'apiVersion: v1' 'kind: Service' 'metadata:' '  generateName: k2s-webhook-auth-probe-' \
        "  namespace: $K2S_WA_PROBE_NAMESPACE" '  labels:' "    app.kubernetes.io/managed-by: $K2S_WA_FIELD_MANAGER" \
        'spec:' '  ports:' '  - port: 1' '    protocol: TCP' |
        k2s_wa_kubectl create --dry-run=server -f - -o 'go-template=clusterIP={{.spec.clusterIP}}{{"\n"}}'
}

# The webhook must assign a clusterIP from its Linux range to the dry-run Service, and the admission metrics of
# the webhook must show only successful calls meanwhile. A call that failed open (failurePolicy Ignore) leaves the
# default dry-run clusterIP, a network address outside the range.
k2s_wa_admission_probe() {
    local before after out ip='' delta calls good failopen rejected reset failed metrics range nl=$'\n'
    local ip_re="(^|$nl)clusterIP=([^$nl]*)" delta_re='^[0-9]+( [0-9]+){4}$'
    range="$(k2s_wa_int_ipv4 "$K2S_WA_RANGE_START")-$(k2s_wa_int_ipv4 "$K2S_WA_RANGE_END")"
    if ! before=$(k2s_wa_admission_metrics); then
        k2s_wa_verify_fail inconclusive 'cannot read the admission metrics of kube-apiserver'
        return 1
    fi
    if ! out=$(k2s_wa_dry_run_service 2>&1); then
        if [[ "$out" == *"webhook \"$K2S_WA_WEBHOOK\""* ]]; then
            k2s_wa_verify_fail admission-failed "webhook $K2S_WA_WEBHOOK refused or failed the dry-run Service: ${out//$nl/ }"
        else
            k2s_wa_verify_fail admission-failed "the dry-run Service was refused: ${out//$nl/ }"
        fi
        return 1
    fi
    if ! after=$(k2s_wa_admission_metrics); then
        k2s_wa_verify_fail inconclusive 'cannot read the admission metrics of kube-apiserver'
        return 1
    fi
    if ! delta=$(printf '%s\n--\n%s\n' "$before" "$after" | awk "$K2S_WA_DELTA_AWK") || [[ ! "$delta" =~ $delta_re ]]; then
        k2s_wa_verify_fail inconclusive 'cannot evaluate the admission metrics of kube-apiserver'
        return 1
    fi
    read -r calls good failopen rejected reset <<< "$delta"
    failed=$((calls - good))
    metrics="calls $calls, failed $failed, failed open $failopen, rejected $rejected, reset $reset"
    if [[ "$out" =~ $ip_re ]]; then ip="${BASH_REMATCH[2]}"; fi
    if k2s_wa_ipv4_int "$ip" && (( K2S_WA_IP_INT >= K2S_WA_RANGE_START && K2S_WA_IP_INT <= K2S_WA_RANGE_END )); then
        if (( calls >= 1 && failed == 0 && failopen == 0 && rejected == 0 && reset == 0 )); then
            k2s_wa_log "webhook $K2S_WA_WEBHOOK assigned $ip to the dry-run Service ($metrics)"
            return 0
        fi
        k2s_wa_verify_fail inconclusive "the webhook assigned $ip, but the admission metrics are ambiguous ($metrics); concurrent admissions?"
    elif (( reset )); then
        k2s_wa_verify_fail inconclusive "kube-apiserver metrics were reset during the check ($metrics)"
    elif (( calls == 0 && failopen == 0 )); then
        k2s_wa_verify_fail admission-not-called "kube-apiserver did not call webhook $K2S_WA_WEBHOOK for the dry-run Service (clusterIP '$ip')"
    elif (( failopen >= 1 && calls == failopen && calls <= 2 )); then
        k2s_wa_verify_fail admission-fail-open "the call of webhook $K2S_WA_WEBHOOK failed and kube-apiserver admitted the dry-run Service without it (clusterIP '$ip', $metrics); see the kube-apiserver log"
    elif (( failed >= 1 && failopen == 0 && calls <= 2 )); then
        k2s_wa_verify_fail admission-failed "the call of webhook $K2S_WA_WEBHOOK failed (clusterIP '$ip', $metrics)"
    elif (( calls >= 1 && failed == 0 && failopen == 0 && rejected == 0 && calls <= 2 )); then
        k2s_wa_verify_fail admission-failed "webhook $K2S_WA_WEBHOOK assigned no clusterIP from $range (clusterIP '$ip'); is the range exhausted?"
    else
        k2s_wa_verify_fail inconclusive "clusterIP '$ip' is outside $range and the admission metrics are ambiguous ($metrics)"
    fi
    return 1
}

# Retries the TLS checks until K2S_WA_VERIFY_TIMEOUT and the admission check up to K2S_WA_VERIFY_ATTEMPTS times
# (the webhook may be rolling out); a webhook answering a client without certificate fails at once.
k2s_wa_verify_authentication() {
    local deadline=$((SECONDS + K2S_WA_VERIFY_TIMEOUT)) attempts=0
    while :; do
        if k2s_wa_probe_targets; then
            if [[ -n "$K2S_WA_UNSAFE_WEBHOOKS" ]]; then
                k2s_wa_verify_fail unsafe-side-effects "no dry-run Service sent: webhooks matching Services declare side effects: $K2S_WA_UNSAFE_WEBHOOKS"
                return 1
            fi
            attempts=$((attempts + 1))
            if k2s_wa_admission_probe; then return 0; fi
            (( attempts < K2S_WA_VERIFY_ATTEMPTS )) || return 1
        elif [[ "$K2S_WA_VERIFY_RESULT" == 'unauthenticated-accepted' ]]; then
            return 1
        fi
        (( SECONDS < deadline )) || return 1
        k2s_wa_log "not verified yet ($K2S_WA_VERIFY_RESULT: $K2S_WA_VERIFY_DETAIL); retrying in ${K2S_WA_VERIFY_INTERVAL}s"
        sleep "$K2S_WA_VERIFY_INTERVAL"
    done
}

# Sets K2S_WA_VERIFY_RESULT to ok or the failure category (see the header).
k2s_wa_run_verification() {
    K2S_WA_VERIFY_RESULT=''
    K2S_WA_VERIFY_DETAIL=''
    if k2s_wa_verify_local && k2s_wa_verify_apiserver && k2s_wa_verify_configmap && k2s_wa_verify_webhook_config &&
        k2s_wa_audit_side_effects && k2s_wa_verify_authentication; then
        K2S_WA_VERIFY_RESULT='ok'
        k2s_wa_log 'verified: the webhook refuses clients without certificate and accepts the client certificate, and kube-apiserver calls it successfully'
        return 0
    fi
    k2s_wa_error "verification failed ($K2S_WA_VERIFY_RESULT): $K2S_WA_VERIFY_DETAIL"
    return 1
}

k2s_wa_remove_kubectl_cache() {
    local dir="$K2S_WA_KUBECTL_CACHE"
    K2S_WA_KUBECTL_CACHE=''
    if [[ -n "$dir" ]] && ! rm -rf -- "$dir"; then
        k2s_wa_warn "cannot remove the temporary kubectl cache directory '$dir'"
    fi
}

# Runs the verification with a private kubectl cache directory (kubectl caches discovery and HTTP responses below
# ~/.kube/cache by default), created in TMPDIR and removed afterwards, also after a failure; an interruption by SIGINT,
# SIGTERM or SIGQUIT removes it and ends the run with exit status 130, 143 or 131. So a verification writes no files.
# Verifications run with the default dispositions of these signals, which are restored afterwards. The handlers are
# installed before the directory is created and reset only after it is removed.
k2s_wa_verify() {
    local rc=0
    K2S_WA_VERIFY_RESULT=''
    K2S_WA_VERIFY_DETAIL=''
    K2S_WA_KUBECTL_CACHE=''
    trap 'k2s_wa_remove_kubectl_cache; exit 130' INT
    trap 'k2s_wa_remove_kubectl_cache; exit 143' TERM
    trap 'k2s_wa_remove_kubectl_cache; exit 131' QUIT
    if ! K2S_WA_KUBECTL_CACHE=$(mktemp -d --tmpdir k2s-webhook-auth-kubectl-cache.XXXXXXXX); then
        K2S_WA_KUBECTL_CACHE=''
        trap - INT TERM QUIT
        k2s_wa_verify_fail inconclusive 'cannot create a private kubectl cache directory'
        k2s_wa_error "verification failed ($K2S_WA_VERIFY_RESULT): $K2S_WA_VERIFY_DETAIL"
        return 1
    fi
    k2s_wa_run_verification || rc=$?
    k2s_wa_remove_kubectl_cache
    trap - INT TERM QUIT
    return "$rc"
}

# --- client certificate renewal ---

k2s_wa_renew() {
    local force="$1" crt="$K2S_WA_AUTH_DIR/client.crt" key="$K2S_WA_AUTH_DIR/client.key" ca="$K2S_WA_CA_DIR/ca.crt"
    local work rc=0 rollback=0
    if ! k2s_wa_check_ca "$K2S_WA_CA_DIR"; then
        k2s_wa_error "client CA in '$K2S_WA_CA_DIR' is missing or invalid ($K2S_WA_REASON); renew never replaces it. Run provision first, or replace the CA manually"
        return 1
    fi
    if [[ ! -f "$K2S_WA_MANIFEST" ]]; then
        k2s_wa_error "kube-apiserver manifest '$K2S_WA_MANIFEST' not found; run ensure-apiserver first"
        return 1
    fi
    k2s_wa_manifest_state "$K2S_WA_MANIFEST" || return 1
    case "$K2S_WA_STATE" in
        configured) ;;
        absent)
            k2s_wa_error "kube-apiserver does not use the client certificate yet; run ensure-apiserver first"
            return 1 ;;
        custom)
            k2s_wa_error "kube-apiserver uses another --admission-control-config-file; renew supports only the configuration of ensure-apiserver. Nothing was changed."
            return 3 ;;
        *)
            k2s_wa_error "'$K2S_WA_MANIFEST' contains an incomplete clusterip-webhook admission configuration; correct it manually. Nothing was changed."
            return 3 ;;
    esac
    if [[ -L "$K2S_WA_AUTH_DIR" || ! -d "$K2S_WA_AUTH_DIR" ]]; then
        k2s_wa_error "'$K2S_WA_AUTH_DIR' is not a directory; run provision first"
        return 1
    fi
    k2s_wa_check_auth_dir || return 1
    if ! k2s_wa_is_valid_key "$key"; then
        k2s_wa_error "client key '$key' is missing or invalid; renew keeps the key and never creates one. Run provision"
        return 1
    fi
    if (( ! force )) && k2s_wa_check_client_cert "$crt" "$key" "$ca"; then
        # Nothing to renew: certificate, key and backup stay untouched, and the verification decides the result.
        k2s_wa_log "client certificate '$crt' is valid for more than $((K2S_WA_RENEW_MARGIN / 86400)) days; not renewed (--force renews it anyway); verifying webhook authentication"
        k2s_wa_verify || rc=$?
        if (( rc != 0 )); then
            k2s_wa_error "webhook authentication does not work with the current client certificate ($K2S_WA_VERIFY_RESULT); it is valid, so it was not renewed"
            return "$rc"
        fi
        return 0
    fi
    if k2s_wa_check_client_cert "$crt" "$key" "$ca" 0; then
        k2s_wa_log 'verifying webhook authentication with the current client certificate'
        if ! k2s_wa_verify; then
            k2s_wa_error "webhook authentication does not work with the current client certificate ($K2S_WA_VERIFY_RESULT); not renewing it"
            return 1
        fi
        k2s_wa_backup_client_cert || return 1
        rollback=1
    else
        k2s_wa_log "renewing without a certificate to restore: $K2S_WA_REASON"
        if [[ -e "$K2S_WA_CERT_BACKUP_FILE" ]]; then
            k2s_wa_log "the existing backup '$K2S_WA_CERT_BACKUP_FILE' is kept and not used"
        fi
    fi
    if ! work=$(mktemp -d "$K2S_WA_ROOT/.k2s-webhook-auth-issue.tmp.XXXXXX"); then
        k2s_wa_error "cannot create a temporary directory in '$K2S_WA_ROOT'"
        return 1
    fi
    k2s_wa_renew_client_cert "$work" || rc=$?
    rm -rf -- "$work" "$K2S_WA_AUTH_DIR"/.client.*.tmp.*
    if (( rc != 0 )); then
        k2s_wa_error "cannot renew the kube-apiserver client certificate: $K2S_WA_REASON; '$crt' was not changed"
        return 1
    fi
    k2s_wa_log "renewed kube-apiserver client certificate '$crt'"
    sleep "$K2S_WA_RELOAD_WAIT"
    if k2s_wa_verify; then
        k2s_wa_log 'webhook authentication works with the renewed client certificate'
        return 0
    fi
    if (( ! rollback )); then
        k2s_wa_error "webhook authentication does not work with the renewed client certificate ($K2S_WA_VERIFY_RESULT) and there is no previous certificate to restore; kube-apiserver was not restarted. Check kube-apiserver and the webhook, then run verify"
        return 1
    fi
    k2s_wa_error "webhook authentication does not work with the renewed client certificate ($K2S_WA_VERIFY_RESULT); restoring the previous certificate"
    if ! k2s_wa_restore_client_cert; then
        k2s_wa_error "cannot restore '$crt' from '$K2S_WA_CERT_BACKUP_FILE'; restore it manually"
        return 6
    fi
    sleep "$K2S_WA_RELOAD_WAIT"
    if k2s_wa_verify; then
        k2s_wa_error 'previous client certificate restored; webhook authentication works with it'
        return 5
    fi
    k2s_wa_error "previous client certificate restored, but webhook authentication could not be verified ($K2S_WA_VERIFY_RESULT)"
    return 6
}

main() {
    local cmd="${1:-}" lock_fd='' rc=0 force=0
    local -a tools=(cmp cp find flock grep mkdir mktemp mv rm sed chmod)
    # A lost terminal or SSH session must not end the run (see the header).
    trap '' HUP PIPE
    case "$cmd" in
        provision | ensure-apiserver | publish | verify) (( $# == 1 )) || cmd='' ;;
        renew)
            if (( $# == 2 )) && [[ "$2" == '--force' ]]; then
                force=1
            elif (( $# != 1 )); then
                cmd=''
            fi ;;
        *) cmd='' ;;
    esac
    case "$cmd" in
        provision) tools+=(openssl id stat sync) ;;
        ensure-apiserver) tools+=(openssl kubectl sort comm chown id stat sync) ;;
        publish) tools+=(openssl kubectl) ;;
        verify) tools+=(openssl kubectl timeout awk base64) ;;
        renew) tools+=(openssl kubectl timeout awk base64 chown sync) ;;
        *) k2s_wa_usage; return 2 ;;
    esac
    k2s_wa_require_root || return 4
    k2s_wa_require_tools "${tools[@]}" || return 4
    if [[ "$cmd" == 'verify' ]]; then
        # Read-only: no directory, lock file or cleanup; a shared lock waits for a running change.
        if [[ -f "$K2S_WA_LOCK_FILE" && ! -L "$K2S_WA_LOCK_FILE" ]]; then
            if ! exec {lock_fd}<"$K2S_WA_LOCK_FILE"; then
                k2s_wa_error "cannot open '$K2S_WA_LOCK_FILE'"
                return 1
            fi
            if ! flock -s -w "$K2S_WA_LOCK_TIMEOUT" "$lock_fd"; then
                exec {lock_fd}<&-
                k2s_wa_error 'another clusterip-webhook-auth.sh run holds the lock'
                return 1
            fi
        fi
        k2s_wa_verify || rc=$?
        if [[ -n "$lock_fd" ]]; then exec {lock_fd}<&-; fi
        printf 'K2S-WEBHOOK-AUTH-VERIFY:%s\n' "${K2S_WA_VERIFY_RESULT:-inconclusive}"
        if (( rc == 0 )); then printf 'K2S-WEBHOOK-AUTH-OK:%s\n' "$cmd"; fi
        return "$rc"
    fi
    # shellcheck disable=SC2174 # the parent of the root directory exists (/etc), so -m applies to the only new directory
    if [[ ! -d "$K2S_WA_ROOT" ]] && ! mkdir -p -m 0755 -- "$K2S_WA_ROOT"; then
        k2s_wa_error "cannot create '$K2S_WA_ROOT'"
        return 1
    fi
    umask 077
    if ! exec {lock_fd}>"$K2S_WA_LOCK_FILE"; then
        k2s_wa_error "cannot open '$K2S_WA_LOCK_FILE'"
        return 1
    fi
    if ! flock -w "$K2S_WA_LOCK_TIMEOUT" "$lock_fd"; then
        exec {lock_fd}>&-
        k2s_wa_error 'another clusterip-webhook-auth.sh run holds the lock'
        return 1
    fi
    k2s_wa_cleanup_stale || rc=$?
    if (( rc == 0 )); then
        case "$cmd" in
            provision) k2s_wa_provision || rc=$? ;;
            ensure-apiserver) k2s_wa_ensure_apiserver || rc=$? ;;
            publish) k2s_wa_publish || rc=$? ;;
            renew) k2s_wa_renew "$force" || rc=$? ;;
        esac
    fi
    exec {lock_fd}>&-
    if (( rc == 0 )); then
        printf 'K2S-WEBHOOK-AUTH-OK:%s\n' "$cmd"
    fi
    return "$rc"
}

k2s_wa_init_paths

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    rc=0
    main "$@" || rc=$?
    exit "$rc"
fi
