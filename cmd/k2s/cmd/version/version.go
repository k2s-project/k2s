// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package version

import (
	"github.com/k2s-project/k2s/cmd/k2s/common"

	"github.com/k2s-project/k2s/internal/cli"
	ve "github.com/k2s-project/k2s/internal/version"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

var VersionCmd = &cobra.Command{
	Use:   cli.VersionFlagName,
	Short: cli.NewVersionFlagHint("K2s / k2s"),
	RunE:  showVersion,
}

func init() {
	VersionCmd.Flags().SortFlags = false
	VersionCmd.Flags().PrintDefaults()
}

func showVersion(ccmd *cobra.Command, args []string) error {
	ve.GetVersion().Print(common.CliName, pterm.Printf)
	return nil
}
