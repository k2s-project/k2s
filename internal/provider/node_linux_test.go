// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

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
	t.Setenv("K2S_SSH_IDENTITY_FILE", "/run/k2s/id_ed25519")
	t.Setenv("K2S_SSH_KNOWN_HOSTS_FILE", "/run/k2s/known_hosts")

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
	for _, expected := range []string{"-i\n/run/k2s/id_ed25519", "IdentitiesOnly=yes", "UserKnownHostsFile=/run/k2s/known_hosts"} {
		if !strings.Contains(string(args), expected) {
			t.Fatalf("ssh args do not include %q: %s", expected, args)
		}
	}
}

func TestAssertSupportedNodeArchitecture(t *testing.T) {
	dir := t.TempDir()
	sshPath := filepath.Join(dir, "ssh")
	script := "#!/bin/sh\ncase \"$*\" in *\"uname -m\"*) printf '%s\\n' \"$SSH_ARCH\";; *) printf '%s\\n' \"$SSH_OS\";; esac\n"
	if err := os.WriteFile(sshPath, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	tests := []struct {
		name    string
		arch    string
		osID    string
		wantErr bool
	}{
		{name: "amd64", arch: "x86_64", osID: "ubuntu", wantErr: false},
		{name: "arm64 Debian", arch: "aarch64", osID: "debian", wantErr: false},
		{name: "arm64 non-Debian", arch: "aarch64", osID: "ubuntu", wantErr: true},
		{name: "unsupported arm", arch: "armv7l", osID: "debian", wantErr: true},
		{name: "unsupported riscv", arch: "riscv64", osID: "debian", wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("SSH_ARCH", tt.arch)
			t.Setenv("SSH_OS", tt.osID)
			err := assertSupportedNodeArchitecture("worker", "192.0.2.10")
			if (err != nil) != tt.wantErr {
				t.Fatalf("assertSupportedNodeArchitecture() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}
