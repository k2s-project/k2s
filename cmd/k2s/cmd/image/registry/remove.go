// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package registry

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

var (
	removeExample = `
	# Remove registry in K2s
	k2s image registry rm ghcr.io

	# Remove registry only on one selected node
	k2s image registry rm ghcr.io --node worker-1

	# Remove registry on multiple selected nodes
	k2s image registry rm ghcr.io --nodes worker-1,winworker-1
`

	rmCmd = &cobra.Command{
		Use:     "rm",
		Short:   "Remove container registry",
		RunE:    removeRegistry,
		Example: removeExample,
	}
)

func init() {
	rmCmd.Flags().String(nodeFlag, "", "Node name to target (e.g. worker-1)")
	rmCmd.Flags().String(nodesFlag, "", "Comma-separated node names to target (e.g. worker-1,worker-2)")
	rmCmd.Flags().SortFlags = false
	rmCmd.Flags().PrintDefaults()
}

func removeRegistry(cmd *cobra.Command, args []string) error {
	if len(args) == 0 || args[0] == "" {
		return errors.New("no registry passed in CLI, use e.g. 'k2s image registry rm <registry-name>'")
	}

	cmdSession := common.StartCmdSession(cmd.CommandPath())
	registryName := args[0]

	slog.Info("Removing registry", "registry", registryName)

	pterm.Printfln("🤖 Removing registry '%s' from K2s cluster", registryName)

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", common.OutputFlagName, err)
	}

	nodesSelection, err := cmd.Flags().GetString(nodesFlag)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", nodesFlag, err)
	}

	nodeSelection, err := cmd.Flags().GetString(nodeFlag)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", nodeFlag, err)
	}

	nodesParam := strings.TrimSpace(nodesSelection)
	if nodesParam == "" {
		nodesParam = strings.TrimSpace(nodeSelection)
	}

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
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

	if err := validateNodeSelector(nodesParam, runtimeConfig); err != nil {
		return err
	}

	if err := context.Providers().Image.RegistryRemove(provider.ImageRegistryRemoveConfig{
		RegistryName: registryName,
		Nodes:        nodesParam,
		ShowOutput:   showOutput,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}
