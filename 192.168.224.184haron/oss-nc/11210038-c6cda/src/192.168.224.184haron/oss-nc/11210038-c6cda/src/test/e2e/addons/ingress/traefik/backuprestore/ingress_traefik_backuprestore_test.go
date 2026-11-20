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

func TestIngressTraefikBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ingress traefik Addon Backup/Restore Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "ingress", "traefik", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-ingress-traefik")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "ingress", "traefik", "-o")

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
	return filepath.Join(backupDir, fmt.Sprintf("ingress_traefik_backup_%s.zip", suffix))
}

var _ = Describe("'ingress traefik' addon backup/restore", Ordered, func() {

	const (
		ingressName     = "traefik-cluster-local"
		namespace       = "ingress-traefik"
		annotationKey   = "k2s-test/marker"
		annotationValue = "backup-restore-sentinel"
	)

	var zipPath string

	BeforeAll(func() {
		zipPath = backupZipPath("basic")
		cleanupBackupDir()
		os.MkdirAll(backupDir, os.ModePerm)
	})

	AfterAll(func(ctx context.Context) {
		suite.K2sCli().Exec(ctx, "addons", "disable", "ingress", "traefik", "-o")
		k2s.VerifyAddonIsDisabled("ingress", "traefik")
	})

	// --- error tests while addon is disabled (cheap, no lifecycle cost) ---

	It("fails backup when addon is disabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "ingress", "traefik")

		Expect(output).To(ContainSubstring("not enabled"))
	})

	It("fails restore with a non-existent backup file", func(ctx context.Context) {
		fakePath := filepath.Join(backupDir, "does-not-exist.zip")

		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "ingress", "traefik", "-f", fakePath)

		Expect(output).To(ContainSubstring("not found"))
	})

	// --- single enable → annotate ingress → backup → disable → restore cycle ---

	It("enables the addon", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")

		k2s.VerifyAddonIsEnabled("ingress", "traefik")

		suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
	})

	It("annotates the Ingress resource with a custom marker", func(ctx context.Context) {
		suite.Kubectl().MustExec(ctx, "annotate", "ingress", ingressName, "-n", namespace,
			fmt.Sprintf("%s=%s", annotationKey, annotationValue))

		output := suite.Kubectl().MustExec(ctx, "get", "ingress", ingressName, "-n", namespace,
			"-o", fmt.Sprintf("jsonpath={.metadata.annotations['%s']}", annotationKey))
		Expect(output).To(Equal(annotationValue))
	})

	It("creates a backup", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "backup", "ingress", "traefik", "-f", zipPath, "-o")

		Expect(zipPath).To(BeAnExistingFile())
	})

	It("fails restore while addon is still enabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "ingress", "traefik", "-f", zipPath)

		Expect(output).To(ContainSubstring("disable"))
	})

	It("disables the addon", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")

		k2s.VerifyAddonIsDisabled("ingress", "traefik")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
	})

	It("restores from backup and the annotation is present", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "restore", "ingress", "traefik", "-f", zipPath, "-o")

		k2s.VerifyAddonIsEnabled("ingress", "traefik")

		suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")

		output := suite.Kubectl().MustExec(ctx, "get", "ingress", ingressName, "-n", namespace,
			"-o", fmt.Sprintf("jsonpath={.metadata.annotations['%s']}", annotationKey))
		Expect(output).To(Equal(annotationValue))
	})

	It("can be enabled when only addons/common and addons/ingress are present", func(ctx context.Context) {
		GinkgoWriter.Println(">>> TEST: can be enabled when only addons/common and addons/ingress are present")

		GinkgoWriter.Println("[Test] Disabling ingress traefik to ensure clean re-enable path")
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")

		GinkgoWriter.Println("[Test] Staging addon isolation: keeping only common and ingress")
		restore, err := exportimport.StageAddonIsolation(suite.RootDir(), "ingress")
		Expect(err).ToNot(HaveOccurred(), "staging addon isolation should succeed")
		DeferCleanup(func() {
			Expect(restore()).To(Succeed(), "addon isolation restore must succeed to avoid a partial workspace state")
		})

		DeferCleanup(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "ingress", "traefik", "-o")
		})

		GinkgoWriter.Println("[Test] Enabling ingress traefik with isolated addons directory")
		output := suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")

		k2s.VerifyAddonIsEnabled("ingress", "traefik")

		GinkgoWriter.Println("[Test] Verifying traefik deployment is available")
		suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")

		GinkgoWriter.Println("[Test] Verifying no PowerShell module-not-found signatures in output")
		Expect(output).NotTo(ContainSubstring("no valid module file was found"), "enable output must not contain PowerShell module-not-found error")
		Expect(output).NotTo(ContainSubstring("was not loaded"), "enable output must not contain PowerShell module-not-loaded error")
	})
})
