// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package main

import (
	"errors"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"syscall"
)

// registerPlatformHandler registers Unix signal handlers for graceful shutdown.
func registerPlatformHandler() error {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		for sig := range sigCh {
			slog.Info("Signal received, shutting down.", "signal", sig)
			if err := closeListener(); err != nil && !errors.Is(err, net.ErrClosed) {
				slog.Error("Failed to close listener on signal", "error", err)
			}
		}
	}()

	return nil
}
