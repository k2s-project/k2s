// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package reset

import (
	"errors"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"

	"github.com/spf13/cobra"
)

var ResetCmd = &cobra.Command{
	Use:   "reset",
	Short: "Reset options",
	RunE:  resetSystem,
}

func init() {
	ResetCmd.AddCommand(resetNetworkCmd)
	ResetCmd.Flags().SortFlags = false
	ResetCmd.Flags().PrintDefaults()
}

func resetSystem(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	_, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if !errors.Is(err, cconfig.ErrSystemInCorruptedState) && !errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return err
		}
	}

	if err := context.Providers().System.Reset(provider.SystemResetConfig{}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}
