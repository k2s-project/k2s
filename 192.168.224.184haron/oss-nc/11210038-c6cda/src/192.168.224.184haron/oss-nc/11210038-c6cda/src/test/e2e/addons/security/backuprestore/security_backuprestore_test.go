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

const testClusterTimeout = time.Minute * 25

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
	backupDir  string
)

func TestSecurityBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "security Addon Backup/Restore Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "security", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-security")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "security", "-o")
	// Security auto-enables ingress nginx when no ingress is present; clean it up.
	suite.K2sCli().Exec(ctx, "addons", "disable", "ingress", "nginx", "-o")
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
	return filepath.Join(backupDir, fmt.Sprintf("security_backup_%s.zip", suffix))
}

var _ = Describe("'security' addon backup/restore", Ordered, func() {

	const (
		caSecretName = "ca-issuer-root-secret"
		caNamespace  = "cert-manager"
	)

	var (
		zipPath      string
		caCertBefore string // base64-encoded CA certificate captured before backup
	)

	BeforeAll(func() {
		zipPath = backupZipPath("basic")
		cleanupBackupDir()
		Expect(os.MkdirAll(backupDir, os.ModePerm)).To(Succeed())
	})

	// No AfterAll — AfterSuite handles cleanup to avoid a redundant
	// disable cycle that would add ~150 s to test runtime.

	// --- error tests while addon is disabled (cheap, no lifecycle cost) ---

	It("fails backup when addon is disabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "security")
		Expect(output).To(ContainSubstring("not enabled"))
	})

	It("fails restore with a non-existent backup file", func(ctx context.Context) {
		fakePath := filepath.Join(backupDir, "does-not-exist.zip")

		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "security", "-f", fakePath)
		Expect(output).To(ContainSubstring("not found"))
	})

	// --- single enable → capture CA → backup → disable → restore cycle ---

	It("enables the addon with minimal components", func(ctx context.Context) {
		// Enable with omit flags to reduce enable/disable time while still
		// exercising the CA root Secret backup/restore path.
		suite.K2sCli().MustExec(ctx, "addons", "enable", "security",
			"--omitHydra", "--omitKeycloak", "--omitOAuth2Proxy", "-o")

		k2s.VerifyAddonIsEnabled("security")
	})

	It("captures the CA root certificate fingerprint", func(ctx context.Context) {
		// The CA root Secret is the key artifact that must survive backup/restore.
		// A fresh enable generates a new CA; backup preserves it so restore
		// keeps the same trust chain instead of generating a different one.
		caCertBefore = suite.Kubectl().MustExec(ctx, "get", "secret", caSecretName, "-n", caNamespace,
			"-o", "jsonpath={.data.tls\\.crt}")
		Expect(caCertBefore).NotTo(BeEmpty(), "CA root Secret should contain tls.crt")
	})

	It("creates a backup", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "backup", "security", "-f", zipPath, "-o")
		Expect(zipPath).To(BeAnExistingFile())
	})

	It("fails restore while addon is still enabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "security", "-f", zipPath)
		Expect(output).To(ContainSubstring("disable"))
	})

	It("disables the addon", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")

		k2s.VerifyAddonIsDisabled("security")
	})

	It("restores from backup and the CA root certificate is preserved", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "restore", "security", "-f", zipPath, "-o")

		k2s.VerifyAddonIsEnabled("security")

		// The restored CA root Secret must contain the ORIGINAL certificate,
		// not a freshly generated one. This proves the backup/restore cycle
		// preserved the trust chain.
		caCertAfter := suite.Kubectl().MustExec(ctx, "get", "secret", caSecretName, "-n", caNamespace,
			"-o", "jsonpath={.data.tls\\.crt}")
		Expect(caCertAfter).To(Equal(caCertBefore),
			"CA root certificate should be identical after restore (same trust chain)")
	})

	It("can be enabled when only addons/common and addons/security are present", func(ctx context.Context) {
		// Disable security first to ensure a clean re-enable path.
		suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")

		restore, err := exportimport.StageAddonIsolation(suite.RootDir(), "security")
		Expect(err).ToNot(HaveOccurred(), "staging addon isolation should succeed")
		DeferCleanup(func() {
			Expect(restore()).To(Succeed(), "addon isolation restore must succeed to avoid a partial workspace state")
		})
		DeferCleanup(func() {
			ctx, cancel := context.WithTimeout(context.Background(), testClusterTimeout)
			defer cancel()
			suite.K2sCli().Exec(ctx, "addons", "disable", "security", "-o")
		})

		output := suite.K2sCli().MustExec(ctx, "addons", "enable", "security",
			"--omitHydra", "--omitKeycloak", "--omitOAuth2Proxy", "-o")

		k2s.VerifyAddonIsEnabled("security")

		Expect(output).NotTo(ContainSubstring("no valid module file was found"), "enable output must not contain PowerShell module-not-found error")
		Expect(output).NotTo(ContainSubstring("was not loaded"), "enable output must not contain PowerShell module-not-loaded error")
	})
})
