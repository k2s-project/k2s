// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

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

var repairCmd = &cobra.Command{
	Use:   "repair",
	Short: "Re-import missing system images on the control-plane from local archives",
	Example: `
  # Restore missing Kubernetes system images (e.g. after an unclean shutdown on an offline node)
  k2s image repair
`,
	RunE: repairImages,
}

func repairImages(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Println("🤖 Repairing system container images..")

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	if _, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir()); err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if err := context.Providers().Image.Repair(provider.ImageRepairConfig{
		ShowOutput: showOutput,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}
