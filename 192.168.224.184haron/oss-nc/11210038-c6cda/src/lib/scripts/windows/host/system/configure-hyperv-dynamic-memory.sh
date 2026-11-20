#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Configure Hyper-V Dynamic Memory support for Debian/Ubuntu VMs
# - Installs hyperv-daemons, loads hv_balloon module
# - Enables automatic memory hotplug (auto_online_blocks)
# - Creates persistent systemd service for boot-time configuration

set -euo pipefail

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly LOG_PREFIX="[HyperV-DynMem]"
readonly SYSTEMD_SERVICE_NAME="auto-online-memory.service"
readonly SYSTEMD_SERVICE_PATH="/etc/systemd/system/${SYSTEMD_SERVICE_NAME}"
readonly AUTO_ONLINE_PATH="/sys/devices/system/memory/auto_online_blocks"
readonly MODULES_CONF="/etc/modules-load.d/hyperv.conf"

log_info() {
    echo "${LOG_PREFIX} [INFO] $*"
}

log_warn() {
    echo "${LOG_PREFIX} [WARN] $*"
}

log_error() {
    echo "${LOG_PREFIX} [ERROR] $*" >&2
}

log_success() {
    echo "${LOG_PREFIX} [SUCCESS] $*"
}


check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_hyperv_platform() {
    local vendor=""

    if [[ -f /sys/class/dmi/id/sys_vendor ]]; then
        vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "unknown")
    fi

    if [[ "${vendor}" == *"Microsoft"* ]] || [[ -d /sys/bus/vmbus ]]; then
        log_info "Detected Hyper-V virtualization platform"
        return 0
    else
        log_warn "Not running on Hyper-V (vendor: ${vendor})"
        log_warn "Configuration will proceed but may not take effect"
        return 0
    fi
}

install_hyperv_daemons() {
    log_info "Checking hyperv-daemons package..."

    if dpkg -l 2>/dev/null | grep -q "^ii.*hyperv-daemons"; then
        log_info "hyperv-daemons already installed"
        return 0
    fi

    log_info "Installing hyperv-daemons package..."

    if DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing hyperv-daemons 2>&1; then
        log_success "hyperv-daemons installed successfully"
    else
        log_warn "Failed to install hyperv-daemons package"
        log_warn "Configuration will continue - hv_balloon may be built into kernel"
        return 0
    fi
}

load_hv_balloon_module() {
    log_info "Checking hv_balloon kernel module..."

    if lsmod | grep -q "^hv_balloon"; then
        log_info "hv_balloon module already loaded"
        return 0
    fi

    if [[ -d /sys/bus/vmbus/drivers/hv_balloon ]] || [[ -f /sys/bus/vmbus/drivers/hv_balloon/bind ]]; then
        log_info "hv_balloon is built into kernel (not a loadable module)"
        log_success "hv_balloon functionality available"
        return 0
    fi

    log_info "Loading hv_balloon kernel module..."

    if modprobe hv_balloon 2>/dev/null; then
        log_success "hv_balloon module loaded successfully"
    else
        log_warn "Failed to load hv_balloon module"
        log_warn "Dynamic memory may still work if built into kernel"
        return 0
    fi
}

ensure_hv_balloon_persistent() {
    log_info "Ensuring hv_balloon loads at boot..."

    if [[ -f "${MODULES_CONF}" ]] && grep -q "^hv_balloon" "${MODULES_CONF}"; then
        log_info "hv_balloon already configured for boot"
        return 0
    fi

    mkdir -p "$(dirname "${MODULES_CONF}")"

    if echo "hv_balloon" >> "${MODULES_CONF}"; then
        log_success "hv_balloon configured to load at boot"
    else
        log_warn "Failed to configure hv_balloon for boot (non-critical)"
    fi
}

enable_auto_online_blocks() {
    log_info "Configuring automatic memory hotplug..."

    if [[ ! -f "${AUTO_ONLINE_PATH}" ]]; then
        log_warn "auto_online_blocks not available (kernel may be too old)"
        log_warn "Dynamic memory hotplug will require manual intervention"
        return 0
    fi

    local current_value
    current_value=$(cat "${AUTO_ONLINE_PATH}" 2>/dev/null || echo "unknown")

    if [[ "${current_value}" == "online" ]]; then
        log_info "auto_online_blocks already set to 'online'"
        return 0
    fi

    log_info "Setting auto_online_blocks to 'online' (was: ${current_value})..."

    if echo "online" > "${AUTO_ONLINE_PATH}"; then
        log_success "auto_online_blocks enabled successfully"
    else
        log_error "Failed to enable auto_online_blocks"
        return 1
    fi
}

