// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package rename

import (
	"errors"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/spf13/cobra"
)

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "rename",
		Short: "Repair a worker node identity after changing its hostname",
		Long: "Reissues the kubelet certificate and replaces the Kubernetes Node identity of a managed worker: " +
			"a Linux worker added with 'k2s node add' or the local Windows worker host. " +
			"Run from the Windows K2s host after changing the worker's OS hostname. Does not change the OS hostname.",
		Example: "  k2s node rename --old-name OLD-NODE --new-name NEW-NODE",
		Args:    cobra.NoArgs,
		RunE:    renameNode,
	}
	cmd.Flags().String("old-name", "", "Existing Kubernetes Node name")
	cmd.Flags().String("new-name", "", "Current OS hostname of the worker")
	cmd.Flags().Duration("timeout", 15*time.Minute, "Maximum repair duration (1m to 24h)")
	cmd.Flags().Bool("force", false, "Continue when a partially registered replacement Node carries workloads, without migrating them first")
	cmd.MarkFlagRequired("old-name")
	cmd.MarkFlagRequired("new-name")
	return cmd
}

func renameNode(cmd *cobra.Command, _ []string) error {
	oldName, err := cmd.Flags().GetString("old-name")
	if err != nil {
		return err
	}
	newName, err := cmd.Flags().GetString("new-name")
	if err != nil {
		return err
	}
	timeout, err := cmd.Flags().GetDuration("timeout")
	if err != nil {
		return err
	}
	force, err := cmd.Flags().GetBool("force")
	if err != nil {
		return err
	}
	cfg, err := (provider.NodeRenameConfig{OldName: oldName, NewName: newName, Timeout: timeout, Force: force}).Validated()
	if err != nil {
		return err
	}
	session := common.StartCmdSession(cmd.CommandPath())
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtime, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}
	if runtime.InstallConfig().SetupName() != definitions.SetupNameK2s {
		return errors.New("node rename is not supported for this setup type")
	}
	if err := context.EnsureK2sK8sContext(runtime.ClusterConfig().Name()); err != nil {
		return err
	}
	cfg.ShowOutput, err = cmd.Flags().GetBool(common.OutputFlagName)
	if err != nil {
		return err
	}
	if err := context.Providers().Node.Rename(cfg); err != nil {
		return err
	}
	session.Finish()
	return nil
}
