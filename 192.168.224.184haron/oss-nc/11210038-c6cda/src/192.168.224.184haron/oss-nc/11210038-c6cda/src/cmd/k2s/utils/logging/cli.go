// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package logging

import (
	"log/slog"

	"github.com/pterm/pterm"
)

type CliHandler struct {
	pterm.SlogHandler
}

// NewCliHandler creates a new CLI log handler based on pterm
func NewCliHandler() HandlerBuilder {
	return func(levelVar *slog.LevelVar) SlogHandler {
		maxWidth := pterm.GetTerminalWidth()
		level := MapLogLevel(levelVar.Level())
		logger := pterm.DefaultLogger.WithMaxWidth(maxWidth).WithLevel(level).WithTimeFormat("15:04:05")
		handler := pterm.NewSlogHandler(logger)

		return &CliHandler{
			SlogHandler: *handler,
		}
	}
}

// MapLogLevel maps from slog.Level to pterm.LogLevel
func MapLogLevel(slogLevel slog.Level) pterm.LogLevel {
	switch {
	case slogLevel > slog.LevelError:
		return pterm.LogLevelFatal
	case slogLevel == slog.LevelError:
		return pterm.LogLevelError
	case slogLevel < slog.LevelError && slogLevel >= slog.LevelWarn:
		return pterm.LogLevelWarn
	case slogLevel < slog.LevelWarn && slogLevel >= slog.LevelInfo:
		return pterm.LogLevelInfo
	case slogLevel < slog.LevelInfo && slogLevel >= slog.LevelDebug:
		return pterm.LogLevelDebug
	case slogLevel < slog.LevelDebug:
		return pterm.LogLevelTrace
	default:
		slog.Warn("Unreachable code reached")
		return pterm.LogLevelDisabled
	}
}

// Flush does nothing
func (h CliHandler) Flush() { /*empty*/ }

// Close does nothing
func (h CliHandler) Close() { /*empty*/ }
