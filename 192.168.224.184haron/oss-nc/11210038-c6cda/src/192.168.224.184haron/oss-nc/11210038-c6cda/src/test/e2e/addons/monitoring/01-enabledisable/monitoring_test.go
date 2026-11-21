// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package monitoringenabdisable

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

var (
	suite                 *framework.K2sTestSuite
	portForwardingSession *gexec.Session
	k2s                   *dsl.K2s
	testFailed            = false
)

func TestMonitoring(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "monitoring Addon Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "monitoring", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
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

var _ = Describe("'monitoring' addon", Ordered, func() {
	When("--omitGrafana flag is used", func() {
		AfterAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")

			k2s.VerifyAddonIsDisabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
		})

		It("deploys Prometheus stack without Grafana", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "--omitGrafana", "-o")

			k2s.VerifyAddonIsEnabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
		})

		It("does not deploy Grafana deployment", func(ctx context.Context) {
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "grafana", "monitoring")
		})

		It("prints the status without Grafana", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", "monitoring")

			Expect(output).To(SatisfyAll(
				MatchRegexp("ADDON STATUS"),
				MatchRegexp(`Addon .+monitoring.+ is .+enabled.+`),
				MatchRegexp("The Kube State Metrics Deployment is working"),
				MatchRegexp("The Prometheus Operator is working"),
				MatchRegexp("Prometheus and Alertmanager are working"),
				MatchRegexp("Node Exporter is working"),
				MatchRegexp("Grafana was omitted during installation"),
			))
		})
	})

	When("no ingress controller is configured", func() {
		AfterAll(func(ctx context.Context) {
			if portForwardingSession != nil {
				portForwardingSession.Kill()
			}
			// NOTE: monitoring stays enabled for the ingress tests that follow
		})

		It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", "monitoring")

			Expect(output).To(ContainSubstring("already disabled"))
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "-o")

			k2s.VerifyAddonIsEnabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-grafana", "monitoring")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "grafana", "monitoring")
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "monitoring")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through port forwarding", func(ctx context.Context) {
			kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
			portForwarding := exec.Command(kubectl, "-n", "monitoring", "port-forward", "svc/kube-prometheus-stack-grafana", "3000:80")
			portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

			url := "http://localhost:3000/monitoring/login"
			suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-o", "NUL", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
		})
	})

	// Monitoring is already enabled from the previous group.
	// Each ingress test: enable ingress → verify reachability → disable ingress.
	// This avoids redundant monitoring enable/disable cycles per ingress type.
	When("ingress controllers are configured", func() {
		AfterAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")

			k2s.VerifyAddonIsDisabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "grafana", "monitoring")
		})

		It("is reachable through traefik ingress", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")

			url := "https://k2s.cluster.local/monitoring/login"
			suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-o", "NUL", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")

			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
		})

		It("is reachable through nginx ingress", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")

			url := "https://k2s.cluster.local/monitoring/login"
			suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-o", "NUL", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")

			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
		})

		It("is reachable through nginx-gw ingress", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx-gw", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("nginx-gw-controller", "nginx-gw")

			url := "https://k2s.cluster.local/monitoring/login"
			httpStatus := suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-I", "-m", "5", "--retry", "10", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))

			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "nginx-gw-controller", "nginx-gw")
		})
	})
})

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().MustExec(ctx, "addons", "status", "monitoring")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Addon .+monitoring.+ is .+enabled.+`),
		MatchRegexp("The Kube State Metrics Deployment is working"),
		MatchRegexp("The Prometheus Operator is working"),
		MatchRegexp("The Grafana Dashboard is working"),
		MatchRegexp("Prometheus and Alertmanager are working"),
		MatchRegexp("Node Exporter is working"),
	))

	output = suite.K2sCli().MustExec(ctx, "addons", "status", "monitoring", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("monitoring"))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
	Expect(status.Props).NotTo(BeNil())
	Expect(status.Props).To(ContainElements(
		SatisfyAll(
			HaveField("Name", "IsKubeStateMetricsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("The Kube State Metrics Deployment is working")))),
		SatisfyAll(
			HaveField("Name", "IsPrometheusOperatorRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("The Prometheus Operator is working")))),
		SatisfyAll(
			HaveField("Name", "IsGrafanaRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("The Grafana Dashboard is working")))),
		SatisfyAll(
			HaveField("Name", "AreStatefulsetsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("Prometheus and Alertmanager are working")))),
		SatisfyAll(
			HaveField("Name", "AreDaemonsetsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("Node Exporter is working")))),
	))
}
