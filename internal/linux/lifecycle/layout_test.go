// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package lifecycle

import (
	"bytes"
	"errors"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestScriptPath(t *testing.T) {
	t.Parallel()

	path, err := ScriptPath("/opt/k2s", LinuxOnly, "Install")
	if err != nil {
		t.Fatalf("ScriptPath() returned error: %v", err)
	}
	want := filepath.Join("/opt/k2s", "lib", "scripts", "linux", "debian", "linuxonly", "Install.sh")
	if path != want {
		t.Errorf("ScriptPath() = %q, want %q", path, want)
	}
}

func TestScriptPathRejectsUnknownScopeAndOperation(t *testing.T) {
	t.Parallel()

	if _, err := ScriptPath("/opt/k2s", "worker", "Install"); err == nil {
		t.Fatal("ScriptPath() accepted unsupported scope")
	}
	if _, err := ScriptPath("/opt/k2s", LinuxOnly, "Upgrade"); err == nil {
		t.Fatal("ScriptPath() accepted unsupported operation")
	}
}

func TestProvisioningScriptPath(t *testing.T) {
	t.Parallel()

	got := ProvisioningScriptPath("/opt/k2s")
	want := filepath.Join("/opt/k2s", "lib", "scripts", "linux", "debian", "linuxonly", "ProvisionPackages.sh")
	if got != want {
		t.Errorf("ProvisioningScriptPath() = %q, want %q", got, want)
	}
}

func TestLoadOperationDiagnostics(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash is not available")
	}
	module, err := filepath.Abs(filepath.Join("..", "..", "..", "lib", "modules", "linux", "cluster", "lifecycle.sh"))
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name    string
		args    []string
		mode    os.FileMode
		content string
		status  int
		detail  string
	}{
		{"no arguments", nil, 0, "", 2, "Expected --operation-file <configuration.json>"},
		{"missing filename", []string{"--operation-file"}, 0, "", 2, "Expected --operation-file <configuration.json>"},
		{"missing file", []string{"--operation-file", "operation.json"}, 0, "", 2, "Lifecycle operation file does not exist"},
		{"unsafe permissions", []string{"--operation-file", "operation.json"}, 0644, "{}", 1, "must have permissions 0600"},
		{"invalid configuration", []string{"--operation-file", "operation.json"}, 0600, "{}", 2, "Invalid lifecycle operation configuration"},
		{"invalid JSON", []string{"--operation-file", "operation.json"}, 0600, "{", 2, "Invalid lifecycle operation configuration"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if test.mode == 0600 {
				if _, err := exec.LookPath("jq"); err != nil {
					t.Skip("jq is not available")
				}
			}
			dir := t.TempDir()
			if test.mode != 0 {
				path := filepath.Join(dir, "operation.json")
				if err := os.WriteFile(path, []byte(test.content), test.mode); err != nil {
					t.Fatal(err)
				}
				if err := os.Chmod(path, test.mode); err != nil {
					t.Fatal(err)
				}
			}
			args := append([]string{"-s", "--", module}, test.args...)
			cmd := exec.Command("bash", args...)
			cmd.Dir = dir
			cmd.Stdin = strings.NewReader("set -euo pipefail\nsource \"$1\"\nshift\nk2s_load_operation \"$@\"\n")
			var stdout, stderr bytes.Buffer
			cmd.Stdout = &stdout
			cmd.Stderr = &stderr
			var exitError *exec.ExitError
			if err := cmd.Run(); !errors.As(err, &exitError) || exitError.ExitCode() != test.status {
				t.Fatalf("loader error = %v, want exit status %d", err, test.status)
			}
			if stdout.Len() != 0 || !strings.Contains(stderr.String(), test.detail) {
				t.Errorf("stdout = %q, stderr = %q; want diagnostic %q on stderr only", stdout.String(), stderr.String(), test.detail)
			}
		})
	}
}

