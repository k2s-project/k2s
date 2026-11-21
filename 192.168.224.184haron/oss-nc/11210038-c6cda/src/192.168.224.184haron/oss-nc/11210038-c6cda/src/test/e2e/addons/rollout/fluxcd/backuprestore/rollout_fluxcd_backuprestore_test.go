// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package backuprestore

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
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

func TestRolloutFluxcdBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "rollout fluxcd Addon Backup/Restore Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "rollout-fluxcd", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-rollout-fluxcd")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	cleanupTestResources(ctx)
	suite.K2sCli().Exec(ctx, "addons", "disable", "rollout", "fluxcd", "-o")
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
	return filepath.Join(backupDir, fmt.Sprintf("rollout_fluxcd_backup_%s.zip", suffix))
}

// cleanupTestResources deletes the test GitRepository and Secret so that
// source-controller can process finalizer removal while still running,
// preventing namespace-termination deadlocks during addon disable.
func cleanupTestResources(ctx context.Context) {
	suite.Kubectl().Exec(ctx, "delete",
		"gitrepositories.source.toolkit.fluxcd.io", "k2s-backup-restore-repo",
		"-n", "rollout", "--timeout=60s", "--ignore-not-found")

	suite.Kubectl().Exec(ctx, "delete", "secret", "k2s-backup-restore-secret",
		"-n", "rollout", "--ignore-not-found")
}

// waitForNamespaceTermination polls until the given namespace no longer exists.
// If the namespace is stuck in Terminating state (e.g. because CRD controllers
// were deleted before their resources' finalizers could be processed), it
// forcefully removes finalizers and force-finalizes the namespace object.
func waitForNamespaceTermination(ctx context.Context, ns string) {
	_, exitCode := suite.Kubectl().Exec(ctx, "get", "namespace", ns)
	if exitCode != 0 {
		return // already gone
	}

	Eventually(func() bool {
		phase, code := suite.Kubectl().Exec(ctx, "get", "namespace", ns,
			"-o", "jsonpath={.status.phase}")
		if code != 0 {
			return true // namespace gone
		}
		if strings.TrimSpace(phase) == "Terminating" {
			forceCleanTerminatingNamespace(ctx, ns)
		}
		return false
	}).WithTimeout(2*time.Minute).WithPolling(5*time.Second).Should(BeTrue(),
		fmt.Sprintf("namespace %q should be fully terminated before proceeding", ns))
}

// forceCleanTerminatingNamespace removes finalizers from all resources in the
// namespace, then force-finalizes the namespace object via the Kubernetes API.
func forceCleanTerminatingNamespace(ctx context.Context, ns string) {
	GinkgoWriter.Printf("Namespace %q stuck in Terminating state \u2013 forcing cleanup\n", ns)

	apiResources, exitCode := suite.Kubectl().Exec(ctx, "api-resources",
		"--namespaced", "--verbs=list", "-o", "name")
	if exitCode == 0 {
		for _, rt := range strings.Split(apiResources, "\n") {
			rt = strings.TrimSpace(rt)
			if rt == "" || rt == "events" || rt == "events.events.k8s.io" {
				continue
			}
			suite.Kubectl().Exec(ctx, "patch", rt, "--all", "-n", ns,
				"--type=merge", "-p", `{"metadata":{"finalizers":null}}`)
		}
	}

	nsJSON, exitCode := suite.Kubectl().Exec(ctx, "get", "namespace", ns, "-o", "json")
	if exitCode != 0 {
		return
	}

	var nsObj map[string]interface{}
	if err := json.Unmarshal([]byte(nsJSON), &nsObj); err != nil {
		return
	}
	if spec, ok := nsObj["spec"].(map[string]interface{}); ok {
		spec["finalizers"] = []interface{}{}
	}

	modified, err := json.Marshal(nsObj)
	if err != nil {
		return
	}

	tmpFile := filepath.Join(os.TempDir(), fmt.Sprintf("k2s-ns-finalize-%s.json", ns))
	if os.WriteFile(tmpFile, modified, 0644) != nil {
		return
	}
	defer os.Remove(tmpFile)

	suite.Kubectl().Exec(ctx, "replace", "--raw",
		fmt.Sprintf("/api/v1/namespaces/%s/finalize", ns), "-f", tmpFile)
}

