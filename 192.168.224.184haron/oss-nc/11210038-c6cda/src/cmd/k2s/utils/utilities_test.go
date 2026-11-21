// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package utils_test

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/cmd/k2s/utils"
)

func TestUtils(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "utils Unit Tests", Label("unit", "ci"))
}

var _ = Describe("utils", func() {
	Describe("EscapeWithSingleQuotes", func() {
		DescribeTable("returns a PowerShell verbatim string literal",
			func(input string, expected string) {
				Expect(utils.EscapeWithSingleQuotes(input)).To(Equal(expected))
			},
			Entry("empty value", "", `''`),
			Entry("plain value", `C:\my dir`, `'C:\my dir'`),
			Entry("apostrophe", `C:\owner's dir`, `'C:\owner''s dir'`),
			Entry("PowerShell expressions", "$(calc) $env:x `n \"", "'$(calc) $env:x `n \"'"),
			Entry("left single quotation mark", "a\u2018b", "'a\u2018\u2018b'"),
			Entry("right single quotation mark", "a\u2019b", "'a\u2019\u2019b'"),
			Entry("single low-9 quotation mark", "a\u201Ab", "'a\u201A\u201Ab'"),
			Entry("single high-reversed-9 quotation mark", "a\u201Bb", "'a\u201B\u201Bb'"),
			Entry("quote injection attempt", "x'; calc; '", "'x''; calc; '''"),
		)
	})

	Describe("EscapeArrayWithSingleQuotes", func() {
		It("returns a comma-separated list of escaped values", func() {
			actual := utils.EscapeArrayWithSingleQuotes([]string{"localhost", "it's", ".local"})

			Expect(actual).To(Equal(`'localhost','it''s','.local'`))
		})

		It("returns a single escaped value", func() {
			Expect(utils.EscapeArrayWithSingleQuotes([]string{"localhost"})).To(Equal(`'localhost'`))
		})
	})
})
