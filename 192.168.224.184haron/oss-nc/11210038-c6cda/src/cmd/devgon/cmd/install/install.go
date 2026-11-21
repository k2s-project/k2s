// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package install

import (
	"github.com/k2s-project/k2s/internal/windows/device"
	"github.com/spf13/cobra"
)

const (
	infPathFlag    = "inf-path"
	hardwareIdFlag = "hardware-id"
)

var (
	installExample = `
  # Install device from INF file with specific hardware ID
  devgon install -p c:\windows\inf\netloop.inf -i *MSLOOP
`
	InstallDeviceCmd = &cobra.Command{
		Use:     "install",
		Short:   "Installs a device",
		Long:    ``,
		RunE:    installDevice,
		Example: installExample,
	}
)

func init() {
	includeAddFlags(InstallDeviceCmd)
}

func includeAddFlags(cmd *cobra.Command) {
	cmd.Flags().StringP(infPathFlag, "p", "", `Path to the INF file, e.g. c:\windows\inf\netloop.inf`)
	cmd.Flags().StringP(hardwareIdFlag, "i", "", `Hardware ID, e.g. '*MSLOOP'`)
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func installDevice(cmd *cobra.Command, args []string) error {
	infPath := cmd.Flags().Lookup(infPathFlag).Value.String()
	hardwareId := cmd.Flags().Lookup(hardwareIdFlag).Value.String()

	return device.Install(infPath, hardwareId)
}