var _ = Describe("'rollout fluxcd' addon backup/restore", Ordered, func() {
	const (
		testNamespace        = "rollout"
		testSecretName       = "k2s-backup-restore-secret"
		testSecretPassword   = "k2s-fluxcd-backup-restore-sentinel"
		testGitRepository    = "k2s-backup-restore-repo"
		testRepositoryConfig = "k2s-backup-restore-gitrepository.yaml"
	)

	var (
		zipPath          string
		passwordDataBase string
	)

	BeforeAll(func() {
		zipPath = backupZipPath("basic")
		cleanupBackupDir()
		Expect(os.MkdirAll(backupDir, os.ModePerm)).To(Succeed())
	})

	AfterAll(func(ctx context.Context) {
		cleanupTestResources(ctx)
		suite.K2sCli().Exec(ctx, "addons", "disable", "rollout", "fluxcd", "-o")
		k2s.VerifyAddonIsDisabled("rollout", "fluxcd")
	})

	It("fails backup when addon is disabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "rollout", "fluxcd")
		Expect(output).To(ContainSubstring("not enabled"))
	})

	It("fails restore with a non-existent backup file", func(ctx context.Context) {
		fakePath := filepath.Join(backupDir, "does-not-exist.zip")

		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "rollout", "fluxcd", "-f", fakePath)
		Expect(output).To(ContainSubstring("not found"))
	})

	It("enables the addon", func(ctx context.Context) {
		waitForNamespaceTermination(ctx, testNamespace)

		suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "fluxcd", "-o")

		k2s.VerifyAddonIsEnabled("rollout", "fluxcd")

		// Enable.ps1 does not check the exit code of 'kubectl create namespace'.
		// If the namespace was still Terminating from a prior run, the create
		// silently fails and the enable "succeeds" without actually deploying
		// anything. Verify the namespace is Active so we fail here — not in a
		// downstream spec.
		Eventually(func() string {
			phase, _ := suite.Kubectl().Exec(ctx, "get", "namespace", testNamespace,
				"-o", "jsonpath={.status.phase}")
			return strings.TrimSpace(phase)
		}).WithTimeout(2*time.Minute).WithPolling(5*time.Second).Should(Equal("Active"),
			"namespace %q must be Active after enable; Enable.ps1 may have failed to create it", testNamespace)
	})

	It("creates a secret-referenced GitRepository to validate Flux backup scope", func(ctx context.Context) {
		suite.Kubectl().MustExec(ctx,
			"create", "secret", "generic", testSecretName,
			"-n", testNamespace,
			"--from-literal=username=k2s",
			fmt.Sprintf("--from-literal=password=%s", testSecretPassword))

		repoPath := filepath.Join(backupDir, testRepositoryConfig)
		repoManifest := fmt.Sprintf(`apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: %s
  namespace: %s
spec:
  interval: 1m
  url: https://github.com/fluxcd/flux2-kustomize-helm-example
  secretRef:
    name: %s
`, testGitRepository, testNamespace, testSecretName)

		Expect(os.WriteFile(repoPath, []byte(repoManifest), 0o600)).To(Succeed())
		suite.Kubectl().MustExec(ctx, "apply", "-f", repoPath)

		passwordDataBase = suite.Kubectl().MustExec(ctx,
			"get", "secret", testSecretName, "-n", testNamespace,
			"-o", "jsonpath={.data.password}")
		Expect(passwordDataBase).NotTo(BeEmpty())

		secretRefName := suite.Kubectl().MustExec(ctx,
			"get", "gitrepositories.source.toolkit.fluxcd.io", testGitRepository, "-n", testNamespace,
			"-o", "jsonpath={.spec.secretRef.name}")
		Expect(secretRefName).To(Equal(testSecretName))
	})

	It("creates a backup", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "backup", "rollout", "fluxcd", "-f", zipPath, "-o")
		Expect(zipPath).To(BeAnExistingFile())
	})

	It("fails restore while addon is still enabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "rollout", "fluxcd", "-f", zipPath)
		Expect(output).To(ContainSubstring("disable"))
	})

	It("disables the addon", func(ctx context.Context) {
		cleanupTestResources(ctx)

		suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "fluxcd", "-o")

		k2s.VerifyAddonIsDisabled("rollout", "fluxcd")
	})

	It("restores from backup and keeps the GitRepository plus referenced Secret", func(ctx context.Context) {
		waitForNamespaceTermination(ctx, testNamespace)

		suite.K2sCli().MustExec(ctx, "addons", "restore", "rollout", "fluxcd", "-f", zipPath, "-o")

		k2s.VerifyAddonIsEnabled("rollout", "fluxcd")

		secretRefName := suite.Kubectl().MustExec(ctx,
			"get", "gitrepositories.source.toolkit.fluxcd.io", testGitRepository, "-n", testNamespace,
			"-o", "jsonpath={.spec.secretRef.name}")
		Expect(secretRefName).To(Equal(testSecretName), "GitRepository should survive backup/restore")

		passwordDataAfter := suite.Kubectl().MustExec(ctx,
			"get", "secret", testSecretName, "-n", testNamespace,
			"-o", "jsonpath={.data.password}")
		Expect(passwordDataAfter).To(Equal(passwordDataBase), "referenced Secret should be restored unchanged")
	})

	It("can be enabled when only addons/common and addons/rollout are present", func(ctx context.Context) {
		GinkgoWriter.Println(">>> TEST: can be enabled when only addons/common and addons/rollout are present")

		GinkgoWriter.Println("[Test] Disabling rollout fluxcd to ensure clean re-enable path")
		suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "fluxcd", "-o")

		GinkgoWriter.Println("[Test] Staging addon isolation: keeping only common and rollout")
		restore, err := exportimport.StageAddonIsolation(suite.RootDir(), "rollout")
		Expect(err).ToNot(HaveOccurred(), "staging addon isolation should succeed")
		DeferCleanup(func() {
			Expect(restore()).To(Succeed(), "addon isolation restore must succeed to avoid a partial workspace state")
		})
		DeferCleanup(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "rollout", "fluxcd", "-o")
		})

		GinkgoWriter.Println("[Test] Enabling rollout fluxcd with isolated addons directory")
		output := suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "fluxcd", "-o")

		GinkgoWriter.Println("[Test] Verifying rollout fluxcd addon is enabled")
		k2s.VerifyAddonIsEnabled("rollout", "fluxcd")

		GinkgoWriter.Println("[Test] Verifying flux namespace is Active")
		Eventually(func() string {
			phase, _ := suite.Kubectl().Exec(ctx, "get", "namespace", testNamespace,
				"-o", "jsonpath={.status.phase}")
			return strings.TrimSpace(phase)
		}).WithTimeout(2*time.Minute).WithPolling(5*time.Second).Should(Equal("Active"),
			"namespace %q must be Active after enable; Enable.ps1 may have failed to create it", testNamespace)

		GinkgoWriter.Println("[Test] Verifying no PowerShell module-not-found signatures in output")
		Expect(output).NotTo(ContainSubstring("no valid module file was found"), "enable output must not contain PowerShell module-not-found error")
		Expect(output).NotTo(ContainSubstring("was not loaded"), "enable output must not contain PowerShell module-not-loaded error")
	})
})
