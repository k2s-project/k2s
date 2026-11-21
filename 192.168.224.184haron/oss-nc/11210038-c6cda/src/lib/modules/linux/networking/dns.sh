#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

if [[ -n ${K2S_DNS_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_DNS_SH_LOADED=1

readonly K2S_DNS_RESOLVED_DROP_IN='/etc/systemd/resolved.conf.d/20-k2s-dns.conf'

k2s_configure_systemd_resolved_dns() {
  local dns_server="$1"
  local dns_domain="$2"
  local content="[Resolve]
DNS=$dns_server
Domains=$dns_domain"

  k2s_write_managed_file "$K2S_DNS_RESOLVED_DROP_IN" 0644 "$content"
  k2s_run systemctl restart systemd-resolved
}

k2s_remove_systemd_resolved_dns() {
  if [[ -f "$K2S_DNS_RESOLVED_DROP_IN" ]]; then
    rm -f "$K2S_DNS_RESOLVED_DROP_IN"
    k2s_log INFO "Removed managed DNS configuration: $K2S_DNS_RESOLVED_DROP_IN"
    k2s_run systemctl restart systemd-resolved
  fi
}

k2s_save_resolver() {
  local mode immutable
  [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]] || return 1
  mode=$(stat -c '%a' /etc/resolv.conf) || return 1
  immutable=false
  lsattr -d /etc/resolv.conf 2>/dev/null | grep -q 'i' && immutable=true
  if [[ -L /etc/resolv.conf ]]; then
    jq -n --arg target "$(readlink /etc/resolv.conf)" --arg mode "$mode" --argjson immutable "$immutable" '{type:"symlink",target:$target,mode:$mode,immutable:$immutable}' > "$K2S_CONFIG_DIR/dns-resolver-state.json"
  else
    jq -n --rawfile content /etc/resolv.conf --arg mode "$mode" --argjson immutable "$immutable" '{type:"file",content:$content,mode:$mode,immutable:$immutable}' > "$K2S_CONFIG_DIR/dns-resolver-state.json"
  fi
  chmod 600 "$K2S_CONFIG_DIR/dns-resolver-state.json"
}

k2s_restore_resolver() {
  local state="$K2S_CONFIG_DIR/dns-resolver-state.json" mode
  [[ -f "$state" ]] || return 0
  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/resolv.conf
  if [[ $(jq -r '.type' "$state") == symlink ]]; then
    ln -s "$(jq -r '.target' "$state")" /etc/resolv.conf
  else
    jq -r '.content' "$state" > /etc/resolv.conf
    mode=$(jq -r '.mode // "644"' "$state")
    chmod "$mode" /etc/resolv.conf
  fi
  [[ $(jq -r '.immutable // false' "$state") == true ]] && chattr +i /etc/resolv.conf || true
}

k2s_dns_start() {
  local gateway dns zones upstreams
  gateway=$(k2s_cfg '.smallsetup.kubeSwitch')
  k2s_kubectl -n kube-system rollout status deployment/coredns --timeout=120s || return 1
  dns=$(k2s_kubectl -n kube-system get service kube-dns -o jsonpath='{.spec.clusterIP}')
  zones=$(k2s_kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | awk '/kubernetes / {for(i=2;i<=NF;i++)if($i!="{")print $i}')
  upstreams=$(resolvectl dns 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u || grep -E '^nameserver ' /etc/resolv.conf | awk '{print $2}')
  [[ -n "$dns" && -n "$zones" && -n "$upstreams" && -x "$K2S_INSTALL_DIR/bin/dnsproxy" ]] || return 1
  mkdir -p /etc/k2s /var/log/dnsproxy
  { printf '%s\n' '---' 'listen-addrs:' '  - "127.0.0.1"' "  - \"$gateway\"" 'listen-ports:' '  - 53' 'upstream:'; for zone in $zones; do printf '  - "[/%s/]%s"\n' "${zone%.}" "$dns"; done; for upstream in $upstreams; do printf '  - "%s"\n' "$upstream"; done; } > /etc/k2s/dnsproxy.yaml
  cat > /etc/systemd/system/k2s-dnsproxy.service <<EOF
[Unit]
Description=K2s DNS proxy
After=network-online.target kubelet.service
[Service]
Type=simple
ExecStart=$K2S_INSTALL_DIR/bin/dnsproxy --config-path=/etc/k2s/dnsproxy.yaml
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || return 1
  systemctl enable --now k2s-dnsproxy || return 1
  printf '# Managed by K2s native Linux installation; restored by k2s stop or uninstall\nnameserver 127.0.0.1\n' > /etc/resolv.conf
  mkdir -p /etc/systemd/resolved.conf.d
  printf '# Managed by K2s native Linux installation\n[Resolve]\nDNS=127.0.0.1\nDomains=~.\n' > /etc/systemd/resolved.conf.d/20-k2s-dns.conf
  systemctl restart systemd-resolved || true
}

k2s_dns_stop() {
  rm -f /etc/systemd/resolved.conf.d/20-k2s-dns.conf
  systemctl stop k2s-dnsproxy 2>/dev/null || true
  systemctl restart systemd-resolved 2>/dev/null || true
  k2s_restore_resolver
}
