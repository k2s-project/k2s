//// SPDX-FileCopyrightText:  © 2024 The K2s Authors
//// SPDX-License-Identifier: Apache-2.0

//go:build windows

package cmd

import (
	"log/slog"

	"github.com/k2s-project/k2s/cmd/devgon/cmd/install"
	"github.com/k2s-project/k2s/cmd/devgon/cmd/remove"
	"github.com/k2s-project/k2s/cmd/devgon/cmd/version"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/internal/logging"

	"github.com/spf13/cobra"
)

func Create(levelVar *slog.LevelVar) *cobra.Command {
	verbosity := ""
	cmd := &cobra.Command{
		Use:   "devgon",
		Short: "devgon – command-line tool to replace Microsoft's devcon.exe",
		Long:  ``,

		SilenceErrors:     true,
		SilenceUsage:      true,
		CompletionOptions: cobra.CompletionOptions{DisableDefaultCmd: true},
		PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
			return logging.SetVerbosity(verbosity, levelVar)
		},
	}

	cmd.AddCommand(install.InstallDeviceCmd)
	cmd.AddCommand(remove.RemoveDeviceCmd)
	cmd.AddCommand(version.VersionCmd)

	cmd.PersistentFlags().StringVarP(&verbosity, cli.VerbosityFlagName, cli.VerbosityFlagShorthand, logging.LevelToLowerString(slog.LevelInfo), cli.VerbosityFlagHelp())

	return cmd
}
