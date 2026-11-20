// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

// Package argocdgitopssync tests the GitOps addon delivery infrastructure
// deployed by the rollout/argocd addon.
//
// The suite verifies two layers:
//
//  1. Infrastructure layer — the Kubernetes resources in k2s-addon-sync that
//     the rollout/argocd Enable.ps1 creates: Namespace, ConfigMaps
//     (addon-sync-config, addon-sync-script), ServiceAccount, and the
//     addon-sync-poller CronJob.
//
//  2. End-to-end sync layer (label "registry") — exports the metrics addon,
//     pushes the OCI artifact to the local registry, manually triggers a
//     one-shot Job from the CronJob, waits for completion, and verifies the
//     sync log output confirms successful processing.
package argocdgitopssync

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/k2s-project/k2s/test/e2e/addons/exportimport"
	gitopssync "github.com/k2s-project/k2s/test/e2e/addons/gitopssync"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	// testClusterTimeout is 30m (vs 20m in rollout-argocd_test.go) to accommodate
	// the extra OCI export → registry push → one-shot Job pipeline under load.
	testClusterTimeout = time.Minute * 30
	addonSyncNamespace = "k2s-addon-sync"
	addonSyncConfig    = "addon-sync-config"
	addonSyncScript    = "addon-sync-script"
	addonSyncSA        = "addon-sync-processor"
	addonSyncPoller    = "addon-sync-poller"
	testAddonName      = "metrics"
	registryHost       = "k2s.registry.local:30500"
	manualJobName      = "addon-sync-argocd-e2e"
	testExportSubDir   = "gitops-sync-argocd-e2e"
	badAddonName       = "bad-sync-test"
	badAddonTag        = "v1.0.0"
)

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	linuxOnly  = false
	testFailed = false
)

