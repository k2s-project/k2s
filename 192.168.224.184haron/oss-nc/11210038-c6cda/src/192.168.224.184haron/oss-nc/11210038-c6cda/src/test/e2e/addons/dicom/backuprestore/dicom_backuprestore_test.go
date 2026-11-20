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

func TestDicomBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "dicom Addon Backup/Restore Acceptance Tests", Label("addon", "addon-medical", "acceptance", "setup-required", "invasive", "dicom", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-dicom")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "dicom", "--force", "-o")

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
	return filepath.Join(backupDir, fmt.Sprintf("dicom_backup_%s.zip", suffix))
}

var _ = Describe("'dicom' addon backup/restore", Ordered, func() {

	const (
		configMapName   = "json-configmap"
		namespace       = "dicom"
		customDataKey   = "k2s-test-marker"
		customDataValue = "backup-restore-sentinel"
	)

	var zipPath string

	BeforeAll(func() {
		zipPath = backupZipPath("basic")
		cleanupBackupDir()
		os.MkdirAll(backupDir, os.ModePerm)
	})

	AfterAll(func(ctx context.Context) {
		suite.K2sCli().Exec(ctx, "addons", "disable", "dicom", "--force", "-o")
		k2s.VerifyAddonIsDisabled("dicom")
	})

	// --- error tests while addon is disabled (cheap, no lifecycle cost) ---

	It("fails backup when addon is disabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "dicom")

		Expect(output).To(ContainSubstring("not enabled"))
	})

	It("fails restore with a non-existent backup file", func(ctx context.Context) {
		fakePath := filepath.Join(backupDir, "does-not-exist.zip")

		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "dicom", "-f", fakePath)

		Expect(output).To(ContainSubstring("not found"))
	})

	// --- single enable → patch → backup → disable → restore cycle ---

	It("enables the addon", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "enable", "dicom", "-o")

		k2s.VerifyAddonIsEnabled("dicom")

		suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
		suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")
	})

	It("patches the ConfigMap with a custom data key", func(ctx context.Context) {
		suite.Kubectl().MustExec(ctx, "patch", "configmap", configMapName, "-n", namespace,
			"--type=merge", "-p", fmt.Sprintf(`{"data":{"%s":"%s"}}`, customDataKey, customDataValue))

		output := suite.Kubectl().MustExec(ctx, "get", "configmap", configMapName, "-n", namespace,
			"-o", fmt.Sprintf("jsonpath={.data['%s']}", customDataKey))
		Expect(output).To(Equal(customDataValue))
	})

	It("creates a backup", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "backup", "dicom", "-f", zipPath, "-o")

		Expect(zipPath).To(BeAnExistingFile())
	})

	It("fails restore while addon is still enabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "dicom", "-f", zipPath)

		Expect(output).To(ContainSubstring("disable"))
	})

	It("disables the addon", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "dicom", "--force", "-o")

		k2s.VerifyAddonIsDisabled("dicom")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "dicom", "dicom")
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "postgres", "dicom")
	})

	It("restores from backup and the custom data key is present", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "restore", "dicom", "-f", zipPath, "-o")

		k2s.VerifyAddonIsEnabled("dicom")

		suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
		suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")

		output := suite.Kubectl().MustExec(ctx, "get", "configmap", configMapName, "-n", namespace,
			"-o", fmt.Sprintf("jsonpath={.data['%s']}", customDataKey))
		Expect(output).To(Equal(customDataValue))
	})


	It("can be enabled when only addons/common and addons/dicom are present", func(ctx context.Context) {
		GinkgoWriter.Println(">>> TEST: can be enabled when only addons/common and addons/dicom are present")

		GinkgoWriter.Println("[Test] Disabling dicom to ensure clean re-enable path")
		suite.K2sCli().Exec(ctx, "addons", "disable", "dicom", "--force", "-o")

		GinkgoWriter.Println("[Test] Staging addon isolation: keeping only common and dicom")
		restore, err := exportimport.StageAddonIsolation(suite.RootDir(), "dicom")
		Expect(err).ToNot(HaveOccurred(), "staging addon isolation should succeed")
		DeferCleanup(func() {
			Expect(restore()).To(Succeed(), "addon isolation restore must succeed to avoid a partial workspace state")
		})
		DeferCleanup(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "dicom", "--force", "-o")
		})

		GinkgoWriter.Println("[Test] Enabling dicom with isolated addons directory")
		output := suite.K2sCli().MustExec(ctx, "addons", "enable", "dicom", "-o")

		GinkgoWriter.Println("[Test] Verifying dicom and postgres deployments are available")
		k2s.VerifyAddonIsEnabled("dicom")
		suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
		suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")

		GinkgoWriter.Println("[Test] Verifying no PowerShell module-not-found signatures in output")
		Expect(output).NotTo(ContainSubstring("no valid module file was found"), "enable output must not contain PowerShell module-not-found error")
		Expect(output).NotTo(ContainSubstring("was not loaded"), "enable output must not contain PowerShell module-not-loaded error")
	})
})
