// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package install

import (
	ic "github.com/k2s-project/k2s/cmd/k2s/cmd/install/config"
	"github.com/spf13/cobra"
)

func bindPlatformFlags(cmd *cobra.Command) {
	cmd.Flags().String(ic.WorkerCPUsFlagName, "", ic.WorkerCPUsFlagUsage)
	cmd.Flags().String(ic.WorkerMemoryFlagName, "", ic.WorkerMemoryFlagUsage)
	cmd.Flags().String(ic.WorkerDiskSizeFlagName, "", ic.WorkerDiskSizeFlagUsage)
	cmd.Flags().String(ic.WindowsQCOW2PathFlagName, "", ic.WindowsQCOW2PathFlagUsage)
}