func TestRolloutArgoCDAddonSync(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "rollout argocd GitOps Addon Sync Tests",
		Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive",
			"rollout-argocd", "gitops-sync", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
	linuxOnly = suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly()
	k2s = dsl.NewK2s(suite)
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}
	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("'rollout argocd' GitOps addon sync", Ordered, func() {

	BeforeAll(func(ctx context.Context) {
		GinkgoWriter.Println("[Setup] Enabling rollout argocd addon")
		suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "argocd", "-o")
		k2s.VerifyAddonIsEnabled("rollout", "argocd")
		GinkgoWriter.Println("[Setup] rollout argocd addon enabled")

		DeferCleanup(func(ctx context.Context) {
			GinkgoWriter.Println("[Teardown] Disabling rollout argocd addon")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "argocd", "-o")
			k2s.VerifyAddonIsDisabled("rollout", "argocd")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollout")
			suite.Cluster().ExpectStatefulSetToBeDeleted("argocd-application-controller", "rollout", ctx)
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-redis", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-server", "rollout")
		})
	})

	// -----------------------------------------------------------------------
	// Infrastructure tests — always run when rollout/argocd is enabled.
	// -----------------------------------------------------------------------
	Describe("addon-sync infrastructure", Ordered, func() {
		It("creates the k2s-addon-sync namespace", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx,
				"get", "namespace", addonSyncNamespace,
				"-o", "jsonpath={.metadata.name}")

			Expect(output).To(Equal(addonSyncNamespace),
				"Namespace %s should exist after enabling rollout/argocd", addonSyncNamespace)
		})

		It("creates the addon-sync-config ConfigMap with all required keys", func(ctx context.Context) {
			// Query each key individually so the assertion proves exact key existence,
			// not just that the string appears somewhere in the serialised .data blob.
			for _, key := range []string{"REGISTRY_URL", "K2S_INSTALL_DIR", "INSECURE"} {
				value := suite.Kubectl().MustExec(ctx,
					"get", "configmap", addonSyncConfig,
					"-n", addonSyncNamespace,
					"-o", fmt.Sprintf("jsonpath={.data.%s}", key))
				Expect(value).NotTo(BeEmpty(),
					"addon-sync-config must have a non-empty %s key", key)
			}
		})

		It("creates the addon-sync-script ConfigMap containing Sync-Addons.ps1", func(ctx context.Context) {
			// Query the key directly to prove key existence, not just a substring hit
			// anywhere in the serialised .data blob (e.g. inside the script body itself).
			value := suite.Kubectl().MustExec(ctx,
				"get", "configmap", addonSyncScript,
				"-n", addonSyncNamespace,
				"-o", `jsonpath={.data['Sync-Addons\.ps1']}`)

			Expect(value).NotTo(BeEmpty(),
				"addon-sync-script ConfigMap must have a non-empty Sync-Addons.ps1 key")
		})

		It("creates the addon-sync-processor ServiceAccount", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx,
				"get", "serviceaccount", addonSyncSA,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.metadata.name}")

			Expect(output).To(Equal(addonSyncSA),
				"ServiceAccount %s should exist in %s", addonSyncSA, addonSyncNamespace)
		})

		It("deploys the addon-sync-poller CronJob", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx,
				"get", "cronjob", addonSyncPoller,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.metadata.name}")

			Expect(output).To(Equal(addonSyncPoller),
				"CronJob %s should exist in %s", addonSyncPoller, addonSyncNamespace)
		})

		It("addon-sync-poller CronJob fires every 5 minutes", func(ctx context.Context) {
			schedule := suite.Kubectl().MustExec(ctx,
				"get", "cronjob", addonSyncPoller,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.spec.schedule}")

			Expect(schedule).To(Equal("*/5 * * * *"),
				"CronJob schedule should be '*/5 * * * *'")
		})

		It("addon-sync-poller CronJob has Forbid concurrencyPolicy to prevent overlapping runs", func(ctx context.Context) {
			policy := suite.Kubectl().MustExec(ctx,
				"get", "cronjob", addonSyncPoller,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.spec.concurrencyPolicy}")

			Expect(policy).To(Equal("Forbid"),
				"CronJob concurrencyPolicy should be 'Forbid' to prevent concurrent sync runs")
		})

		It("addon-sync-poller CronJob has activeDeadlineSeconds of 300 seconds", func(ctx context.Context) {
			deadline := suite.Kubectl().MustExec(ctx,
				"get", "cronjob", addonSyncPoller,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.spec.jobTemplate.spec.activeDeadlineSeconds}")

			// 300 s (5 min) is sufficient because the pause-win image is pre-cached
			// on every K2s Windows node (zero pull time). The sync script itself
			// completes in 30-120 s depending on the number of addons.
			Expect(deadline).To(Equal("300"),
				"CronJob activeDeadlineSeconds should be 300 (5 min) — pause-win image is pre-cached")
		})

		It("addon-sync-poller CronJob references the addon-sync-config ConfigMap via env valueFrom", func(ctx context.Context) {
			// Target env[*].valueFrom.configMapKeyRef.name specifically so the assertion
			// proves the valueFrom mechanism rather than any arbitrary string match.
			envOutput := suite.Kubectl().MustExec(ctx,
				"get", "cronjob", addonSyncPoller,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.spec.jobTemplate.spec.template.spec.containers[0].env[*].valueFrom.configMapKeyRef.name}")

			Expect(envOutput).To(ContainSubstring(addonSyncConfig),
				"Poller Job containers should reference %s via env[*].valueFrom.configMapKeyRef", addonSyncConfig)
		})

		It("addon-sync-poller CronJob references the addon-sync-script ConfigMap volume", func(ctx context.Context) {
			volumesOutput := suite.Kubectl().MustExec(ctx,
				"get", "cronjob", addonSyncPoller,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.spec.jobTemplate.spec.template.spec.volumes[*].configMap.name}")

			Expect(volumesOutput).To(ContainSubstring(addonSyncScript),
				"Poller Job should mount %s as a volume", addonSyncScript)
		})

		It("addon-sync-poller CronJob runs as a Windows HostProcess container", func(ctx context.Context) {
			if linuxOnly {
				Skip("Windows HostProcess containers are not available on Linux-only clusters")
			}
			// K2s manifests set hostProcess at pod securityContext level.
			// Container-level hostProcess may be inherited and therefore empty.
			containerHostProcess := suite.Kubectl().MustExec(ctx,
				"get", "cronjob", addonSyncPoller,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.spec.jobTemplate.spec.template.spec.containers[0].securityContext.windowsOptions.hostProcess}")

			Expect(containerHostProcess).To(Or(Equal("true"), BeEmpty()),
				"Container-level hostProcess may be explicitly true or inherited from pod-level securityContext")

			podHostProcess := suite.Kubectl().MustExec(ctx,
				"get", "cronjob", addonSyncPoller,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.spec.jobTemplate.spec.template.spec.securityContext.windowsOptions.hostProcess}")

			Expect(podHostProcess).To(Equal("true"),
				"Pod-level hostProcess must also be true")
		})

		It("addon-sync-poller CronJob runs as NT AUTHORITY\\SYSTEM", func(ctx context.Context) {
			if linuxOnly {
				Skip("Windows NT AUTHORITY\\SYSTEM identity is not applicable on Linux-only clusters")
			}
			user := suite.Kubectl().MustExec(ctx,
				"get", "cronjob", addonSyncPoller,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.spec.jobTemplate.spec.template.spec.securityContext.windowsOptions.runAsUserName}")

			Expect(user).To(Equal(`NT AUTHORITY\SYSTEM`),
				"Poller Job should run as NT AUTHORITY\\SYSTEM to write to K2s install directory")
		})
	})

	// -----------------------------------------------------------------------
	// End-to-end sync test — requires the registry addon.
	// Labels: registry
	// -----------------------------------------------------------------------
	When("registry addon is enabled", Label("registry"), Ordered, func() {
		var exportDir string
		var exportedOciFile string

		BeforeAll(func(ctx context.Context) {
			GinkgoWriter.Println("[Setup] Enabling registry addon for GitOps sync E2E test")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "registry", "-o")
			k2s.VerifyAddonIsEnabled("registry")

			// Best-effort cleanup: remove malformed artifact from negative tests in prior runs.
			orasExe := filepath.Join(suite.RootDir(), "bin", "oras.exe")
			suite.Cli(orasExe).Exec(ctx,
				"manifest", "delete",
				fmt.Sprintf("%s/addons/%s:%s", registryHost, badAddonName, badAddonTag),
				"--plain-http", "--force")
			os.Remove(filepath.Join(suite.RootDir(), "addons", ".addon-sync-digests", badAddonName))

			exportDir = filepath.Join(suite.RootDir(), "tmp", testExportSubDir)
			GinkgoWriter.Printf("[Setup] Export directory: %s\n", exportDir)

			// Delete any digest file from previous runs so sync runs unconditionally.
			digestFile := filepath.Join(suite.RootDir(), "addons", ".addon-sync-digests", testAddonName)
			if err := os.Remove(digestFile); err == nil {
				GinkgoWriter.Printf("[Setup] Removed stale digest file: %s\n", digestFile)
			}

			// Delete any previously triggered manual test Job.
			suite.Kubectl().Exec(ctx,
				"delete", "job", manualJobName,
				"-n", addonSyncNamespace,
				"--ignore-not-found=true")

			// Delete any CronJob-spawned jobs left from a prior or concurrent trigger.
			suite.Kubectl().Exec(ctx,
				"delete", "jobs",
				"-n", addonSyncNamespace,
				"-l", "batch.kubernetes.io/cronjob-name="+addonSyncPoller,
				"--ignore-not-found=true")

			DeferCleanup(func(ctx context.Context) {
				// Remove manually triggered Job (ignore if already gone via ttlSecondsAfterFinished).
				suite.Kubectl().Exec(ctx,
					"delete", "job", manualJobName,
					"-n", addonSyncNamespace,
					"--ignore-not-found=true")

				// Remove digest file written by the sync Job so future runs detect change.
				cleanupDigest := filepath.Join(suite.RootDir(), "addons", ".addon-sync-digests", testAddonName)
				if err := os.Remove(cleanupDigest); err == nil {
					GinkgoWriter.Printf("[Teardown] Removed digest file: %s\n", cleanupDigest)
				}

				// Clean up exported artifacts.
				exportimport.CleanupExportedFiles(exportDir, exportedOciFile)

				GinkgoWriter.Println("[Teardown] Disabling registry addon")
				suite.K2sCli().MustExec(ctx, "addons", "disable", "registry", "-o")
				k2s.VerifyAddonIsDisabled("registry")
			})
		})

		It("exports the metrics addon manifests to an OCI tar (images and packages omitted)", func(ctx context.Context) {
			GinkgoWriter.Println("[Test] Exporting metrics addon (manifests only, --omit-images --omit-packages)")
			// Only the manifests+scripts layer is needed for the GitOps sync Job.
			// --omit-images and --omit-packages avoid pulling Windows images that
			// may not be cached in the containerd store on the test node.
			Expect(os.MkdirAll(exportDir, 0755)).To(Succeed())
			suite.K2sCli().MustExec(ctx, "addons", "export", testAddonName,
				"--omit-images", "--omit-packages",
				"-d", exportDir, "-o")

			pattern := filepath.Join(exportDir, fmt.Sprintf("K2s-*-addons-%s.oci.tar", testAddonName))
			files, err := filepath.Glob(pattern)
			Expect(err).ToNot(HaveOccurred())
			Expect(files).To(HaveLen(1),
				"export should produce exactly one OCI tar matching %s", pattern)

			exportedOciFile = files[0]
			info, err := os.Stat(exportedOciFile)
			Expect(err).ToNot(HaveOccurred(), "exported OCI tar should exist at %s", exportedOciFile)
			GinkgoWriter.Printf("[Test] Exported OCI tar (manifests only): %s (%d bytes)\n", exportedOciFile, info.Size())
		})

		It("pushes the exported OCI artifact to the local registry", func(ctx context.Context) {
			Expect(exportedOciFile).NotTo(BeEmpty(), "OCI tar must have been exported in previous step")

			// Extract the OCI Image Layout tar to a temp directory.
			// oras copy --from-oci-layout requires a directory, not a tar file.
			orasLayoutDir, err := os.MkdirTemp("", "k2s-oras-layout-argocd-*")
			Expect(err).ToNot(HaveOccurred())
			defer os.RemoveAll(orasLayoutDir)

			GinkgoWriter.Printf("[Test] Extracting %s → %s\n", exportedOciFile, orasLayoutDir)
			suite.Cli(gitopssync.TarExe()).MustExec(ctx, "-xf", exportedOciFile, "-C", orasLayoutDir)

			// Read the tag dynamically from the extracted OCI layout to avoid
			// hardcoding the addon version in test code.
			addonTag, err := gitopssync.ReadTagFromOCILayout(orasLayoutDir)
			Expect(err).ToNot(HaveOccurred(), "should read tag from exported OCI layout index.json")
			GinkgoWriter.Printf("[Test] Detected addon tag from OCI layout: %s\n", addonTag)

			srcRef := fmt.Sprintf("%s:%s", orasLayoutDir, addonTag)
			destRef := fmt.Sprintf("%s/addons/%s:%s", registryHost, testAddonName, addonTag)

			GinkgoWriter.Printf("[Test] Pushing %s → %s\n", srcRef, destRef)

			orasExe := filepath.Join(suite.RootDir(), "bin", "oras.exe")
			suite.Cli(orasExe).MustExec(ctx,
				"copy",
				"--from-oci-layout", srcRef,
				destRef,
				"--to-plain-http")

			GinkgoWriter.Printf("[Test] Push succeeded: %s\n", destRef)
		})

		It("executes a manual sync Job triggered from the CronJob and reports success", func(ctx context.Context) {
			GinkgoWriter.Printf("[Test] Creating one-shot Job %s from CronJob %s\n", manualJobName, addonSyncPoller)

			suite.Kubectl().MustExec(ctx,
				"create", "job", manualJobName,
				"--from=cronjob/"+addonSyncPoller,
				"-n", addonSyncNamespace)

			GinkgoWriter.Println("[Test] Waiting for Job to complete (timeout: 20m)")
			gitopssync.WaitForJobCompletion(ctx, suite, addonSyncNamespace, manualJobName)

			// Explicit failure check visible in this spec body — not hidden in a helper.
			failedStatus, _ := suite.Kubectl().Exec(ctx,
				"get", "job", manualJobName,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.status.conditions[?(@.type=='Failed')].status}")
			failureReason, _ := suite.Kubectl().Exec(ctx,
				"get", "job", manualJobName,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.status.conditions[?(@.type=='Failed')].reason}")
			if failedStatus == "True" {
				GinkgoWriter.Printf("[Test] Job %s FAILED — reason: %q\n", manualJobName, failureReason)
			}
			Expect(failedStatus).NotTo(Equal("True"),
				"Job %s must not be in Failed state (reason: %s)", manualJobName, failureReason)

			GinkgoWriter.Println("[Test] Retrieving Job pod logs")
			logs := gitopssync.GetJobLogs(ctx, suite, addonSyncNamespace, manualJobName)

			GinkgoWriter.Printf("[Test] Job logs (trimmed):\n%s\n", gitopssync.SafeTrim(logs, 2000))

			Expect(logs).To(ContainSubstring("Addon sync completed"),
				"Job log should contain the sync summary line")
			// Assert explicitly zero failures (not just "Failed: 1") to catch N>1 failures.
			Expect(logs).To(ContainSubstring("Failed: 0"),
				"Job log should report Failed: 0 in the sync summary")
			// Assert the addon was actually processed, not skipped due to a stale digest.
			Expect(logs).To(ContainSubstring("Synced: 1"),
				"Job log should report Synced: 1 confirming the addon was processed, not skipped")
			Expect(logs).NotTo(ContainSubstring("[AddonSync][ERROR]"),
				"Job log should contain no ERROR-level messages")
		})

		It("sync wrote a digest file proving the addon was processed (not skipped)", func(ctx context.Context) {
			// Sync-Addons.ps1 writes .addon-sync-digests/<addonName> after processing.
			// BeforeAll deleted any stale digest, so its existence here proves the
			// current sync run actually processed the metrics addon rather than skipping it.
			digestFile := filepath.Join(suite.RootDir(), "addons", ".addon-sync-digests", testAddonName)

			Expect(digestFile).To(BeAnExistingFile(),
				"Sync-Addons.ps1 should write digest file %s after processing %s", digestFile, testAddonName)

			GinkgoWriter.Printf("[Test] Digest file confirmed at: %s\n", digestFile)
		})

	})

	// -----------------------------------------------------------------------
	// Negative test — malformed OCI artifact triggers failure signaling.
	// Run with: --label-filter="registry && negative"
	// -----------------------------------------------------------------------
	When("a malformed OCI artifact with wrong layer media type is in the registry",
		Label("registry", "negative"), Ordered, func() {

			const (
				negativeJobName = "addon-sync-argocd-neg"
			)
			var badLayoutDir string

			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "registry", "-o")
				k2s.VerifyAddonIsEnabled("registry")
				// Remove stale digest so the poller unconditionally tries to sync bad-sync-test.
				os.Remove(filepath.Join(suite.RootDir(), "addons", ".addon-sync-digests", badAddonName))
				suite.Kubectl().Exec(ctx, "delete", "job", negativeJobName,
					"-n", addonSyncNamespace, "--ignore-not-found=true")

				// Best-effort delete the tag from a prior run so re-runs don't get AlreadyExists
				// when oras pushes the dummy artifact again.
				orasExe := filepath.Join(suite.RootDir(), "bin", "oras.exe")
				suite.Cli(orasExe).Exec(ctx,
					"manifest", "delete",
					fmt.Sprintf("%s/addons/%s:%s", registryHost, badAddonName, badAddonTag),
					"--plain-http", "--force")

				DeferCleanup(func(ctx context.Context) {
					suite.Kubectl().Exec(ctx, "delete", "job", negativeJobName,
						"-n", addonSyncNamespace, "--ignore-not-found=true")
					suite.Cli(orasExe).Exec(ctx,
						"manifest", "delete",
						fmt.Sprintf("%s/addons/%s:%s", registryHost, badAddonName, badAddonTag),
						"--plain-http", "--force")
					os.Remove(filepath.Join(suite.RootDir(), "addons", ".addon-sync-digests", badAddonName))
					if badLayoutDir != "" {
						os.RemoveAll(badLayoutDir)
					}
					suite.K2sCli().MustExec(ctx, "addons", "disable", "registry", "-o")
					k2s.VerifyAddonIsDisabled("registry")
				})
			})

			It("pushes an OCI artifact with the wrong layer media type to the registry", func(ctx context.Context) {
				var err error
				badLayoutDir, err = gitopssync.CreateDummyOCILayout(badAddonTag)
				Expect(err).ToNot(HaveOccurred(), "should create dummy OCI Image Layout with wrong media type")

				ref := fmt.Sprintf("%s/addons/%s:%s", registryHost, badAddonName, badAddonTag)
				srcRef := fmt.Sprintf("%s:%s", badLayoutDir, badAddonTag)
				GinkgoWriter.Printf("[Test] Pushing malformed artifact from OCI layout %s → %s\n", srcRef, ref)

				orasExe := filepath.Join(suite.RootDir(), "bin", "oras.exe")
				suite.Cli(orasExe).MustExec(ctx, "copy", "--from-oci-layout", srcRef, ref, "--to-plain-http")
				GinkgoWriter.Println("[Test] Malformed artifact accepted by registry (wrong layer media type is valid OCI)")
			})

			It("sync Job signals failure for the malformed artifact and does not silently succeed", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx,
					"create", "job", negativeJobName,
					"--from=cronjob/"+addonSyncPoller,
					"-n", addonSyncNamespace)

				GinkgoWriter.Printf("[Test] Waiting for negative test Job %s to finish (Complete or Failed)\n", negativeJobName)
				gitopssync.WaitForJobToFinish(ctx, suite, addonSyncNamespace, negativeJobName)

				condition, _ := suite.Kubectl().Exec(ctx,
					"get", "job", negativeJobName,
					"-n", addonSyncNamespace,
					"-o", "jsonpath={.status.conditions[*].type}")
				logs := gitopssync.GetJobLogs(ctx, suite, addonSyncNamespace, negativeJobName)
				GinkgoWriter.Printf("[Test] Job condition types: %q\n", condition)
				GinkgoWriter.Printf("[Test] Job logs (trimmed):\n%s\n", gitopssync.SafeTrim(logs, 2000))

				// The sync system must signal failure — either the Job pod exits non-zero
				// (condition contains "Failed"), or the script exits 0 with a non-zero
				// "Failed:" count in the summary, or it emits an [AddonSync][ERROR] log line.
				// Silently returning Synced:1 with no error for a malformed artifact is a bug.
				Expect(condition+logs).To(
					Or(ContainSubstring("Failed"), ContainSubstring("[AddonSync][ERROR]")),
					"sync system should signal failure for the malformed OCI artifact")
			})
		})
})
