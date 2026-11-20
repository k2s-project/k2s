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

func TestViewerBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "viewer Addon Backup/Restore Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "viewer", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-viewer")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "viewer", "-o")

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
	return filepath.Join(backupDir, fmt.Sprintf("viewer_backup_%s.zip", suffix))
}

var _ = Describe("'viewer' addon backup/restore", Ordered, func() {

	Describe("backup and restore", func() {
		var zipPath string

		BeforeAll(func() {
			zipPath = backupZipPath("basic")
			cleanupBackupDir()
			os.MkdirAll(backupDir, os.ModePerm)
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "viewer", "-o")
			k2s.VerifyAddonIsDisabled("viewer")
		})

		// --- error tests while addon is disabled ---

		It("fails backup when addon is disabled", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "viewer")

			Expect(output).To(ContainSubstring("not enabled"))
		})

		It("fails restore with a non-existent backup file", func(ctx context.Context) {
			fakePath := filepath.Join(backupDir, "does-not-exist.zip")

			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "viewer", "-f", fakePath)

			Expect(output).To(ContainSubstring("not found"))
		})

		// --- enable → backup → error while enabled → disable → restore ---

		It("enables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "-o")

			k2s.VerifyAddonIsEnabled("viewer")

			suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
		})

		It("creates a backup", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "backup", "viewer", "-f", zipPath, "-o")

			Expect(zipPath).To(BeAnExistingFile())
		})

		It("fails restore while addon is still enabled", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "viewer", "-f", zipPath)

			Expect(output).To(ContainSubstring("disable"))
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "viewer", "-o")

			k2s.VerifyAddonIsDisabled("viewer")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")
		})

		It("restores from backup successfully", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "restore", "viewer", "-f", zipPath, "-o")

			k2s.VerifyAddonIsEnabled("viewer")

			suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
		})
	})

	Describe("backup and restore preserves Service customisation", func() {
		const (
			testNamespace     = "viewer"
			testAnnotationKey = "k2s-test/backup-marker"
			testAnnotationVal = "viewer-backup-test-value"
		)

		var zipPath string

		BeforeAll(func() {
			zipPath = backupZipPath("with-svc-annotation")
			cleanupBackupDir()
			os.MkdirAll(backupDir, os.ModePerm)
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "viewer", "-o")
			k2s.VerifyAddonIsDisabled("viewer")
		})

		It("enables the addon and annotates the Service", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "-o")

			k2s.VerifyAddonIsEnabled("viewer")

			suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")

			// Add a custom annotation to the Service that will be captured in the backup.
			suite.Kubectl().MustExec(ctx, "annotate", "svc", "viewerwebapp", "-n", testNamespace,
				fmt.Sprintf("%s=%s", testAnnotationKey, testAnnotationVal))

			// Verify annotation is present before backup.
			output := suite.Kubectl().MustExec(ctx, "get", "svc", "viewerwebapp", "-n", testNamespace,
				"-o", fmt.Sprintf("jsonpath={.metadata.annotations['%s']}", testAnnotationKey))
			Expect(output).To(Equal(testAnnotationVal))
		})

		It("creates a backup containing the annotated Service", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "backup", "viewer", "-f", zipPath, "-o")

			Expect(zipPath).To(BeAnExistingFile())
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "viewer", "-o")

			k2s.VerifyAddonIsDisabled("viewer")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")
		})

		It("restores from backup and the custom Service annotation is preserved", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "restore", "viewer", "-f", zipPath, "-o")

			k2s.VerifyAddonIsEnabled("viewer")

			suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")

			// The annotation was on the backed-up Service YAML.  Restore.ps1
			// applies the backed-up resources via kubectl apply / replace, and
			// Update.ps1 does NOT touch the Service — so the annotation must
			// still be present.
			output := suite.Kubectl().MustExec(ctx, "get", "svc", "viewerwebapp", "-n", testNamespace,
				"-o", fmt.Sprintf("jsonpath={.metadata.annotations['%s']}", testAnnotationKey))
			Expect(output).To(Equal(testAnnotationVal))
		})
	})

	It("can be enabled when only addons/common and addons/viewer are present", func(ctx context.Context) {
		suite.K2sCli().Exec(ctx, "addons", "disable", "viewer", "-o")

		restore, err := exportimport.StageAddonIsolation(suite.RootDir(), "viewer")
		Expect(err).ToNot(HaveOccurred(), "staging addon isolation should succeed")
		DeferCleanup(func() {
			Expect(restore()).To(Succeed(), "addon isolation restore must succeed to avoid a partial workspace state")
		})
		DeferCleanup(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "viewer", "-o")
		})

		output := suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "-o")

		k2s.VerifyAddonIsEnabled("viewer")
		suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")

		Expect(output).NotTo(ContainSubstring("no valid module file was found"), "enable output must not contain PowerShell module-not-found error")
		Expect(output).NotTo(ContainSubstring("was not loaded"), "enable output must not contain PowerShell module-not-loaded error")
	})
})
