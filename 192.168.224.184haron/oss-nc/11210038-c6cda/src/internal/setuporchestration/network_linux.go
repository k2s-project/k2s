// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package setuporchestration

import (
	"fmt"
	"log/slog"
	"os"

	_ "embed"
)

const (
	// k2sNetworkName is the libvirt network used for host ↔ Windows VM communication.
	k2sNetworkName = "k2s"

	// Network addresses matching cfg/config.json values.
	hostBridgeIP       = "172.19.1.1"
	winVMIP            = "172.19.1.101"
	networkCIDR        = "172.19.1.0/24"
	networkMask        = "255.255.255.0"
	dhcpRangeStart     = "172.19.1.100"
	dhcpRangeEnd       = "172.19.1.199"
	podNetworkWorker   = "172.20.1.0/24"
)

// networkTemplateData holds values for the libvirt network XML template.
type networkTemplateData struct {
	Name           string
	BridgeName     string
	HostIP         string
	Netmask        string
	DHCPRangeStart string
	DHCPRangeEnd   string
	WinVMIP        string
	WinVMMac       string
}

//go:embed libvirt_network.xml.tmpl
var networkXMLTemplate string

// winVMMACAddress is a fixed MAC address for the Windows worker VM.
// Using a fixed MAC ensures the DHCP reservation always assigns the same IP.
const winVMMACAddress = "52:54:00:25:57:01"

// CreateK2sNetwork creates the libvirt NAT network for K2s host ↔ VM communication.
func CreateK2sNetwork() error {
	slog.Info("[Network] Creating K2s libvirt network", "name", k2sNetworkName, "hostIP", hostBridgeIP)

	// Check if network already exists
	output, err := runCommandOutput("virsh", "net-info", k2sNetworkName)
	if err == nil && output != "" {
		slog.Info("[Network] K2s network already exists, ensuring it is active")
		_ = runCommand("virsh", "net-start", k2sNetworkName)
		_ = runCommand("virsh", "net-autostart", k2sNetworkName)
		return nil
	}

	data := networkTemplateData{
		Name:           k2sNetworkName,
		BridgeName:     "virbr-k2s",
		HostIP:         hostBridgeIP,
		Netmask:        networkMask,
		DHCPRangeStart: dhcpRangeStart,
		DHCPRangeEnd:   dhcpRangeEnd,
		WinVMIP:        winVMIP,
		WinVMMac:       winVMMACAddress,
	}

	tmpl, err := loadLibvirtTemplate("network.xml.tmpl", networkXMLTemplate)
	if err != nil {
		return fmt.Errorf("failed to load network XML template: %w", err)
	}

	tmpFile, err := os.CreateTemp("", "k2s-network-*.xml")
	if err != nil {
		return fmt.Errorf("failed to create temp file for network XML: %w", err)
	}
	defer os.Remove(tmpFile.Name())

	if err := tmpl.Execute(tmpFile, data); err != nil {
		tmpFile.Close()
		return fmt.Errorf("failed to render network XML: %w", err)
	}
	tmpFile.Close()

	// Define, start and autostart the network
	if err := runCommand("virsh", "net-define", tmpFile.Name()); err != nil {
		return fmt.Errorf("failed to define K2s network: %w", err)
	}

	if err := runCommand("virsh", "net-start", k2sNetworkName); err != nil {
		return fmt.Errorf("failed to start K2s network: %w", err)
	}

	if err := runCommand("virsh", "net-autostart", k2sNetworkName); err != nil {
		slog.Warn("[Network] Could not set network to autostart", "error", err)
	}

	slog.Info("[Network] K2s network created and active")
	return nil
}

// SetupRoutes adds host routes for the Windows worker pod subnet and service CIDR.
func SetupRoutes() error {
	slog.Info("[Network] Setting up routes for Windows worker VM")

	// Route the Windows pod subnet (172.20.1.0/24) to the Windows VM
	if err := runCommand("ip", "route", "replace", podNetworkWorker, "via", winVMIP); err != nil {
		slog.Warn("[Network] Could not add route for Windows pod subnet", "error", err)
	}

	slog.Info("[Network] Routes configured")
	return nil
}

// RemoveK2sNetwork removes the K2s libvirt network and host routes.
func RemoveK2sNetwork() error {
	slog.Info("[Network] Removing K2s network")

	// Remove routes (ignore errors)
	_ = runCommand("ip", "route", "del", podNetworkWorker)

	// Destroy and undefine the network
	_ = runCommand("virsh", "net-destroy", k2sNetworkName)
	_ = runCommand("virsh", "net-undefine", k2sNetworkName)

	slog.Info("[Network] K2s network removed")
	return nil
}
