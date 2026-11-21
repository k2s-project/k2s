// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package main

import (
	"fmt"
	"log/slog"
	"path/filepath"
	"strings"
	"time"

	"github.com/Microsoft/windows-container-networking/cni"
	"github.com/Microsoft/windows-container-networking/common"
	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/internal/containernetworking"
	"github.com/k2s-project/k2s/internal/logging"
	ve "github.com/k2s-project/k2s/internal/version"

	"flag"
	"os"
)

const cliName = "bridge"

// Version is populated by make during build.
var version string

func main() {
	versionFlag := cli.NewVersionFlag(cliName)
	flag.Parse()

	if *versionFlag {
		ve.GetVersion().Print(cliName)
		return
	}

	containerID := os.Getenv("CNI_CONTAINERID")
	argsPlugin := os.Getenv("CNI_ARGS")
	argsCmd := os.Getenv("CNI_COMMAND")
	allPlugins := strings.Split(argsPlugin, ";")
	var podName string
	for _, v := range allPlugins {
		var value string
		n, err := fmt.Sscanf(v, "K8S_POD_NAME=%s", &value)
		if err == nil && n > 0 {
			podName = value
		}
	}

	logFileNamePart := podName + "-" + argsCmd
	if podName == "" {
		logFileNamePart = containerID
	}

	logFileName := fmt.Sprintf("bridge-%s.log", logFileNamePart)
	logDir := filepath.Join(logging.RootLogDir(), cliName)

	logFile, err := logging.SetupDefaultFileLogger(logDir, logFileName, slog.LevelDebug, "component", cliName, "scope", "[cni-net]")
	if err != nil {
		slog.Error("failed to setup file logger", "error", err)
		os.Exit(1)
	}
	defer logFile.Close()

	slog.Info("Starting CNI plugin", "command", argsCmd, "container-id", containerID, "net-ns", os.Getenv("CNI_NETNS"), "if-name", os.Getenv("CNI_IFNAME"), "args", argsPlugin, "path", os.Getenv("CNI_PATH"))

	config := common.PluginConfig{Version: version}

	netPlugin, err := containernetworking.NewPlugin(&config)
	if err != nil {
		slog.Error("failed to create network plugin", "error", err)
		os.Exit(1)
	}

	err = netPlugin.Start(&config)
	if err != nil {
		slog.Error("failed to start network plugin", "error", err)
		os.Exit(1)
	}

	err = netPlugin.Execute(cni.PluginApi(netPlugin))

	netPlugin.Stop()

	if err != nil {
		slog.Error("failed to execute network plugin", "error", err)
		os.Exit(1)
	}

	err = logging.CleanLogDir(logDir, 24*time.Hour)
	if err != nil {
		slog.Error("failed to clean up log dir", "error", err)
		os.Exit(1)
	}
}
