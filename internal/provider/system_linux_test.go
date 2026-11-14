// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	linuxlifecycle "github.com/k2s-project/k2s/internal/linux/lifecycle"
)

type compactStubs struct {
	domState   string
	confirm    bool
	prompted   bool
	executed   bool
	operation  string
	input      linuxlifecycle.Operation
	virshCalls int
}

func stubCompact(t *testing.T, s *compactStubs) {
	t.Helper()
	origRun, origConfirm, origExecute := linuxRunCombinedOutput, linuxConfirm, linuxExecuteLifecycle
	t.Cleanup(func() {
		linuxRunCombinedOutput, linuxConfirm, linuxExecuteLifecycle = origRun, origConfirm, origExecute
	})
	linuxRunCombinedOutput = func(name string, args ...string) ([]byte, error) {
		s.virshCalls++
		if name != "virsh" || len(args) != 2 || args[0] != "domstate" || args[1] != "k2s-win-worker" {
			t.Fatalf("unexpected command: %s %v", name, args)
		}
		return []byte(s.domState + "\n\n"), nil
	}
	linuxConfirm = func(string) bool {
		s.prompted = true
		return s.confirm
	}
	linuxExecuteLifecycle = func(operation string, input linuxlifecycle.Operation) error {
		s.executed = true
		s.operation = operation
		s.input = input
		return nil
	}
}

func newCompactProvider(t *testing.T, withWorker bool) *linuxSystemProvider {
	t.Helper()
	configDir := t.TempDir()
	if withWorker {
		state := `{"name":"k2s-win-worker","disk":"/var/lib/libvirt/images/k2s/k2s-win-worker.qcow2"}`
		if err := os.WriteFile(filepath.Join(configDir, linuxWindowsWorkerStateFile), []byte(state), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return &linuxSystemProvider{installDir: "/opt/k2s", configDir: configDir}
}

func TestCompact_RejectsLinuxOnlySetup(t *testing.T) {
	s := &compactStubs{}
	stubCompact(t, s)

	err := newCompactProvider(t, true).Compact(SystemCompactConfig{LinuxOnly: true, Yes: true})

	if !errors.Is(err, ErrNotSupported) {
		t.Fatalf("expected ErrNotSupported, got: %v", err)
	}
	if s.executed {
		t.Fatal("lifecycle must not run for a Linux-only setup")
	}
}

func TestCompact_RejectsMissingWindowsWorker(t *testing.T) {
	s := &compactStubs{}
	stubCompact(t, s)

	err := newCompactProvider(t, false).Compact(SystemCompactConfig{Yes: true})

	if !errors.Is(err, ErrNotSupported) {
		t.Fatalf("expected ErrNotSupported, got: %v", err)
	}
	if s.executed {
		t.Fatal("lifecycle must not run without a Windows worker")
	}
}

func TestCompact_RejectsWorkerStateWithoutName(t *testing.T) {
	s := &compactStubs{}
	stubCompact(t, s)
	p := newCompactProvider(t, false)
	if err := os.WriteFile(filepath.Join(p.configDir, linuxWindowsWorkerStateFile), []byte(`{"disk":"/tmp/disk.qcow2"}`), 0600); err != nil {
		t.Fatal(err)
	}

	err := p.Compact(SystemCompactConfig{Yes: true})

	if err == nil || errors.Is(err, ErrNotSupported) {
		t.Fatalf("expected an invalid state error, got: %v", err)
	}
	if s.executed {
		t.Fatal("lifecycle must not run with an invalid worker state")
	}
}

func TestCompact_YesSkipsPromptAndPassesNoRestart(t *testing.T) {
	s := &compactStubs{domState: "running"}
	stubCompact(t, s)
	p := newCompactProvider(t, true)

	if err := p.Compact(SystemCompactConfig{Yes: true, NoRestart: true}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if s.prompted || s.virshCalls != 0 {
		t.Fatal("--yes must skip the worker state check and the prompt")
	}
	want := linuxlifecycle.Operation{InstallDir: "/opt/k2s", ConfigDir: p.configDir, NoRestart: true}
	if !s.executed || s.operation != "Compact" || !reflect.DeepEqual(s.input, want) {
		t.Fatalf("unexpected lifecycle call: executed=%v operation=%q input=%+v", s.executed, s.operation, s.input)
	}
}

func TestCompact_PromptsWhenWorkerIsRunning(t *testing.T) {
	for name, confirm := range map[string]bool{"confirmed": true, "declined": false} {
		t.Run(name, func(t *testing.T) {
			s := &compactStubs{domState: "running", confirm: confirm}
			stubCompact(t, s)

			if err := newCompactProvider(t, true).Compact(SystemCompactConfig{}); err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if !s.prompted {
				t.Fatal("expected a confirmation prompt for a running worker")
			}
			if s.executed != confirm {
				t.Fatalf("lifecycle executed = %v, want %v", s.executed, confirm)
			}
		})
	}
}

func TestCompact_DoesNotPromptWhenWorkerIsShutOff(t *testing.T) {
	s := &compactStubs{domState: "shut off"}
	stubCompact(t, s)

	if err := newCompactProvider(t, true).Compact(SystemCompactConfig{}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if s.prompted {
		t.Fatal("a stopped worker must not require confirmation")
	}
	if !s.executed || s.operation != "Compact" {
		t.Fatalf("expected the Compact lifecycle operation, got executed=%v operation=%q", s.executed, s.operation)
	}
}
