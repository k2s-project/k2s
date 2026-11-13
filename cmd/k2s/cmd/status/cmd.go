// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package status

import (
	"errors"
	"fmt"
	"runtime"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/json"
	"github.com/k2s-project/k2s/internal/terminal"

	"github.com/spf13/cobra"
)

type StatusPrinter interface {
	Print() error
}

const (
	outputFlagName = "output"
	wideOption     = "wide"
	jsonOption     = "json"

	statusCommandExample = `
  # Status of the cluster
  k2s status

  # Status of the cluster with more information
  k2s status -o wide

  # Status of the cluster in JSON output format
  k2s status -o json
`
)

var StatusCmd = &cobra.Command{
	Use:     "status",
	Short:   "Prints out status information about the K2s cluster on this machine",
	RunE:    printStatus,
	Example: statusCommandExample,
}

func init() {
	StatusCmd.Flags().StringP(outputFlagName, "o", "", "Output format modifier. Currently supported: 'wide' for more information and 'json' for output as JSON structure")
	StatusCmd.Flags().SortFlags = false
	StatusCmd.Flags().PrintDefaults()
}

func printStatus(cmd *cobra.Command, args []string) error {
	outputOption, err := cmd.Flags().GetString(outputFlagName)
	if err != nil {
		return err
	}

	if outputOption != "" && outputOption != wideOption && outputOption != jsonOption {
		return fmt.Errorf("parameter '%s' not supported for flag 'o'", outputOption)
	}

	terminalPrinter := terminal.NewTerminalPrinter()

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			if outputOption == jsonOption {
				return printSystemErrJson(terminalPrinter.Println, cconfig.ErrSystemInCorruptedState, common.CreateSystemInCorruptedStateCmdFailure)
			}
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			if outputOption == jsonOption {
				return printSystemErrJson(terminalPrinter.Println, cconfig.ErrSystemNotInstalled, common.CreateSystemNotInstalledCmdFailure)
			}
			return common.CreateSystemNotInstalledCmdFailure()
		}

		return err
	}

	if runtime.GOOS != "linux" {
		if err := context.EnsureK2sK8sContext(runtimeConfig.ClusterConfig().Name()); err != nil {
			return err
		}
	}

	printer := determinePrinter(outputOption, runtimeConfig, terminalPrinter, context)

	return printer.Print()
}

func determinePrinter(outputOption string, config *cconfig.K2sRuntimeConfig, terminalPrinter TerminalPrinter, context *common.CmdContext) StatusPrinter {
	loadFunc := func() (*LoadedStatus, error) {
		return LoadStatus(context)
	}

	if outputOption == jsonOption {
		return NewJsonPrinter(config, terminalPrinter.Println, json.MarshalIndent, loadFunc)
	}
	return NewUserFriendlyPrinter(config, outputOption == wideOption, terminalPrinter, loadFunc)
}

func printSystemErrJson(printlnFunc func(m ...any), systemError error, systemCmdFailureFunc func() *common.CmdFailure) error {
	errCode := systemError.Error()
	status := PrintStatus{
		Error: &errCode,
	}

	bytes, err := json.MarshalIndent(status)
	if err != nil {
		return err
	}

	printlnFunc(string(bytes))

	failure := systemCmdFailureFunc()
	failure.SuppressCliOutput = true

	return failure
}
