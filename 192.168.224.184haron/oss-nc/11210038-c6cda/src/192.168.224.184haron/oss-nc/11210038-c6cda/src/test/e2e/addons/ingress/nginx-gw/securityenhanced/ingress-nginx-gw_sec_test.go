// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package ingressnginxgw_sec

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path"
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
	suite *framework.K2sTestSuite
	k2s   *dsl.K2s
)

func TestIngressNginxGwSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Ingress-nginx-gw and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-2", "acceptance", "setup-required", "invasive", "ingress-nginx-gw", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up ingress-nginx-gw security test")
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up ingress-nginx-gw security test")
	suite.SetupInfo().ReloadRuntimeConfig()
	if k2s.IsAddonEnabled("ingress", "nginx-gw") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
	}

	if k2s.IsAddonEnabled("security") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
	}

	suite.TearDown(ctx)
	GinkgoWriter.Println(">>> TEST: AfterSuite complete")
})

var _ = Describe("'ingress-nginx-gw and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then ingress-nginx-gw addon", func() {
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
			GinkgoWriter.Println(">>> TEST: Ingress-nginx verified with linkerd injection")
		})

		It("installs cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying cmctl.exe installation")
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(err).To(BeNil())
			GinkgoWriter.Println(">>> TEST: cmctl.exe installation verified")
		})

		It("creates the ca-issuer-root-secret", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying ca-issuer-root-secret creation")
			output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
			Expect(output).To(ContainSubstring("ca-issuer-root-secret"))
			GinkgoWriter.Println(">>> TEST: ca-issuer-root-secret creation verified")
		})

		It("applies sample workloads", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Applying sample workloads")
			suite.Kubectl().MustExec(ctx, "apply", "-k", "..\\..\\nginx-gw\\workloads")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-nginx-gw-test")
			GinkgoWriter.Println(">>> TEST: Sample workloads applied")
		})

		It("tests connectivity to the albums using the bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to albums")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/albums-linux1"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Albums connectivity verified")
		})

		It("creates nginx-gw HTTPRoutes for keycloak and oauth2-proxy plus shared ReferenceGrant", func(ctx context.Context) {
			// Scenario A: both backends present -> both HTTPRoutes + shared ReferenceGrant created.
			kc := suite.Kubectl().MustExec(ctx, "get", "httproute", "keycloak-nginx-gw-cluster-local", "-n", "security", "--ignore-not-found")
			Expect(kc).To(ContainSubstring("keycloak-nginx-gw-cluster-local"))
			o2p := suite.Kubectl().MustExec(ctx, "get", "httproute", "oauth2-proxy-nginx-gw-cluster-local", "-n", "security", "--ignore-not-found")
			Expect(o2p).To(ContainSubstring("oauth2-proxy-nginx-gw-cluster-local"))
			rg := suite.Kubectl().MustExec(ctx, "get", "referencegrant", "security-to-nginx-gw", "-n", "nginx-gw", "--ignore-not-found")
			Expect(rg).To(ContainSubstring("security-to-nginx-gw"))

			// Scenario A also creates the Linkerd Server / ServerAuthorization policies and the
			// shared SnippetsFilter (Gateway API / enhanced-mode flavour only).
			kcAuth := suite.Kubectl().MustExec(ctx, "get", "serverauthorization", "keycloak-allow-all", "-n", "security", "--ignore-not-found")
			Expect(kcAuth).To(ContainSubstring("keycloak-allow-all"))
			o2pAuth := suite.Kubectl().MustExec(ctx, "get", "serverauthorization", "oauth2-proxy-allow-all", "-n", "security", "--ignore-not-found")
			Expect(o2pAuth).To(ContainSubstring("oauth2-proxy-allow-all"))
			snip := suite.Kubectl().MustExec(ctx, "get", "snippetsfilter", "oauth2-shared-locations", "-n", "security", "--ignore-not-found")
			Expect(snip).To(ContainSubstring("oauth2-shared-locations"))

			// nginx-gw mode must NOT create the Traefik-specific Ingress/Middleware resources.
			traefikIngress, _ := suite.Kubectl().Exec(ctx, "get", "ingress", "oauth2-proxy", "-n", "security", "--ignore-not-found")
			Expect(traefikIngress).To(BeEmpty())
			traefikMw, _ := suite.Kubectl().Exec(ctx, "get", "middleware", "oauth2-proxy-forwarder-signin", "-n", "security", "--ignore-not-found")
			Expect(traefikMw).To(BeEmpty())
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\workloads")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})

		It("removes nginx-gw split security ingress resources on disable", func(ctx context.Context) {
			kc, _ := suite.Kubectl().Exec(ctx, "get", "httproute", "keycloak-nginx-gw-cluster-local", "-n", "security", "--ignore-not-found")
			Expect(kc).To(BeEmpty())
			o2p, _ := suite.Kubectl().Exec(ctx, "get", "httproute", "oauth2-proxy-nginx-gw-cluster-local", "-n", "security", "--ignore-not-found")
			Expect(o2p).To(BeEmpty())
			rg, _ := suite.Kubectl().Exec(ctx, "get", "referencegrant", "security-to-nginx-gw", "-n", "nginx-gw", "--ignore-not-found")
			Expect(rg).To(BeEmpty())
			snip, _ := suite.Kubectl().Exec(ctx, "get", "snippetsfilter", "oauth2-shared-locations", "-n", "security", "--ignore-not-found")
			Expect(snip).To(BeEmpty())
		})

		It("retains cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying cmctl.exe is retained")
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(err).To(BeNil())
			GinkgoWriter.Println(">>> TEST: cmctl.exe retention verified")
		})

		It("removed the ca-issuer-root-secret", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying ca-issuer-root-secret removal")
			output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-A")
			Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"))
			GinkgoWriter.Println(">>> TEST: ca-issuer-root-secret removal verified")
		})
	})
})
