// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package remove

import (
	"errors"
	"path/filepath"
	"strconv"

	"github.com/pterm/pterm"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/utils"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

const (
	MachineName          = "name"
	MachineNameFlagUsage = "Hostname of the node"
)

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "remove",
		Short: "Remove a node from the cluster",
		Long:  "Removes a node from a K2s cluster",
		Example: `  # Remove a worker node by its hostname
  k2s node remove --name worker-node-1`,
		RunE: removeNode,
	}
	cmd.Flags().StringP(MachineName, "m", "", MachineNameFlagUsage)
	cmd.MarkFlagsOneRequired(MachineName)

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func removeNode(ccmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(ccmd.CommandPath())
	context := ccmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if err := context.EnsureK2sK8sContext(runtimeConfig.ClusterConfig().Name()); err != nil {
		return err
	}

	if runtimeConfig.InstallConfig().SetupName() != definitions.SetupNameK2s {
		return errors.New("removing node is not supported for this setup type. Aborting")
	}

	outputFlag, err := strconv.ParseBool(ccmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	machineName := ccmd.Flags().Lookup(MachineName).Value.String()

	pterm.Printfln("🤖 Removing node from K2s cluster")

	if err := context.Providers().Node.Remove(provider.NodeRemoveConfig{
		NodeName:   machineName,
		ShowOutput: outputFlag,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

func buildRemoveNodeCmd(flags *pflag.FlagSet, setupName string) (string, error) {
	outputFlag, err := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	if setupName != definitions.SetupNameK2s {
		return "", errors.New("removing node is not supported for this setup type. Aborting")
	}

	cmd := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "worker", "linux", "bare-metal", "Remove.ps1"))

	if outputFlag {
		cmd += " -ShowLogs"
	}

	machineName := flags.Lookup(MachineName).Value.String()

	if machineName != "" {
		cmd += " -NodeName " + machineName
	}

	return cmd, nil
}
