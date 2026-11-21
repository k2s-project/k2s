// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package backuprestore

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	gpuRequiredFilterTag = "gpu-required"
	testClusterTimeout   = time.Minute * 60
)

var (
	suite                     *framework.K2sTestSuite
	k2s                       *dsl.K2s
	testFailed                = false
	backupDir                 string
	isGpuExecution            = false
	gpuExecutionSkipMessage   = fmt.Sprintf("can only be run using the filter value '%s'", gpuRequiredFilterTag)
)

func TestGpuNodeBackupRestore(t *testing.T) {
	executionLabels := []string{"addon", "addon-diverse", "acceptance", "setup-required", "invasive", "gpu-node", "backup-restore", "system-running"}
	userAppliedLabels := GinkgoLabelFilter()
	if strings.Compare(userAppliedLabels, "") != 0 {
		if Label(gpuRequiredFilterTag).MatchesLabelFilter(userAppliedLabels) {
			isGpuExecution = true
			executionLabels = append(executionLabels, gpuRequiredFilterTag)
		}
	}

	RegisterFailHandler(Fail)
	RunSpecs(t, "gpu-node Addon Backup/Restore Acceptance Tests", Label(executionLabels...))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-gpu-node")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "gpu-node", "-o")
	cleanupBackupDir()

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

func cleanupBackupDir() {
	_ = os.RemoveAll(backupDir)
}

func backupZipPath(suffix string) string {
	return filepath.Join(backupDir, fmt.Sprintf("gpu_node_backup_%s.zip", suffix))
}

var _ = Describe("'gpu-node' addon backup/restore", Ordered, func() {
	var zipPath string

	BeforeAll(func() {
		zipPath = backupZipPath("basic")
		cleanupBackupDir()
		Expect(os.MkdirAll(backupDir, os.ModePerm)).To(Succeed())
	})

	AfterAll(func(ctx context.Context) {
		suite.K2sCli().Exec(ctx, "addons", "disable", "gpu-node", "-o")
		k2s.VerifyAddonIsDisabled("gpu-node")
	})

	// --- error tests while addon is disabled (cheap, no GPU required) ---

	It("fails backup when addon is disabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "gpu-node")
		Expect(output).To(ContainSubstring("not enabled"))
	})

	It("fails restore with a non-existent backup file", func(ctx context.Context) {
		fakePath := filepath.Join(backupDir, "does-not-exist.zip")

		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "gpu-node", "-f", fakePath)
		Expect(output).To(ContainSubstring("not found"))
	})

	// --- enable → backup → disable → restore (requires GPU hardware) ---

	Describe("enable → backup → disable → restore", func() {
		BeforeAll(func() {
			if !isGpuExecution {
				Skip(gpuExecutionSkipMessage)
			}
		})

		It("enables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "gpu-node", "-o")

			k2s.VerifyAddonIsEnabled("gpu-node")

			suite.Cluster().ExpectDeploymentToBeAvailable("nvidia-device-plugin", "gpu-node")
		})

		It("creates a backup", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "backup", "gpu-node", "-f", zipPath, "-o")
			Expect(zipPath).To(BeAnExistingFile())
		})

		It("fails restore while addon is still enabled", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "gpu-node", "-f", zipPath)
			Expect(output).To(ContainSubstring("disable"))
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "gpu-node", "-o")
			k2s.VerifyAddonIsDisabled("gpu-node")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "nvidia-device-plugin", "gpu-node")
		})

		It("restores from backup and gpu-node components are available", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "restore", "gpu-node", "-f", zipPath, "-o")

			k2s.VerifyAddonIsEnabled("gpu-node")

			suite.Cluster().ExpectDeploymentToBeAvailable("nvidia-device-plugin", "gpu-node")
		})
	})
})
