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
	"time"

	_ "embed"
)

//go:embed libvirt_domain.xml.tmpl
var domainXMLTemplate string

// LibvirtVMManager implements VMManager using libvirt/KVM via the virsh CLI.
type LibvirtVMManager struct{}

// NewVMManager returns a libvirt-backed VM manager for Linux hosts.
func NewVMManager() VMManager {
	return &LibvirtVMManager{}
}

// domainTemplateData holds values substituted into the libvirt domain XML template.
type domainTemplateData struct {
	Name          string
	MemoryKB      int
	CPUCount      int
	DiskPath      string
	NetworkBridge string
	FirmwarePath  string
	NVRAMPath     string
	MACAddress    string
}

func (m *LibvirtVMManager) CreateVM(config VMConfig) error {
	slog.Info("[VMManager] Creating VM", "name", config.Name, "cpus", config.CPUCount, "memoryMB", config.MemoryMB, "diskGB", config.DiskSizeGB)

	// Determine OVMF firmware path (UEFI boot for Windows)
	firmwarePath := findOVMFCode()
	if firmwarePath == "" {
		return fmt.Errorf("OVMF UEFI firmware not found; install the ovmf package (e.g. apt install ovmf)")
	}

	// NVRAM (per-VM EFI variable store)
	nvramDir := filepath.Dir(config.ImagePath)
	nvramPath := filepath.Join(nvramDir, config.Name+"_VARS.fd")

	data := domainTemplateData{
		Name:          config.Name,
		MemoryKB:      config.MemoryMB * 1024,
		CPUCount:      config.CPUCount,
		DiskPath:      config.ImagePath,
		NetworkBridge:  config.NetworkBridge,
		FirmwarePath:  firmwarePath,
		NVRAMPath:     nvramPath,
		MACAddress:    winVMMACAddress,
	}

	// Render domain XML (user-customised template takes precedence over embedded default)
	tmpl, err := loadLibvirtTemplate("domain.xml.tmpl", domainXMLTemplate)
	if err != nil {
		return fmt.Errorf("failed to load domain XML template: %w", err)
	}

	tmpFile, err := os.CreateTemp("", "k2s-vm-*.xml")
	if err != nil {
		return fmt.Errorf("failed to create temp file for domain XML: %w", err)
	}
	defer os.Remove(tmpFile.Name())

	if err := tmpl.Execute(tmpFile, data); err != nil {
		tmpFile.Close()
		return fmt.Errorf("failed to render domain XML: %w", err)
	}
	tmpFile.Close()

	// Define the VM
	if err := runCommand("virsh", "define", tmpFile.Name()); err != nil {
		return fmt.Errorf("failed to define VM '%s': %w", config.Name, err)
	}

	slog.Info("[VMManager] VM defined", "name", config.Name)
	return nil
}

func (m *LibvirtVMManager) StartVM(name string) error {
	slog.Info("[VMManager] Starting VM", "name", name)
	if err := runCommand("virsh", "start", name); err != nil {
		return fmt.Errorf("failed to start VM '%s': %w", name, err)
	}
	return nil
}

func (m *LibvirtVMManager) StopVM(name string) error {
	slog.Info("[VMManager] Stopping VM", "name", name)

	// Try graceful shutdown first
	if err := runCommand("virsh", "shutdown", name); err != nil {
		slog.Warn("[VMManager] Graceful shutdown failed, forcing destroy", "name", name, "error", err)
		return m.destroyVM(name)
	}

	// Wait up to 60 seconds for the VM to stop
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		running, err := m.VMIsRunning(name)
		if err != nil || !running {
			slog.Info("[VMManager] VM stopped", "name", name)
			return nil
		}
		time.Sleep(3 * time.Second)
	}

	slog.Warn("[VMManager] VM did not stop gracefully within 60s, forcing destroy", "name", name)
	return m.destroyVM(name)
}

func (m *LibvirtVMManager) destroyVM(name string) error {
	if err := runCommand("virsh", "destroy", name); err != nil {
		return fmt.Errorf("failed to destroy VM '%s': %w", name, err)
	}
	return nil
}

func (m *LibvirtVMManager) RemoveVM(name string) error {
	slog.Info("[VMManager] Removing VM", "name", name)

	// Force-stop if running (ignore errors — may already be off)
	_ = runCommand("virsh", "destroy", name)

	// Undefine with storage removal
	if err := runCommand("virsh", "undefine", name, "--remove-all-storage", "--nvram"); err != nil {
		return fmt.Errorf("failed to undefine VM '%s': %w", name, err)
	}

	slog.Info("[VMManager] VM removed", "name", name)
	return nil
}

func (m *LibvirtVMManager) VMExists(name string) (bool, error) {
	output, err := runCommandOutput("virsh", "dominfo", name)
	if err != nil {
		// "Domain not found" is the expected error when VM doesn't exist
		if strings.Contains(err.Error(), "Domain not found") || strings.Contains(err.Error(), "failed to get domain") {
			return false, nil
		}
		return false, err
	}
	return strings.Contains(output, "Name:"), nil
}

func (m *LibvirtVMManager) VMIsRunning(name string) (bool, error) {
	output, err := runCommandOutput("virsh", "domstate", name)
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(output) == "running", nil
}

// findOVMFCode searches for the OVMF UEFI firmware on common Linux paths.
func findOVMFCode() string {
	candidates := []string{
		"/usr/share/OVMF/OVMF_CODE_4M.fd",
		"/usr/share/OVMF/OVMF_CODE.fd",
		"/usr/share/edk2/ovmf/OVMF_CODE.fd",
		"/usr/share/edk2-ovmf/x64/OVMF_CODE.fd",
		"/usr/share/qemu/OVMF.fd",
	}
	for _, path := range candidates {
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}
	return ""
}
