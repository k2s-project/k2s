// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: MIT

package systemrunning

import (
	"testing"

	. "github.com/onsi/gomega"
)

func TestStorageCapacityMatcher(t *testing.T) {
	for _, tc := range []struct {
		name  string
		value string
		valid bool
	}{
		{"Windows plain bytes", "214746263552", true},
		{"Linux plain bytes", "52626063360", true},
		{"legacy kibibytes", "51392640Ki", true},
		{"gibibytes", "49Gi", true},
		{"decimal quantity", "50G", true},
		{"empty", "", false},
		{"malformed", "not-a-quantity", false},
		{"invalid suffix", "100KiB", false},
		{"trailing garbage", "100Ki-invalid", false},
		{"zero bytes", "0", false},
		{"zero kibibytes", "0Ki", false},
		{"negative bytes", "-1", false},
		{"negative kibibytes", "-100Ki", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			matched, err := WithTransform(isPositiveStorageCapacity, BeTrue()).Match(tc.value)
			if tc.valid && err != nil {
				t.Fatalf("valid capacity %q produced an error: %v", tc.value, err)
			}
			if matched != tc.valid {
				t.Fatalf("capacity %q matched = %v, want %v (error: %v)", tc.value, matched, tc.valid, err)
			}
		})
	}
}
