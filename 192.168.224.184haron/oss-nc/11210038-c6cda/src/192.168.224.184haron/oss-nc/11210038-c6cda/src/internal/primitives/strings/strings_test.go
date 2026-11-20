// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package strings_test

import (
	"testing"
	"time"

	sut "github.com/k2s-project/k2s/internal/primitives/strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestStrings(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "strings Unit Tests", Label("unit", "ci"))
}

var _ = Describe("strings", func() {
	Describe("ToStrings", func() {
		When("no input", func() {
			It("returns empty slice", func() {
				actual := sut.ToStrings()

				Expect(actual).To(HaveLen(0))
			})
		})

		DescribeTable("single input", func(input any, expeced []string) {
			actual := sut.ToStrings(input)

			Expect(actual).To(HaveExactElements(expeced))
		},
			Entry("returns nil parameter", nil, []string{"<nil>"}),
			Entry("returns boolean parameter", true, []string{"true"}),
			Entry("returns string parameter", "test", []string{"test"}),
			Entry("returns multiple boolean parameters", []bool{true, false}, []string{"[true false]"}),
			Entry("returns multiple string parameters", []string{"test 1", "test 2"}, []string{"[test 1 test 2]"}),
		)

		When("multiple inputs", func() {
			It("returns correct result", func() {
				input1 := "test 1"
				input2 := true
				var input3 []int

				actual := sut.ToStrings(input1, input2, input3, nil)

				Expect(actual).To(HaveLen(4))
				Expect(actual[0]).To(Equal(input1))
				Expect(actual[1]).To(Equal("true"))
				Expect(actual[2]).To(Equal("[]"))
				Expect(actual[3]).To(Equal("<nil>"))
			})
		})
	})

	DescribeTable("ToString", func(input any, expected string) {
		actual := sut.ToString(input)

		Expect(actual).To(Equal(expected))
	},
		Entry("Nil parameter", nil, "<nil>"),
		Entry("Boolean parameter", true, "true"),
		Entry("String parameter", "test", "test"),
		Entry("Slice of boolean parameters", []bool{true, false}, "[true false]"),
		Entry("Slice of string parameters", []string{"test 1", "test 2"}, "[test 1 test 2]"),
	)

	DescribeTable("ToAgeString", func(input time.Duration, expected string) {
		actual := sut.ToAgeString(input)

		Expect(actual).To(Equal(expected))
	},
		Entry("Nanoseconds", time.Nanosecond*5, "0s"),
		Entry("Microseconds", time.Microsecond*5, "0s"),
		Entry("Milliseconds", time.Millisecond*5, "0s"),
		Entry("Seconds", time.Second*5, "5s"),
		Entry("Minutes", time.Minute*5+time.Second*23, "5m23s"),
		Entry("Hours", time.Hour*4+time.Minute*55+time.Second*23, "4h55m23s"),
		Entry("Days", time.Hour*26+time.Minute*55+time.Second*23, "1d2h"),
	)
})
