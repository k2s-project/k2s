// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package dashboardsecurityenhanced

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

	certManagerPluginName  = "cert-manager-plugin"
	certManagerPluginImage = "headlamp-plugin-cert-manager"
)

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
)

func TestDashboardSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Dashboard and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-1", "acceptance", "setup-required", "invasive", "dashboard", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up dashboard security test")
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up dashboard security test")

	// Guard against BeforeSuite failure: if suite was never initialised (e.g. addons
	// were still enabled when the test started), skip cleanup to avoid a nil-pointer panic.
	if suite == nil {
		GinkgoWriter.Println(">>> TEST: AfterSuite - suite is nil (BeforeSuite failed), skipping cleanup")
		return
	}

	if testFailed {
		// Best-effort diagnostic dump — must NOT block AfterSuite.
		// Use os/exec directly with a 3-minute context so MSINFO32 or other
		// slow host-diag tools can't hang the suite indefinitely.
		GinkgoWriter.Println(">>> TEST: AfterSuite - collecting system dump (best-effort, 3 min cap)")
		dumpCtx, dumpCancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer dumpCancel()
		k2sExe := path.Join(suite.RootDir(), "k2s.exe")
		dumpCmd := exec.CommandContext(dumpCtx, k2sExe, "system", "dump", "-S", "-o")
		if out, err := dumpCmd.CombinedOutput(); err != nil {
			GinkgoWriter.Printf(">>> TEST: AfterSuite - system dump error: %v (output: %s)\n", err, string(out))
		}
	}

	// Always attempt addon cleanup — best-effort, regardless of testFailed.
	// Individual Describe blocks have their own deactivation It steps; these
	// guards ensure we clean up even if a test fails mid-scenario.
	suite.SetupInfo().ReloadRuntimeConfig()

	if k2s.IsAddonEnabled("dashboard") {
		GinkgoWriter.Println(">>> TEST: AfterSuite - disabling leftover dashboard addon")
		suite.K2sCli().MustExec(ctx, "addons", "disable", "dashboard", "-o")
	}
	if k2s.IsAddonEnabled("ingress", "nginx") {
		GinkgoWriter.Println(">>> TEST: AfterSuite - disabling leftover ingress nginx addon")
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	}
	if k2s.IsAddonEnabled("security") {
		GinkgoWriter.Println(">>> TEST: AfterSuite - disabling leftover security addon")
		suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
	}

	suite.TearDown(ctx)
	GinkgoWriter.Println(">>> TEST: AfterSuite complete")
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("'dashboard and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then dashboard addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("activates the dashboard addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling dashboard addon")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "dashboard", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("headlamp", "dashboard")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "headlamp", "dashboard")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "dashboard")
			GinkgoWriter.Println(">>> TEST: Dashboard addon (Headlamp) enabled and verified with linkerd injection")
		})

		It("activates the cert-manager Headlamp plugin (capability-driven)", func(ctx context.Context) {
			// The security (enhanced) addon provides the cert-manager capability, so enabling
			// dashboard must trigger Sync-HeadlampPlugins to inject the cert-manager init-container,
			// plus the shared plugins volume and the main-container mount. This exercises
			// capability detection AND plugin activation.
			GinkgoWriter.Println(">>> TEST: Verifying cert-manager plugin init-container")
			suite.Cluster().ExpectDeploymentInitContainer(ctx, headlampDeployment, headlampNamespace, certManagerPluginName, certManagerPluginImage)

			GinkgoWriter.Println(">>> TEST: Verifying shared plugins volume and main-container mount")
			suite.Cluster().ExpectDeploymentVolume(ctx, headlampDeployment, headlampNamespace, headlampPluginsVolume)
			suite.Cluster().ExpectDeploymentVolumeMount(ctx, headlampDeployment, headlampNamespace, headlampContainerName, headlampPluginsVolume, "")
		})

		It("retains the cert-manager plugin when security is disabled (cert-manager kept for ingress)", func(ctx context.Context) {
			// Disable ONLY security (dashboard stays enabled) so we can observe reconciliation.
			// Plugin activation is CAPABILITY-based, not addon-based (see Sync-HeadlampPlugins):
			//   - cert-manager is SHARED: security/Disable.ps1 intentionally preserves cert-manager
			//     while any ingress addon is enabled ("cert-manager is required for enabled ingress
			//     addons. Skipping cert-manager uninstallation."). Enhanced security co-enables
			//     ingress/nginx, so cert-manager stays live here and Test-CertManagerCapabilityAvailable
			//     still returns true → the cert-manager-plugin init-container MUST be RETAINED.
			// The cert-manager plugin is only expected to disappear once ingress (and thus
			// cert-manager) is also disabled, which happens in the next step.
			GinkgoWriter.Println(">>> TEST: Disabling security to verify capability-based plugin reconciliation")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")

			// cert-manager capability persists (kept for ingress) → its plugin must remain.
			suite.Cluster().ExpectDeploymentInitContainer(ctx, headlampDeployment, headlampNamespace, certManagerPluginName, certManagerPluginImage)

			// Deployment must remain healthy after reconciliation.
			suite.Cluster().ExpectDeploymentToBeAvailable("headlamp", "dashboard")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "headlamp", "dashboard")
			GinkgoWriter.Println(">>> TEST: cert-manager plugin retained, deployment reconciled")
		})

		It("deactivates the remaining addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating remaining addons (security already disabled)")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "dashboard", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			GinkgoWriter.Println(">>> TEST: Remaining addons deactivated")
		})
	})

	Describe("Dashboard addon activated first then security addon", func() {
		It("activates the dashboard addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling dashboard addon first")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "dashboard", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("headlamp", "dashboard")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "headlamp", "dashboard")
			GinkgoWriter.Println(">>> TEST: Dashboard addon (Headlamp) enabled")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "dashboard")
			GinkgoWriter.Println(">>> TEST: Security addon enabled and linkerd injection verified")
		})

		It("deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "dashboard", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})
})
