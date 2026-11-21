// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package dashboardplugins

import (
	"context"
	"os/exec"
	"path"
	"testing"
	"time"

	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 30

// Headlamp plugin runtime contract (must match addons/dashboard/dashboard.module.psm1 and
// addons/dashboard/build/headlamp-plugins.lock.json).
const (
	headlampDeployment    = "headlamp"
	headlampNamespace     = "dashboard"
	headlampContainerName = "headlamp"
	headlampPluginsVolume = "headlamp-plugins"
)

// pluginCase is one row of the generic, data-driven plugin activation matrix. Adding a new
// plugin to the framework means adding one row here — no new test logic, mirroring the
// "one lock entry + one registry row" pattern in the runtime code.
type pluginCase struct {
	description   string   // human-readable capability/provider description
	enableArgs    []string // k2s CLI args that enable the capability provider addon
	disableArgs   []string // k2s CLI args that disable the capability provider addon
	initContainer string   // expected Headlamp plugin init-container name (== pluginDir)
	image         string   // expected plugin image identity (name only; substring match)
}

// The image field asserts the plugin image *identity* (repository name) only — never a version.
// ExpectDeploymentInitContainer does a strings.Contains() check, so "headlamp-plugin-<name>"
// confirms the correct plugin image is injected without duplicating version metadata here.
// Exact image versions are validated by the lock ↔ manifest ↔ registry parity unit tests
// (addons/dashboard/build/headlamp-plugin-images.unit.tests.ps1), which is the single source
// of truth; keeping versions out of this file removes E2E version drift by construction.
//
// The cert-manager plugin is intentionally NOT included here: it is already
// validated end-to-end by 02-securityenhanced (the security addon provides the capability).
// This suite covers the remaining plugins whose providers are otherwise unexercised.
var pluginCases = []pluginCase{
	{
		description:   "KEDA plugin via the autoscaling addon",
		enableArgs:    []string{"addons", "enable", "autoscaling", "-o"},
		disableArgs:   []string{"addons", "disable", "autoscaling", "-o"},
		initContainer: "keda-plugin",
		image:         "headlamp-plugin-keda",
	},
	{
		description:   "Flux plugin via the rollout fluxcd addon",
		enableArgs:    []string{"addons", "enable", "rollout", "fluxcd", "-o"},
		disableArgs:   []string{"addons", "disable", "rollout", "fluxcd", "-o"},
		initContainer: "flux-plugin",
		image:         "headlamp-plugin-flux",
	},
	{
		description:   "Prometheus plugin via the monitoring addon",
		enableArgs:    []string{"addons", "enable", "monitoring", "-o"},
		disableArgs:   []string{"addons", "disable", "monitoring", "-o"},
		initContainer: "prometheus-plugin",
		image:         "headlamp-plugin-prometheus",
	},
}

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
)

