// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package maps_test

import (
	"testing"

	"github.com/k2s-project/k2s/internal/primitives/maps"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestMaps(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "maps Unit Tests", Label("unit", "ci"))
}

var _ = Describe("maps", func() {
	Describe("GetValue", func() {
		When("map does not contain key", func() {
			It("returns error", func() {
				input := map[string]any{"some-key": 123}

				val, err := maps.GetValue[int]("my-key", input)

				Expect(val).To(Equal(0))
				Expect(err).To(MatchError("map does not contain key 'my-key'"))
			})
		})

		When("map value cannot be converted to target type", func() {
			It("returns error", func() {
				input := map[string]any{"my-key": "123"}

				val, err := maps.GetValue[int]("my-key", input)

				Expect(val).To(Equal(0))
				Expect(err).To(MatchError("cannot convert map value to 'int'"))
			})
		})

		When("key exists and value can be converted", func() {
			It("returns value", func() {
				input := map[string]any{"my-key": 123}

				val, err := maps.GetValue[int]("my-key", input)

				Expect(val).To(Equal(123))
				Expect(err).ToNot(HaveOccurred())
			})
		})
	})
})
