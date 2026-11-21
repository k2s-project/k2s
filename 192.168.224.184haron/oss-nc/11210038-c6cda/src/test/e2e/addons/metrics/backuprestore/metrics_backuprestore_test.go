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

func TestMetricsBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "metrics Addon Backup/Restore Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "metrics", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-metrics")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "metrics", "-o")

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
	return filepath.Join(backupDir, fmt.Sprintf("metrics_backup_%s.zip", suffix))
}

var _ = Describe("'metrics' addon backup/restore", Ordered, func() {

	Describe("backup and restore", func() {
		var zipPath string

		BeforeAll(func() {
			zipPath = backupZipPath("basic")
			cleanupBackupDir()
			os.MkdirAll(backupDir, os.ModePerm)
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "metrics", "-o")
			k2s.VerifyAddonIsDisabled("metrics")
		})

		// --- error tests while addon is disabled ---

		It("fails backup when addon is disabled", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "metrics")

			Expect(output).To(ContainSubstring("not enabled"))
		})

		It("fails restore with a non-existent backup file", func(ctx context.Context) {
			fakePath := filepath.Join(backupDir, "does-not-exist.zip")

			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "metrics", "-f", fakePath)

			Expect(output).To(ContainSubstring("not found"))
		})

		// --- enable → backup → error while enabled → disable → restore ---

		It("enables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "metrics", "-o")

			k2s.VerifyAddonIsEnabled("metrics")

			suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")
		})

		It("creates a backup", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "backup", "metrics", "-f", zipPath, "-o")

			Expect(zipPath).To(BeAnExistingFile())
		})

		It("fails restore while addon is still enabled", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "metrics", "-f", zipPath)

			Expect(output).To(ContainSubstring("disable"))
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "metrics", "-o")

			k2s.VerifyAddonIsDisabled("metrics")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "metrics-server", "metrics")
		})

		It("restores from backup successfully", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "restore", "metrics", "-f", zipPath, "-o")

			k2s.VerifyAddonIsEnabled("metrics")

			suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")
		})
	})

	Describe("backup and restore preserves windows-exporter-config ConfigMap data", func() {
		// Backup.ps1 captures the windows-exporter-config ConfigMap from
		// kube-system with its full .data field.  Restore.ps1 applies the
		// backed-up JSON on top of the freshly created ConfigMap from
		// Enable.ps1.  We add a custom data key before backup and verify
		// it survives the full cycle.
		const (
			configMapName   = "windows-exporter-config"
			configMapNS     = "kube-system"
			customDataKey   = "k2s-test-marker"
			customDataValue = "backup-restore-sentinel"
		)

		var zipPath string

		BeforeAll(func() {
			zipPath = backupZipPath("with-data")
			cleanupBackupDir()
			os.MkdirAll(backupDir, os.ModePerm)
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "metrics", "-o")
			k2s.VerifyAddonIsDisabled("metrics")
		})

		It("enables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "metrics", "-o")

			k2s.VerifyAddonIsEnabled("metrics")

			suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")
		})

		It("patches the ConfigMap with a custom data key", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx, "patch", "configmap", configMapName, "-n", configMapNS,
				"--type=merge", "-p", fmt.Sprintf(`{"data":{"%s":"%s"}}`, customDataKey, customDataValue))

			output := suite.Kubectl().MustExec(ctx, "get", "configmap", configMapName, "-n", configMapNS,
				"-o", fmt.Sprintf("jsonpath={.data['%s']}", customDataKey))
			Expect(output).To(Equal(customDataValue))
		})

		It("creates a backup containing the patched ConfigMap", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "backup", "metrics", "-f", zipPath, "-o")

			Expect(zipPath).To(BeAnExistingFile())
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "metrics", "-o")

			k2s.VerifyAddonIsDisabled("metrics")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "metrics-server", "metrics")
		})

		It("restores from backup and the custom data key is present", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "restore", "metrics", "-f", zipPath, "-o")

			k2s.VerifyAddonIsEnabled("metrics")

			suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")

			// The backed-up ConfigMap contained our custom data key.
			// Restore.ps1 applies it via kubectl apply, merging with the
			// freshly created ConfigMap from Enable.ps1.
			output := suite.Kubectl().MustExec(ctx, "get", "configmap", configMapName, "-n", configMapNS,
				"-o", fmt.Sprintf("jsonpath={.data['%s']}", customDataKey))
			Expect(output).To(Equal(customDataValue))
		})
	})

	It("can be enabled when only addons/common and addons/metrics are present", func(ctx context.Context) {
		GinkgoWriter.Println(">>> TEST: can be enabled when only addons/common and addons/metrics are present")

		GinkgoWriter.Println("[Test] Disabling metrics to ensure clean re-enable path")
		suite.K2sCli().Exec(ctx, "addons", "disable", "metrics", "-o")

		GinkgoWriter.Println("[Test] Staging addon isolation: keeping only common and metrics")
		restore, err := exportimport.StageAddonIsolation(suite.RootDir(), "metrics")
		Expect(err).ToNot(HaveOccurred(), "staging addon isolation should succeed")
		DeferCleanup(func() {
			Expect(restore()).To(Succeed(), "addon isolation restore must succeed to avoid a partial workspace state")
		})
		DeferCleanup(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "metrics", "-o")
		})

		GinkgoWriter.Println("[Test] Enabling metrics with isolated addons directory")
		output := suite.K2sCli().MustExec(ctx, "addons", "enable", "metrics", "-o")

		k2s.VerifyAddonIsEnabled("metrics")
		GinkgoWriter.Println("[Test] Verifying metrics-server deployment is available")
		suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")

		GinkgoWriter.Println("[Test] Verifying no PowerShell module-not-found signatures in output")
		Expect(output).NotTo(ContainSubstring("no valid module file was found"), "enable output must not contain PowerShell module-not-found error")
		Expect(output).NotTo(ContainSubstring("was not loaded"), "enable output must not contain PowerShell module-not-loaded error")
	})
})
