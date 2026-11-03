// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier:   MIT

package units

import (
	"fmt"
	"math"
	"strings"

	"github.com/alecthomas/units"
)

type BytesQuantity float64

const (
	maxUnit  = "EiB"
	kibibyte = 1024.0
)

var byteUnits = []string{"B", "KiB", "MiB", "GiB", "TiB", "PiB"}

func ParseBase2Bytes(input string) (BytesQuantity, error) {
	// see https://physics.nist.gov/cuu/Units/binary.html
	// and https://en.wikipedia.org/wiki/Byte#Multiple-byte_units
	if strings.HasSuffix(input, "i") || isPlainNumber(input) {
		input += "B"
	}

	bytes, err := units.ParseBase2Bytes(input)
	if err != nil {
		return 0, fmt.Errorf("could not parse base-2 bytes: %w", err)
	}

	return BytesQuantity(bytes), nil
}

// Kubernetes reports quantities without suffix (e.g. ephemeral-storage) as plain bytes.
func isPlainNumber(input string) bool {
	if input == "" {
		return false
	}
	for _, c := range input {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func (quantity BytesQuantity) String() string {
	for _, unit := range byteUnits {
		if math.Abs(quantity.float()) < kibibyte {
			return quantity.format(unit)
		}
		quantity /= kibibyte
	}
	return quantity.format(maxUnit)
}

func (quantity BytesQuantity) format(unit string) string {
	format := "%.1f%s"
	if quantity.isInteger() {
		format = "%.0f%s"
	}
	return fmt.Sprintf(format, quantity, unit)
}

func (quantity BytesQuantity) float() float64 {
	return float64(quantity)
}

func (quantity BytesQuantity) isInteger() bool {
	return quantity.float() == math.Trunc(quantity.float())
}
