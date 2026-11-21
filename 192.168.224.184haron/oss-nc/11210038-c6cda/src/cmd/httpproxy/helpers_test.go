// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"net/url"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("Helper Tests", func() {
	Describe("cannonicalAddr", func() {
		When("URL contains no port", func() {
			It("returns host with port", func() {
				rawUrl := "https://somehost"
				url, _ := url.Parse(rawUrl)
				expectedRawUrl := strings.ReplaceAll(rawUrl, "https://", "") + ":443"

				actualUrlString := canonicalAddr(url)

				Expect(actualUrlString).To(Equal(expectedRawUrl))
			})
		})

		When("URL contains port", func() {
			It("returns same URL", func() {
				rawUrl := "https://somehost:1234"
				url, _ := url.Parse(rawUrl)
				expectedRawUrl := strings.ReplaceAll(rawUrl, "https://", "")

				actualUrlString := canonicalAddr(url)

				Expect(actualUrlString).To(Equal(expectedRawUrl))
			})
		})
	})

	Describe("useProxy", func() {
		When("no-proxy is not defined", func() {
			It("returns true", func() {
				testUrl1, _ := url.Parse("https://www.google.com")
				testUrl2, _ := url.Parse("https://192.168.0.10:3000/testservice")
				cannonicalAddr1 := canonicalAddr(testUrl1)
				cannonicalAddr2 := canonicalAddr(testUrl2)
				getEnvFunc := func(k string) string { return "" }

				useProxyForAddress1 := useProxy(cannonicalAddr1, getEnvFunc)
				useProxyForAddress2 := useProxy(cannonicalAddr2, getEnvFunc)

				Expect(useProxyForAddress1).To(BeTrue())
				Expect(useProxyForAddress2).To(BeTrue())
			})
		})

		When("no-proxy is set for all hosts", func() {
			It("returns false", func() {
				testUrl1, _ := url.Parse("https://www.google.com")
				testUrl2, _ := url.Parse("https://192.168.0.10:3000/testservice")
				cannonicalAddr1 := canonicalAddr(testUrl1)
				cannonicalAddr2 := canonicalAddr(testUrl2)
				getEnvFunc := func(k string) string { return "*" }

				useProxyForAddress1 := useProxy(cannonicalAddr1, getEnvFunc)
				useProxyForAddress2 := useProxy(cannonicalAddr2, getEnvFunc)

				Expect(useProxyForAddress1).To(BeFalse())
				Expect(useProxyForAddress2).To(BeFalse())
			})
		})

		When("host is localhost", func() {
			It("returns false", func() {
				testUrl, _ := url.Parse("https://localhost:8080")
				cannonicalAddress := canonicalAddr(testUrl)
				getEnvFunc := func(k string) string { return "" }

				useProxyForAddress := useProxy(cannonicalAddress, getEnvFunc)

				Expect(useProxyForAddress).To(BeFalse())
			})
		})

		When("host IP is loopback", func() {
			It("returns false", func() {
				testUrl, _ := url.Parse("https://127.0.0.1:8080/test")
				cannonicalAddress := canonicalAddr(testUrl)
				getEnvFunc := func(k string) string { return "" }

				useProxyForAddress := useProxy(cannonicalAddress, getEnvFunc)

				Expect(useProxyForAddress).To(BeFalse())
			})
		})

		When("host is present in no-proxy", func() {
			It("returns false", func() {
				testUrl, _ := url.Parse("https://k8s.local.io/test")
				cannonicalAddress := canonicalAddr(testUrl)
				getEnvFunc := func(k string) string { return "internalsite.com,k8s.local.io," }

				useProxyForAddress := useProxy(cannonicalAddress, getEnvFunc)

				Expect(useProxyForAddress).To(BeFalse())
			})
		})

		When("host is not present in no-proxy", func() {
			It("returns true", func() {
				testUrl, _ := url.Parse("https://www.sometestwebsite.com")
				cannonicalAddress := canonicalAddr(testUrl)
				getEnvFunc := func(k string) string { return "internalsite.com,k8s.local.io," }

				useProxyForAddress := useProxy(cannonicalAddress, getEnvFunc)

				Expect(useProxyForAddress).To(BeTrue())
			})
		})

		When("domain is configured in no-proxy", func() {
			It("returns false", func() {
				testUrl, _ := url.Parse("https://myk8s.local.io/test")
				cannonicalAddress := canonicalAddr(testUrl)
				getEnvFunc := func(k string) string { return "internalsite.com,.local.io" }

				useProxyForAddress := useProxy(cannonicalAddress, getEnvFunc)

				Expect(useProxyForAddress).To(BeFalse())
			})
		})
	})
})