create_systemd_service() {
    log_info "Creating systemd service for persistent configuration..."

    cat > "${SYSTEMD_SERVICE_PATH}" <<'EOF'
[Unit]
Description=Hyper-V Dynamic Memory Auto-Online Configuration
Documentation=https://www.kernel.org/doc/html/latest/admin-guide/mm/memory-hotplug.html
After=local-fs.target
Before=kubelet.service containerd.service
ConditionPathExists=/sys/devices/system/memory/auto_online_blocks

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'echo online > /sys/devices/system/memory/auto_online_blocks'
ExecStart=/bin/bash -c 'modprobe -q hv_balloon || true'
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    if [[ ! -f "${SYSTEMD_SERVICE_PATH}" ]]; then
        log_error "Failed to create systemd service file"
        return 1
    fi

    log_success "Systemd service file created"
}

enable_systemd_service() {
    log_info "Enabling and starting systemd service..."

    if ! systemctl daemon-reload 2>&1; then
        log_error "Failed to reload systemd daemon"
        return 1
    fi

    if systemctl enable "${SYSTEMD_SERVICE_NAME}" 2>&1; then
        log_success "Service enabled for boot"
    else
        log_error "Failed to enable service"
        return 1
    fi

    if systemctl start "${SYSTEMD_SERVICE_NAME}" 2>&1; then
        log_success "Service started successfully"
    else
        log_warn "Service start failed (may already be running or not needed)"
    fi
}

verify_configuration() {
    log_info "Verifying configuration..."

    local all_ok=true

    if dpkg -l 2>/dev/null | grep -q "^ii.*hyperv-daemons"; then
        log_success "✓ hyperv-daemons package installed"
    else
        log_info "ℹ hyperv-daemons package not installed (may not be needed)"
    fi

    if lsmod | grep -q "^hv_balloon"; then
        log_success "✓ hv_balloon module loaded"
    elif [[ -d /sys/bus/vmbus/drivers/hv_balloon ]] || [[ -f /sys/bus/vmbus/drivers/hv_balloon/bind ]]; then
        log_success "✓ hv_balloon functionality available (built into kernel)"
    else
        log_warn "⚠ hv_balloon not detected (may affect dynamic memory)"
    fi

    if [[ -f "${AUTO_ONLINE_PATH}" ]]; then
        local value
        value=$(cat "${AUTO_ONLINE_PATH}" 2>/dev/null || echo "unknown")
        if [[ "${value}" == "online" ]]; then
            log_success "✓ auto_online_blocks = online"
        else
            log_warn "✗ auto_online_blocks = ${value} (expected: online)"
            all_ok=false
        fi
    else
        log_warn "✗ auto_online_blocks not available on this kernel"
        all_ok=false
    fi

    if systemctl is-enabled "${SYSTEMD_SERVICE_NAME}" &>/dev/null; then
        log_success "✓ systemd service enabled"
    else
        log_warn "✗ systemd service not enabled"
        all_ok=false
    fi

    if systemctl is-active "${SYSTEMD_SERVICE_NAME}" &>/dev/null; then
        log_success "✓ systemd service active"
    else
        log_warn "✗ systemd service not active"
    fi

    if [[ "${all_ok}" == true ]]; then
        log_success "All critical checks passed"
        return 0
    else
        log_warn "Some checks failed - review warnings above"
        return 0
    fi
}

main() {
    log_info "Starting Hyper-V Dynamic Memory configuration for K2s"
    echo ""

    check_root
    check_hyperv_platform
    echo ""

    install_hyperv_daemons
    echo ""

    load_hv_balloon_module
    ensure_hv_balloon_persistent
    echo ""

    enable_auto_online_blocks
    echo ""

    create_systemd_service
    enable_systemd_service
    echo ""

    verify_configuration
    echo ""

    log_success "Hyper-V Dynamic Memory configuration completed successfully"
    log_success "Configuration is persistent across reboots"

    return 0
}

main "$@"

