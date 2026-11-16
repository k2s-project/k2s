// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package proxy

import (
	"github.com/k2s-project/k2s/cmd/k2s/cmd/system/proxy/override"
	"github.com/spf13/cobra"
)

var ProxyCmd = &cobra.Command{
	Use:   "proxy",
	Short: "Manage proxy settings",
}

func init() {
	ProxyCmd.AddCommand(proxySetCmd)
	ProxyCmd.AddCommand(proxyGetCmd)
	ProxyCmd.AddCommand(proxyShowCmd)
	ProxyCmd.AddCommand(proxyResetCmd)
	ProxyCmd.AddCommand(override.OverrideCmd)
}
