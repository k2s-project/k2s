// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package dashboardenabdisable

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"os/exec"
	"path"
	"testing"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
	"github.com/onsi/gomega/gstruct"
)

const testClusterTimeout = time.Minute * 10

// Headlamp plugin runtime contract (must match addons/dashboard/dashboard.module.psm1).
const (
	headlampDeployment    = "headlamp"
	headlampNamespace     = "dashboard"
	headlampContainerName = "headlamp"
	headlampPluginsVolume = "headlamp-plugins"
	certManagerPluginName = "cert-manager-plugin"
	fluxPluginName        = "flux-plugin"
	prometheusPluginName  = "prometheus-plugin"
	kedaPluginName        = "keda-plugin"
)

var (
	suite                 *framework.K2sTestSuite
	portForwardingSession *gexec.Session
	k2s                   *dsl.K2s
	testFailed            = false
)

func TestDashboard(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "dashboard Addon Acceptance Tests", Label("addon", "addon-diverse", "acceptance", "setup-required", "invasive", "dashboard", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		GinkgoWriter.Println(">>> TEST: AfterSuite - suite is nil (BeforeSuite failed), skipping cleanup")
		return
	}

	if testFailed {
		// Best-effort diagnostic dump — must NOT block AfterSuite.
		// Use os/exec directly with a 3-minute context so MSINFO32 or other
		// slow host-diag tools can't hang the suite indefinitely.
		// Gomega's MustExec / Exec would call Fail() on timeout, so we bypass it.
		GinkgoWriter.Println(">>> TEST: AfterSuite - collecting system dump (best-effort, 3 min cap)")
		dumpCtx, dumpCancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer dumpCancel()
		k2sExe := path.Join(suite.RootDir(), "k2s.exe")
		dumpCmd := exec.CommandContext(dumpCtx, k2sExe, "system", "dump", "-S", "-o")
		if out, err := dumpCmd.CombinedOutput(); err != nil {
			GinkgoWriter.Printf(">>> TEST: AfterSuite - system dump error: %v (output: %s)\n", err, string(out))
		}
	}

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("'dashboard' addon", Ordered, func() {
	Describe("status command", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "dashboard")

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Addon .+dashboard.+ is .+disabled.+`),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "dashboard", "-o", "json")

				var status status.AddonPrintStatus

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

				Expect(status.Name).To(Equal("dashboard"))
				Expect(status.Enabled).NotTo(BeNil())
				Expect(*status.Enabled).To(BeFalse())
				Expect(status.Props).To(BeNil())
				Expect(status.Error).To(BeNil())
			})
		})
	})

	Describe("disable command", func() {
		When("addon is already disabled", func() {
			It("prints already-disabled message and exits with non-zero", func(ctx context.Context) {
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", "dashboard")

				Expect(output).To(ContainSubstring("already disabled"))
			})
		})
	})

	Describe("enable command", func() {
		When("no ingress controller is configured", func() {
			AfterAll(func(ctx context.Context) {
				if portForwardingSession != nil {
					portForwardingSession.Kill()
				}

				suite.K2sCli().MustExec(ctx, "addons", "disable", "dashboard", "-o")
				k2s.VerifyAddonIsDisabled("dashboard")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "headlamp", "dashboard")
			})

			It("is in enabled state and pod is in running state", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "dashboard", "-o")
				k2s.VerifyAddonIsEnabled("dashboard")

				suite.Cluster().ExpectDeploymentToBeAvailable("headlamp", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "headlamp", "dashboard")
			})

			It("is reachable through port forwarding", func(ctx context.Context) {
				kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
				portForwarding := exec.Command(kubectl, "-n", "dashboard", "port-forward", "svc/headlamp", "4466:4466")
				portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

				url := "http://localhost:4466/dashboard/"
				suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-o", "NUL", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
			})

			It("does not inject any Headlamp plugin init-containers, volume, or mount when no plugin capability is present", func(ctx context.Context) {
				// Plugin activation is capability-driven, not always-on. With only the dashboard
				// enabled (no cert-manager/flux/prometheus/keda capability in the cluster),
				// Sync-HeadlampPlugins must leave the headlamp deployment free of every K2s plugin
				// init-container, the shared plugins volume, and the main-container mount.
				suite.Cluster().ExpectDeploymentNotToHaveInitContainer(ctx, headlampDeployment, headlampNamespace, certManagerPluginName)
				suite.Cluster().ExpectDeploymentNotToHaveInitContainer(ctx, headlampDeployment, headlampNamespace, fluxPluginName)
				suite.Cluster().ExpectDeploymentNotToHaveInitContainer(ctx, headlampDeployment, headlampNamespace, prometheusPluginName)
				suite.Cluster().ExpectDeploymentNotToHaveInitContainer(ctx, headlampDeployment, headlampNamespace, kedaPluginName)

				suite.Cluster().ExpectDeploymentNotToHaveVolume(ctx, headlampDeployment, headlampNamespace, headlampPluginsVolume)
				suite.Cluster().ExpectDeploymentNotToHaveVolumeMount(ctx, headlampDeployment, headlampNamespace, headlampContainerName, headlampPluginsVolume)
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})

		When("traefik as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "dashboard", "-o")
				suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")
				k2s.VerifyAddonIsDisabled("dashboard")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "headlamp", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
			})

			It("is in enabled state and pod is in running state", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "dashboard", "--ingress", "traefik", "-o")
				k2s.VerifyAddonIsEnabled("dashboard")

				suite.Cluster().ExpectDeploymentToBeAvailable("headlamp", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "headlamp", "dashboard")
			})

			It("is reachable through k2s.cluster.local", func(ctx context.Context) {
				url := "https://k2s.cluster.local/dashboard/"
				_, err := suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, url)
				Expect(err).NotTo(HaveOccurred())
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})

		When("nginx as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "dashboard", "-o")
				suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
				k2s.VerifyAddonIsDisabled("dashboard")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "headlamp", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
			})

			It("is in enabled state and pod is in running state", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "dashboard", "--ingress", "nginx", "-o")
				k2s.VerifyAddonIsEnabled("dashboard")

				suite.Cluster().ExpectDeploymentToBeAvailable("headlamp", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "headlamp", "dashboard")
			})

			It("is reachable through k2s.cluster.local", func(ctx context.Context) {
				url := "https://k2s.cluster.local/dashboard/"
				_, err := suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, url)
				Expect(err).NotTo(HaveOccurred())
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})

		When("nginx-gw as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx-gw", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("nginx-gw-controller", "nginx-gw")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "dashboard", "-o")
				suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
				k2s.VerifyAddonIsDisabled("dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "headlamp", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "nginx-gw", "nginx-gw")
			})

			It("is in enabled state and pod is in running state", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "dashboard", "--ingress", "nginx-gw", "-o")
				k2s.VerifyAddonIsEnabled("dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("headlamp", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "headlamp", "dashboard")
			})

			It("is reachable through k2s.cluster.local", func(ctx context.Context) {
				url := "https://k2s.cluster.local/dashboard/"
				_, err := suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, url)
				Expect(err).NotTo(HaveOccurred())
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})
	})
})

func expectAddonToBeAlreadyEnabled(ctx context.Context) {
	output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "dashboard")

	Expect(output).To(ContainSubstring("already enabled"))
}

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().MustExec(ctx, "addons", "status", "dashboard")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Addon .+dashboard.+ is .+enabled.+`),
		MatchRegexp("The Headlamp dashboard is working"),
	))

	// Small delay between the two status calls to avoid a transient Windows
	// "Access is denied" error when PowerShell is spawned twice in rapid succession
	// (observed with Windows AppLocker/process-token cleanup timing).
	time.Sleep(2 * time.Second)

	output = suite.K2sCli().MustExec(ctx, "addons", "status", "dashboard", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("dashboard"))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
	Expect(status.Props).NotTo(BeNil())
	Expect(status.Props).To(ContainElements(
		SatisfyAll(
			HaveField("Name", "IsHeadlampRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("The Headlamp dashboard is working")))),
	))
}
