// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"fmt"
	"net"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("Network CIDRs Tests", func() {
	Describe("Set", func() {
		When("network CIDR is valid", func() {
			It("gets added successfully", func() {
				networkCidrs := newNetworkCidrs()
				cidrToBeAdded := "172.24.0.0/16"

				Expect(networkCidrs.Set(cidrToBeAdded)).To(Succeed())
				Expect(networkCidrs).To(ContainElement(cidrToBeAdded))
			})
		})

		When("network CIDR is invalid", func() {
			It("does not get added", func() {
				networkCidrs := newNetworkCidrs()
				cidrToBeAdded := "abc"

				Expect(networkCidrs.Set(cidrToBeAdded)).ToNot(Succeed())
			})
		})
	})

	Describe("String", func() {
		When("no network CIDR is added", func() {
			It("returns empty string", func() {
				networkCIDRs := newNetworkCidrs()

				actual := networkCIDRs.String()

				Expect(actual).To(BeEmpty())
			})
		})

		When("network CIDRs are added", func() {
			It("returns CIDRs as comma-separated string", func() {
				cidr1 := "172.16.1.0/24"
				cidr2 := "12.10.1.0/24"
				expected := fmt.Sprintf("%s,%s", cidr1, cidr2)
				networkCIDRs := newNetworkCidrs()
				networkCIDRs.Set(cidr1)
				networkCIDRs.Set(cidr2)

				actual := networkCIDRs.String()

				Expect(actual).To(Equal(expected))
			})
		})
	})

	Describe("ToIPNet", func() {
		When("no network CIDR is added", func() {
			It("returns empty IPNet slice", func() {
				networkCIDRs := newNetworkCidrs()

				actual, err := networkCIDRs.ToIPNet()

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(BeEmpty())
			})
		})

		When("network CIDRs are added", func() {
			It("returns CIDRs as IPNet slice", func() {
				cidr := net.IPNet{IP: net.IP{172, 19, 1, 0}, Mask: net.IPv4Mask(255, 255, 255, 0)}
				networkCIDRs := newNetworkCidrs()
				networkCIDRs.Set(cidr.String())

				actual, err := networkCIDRs.ToIPNet()

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(HaveLen(1))
				Expect(actual).To(ContainElement(&cidr))
			})
		})
	})
})
