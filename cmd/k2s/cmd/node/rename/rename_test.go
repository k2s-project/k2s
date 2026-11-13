// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package rename

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	contracts "github.com/k2s-project/k2s/internal/contracts/config"
	coreconfig "github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/k2s-project/k2s/internal/providers/kubeconfig"
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

type testNodeProvider struct {
	provider.NodeProvider
	calls int
	cfg   provider.NodeRenameConfig
	err   error
}

func (p *testNodeProvider) Rename(cfg provider.NodeRenameConfig) error {
	p.calls++
	p.cfg = cfg
	return p.err
}

func TestRenameDispatchesValidatedConfigAndReturnsProviderFailure(t *testing.T) {
	providerErr := errors.New("rename failed during drain")
	for _, expectedErr := range []error{nil, providerErr} {
		name := "success"
		if expectedErr != nil {
			name = "provider failure"
		}
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			if err := coreconfig.WriteRuntimeConfig(dir, "k2s", false, "test", "test-cluster", "kubemaster", false); err != nil {
				t.Fatal(err)
			}
			kubeConfigPath := filepath.Join(dir, kubeconfig.DefaultFileName)
			data := `apiVersion: v1
kind: Config
current-context: test-context
contexts:
- name: test-context
  context:
    cluster: test-cluster
    user: test-user
`
			if err := os.WriteFile(kubeConfigPath, []byte(data), 0o600); err != nil {
				t.Fatal(err)
			}
			t.Setenv("KUBECONFIG", kubeConfigPath)
			host := contracts.NewHostConfig(contracts.NewKubeConfig(dir, "", kubeConfigPath), nil, dir, dir, dir)
			nodeProvider := &testNodeProvider{err: expectedErr}
			cmdContext := common.NewCmdContext(contracts.NewK2sConfig(host, nil), nil, &provider.Registry{Node: nodeProvider})
			cmd := NewCmd()
			cmd.Flags().Bool(common.OutputFlagName, false, "")
			cmd.SilenceUsage = true
			cmd.SilenceErrors = true
			cmd.SetContext(context.WithValue(context.Background(), common.ContextKeyCmdContext, cmdContext))
			cmd.SetArgs([]string{"--old-name", "OLD-NODE", "--new-name", "NEW-NODE", "--timeout", "20m", "--force", "--output"})
			err := cmd.Execute()
			if !errors.Is(err, expectedErr) {
				t.Fatalf("Execute() error = %v, want %v", err, expectedErr)
			}
			want := provider.NodeRenameConfig{OldName: "old-node", NewName: "new-node", Timeout: 20 * time.Minute, Force: true, ShowOutput: true}
			if nodeProvider.calls != 1 || nodeProvider.cfg != want {
				t.Fatalf("Rename called %d times with %+v, want once with %+v", nodeProvider.calls, nodeProvider.cfg, want)
			}
		})
	}
}
