// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package install

import (
	ic "github.com/k2s-project/k2s/cmd/k2s/cmd/install/config"
	"github.com/spf13/cobra"
)

func bindPlatformFlags(cmd *cobra.Command) {
	cmd.Flags().String(ic.ControlPlaneCPUsFlagName, "", ic.ControlPlaneCPUsFlagUsage)
	cmd.Flags().String(ic.ControlPlaneMemoryFlagName, "", ic.ControlPlaneMemoryFlagUsage)
	cmd.Flags().String(ic.ControlPlaneMemoryMinFlagName, "", ic.ControlPlaneMemoryMinFlagUsage)
	cmd.Flags().String(ic.ControlPlaneMemoryMaxFlagName, "", ic.ControlPlaneMemoryMaxFlagUsage)
	cmd.Flags().String(ic.ControlPlaneDiskSizeFlagName, "", ic.ControlPlaneDiskSizeFlagUsage)
	cmd.Flags().Bool(ic.WslFlagName, false, ic.WslFlagUsage)
	cmd.Flags().String(ic.K8sBinFlagName, "", ic.K8sBinFlagUsage)
}