// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package loggingsecurity

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

const testClusterTimeout = time.Minute * 30

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
)

func TestLoggingSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Logging and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-2", "acceptance", "setup-required", "invasive", "logging", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up logging security test")
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up logging security test")
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	if suite.ShouldCleanup(testFailed) {
		suite.SetupInfo().ReloadRuntimeConfig()

		if k2s.IsAddonEnabled("logging") {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "logging", "-o")
		}

		if k2s.IsAddonEnabled("ingress", "nginx") {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
		}

		if k2s.IsAddonEnabled("ingress", "nginx-gw") {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
		}

		if k2s.IsAddonEnabled("security") {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
		}
	}

	suite.TearDown(ctx)
	GinkgoWriter.Println(">>> TEST: AfterSuite complete")
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("'logging and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then logging addon with nginx ingress", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("activates the logging addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling logging addon")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "logging", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("opensearch-dashboards", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "logging")
			GinkgoWriter.Println(">>> TEST: Logging addon enabled and verified with linkerd injection")
		})

		It("tests connectivity to the logging server using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to logging server")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/logging"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Logging server connectivity verified")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "logging", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})

	Describe("Logging addon activated first then security addon with nginx-gw ingress", func() {
		It("activates the logging addon with nginx-gw", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling logging addon first with nginx-gw")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "logging", "--ingress", "nginx-gw", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("opensearch-dashboards", "logging")
			suite.Cluster().ExpectDeploymentToBeAvailable("nginx-cluster-local-nginx-gw", "nginx-gw")
			GinkgoWriter.Println(">>> TEST: Logging addon enabled with nginx-gw")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			suite.Cluster().ExpectDeploymentToBeAvailable("nginx-cluster-local-nginx-gw", "nginx-gw")
			suite.Cluster().ExpectDeploymentToBeAvailable("opensearch-dashboards", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "logging")
			GinkgoWriter.Println(">>> TEST: Security addon enabled and linkerd injection verified")
		})

		It("tests connectivity to the logging server using bearer token with nginx-gw", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to logging server via nginx-gw")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/logging"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Logging server connectivity verified via nginx-gw")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "logging", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})
})
