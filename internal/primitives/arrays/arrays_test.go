// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package arrays_test

import (
	"testing"

	sut "github.com/k2s-project/k2s/internal/primitives/arrays"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestArrays(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "arrays Unit Tests", Label("unit", "ci"))
}

var _ = Describe("arrays", func() {
	DescribeTable("Insert", func(input []int, expected []int, inputItem int, inputIndex int) {
		actual := sut.Insert(input, inputItem, inputIndex)

		Expect(actual).To(Equal(expected))
	},
		Entry("inserting at the beginning", []int{1, 2, 3, 4}, []int{5, 1, 2, 3, 4}, 5, 0),
		Entry("inserting into the middle", []int{1, 2, 3, 4}, []int{1, 2, 5, 3, 4}, 5, 2),
		Entry("inserting at the end", []int{1, 2, 3, 4}, []int{1, 2, 3, 4, 5}, 5, 4),
	)
})
