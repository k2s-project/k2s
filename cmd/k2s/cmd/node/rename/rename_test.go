// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package rename

import (
	"testing"
	"time"
)

func TestRenameCommandRequiresNames(t *testing.T) {
	for _, args := range [][]string{nil, {"--old-name", "old"}, {"--new-name", "new"}} {
		cmd := NewCmd()
		cmd.SilenceUsage = true
		cmd.SilenceErrors = true
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil {
			t.Fatalf("expected required flag error for %v", args)
		}
	}
}

func TestRenameCommandRejectsInvalidInputBeforeLoadingContext(t *testing.T) {
	for _, args := range [][]string{
		{"--old-name", "old", "--new-name", "old"},
		{"--old-name", "old", "--new-name", "new;hostname"},
		{"--old-name", "old", "--new-name", "new", "--timeout", "0s"},
		{"--old-name", "old", "--new-name", "new", "unexpected"},
	} {
		cmd := NewCmd()
		cmd.SilenceUsage = true
		cmd.SilenceErrors = true
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil {
			t.Fatalf("expected validation error for %v", args)
		}
	}
}

func TestRenameDefaultTimeout(t *testing.T) {
	timeout, err := NewCmd().Flags().GetDuration("timeout")
	if err != nil || timeout != 15*time.Minute {
		t.Fatalf("timeout = %v, error = %v", timeout, err)
	}
}

func TestRenameForceIsOptIn(t *testing.T) {
	force, err := NewCmd().Flags().GetBool("force")
	if err != nil || force {
		t.Fatalf("force = %v, error = %v", force, err)
	}
}
