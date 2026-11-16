// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0
package k2s

import (
	"context"
	"fmt"
	"time"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/test/framework/os"
)

type KubeProxyRestarter struct {
	runtimeConfig config.K2sRuntimeConfig
	nssmCli       *os.CliExecutor
}

func NewKubeProxyRestarter(setupInfo config.K2sRuntimeConfig, nssmCli *os.CliExecutor) *KubeProxyRestarter {
	return &KubeProxyRestarter{
		runtimeConfig: setupInfo,
		nssmCli:       nssmCli,
	}
}

func (r *KubeProxyRestarter) Restart(ctx context.Context) {
	if r.runtimeConfig.InstallConfig().LinuxOnly() || r.nssmCli == nil {
		GinkgoWriter.Println("Native Linux setup, skipping Windows kubeproxy restart")
	} else {
		r.restart(ctx)
	}
}

func (r *KubeProxyRestarter) restart(ctx context.Context) {
	GinkgoWriter.Println("Restarting kubeproxy to clean all caches..")

	const maxAttempts = 3
	const retryDelay = 5 * time.Second

	for attempt := 1; attempt <= maxAttempts; attempt++ {
		_, exitCode := r.nssmCli.Exec(ctx, "restart", "kubeproxy")
		if exitCode == 0 {
			break
		}
		if attempt == maxAttempts {
			Fail(fmt.Sprintf("kubeproxy restart failed after %d attempts (last exit code: %d)", maxAttempts, exitCode))
		}
		GinkgoWriter.Printf("kubeproxy restart attempt %d/%d failed (exit code: %d), retrying after %v\n", attempt, maxAttempts, exitCode, retryDelay)
		time.Sleep(retryDelay)
	}

	GinkgoWriter.Println("kubeproxy restarted")
}
