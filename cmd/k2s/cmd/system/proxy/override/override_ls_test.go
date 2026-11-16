// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package override

import (
	"path"

	"github.com/k2s-project/k2s/cmd/k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("override ls", func() {
	Describe("overrideListCmd", func() {
		It("has correct command name", func() {
			Expect(overrideListCmd.Use).To(Equal("ls"))
		})

		It("has short description", func() {
			Expect(overrideListCmd.Short).To(Equal("List all overrides"))
		})

		It("has long description", func() {
			Expect(overrideListCmd.Long).To(Equal("List all overrides in the system"))
		})

		It("has RunE function defined", func() {
			Expect(overrideListCmd.RunE).NotTo(BeNil())
		})

		It("has no subcommands", func() {
			Expect(overrideListCmd.Commands()).To(BeEmpty())
		})

		It("accepts no arguments", func() {
			Expect(overrideListCmd.Args).To(BeNil())
		})

		It("accepts no flags", func() {
			Expect(overrideListCmd.Flags().HasFlags()).To(BeFalse())
		})
	})

	Describe("PowerShell script invocation", func() {
		It("uses correct script path", func() {
			expectedScript := utils.FormatScriptFilePath(path.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "proxy", "override", "ListProxyOverrides.ps1"))
			Expect(expectedScript).To(ContainSubstring("ListProxyOverrides.ps1"))
			Expect(expectedScript).To(ContainSubstring(path.Join("lib", "scripts", "windows", "host", "system", "proxy", "override")))
		})
	})

	Describe("ProxyOverrides struct", func() {
		It("can hold multiple overrides", func() {
			overrides := &ProxyOverrides{
				ProxyOverrides: []string{"override1", "override2", "override3"},
			}
			Expect(overrides.ProxyOverrides).To(HaveLen(3))
			Expect(overrides.ProxyOverrides).To(ContainElements("override1", "override2", "override3"))
		})

		It("can hold empty list of overrides", func() {
			overrides := &ProxyOverrides{
				ProxyOverrides: []string{},
			}
			Expect(overrides.ProxyOverrides).To(BeEmpty())
		})
	})

	Describe("Error handling scenarios", func() {
		It("should handle nil ProxyOverrides array in result", func() {
			overrides := &ProxyOverrides{
				ProxyOverrides: nil,
			}
			Expect(overrides.ProxyOverrides).To(BeNil())
		})
	})
})
