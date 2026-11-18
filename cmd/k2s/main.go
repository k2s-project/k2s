// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
	"fmt"
	"log/slog"
	"os"

	"github.com/k2s-project/k2s/cmd/k2s/cmd"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/utils/logging"
	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/internal/provider"

	"github.com/pterm/pterm"
)

func main() {
	enableVirtualTerminalProcessing()

	exitCode := cli.ExitCodeSuccess

	logger := logging.NewSlogger()

	defer func() {
		if err := recover(); err != nil {
			exitCode = cli.ExitCodeFailure
			handleUnexpectedError(err)
		}

		logger.Flush()
		logger.Close()
		os.Exit(int(exitCode))
	}()

	rootCmd, err := cmd.CreateRootCmd(logger)
	if err != nil {
		exitCode = cli.ExitCodeFailure
		slog.Error("error occurred during root command creation", "error", err)
		return
	}

	err = rootCmd.Execute()
	if err == nil {
		return
	}

	exitCode = cli.ExitCodeFailure

	if cmdFailure, ok := errors.AsType[*common.CmdFailure](err); ok {
		handleCmdFailure(cmdFailure.Severity, cmdFailure.Code, cmdFailure.Message, cmdFailure.SuppressCliOutput)
		return
	}

	if providerFailure, ok := errors.AsType[*provider.ProviderFailure](err); ok {
		handleCmdFailure(common.FailureSeverity(providerFailure.Severity), providerFailure.Code, providerFailure.Message, providerFailure.SuppressCliOutput)
		return
	}

	handleUnexpectedError(err)
}

func handleCmdFailure(severity common.FailureSeverity, code string, message string, suppressCliOutput bool) {
	if !suppressCliOutput {
		switch severity {
		case common.SeverityWarning:
			pterm.Warning.Println(message)
		case common.SeverityError:
			pterm.Error.Println(message)
		default:
			slog.Warn("unknown cmd failure severity", "severity", severity)
		}
	}

	slog.Error("command failed",
		"severity", fmt.Sprintf("%d(%s)", severity, severity),
		"code", code,
		"message", message,
		"suppressCliOutput", suppressCliOutput)
}

func handleUnexpectedError(err any) {
	pterm.Error.Println(fmt.Errorf("%v", err))

	slog.Error("unexpected error", "error", err)
}
