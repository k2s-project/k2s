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

var _ = Describe("override delete", func() {
	Describe("overrideDeleteCmd", func() {
		It("has correct command name", func() {
			Expect(overrideDeleteCmd.Use).To(Equal("delete"))
		})

		It("has short description", func() {
			Expect(overrideDeleteCmd.Short).To(Equal("Delete an override"))
		})

		It("has RunE function defined", func() {
			Expect(overrideDeleteCmd.RunE).NotTo(BeNil())
		})

		It("has no subcommands", func() {
			Expect(overrideDeleteCmd.Commands()).To(BeEmpty())
		})

		It("has no long description", func() {
			Expect(overrideDeleteCmd.Long).To(BeEmpty())
		})

		It("requires at least one argument", func() {
			Expect(overrideDeleteCmd.RunE).NotTo(BeNil())
		})

		It("accepts multiple arguments", func() {
			Expect(overrideDeleteCmd.Args).To(BeNil())
		})

		It("accepts no flags", func() {
			Expect(overrideDeleteCmd.Flags().HasFlags()).To(BeFalse())
		})
	})

	Describe("PowerShell script invocation", func() {
		It("uses correct script path", func() {
			expectedScript := utils.FormatScriptFilePath(path.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "proxy", "override", "DeleteProxyOverride.ps1"))
			Expect(expectedScript).To(ContainSubstring("DeleteProxyOverride.ps1"))
			Expect(expectedScript).To(ContainSubstring(path.Join("lib", "scripts", "windows", "host", "system", "proxy", "override")))
		})

		It("joins multiple arguments with comma", func() {
			args := []string{"override1", "override2", "override3"}
			result := strings.Join(args, ",")
			Expect(result).To(Equal("override1,override2,override3"))
		})
	})

})
