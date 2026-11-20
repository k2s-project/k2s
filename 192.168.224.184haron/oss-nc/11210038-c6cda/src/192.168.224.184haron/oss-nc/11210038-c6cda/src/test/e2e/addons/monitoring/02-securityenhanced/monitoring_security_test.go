// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package monitoringsecurity

import (
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"
	"github.com/k2s-project/k2s/test/framework/k2s/addons"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 20

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
)

func TestMonitoringSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Monitoring and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-3", "acceptance", "setup-required", "invasive", "monitoring", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up monitoring security test")
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up monitoring security test")

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}
	suite.TearDown(ctx)
	GinkgoWriter.Println(">>> TEST: AfterSuite complete")
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("'monitoring and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then monitoring addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling monitoring addon")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "-o")

			k2s.VerifyAddonIsEnabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-grafana", "monitoring")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "grafana", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "monitoring")
			GinkgoWriter.Println(">>> TEST: Monitoring addon enabled and verified with linkerd injection")
		})

		It("tests connectivity to the monitoring server using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to monitoring server")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/monitoring/login"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Monitoring server connectivity verified")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})

	// NOTE: "Monitoring first → Security" enable-order with nginx (implicit) was removed.
	// The retrofit Linkerd injection path is already covered by
	// "Monitoring addon with nginx-gw activated first then security addon" below.
	// The injection logic in Update.ps1 is ingress-agnostic, so testing it
	// once (with nginx-gw) is sufficient. This saves ~16 min per run.

	Describe("Security addon activated first then monitoring addon with nginx-gw ingress", func() {
		It("activates the ingress addon with nginx-gw", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling ingress addon with nginx-gw")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx-gw", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("nginx-gw-controller", "nginx-gw")
			GinkgoWriter.Println(">>> TEST: Ingress nginx-gw addon enabled")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling monitoring addon with nginx-gw ingress")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "--ingress", "nginx-gw", "-o")

			k2s.VerifyAddonIsEnabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-grafana", "monitoring")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "grafana", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "monitoring")
			GinkgoWriter.Println(">>> TEST: Monitoring addon enabled and verified with linkerd injection")
		})

		It("tests connectivity to the monitoring server using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to monitoring server via nginx-gw")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/monitoring/login"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Monitoring server connectivity verified via nginx-gw")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})

	Describe("Monitoring addon with nginx-gw activated first then security addon", func() {
		It("activates the ingress addon with nginx-gw", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling ingress addon with nginx-gw")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx-gw", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("nginx-gw-controller", "nginx-gw")
			GinkgoWriter.Println(">>> TEST: Ingress nginx-gw addon enabled")
		})

		It("activates the monitoring addon with nginx-gw ingress", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling monitoring addon with nginx-gw first")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "--ingress", "nginx-gw", "-o")
			GinkgoWriter.Println(">>> TEST: Monitoring addon enabled")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying monitoring addon state")
			k2s.VerifyAddonIsEnabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-grafana", "monitoring")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "grafana", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "monitoring")
			GinkgoWriter.Println(">>> TEST: Monitoring addon verified with linkerd injection")
		})

		It("tests connectivity to the monitoring server using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to monitoring server via nginx-gw")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/monitoring/login"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Monitoring server connectivity verified via nginx-gw")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})
})
