// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package list

import (
	"errors"
	"fmt"
	"log/slog"

	"github.com/spf13/cobra"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/k2s-project/k2s/internal/terminal"

	cc "github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/common"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/list/print"
	"github.com/k2s-project/k2s/internal/core/addons"
	"github.com/k2s-project/k2s/internal/core/config"
)

const (
	Enabled        = "Enabled"
	Disabled       = "Disabled"
	outputFlagName = "output"
	jsonOption     = "json"
)

func NewCommand(allAddons addons.Addons) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "ls",
		Short: "List addons available for K2s",
		RunE: func(cmd *cobra.Command, args []string) error {
			return listAddons(cmd, allAddons)
		},
	}

	cmd.Flags().StringP(outputFlagName, "o", "", "Output format modifier. Currently supported: 'json' for output as JSON structure")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func listAddons(cmd *cobra.Command, allAddons addons.Addons) error {
	common.LogAddons(allAddons)

	slog.Info("Listing addons")

	outputOption, err := cmd.Flags().GetString(outputFlagName)
	if err != nil {
		return err
	}

	if outputOption != "" && outputOption != jsonOption {
		return fmt.Errorf("parameter '%s' not supported for flag 'o'", outputOption)
	}

	context := cmd.Context().Value(cc.ContextKeyCmdContext).(*cc.CmdContext)
	_, err = config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return cc.CreateSystemInCorruptedStateCmdFailure()
		}
		if !errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return err
		}
		slog.Info("Setup not installed, listing addons without enabled status", "error", err)
	}

	addonProv := context.Providers().Addon

	if outputOption == jsonOption {
		return printAddonsAsJson(allAddons, addonProv)
	}

	return printAddonsUserFriendly(allAddons, addonProv)
}

func printAddonsAsJson(allAddons addons.Addons, addonProv provider.AddonProvider) error {
	terminalPrinter := terminal.NewTerminalPrinter()
	addonsPrinter := print.NewAddonsPrinter(terminalPrinter)

	enabledAddons, err := loadEnabledAddons(addonProv)
	if err != nil {
		return err
	}

	if err := addonsPrinter.PrintAddonsAsJson(enabledAddons, allAddons); err != nil {
		return fmt.Errorf("addons could not be printed: %w", err)
	}

	return nil
}

func printAddonsUserFriendly(allAddons addons.Addons, addonProv provider.AddonProvider) error {
	terminalPrinter := terminal.NewTerminalPrinter()
	addonsPrinter := print.NewAddonsPrinter(terminalPrinter)

	spinner, err := cc.StartSpinner(terminalPrinter)
	if err != nil {
		return err
	}

	enabledAddons, err := loadEnabledAddons(addonProv)

	cc.StopSpinner(spinner)

	if err != nil {
		return err
	}

	terminalPrinter.PrintHeader("Available Addons")

	if err := addonsPrinter.PrintAddonsUserFriendly(enabledAddons, allAddons); err != nil {
		return fmt.Errorf("addons could not be printed: %w", err)
	}

	slog.Info("Addons listed")

	return nil
}

func loadEnabledAddons(addonProv provider.AddonProvider) ([]print.EnabledAddon, error) {
	listResult, err := addonProv.List(provider.AddonListConfig{})
	if err != nil {
		return nil, fmt.Errorf("could not load enabled addons: %s", err)
	}

	var enabled []print.EnabledAddon
	for _, a := range listResult.Addons {
		if a.Enabled {
			enabled = append(enabled, print.EnabledAddon{
				Name:            a.Name,
				Description:     a.Description,
				Implementations: a.Implementations,
			})
		}
	}
	return enabled, nil
}
