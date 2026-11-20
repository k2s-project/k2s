// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package viewersecurity

import (
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/k2s/addons"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 30

var (
	suite      *framework.K2sTestSuite
	testFailed = false
)

func TestViewerSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Viewer and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-3", "acceptance", "setup-required", "invasive", "viewer", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up viewer security test")
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up viewer security test")

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	if suite.ShouldCleanup(testFailed) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "viewer", "-o")
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
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

var _ = Describe("'Viewer and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then viewer addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("activates the viewer addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling viewer addon")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "viewer")
			GinkgoWriter.Println(">>> TEST: Viewer addon enabled and verified with linkerd injection")
		})

		It("tests connectivity to the viewer server using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to viewer server")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/viewer/"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Viewer server connectivity verified")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "viewer", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})

	Describe("Viewer addon activated first then security addon", func() {
		It("activates the viewer addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling viewer addon first")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "-o")
			suite.Cluster().WaitForAPIServerReady(ctx)
			suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")
			GinkgoWriter.Println(">>> TEST: Viewer addon enabled")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "viewer")
			GinkgoWriter.Println(">>> TEST: Security addon enabled and linkerd injection verified")
		})

		It("tests connectivity to the viewer server using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to viewer server")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/viewer/"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Viewer server connectivity verified")
		})
	})
})
