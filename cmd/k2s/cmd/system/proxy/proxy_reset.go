// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package proxy

import (
	"errors"
	"path"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/utils"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/providers/powershell"
	"github.com/spf13/cobra"
)

var proxyResetCmd = &cobra.Command{
	Use:   "reset",
	Short: "Reset the proxy settings",
	Long:  "This command resets the proxy settings to their default values.",
	RunE:  resetProxyConfig,
}

func resetProxyConfig(cmd *cobra.Command, args []string) error {
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	_, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		return err
	}

	psCmd := utils.FormatScriptFilePath(path.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "proxy", "ResetProxy.ps1"))
	var params []string

	result, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "ProxyOverrides", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if result != nil && result.Failure != nil {
		return result.Failure
	}

	return nil
}
