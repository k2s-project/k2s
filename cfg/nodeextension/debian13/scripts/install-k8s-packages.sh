#!/bin/bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# install-k8s-packages.sh

set -euo pipefail

K8S_DEB_PACKAGES_PATH="${1:?Argument missing: K8sDebPackagesPath}"
PROXY="${2:-}"
REGISTRY_TOKEN="${3:?Argument missing: RegistryToken}"
IS_WSL="${4:-false}"
NO_PROXY="${5:-localhost,127.0.0.1,::1,172.20.0.0/16,172.21.0.0/16,.cluster.local,.svc}"
CONFIGURE_CONTAINER_TOOLING_PROXY="${6:-false}"

echo "[InstallK8s] Starting Kubernetes artifacts installation"
echo "[InstallK8s] Packages path: $K8S_DEB_PACKAGES_PATH"

if [ -n "$PROXY" ]; then
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$PROXY" "$PROXY" \
        | sudo tee /etc/apt/apt.conf.d/90k2s-install-proxy > /dev/null
    trap 'sudo rm -f /etc/apt/apt.conf.d/90k2s-install-proxy' EXIT
fi

# ---------------------------------------------------------------------------
# Validate packages directory
# ---------------------------------------------------------------------------
if ! ls "$K8S_DEB_PACKAGES_PATH" > /dev/null 2>&1; then
    echo "[InstallK8s] ERROR: The directory '$K8S_DEB_PACKAGES_PATH' does not exist. Cannot install Kubernetes artifacts." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Wait for dpkg lock (unattended-upgrades may hold it)
# ---------------------------------------------------------------------------
wait_for_dpkg_lock() {
    local max_wait=300  # 5 minutes
    local waited=0
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [ $waited -ge $max_wait ]; then
            echo "[InstallK8s] ERROR: Timeout waiting for dpkg lock after ${max_wait}s" >&2
            exit 1
        fi
        echo "[InstallK8s] Waiting for dpkg lock (held by another process)..."
        sleep 5
        waited=$((waited + 5))
    done
    if [ $waited -gt 0 ]; then
        echo "[InstallK8s] dpkg lock released after ${waited}s"
    fi
}

wait_for_dpkg_lock

# ---------------------------------------------------------------------------
# Install .deb packages
# ---------------------------------------------------------------------------
echo "[InstallK8s] Installing deb packages from $K8S_DEB_PACKAGES_PATH"
sudo DEBIAN_FRONTEND=noninteractive dpkg -i "$K8S_DEB_PACKAGES_PATH"/*.deb || true
sudo DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y

if ! command -v crictl >/dev/null 2>&1; then
    echo "[InstallK8s] ERROR: crictl is not available after package installation. Ensure cri-tools is included in the Kubernetes artifact set." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Configure bridged traffic (kernel modules + sysctl)
# ---------------------------------------------------------------------------
echo "[InstallK8s] Configuring bridged traffic"
echo overlay   | sudo tee /etc/modules-load.d/k8s.conf
echo br_netfilter | sudo tee /etc/modules-load.d/k8s.conf
sudo modprobe overlay
sudo modprobe br_netfilter

echo 'net.bridge.bridge-nf-call-ip6tables = 1' | sudo tee -a /etc/sysctl.d/k8s.conf
echo 'net.bridge.bridge-nf-call-iptables = 1'  | sudo tee -a /etc/sysctl.d/k8s.conf
echo 'net.ipv4.ip_forward = 1'                  | sudo tee -a /etc/sysctl.d/k8s.conf
sudo sysctl --system

# ---------------------------------------------------------------------------
# Ensure shared mount on reboot
# ---------------------------------------------------------------------------
echo '@reboot root mount --make-rshared /' | sudo tee /etc/cron.d/sharedmount

# ---------------------------------------------------------------------------
# Hold cri-o to prevent unintended upgrades
# ---------------------------------------------------------------------------
sudo apt-mark hold cri-o

# ---------------------------------------------------------------------------
# Configure crictl timeout
# ---------------------------------------------------------------------------
sudo touch /etc/crictl.yaml
if grep -q 'timeout' /etc/crictl.yaml; then
    sudo sed -i 's/timeout.*/timeout: 30/g' /etc/crictl.yaml
else
    echo 'timeout: 30' | sudo tee -a /etc/crictl.yaml
fi

# ---------------------------------------------------------------------------
# Proxy configuration for CRI-O (optional)
# ---------------------------------------------------------------------------
if [ -n "$PROXY" ]; then
    echo "[InstallK8s] Configuring CRI-O proxy: $PROXY"
    sudo mkdir -p /etc/systemd/system/crio.service.d
    sudo touch /etc/systemd/system/crio.service.d/http-proxy.conf
    {
        echo '[Service]'
        echo "Environment='HTTP_PROXY=$PROXY'"
        echo "Environment='HTTPS_PROXY=$PROXY'"
        echo "Environment='http_proxy=$PROXY'"
        echo "Environment='https_proxy=$PROXY'"
        echo "Environment='NO_PROXY=$NO_PROXY'"
        echo "Environment='no_proxy=$NO_PROXY'"
    } | sudo tee /etc/systemd/system/crio.service.d/http-proxy.conf > /dev/null

