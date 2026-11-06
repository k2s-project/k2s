#!/bin/bash
# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Installs the bundled Linux CLI tools into /usr/local/bin of the control-plane node.
# Currently: yq, helm, krew.
#
# Executed by Install-CliToolsOnKubeMaster at base-image build time, so the tools are baked into the
# base image and offline installations require no downloads. Every tool block is guarded by
# 'command -v' and is therefore idempotent. To add a further tool, append a new guarded block below.
set -e


# Try to get proxy from apt or environment
PROXY=""
if [ -f /etc/apt/apt.conf.d/proxy.conf ]; then
    PROXY=$(grep -i 'Acquire::http::Proxy' /etc/apt/apt.conf.d/proxy.conf | awk -F'"' '{print $2}')
fi
if [ -z "$PROXY" ] && grep -qi 'http_proxy' /etc/environment; then
    PROXY=$(grep -i 'http_proxy' /etc/environment | awk -F'=' '{print $2}' | tr -d '"')
fi

echo "Proxy detected: $PROXY"

# Set curl proxy option if proxy is set
CURL_PROXY_OPT=""
if [ -n "$PROXY" ]; then
    CURL_PROXY_OPT="--proxy $PROXY"
fi

# Install yq
# Keep YQ_VERSION in sync with the yq download URL in
# lib/modules/windows/node/k2s.node.module/windowsnode/downloader/artifacts/yaml-tools/yaml-tools.module.psm1
if ! command -v yq &> /dev/null; then
    echo "Installing yq..."
    YQ_VERSION="v4.53.4"
    ARCH=$(uname -m)
    # yq release artifacts use Go's architecture names: yq_linux_amd64 / yq_linux_arm64.
    # 'uname -m' reports x86_64 / aarch64, so both have to be normalized or the download 404s.
    if [[ "$ARCH" == "x86_64" ]]; then
        ARCH="amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        ARCH="arm64"
    fi
    sudo curl -fL $CURL_PROXY_OPT -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" --silent
    sudo chmod +x /usr/local/bin/yq
    yq --version
else
    echo "yq already installed"
fi

# Install helm
# Keep HELM_VERSION in sync with the helm download URL in
# lib/modules/windows/node/k2s.node.module/windowsnode/downloader/artifacts/helm/helm.module.psm1
if ! command -v helm &> /dev/null; then
    echo "Installing helm..."
    HELM_VERSION="v4.3.1"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        ARCH="amd64"
    fi
    curl -fL $CURL_PROXY_OPT -o "helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" --silent
    tar -xzf "helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
    sudo mv "linux-${ARCH}/helm" /usr/local/bin/helm
    sudo chmod +x /usr/local/bin/helm
    rm -rf "helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" "linux-${ARCH}"
    helm version
else
    echo "helm already installed"
fi

# Install krew (kubectl plugin manager - https://krew.sigs.k8s.io/).
# The binary must be named 'kubectl-krew' so that kubectl discovers it on PATH and exposes it as the
# 'kubectl krew' subcommand. Keep KREW_VERSION in sync with $windowsNode_KrewVersion in
# lib/modules/windows/node/k2s.node.module/windowsnode/downloader/artifacts/krew/krew.module.psm1.
if ! command -v kubectl-krew &> /dev/null; then
    echo "Installing krew..."
    KREW_VERSION="v0.5.0"
    ARCH=$(uname -m)
    # Krew release artifacts use Go's architecture names: krew-linux_amd64 / krew-linux_arm64.
    # 'uname -m' reports x86_64 / aarch64, so both have to be normalized or the download 404s.
    if [[ "$ARCH" == "x86_64" ]]; then
        ARCH="amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        ARCH="arm64"
    fi
    curl -fL $CURL_PROXY_OPT -o "krew-linux_${ARCH}.tar.gz" "https://github.com/kubernetes-sigs/krew/releases/download/${KREW_VERSION}/krew-linux_${ARCH}.tar.gz" --silent
    tar -xzf "krew-linux_${ARCH}.tar.gz" "./krew-linux_${ARCH}"
    sudo mv "krew-linux_${ARCH}" /usr/local/bin/kubectl-krew
    sudo chmod +x /usr/local/bin/kubectl-krew
    rm -rf "krew-linux_${ARCH}.tar.gz"
    # Only verify that the binary was installed and is executable. Running 'kubectl-krew version'
    # here would execute krew as root during image build and could create root-owned Krew state.
    test -x /usr/local/bin/kubectl-krew
else
    echo "krew already installed"
fi

# Krew installs plugins into the per-user directory $HOME/.krew/bin, so that directory must be on PATH
# for installed plugins to be discoverable. Plugins themselves are user-managed - K2s never installs
# them and never touches $HOME/.krew. Determine the invoking (non-root) user because this script runs
# under sudo.
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [ -n "$TARGET_HOME" ]; then
    PROFILE_FILE="$TARGET_HOME/.profile"
    # Guarded append keeps the operation idempotent across re-runs and upgrades.
    if ! grep -q '.krew/bin' "$PROFILE_FILE" 2>/dev/null; then
        echo "Adding \$HOME/.krew/bin to PATH in $PROFILE_FILE"
        echo 'export PATH="$HOME/.krew/bin:$PATH"' | sudo tee -a "$PROFILE_FILE" > /dev/null
        sudo chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$PROFILE_FILE"
    else
        echo "\$HOME/.krew/bin already on PATH in $PROFILE_FILE"
    fi
fi
