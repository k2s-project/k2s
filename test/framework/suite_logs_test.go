// SPDX-FileCopyrightText: (C) 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package framework

import (
	"path/filepath"
	"runtime"
	"testing"

	contracts "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/logging"
	"github.com/k2s-project/k2s/test/framework/k2s"
)

func TestLogsDirUsesInstalledWindowsConfiguration(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows installation log discovery")
	}
	t.Setenv(logging.LogRootEnvVar, "")
	t.Setenv("K2S_TEST_LOG_DRIVE", `D:\custom logs`)
	for _, path := range []string{`C:\var\log`, `D:\var\log`, `${K2S_TEST_LOG_DRIVE}\k2s`} {
		t.Run(path, func(t *testing.T) {
			host := contracts.NewHostConfig(nil, nil, "", "", path)
			suite := &K2sTestSuite{setupInfo: &k2s.SetupInfo{
				Config: *contracts.NewK2sConfig(host, nil),
			}}
			want := path
			if path == `${K2S_TEST_LOG_DRIVE}\k2s` {
				want = `D:\custom logs\k2s`
			}
			if got := suite.LogsDir(); got != filepath.Clean(want) {
				t.Fatalf("LogsDir() = %q, want %q", got, want)
			}
		})
	}
}

func TestLogsDirPreservesExplicitOverride(t *testing.T) {
	override := t.TempDir()
	t.Setenv(logging.LogRootEnvVar, override)
	logging.ResetRootLogDirCache()
	t.Cleanup(logging.ResetRootLogDirCache)
	host := contracts.NewHostConfig(nil, nil, "", "", `D:\var\log`)
	for name, suite := range map[string]*K2sTestSuite{
		"configured installation": {setupInfo: &k2s.SetupInfo{Config: *contracts.NewK2sConfig(host, nil)}},
		"without installation":    {},
	} {
		t.Run(name, func(t *testing.T) {
			if got := suite.LogsDir(); got != override {
				t.Fatalf("LogsDir() = %q, want override %q", got, override)
			}
		})
	}
}
