// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"unicode/utf16"

	"github.com/k2s-project/k2s/internal/definitions"
)

type recordedCmd struct {
	name string
	args []string
}

type mockCmdRunner struct {
	calls []recordedCmd
	fn    func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error
}

func (m *mockCmdRunner) Run(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
	argsCopy := append([]string(nil), args...)
	m.calls = append(m.calls, recordedCmd{name: name, args: argsCopy})
	if m.fn != nil {
		return m.fn(ctx, name, args, stdout, stderr)
	}
	return nil
}

func decodeUTF16LEBase64(t *testing.T, b64 string) string {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		t.Fatalf("base64 decode failed: %v", err)
	}
	if len(raw)%2 != 0 {
		t.Fatalf("expected even byte length for UTF-16LE, got %d", len(raw))
	}
	u16 := make([]uint16, len(raw)/2)
	for i := range u16 {
		u16[i] = binary.LittleEndian.Uint16(raw[i*2:])
	}
	return string(utf16.Decode(u16))
}

func TestWinWorker_EncodePowerShellUTF16LE(t *testing.T) {
	script := "Write-Output 'hello-k2s'"
	b64 := encodePowerShellUTF16LE(script)
	got := decodeUTF16LEBase64(t, b64)
	if got != script {
		t.Fatalf("decoded = %q, want %q", got, script)
	}
}

func TestWinWorker_PsSingleQuote(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"simple", "'simple'"},
		{"it's", "'it''s'"},
		{"a'b'c", "'a''b''c'"},
		{"", "''"},
	}
	for _, tc := range cases {
		if got := psSingleQuote(tc.in); got != tc.want {
			t.Errorf("psSingleQuote(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestWinWorker_WinTempDir(t *testing.T) {
	dir1 := winTempDir("img")
	dir2 := winTempDir("img")
	if !strings.HasPrefix(dir1, `C:\ProgramData\K2s\tmp\img-`) {
		t.Fatalf("unexpected prefix: %q", dir1)
	}
	if dir1 == dir2 {
		t.Fatalf("expected unique temp dirs, got identical %q", dir1)
	}
	if dirEmpty := winTempDir(""); !strings.HasPrefix(dirEmpty, `C:\ProgramData\K2s\tmp\k2s-`) {
		t.Fatalf("unexpected default prefix: %q", dirEmpty)
	}
}

func TestWinWorker_IsLinuxOnlySetup(t *testing.T) {
	t.Run("explicit LinuxOnly true", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, definitions.K2sRuntimeConfigFileName), []byte(`{"LinuxOnly":true}`), 0644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, windowsWorkerStateFileName), []byte(`{"ip":"172.19.1.101"}`), 0600); err != nil {
			t.Fatal(err)
		}
		if !isLinuxOnlySetup(dir) {
			t.Fatal("expected true when setup.json has LinuxOnly:true")
		}
	})

	t.Run("explicit LinuxOnly false", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, definitions.K2sRuntimeConfigFileName), []byte(`{"LinuxOnly":false}`), 0644); err != nil {
			t.Fatal(err)
		}
		if isLinuxOnlySetup(dir) {
			t.Fatal("expected false when setup.json has LinuxOnly:false")
		}
	})

	t.Run("missing setup.json with windows-worker.json present", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, windowsWorkerStateFileName), []byte(`{"ip":"172.19.1.101"}`), 0600); err != nil {
			t.Fatal(err)
		}
		if isLinuxOnlySetup(dir) {
			t.Fatal("expected false when windows-worker.json exists and setup.json is missing")
		}
	})

	t.Run("missing setup.json and missing windows-worker.json", func(t *testing.T) {
		dir := t.TempDir()
		if !isLinuxOnlySetup(dir) {
			t.Fatal("expected true when both setup.json and windows-worker.json are missing")
		}
	})

	t.Run("setup.json omits LinuxOnly with windows-worker.json present", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, definitions.K2sRuntimeConfigFileName), []byte(`{"SetupType":"k2s"}`), 0644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, windowsWorkerStateFileName), []byte(`{"ip":"172.19.1.101"}`), 0600); err != nil {
			t.Fatal(err)
		}
		if isLinuxOnlySetup(dir) {
			t.Fatal("expected false when setup.json omits LinuxOnly and windows-worker.json exists")
		}
	})
}

