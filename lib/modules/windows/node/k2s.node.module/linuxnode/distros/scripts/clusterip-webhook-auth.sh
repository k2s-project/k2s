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
#
# Exit codes: 0 success, 1 failure, 2 usage, 3 conflict (nothing changed), 4 missing prerequisite,
# 5 previous manifest restored and kube-apiserver recovered, 6 kube-apiserver recovery not verified.
# Only on success the last line printed is K2S-WEBHOOK-AUTH-OK:<command>.
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
K2S_WA_PROC_DIR='/proc'
K2S_WA_REASON=''
K2S_WA_STATE=''
K2S_WA_PROC_STATES=''
# One line per container argument, volume mount and volume of a static Pod manifest.
# shellcheck disable=SC2016 # Go template variables, not shell expansions
K2S_WA_STATE_TEMPLATE='{{range .spec.containers}}{{$c := .name}}{{range .command}}C|{{$c}}|{{.}}{{"\n"}}{{end}}{{range .args}}A|{{$c}}|{{.}}{{"\n"}}{{end}}{{range .volumeMounts}}M|{{$c}}|{{.name}}|{{.mountPath}}|{{.readOnly}}{{"\n"}}{{end}}{{end}}{{range .spec.volumes}}V|{{.name}}|{{with .hostPath}}{{.path}}|{{.type}}{{end}}{{"\n"}}{{end}}'
# shellcheck disable=SC2016 # Go template variables, not shell expansions
K2S_WA_CONFIGMAP_TEMPLATE='{{.kind}}|{{.metadata.namespace}}|{{.metadata.name}}{{"\n"}}{{range $k, $v := .data}}data/{{$k}}{{"\n"}}{{end}}{{range $k, $v := .binaryData}}binaryData/{{$k}}{{"\n"}}{{end}}'

k2s_wa_log() { printf '[ClusterIPWebhookAuth] %s\n' "$*"; }
k2s_wa_error() { printf '[ClusterIPWebhookAuth] ERROR: %s\n' "$*"; }
k2s_wa_kubectl() { kubectl --kubeconfig "$K2S_WA_ADMIN_KUBECONFIG" "$@"; }
k2s_wa_kubectl_local() { KUBECONFIG=/dev/null kubectl "$@"; }
k2s_wa_usage() { printf 'Usage: %s provision|ensure-apiserver|publish\n' "${0##*/}"; }

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
    local dir="$1" constraints out
    K2S_WA_REASON=''
    [[ -f "$dir/ca.crt" && -f "$dir/ca.key" ]] || { K2S_WA_REASON='ca.crt or ca.key is missing'; return 1; }
    k2s_wa_is_single_cert "$dir/ca.crt" || { K2S_WA_REASON='ca.crt is not a single PEM certificate'; return 1; }
    constraints=$(openssl x509 -in "$dir/ca.crt" -noout -ext basicConstraints 2>/dev/null) || constraints=''
    [[ "$constraints" == *'CA:TRUE'* ]] || { K2S_WA_REASON='ca.crt is not a CA certificate'; return 1; }
    if ! out=$(openssl verify -trusted "$dir/ca.crt" -check_ss_sig "$dir/ca.crt" 2>&1); then
        K2S_WA_REASON="ca.crt is not valid: ${out//$'\n'/ }"
        return 1
    fi
    if ! openssl x509 -in "$dir/ca.crt" -noout -checkend "$K2S_WA_CA_MARGIN" >/dev/null 2>&1; then
        K2S_WA_REASON="ca.crt expires within $((K2S_WA_CA_MARGIN / 86400)) days"
        return 1
    fi
    k2s_wa_is_valid_key "$dir/ca.key" || { K2S_WA_REASON='ca.key is not a valid unencrypted private key'; return 1; }
    k2s_wa_key_matches "$dir/ca.crt" "$dir/ca.key" || { K2S_WA_REASON='ca.key does not belong to ca.crt'; return 1; }
}

