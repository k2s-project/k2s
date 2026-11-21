// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package main

import (
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"
)

// Get the directory of the module
func getModuleDirectory() string {
	exePath, err := os.Executable()
	if err != nil {
		slog.Error("GetModuleDirectory: failed to get executable path", "error", err)
		os.Exit(1)
	}
	dir := filepath.Dir(exePath)
	slog.Debug("Module directory where vfprules.dll is searched", "dir", dir)
	return dir
}

// VfpRoutes struct to hold the routes to be added
func vfpAddRule(name string, portid string, startip string, stopip string, priority string, gateway string) (uint32, error) {
	vfrulesDLL := syscall.NewLazyDLL(getModuleDirectory() + "\\vfprules.dll")
	procVfpAddRule := vfrulesDLL.NewProc("VfpAddRule")
	ret, _, err := procVfpAddRule.Call(
		uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(name))),
		uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(portid))),
		uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(startip))),
		uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(stopip))),
		uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(priority))),
		uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(gateway))),
	)
	if ret != 0 {
		return uint32(ret), nil
	}
	return 0, err
}

// getStartStopIp converts a subnet definition into start and stop IP addresses.
func getStartStopIp(subnet string) (string, string, error) {
	// Parse the subnet definition
	ip, ipNet, err := net.ParseCIDR(subnet)
	if err != nil {
		return "", "", err
	}

	// Calculate the start IP address (the first IP in the subnet)
	startIp := ip.Mask(ipNet.Mask)

	// Calculate the stop IP address (the last IP in the subnet)
	stopIp := make(net.IP, len(startIp))
	for i := range startIp {
		stopIp[i] = startIp[i] | ^ipNet.Mask[i]
	}

	return startIp.String(), stopIp.String(), nil
}

// Function which adds the rules to the vfprules.dll using the VfpAddRule function
func addVfpRulesWithVfpApi(portid string, port string, vfpRoutes *VfpRoutes, logDir string) error {
	slog.Debug("addVfpRulesWithVfpApi", "port-id", portid, "port", port, "vfp-routes", vfpRoutes, "log-dir", logDir)

	// go through rules and add them
	for _, vfpRoute := range vfpRoutes.Routes {
		slog.Info("addVfpRulesWithVfpApi: vfp route", "name", vfpRoute.Name, "subnet", vfpRoute.Subnet, "gateway", vfpRoute.Gateway, "priority", vfpRoute.Priority)
		// get mac address of gateway
		mac, errmac := getMacOfGateway(vfpRoute.Gateway)
		if errmac != nil {
			slog.Info("AddVfpRules: MAC not found, will continue with the other rules", "error", errmac)
		} else {
			// build from subnet definition start and stop ip
			startip, stopip, err := getStartStopIp(vfpRoute.Subnet)
			if err != nil {
				slog.Info("AddVfpRules: StartStopIp error, will continue with the other rules", "error", err)
				continue
			}

			// write the rules to be added using the vfprules.dll
			int32, error := vfpAddRule(vfpRoute.Name, portid, startip, stopip, vfpRoute.Priority, mac)
			if error != nil {
				slog.Info("AddVfpRules: Adding rule error, will continue with the other rules", "error", error, "int32", int32)
				continue
			}
		}
	}
	return nil
}
