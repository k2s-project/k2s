// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package bash

import (
	"context"
	"log/slog"

	k2sos "github.com/k2s-project/k2s/internal/os"
)

type scriptBuilder struct {
	cmdBuilder *k2sos.CmdBuilder
}

// NewScript creates a new script builder for the given script.
// It sets up the command to run the script with the necessary environment variables
// and default output writers (slog.Info for stdout and slog.Error for stderr).
func NewScript(script string) *scriptBuilder {
	return &scriptBuilder{
		cmdBuilder: k2sos.NewCmd("env").
			WithArgs("K2S_LOG_TO_CLI=true", "bash", script).
			WithStdOutWriter(slog.Info).
			WithStdErrWriter(slog.Error),
	}
}

// WithContext sets the context for the script builder.
// It allows the script to be executed with a specific context, which can be used for cancellation and timeouts.
func (builder *scriptBuilder) WithContext(ctx context.Context) *scriptBuilder {
	builder.cmdBuilder.WithContext(ctx)
	return builder
}

func (builder *scriptBuilder) WithArgs(args ...string) *scriptBuilder {
	builder.cmdBuilder.WithArgs(args...)
	return builder
}

// WithStdOutWriter sets the standard output writer for the script builder.
// Nil writer defaults to a no-op writer.
func (builder *scriptBuilder) WithStdOutWriter(writer k2sos.StdWriter) *scriptBuilder {
	builder.cmdBuilder.WithStdOutWriter(writer)
	return builder
}

// WithStdErrWriter sets the standard error writer for the script builder.
// Nil writer defaults to a no-op writer.
func (builder *scriptBuilder) WithStdErrWriter(writer k2sos.StdWriter) *scriptBuilder {
	builder.cmdBuilder.WithStdErrWriter(writer)
	return builder
}

// Exec executes the script using the configured command builder on the supported platform.
func (builder *scriptBuilder) Exec() error {
	if err := platformGuard(); err != nil {
		return err
	}
	return builder.cmdBuilder.Exec()
}
