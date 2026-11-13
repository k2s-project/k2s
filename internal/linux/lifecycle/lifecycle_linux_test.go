// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package lifecycle

import (
	"bytes"
	"errors"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	startMessage  = "Starting native Debian 13 lifecycle operation: install"
	failedMessage = "Native Debian 13 lifecycle operation failed: install (exit code 3)"

	// Replaces the operation loader and the lock handling of the lifecycle module,
	// and runs a test operation that produces all kinds of output.
	testOperationScript = `
k2s_load_operation() {
	[[ "$1" == '--operation-file' ]] || return 2
	K2S_LOG_FILE="${2}.log"
}
test_operation() {
  k2s_log INFO 'logged detail'
  printf '%s\n' 'raw stdout detail'
  printf '%s\n' 'raw stderr detail' >&2
  [[ $K2S_TEST_STATUS -eq 0 ]] || k2s_log_prereq_failure 'prereq detail'
  k2s_run bash -c "echo 'run stdout detail'; echo 'run stderr detail' >&2; exit $K2S_TEST_STATUS"
}
k2s_lock_and_run() { test_operation; }
k2s_dispatch_lifecycle install "$@"
`
)

type recordingWriter struct {
	mu     sync.Mutex
	stdOut []string
	stdErr []string
}

type loadOperationCase struct {
	name    string
	args    []string
	mode    os.FileMode
	content string
	status  int
	detail  string
}

type executeCase struct {
	name         string
	status       int
	showLogs     bool
	wantStdOut   []string
	wantNoStdOut []string
	wantStdErr   []string
}

func (w *recordingWriter) WriteStdOut(message string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.stdOut = append(w.stdOut, message)
}

func (w *recordingWriter) WriteStdErr(message string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.stdErr = append(w.stdErr, message)
}

func (w *recordingWriter) Flush() {}

func (w *recordingWriter) stdOutText() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return strings.Join(w.stdOut, "\n")
}

func (w *recordingWriter) stdErrText() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return strings.Join(w.stdErr, "\n")
}

func TestLoadOperationDiagnostics(t *testing.T) {
	module, err := filepath.Abs(linuxModulePath(filepath.Join("cluster", "lifecycle.sh")))
	if err != nil {
		t.Fatal(err)
	}

	for _, test := range []loadOperationCase{
		{"no arguments", nil, 0, "", 2, "Expected --operation-file <configuration.json>"},
		{"missing filename", []string{"--operation-file"}, 0, "", 2, "Expected --operation-file <configuration.json>"},
		{"missing file", []string{"--operation-file", "operation.json"}, 0, "", 2, "Lifecycle operation file does not exist"},
		{"unsafe permissions", []string{"--operation-file", "operation.json"}, 0o644, "{}", 1, "must have permissions 0600"},
		{"invalid configuration", []string{"--operation-file", "operation.json"}, 0o600, "{}", 2, "Invalid lifecycle operation configuration"},
		{"invalid JSON", []string{"--operation-file", "operation.json"}, 0o600, "{", 2, "Invalid lifecycle operation configuration"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if test.mode == 0o600 {
				requireTools(t, "jq")
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

			cmd := exec.Command("bash", append([]string{"-s", "--", module}, test.args...)...)
			cmd.Dir = dir
			cmd.Stdin = strings.NewReader("set -euo pipefail\nsource \"$1\"\nshift\nk2s_load_operation \"$@\"\n")
			var stdout, stderr bytes.Buffer
			cmd.Stdout = &stdout
			cmd.Stderr = &stderr

			err := cmd.Run()

			assertExitStatus(t, err, test.status)
			if stdout.Len() != 0 || !strings.Contains(stderr.String(), test.detail) {
				t.Errorf("stdout = %q, stderr = %q; want diagnostic %q on stderr only", stdout.String(), stderr.String(), test.detail)
			}
		})
	}
}