func TestExecuteLogsScriptOutput(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash is not available")
	}
	var lifecycleScript strings.Builder
	for _, module := range []string{"common/logging.sh", "common/command.sh", "cluster/lifecycle.sh"} {
		data, err := os.ReadFile(filepath.Join("..", "..", "..", "lib", "modules", "linux", module))
		if err != nil {
			t.Fatal(err)
		}
		lifecycleScript.Write(data)
		lifecycleScript.WriteByte('\n')
	}
	lifecycleScript.WriteString(`
k2s_load_operation() {
	[[ "$1" == '--operation-file' ]] || return 2
	K2S_LOG_FILE="${2}.log"
}
test_operation() {
  printf '%s\n' 'stdout detail'
  printf '%s\n' 'stderr detail' >&2
  return 3
}
k2s_lock_and_run() { k2s_run test_operation; }
k2s_dispatch_lifecycle install "$@"
`)
	for _, test := range []struct {
		name     string
		script   string
		wantLogs []string
		status   int
	}{
		{"stderr", "echo 'must be run as root' >&2; exit 3", []string{`level=ERROR msg="must be run as root"`}, 3},
		{"merged output", "exec > >(tee /dev/null) 2>&1; echo 'must be run as root' >&2; exit 3", []string{`level=INFO msg="must be run as root"`}, 3},
		{"both streams", "echo 'stdout detail'; echo 'stderr detail' >&2; exit 3", []string{`level=INFO msg="stdout detail"`, `level=ERROR msg="stderr detail"`}, 3},
		{"lifecycle streams", lifecycleScript.String(), []string{`level=INFO msg="stdout detail"`, `level=ERROR msg="stderr detail"`, `level=INFO msg="Starting native Debian 13 lifecycle operation: install"`, `level=ERROR msg="Native Debian 13 lifecycle operation failed: install (exit code 3)"`}, 3},
		{"direct lifecycle streams", "unset K2S_LOG_TO_CLI\n" + lifecycleScript.String(), []string{`level=INFO msg="stdout detail"`, `level=ERROR msg="stderr detail"`}, 3},
		{"no output", "exit 3", nil, 3},
		{"success", "echo 'completed'", []string{`level=INFO msg=completed`}, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			var logs bytes.Buffer
			previousLogger := slog.Default()
			slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
			t.Cleanup(func() { slog.SetDefault(previousLogger) })

			installDir := t.TempDir()
			configDir := t.TempDir()
			script, err := ScriptPath(installDir, LinuxOnly, "Install")
			if err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Dir(script), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(script, []byte(test.script), 0600); err != nil {
				t.Fatal(err)
			}

			err = Execute("Install", Operation{InstallDir: installDir, ConfigDir: configDir})
			for _, want := range test.wantLogs {
				if count := strings.Count(logs.String(), want); count != 1 {
					t.Errorf("script logs = %q, want %q exactly once, got %d", logs.String(), want, count)
				}
			}
			shellLogs, globErr := filepath.Glob(filepath.Join(configDir, "*.log"))
			if globErr != nil {
				t.Fatal(globErr)
			}
			if test.name == "direct lifecycle streams" {
				if len(shellLogs) != 1 {
					t.Fatalf("direct script created %d shell logs, want 1", len(shellLogs))
				}
				data, readErr := os.ReadFile(shellLogs[0])
				if readErr != nil {
					t.Fatal(readErr)
				}
				for _, message := range []string{"stdout detail", "stderr detail", "Starting native Debian 13 lifecycle operation: install"} {
					if strings.Count(string(data), message) != 1 {
						t.Errorf("shell log = %q, want %q exactly once", data, message)
					}
				}
				if !strings.Contains(string(data), " [INFO] Starting native Debian 13 lifecycle operation: install") {
					t.Errorf("direct script log is missing its level prefix: %q", data)
				}
				for _, line := range strings.Split(string(data), "\n") {
					if strings.Contains(line, "Starting native Debian 13 lifecycle operation: install") {
						timestamp, _, _ := strings.Cut(line, " ")
						if _, err := time.Parse(time.RFC3339, timestamp); err != nil {
							t.Errorf("direct script log timestamp = %q: %v", timestamp, err)
						}
					}
				}
			} else if len(shellLogs) != 0 {
				t.Errorf("CLI invocation created redundant shell logs: %v", shellLogs)
			}
			if test.status == 0 {
				if err != nil {
					t.Fatalf("Execute() returned error: %v", err)
				}
				return
			}
			var exitError *exec.ExitError
			if !errors.As(err, &exitError) || exitError.ExitCode() != test.status {
				t.Fatalf("Execute() error = %v, want exit status %d", err, test.status)
			}
		})
	}
}