fi

if [ "$CONFIGURE_CONTAINER_TOOLING_PROXY" = "true" ] && [ -n "$PROXY" ]; then
    # Native Linux K2s uses Buildah and Podman directly on the host. Keep
    # its proxy configuration separate from CRI-O and user configuration.
    echo "[InstallK8s] Configuring containers tooling proxy: $PROXY"
    sudo mkdir -p /etc/containers/containers.conf.d
    {
        echo '# Managed by K2s native Linux installation'
        echo '[engine]'
        echo 'env = ['
        echo "  \"HTTP_PROXY=$PROXY\","
        echo "  \"HTTPS_PROXY=$PROXY\","
        echo "  \"http_proxy=$PROXY\","
        echo "  \"https_proxy=$PROXY\","
        echo "  \"NO_PROXY=$NO_PROXY\","
        echo "  \"no_proxy=$NO_PROXY\""
        echo ']'
    } | sudo tee /etc/containers/containers.conf.d/20-k2s-proxy.conf > /dev/null
else
    # Windows-host Kubemaster provisioning owns Buildah proxy behavior via its
    # established transparent proxy setup. Remove stale native-only state.
    sudo rm -f /etc/containers/containers.conf.d/20-k2s-proxy.conf
fi

# ---------------------------------------------------------------------------
# Container registry authentication (shsk2s.azurecr.io)
# ---------------------------------------------------------------------------
echo "[InstallK8s] Configuring container registry authentication"
cat <<EOF | sudo tee /tmp/auth.json > /dev/null
{
  "auths": {
    "shsk2s.azurecr.io": {
      "auth": "$REGISTRY_TOKEN"
    }
  }
}
EOF
sudo mkdir -p /root/.config/containers
sudo mv /tmp/auth.json /root/.config/containers/auth.json

# ---------------------------------------------------------------------------
# Configure CRI-O: lower priority of default CNI bridge
# ---------------------------------------------------------------------------
echo "[InstallK8s] Configure CRI-O"
# cri-o default cni bridge should have least priority
CRIO_CNI_FILE='/etc/cni/net.d/10-crio-bridge.conf'
if [ -f "$CRIO_CNI_FILE" ]; then
    sudo mv "$CRIO_CNI_FILE" /etc/cni/net.d/100-crio-bridge.conf
else
    echo "[InstallK8s] File does not exist, no renaming of cni file $CRIO_CNI_FILE.."
fi

# Add unqualified-search-registries only if not already present (prevents duplicate entries on retry)
sudo mkdir -p /etc/containers
if ! grep -q '^[[:space:]]*unqualified-search-registries[[:space:]]*=' /etc/containers/registries.conf 2>/dev/null; then
    echo 'unqualified-search-registries = ["docker.io", "quay.io"]' | sudo tee -a /etc/containers/registries.conf
else
    echo "[InstallK8s] unqualified-search-registries already configured in /etc/containers/registries.conf, skipping"
fi

KUBEADM_VERSION="$(kubeadm version -o short)"
KUBEADM_PAUSE_IMAGE="$(kubeadm config images list --kubernetes-version "$KUBEADM_VERSION" | grep '/pause:' | tail -n 1 || true)"
if [ -n "$KUBEADM_PAUSE_IMAGE" ]; then
    echo "[InstallK8s] Configuring CRI-O pause image from kubeadm $KUBEADM_VERSION: $KUBEADM_PAUSE_IMAGE"
    sudo mkdir -p /etc/crio/crio.conf.d
    {
        echo '[crio.image]'
        echo "pause_image = \"$KUBEADM_PAUSE_IMAGE\""
    } | sudo tee /etc/crio/crio.conf.d/20-k2s-kubeadm-pause.conf > /dev/null
    # Reload first: the cri-o package upgrade may have replaced crio.service on disk
    sudo systemctl daemon-reload
    sudo systemctl restart crio || true
else
    echo "[InstallK8s] WARNING: Could not resolve pause image from kubeadm; keeping CRI-O package default"
fi

# ---------------------------------------------------------------------------
# Hold kubelet, kubeadm, kubectl
# ---------------------------------------------------------------------------
sudo apt-mark hold kubelet kubeadm kubectl cri-tools

# ---------------------------------------------------------------------------
# Start CRI-O
# ---------------------------------------------------------------------------
echo "[InstallK8s] Starting CRI-O"
sudo systemctl daemon-reload
sudo systemctl enable crio || true
sudo systemctl start crio

# ---------------------------------------------------------------------------
# WSL-specific CRI-O fix (optional)
# ---------------------------------------------------------------------------
if [ "$IS_WSL" = "true" ]; then
    echo "[InstallK8s] Applying CRI-O WSL fix"
    CONFIG_WSL='/etc/crio/crio.conf.d/20-wsl.conf'
    {
        echo '[crio.runtime]'
        echo 'add_inheritable_capabilities=true'
        echo 'default_sysctls=["net.ipv4.ip_unprivileged_port_start=0"]'
    } | sudo tee -a "$CONFIG_WSL" > /dev/null
    sudo systemctl restart crio
fi

echo "[InstallK8s] Kubernetes artifacts installation completed successfully"
