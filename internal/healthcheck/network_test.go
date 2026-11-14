// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package healthcheck_test

import (
	"errors"
	"net"

	"github.com/k2s-project/k2s/internal/healthcheck"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func fakeInterfaces(interfaces ...healthcheck.NetworkInterface) healthcheck.NetworkInterfacesFunc {
	return func() ([]healthcheck.NetworkInterface, error) {
		return interfaces, nil
	}
}

var _ = Describe("APIPA check", func() {
	It("passes when no active adapter has an APIPA address", func() {
		check := healthcheck.NewApipaCheck(fakeInterfaces(
			healthcheck.NetworkInterface{Name: "Ethernet", Up: true, Addresses: []net.IP{net.ParseIP("192.168.0.10"), net.ParseIP("fe80::1")}},
			healthcheck.NetworkInterface{Name: "vEthernet (KubeSwitch)", Up: true, Addresses: []net.IP{net.ParseIP("172.19.1.1")}},
		))

		result := runSingle(check)

		Expect(result.Name).To(Equal("apipa-address"))
		Expect(result.Status).To(Equal(healthcheck.StatusPass))
	})

	It("warns about active adapters with an APIPA address", func() {
		check := healthcheck.NewApipaCheck(fakeInterfaces(
			healthcheck.NetworkInterface{Name: "Ethernet", Up: true, Addresses: []net.IP{net.ParseIP("169.254.12.34")}},
			healthcheck.NetworkInterface{Name: "Wi-Fi", Up: true, Addresses: []net.IP{net.ParseIP("10.0.0.5")}},
			healthcheck.NetworkInterface{Name: "vEthernet (Loopbackk2s)", Up: true, Addresses: []net.IP{net.ParseIP("172.22.1.2"), net.ParseIP("169.254.1.1")}},
		))

		result := runSingle(check)

		Expect(result.Status).To(Equal(healthcheck.StatusWarn))
		Expect(result.Message).To(Equal("APIPA address found on 'Ethernet', 'vEthernet (Loopbackk2s)'"))
		Expect(result.Hint).To(ContainSubstring("FixAutoconfiguration.ps1"))
	})

	It("ignores inactive and loopback adapters", func() {
		check := healthcheck.NewApipaCheck(fakeInterfaces(
			healthcheck.NetworkInterface{Name: "Disconnected", Up: false, Addresses: []net.IP{net.ParseIP("169.254.12.34")}},
			healthcheck.NetworkInterface{Name: "Loopback", Up: true, Loopback: true, Addresses: []net.IP{net.ParseIP("169.254.1.1")}},
		))

		Expect(runSingle(check).Status).To(Equal(healthcheck.StatusPass))
	})

	It("does not treat IPv6 link-local or neighbouring IPv4 ranges as APIPA", func() {
		check := healthcheck.NewApipaCheck(fakeInterfaces(
			healthcheck.NetworkInterface{Name: "Ethernet", Up: true, Addresses: []net.IP{
				net.ParseIP("fe80::a9fe:1"), net.ParseIP("169.253.255.255"), net.ParseIP("169.255.0.1"),
			}},
		))

		Expect(runSingle(check).Status).To(Equal(healthcheck.StatusPass))
	})

	It("skips when the interfaces cannot be listed", func() {
		check := healthcheck.NewApipaCheck(func() ([]healthcheck.NetworkInterface, error) {
			return nil, errors.New("access denied")
		})

		result := runSingle(check)

		Expect(result.Status).To(Equal(healthcheck.StatusSkip))
		Expect(result.Message).To(Equal("access denied"))
	})
})

var _ = Describe("GetNetworkInterfaces", func() {
	It("lists the interfaces of the host including a loopback interface", func() {
		interfaces, err := healthcheck.GetNetworkInterfaces()

		Expect(err).ToNot(HaveOccurred())
		Expect(interfaces).To(ContainElement(HaveField("Loopback", BeTrue())))
	})
})
