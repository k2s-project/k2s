// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package traefiksecurity

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
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
)

func TestTraefikSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Ingress-traefik and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-2", "acceptance", "setup-required", "invasive", "ingress-traefik", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up ingress-traefik security test")
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up ingress-traefik security test")
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}
	if suite.ShouldCleanup(testFailed) {
		suite.SetupInfo().ReloadRuntimeConfig()
		suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\..\\traefik\\workloads", "--ignore-not-found")

		if k2s.IsAddonEnabled("ingress", "traefik") {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")
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

var _ = Describe("'ingress-traefik and security enhanced' addon", Ordered, func() {
	Describe("Security addon activated first then traefik addon", func() {
		It("activates the enhanced security addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("enables the traefik addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling traefik addon")
			// nginx is enabled by security addon, so we need to disable it first.
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "ingress-traefik")
			GinkgoWriter.Println(">>> TEST: Traefik addon enabled and verified with linkerd injection")
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

		It("tests connectivity to albums-linux using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Applying sample workloads and testing connectivity")
			// Apply sample workloads if necessary.
			suite.Kubectl().MustExec(ctx, "apply", "-k", "..\\..\\traefik\\workloads")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-traefik-test")

			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/albums-linux1"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Albums connectivity verified")
		})

		It("creates traefik split ingress for keycloak and oauth2-proxy with middleware, no service-not-found or redundant TLS-secret errors", func(ctx context.Context) {
			// Scenario A: both backends present -> both Ingresses + oauth2 middleware are created.
			kc := suite.Kubectl().MustExec(ctx, "get", "ingress", "keycloak", "-n", "security", "--ignore-not-found")
			Expect(kc).To(ContainSubstring("keycloak"))
			o2p := suite.Kubectl().MustExec(ctx, "get", "ingress", "oauth2-proxy", "-n", "security", "--ignore-not-found")
			Expect(o2p).To(ContainSubstring("oauth2-proxy"))
			mw := suite.Kubectl().MustExec(ctx, "get", "middleware", "oauth2-proxy-forwarder-signin", "-n", "security", "--ignore-not-found")
			Expect(mw).To(ContainSubstring("oauth2-proxy-forwarder-signin"))
			// MustExec (asserts kubectl exit code 0) instead of Exec(..., _): if traefik log
			// retrieval fails, an empty result would make the negative assertions below pass
			// vacuously, hiding a real error.
			// --since is set well above the suite step timeout (20m) so the whole traefik log
			// history is captured: this suite disables all addons in BeforeSuite, so the traefik
			// pod is created fresh when the ingress-traefik addon is enabled and kubectl logs
			// (no --previous) only returns this run's logs. A fixed --tail could otherwise rotate
			// the relevant lines out on a busy proxy and mask a real error.
			logs := suite.Kubectl().MustExec(ctx, "logs", "-n", "ingress-traefik", "deploy/traefik", "--since=1h")
			Expect(logs).NotTo(ContainSubstring("service not found"))
			// Regression guard for the removed spec.tls blocks: the Traefik keycloak/oauth2-proxy
			// ingresses no longer declare tls referencing security/k2s-cluster-local-tls (a secret
			// that only ever exists in the ingress-traefik namespace). Traefik must therefore no
			// longer log the failed secret lookup. If the blocks were reintroduced Traefik would
			// re-emit this error on every reconcile, so the full-history window reliably catches a
			// regression. The trusted certificate for k2s.cluster.local is owned and served by the
			// central ingress-traefik/traefik-cluster-local ingress.
			Expect(logs).NotTo(ContainSubstring("secret security/k2s-cluster-local-tls does not exist"))
		})

		It("serves keycloak and oauth2-proxy over HTTPS with the trusted k2s.cluster.local certificate", func(ctx context.Context) {
			// The HTTP client used here trusts ONLY the K2s self-signed CA (loaded from the
			// cluster secret, see addons.VerifyDeploymentReachableFromHostWithStatusCode). A
			// successful HTTPS response therefore proves that the central ingress' trusted
			// certificate is served for the security routes even though the keycloak/oauth2-proxy
			// ingresses no longer declare a spec.tls block. Redirects are followed, so the
			// oauth2 sign-in endpoint resolves to the Keycloak login page (200).
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, "https://k2s.cluster.local/keycloak/realms/demo-app")
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, "https://k2s.cluster.local/oauth2/start?rd=%2F")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\..\\traefik\\workloads")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})

		It("removes all traefik split security ingress resources on disable", func(ctx context.Context) {
			// MustExec asserts kubectl exited 0. With --ignore-not-found kubectl returns an
			// empty body and exit code 0 when the resource is gone, so BeEmpty() still holds
			// for the "removed" case while a genuine API/connection failure now fails the test
			// instead of masquerading as an empty (== removed) result.
			kc := suite.Kubectl().MustExec(ctx, "get", "ingress", "keycloak", "-n", "security", "--ignore-not-found")
			Expect(kc).To(BeEmpty())
			o2p := suite.Kubectl().MustExec(ctx, "get", "ingress", "oauth2-proxy", "-n", "security", "--ignore-not-found")
			Expect(o2p).To(BeEmpty())
			mw := suite.Kubectl().MustExec(ctx, "get", "middleware", "oauth2-proxy-forwarder-signin", "-n", "security", "--ignore-not-found")
			Expect(mw).To(BeEmpty())
		})

		It("retains cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(err).To(BeNil())
		})

		It("removed the ca-issuer-root-secret", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-A")
			Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"))
		})
	})

	Describe("traefik addon activated first then security addon", func() {
		It("enables the traefik addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling traefik addon first")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
			GinkgoWriter.Println(">>> TEST: Traefik addon enabled")
		})

		It("activates the enhanced security addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "ingress-traefik")
			GinkgoWriter.Println(">>> TEST: Security addon enabled and linkerd injection verified")
		})

		It("tests connectivity to albums-linux using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Applying sample workloads and testing connectivity")
			// Apply sample workloads if necessary.
			suite.Kubectl().MustExec(ctx, "apply", "-k", "..\\..\\traefik\\workloads")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-traefik-test")

			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/albums-linux1"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Albums connectivity verified")
		})

		It("emits no redundant TLS-secret error and serves keycloak/oauth2 over HTTPS regardless of activation order", func(ctx context.Context) {
			// Same regression guard as the "security first" scenario, verified for the reverse
			// activation order (traefik enabled first, then security). Removing the spec.tls
			// blocks must not cause Traefik to log the failed security/k2s-cluster-local-tls
			// lookup, and the central ingress' trusted certificate must still be served.
			// --since spans the full traefik log history (the pod is created fresh in this suite),
			// so a regressed error - which would recur on every reconcile - cannot rotate out.
			logs := suite.Kubectl().MustExec(ctx, "logs", "-n", "ingress-traefik", "deploy/traefik", "--since=1h")
			Expect(logs).NotTo(ContainSubstring("secret security/k2s-cluster-local-tls does not exist"))
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, "https://k2s.cluster.local/keycloak/realms/demo-app")
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, "https://k2s.cluster.local/oauth2/start?rd=%2F")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\..\\traefik\\workloads")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
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
