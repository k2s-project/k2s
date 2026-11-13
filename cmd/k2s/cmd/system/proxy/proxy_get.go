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
	"github.com/k2s-project/k2s/internal/terminal"
	"github.com/spf13/cobra"
)

type ProxyServer struct {
	common.CmdResult
	Proxy *string `json:"proxy"`
}

var proxyGetCmd = &cobra.Command{
	Use:   "get",
	Short: "Get proxy information",
	Long:  "Get information about the proxy configuration",
	RunE:  getProxyServer,
}

func getProxyServer(cmd *cobra.Command, args []string) error {
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

	psCmd := utils.FormatScriptFilePath(path.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "proxy", "GetProxy.ps1"))
	var params []string
	proxy, err := powershell.ExecutePsWithStructuredResult[*ProxyServer](psCmd, "ProxyServer", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	terminal.NewTerminalPrinter().Println(*proxy.Proxy)

	return nil
}
