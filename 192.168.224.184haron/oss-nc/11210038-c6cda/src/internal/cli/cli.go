// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"flag"
	"fmt"
	"log/slog"

	"github.com/k2s-project/k2s/internal/logging"
)

type ExitCode int

const (
	ExitCodeSuccess ExitCode = 0
	ExitCodeFailure ExitCode = 1

	VerbosityFlagName      = "verbosity"
	VerbosityFlagShorthand = "v"

	VersionFlagName = "version"
)

func VerbosityFlagHelp() string {
	debug := logging.LevelToLowerString(slog.LevelDebug)
	info := logging.LevelToLowerString(slog.LevelInfo)
	warn := logging.LevelToLowerString(slog.LevelWarn)
	err := logging.LevelToLowerString(slog.LevelError)

	return "log level/verbosity, either pre-defined levels, integer values or a combination of both.\n" +
		fmt.Sprintf("Pre-defined levels: %s = %d | %s = %d | %s = %d | %s = %d\n", debug, slog.LevelDebug, info, slog.LevelInfo, warn, slog.LevelWarn, err, slog.LevelError) +
		fmt.Sprintf("- e.g. '-v %s'\t-> %s\n", debug, debug) +
		fmt.Sprintf("- e.g. '-v %d'\t-> %s\n", slog.LevelWarn, warn) +
		fmt.Sprintf("- e.g. '-v %s+4'\t-> %s\n", debug, info) +
		fmt.Sprintf("- e.g. '-v %s-8'\t-> %s\n", err, info) +
		fmt.Sprintf("- e.g. '-v %s+2'\t-> %d (between %s and %s)\n", warn, slog.LevelWarn+2, warn, err)
}

func NewVersionFlag(cliName string) *bool {
	return flag.Bool(VersionFlagName, false, NewVersionFlagHint(cliName))
}

func NewVersionFlagHint(cliName string) string {
	return fmt.Sprintf("Shows the current version of %s CLI", cliName)
}
