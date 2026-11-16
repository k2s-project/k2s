// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package override

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("override", func() {
	Describe("OverrideCmd", func() {
		It("has correct command name", func() {
			Expect(OverrideCmd.Use).To(Equal("override"))
		})

		It("has short description", func() {
			Expect(OverrideCmd.Short).To(Equal("Override command"))
		})

		It("has long description", func() {
			Expect(OverrideCmd.Long).To(Equal("Override command is used to override certain settings"))
		})

		It("has all subcommands", func() {
			subcommands := make(map[string]bool)
			for _, cmd := range OverrideCmd.Commands() {
				subcommands[cmd.Use] = true
			}

			Expect(subcommands).To(HaveKey("add"))
			Expect(subcommands).To(HaveKey("delete"))
			Expect(subcommands).To(HaveKey("ls"))
		})

		It("has correct number of subcommands", func() {
			Expect(OverrideCmd.Commands()).To(HaveLen(3))
		})
	})
})
