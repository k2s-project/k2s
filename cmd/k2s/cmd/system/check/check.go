// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package check

import (
	"errors"
	"fmt"
	"path/filepath"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/healthcheck"
	"github.com/k2s-project/k2s/internal/json"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/k2s-project/k2s/internal/terminal"

	"github.com/spf13/cobra"
)

const (
	outputFlagName = "output"
	jsonOption     = "json"

	checkFailedCode = "system-check-failed"

	checkCommandExample = `
  # Run all health checks
  k2s system check

  # Run all health checks and print the results as JSON
  k2s system check -o json
`
)

var CheckCmd = &cobra.Command{
	Use:   "check",
	Short: "Runs read-only health checks on the host and the cluster and suggests fixes",
	Long: `Runs a set of read-only health checks for known causes of K2s problems and prints pass, warn, fail or skip for each, together with a suggested fix.

No changes are made to the system. The command exits with a non-zero exit code if at least one check fails.`,
	Example: checkCommandExample,
	RunE:    runChecks,
}

func init() {
	CheckCmd.Flags().StringP(outputFlagName, "o", "", "Output format modifier. Currently supported: 'json' for output as JSON structure")
	CheckCmd.Flags().SortFlags = false
	CheckCmd.Flags().PrintDefaults()
}

func runChecks(cmd *cobra.Command, args []string) error {
	outputOption, err := cmd.Flags().GetString(outputFlagName)
	if err != nil {
		return err
	}

	if outputOption != "" && outputOption != jsonOption {
		return fmt.Errorf("parameter '%s' not supported for flag 'o'", outputOption)
	}

	terminalPrinter := terminal.NewTerminalPrinter()

	var printer checkPrinter
	if outputOption == jsonOption {
		printer = newJsonPrinter(terminalPrinter.Println, json.MarshalIndent)
	} else {
		printer = newUserFriendlyPrinter(terminalPrinter)
	}

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)

	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return printer.PrintSystemError(cconfig.ErrSystemInCorruptedState, common.CreateSystemInCorruptedStateCmdFailure())
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return printer.PrintSystemError(cconfig.ErrSystemNotInstalled, common.CreateSystemNotInstalledCmdFailure())
		}
		return err
	}

	checkConfig := provider.SystemCheckConfig{
		ClusterName:    runtimeConfig.ClusterConfig().Name(),
		KubeconfigPath: filepath.Join(context.Config().Host().KubeConfig().CurrentDir(), definitions.KubeconfigName),
		SetupName:      runtimeConfig.InstallConfig().SetupName(),
		LinuxOnly:      runtimeConfig.InstallConfig().LinuxOnly(),
		WslEnabled:     runtimeConfig.InstallConfig().WslEnabled(),
	}

	report, err := printer.Run(func() (healthcheck.Report, error) {
		return context.Providers().System.Check(checkConfig)
	})
	if err != nil {
		return err
	}

	return printer.PrintReport(report)
}

func createChecksFailedCmdFailure(report healthcheck.Report) *common.CmdFailure {
	return &common.CmdFailure{
		Severity: common.SeverityError,
		Code:     checkFailedCode,
		Message:  fmt.Sprintf("%d of %d check(s) failed", report.Count(healthcheck.StatusFail), len(report.Results)),
	}
}
