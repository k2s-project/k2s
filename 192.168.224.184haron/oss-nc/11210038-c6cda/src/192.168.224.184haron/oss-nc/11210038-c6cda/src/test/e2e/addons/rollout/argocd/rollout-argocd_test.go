// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package rolloutargocd

import (
	"context"
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

const testClusterTimeout = time.Minute * 20

const (
	statusCheckRetryTimeout = 3 * time.Minute
	statusCheckRetryPolling = 10 * time.Second
)

var (
	suite                 *framework.K2sTestSuite
	portForwardingSession *gexec.Session
	linuxOnly             = false
	k2s                   *dsl.K2s
	testFailed            = false
)

func TestRolloutArgoCD(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "rollout argocd Addon Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "rollout-argocd", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
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

var _ = Describe("'rollout argocd' addon", Ordered, func() {
	When("no ingress controller is configured", func() {
		AfterAll(func(ctx context.Context) {
			portForwardingSession.Kill()
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

		It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", "rollout", "argocd")

			Expect(output).To(ContainSubstring("already disabled"))
		})

		Describe("status", func() {
			Context("default output", func() {
				It("displays disabled message", func(ctx context.Context) {
					output := suite.K2sCli().MustExec(ctx, "addons", "status", "rollout", "argocd")

					Expect(output).To(SatisfyAll(
						MatchRegexp(`ADDON STATUS`),
						MatchRegexp(`Implementation .+argocd.+ of Addon .+rollout.+ is .+disabled.+`),
					))
				})
			})

			Context("JSON output", func() {
				It("displays JSON", func(ctx context.Context) {
					output := suite.K2sCli().MustExec(ctx, "addons", "status", "rollout", "argocd", "-o", "json")

					var status status.AddonPrintStatus

					Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

					Expect(status.Name).To(Equal("rollout"))
					Expect(status.Implementation).To(Equal("argocd"))
					Expect(status.Enabled).NotTo(BeNil())
					Expect(*status.Enabled).To(BeFalse())
					Expect(status.Props).To(BeNil())
					Expect(status.Error).To(BeNil())
				})
			})
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "argocd", "-o")

			k2s.VerifyAddonIsEnabled("rollout", "argocd")

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", "rollout")

			suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", "rollout", 1, ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", "rollout")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-application-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-redis", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-server", "rollout")
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "rollout", "argocd")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("displays rollout argocd implementation in addon list", func(ctx context.Context) {
			expectListToDisplayImplementation(ctx)
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through port forwarding", func(ctx context.Context) {
			kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
			portForwarding := exec.Command(kubectl, "-n", "rollout", "port-forward", "svc/argocd-server", "8080:443")
			portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

			url := "https://localhost:8080/rollout/"
			suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-o", "NUL", "-m", "5", "--retry", "3", "--fail", "--retry-all-errors")
		})
	})

	When("traefik as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "argocd", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")

			k2s.VerifyAddonIsDisabled("rollout", "argocd")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollout")

			suite.Cluster().ExpectStatefulSetToBeDeleted("argocd-application-controller", "rollout", ctx)

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-redis", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-server", "rollout")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "argocd", "-o")

			k2s.VerifyAddonIsEnabled("rollout", "argocd")

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", "rollout")

			suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", "rollout", 1, ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", "rollout")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-application-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-redis", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-server", "rollout")
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "rollout", "argocd")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through k2s.cluster.local/rollout", func(ctx context.Context) {
			url := "https://k2s.cluster.local/rollout/"
			suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-o", "NUL", "-m", "5", "--retry", "3", "--fail", "--retry-all-errors")
		})
	})

	Describe("ingress-nginx as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "argocd", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")

			k2s.VerifyAddonIsDisabled("rollout", "argocd")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollout")

			suite.Cluster().ExpectStatefulSetToBeDeleted("argocd-application-controller", "rollout", ctx)

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-redis", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-server", "rollout")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "argocd", "-o")

			k2s.VerifyAddonIsEnabled("rollout", "argocd")

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", "rollout")

			suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", "rollout", 1, ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", "rollout")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-application-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-redis", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-server", "rollout")
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "rollout", "argocd")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through k2s.cluster.local/rollout", func(ctx context.Context) {
			url := "https://k2s.cluster.local/rollout/"
			suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-o", "NUL", "-m", "5", "--retry", "3", "--fail", "--retry-all-errors")
		})
	})

	When("FluxCD is already enabled", func() {
		BeforeEach(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "fluxcd", "-o")

			DeferCleanup(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "fluxcd", "-o")
			})
		})

		It("prevents enabling ArgoCD", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "rollout", "argocd")

			Expect(output).To(ContainSubstring("Addon 'rollout fluxcd' is enabled"))
		})
	})
})

