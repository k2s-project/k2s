// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package dicomsecurity

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

func TestDicomSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "DICOM and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-1", "acceptance", "setup-required", "invasive", "dicom", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up DICOM security test")
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up DICOM security test")
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}
	if suite.ShouldCleanup(testFailed) {

		suite.SetupInfo().ReloadRuntimeConfig()
		suite.K2sCli().MustExec(ctx, "addons", "disable", "dicom", "-o", "-f")
		if k2s.IsAddonEnabled("security") {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
		}
		if k2s.IsAddonEnabled("ingress", "nginx") {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
		}
		if k2s.IsAddonEnabled("ingress", "nginx-gw") {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
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

var _ = Describe("'dicom and security enhanced' addons", Ordered, func() {
	Describe("Security addon activated first then dicom addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)

			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("activates the dicom addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling DICOM addon")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "dicom", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
			suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "dicom")
			GinkgoWriter.Println(">>> TEST: DICOM addon enabled and verified with linkerd injection")
		})

		It("tests connectivity to the dicom server using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to DICOM server")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/dicom/ui/app"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: DICOM server connectivity verified")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "dicom", "-o", "-f")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})

	Describe("Dicom addon activated first then security addon", func() {
		It("activates the dicom addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling DICOM addon first")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "dicom", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
			suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")
			GinkgoWriter.Println(">>> TEST: DICOM addon enabled")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "dicom")
			GinkgoWriter.Println(">>> TEST: Security addon enabled and linkerd injection verified")
		})

		It("tests connectivity to the dicom server using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to DICOM server")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/dicom/ui/app"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: DICOM server connectivity verified")
		})
		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "dicom", "-o", "-f")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})

	Describe("DICOM addon with nginx-gw and security enhanced", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)

			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("disables the nginx addon enabled by security", func(ctx context.Context) {
			// nginx is enabled by security addon, so we need to disable it first to avoid port conflicts.
			GinkgoWriter.Println(">>> TEST: Disabling default ingress-nginx addon")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			GinkgoWriter.Println(">>> TEST: Disabled default ingress-nginx addon")
		})

		It("activates the ingress-nginx-gw addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling ingress-nginx-gw addon")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx-gw", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("nginx-gw-controller", "nginx-gw")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "nginx-gw", "nginx-gw")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "nginx-gw")
			GinkgoWriter.Println(">>> TEST: Ingress-nginx-gw verified with linkerd injection")
		})

		It("activates the dicom addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling DICOM addon")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "dicom", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
			suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "dicom")
			GinkgoWriter.Println(">>> TEST: DICOM addon enabled and verified with linkerd injection")
		})

		It("tests connectivity to the dicom server using bearer token via nginx-gw", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to DICOM server via nginx-gw")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/dicom/ui/app"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: DICOM server connectivity via nginx-gw verified")
		})

		It("tests connectivity to the dicom-web API using bearer token via nginx-gw", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to DICOM-Web API via nginx-gw")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/dicom/studies"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: DICOM-Web API connectivity via nginx-gw verified")
		})
	})
})