func TestExecuteLetsScriptLogToFile(t *testing.T) {
	lifecycleScript := buildLifecycleScript(t)

	for _, test := range []executeCase{
		{
			name:         "success without showing logs",
			status:       0,
			wantNoStdOut: []string{startMessage, "logged detail", "raw stdout detail", "run stdout detail", "Running command"},
			wantStdErr:   []string{"raw stderr detail"},
		},
		{
			name:       "success showing logs",
			status:     0,
			showLogs:   true,
			wantStdOut: []string{startMessage, "logged detail", "raw stdout detail", "run stdout detail", "run stderr detail"},
			wantStdErr: []string{"raw stderr detail"},
		},
		{
			name:         "failure without showing logs",
			status:       3,
			wantNoStdOut: []string{startMessage, "logged detail", "raw stdout detail", "run stdout detail"},
			wantStdErr:   []string{"raw stderr detail", "[PREREQ-FAILED] prereq detail", "Command failed with exit code 3", failedMessage},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			slogs := captureSlog(t)
			t.Setenv("K2S_TEST_STATUS", strconv.Itoa(test.status))
			installDir := t.TempDir()
			configDir := t.TempDir()
			writeInstallScript(t, installDir, lifecycleScript)
			writer := &recordingWriter{}

			err := Execute("Install", Operation{InstallDir: installDir, ConfigDir: configDir}, writer, test.showLogs)

			assertContains(t, "stdout", writer.stdOutText(), test.wantStdOut)
			assertNotContains(t, "stdout", writer.stdOutText(), test.wantNoStdOut)
			assertContains(t, "stderr", writer.stdErrText(), test.wantStdErr)
			assertNotContains(t, "CLI log", slogs.String(), []string{"detail"})
			assertScriptLog(t, readSingleLogFile(t, configDir))
			assertExitStatus(t, err, test.status)
		})
	}
}

func requireTools(t *testing.T, tools ...string) {
	t.Helper()
	for _, tool := range tools {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s is not available", tool)
		}
	}
}

func linuxModulePath(module string) string {
	return filepath.Join("..", "..", "..", "lib", "modules", "linux", module)
}

func buildLifecycleScript(t *testing.T) string {
	t.Helper()

	var script strings.Builder
	for _, module := range []string{"common/logging.sh", "common/command.sh", "cluster/lifecycle.sh"} {
		data, err := os.ReadFile(linuxModulePath(module))
		if err != nil {
			t.Fatal(err)
		}
		script.Write(data)
		script.WriteByte('\n')
	}
	script.WriteString(testOperationScript)
	return script.String()
}

func writeInstallScript(t *testing.T, installDir string, content string) {
	t.Helper()

	script, err := ScriptPath(installDir, LinuxOnly, "Install")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(script), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(script, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func captureSlog(t *testing.T) *bytes.Buffer {
	t.Helper()

	var logs bytes.Buffer
	previousLogger := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
	t.Cleanup(func() { slog.SetDefault(previousLogger) })
	return &logs
}

func readSingleLogFile(t *testing.T, dir string) string {
	t.Helper()

	logFiles, err := filepath.Glob(filepath.Join(dir, "*.log"))
	if err != nil {
		t.Fatal(err)
	}
	if len(logFiles) != 1 {
		t.Fatalf("script created %d log files, want 1", len(logFiles))
	}
	data, err := os.ReadFile(logFiles[0])
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func assertContains(t *testing.T, stream string, got string, wanted []string) {
	t.Helper()

	for _, want := range wanted {
		if !strings.Contains(got, want) {
			t.Errorf("%s = %q, want %q", stream, got, want)
		}
	}
}

func assertNotContains(t *testing.T, stream string, got string, unwanted []string) {
	t.Helper()

	for _, notWanted := range unwanted {
		if strings.Contains(got, notWanted) {
			t.Errorf("%s = %q, must not contain %q", stream, got, notWanted)
		}
	}
}

func assertScriptLog(t *testing.T, log string) {
	t.Helper()

	for _, message := range []string{"logged detail", "raw stdout detail", "raw stderr detail", "run stdout detail", "run stderr detail", startMessage} {
		if strings.Count(log, message) != 1 {
			t.Errorf("script log = %q, want %q exactly once", log, message)
		}
	}
	if !strings.Contains(log, " [INFO] "+startMessage) {
		t.Errorf("script log is missing its level prefix: %q", log)
	}
	for _, line := range strings.Split(log, "\n") {
		if strings.Contains(line, startMessage) {
			timestamp, _, _ := strings.Cut(line, " ")
			if _, err := time.Parse(time.RFC3339, timestamp); err != nil {
				t.Errorf("script log timestamp = %q: %v", timestamp, err)
			}
		}
	}
}

func assertExitStatus(t *testing.T, err error, status int) {
	t.Helper()

	if status == 0 {
		if err != nil {
			t.Fatalf("returned error: %v", err)
		}
		return
	}
	var exitError *exec.ExitError
	if !errors.As(err, &exitError) || exitError.ExitCode() != status {
		t.Fatalf("error = %v, want exit status %d", err, status)
	}
}