func expectListToDisplayImplementation(ctx context.Context) {
	output := suite.K2sCli().MustExec(ctx, "addons", "ls")
	Expect(output).To(MatchRegexp(`(?s)Enabled.*rollout.*argocd`))

	jsonOutput := suite.K2sCli().MustExec(ctx, "addons", "ls", "-o", "json")

	type implEntry struct {
		Name string `json:"name"`
	}
	type addonEntry struct {
		Name            string      `json:"name"`
		Implementations []implEntry `json:"implementations"`
	}
	type listResult struct {
		EnabledAddons  []addonEntry `json:"enabledAddons"`
		DisabledAddons []addonEntry `json:"disabledAddons"`
	}

	var result listResult
	Expect(json.Unmarshal([]byte(jsonOutput), &result)).To(Succeed())

	Expect(result.EnabledAddons).To(ContainElement(
		SatisfyAll(
			HaveField("Name", "rollout"),
			HaveField("Implementations", ContainElement(HaveField("Name", "argocd"))),
		),
	))
	Expect(result.DisabledAddons).ToNot(ContainElement(
		SatisfyAll(
			HaveField("Name", "rollout"),
			HaveField("Implementations", ContainElement(HaveField("Name", "argocd"))),
		),
	))
}

func expectStatusToBePrinted(ctx context.Context) {
	Eventually(func() string {
		return suite.K2sCli().MustExec(ctx, "addons", "status", "rollout", "argocd")
	}).WithTimeout(statusCheckRetryTimeout).WithPolling(statusCheckRetryPolling).Should(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Implementation .+argocd.+ of Addon .+rollout.+ is .+enabled.+`),
		MatchRegexp("ArgoCD Application Set Controller is working"),
		MatchRegexp("ArgoCD Dex Server is working"),
		MatchRegexp("ArgoCD Notification Controller is working"),
		MatchRegexp("ArgoCD Redis DB is working"),
		MatchRegexp("ArgoCD Repo Server is working"),
		MatchRegexp("ArgoCD Server is working"),
		MatchRegexp("ArgoCD Application Server is working"),
	))

	Eventually(func(g Gomega) {
		output := suite.K2sCli().MustExec(ctx, "addons", "status", "rollout", "argocd", "-o", "json")

		var status status.AddonPrintStatus

		g.Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

		g.Expect(status.Name).To(Equal("rollout"))
		g.Expect(status.Implementation).To(Equal("argocd"))
		g.Expect(status.Error).To(BeNil())
		g.Expect(status.Enabled).NotTo(BeNil())
		g.Expect(*status.Enabled).To(BeTrue())
		g.Expect(status.Props).NotTo(BeNil())
		g.Expect(status.Props).To(ContainElements(
			SatisfyAll(
				HaveField("Name", "IsArgoCDApplicationsetControllerRunning"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(ContainSubstring("ArgoCD Application Set Controller is working")))),
			SatisfyAll(
				HaveField("Name", "IsArgoCDDexServerRunning"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("ArgoCD Dex Server is working")))),
			SatisfyAll(
				HaveField("Name", "IsArgoCDNotificationControllerRunning"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("ArgoCD Notification Controller is working")))),
			SatisfyAll(
				HaveField("Name", "IsArgoCDRedisRunning"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("ArgoCD Redis DB is working")))),
			SatisfyAll(
				HaveField("Name", "IsArgoCDRepoServerRunning"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("ArgoCD Repo Server is working")))),
			SatisfyAll(
				HaveField("Name", "IsArgoCDServerRunning"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("ArgoCD Server is working")))),
			SatisfyAll(
				HaveField("Name", "AreStatefulsetsRunning"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("ArgoCD Application Server is working")))),
		))
	}).WithTimeout(statusCheckRetryTimeout).WithPolling(statusCheckRetryPolling).Should(Succeed())
}
