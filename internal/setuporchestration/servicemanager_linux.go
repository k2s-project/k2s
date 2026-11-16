// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package setuporchestration

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
)

// SystemdServiceManager implements ServiceManager using systemd on Linux.
type SystemdServiceManager struct{}

// NewServiceManager returns a systemd-backed service manager for Linux hosts.
func NewServiceManager() ServiceManager {
	return &SystemdServiceManager{}
}

func (m *SystemdServiceManager) StartService(name string) error {
	slog.Debug("[ServiceManager] Starting service", "name", name)
	return runCommand("systemctl", "start", name)
}

func (m *SystemdServiceManager) StopService(name string) error {
	slog.Debug("[ServiceManager] Stopping service", "name", name)
	return runCommand("systemctl", "stop", name)
}

func (m *SystemdServiceManager) RestartService(name string) error {
	slog.Debug("[ServiceManager] Restarting service", "name", name)
	return runCommand("systemctl", "restart", name)
}

func (m *SystemdServiceManager) IsServiceRunning(name string) (bool, error) {
	output, err := runCommandOutput("systemctl", "is-active", name)
	if err != nil {
		// systemctl exits non-zero when the service is not active
		return false, nil
	}
	return strings.TrimSpace(output) == "active", nil
}

func (m *SystemdServiceManager) InstallService(config ServiceConfig) error {
	slog.Info("[ServiceManager] Installing systemd service", "name", config.Name, "binary", config.BinaryPath)

	unitContent := generateSystemdUnit(config)
	unitPath := filepath.Join("/etc/systemd/system", config.Name+".service")

	if err := os.WriteFile(unitPath, []byte(unitContent), 0644); err != nil {
		return fmt.Errorf("failed to write systemd unit file '%s': %w", unitPath, err)
	}

	// Reload systemd to pick up the new unit
	if err := runCommand("systemctl", "daemon-reload"); err != nil {
		return fmt.Errorf("failed to reload systemd: %w", err)
	}

	// Enable the service to start on boot
	if err := runCommand("systemctl", "enable", config.Name); err != nil {
		return fmt.Errorf("failed to enable service '%s': %w", config.Name, err)
	}

	slog.Info("[ServiceManager] Service installed", "name", config.Name, "unit", unitPath)
	return nil
}

func (m *SystemdServiceManager) RemoveService(name string) error {
	slog.Info("[ServiceManager] Removing service", "name", name)

	// Stop and disable
	_ = runCommand("systemctl", "stop", name)
	_ = runCommand("systemctl", "disable", name)

	// Remove unit file
	unitPath := filepath.Join("/etc/systemd/system", name+".service")
	if err := os.Remove(unitPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to remove unit file '%s': %w", unitPath, err)
	}

	// Reload systemd
	_ = runCommand("systemctl", "daemon-reload")

	slog.Info("[ServiceManager] Service removed", "name", name)
	return nil
}

// generateSystemdUnit creates a systemd unit file content from a ServiceConfig.
func generateSystemdUnit(config ServiceConfig) string {
	args := ""
	if len(config.Args) > 0 {
		args = " " + strings.Join(config.Args, " ")
	}

	workDir := config.WorkingDir
	if workDir == "" {
		workDir = filepath.Dir(config.BinaryPath)
	}

	return fmt.Sprintf(`[Unit]
Description=K2s %s service
After=network.target

[Service]
Type=simple
ExecStart=%s%s
WorkingDirectory=%s
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
`, config.Name, config.BinaryPath, args, workDir)
}
