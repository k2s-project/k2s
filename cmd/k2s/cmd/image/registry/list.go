// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package registry

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	"github.com/k2s-project/k2s/cmd/k2s/utils"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/providers/powershell"
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
	nodeSelection, err := cmd.Flags().GetString(nodeFlag)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", nodeFlag, err)
	}

	nodesSelection, err := cmd.Flags().GetString(nodesFlag)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", nodesFlag, err)
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

	// On Linux host or Linux-only setup, never invoke PowerShell; print registries directly from config
	if runtime.GOOS == "linux" || runtimeConfig.InstallConfig().LinuxOnly() {
		return printRegistries(runtimeConfig.ClusterConfig().Registries())
	}

	// If node(s) specified on Windows host, call PowerShell script
	if nodesParam != "" {
		return listRegistriesOnNodes(cmd, nodesParam)
	}

	return printRegistries(runtimeConfig.ClusterConfig().Registries())
}

func printRegistries(registries []cconfig.Registry) error {
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

func listRegistriesOnNodes(cmd *cobra.Command, nodesParam string) error {
	psCmd := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "image", "registry", "List-Registries.ps1"))

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", common.OutputFlagName, err)
	}

	params := []string{
		" -Nodes " + utils.EscapeWithSingleQuotes(nodesParam),
	}

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	return nil
}
