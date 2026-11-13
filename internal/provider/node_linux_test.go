// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build linux

package provider

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSSHCmdToNodeRequiresKnownHostVerification(t *testing.T) {
	dir := t.TempDir()
	argsPath := filepath.Join(dir, "args")
	sshPath := filepath.Join(dir, "ssh")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$SSH_ARGS_FILE\"\n"
	if err := os.WriteFile(sshPath, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SSH_ARGS_FILE", argsPath)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	if _, err := sshCmdToNode("worker", "192.0.2.10", "true"); err != nil {
		t.Fatal(err)
	}

	args, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(args), "StrictHostKeyChecking=yes") {
		t.Fatalf("ssh args do not require host key verification: %s", args)
	}
	if strings.Contains(string(args), "StrictHostKeyChecking=no") ||
		strings.Contains(string(args), "UserKnownHostsFile=/dev/null") {
		t.Fatalf("ssh args disable host key verification: %s", args)
	}
}
