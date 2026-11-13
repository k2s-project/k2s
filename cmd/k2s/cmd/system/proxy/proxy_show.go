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

var proxyShowCmd = &cobra.Command{
	Use:   "show",
	Short: "Show proxy information",
	Long:  "This command shows information about the proxy",
	RunE:  showProxyConfig,
}

type ProxyInfo struct {
	common.CmdResult
	Proxy          *string  `json:"proxy"`
	ProxyOverrides []string `json:"proxyoverrides"`
}

func showProxyConfig(cmd *cobra.Command, args []string) error {
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

	psCmd := utils.FormatScriptFilePath(path.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "proxy", "ShowProxy.ps1"))
	var params []string
	proxyInfo, err := powershell.ExecutePsWithStructuredResult[*ProxyInfo](psCmd, "ShowProxyResult", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	printer := terminal.NewTerminalPrinter()

	// Display proxy configuration
	if proxyInfo.Proxy != nil && *proxyInfo.Proxy != "" {
		printer.Println("Proxy: " + *proxyInfo.Proxy)
	} else {
		printer.Println("Proxy: <not configured>")
	}

	// Display proxy overrides
	if len(proxyInfo.ProxyOverrides) > 0 {
		printer.Println("Proxy Overrides:")
		for _, v := range proxyInfo.ProxyOverrides {
			printer.Println("  - " + v)
		}
	} else {
		printer.Println("Proxy Overrides: <none>")
	}

	return nil
}