func TestWinWorker_ReadWindowsWorkerState(t *testing.T) {
	dir := t.TempDir()
	raw := `{"name":"k2s-win-worker","network":"k2s-switch","ip":"172.19.1.105","mac":"52:54:00:25:57:01","disk":"/var/lib/libvirt/images/k2s/k2s-win-worker.qcow2","proxy":"http://172.19.1.1:8181"}`
	if err := os.WriteFile(filepath.Join(dir, windowsWorkerStateFileName), []byte(raw), 0600); err != nil {
		t.Fatal(err)
	}
	state, err := readWindowsWorkerState(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if state.Name != "k2s-win-worker" || state.IP != "172.19.1.105" || state.Network != "k2s-switch" {
		t.Fatalf("unexpected state: %+v", state)
	}
}

func TestWinWorker_ResolveSSHConfigAndArgs(t *testing.T) {
	configDir := t.TempDir()
	homeDir := t.TempDir()

	// Write windows-worker.json with custom IP
	if err := os.WriteFile(filepath.Join(configDir, windowsWorkerStateFileName), []byte(`{"ip":"172.19.1.111"}`), 0600); err != nil {
		t.Fatal(err)
	}
	// Write known_hosts
	khPath := filepath.Join(configDir, filepath.FromSlash(windowsWorkerKnownHostsRel))
	if err := os.MkdirAll(filepath.Dir(khPath), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(khPath, []byte("172.19.1.111 ssh-ed25519 AAAA\n"), 0600); err != nil {
		t.Fatal(err)
	}
	// Write $HOME/.ssh/k2s/id_ed25519
	keyPath := filepath.Join(homeDir, ".ssh", "k2s", "id_ed25519")
	if err := os.MkdirAll(filepath.Dir(keyPath), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyPath, []byte("dummy-key"), 0600); err != nil {
		t.Fatal(err)
	}

	c := &winWorkerClient{
		configDir: configDir,
		getenvFn: func(k string) string {
			if k == "HOME" {
				return homeDir
			}
			return ""
		},
	}

	cfg := c.resolveSSHConfig()
	if cfg.User != "remote" || cfg.IP != "172.19.1.111" {
		t.Fatalf("unexpected user/ip: %+v", cfg)
	}
	if cfg.KnownHostsPath != khPath {
		t.Fatalf("KnownHostsPath = %q, want %q", cfg.KnownHostsPath, khPath)
	}
	if cfg.KeyPath != keyPath && cfg.KeyPath != rootK2sSSHKeyPath {
		t.Fatalf("unexpected KeyPath = %q", cfg.KeyPath)
	}

	scpArgs := cfg.scpToArgs("/tmp/img.tar", `C:\ProgramData\K2s\tmp\img.tar`)
	lastArg := scpArgs[len(scpArgs)-1]
	if lastArg != "remote@172.19.1.111:C:/ProgramData/K2s/tmp/img.tar" {
		t.Fatalf("unexpected scp target arg: %q", lastArg)
	}

	// Verify missing known_hosts falls back to StrictHostKeyChecking=no
	if err := os.Remove(khPath); err != nil {
		t.Fatal(err)
	}
	cfgNoKH := c.resolveSSHConfig()
	args := cfgNoKH.sshArgs("echo ok")
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "StrictHostKeyChecking=no") || !strings.Contains(joined, "UserKnownHostsFile=/dev/null") {
		t.Fatalf("expected StrictHostKeyChecking=no fallback, got: %v", args)
	}
	if !strings.Contains(joined, "BatchMode=yes") || !strings.Contains(joined, "ServerAliveInterval=15") {
		t.Fatalf("expected standard SSH options, got: %v", args)
	}
}

func TestWinWorker_RunWindowsPowerShell(t *testing.T) {
	t.Run("success strips CR and streams when showOutput is true", func(t *testing.T) {
		var outStream, errStream bytes.Buffer
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				if name != "ssh" {
					t.Fatalf("expected ssh command, got %q", name)
				}
				remoteCmd := args[len(args)-1]
				const prefix = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "
				if !strings.HasPrefix(remoteCmd, prefix) {
					t.Fatalf("unexpected remoteCmd: %q", remoteCmd)
				}
				decoded := decodeUTF16LEBase64(t, strings.TrimPrefix(remoteCmd, prefix))
				if !strings.Contains(decoded, "$ErrorActionPreference = 'Stop'") ||
					!strings.Contains(decoded, "$ProgressPreference = 'SilentlyContinue'") ||
					!strings.Contains(decoded, "Write-Output 'ok'") {
					t.Fatalf("unexpected decoded script: %q", decoded)
				}
				_, _ = io.WriteString(stdout, "line1\r\nline2\r\n")
				return nil
			},
		}

		c := &winWorkerClient{
			configDir:    t.TempDir(),
			runner:       runner,
			stdoutWriter: &outStream,
			stderrWriter: &errStream,
		}
		got, err := c.runWindowsPowerShell(context.Background(), "Write-Output 'ok'", true)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != "line1\nline2" {
			t.Fatalf("got %q, want %q", got, "line1\nline2")
		}
		if !strings.Contains(outStream.String(), "line1") {
			t.Fatalf("expected streamed output, got %q", outStream.String())
		}
	})

	t.Run("failure includes stderr", func(t *testing.T) {
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				_, _ = io.WriteString(stderr, "boom on windows\r\n")
				return errors.New("exit status 1")
			},
		}
		c := &winWorkerClient{
			configDir: t.TempDir(),
			runner:    runner,
		}
		_, err := c.runWindowsPowerShell(context.Background(), "throw 'boom'", false)
		if err == nil || !strings.Contains(err.Error(), "boom on windows") {
			t.Fatalf("expected error containing stderr, got: %v", err)
		}
	})
}

