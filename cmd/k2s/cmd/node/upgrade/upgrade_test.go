// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package upgrade

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	systemupgrade "github.com/k2s-project/k2s/cmd/k2s/cmd/system/upgrade"
	"github.com/k2s-project/k2s/cmd/k2s/utils/logging"
	contracts "github.com/k2s-project/k2s/internal/contracts/config"
	coreconfig "github.com/k2s-project/k2s/internal/core/config"
	bl "github.com/k2s-project/k2s/internal/logging"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/k2s-project/k2s/internal/providers/kubeconfig"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

func TestUpgradeCommandRequiresNodeAndPath(t *testing.T) {
	for _, args := range [][]string{nil, {"--node", "k2s-nodepkg-debian13"}, {"--path", "debian13-node.zip"}} {
		cmd := NewCmd()
		cmd.SilenceUsage = true
		cmd.SilenceErrors = true
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), "required flag(s)") {
			t.Fatalf("Execute() error = %v for %v, want required flag error", err, args)
		}
	}
}

func TestUpgradeCommandRejectsInvalidInputBeforeLoadingContext(t *testing.T) {
	nodePackage := writeFile(t, "debian13-node.zip")
	textFile := writeFile(t, "debian13-node.txt")
	for _, tt := range []struct {
		args    []string
		wantErr string
	}{
		{[]string{"--node", "k2s-nodepkg-debian13", "--path", filepath.Join(t.TempDir(), "missing.zip")}, "does not exist"},
		{[]string{"--node", "k2s-nodepkg-debian13", "--path", textFile}, "must be a .zip file"},
		{[]string{"--node", "k2s-nodepkg-debian13;hostname", "--path", nodePackage}, "invalid node name"},
		{[]string{"--node", "k2s-nodepkg-debian13", "--path", nodePackage, "unexpected"}, "unknown command"},
	} {
		cmd := NewCmd()
		cmd.Flags().Bool(common.OutputFlagName, false, "")
		cmd.SilenceUsage = true
		cmd.SilenceErrors = true
		cmd.SetArgs(tt.args)
		if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), tt.wantErr) {
			t.Fatalf("Execute() error = %v for %v, want error containing %q", err, tt.args, tt.wantErr)
		}
	}
}

type testNodeProvider struct {
	provider.NodeProvider
	calls []provider.NodeUpgradeConfig
	err   error
}

func (p *testNodeProvider) Upgrade(cfg provider.NodeUpgradeConfig) error {
	p.calls = append(p.calls, cfg)
	return p.err
}

func TestUpgradeDispatchesValidatedConfigAndReturnsProviderFailure(t *testing.T) {
	providerErr := errors.New("node upgrade failed during drain")
	for _, expectedErr := range []error{nil, providerErr} {
		name := "success"
		if expectedErr != nil {
			name = "provider failure"
		}
		t.Run(name, func(t *testing.T) {
			nodePackage := writeFile(t, "debian13-node-delta-v1.7.0-to-v1.8.0.zip")
			nodeProvider := &testNodeProvider{err: expectedErr}

			err := execute(t, NewCmd(), newCmdContext(t, nodeProvider), "--node", "K2S-NODEPKG-DEBIAN13", "--path", nodePackage, "--output")

			if !errors.Is(err, expectedErr) {
				t.Fatalf("Execute() error = %v, want %v", err, expectedErr)
			}
			want := provider.NodeUpgradeConfig{NodeName: "k2s-nodepkg-debian13", NodePackagePath: nodePackage, ShowOutput: true}
			if len(nodeProvider.calls) != 1 || nodeProvider.calls[0] != want {
				t.Fatalf("Upgrade called with %+v, want once with %+v", nodeProvider.calls, want)
			}
		})
	}
}

func TestUpgradeAndSystemUpgradeWithNodeAreEquivalent(t *testing.T) {
	nodePackage := writeFile(t, "debian13-node-v1.8.0.zip")
	providerErr := errors.New("node upgrade failed during drain")
	for _, tt := range []struct {
		name        string
		args        []string
		providerErr error
	}{
		{"upgrade", []string{"--node", "k2s-nodepkg-debian13", "--path", nodePackage}, nil},
		{"upgrade with short flags and output", []string{"-n", "K2S-NODEPKG-DEBIAN13", "--path", nodePackage, "-o"}, nil},
		{"provider failure", []string{"--node", "k2s-nodepkg-debian13", "--path", nodePackage}, providerErr},
		{"missing node package", []string{"--node", "k2s-nodepkg-debian13", "--path", filepath.Join(t.TempDir(), "missing.zip")}, nil},
		{"invalid node name", []string{"--node", "k2s_nodepkg_debian13", "--path", nodePackage}, nil},
	} {
		t.Run(tt.name, func(t *testing.T) {
			nodeUpgradeProvider := &testNodeProvider{err: tt.providerErr}
			nodeUpgradeErr := execute(t, NewCmd(), newCmdContext(t, nodeUpgradeProvider), tt.args...)

			t.Cleanup(func() { resetFlags(systemupgrade.UpgradeCmd) })
			systemUpgradeProvider := &testNodeProvider{err: tt.providerErr}
			systemUpgradeErr := execute(t, systemupgrade.UpgradeCmd, newCmdContext(t, systemUpgradeProvider), tt.args...)

			if fmt.Sprint(nodeUpgradeErr) != fmt.Sprint(systemUpgradeErr) {
				t.Fatalf("'node upgrade' error = %v, 'system upgrade' error = %v", nodeUpgradeErr, systemUpgradeErr)
			}
			if !slices.Equal(nodeUpgradeProvider.calls, systemUpgradeProvider.calls) {
				t.Fatalf("'node upgrade' calls = %+v, 'system upgrade' calls = %+v", nodeUpgradeProvider.calls, systemUpgradeProvider.calls)
			}
		})
	}
}

func writeFile(t *testing.T, name string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte("zip"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// newCmdContext prepares an installed K2s setup and returns a command context with the given node provider.
func newCmdContext(t *testing.T, nodeProvider provider.NodeProvider) *common.CmdContext {
	t.Helper()
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

	// The upgrade switches to a dedicated CLI log file and back; keep both log files in the test directory.
	t.Setenv(bl.LogRootEnvVar, filepath.Join(dir, "logs"))
	bl.ResetRootLogDirCache()
	defaultLogger := slog.Default()
	logger := logging.NewSlogger()
	t.Cleanup(func() {
		logger.Close()
		slog.SetDefault(defaultLogger)
		bl.ResetRootLogDirCache()
	})

	host := contracts.NewHostConfig(contracts.NewKubeConfig(dir, "", kubeConfigPath), nil, dir, dir, dir)
	return common.NewCmdContext(contracts.NewK2sConfig(host, nil), logger, &provider.Registry{Node: nodeProvider})
}

func execute(t *testing.T, cmd *cobra.Command, cmdContext *common.CmdContext, args ...string) error {
	t.Helper()
	if cmd.Flags().Lookup(common.OutputFlagName) == nil {
		cmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	}
	cmd.SilenceUsage = true
	cmd.SilenceErrors = true
	cmd.SetContext(context.WithValue(context.Background(), common.ContextKeyCmdContext, cmdContext))
	cmd.SetArgs(args)
	return cmd.Execute()
}

// resetFlags restores the defaults of a command that is shared between tests.
func resetFlags(cmd *cobra.Command) {
	cmd.Flags().VisitAll(func(flag *pflag.Flag) {
		_ = flag.Value.Set(flag.DefValue)
		flag.Changed = false
	})
}
