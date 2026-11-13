// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package bash

import (
	"log/slog"

	"github.com/k2s-project/k2s/internal/os"
	"github.com/k2s-project/k2s/internal/output"
)

const ShowLogsEnvVar = "K2S_SHOW_LOGS"

type scriptBuilder struct {
	script   string
	args     []string
	showLogs bool
	writer   output.StreamWriter
}

func NewScript(script string) *scriptBuilder {
	return &scriptBuilder{script: script}
}

func (builder *scriptBuilder) WithArgs(args ...string) *scriptBuilder {
	builder.args = append(builder.args, args...)
	return builder
}

// WithShowLogs sets the log-enabling env variable for the script.
func (builder *scriptBuilder) WithShowLogs(show bool) *scriptBuilder {
	builder.showLogs = show
	return builder
}

// WithStdWriter sets the writer for stdout and stderr lines; nil discards them.
// Flush is not called
func (builder *scriptBuilder) WithStdWriter(writer output.StreamWriter) *scriptBuilder {
	builder.writer = writer
	return builder
}

// Exec returns an error if the script exits with a non-zero code.
func (builder *scriptBuilder) Exec() error {
	if err := platformGuard(); err != nil {
		return err
	}

	cmdArgs := []string{}
	if builder.showLogs {
		cmdArgs = append(cmdArgs, "env", ShowLogsEnvVar+"=true")
	}
	cmdArgs = append(cmdArgs, "bash", builder.script)

	// Crucial order: before any arguments containing potentially sensitive information.
	slog.Debug("Bash command created", "command", cmdArgs)

	cmdArgs = append(cmdArgs, builder.args...)

	cmd := os.NewCmd(cmdArgs[0]).WithArgs(cmdArgs[1:]...)
	if builder.writer != nil {
		cmd.WithStdOutWriter(func(msg string, _ ...any) { builder.writer.WriteStdOut(msg) }).
			WithStdErrWriter(func(msg string, _ ...any) { builder.writer.WriteStdErr(msg) })
	}
	return cmd.Exec()
}
