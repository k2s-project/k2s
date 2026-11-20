// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package remove

import (
	"github.com/k2s-project/k2s/internal/windows/device"
	"github.com/spf13/cobra"
)

const (
	hardwareInstanceIdFlag = "hardware-instance-id"
	removeExample          = `
	# Remove device with specific hardware instance ID
	devgon remove -i ROOT\NET\0001
  `
)

var (
	RemoveDeviceCmd = &cobra.Command{
		Use:     "remove",
		Short:   "Removes a device",
		Long:    ``,
		RunE:    execRemoveDeviceCmd,
		Example: removeExample,
	}
)

func init() {
	includeAddFlags(RemoveDeviceCmd)
}

func includeAddFlags(cmd *cobra.Command) {
	cmd.Flags().StringP(hardwareInstanceIdFlag, "i", "", `Hardware instance ID, e.g. 'ROOT\NET\0001'`)
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func execRemoveDeviceCmd(cmd *cobra.Command, args []string) error {
	hardwareInstanceId := cmd.Flags().Lookup(hardwareInstanceIdFlag).Value.String()

	return device.Remove(hardwareInstanceId)
}
