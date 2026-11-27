// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"sync"

	"github.com/k2s-project/k2s/internal/cli"
	ve "github.com/k2s-project/k2s/internal/version"
)

const cliName = "httpproxy"

var (
	listenerMu        sync.Mutex
	listener          net.Listener
	shutdownRequested bool

	shutdownCleanupMu   sync.Mutex
	shutdownCleanupDone chan struct{}
)

func setListener(l net.Listener) bool {
	listenerMu.Lock()
	if shutdownRequested {
		listenerMu.Unlock()
		if l != nil {
			if err := l.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
				slog.Warn("Failed to close listener after shutdown request", "error", err)
			}
		}
		return false
	}
	listener = l
	listenerMu.Unlock()
	return true
}

func closeListener() error {
	listenerMu.Lock()
	shutdownRequested = true
	l := listener
	listener = nil
	listenerMu.Unlock()
	if l != nil {
		return l.Close()
	}
	return nil
}

func beginShutdownCleanup() func() {
	shutdownCleanupMu.Lock()
	defer shutdownCleanupMu.Unlock()
	if shutdownCleanupDone == nil {
		shutdownCleanupDone = make(chan struct{})
	}
	done := shutdownCleanupDone
	var closeOnce sync.Once
	return func() {
		closeOnce.Do(func() {
			close(done)
		})
	}
}

func waitForShutdownCleanup() {
	shutdownCleanupMu.Lock()
	done := shutdownCleanupDone
	shutdownCleanupMu.Unlock()
	if done != nil {
		<-done
	}
}

func resetListenerState() {
	listenerMu.Lock()
	l := listener
	listener = nil
	shutdownRequested = false
	listenerMu.Unlock()
	if l != nil {
		_ = l.Close()
	}

	shutdownCleanupMu.Lock()
	shutdownCleanupDone = nil
	shutdownCleanupMu.Unlock()
}

func runProxy(
	cfg *proxyConfig,
	listen func(network, address string) (net.Listener, error),
	serve func(net.Listener, http.Handler) error,
) error {
	if cfg == nil {
		return errors.New("proxy config must not be nil")
	}
	if listen == nil {
		listen = net.Listen
	}
	if serve == nil {
		serve = http.Serve
	}

	proxyHandler, err := newProxyHttpHandler(cfg)
	if err != nil {
		return fmt.Errorf("failed to create proxy handler: %w", err)
	}

	listenAddr := ""
	if cfg.ListenAddress != nil {
		listenAddr = *cfg.ListenAddress
	}

	l, err := listen("tcp", listenAddr)
	if err != nil {
		return fmt.Errorf("failed to listen on %s: %w", listenAddr, err)
	}

	if !setListener(l) {
		return nil
	}
	defer func() {
		if closeErr := closeListener(); closeErr != nil && !errors.Is(closeErr, net.ErrClosed) {
			slog.Warn("Failed to close listener", "error", closeErr)
		}
	}()

	if err := serve(l, proxyHandler); err != nil && !errors.Is(err, net.ErrClosed) && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("proxy server stopped with error: %w", err)
	}
	return nil
}

func main() {
	var allowedCIDRs networkCIDRs
	verbose := flag.Bool("verbose", true, "should every proxy request be logged to stdout")
	addr := flag.String("addr", ":8181", "proxy listen address")
	forwardProxy := flag.String("forwardproxy", "", "forward proxy to be used")

	versionFlag := cli.NewVersionFlag(cliName)
	flag.Var(&allowedCIDRs, "allowed-cidr", "source network (CIDR) allowed to use the HTTP proxy; repeatable, at least one is required")
	flag.Parse()

	if *versionFlag {
		ve.GetVersion().Print(cliName)
		return
	}

	// Register platform-specific signal/event handler and run startup
	if err := registerPlatformHandler(); err != nil {
		slog.Error("Failed to register platform handler", "error", err)
		_ = os.Stderr.Sync()
		os.Exit(1)
	}

	// start proxy
	slog.Info("Start of proxy.")
	proxyConfig := newProxyConfig(verbose, addr, forwardProxy, allowedCIDRs)
	if err := runProxy(proxyConfig, net.Listen, http.Serve); err != nil {
		slog.Error("HTTP proxy exited with error", "error", err)
		waitForShutdownCleanup()
		_ = os.Stderr.Sync()
		os.Exit(1)
	}

	// Wait for cleanup tasks before exiting
	slog.Info("Wait for exit of shutdown handler")
	waitForShutdownCleanup()

	// flush all logs
	slog.Info("Sync stderr log file")
	_ = os.Stderr.Sync()
}
