#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

if [[ -n ${K2S_NODE_PACKAGES_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_NODE_PACKAGES_SH_LOADED=1

k2s_wait_for_dpkg_lock() {
  local timeout_seconds="${1:-300}"
  local deadline=$((SECONDS + timeout_seconds))

  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      k2s_log ERROR "Timed out waiting for the Debian package manager lock after ${timeout_seconds}s"
      return 1
    fi
    k2s_log INFO 'Waiting for the Debian package manager lock.'
    sleep 5
  done
}

k2s_install_debian_packages() {
  local package_directory="$1"
  k2s_require_directory "$package_directory" || return 1
  k2s_wait_for_dpkg_lock || return 1
  k2s_run env DEBIAN_FRONTEND=noninteractive dpkg -i "$package_directory"/*.deb || true
  k2s_run env DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y
}

k2s_packages_install() {
  local version token gateway
  version=$(sed -n "/function Get-DefaultK8sVersion/,/^}/s/.*return ['\"]\(v[0-9][0-9.]*\)['\"].*/\1/p" "$K2S_INSTALL_DIR/lib/modules/windows/infra/k2s.infra.module/config/config.module.psm1" | head -1)
  token=$(tr -d '\r\n[:space:]' < "$K2S_INSTALL_DIR/bin/registry.dat")
  token=${token#$'\xEF\xBB\xBF'}
  printf '%s' "$token" | base64 -d >/dev/null 2>&1 || { k2s_log ERROR 'Packaged registry credential is not valid Base64.'; return 1; }
  gateway=$(k2s_cfg '.smallsetup.kubeSwitch')
  [[ -n "$token" && -n "$version" ]] || return 1
  K2S_VERSION="$version"
  export K2S_VERSION
  k2s_log INFO "Provisioning Kubernetes version $K2S_VERSION."
  mkdir -p "$K2S_CONFIG_DIR/packages"
  chmod 700 "$K2S_CONFIG_DIR/packages"
  "$K2S_INSTALL_DIR/lib/scripts/linux/debian/linuxonly/ProvisionPackages.sh" download "$K2S_CONFIG_DIR/packages" "$version" "http://$gateway:8181" || return 1
  "$K2S_INSTALL_DIR/lib/scripts/linux/debian/linuxonly/ProvisionPackages.sh" install "$K2S_CONFIG_DIR/packages" "http://$gateway:8181" "$token" false "$K2S_NO_PROXY" true || return 1
  command -v kubeadm kubectl crictl crio buildah >/dev/null || return 1
  systemctl enable --now crio || return 1
  crictl --runtime-endpoint unix:///var/run/crio/crio.sock version || return 1
  [[ $(kubeadm version -o short) == "$K2S_VERSION" ]] || return 1
  mkdir -p /var/log/kubelet /etc/systemd/system/kubelet.service.d
  printf '[Service]\nStandardOutput=append:/var/log/kubelet/kubelet.log\nStandardError=append:/var/log/kubelet/kubelet.log\n' > /etc/systemd/system/kubelet.service.d/20-k2s-logging.conf
  systemctl daemon-reload
}
