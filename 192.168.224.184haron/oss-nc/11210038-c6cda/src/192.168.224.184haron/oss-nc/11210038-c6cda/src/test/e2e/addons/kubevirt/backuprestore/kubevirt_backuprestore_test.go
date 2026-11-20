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
	manualExecutionFilterTag = "manual"
	testClusterTimeout       = time.Minute * 60
)

var (
	suite                         *framework.K2sTestSuite
	k2s                           *dsl.K2s
	testFailed                    = false
	backupDir                     string
	isManualExecution             = false
	automatedExecutionSkipMessage = fmt.Sprintf("can only be run using the filter value '%s'", manualExecutionFilterTag)
)

func TestKubevirtBackupRestore(t *testing.T) {
	executionLabels := []string{"addon", "addon-diverse", "acceptance", "internet-required", "setup-required", "invasive", "kubevirt", "backup-restore", "system-running"}
	userAppliedLabels := GinkgoLabelFilter()
	if strings.Compare(userAppliedLabels, "") != 0 {
		if Label(manualExecutionFilterTag).MatchesLabelFilter(userAppliedLabels) {
			isManualExecution = true
			executionLabels = append(executionLabels, manualExecutionFilterTag)
		}
	}

	RegisterFailHandler(Fail)
	RunSpecs(t, "kubevirt Addon Backup/Restore Acceptance Tests", Label(executionLabels...))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-kubevirt")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "kubevirt", "-o")
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
	return filepath.Join(backupDir, fmt.Sprintf("kubevirt_backup_%s.zip", suffix))
}

var _ = Describe("'kubevirt' addon backup/restore", Ordered, func() {
	var zipPath string

	BeforeAll(func() {
		zipPath = backupZipPath("basic")
		cleanupBackupDir()
		Expect(os.MkdirAll(backupDir, os.ModePerm)).To(Succeed())
	})

	AfterAll(func(ctx context.Context) {
		suite.K2sCli().Exec(ctx, "addons", "disable", "kubevirt", "-o")
		k2s.VerifyAddonIsDisabled("kubevirt")
	})

	// --- error tests while addon is disabled (cheap, no lifecycle cost) ---

	It("fails backup when addon is disabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "kubevirt")
		Expect(output).To(ContainSubstring("not enabled"))
	})

	It("fails restore with a non-existent backup file", func(ctx context.Context) {
		fakePath := filepath.Join(backupDir, "does-not-exist.zip")

		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "kubevirt", "-f", fakePath)
		Expect(output).To(ContainSubstring("not found"))
	})

	Describe("enable → backup → disable → restore", func() {
		BeforeAll(func() {
			if !isManualExecution {
				Skip(automatedExecutionSkipMessage)
			}
		})

		It("enables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "kubevirt", "-o")

			k2s.VerifyAddonIsEnabled("kubevirt")

			suite.Cluster().ExpectDeploymentToBeAvailable("virt-api", "kubevirt")
			suite.Cluster().ExpectDeploymentToBeAvailable("virt-controller", "kubevirt")
			suite.Cluster().ExpectDeploymentToBeAvailable("virt-operator", "kubevirt")
			suite.Kubectl().MustExec(ctx, "rollout", "status", "daemonset/virt-handler", "-n", "kubevirt", "--timeout=180s")
			suite.Kubectl().MustExec(ctx, "wait", "--timeout=180s", "--for=condition=Available", "-n", "kubevirt", "kv/kubevirt")
		})

		It("creates a backup", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "backup", "kubevirt", "-f", zipPath, "-o")
			Expect(zipPath).To(BeAnExistingFile())
		})

		It("fails restore while addon is still enabled", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "kubevirt", "-f", zipPath)
			Expect(output).To(ContainSubstring("disable"))
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "kubevirt", "-o")
			k2s.VerifyAddonIsDisabled("kubevirt")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "virt-api", "kubevirt")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "virt-controller", "kubevirt")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "virt-operator", "kubevirt")
		})

		It("restores from backup and kubevirt components are available", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "restore", "kubevirt", "-f", zipPath, "-o")

			k2s.VerifyAddonIsEnabled("kubevirt")

			suite.Cluster().ExpectDeploymentToBeAvailable("virt-api", "kubevirt")
			suite.Cluster().ExpectDeploymentToBeAvailable("virt-controller", "kubevirt")
			suite.Cluster().ExpectDeploymentToBeAvailable("virt-operator", "kubevirt")
			suite.Kubectl().MustExec(ctx, "rollout", "status", "daemonset/virt-handler", "-n", "kubevirt", "--timeout=180s")
			suite.Kubectl().MustExec(ctx, "wait", "--timeout=180s", "--for=condition=Available", "-n", "kubevirt", "kv/kubevirt")
		})
	})
})
