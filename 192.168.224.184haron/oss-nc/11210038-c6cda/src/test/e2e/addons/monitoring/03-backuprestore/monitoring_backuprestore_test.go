// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package backuprestore

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/e2e/addons/exportimport"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 20

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
	backupDir  string
)

func TestMonitoringBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "monitoring Addon Backup/Restore Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "monitoring", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-monitoring")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "monitoring", "-o")

	cleanupBackupDir()

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

func cleanupBackupDir() {
	os.RemoveAll(backupDir)
}

func backupZipPath(suffix string) string {
	return filepath.Join(backupDir, fmt.Sprintf("monitoring_backup_%s.zip", suffix))
}

var _ = Describe("'monitoring' addon backup/restore", Ordered, func() {

	Describe("backup and restore", func() {
		var zipPath string

		BeforeAll(func() {
			zipPath = backupZipPath("basic")
			cleanupBackupDir()
			os.MkdirAll(backupDir, os.ModePerm)
		})

		// No AfterAll disable here — monitoring stays running for the
		// next Describe block (custom dashboard test), saving a full
		// disable + enable cycle (~5-8 min).

		// --- error tests while addon is disabled ---

		It("fails backup when addon is disabled", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "monitoring")

			Expect(output).To(ContainSubstring("not enabled"))
		})

		It("fails restore with a non-existent backup file", func(ctx context.Context) {
			fakePath := filepath.Join(backupDir, "does-not-exist.zip")

			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "monitoring", "-f", fakePath)

			Expect(output).To(ContainSubstring("not found"))
		})

		// --- enable → backup → error while enabled → disable → restore ---

		It("enables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "-o")

			k2s.VerifyAddonIsEnabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-grafana", "monitoring")
		})

		It("creates a backup", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "backup", "monitoring", "-f", zipPath, "-o")

			Expect(zipPath).To(BeAnExistingFile())
		})

		It("fails restore while addon is still enabled", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "monitoring", "-f", zipPath)

			Expect(output).To(ContainSubstring("disable"))
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")

			k2s.VerifyAddonIsDisabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "grafana", "monitoring")
		})

		It("restores from backup successfully", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "restore", "monitoring", "-f", zipPath, "-o")

			k2s.VerifyAddonIsEnabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-grafana", "monitoring")
		})
	})

	Describe("backup and restore preserves custom Grafana dashboard ConfigMap", func() {
		// Backup.ps1 exports non-Helm-managed ConfigMaps labelled
		// grafana_dashboard=1 in the monitoring namespace.
		// Restore.ps1 re-applies them via server-side apply after
		// Enable.ps1 creates a fresh stack.  We create a custom
		// dashboard ConfigMap before backup and verify it survives
		// the full cycle.
		const (
			customCMName = "k2s-test-custom-dashboard"
			namespace    = "monitoring"
		)

		var zipPath string

		BeforeAll(func() {
			zipPath = backupZipPath("with-dashboard")
			cleanupBackupDir()
			os.MkdirAll(backupDir, os.ModePerm)
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "monitoring", "-o")
			k2s.VerifyAddonIsDisabled("monitoring")
		})

		// Monitoring is already running from the previous Describe's
		// successful restore — no need to enable again.

		It("creates a custom Grafana dashboard ConfigMap", func(ctx context.Context) {
			// Create a ConfigMap with the grafana_dashboard=1 label so
			// Backup.ps1 picks it up as a user-created dashboard.
			suite.Kubectl().MustExec(ctx, "create", "configmap", customCMName,
				"-n", namespace,
				"--from-literal=test-dashboard.json={\"uid\":\"k2s-test\",\"title\":\"K2s Test Dashboard\"}")

			suite.Kubectl().MustExec(ctx, "label", "configmap", customCMName,
				"-n", namespace, "grafana_dashboard=1")

			// Verify it exists
			output := suite.Kubectl().MustExec(ctx, "get", "configmap", customCMName, "-n", namespace,
				"-o", "jsonpath={.data['test-dashboard\\.json']}")
			Expect(output).To(ContainSubstring("K2s Test Dashboard"))
		})

		It("creates a backup containing the custom dashboard", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "backup", "monitoring", "-f", zipPath, "-o")

			Expect(zipPath).To(BeAnExistingFile())
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")

			k2s.VerifyAddonIsDisabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "grafana", "monitoring")
		})

		It("restores from backup and the custom dashboard ConfigMap is present", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "restore", "monitoring", "-f", zipPath, "-o")

			k2s.VerifyAddonIsEnabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-grafana", "monitoring")

			// Verify the custom dashboard ConfigMap was restored.
			output := suite.Kubectl().MustExec(ctx, "get", "configmap", customCMName, "-n", namespace,
				"-o", "jsonpath={.data['test-dashboard\\.json']}")
			Expect(output).To(ContainSubstring("K2s Test Dashboard"))
		})
	})


	It("can be enabled when only addons/common and addons/monitoring are present", func(ctx context.Context) {
		GinkgoWriter.Println(">>> TEST: can be enabled when only addons/common and addons/monitoring are present")

		GinkgoWriter.Println("[Test] Disabling monitoring to ensure clean re-enable path")
		suite.K2sCli().Exec(ctx, "addons", "disable", "monitoring", "-o")

		GinkgoWriter.Println("[Test] Staging addon isolation: keeping only common and monitoring")
		restore, err := exportimport.StageAddonIsolation(suite.RootDir(), "monitoring")
		Expect(err).ToNot(HaveOccurred(), "staging addon isolation should succeed")
		DeferCleanup(func() {
			Expect(restore()).To(Succeed(), "addon isolation restore must succeed to avoid a partial workspace state")
		})
		DeferCleanup(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "monitoring", "-o")
		})

		GinkgoWriter.Println("[Test] Enabling monitoring with isolated addons directory")
		output := suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "-o")

		GinkgoWriter.Println("[Test] Verifying kube-prometheus-stack deployments are available")
		k2s.VerifyAddonIsEnabled("monitoring")
		suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
		suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-grafana", "monitoring")

		GinkgoWriter.Println("[Test] Verifying no PowerShell module-not-found signatures in output")
		Expect(output).NotTo(ContainSubstring("no valid module file was found"), "enable output must not contain PowerShell module-not-found error")
		Expect(output).NotTo(ContainSubstring("was not loaded"), "enable output must not contain PowerShell module-not-loaded error")
	})
})
