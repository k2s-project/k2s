// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package setuporchestration

import "testing"

func TestRunCommandOutputExcludesSuccessfulStderr(t *testing.T) {
	t.Parallel()

	output, err := runCommandOutput("sh", "-c", "printf 'control-plane\\n'; printf 'warning\\n' >&2")
	if err != nil {
		t.Fatalf("runCommandOutput() returned error: %v", err)
	}
	if output != "control-plane\n" {
		t.Fatalf("runCommandOutput() = %q, want stdout only", output)
	}
}
