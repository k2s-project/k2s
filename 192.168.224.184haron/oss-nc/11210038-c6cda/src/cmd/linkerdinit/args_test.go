// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// injectedArgs mirrors the args the Linkerd proxy injector renders for the merged
// image model, taken verbatim from a meshed Windows pod spec (edge-26.6.3).
func injectedArgs() []string {
	return []string{
		"--firewall-bin-path", "iptables-nft",
		"--firewall-save-bin-path", "iptables-nft-save",
		"--ipv6=false",
		"--incoming-proxy-port", "4143",
		"--outgoing-proxy-port", "4140",
		"--proxy-uid", "2102",
		"--inbound-ports-to-ignore", "4190,4191,4567,4568",
		"--outbound-ports-to-ignore", "4567,4568",
	}
}

var _ = Describe("args", func() {
	Describe("parseArgs", func() {
		It("parses the args rendered by the Linkerd proxy injector", func() {
			flags, err := parseArgs(injectedArgs())

			Expect(err).ToNot(HaveOccurred())
			Expect(flags).To(HaveKeyWithValue("firewall-bin-path", "iptables-nft"))
			Expect(flags).To(HaveKeyWithValue("firewall-save-bin-path", "iptables-nft-save"))
			Expect(flags).To(HaveKeyWithValue("ipv6", "false"))
			Expect(flags).To(HaveKeyWithValue("incoming-proxy-port", "4143"))
			Expect(flags).To(HaveKeyWithValue("outgoing-proxy-port", "4140"))
			Expect(flags).To(HaveKeyWithValue("proxy-uid", "2102"))
			Expect(flags).To(HaveKeyWithValue("inbound-ports-to-ignore", "4190,4191,4567,4568"))
			Expect(flags).To(HaveKeyWithValue("outbound-ports-to-ignore", "4567,4568"))
		})

		It("resolves upstream shorthand flags", func() {
			flags, err := parseArgs([]string{"-p", "4143", "-o", "4140", "-u", "2102"})

			Expect(err).ToNot(HaveOccurred())
			Expect(flags).To(HaveKeyWithValue("incoming-proxy-port", "4143"))
			Expect(flags).To(HaveKeyWithValue("outgoing-proxy-port", "4140"))
			Expect(flags).To(HaveKeyWithValue("proxy-uid", "2102"))
		})

		It("accepts unknown flags so upstream additions do not break meshing", func() {
			flags, err := parseArgs(append(injectedArgs(), "--brand-new-flag", "value", "--simulate"))

			Expect(err).ToNot(HaveOccurred())
			Expect(flags).To(HaveKeyWithValue("brand-new-flag", "value"))
			Expect(flags).To(HaveKeyWithValue("simulate", "true"))
		})

		It("rejects positional arguments", func() {
			_, err := parseArgs([]string{"install"})

			Expect(err).To(MatchError(ContainSubstring("unexpected positional argument")))
		})

		It("rejects a value flag without a value", func() {
			_, err := parseArgs([]string{"--incoming-proxy-port", "--ipv6=false"})

			Expect(err).To(MatchError(ContainSubstring("missing a value")))
		})
	})

	Describe("verifyContract", func() {
		It("accepts the args rendered by the Linkerd proxy injector", func() {
			flags, err := parseArgs(injectedArgs())
			Expect(err).ToNot(HaveOccurred())

			Expect(verifyContract(flags)).To(Succeed())
		})

		It("ignores the order of the port exception lists", func() {
			flags, err := parseArgs([]string{
				"--incoming-proxy-port", "4143",
				"--outgoing-proxy-port", "4140",
				"--inbound-ports-to-ignore", "4568,4190,4567,4191",
				"--outbound-ports-to-ignore", "4568,4567",
			})
			Expect(err).ToNot(HaveOccurred())

			Expect(verifyContract(flags)).To(Succeed())
		})

		DescribeTable("rejects a drifted redirection contract",
			func(flagName, value string) {
				flags, err := parseArgs(injectedArgs())
				Expect(err).ToNot(HaveOccurred())
				flags[flagName] = value

				Expect(verifyContract(flags)).To(MatchError(ContainSubstring("the K2s CNI programs")))
			},
			Entry("inbound proxy port", "incoming-proxy-port", "4243"),
			Entry("outbound proxy port", "outgoing-proxy-port", "4240"),
			Entry("inbound port exceptions", "inbound-ports-to-ignore", "4190,4191"),
			Entry("outbound port exceptions", "outbound-ports-to-ignore", "4567"),
		)

		DescribeTable("rejects a missing contract flag",
			func(flagName string) {
				flags, err := parseArgs(injectedArgs())
				Expect(err).ToNot(HaveOccurred())
				delete(flags, flagName)

				Expect(verifyContract(flags)).To(MatchError(ContainSubstring("was not passed by the Linkerd proxy injector")))
			},
			Entry("inbound proxy port", "incoming-proxy-port"),
			Entry("outbound proxy port", "outgoing-proxy-port"),
			Entry("inbound port exceptions", "inbound-ports-to-ignore"),
			Entry("outbound port exceptions", "outbound-ports-to-ignore"),
		)

		DescribeTable("rejects redirection options the HNS policy cannot express",
			func(flagName string) {
				flags, err := parseArgs(injectedArgs())
				Expect(err).ToNot(HaveOccurred())
				flags[flagName] = "8080"

				Expect(verifyContract(flags)).To(MatchError(ContainSubstring("cannot be expressed as an HNS L4WFPPROXY policy")))
			},
			Entry("ports to redirect", "ports-to-redirect"),
			Entry("subnets to ignore", "subnets-to-ignore"),
		)
	})

	Describe("run", func() {
		It("succeeds and reports that the CNI owns the redirection", func() {
			out := &bytes.Buffer{}

			Expect(run(injectedArgs(), out)).To(Succeed())
			Expect(out.String()).To(ContainSubstring("HNS L4WFPPROXY"))
		})

		It("fails when the contract drifted", func() {
			out := &bytes.Buffer{}
			args := append(injectedArgs(), "--incoming-proxy-port=4243")

			Expect(run(args, out)).To(HaveOccurred())
		})
	})
})
