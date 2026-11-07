// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"flag"
	"log/slog"
	"net"
	"net/http"
	"os"
	"sync"

	"github.com/k2s-project/k2s/internal/cli"
	ve "github.com/k2s-project/k2s/internal/version"
)

const cliName = "httpproxy"

var cleanupWg sync.WaitGroup // WaitGroup to synchronize cleanup tasks

var listener net.Listener

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
		return
	}

	// start proxy
	slog.Info("Start of proxy.")
	proxyConfig := newProxyConfig(verbose, addr, forwardProxy, allowedCIDRs)
	proxyHandler, err := newProxyHttpHandler(proxyConfig)
	if err != nil {
		slog.Error("Failed to create proxy handler", "error", err)
		return
	}

	// Keep a reference to the listener
	listener, err = net.Listen("tcp", *proxyConfig.ListenAddress)
	if err != nil {
		slog.Error("Failed to listen", "error", err)
		return
	}
	http.Serve(listener, proxyHandler)

	// Wait for cleanup tasks before exiting
	slog.Info("Wait for exit of shutdown handler")
	cleanupWg.Wait()

	// flush all logs
	slog.Info("Sync stderr log file")
	os.Stderr.Sync()
}
