// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier:   MIT

package units_test

import (
	"log/slog"
	"math"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/primitives/units"
)

func TestUnits(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "units Unit Tests", Label("unit", "ci", "units"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("units", func() {
	DescribeTable("ParseBase2Bytes", func(input string, expected units.BytesQuantity, errorExpected bool) {
		actual, err := units.ParseBase2Bytes(input)

		if errorExpected {
			Expect(err).To(HaveOccurred())
		} else {
			Expect(err).ToNot(HaveOccurred())
		}

		Expect(actual).To(Equal(expected))
	},
		Entry("empty string", "", units.BytesQuantity(0), true),
		Entry("invalid string", "abc", units.BytesQuantity(0), true),
		Entry("invalid kilo unit", "1kB", units.BytesQuantity(0), true),
		Entry("unsupported ZiB", "1ZiB", units.BytesQuantity(0), true),
		Entry("unsupported YiB", "1YiB", units.BytesQuantity(0), true),
		Entry("unsupported RiB", "1RiB", units.BytesQuantity(0), true),
		Entry("unsupported QiB", "1QiB", units.BytesQuantity(0), true),

		Entry("plain bytes", "1", units.BytesQuantity(1), false),
		Entry("plain bytes, large", "52626063360", units.BytesQuantity(52626063360), false),
		Entry("01KB", "01KB", units.BytesQuantity(1024), false),
		Entry("1KB", "1KB", units.BytesQuantity(1024), false),
		Entry("1MB", "1MB", units.BytesQuantity(math.Pow(1024, 2)), false),
		Entry("1GB", "1GB", units.BytesQuantity(math.Pow(1024, 3)), false),
		Entry("1TB", "1TB", units.BytesQuantity(math.Pow(1024, 4)), false),
		Entry("1PB", "1PB", units.BytesQuantity(math.Pow(1024, 5)), false),
		Entry("1EB", "1EB", units.BytesQuantity(math.Pow(1024, 6)), false),

		Entry("01Ki", "01Ki", units.BytesQuantity(1024), false),
		Entry("1Ki", "1Ki", units.BytesQuantity(1024), false),
		Entry("1Mi", "1Mi", units.BytesQuantity(math.Pow(1024, 2)), false),
		Entry("1Gi", "1Gi", units.BytesQuantity(math.Pow(1024, 3)), false),
		Entry("1Ti", "1Ti", units.BytesQuantity(math.Pow(1024, 4)), false),
		Entry("1Pi", "1Pi", units.BytesQuantity(math.Pow(1024, 5)), false),
		Entry("1Ei", "1Ei", units.BytesQuantity(math.Pow(1024, 6)), false),

		Entry("01KiB", "01KiB", units.BytesQuantity(1024), false),
		Entry("1KiB", "1KiB", units.BytesQuantity(1024), false),
		Entry("1MiB", "1MiB", units.BytesQuantity(math.Pow(1024, 2)), false),
		Entry("1GiB", "1GiB", units.BytesQuantity(math.Pow(1024, 3)), false),
		Entry("1TiB", "1TiB", units.BytesQuantity(math.Pow(1024, 4)), false),
		Entry("1PiB", "1PiB", units.BytesQuantity(math.Pow(1024, 5)), false),
		Entry("1EiB", "1EiB", units.BytesQuantity(math.Pow(1024, 6)), false),
	)

	DescribeTable("String", func(input units.BytesQuantity, expected string) {
		Expect(input.String()).To(Equal(expected))
	},
		Entry("1B", units.BytesQuantity(1), "1B"),
		Entry("1KiB", units.BytesQuantity(1024), "1KiB"),
		Entry("1.5KiB", units.BytesQuantity(1024+512), "1.5KiB"),
		Entry("1MiB", units.BytesQuantity(math.Pow(1024, 2)), "1MiB"),
		Entry("1.5MiB", units.BytesQuantity(math.Pow(1024, 2)+(math.Pow(1024, 2)/2)), "1.5MiB"),
		Entry("1GiB", units.BytesQuantity(math.Pow(1024, 3)), "1GiB"),
		Entry("1.5GiB", units.BytesQuantity(math.Pow(1024, 3)+(math.Pow(1024, 3)/2)), "1.5GiB"),
		Entry("1TiB", units.BytesQuantity(math.Pow(1024, 4)), "1TiB"),
		Entry("1.5TiB", units.BytesQuantity(math.Pow(1024, 4)+(math.Pow(1024, 4)/2)), "1.5TiB"),
		Entry("1PiB", units.BytesQuantity(math.Pow(1024, 5)), "1PiB"),
		Entry("1.5PiB", units.BytesQuantity(math.Pow(1024, 5)+(math.Pow(1024, 5)/2)), "1.5PiB"),
		Entry("1EiB", units.BytesQuantity(math.Pow(1024, 6)), "1EiB"),
		Entry("1.5EiB", units.BytesQuantity(math.Pow(1024, 6)+(math.Pow(1024, 6)/2)), "1.5EiB"),
	)
})
