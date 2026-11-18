// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"errors"
	"strconv"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"
)

var cleanCmd = &cobra.Command{
	Use:   "clean",
	Short: "Remove container images from all nodes",
	Example: `
  # Remove user images from the default nodes (Linux control-plane and local Windows host)
  k2s image clean

  # Remove user images from a specific worker node only
  k2s image clean --node worker-1

  # Remove user images from multiple specific nodes only
  k2s image clean --nodes worker-1,worker-2
`,
	RunE: cleanImages,
}

func init() {
	addNodeSelectionFlags(cleanCmd)
	cleanCmd.Flags().SortFlags = false
	cleanCmd.Flags().PrintDefaults()
}

func cleanImages(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Println("🤖 Cleaning container images..")

	nodeSelector, err := parseNodeSelector(cmd)
	if err != nil {
		return err
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
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

	if err := validateNodeSelector(nodeSelector, runtimeConfig); err != nil {
		return err
	}

	if err := context.Providers().Image.Clean(provider.ImageCleanConfig{
		Nodes:      nodeSelector,
		ShowOutput: showOutput,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}
