// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package healthcheck

import (
	"fmt"
	"net"
	"slices"
	"strings"
)

const apipaHint = "Renew the address of the affected adapter (e.g. 'ipconfig /renew') or disable APIPA with 'smallsetup\\FixAutoconfiguration.ps1' (see 'Known Issues > Microsoft APIPA / Link-Local Address' in the K2s documentation)"

// apipaNetwork is the IPv4 link-local block used by Automatic Private IP Addressing.
var apipaNetwork = &net.IPNet{IP: net.IPv4(169, 254, 0, 0), Mask: net.CIDRMask(16, 32)}

// NetworkInterface is the subset of an interface's properties the APIPA check needs.
type NetworkInterface struct {
	Name      string
	Up        bool
	Loopback  bool
	Addresses []net.IP
}

// NetworkInterfacesFunc lists the network interfaces of the host.
type NetworkInterfacesFunc func() ([]NetworkInterface, error)

// GetNetworkInterfaces lists the host's network interfaces with their IP addresses.
func GetNetworkInterfaces() ([]NetworkInterface, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, fmt.Errorf("could not list network interfaces: %w", err)
	}

	result := make([]NetworkInterface, 0, len(interfaces))
	for _, iface := range interfaces {
		addrs, err := iface.Addrs()
		if err != nil {
			return nil, fmt.Errorf("could not list addresses of network interface '%s': %w", iface.Name, err)
		}

		ips := make([]net.IP, 0, len(addrs))
		for _, addr := range addrs {
			if ipNet, ok := addr.(*net.IPNet); ok {
				ips = append(ips, ipNet.IP)
			}
		}

		result = append(result, NetworkInterface{
			Name:      iface.Name,
			Up:        iface.Flags&net.FlagUp != 0,
			Loopback:  iface.Flags&net.FlagLoopback != 0,
			Addresses: ips,
		})
	}
	return result, nil
}

// NewApipaCheck returns a check that reports active network adapters with an APIPA
// (169.254.x.x) address. Such an address prevents flannel from creating the 'cbr0' switch.
func NewApipaCheck(interfacesFunc NetworkInterfacesFunc) Check {
	return Check{
		Name:        "apipa-address",
		Description: "No APIPA (169.254.x.x) address on active network adapters",
		Run: func() Outcome {
			return checkApipa(interfacesFunc)
		},
	}
}

func checkApipa(interfacesFunc NetworkInterfacesFunc) Outcome {
	interfaces, err := interfacesFunc()
	if err != nil {
		return skip(err.Error())
	}

	var affected []string
	for _, iface := range interfaces {
		if !iface.Up || iface.Loopback {
			continue
		}
		if slices.ContainsFunc(iface.Addresses, isApipaAddress) {
			affected = append(affected, fmt.Sprintf("'%s'", iface.Name))
		}
	}

	if len(affected) > 0 {
		return warn(fmt.Sprintf("APIPA address found on %s", strings.Join(affected, ", ")), apipaHint)
	}
	return pass("no active network adapter uses an APIPA address")
}

func isApipaAddress(ip net.IP) bool {
	ipv4 := ip.To4()
	return ipv4 != nil && apipaNetwork.Contains(ipv4)
}
