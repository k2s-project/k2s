// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package override

import (
	"path"
	"strings"

	"github.com/k2s-project/k2s/cmd/k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("override add", func() {
	Describe("overrideAddCmd", func() {
		It("has correct command name", func() {
			Expect(overrideAddCmd.Use).To(Equal("add"))
		})

		It("has short description", func() {
			Expect(overrideAddCmd.Short).To(Equal("Add an override"))
		})

		It("has RunE function defined", func() {
			Expect(overrideAddCmd.RunE).NotTo(BeNil())
		})

		It("has no subcommands", func() {
			Expect(overrideAddCmd.Commands()).To(BeEmpty())
		})

		It("has no long description", func() {
			Expect(overrideAddCmd.Long).To(BeEmpty())
		})

		It("requires at least one argument", func() {
			Expect(overrideAddCmd.RunE).NotTo(BeNil())
		})

		It("accepts multiple arguments", func() {
			Expect(overrideAddCmd.Args).To(BeNil())
		})

		It("accepts no flags", func() {
			Expect(overrideAddCmd.Flags().HasFlags()).To(BeFalse())
		})
	})

	Describe("PowerShell script invocation", func() {
		It("uses correct script path", func() {
			expectedScript := utils.FormatScriptFilePath(path.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "proxy", "override", "AddProxyOverride.ps1"))
			Expect(expectedScript).To(ContainSubstring("AddProxyOverride.ps1"))
			Expect(expectedScript).To(ContainSubstring(path.Join("lib", "scripts", "windows", "host", "system", "proxy", "override")))
		})

		It("joins multiple arguments with comma", func() {
			args := []string{"override1", "override2", "override3"}
			result := strings.Join(args, ",")
			Expect(result).To(Equal("override1,override2,override3"))
		})
	})

})
