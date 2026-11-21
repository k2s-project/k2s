// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package main

import (
	"log/slog"
	"os"

	"github.com/k2s-project/k2s/cmd/devgon/cmd"

	"github.com/k2s-project/k2s/internal/logging"
)

func main() {
	var levelVar = new(slog.LevelVar)
	options := &slog.HandlerOptions{
		Level:       levelVar,
		AddSource:   true,
		ReplaceAttr: logging.ShortenSourceAttribute}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, options)))

	rootCmd := cmd.Create(levelVar)

	if err := rootCmd.Execute(); err != nil {
		slog.Error("error occurred while executing the command", "error", err)
		os.Exit(1)
	}
}
