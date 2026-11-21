// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package proxy

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("proxy show", func() {
	Describe("proxyShowCmd", func() {
		It("has correct command name", func() {
			Expect(proxyShowCmd.Use).To(Equal("show"))
		})

		It("has short description", func() {
			Expect(proxyShowCmd.Short).To(Equal("Show proxy information"))
		})

		It("has long description", func() {
			Expect(proxyShowCmd.Long).To(Equal("This command shows information about the proxy"))
		})

		It("has RunE function defined", func() {
			Expect(proxyShowCmd.RunE).NotTo(BeNil())
		})

		It("has no subcommands", func() {
			Expect(proxyShowCmd.Commands()).To(BeEmpty())
		})

		It("accepts no arguments", func() {
			Expect(proxyShowCmd.Args).To(BeNil())
		})

		It("accepts no flags", func() {
			Expect(proxyShowCmd.Flags().HasFlags()).To(BeFalse())
		})
	})
})
