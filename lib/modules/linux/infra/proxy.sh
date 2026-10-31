#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

if [[ -n ${K2S_PROXY_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_PROXY_SH_LOADED=1

readonly K2S_APT_PROXY_CONFIG='/etc/apt/apt.conf.d/proxy.conf'
readonly K2S_APT_PROXY_BACKUP='apt-proxy.conf.pre-k2s'
readonly K2S_APT_PROXY_HEADER='# Managed by K2s native Linux installation'

k2s_proxy_network_install() {
  local address cidr
  address=$(k2s_cfg '.smallsetup.kubeSwitch')
  cidr=$(k2s_cfg '.smallsetup.masterNetworkCIDR')
  if [[ ${K2S_LINUX_ONLY:-true} != true ]]; then
    k2s_windows_worker_network_create
    return $?
  fi
  if ip -o -4 addr show | grep -Fq "$address/" && ! ip -o -4 addr show dev k2s-proxy0 | grep -Fq "$address/"; then
    k2s_log ERROR "Configured KubeSwitch address is already used: $address"
    return 5
  fi

  cat > /etc/systemd/system/k2s-proxy-network.service <<EOF
[Unit]
Description=K2s Linux-only proxy compatibility network
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -ec '/usr/sbin/ip link show k2s-proxy0 >/dev/null 2>&1 || /usr/sbin/ip link add k2s-proxy0 type dummy; /usr/sbin/ip addr replace $address/${cidr#*/} dev k2s-proxy0; /usr/sbin/ip link set k2s-proxy0 up'
ExecStop=/usr/sbin/ip link delete k2s-proxy0
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || return 1
  systemctl enable --now k2s-proxy-network
  systemctl restart k2s-proxy-network || return 1
}

k2s_proxy_install() {
  local gateway pod service primary args network_dependencies
  gateway=$(k2s_cfg '.smallsetup.kubeSwitch')
  pod=$(k2s_cfg '.smallsetup.podNetworkCIDR')
  service=$(k2s_cfg '.smallsetup.servicesCIDR')
  primary=$(ip -4 route get 1.1.1.1 | awk '/src/ {for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')
  [[ -x "$K2S_INSTALL_DIR/bin/httpproxy" && -n "$primary" ]] || return 1

  args="--addr :8181 --allowed-cidr 127.0.0.0/8 --allowed-cidr $pod --allowed-cidr $service --allowed-cidr $(k2s_cfg '.smallsetup.masterNetworkCIDR') --allowed-cidr $primary/32 --allowed-cidr 10.88.0.0/16"
  [[ -n "$K2S_PROXY" ]] && args="$args --forwardproxy $K2S_PROXY"
  network_dependencies='After=network-online.target'
  [[ ${K2S_LINUX_ONLY:-true} == true ]] && network_dependencies='After=network-online.target k2s-proxy-network.service
Requires=k2s-proxy-network.service'
  mkdir -p /var/log/httpproxy /etc/apt/apt.conf.d "$K2S_CONFIG_DIR"
  if [[ -f "$K2S_APT_PROXY_CONFIG" ]] && ! grep -Fq "$K2S_APT_PROXY_HEADER" "$K2S_APT_PROXY_CONFIG"; then
    local backup="$K2S_CONFIG_DIR/$K2S_APT_PROXY_BACKUP"
    [[ ! -e "$backup" ]] || { k2s_log ERROR "Refusing to overwrite existing apt proxy backup: $backup"; return 5; }
    cp "$K2S_APT_PROXY_CONFIG" "$backup" || return 1
    chmod 600 "$backup"
  fi
  cat > /etc/systemd/system/k2s-httpproxy.service <<EOF
[Unit]
Description=K2s local HTTP proxy
$network_dependencies
[Service]
Type=simple
ExecStart=$K2S_INSTALL_DIR/bin/httpproxy $args
Environment="NO_PROXY=$K2S_NO_PROXY"
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  printf '%s\nAcquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$K2S_APT_PROXY_HEADER" "http://$gateway:8181" "http://$gateway:8181" > "$K2S_APT_PROXY_CONFIG"
  systemctl daemon-reload || return 1
  systemctl enable --now k2s-httpproxy
  systemctl restart k2s-httpproxy || return 1
}

k2s_proxy_cleanup() {
  systemctl disable --now k2s-httpproxy 2>/dev/null || true
  rm -f /etc/systemd/system/k2s-httpproxy.service
  rm -f /etc/systemd/system/crio.service.d/http-proxy.conf /etc/containers/containers.conf.d/20-k2s-proxy.conf

  if [[ -f "$K2S_APT_PROXY_CONFIG" ]] && grep -Fq "$K2S_APT_PROXY_HEADER" "$K2S_APT_PROXY_CONFIG"; then
    local backup="$K2S_CONFIG_DIR/$K2S_APT_PROXY_BACKUP"
    if [[ -f "$backup" ]]; then
      cp "$backup" "$K2S_APT_PROXY_CONFIG" || k2s_log WARN "Could not restore apt proxy configuration from $backup"
      rm -f "$backup"
    else
      rm -f "$K2S_APT_PROXY_CONFIG"
    fi
  fi

  if [[ ${K2S_LINUX_ONLY:-true} == true ]]; then
    systemctl disable --now k2s-proxy-network 2>/dev/null || true
    rm -f /etc/systemd/system/k2s-proxy-network.service
    ip link delete k2s-proxy0 2>/dev/null || true
  fi
  systemctl daemon-reload || true
}