func TestWinWorker_ScpToAndFromWindows(t *testing.T) {
	runner := &mockCmdRunner{}
	c := &winWorkerClient{
		configDir: t.TempDir(),
		runner:    runner,
	}

	if err := c.scpToWindows(context.Background(), "/var/tmp/a.tar", `C:\ProgramData\K2s\tmp\a.tar`); err != nil {
		t.Fatalf("scpToWindows failed: %v", err)
	}
	if err := c.scpFromWindows(context.Background(), `C:\ProgramData\K2s\tmp\b.tar`, "/var/tmp/b.tar"); err != nil {
		t.Fatalf("scpFromWindows failed: %v", err)
	}

	if len(runner.calls) != 2 {
		t.Fatalf("expected 2 scp calls, got %d", len(runner.calls))
	}
	toCall := runner.calls[0]
	if toCall.name != "scp" || !reflect.DeepEqual(toCall.args[len(toCall.args)-2:], []string{"/var/tmp/a.tar", "remote@172.19.1.101:C:/ProgramData/K2s/tmp/a.tar"}) {
		t.Fatalf("unexpected scpToWindows call: %+v", toCall)
	}
	fromCall := runner.calls[1]
	if fromCall.name != "scp" || !reflect.DeepEqual(fromCall.args[len(fromCall.args)-2:], []string{"remote@172.19.1.101:C:/ProgramData/K2s/tmp/b.tar", "/var/tmp/b.tar"}) {
		t.Fatalf("unexpected scpFromWindows call: %+v", fromCall)
	}
}

func TestWinWorker_DiscoverNodes(t *testing.T) {
	t.Run("from kubectl get nodes", func(t *testing.T) {
		configDir := t.TempDir()
		_ = os.WriteFile(filepath.Join(configDir, definitions.K2sRuntimeConfigFileName), []byte(`{"LinuxOnly":false}`), 0644)

		kubectlJSON := `{
			"items": [
				{"metadata":{"name":"debian13-host","labels":{"node-role.kubernetes.io/control-plane":""}},"status":{"nodeInfo":{"operatingSystem":"linux"}}},
				{"metadata":{"name":"win-worker-01"},"status":{"nodeInfo":{"operatingSystem":"windows"}}}
			]
		}`
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				if name == "kubectl" {
					_, _ = io.WriteString(stdout, kubectlJSON)
					return nil
				}
				return errors.New("unexpected command")
			},
		}

		c := &winWorkerClient{
			configDir: configDir,
			runner:    runner,
			getenvFn:  func(string) string { return "/etc/kubernetes/admin.conf" },
		}
		linuxName, winName, err := c.discoverNodes(context.Background())
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if linuxName != "debian13-host" || winName != "win-worker-01" {
			t.Fatalf("got (%q, %q), want (%q, %q)", linuxName, winName, "debian13-host", "win-worker-01")
		}
	})

	t.Run("fallback to hostname and SSH COMPUTERNAME", func(t *testing.T) {
		configDir := t.TempDir()
		_ = os.WriteFile(filepath.Join(configDir, definitions.K2sRuntimeConfigFileName), []byte(`{"LinuxOnly":false}`), 0644)

		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				if name == "kubectl" {
					return errors.New("apiserver unreachable")
				}
				if name == "ssh" {
					_, _ = io.WriteString(stdout, "win2025-vm\r\n")
					return nil
				}
				return nil
			},
		}

		c := &winWorkerClient{
			configDir:  configDir,
			runner:     runner,
			hostnameFn: func() (string, error) { return "MyDebianHost", nil },
		}
		linuxName, winName, err := c.discoverNodes(context.Background())
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if linuxName != "mydebianhost" || winName != "win2025-vm" {
			t.Fatalf("got (%q, %q), want (%q, %q)", linuxName, winName, "mydebianhost", "win2025-vm")
		}
	})
}