func TestDashboardPlugins(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "dashboard Headlamp Plugin Activation Acceptance Tests", Label("addon", "addon-diverse", "acceptance", "setup-required", "invasive", "dashboard", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	// The dashboard must be enabled for Sync-HeadlampPlugins to have any effect. Enable it once
	// for the whole suite; capability-provider addons are toggled per test case around it.
	GinkgoWriter.Println(">>> TEST: BeforeSuite - enabling dashboard addon")
	suite.K2sCli().MustExec(ctx, "addons", "enable", "dashboard", "-o")
	k2s.VerifyAddonIsEnabled("dashboard")
	suite.Cluster().ExpectDeploymentToBeAvailable(headlampDeployment, headlampNamespace)
	suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", headlampDeployment, headlampNamespace)
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil || k2s == nil {
		GinkgoWriter.Println(">>> TEST: AfterSuite - suite is nil (BeforeSuite failed), skipping cleanup")
		return
	}

	if testFailed {
		// Best-effort diagnostic dump — must NOT block AfterSuite.
		dumpCtx, dumpCancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer dumpCancel()
		k2sExe := path.Join(suite.RootDir(), "k2s.exe")
		dumpCmd := exec.CommandContext(dumpCtx, k2sExe, "system", "dump", "-S", "-o")
		if out, err := dumpCmd.CombinedOutput(); err != nil {
			GinkgoWriter.Printf(">>> TEST: AfterSuite - system dump error: %v (output: %s)\n", err, string(out))
		}
	}

	// Best-effort cleanup of any leftover capability providers, then the dashboard.
	suite.SetupInfo().ReloadRuntimeConfig()
	if k2s.IsAddonEnabled("autoscaling") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "autoscaling", "-o")
	}
	if k2s.IsAddonEnabled("monitoring") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")
	}
	if k2s.IsAddonEnabled("rollout", "fluxcd") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "fluxcd", "-o")
	}
	if k2s.IsAddonEnabled("dashboard") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "dashboard", "-o")
	}

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("dashboard Headlamp plugin activation (capability-driven)", Ordered, func() {

	// Generic, table-driven activation/removal cycle — identical logic for every plugin.
	for _, tc := range pluginCases {
		tc := tc // pin loop variable for the closures

		Context(tc.description, Ordered, func() {
			It("activates the plugin init-container, volume, and mount when the capability provider is enabled", func(ctx context.Context) {
				GinkgoWriter.Printf(">>> TEST: enabling capability provider: %v\n", tc.enableArgs)
				suite.K2sCli().MustExec(ctx, tc.enableArgs...)

				GinkgoWriter.Printf(">>> TEST: verifying plugin init-container %q (image %q)\n", tc.initContainer, tc.image)
				suite.Cluster().ExpectDeploymentInitContainer(ctx, headlampDeployment, headlampNamespace, tc.initContainer, tc.image)
				suite.Cluster().ExpectDeploymentVolume(ctx, headlampDeployment, headlampNamespace, headlampPluginsVolume)
				suite.Cluster().ExpectDeploymentVolumeMount(ctx, headlampDeployment, headlampNamespace, headlampContainerName, headlampPluginsVolume, "")

				suite.Cluster().ExpectDeploymentToBeAvailable(headlampDeployment, headlampNamespace)
			})

			It("removes the plugin init-container when the capability provider is disabled", func(ctx context.Context) {
				GinkgoWriter.Printf(">>> TEST: disabling capability provider: %v\n", tc.disableArgs)
				suite.K2sCli().MustExec(ctx, tc.disableArgs...)

				GinkgoWriter.Printf(">>> TEST: verifying plugin init-container %q removed\n", tc.initContainer)
				suite.Cluster().ExpectDeploymentNotToHaveInitContainer(ctx, headlampDeployment, headlampNamespace, tc.initContainer)

				suite.Cluster().ExpectDeploymentToBeAvailable(headlampDeployment, headlampNamespace)
			})
		})
	}

	// Multi-provider reconciliation: two independent capability providers must produce two
	// coexisting plugin init-containers, and disabling one must remove ONLY its plugin while
	// the other's remains — proving reconciliation is per-plugin, not all-or-nothing.
	Context("multi-provider reconciliation (KEDA + Flux)", Ordered, func() {
		const (
			kedaInit = "keda-plugin"
			fluxInit = "flux-plugin"
		)

		AfterAll(func(ctx context.Context) {
			if k2s.IsAddonEnabled("autoscaling") {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "autoscaling", "-o")
			}
			if k2s.IsAddonEnabled("rollout", "fluxcd") {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "fluxcd", "-o")
			}
		})

		It("activates both plugin init-containers when both providers are enabled", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "autoscaling", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "fluxcd", "-o")

			suite.Cluster().ExpectDeploymentInitContainer(ctx, headlampDeployment, headlampNamespace, kedaInit, "headlamp-plugin-keda")
			suite.Cluster().ExpectDeploymentInitContainer(ctx, headlampDeployment, headlampNamespace, fluxInit, "headlamp-plugin-flux")
		})

		It("removes only the disabled provider's plugin and keeps the other", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "autoscaling", "-o")

			suite.Cluster().ExpectDeploymentNotToHaveInitContainer(ctx, headlampDeployment, headlampNamespace, kedaInit)
			suite.Cluster().ExpectDeploymentInitContainer(ctx, headlampDeployment, headlampNamespace, fluxInit, "headlamp-plugin-flux")
		})
	})
})

