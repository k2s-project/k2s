// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package registry

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/k2s-project/k2s/internal/terminal"

	"github.com/spf13/cobra"
)

var (
	listExample = `
	# List configured image registries in K2s 
	k2s image registry ls

	# List registries on a specific node
	k2s image registry ls --node worker-1

	# List registries on multiple specific nodes
	k2s image registry ls --nodes worker-1,worker-2
`

	listCmd = &cobra.Command{
		Use:     "ls",
		Short:   "List configured registries",
		RunE:    listRegistries,
		Example: listExample,
	}
)

func init() {
	listCmd.Flags().String(nodeFlag, "", "Node name to target (e.g. worker-1)")
	listCmd.Flags().String(nodesFlag, "", "Comma-separated node names to target (e.g. worker-1,worker-2)")
	listCmd.Flags().SortFlags = false
	listCmd.Flags().PrintDefaults()
}

func listRegistries(cmd *cobra.Command, args []string) error {
	nodesParam, err := common.ParseNodeSelector(cmd, nodeFlag, nodesFlag)
	if err != nil {
		return err
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

	if nodesParam == "" {
		return printRegistries(runtimeConfig.ClusterConfig().Registries())
	}

	if err := common.ValidateNodeSelector(nodesParam, runtimeConfig); err != nil {
		return err
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", common.OutputFlagName, err)
	}

	registries, err := context.Providers().Image.RegistryList(cmd.Context(), provider.ImageRegistryListConfig{
		Nodes:      splitNodes(nodesParam),
		ShowOutput: showOutput,
	})
	if err != nil {
		return err
	}

	if registries != nil {
		return printRegistries(registries)
	}

	return nil
}

func splitNodes(nodesParam string) []string {
	parts := strings.Split(nodesParam, ",")
	var nodes []string
	for _, p := range parts {
		trimmed := strings.TrimSpace(p)
		if trimmed != "" {
			nodes = append(nodes, trimmed)
		}
	}
	return nodes
}

func printRegistries[T ~string](registries []T) error {
	terminalPrinter := terminal.NewTerminalPrinter()

	if len(registries) == 0 {
		terminalPrinter.PrintInfoln("No registries configured!")
		return nil
	}

	terminalPrinter.PrintHeader("Configured registries:")
	for _, v := range registries {
		terminalPrinter.Printfln(" - %s", v)
	}

	return nil
}
