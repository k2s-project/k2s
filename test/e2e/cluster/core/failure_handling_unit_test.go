// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: MIT

package core

import (
	"context"
	"os"
	"os/exec"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type expectedSetupFailure struct {
	failed bool
}

func (f *expectedSetupFailure) Fail() {
	f.failed = true
}

func TestCoreBeforeSuiteFailureState(t *testing.T) {
	const childEnv = "K2S_CORE_SETUP_FAILURE_CHILD"
	if os.Getenv(childEnv) == "1" {
		// Fail inside framework.Setup before any installation or cluster access.
		t.Setenv("SYSTEM_TEST_TIMEOUT", "invalid-duration")
		RegisterFailHandler(Fail)
		reporter := &expectedSetupFailure{}
		if RunSpecs(reporter, "Core setup failure regression") || !reporter.failed {
			t.Fatal("expected BeforeSuite to fail")
		}
		if !testFailed {
			t.Fatal("BeforeSuite failure was not retained for diagnostics and cleanup")
		}
		if suite != nil {
			t.Fatal("test unexpectedly initialized the cluster suite")
		}
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestCoreBeforeSuiteFailureState$")
	cmd.Env = append(os.Environ(), childEnv+"=1")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("setup failure regression: %v\n%s", err, output)
	}
}