k2s_wa_check_client_cert() {
    local crt="$1" key="$2" ca="$3" usage constraints out
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
    if ! openssl x509 -in "$crt" -noout -checkend "$K2S_WA_RENEW_MARGIN" >/dev/null 2>&1; then
        K2S_WA_REASON="client certificate expires within $((K2S_WA_RENEW_MARGIN / 86400)) days"
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
    if ! cp -p -- "$K2S_WA_MANIFEST" "$tmp" || ! cmp -s -- "$K2S_WA_MANIFEST" "$tmp" || ! mv -f -- "$tmp" "$K2S_WA_BACKUP_FILE"; then
        rm -f -- "$tmp"
        k2s_wa_error "cannot back up '$K2S_WA_MANIFEST' to '$K2S_WA_BACKUP_FILE'"
        return 1
    fi
    k2s_wa_log "backed up '$K2S_WA_MANIFEST' to '$K2S_WA_BACKUP_FILE'"
}

k2s_wa_restore_manifest() {
    local tmp
    tmp=$(mktemp "$K2S_WA_MANIFEST_DIR/.kube-apiserver.yaml.k2s-webhook-auth.XXXXXX") || return 1
    if ! cp -p -- "$K2S_WA_BACKUP_FILE" "$tmp" || ! cmp -s -- "$K2S_WA_BACKUP_FILE" "$tmp" || ! mv -f -- "$tmp" "$K2S_WA_MANIFEST"; then
        rm -f -- "$tmp"
        return 1
    fi
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
    if ! chmod --reference="$K2S_WA_MANIFEST" -- "$staged" || ! chown --reference="$K2S_WA_MANIFEST" -- "$staged" ||
        ! mv -f -- "$staged" "$K2S_WA_MANIFEST"; then
        k2s_wa_error "cannot replace '$K2S_WA_MANIFEST'"
        return 1
    fi
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
    return "$rc"
}

# --- CA publication ---

# Checks that the ConfigMap in file $1 is ours and contains exactly ca.crt with the local CA certificate.
k2s_wa_check_configmap() {
    local file="$1" summary value expected
    local nl=$'\n'
    K2S_WA_REASON=''
    summary=$(k2s_wa_kubectl_local patch --local -f "$file" --type=json -p '[]' -o "go-template=$K2S_WA_CONFIGMAP_TEMPLATE") ||
        { K2S_WA_REASON='cannot parse the ConfigMap'; return 1; }
    value=$(k2s_wa_kubectl_local patch --local -f "$file" --type=json -p '[]' -o 'jsonpath={.data.ca\.crt}') ||
        { K2S_WA_REASON='cannot read ca.crt from the ConfigMap'; return 1; }
    expected=$(<"$K2S_WA_CA_DIR/ca.crt") || { K2S_WA_REASON='cannot read the local CA certificate'; return 1; }
    if [[ "$summary" != "ConfigMap|$K2S_WA_NAMESPACE|$K2S_WA_CONFIGMAP${nl}data/ca.crt" ]]; then
        K2S_WA_REASON="unexpected object or keys: ${summary//$nl/ }"
        return 1
    fi
    [[ "$value" == "$expected" ]] || { K2S_WA_REASON='ca.crt differs from the local CA certificate'; return 1; }
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

main() {
    local cmd="${1:-}" lock_fd rc=0
    local -a tools=(cmp cp find flock grep mkdir mktemp mv rm sed chmod)
    if (( $# != 1 )); then
        k2s_wa_usage
        return 2
    fi
    case "$cmd" in
        provision) tools+=(openssl) ;;
        ensure-apiserver) tools+=(openssl kubectl sort comm chown) ;;
        publish) tools+=(openssl kubectl) ;;
        *) k2s_wa_usage; return 2 ;;
    esac
    k2s_wa_require_root || return 4
    k2s_wa_require_tools "${tools[@]}" || return 4
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
