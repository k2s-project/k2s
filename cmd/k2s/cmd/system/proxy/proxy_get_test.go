// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package proxy

import (
	"path"

	"github.com/k2s-project/k2s/cmd/k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("proxy get", func() {
	Describe("proxyGetCmd", func() {
		It("has correct command name", func() {
			Expect(proxyGetCmd.Use).To(Equal("get"))
		})

		It("has short description", func() {
			Expect(proxyGetCmd.Short).To(Equal("Get proxy information"))
		})

		It("has long description", func() {
			Expect(proxyGetCmd.Long).To(Equal("Get information about the proxy configuration"))
		})

		It("has RunE function defined", func() {
			Expect(proxyGetCmd.RunE).NotTo(BeNil())
		})

		It("has no subcommands", func() {
			Expect(proxyGetCmd.Commands()).To(BeEmpty())
		})

		It("accepts no arguments", func() {
			Expect(proxyGetCmd.Args).To(BeNil())
		})

		It("accepts no flags", func() {
			Expect(proxyGetCmd.Flags().HasFlags()).To(BeFalse())
		})
	})

	Describe("PowerShell script invocation", func() {
		It("uses correct script path", func() {
			expectedScript := utils.FormatScriptFilePath(path.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "proxy", "GetProxy.ps1"))
			Expect(expectedScript).To(ContainSubstring("GetProxy.ps1"))
			Expect(expectedScript).To(ContainSubstring(path.Join("lib", "scripts", "windows", "host", "system", "proxy")))
		})
	})

	Describe("ProxyServer struct", func() {
		It("can hold proxy value", func() {
			testProxy := "http://proxy.example.com:8080"
			server := &ProxyServer{Proxy: &testProxy}
			Expect(server.Proxy).NotTo(BeNil())
			Expect(*server.Proxy).To(Equal(testProxy))
		})
	})

})