func TestWinWorker_ResolveNodeTarget(t *testing.T) {
	setupClient := func(linuxOnly bool) *winWorkerClient {
		configDir := t.TempDir()
		content := `{"LinuxOnly":true}`
		if !linuxOnly {
			content = `{"LinuxOnly":false}`
		}
		_ = os.WriteFile(filepath.Join(configDir, definitions.K2sRuntimeConfigFileName), []byte(content), 0644)

		kubectlJSON := `{
			"items": [
				{"metadata":{"name":"k2s-linux-host","labels":{"node-role.kubernetes.io/control-plane":""}},"status":{"nodeInfo":{"operatingSystem":"linux"}}},
				{"metadata":{"name":"win-worker-vm"},"status":{"nodeInfo":{"operatingSystem":"windows"}}}
			]
		}`
		if linuxOnly {
			kubectlJSON = `{
				"items": [
					{"metadata":{"name":"k2s-linux-host","labels":{"node-role.kubernetes.io/control-plane":""}},"status":{"nodeInfo":{"operatingSystem":"linux"}}}
				]
			}`
		}

		return &winWorkerClient{
			configDir: configDir,
			runner: &mockCmdRunner{
				fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
					if name == "kubectl" {
						_, _ = io.WriteString(stdout, kubectlJSON)
					}
					return nil
				},
			},
		}
	}

	ctx := context.Background()

	t.Run("linux-only defaultAll=true", func(t *testing.T) {
		c := setupClient(true)
		tgt, err := c.resolveNodeTarget(ctx, nil, false, true)
		if err != nil {
			t.Fatal(err)
		}
		if !tgt.IncludeLinux || tgt.IncludeWindows || tgt.LinuxNodeName != "k2s-linux-host" {
			t.Fatalf("unexpected target: %+v", tgt)
		}
	})

	t.Run("linux-only --windows errors", func(t *testing.T) {
		c := setupClient(true)
		if _, err := c.resolveNodeTarget(ctx, nil, true, false); err == nil {
			t.Fatal("expected error for --windows on LinuxOnly")
		}
	})

	t.Run("linux-only requesting windows node errors", func(t *testing.T) {
		c := setupClient(true)
		if _, err := c.resolveNodeTarget(ctx, []string{"windows"}, false, true); err == nil {
			t.Fatal("expected error requesting windows node on LinuxOnly")
		}
	})

	t.Run("reverted defaultAll=true includes both", func(t *testing.T) {
		c := setupClient(false)
		tgt, err := c.resolveNodeTarget(ctx, nil, false, true)
		if err != nil {
			t.Fatal(err)
		}
		if !tgt.IncludeLinux || !tgt.IncludeWindows || tgt.WindowsNodeName != "win-worker-vm" {
			t.Fatalf("unexpected target: %+v", tgt)
		}
	})

	t.Run("reverted defaultAll=false includes linux only", func(t *testing.T) {
		c := setupClient(false)
		tgt, err := c.resolveNodeTarget(ctx, nil, false, false)
		if err != nil {
			t.Fatal(err)
		}
		if !tgt.IncludeLinux || tgt.IncludeWindows {
			t.Fatalf("unexpected target: %+v", tgt)
		}
	})

	t.Run("reverted --windows targets windows only", func(t *testing.T) {
		c := setupClient(false)
		tgt, err := c.resolveNodeTarget(ctx, nil, true, false)
		if err != nil {
			t.Fatal(err)
		}
		if tgt.IncludeLinux || !tgt.IncludeWindows {
			t.Fatalf("unexpected target: %+v", tgt)
		}
	})

	t.Run("reverted case-insensitive windows node match", func(t *testing.T) {
		c := setupClient(false)
		tgt, err := c.resolveNodeTarget(ctx, []string{"WIN-WORKER-VM"}, false, true)
		if err != nil {
			t.Fatal(err)
		}
		if tgt.IncludeLinux || !tgt.IncludeWindows {
			t.Fatalf("unexpected target: %+v", tgt)
		}
	})

	t.Run("reverted both nodes requested", func(t *testing.T) {
		c := setupClient(false)
		tgt, err := c.resolveNodeTarget(ctx, []string{"linux", "k2s-win-worker"}, false, false)
		if err != nil {
			t.Fatal(err)
		}
		if !tgt.IncludeLinux || !tgt.IncludeWindows {
			t.Fatalf("unexpected target: %+v", tgt)
		}
	})

	t.Run("reverted --windows with linux-only node errors", func(t *testing.T) {
		c := setupClient(false)
		if _, err := c.resolveNodeTarget(ctx, []string{"k2s-linux-host"}, true, false); err == nil {
			t.Fatal("expected error combining --windows with linux-only node")
		}
	})

	t.Run("reverted unknown node errors", func(t *testing.T) {
		c := setupClient(false)
		if _, err := c.resolveNodeTarget(ctx, []string{"nonexistent-node"}, false, true); err == nil {
			t.Fatal("expected error for unknown node")
		}
	})
}
