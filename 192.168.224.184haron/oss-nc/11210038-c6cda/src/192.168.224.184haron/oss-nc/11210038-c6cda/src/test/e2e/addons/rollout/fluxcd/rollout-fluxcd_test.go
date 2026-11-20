// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package rolloutfluxcd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 20

var (
	suite      *framework.K2sTestSuite
	linuxOnly  = false
	k2s        *dsl.K2s
	testFailed = false
)

func TestRolloutFluxCD(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "rollout fluxcd Addon Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "rollout-fluxcd", "system-running"))
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

var _ = Describe("'rollout fluxcd' addon", Ordered, func() {
	When("no ingress controller is configured", func() {
		AfterAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "fluxcd", "-o")

			k2s.VerifyAddonIsDisabled("rollout", "fluxcd")
			expectFluxCliToExist()

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/part-of", "flux", "rollout")
		})

		It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", "rollout", "fluxcd")

			Expect(output).To(ContainSubstring("already disabled"))
		})

		Describe("status", func() {
			Context("default output", func() {
				It("displays disabled message", func(ctx context.Context) {
					output := suite.K2sCli().MustExec(ctx, "addons", "status", "rollout", "fluxcd")

					Expect(output).To(SatisfyAll(
						MatchRegexp(`ADDON STATUS`),
						MatchRegexp(`Implementation .+fluxcd.+ of Addon .+rollout.+ is .+disabled.+`),
					))
				})
			})

			Context("JSON output", func() {
				It("displays JSON", func(ctx context.Context) {
					output := suite.K2sCli().MustExec(ctx, "addons", "status", "rollout", "fluxcd", "-o", "json")

					var status status.AddonPrintStatus

					Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

					Expect(status.Name).To(Equal("rollout"))
					Expect(status.Implementation).To(Equal("fluxcd"))
					Expect(status.Enabled).NotTo(BeNil())
					Expect(*status.Enabled).To(BeFalse())
					Expect(status.Props).To(BeNil())
					Expect(status.Error).To(BeNil())
				})
			})
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "fluxcd", "-o")

			k2s.VerifyAddonIsEnabled("rollout", "fluxcd")
			expectFluxCliToExist()
			expectFluxCliToBeRunnable(ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("source-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("kustomize-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("helm-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("notification-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("image-reflector-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("image-automation-controller", "rollout")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "source-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "kustomize-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "helm-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "notification-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "image-reflector-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "image-automation-controller", "rollout")
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "rollout", "fluxcd")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})
	})

	When("ingress nginx as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "fluxcd", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")

			k2s.VerifyAddonIsDisabled("rollout", "fluxcd")
			expectFluxCliToExist()

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/part-of", "flux", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "fluxcd", "--ingress", "nginx", "-o")

			k2s.VerifyAddonIsEnabled("rollout", "fluxcd")
			expectFluxCliToExist()
			expectFluxCliToBeRunnable(ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("source-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("kustomize-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("helm-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("notification-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("image-reflector-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("image-automation-controller", "rollout")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "source-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "kustomize-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "helm-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "notification-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "image-reflector-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "image-automation-controller", "rollout")
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "rollout", "fluxcd")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("webhook receiver is accessible through ingress", func(ctx context.Context) {
			svcOutput := suite.Kubectl().MustExec(ctx, "get", "svc", "-n", "rollout", "webhook-receiver", "-o", "jsonpath={.metadata.name}")
			Expect(svcOutput).To(Equal("webhook-receiver"))

			ingressOutput := suite.Kubectl().MustExec(ctx, "get", "ingress", "-n", "rollout", "-o", "jsonpath={.items[?(@.spec.ingressClassName=='nginx')].metadata.name}")
			Expect(ingressOutput).To(ContainSubstring("rollout-nginx-cluster-local"))

			url := "http://k2s.cluster.local/hook/"

			Eventually(func(ctx context.Context) bool {
				output, _ := suite.Cli("curl.exe").Exec(ctx, url, "-i", "-m", "5", "-s")

				if output != "" {
					GinkgoWriter.Printf("Received response: %s\n", output)
				}

				return output != "" && (strings.Contains(output, "HTTP/") ||
					strings.Contains(output, "404") ||
					strings.Contains(output, "405") ||
					strings.Contains(output, "200"))
			}, "30s", "2s", ctx).Should(BeTrue())
		})
	})

	When("ingress traefik as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "fluxcd", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")

			k2s.VerifyAddonIsDisabled("rollout", "fluxcd")
			expectFluxCliToExist()

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/part-of", "flux", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "fluxcd", "--ingress", "traefik", "-o")

			k2s.VerifyAddonIsEnabled("rollout", "fluxcd")
			expectFluxCliToExist()
			expectFluxCliToBeRunnable(ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("source-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("kustomize-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("helm-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("notification-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("image-reflector-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("image-automation-controller", "rollout")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "source-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "kustomize-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "helm-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "notification-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "image-reflector-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "image-automation-controller", "rollout")
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "rollout", "fluxcd")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("webhook receiver is accessible through ingress", func(ctx context.Context) {
			svcOutput := suite.Kubectl().MustExec(ctx, "get", "svc", "-n", "rollout", "webhook-receiver", "-o", "jsonpath={.metadata.name}")
			Expect(svcOutput).To(Equal("webhook-receiver"))

			ingressOutput := suite.Kubectl().MustExec(ctx, "get", "ingress", "-n", "rollout", "-o", "jsonpath={.items[?(@.spec.ingressClassName=='traefik')].metadata.name}")
			Expect(ingressOutput).To(ContainSubstring("rollout-traefik-cluster-local"))

			url := "http://k2s.cluster.local/hook/"

			Eventually(func(ctx context.Context) bool {
				output, _ := suite.Cli("curl.exe").Exec(ctx, url, "-i", "-m", "5", "-s")

				if output != "" {
					GinkgoWriter.Printf("Received response: %s\n", output)
				}

				return output != "" && (strings.Contains(output, "HTTP/") ||
					strings.Contains(output, "404") ||
					strings.Contains(output, "405") ||
					strings.Contains(output, "200"))
			}, "30s", "2s", ctx).Should(BeTrue())
		})
	})

	When("ArgoCD is already enabled", func() {
		BeforeEach(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "argocd", "-o")

			DeferCleanup(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "argocd", "-o")
			})
		})

		It("prevents enabling FluxCD", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "rollout", "fluxcd")

			Expect(output).To(ContainSubstring("Addon 'rollout argocd' is enabled"))
		})
	})
})

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().MustExec(ctx, "addons", "status", "rollout", "fluxcd")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Implementation .+fluxcd.+ of Addon .+rollout.+ is .+enabled.+`),
		MatchRegexp("Flux Source Controller is working"),
		MatchRegexp("Flux Kustomize Controller is working"),
		MatchRegexp("Flux Helm Controller is working"),
		MatchRegexp("Flux Notification Controller is working"),
	))

	output = suite.K2sCli().MustExec(ctx, "addons", "status", "rollout", "fluxcd", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("rollout"))
	Expect(status.Implementation).To(Equal("fluxcd"))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
}

func fluxCliPath() string {
	return filepath.Join(suite.RootDir(), "bin", "flux.exe")
}

func expectFluxCliToExist() {
	Eventually(func() bool {
		_, err := os.Stat(fluxCliPath())
		return err == nil
	}, "30s", "1s").Should(BeTrue(), "flux CLI should exist at %s", fluxCliPath())
}

func expectFluxCliToBeRunnable(ctx context.Context) {
	output := suite.Cli(fluxCliPath()).MustExec(ctx, "version", "--client")

	Expect(output).To(ContainSubstring("flux:"), "flux CLI should report its version")
}
