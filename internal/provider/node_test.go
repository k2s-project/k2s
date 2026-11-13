// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package provider

import (
	"testing"
	"time"
)

func TestNodeRenameConfigValidation(t *testing.T) {
	tests := []struct {
		name    string
		old     string
		new     string
		timeout time.Duration
		valid   bool
	}{
		{"normalizes names", "OLD-NODE", "NEW-NODE", 15 * time.Minute, true},
		{"empty old", "", "new", time.Minute, false},
		{"empty new", "old", "", time.Minute, false},
		{"same name", "OLD", "old", time.Minute, false},
		{"shell input", "old", "new;hostname", time.Minute, false},
		{"invalid hostname", "old", "new_node", time.Minute, false},
		{"invalid timeout", "old", "new", time.Second, false},
		{"excessive timeout", "old", "new", 25 * time.Hour, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg, err := (NodeRenameConfig{OldName: tt.old, NewName: tt.new, Timeout: tt.timeout}).Validated()
			if (err == nil) != tt.valid {
				t.Fatalf("Validated() error = %v, valid = %t", err, tt.valid)
			}
			if tt.valid && (cfg.OldName != "old-node" || cfg.NewName != "new-node") {
				t.Fatalf("names not normalized: %+v", cfg)
			}
		})
	}
}
