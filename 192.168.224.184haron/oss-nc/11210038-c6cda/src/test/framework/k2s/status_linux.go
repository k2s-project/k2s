// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package k2s

import (
	"context"
	"os"

	testos "github.com/k2s-project/k2s/test/framework/os"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
)

// StatusChecker verifies native Linux K2s availability through the API server.
type StatusChecker struct {
	newCliFunc func(cliPath string) *testos.CliExecutor
	setupInfo  *SetupInfo
}

func NewStatusChecker(newCliFunc func(cliPath string) *testos.CliExecutor, setupInfo *SetupInfo) *StatusChecker {
	return &StatusChecker{
		newCliFunc: newCliFunc,
		setupInfo:  setupInfo,
	}
}

// IsK2sRunning checks the native control plane using the kubeconfig supplied
// by the Linux acceptance-test runner.
func (sc *StatusChecker) IsK2sRunning(ctx context.Context) bool {
	GinkgoWriter.Println("Checking native Linux K2s API server status..")
	sc.setupInfo.ReloadRuntimeConfig()

	args := []string{"cluster-info", "--request-timeout=10s"}
	if kubeconfig := os.Getenv("KUBECONFIG"); kubeconfig != "" {
		GinkgoWriter.Println("Using kubeconfig <", kubeconfig, "> for native Linux status")
		args = append([]string{"--kubeconfig", kubeconfig}, args...)
	}
	_, exitCode := sc.newCliFunc("kubectl").NoStdOut().Exec(ctx, args...)
	isRunning := exitCode == 0
	GinkgoWriter.Println("K2s system running:", isRunning)
	return isRunning
}
