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

func TestRolloutArgocdBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "rollout argocd Addon Backup/Restore Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "rollout-argocd", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-rollout-argocd")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "rollout", "argocd", "-o")
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
	return filepath.Join(backupDir, fmt.Sprintf("rollout_argocd_backup_%s.zip", suffix))
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

	phase, _ := suite.Kubectl().Exec(ctx, "get", "namespace", ns,
		"-o", "jsonpath={.status.phase}")
	if phase == "Terminating" {
		forceCleanTerminatingNamespace(ctx, ns)
	}

	Eventually(func() bool {
		_, code := suite.Kubectl().Exec(ctx, "get", "namespace", ns)
		return code != 0
	}).WithTimeout(2*time.Minute).WithPolling(5*time.Second).Should(BeTrue(),
		fmt.Sprintf("namespace %q should be fully terminated before proceeding", ns))
}

// forceCleanTerminatingNamespace removes finalizers from all resources in the
// namespace, then force-finalizes the namespace object via the Kubernetes API.
func forceCleanTerminatingNamespace(ctx context.Context, ns string) {
	GinkgoWriter.Printf("Namespace %q stuck in Terminating state \u2013 forcing cleanup\n", ns)

	// 1. Remove finalizers from all namespaced resources so the namespace
	//    controller can finish deletion.
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

	// 2. Force-finalize the namespace by clearing spec.finalizers via the
	//    /finalize subresource.
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

var _ = Describe("'rollout argocd' addon backup/restore", Ordered, func() {

	const (
		namespace      = "rollout"
		markerAnnotKey = "k2s-test/marker"
		markerAnnotVal = "backup-restore-sentinel"
		appProjectName = "k2s-test-project"
	)

	var zipPath string

	BeforeAll(func() {
		zipPath = backupZipPath("basic")
		cleanupBackupDir()
		Expect(os.MkdirAll(backupDir, os.ModePerm)).To(Succeed())
	})

	AfterAll(func(ctx context.Context) {
		suite.K2sCli().Exec(ctx, "addons", "disable", "rollout", "argocd", "-o")
		k2s.VerifyAddonIsDisabled("rollout", "argocd")
	})

	// --- error tests while addon is disabled (cheap, no lifecycle cost) ---

	It("fails backup when addon is disabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "rollout", "argocd")
		Expect(output).To(ContainSubstring("not enabled"))
	})

	It("fails restore with a non-existent backup file", func(ctx context.Context) {
		fakePath := filepath.Join(backupDir, "does-not-exist.zip")

		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "rollout", "argocd", "-f", fakePath)
		Expect(output).To(ContainSubstring("not found"))
	})

	// --- single enable → mutate → backup → disable → restore cycle ---

	It("enables the addon", func(ctx context.Context) {
		waitForNamespaceTermination(ctx, namespace)

		suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "argocd", "-o")

		k2s.VerifyAddonIsEnabled("rollout", "argocd")

		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", namespace)
		suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", namespace, 1, ctx)
	})

	It("creates a test AppProject with a sentinel annotation", func(ctx context.Context) {
		// Write a dummy AppProject CR manifest and apply it.
		// The argocd admin export captures AppProjects.
		yamlContent := fmt.Sprintf(`apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: %s
  namespace: %s
  annotations:
    %s: "%s"
spec:
  description: "Backup/restore test project"
  sourceRepos:
    - '*'
  destinations:
    - namespace: '*'
      server: '*'
`, appProjectName, namespace, markerAnnotKey, markerAnnotVal)

		manifestFile := filepath.Join(backupDir, "test-appproject.yaml")
		Expect(os.WriteFile(manifestFile, []byte(yamlContent), 0644)).To(Succeed())

		suite.Kubectl().MustExec(ctx, "apply", "-f", manifestFile)

		// Verify the resource was created with the annotation
		output := suite.Kubectl().MustExec(ctx, "get", "appproject", appProjectName, "-n", namespace,
			"-o", fmt.Sprintf("jsonpath={.metadata.annotations['%s']}", markerAnnotKey))
		Expect(output).To(Equal(markerAnnotVal))
	})

	It("creates a backup", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "backup", "rollout", "argocd", "-f", zipPath, "-o")
		Expect(zipPath).To(BeAnExistingFile())
	})

	It("fails restore while addon is still enabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "rollout", "argocd", "-f", zipPath)
		Expect(output).To(ContainSubstring("disable"))
	})

	It("disables the addon", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "argocd", "-o")

		k2s.VerifyAddonIsDisabled("rollout", "argocd")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", namespace)
		suite.Cluster().ExpectStatefulSetToBeDeleted("argocd-application-controller", namespace, ctx)
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-dex-server", namespace)
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", namespace)
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-redis", namespace)
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-repo-server", namespace)
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-server", namespace)
	})

	It("restores from backup and the sentinel AppProject is present", func(ctx context.Context) {
		waitForNamespaceTermination(ctx, namespace)

		suite.K2sCli().MustExec(ctx, "addons", "restore", "rollout", "argocd", "-f", zipPath, "-o")

		k2s.VerifyAddonIsEnabled("rollout", "argocd")

		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", namespace)
		suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", namespace, 1, ctx)

		// Verify the sentinel AppProject annotation survived the backup/restore cycle
		output := suite.Kubectl().MustExec(ctx, "get", "appproject", appProjectName, "-n", namespace,
			"-o", fmt.Sprintf("jsonpath={.metadata.annotations['%s']}", markerAnnotKey))
		Expect(output).To(Equal(markerAnnotVal))
	})

	It("can be enabled when only addons/common and addons/rollout are present", func(ctx context.Context) {
		GinkgoWriter.Println(">>> TEST: can be enabled when only addons/common and addons/rollout are present")

		GinkgoWriter.Println("[Test] Disabling rollout argocd to ensure clean re-enable path")
		suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "argocd", "-o")

		GinkgoWriter.Println("[Test] Staging addon isolation: keeping only common and rollout")
		restore, err := exportimport.StageAddonIsolation(suite.RootDir(), "rollout")
		Expect(err).ToNot(HaveOccurred(), "staging addon isolation should succeed")
		DeferCleanup(func() {
			Expect(restore()).To(Succeed(), "addon isolation restore must succeed to avoid a partial workspace state")
		})
		DeferCleanup(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "rollout", "argocd", "-o")
		})

		GinkgoWriter.Println("[Test] Enabling rollout argocd with isolated addons directory")
		output := suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "argocd", "-o")

		GinkgoWriter.Println("[Test] Verifying rollout argocd addon is enabled")
		k2s.VerifyAddonIsEnabled("rollout", "argocd")

		GinkgoWriter.Println("[Test] Verifying argocd deployments are available")
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", namespace)
		suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", namespace)
		suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", namespace, 1, ctx)

		GinkgoWriter.Println("[Test] Verifying no PowerShell module-not-found signatures in output")
		Expect(output).NotTo(ContainSubstring("no valid module file was found"), "enable output must not contain PowerShell module-not-found error")
		Expect(output).NotTo(ContainSubstring("was not loaded"), "enable output must not contain PowerShell module-not-loaded error")
	})
})
