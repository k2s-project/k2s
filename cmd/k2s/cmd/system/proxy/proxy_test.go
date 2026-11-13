// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package proxy

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("proxy", func() {
	Describe("ProxyCmd", func() {
		It("has correct command name", func() {
			Expect(ProxyCmd.Use).To(Equal("proxy"))
		})

		It("has short description", func() {
			Expect(ProxyCmd.Short).To(Equal("Manage proxy settings"))
		})

		It("has all subcommands", func() {
			subcommands := make(map[string]bool)
			for _, cmd := range ProxyCmd.Commands() {
				subcommands[cmd.Use] = true
			}

			Expect(subcommands).To(HaveKey("set"))
			Expect(subcommands).To(HaveKey("get"))
			Expect(subcommands).To(HaveKey("show"))
			Expect(subcommands).To(HaveKey("reset"))
			Expect(subcommands).To(HaveKey("override"))
		})

		It("has correct number of subcommands", func() {
			Expect(ProxyCmd.Commands()).To(HaveLen(5))
		})
	})
})
