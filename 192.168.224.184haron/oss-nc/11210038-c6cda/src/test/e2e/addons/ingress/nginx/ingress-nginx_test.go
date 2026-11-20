// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package ingressnginx

import (
	"context"
	"encoding/json"
	"os"
	"path"
	"testing"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	"github.com/k2s-project/k2s/test/framework"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework/dsl"
	"github.com/k2s-project/k2s/test/framework/regex"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

const testClusterTimeout = time.Minute * 10

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
)

func TestIngressNginx(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ingress nginx Addon Acceptance Tests", Label("addon", "addon-communication", "acceptance", "setup-required", "invasive", "ingress-nginx", "system-running"))
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

var _ = Describe("'ingress-nginx' addon", Ordered, func() {
	AfterAll(func(ctx context.Context) {
		suite.Kubectl().MustExec(ctx, "delete", "-k", "workloads")
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
		k2s.VerifyAddonIsDisabled("ingress", "nginx")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "albums-linux1", "ingress-nginx-test")
	})

	It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", "ingress", "nginx")

		Expect(output).To(ContainSubstring("already disabled"))
	})

	It("is in enabled state and pods are in running state", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")

		k2s.VerifyAddonIsEnabled("ingress", "nginx")

		suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
		if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
			suite.Cluster().ExpectDeploymentToBeAvailable("external-dns", "kube-system")
		}

		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
		if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "external-dns", "kube-system")
		}
	})

	It("installs cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
		if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
			Skip("cmctl.exe is a Windows-only binary")
		}
		cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(err).To(BeNil())
	})

	It("creates the ca-issuer-root-secret", func(ctx context.Context) {
		output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
		Expect(output).To(ContainSubstring("ca-issuer-root-secret"))
	})

	It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "ingress", "nginx")

		Expect(output).To(ContainSubstring("already enabled"))
	})

	It("makes k2s.cluster.local reachable, with http status NotFound", func(ctx context.Context) {
		url := "https://k2s.cluster.local/"
		httpStatus := suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-I", "-m", "5", "--retry", "10", "--retry-all-errors")
		Expect(httpStatus).To(ContainSubstring("404"))
	})

	It("sample app is reachable through nginx ingress controller", func(ctx context.Context) {
		suite.Kubectl().MustExec(ctx, "apply", "-k", "workloads")
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-nginx-test")

		_, err := suite.HttpClient().GetJson(ctx, "http://albums-linux1.ingress-nginx-test.svc.cluster.local/albums-linux1")

		Expect(err).ToNot(HaveOccurred())
	})

	It("prints the status", func(ctx context.Context) {
		output := suite.K2sCli().MustExec(ctx, "addons", "status", "ingress", "nginx")

		Expect(output).To(SatisfyAll(
			MatchRegexp("ADDON STATUS"),
			MatchRegexp(`Implementation .+nginx.+ of Addon .+ingress.+ is .+enabled.+`),
			MatchRegexp("The nginx ingress controller is working"),
			MatchRegexp("The external IP for ingress-nginx service is set to %s", regex.IpAddressRegex),
			MatchRegexp("The cert-manager API is ready"),
			MatchRegexp("The CA root certificate is available"),
		))

		output = suite.K2sCli().MustExec(ctx, "addons", "status", "ingress", "nginx", "-o", "json")

		var status status.AddonPrintStatus

		Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

		Expect(status.Name).To(Equal("ingress"))
		Expect(status.Implementation).To(Equal("nginx"))
		Expect(status.Error).To(BeNil())
		Expect(status.Enabled).NotTo(BeNil())
		Expect(*status.Enabled).To(BeTrue())
		Expect(status.Props).NotTo(BeNil())
		Expect(status.Props).To(ContainElements(
			SatisfyAll(
				HaveField("Name", "IsIngressNginxRunning"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(ContainSubstring("The nginx ingress controller is working")))),
			SatisfyAll(
				HaveField("Name", "IsExternalIPSet"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("The external IP for ingress-nginx service is set to %s", regex.IpAddressRegex)))),
			SatisfyAll(
				HaveField("Name", "IsCertManagerAvailable"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(ContainSubstring("The cert-manager API is ready")))),
			SatisfyAll(
				HaveField("Name", "IsCaRootCertificateAvailable"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("The CA root certificate is available")))),
		))
	})

})

var _ = Describe("'ingress-nginx' addon with --omitCertMgr", Ordered, func() {
	AfterAll(func(ctx context.Context) {
		if k2s.IsAddonEnabled("ingress", "nginx") {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			k2s.VerifyAddonIsDisabled("ingress", "nginx")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
		}
	})

	It("enables without cert-manager and pods are running", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "--omitCertMgr", "-o")

		k2s.VerifyAddonIsEnabled("ingress", "nginx")

		suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")

		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
	})

	It("cert-manager namespace does not exist", func(ctx context.Context) {
		output, _ := suite.Kubectl().Exec(ctx, "get", "namespace", "cert-manager", "--ignore-not-found")
		Expect(output).To(BeEmpty())
	})

	It("ca-issuer-root-secret does not exist", func(ctx context.Context) {
		output, _ := suite.Kubectl().Exec(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret", "--ignore-not-found")
		Expect(output).To(BeEmpty())
	})

	It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "ingress", "nginx")

		Expect(output).To(ContainSubstring("already enabled"))
	})

	It("status shows cert-manager as unavailable", func(ctx context.Context) {
		output := suite.K2sCli().MustExec(ctx, "addons", "status", "ingress", "nginx", "-o", "json")

		var addonStatus status.AddonPrintStatus

		Expect(json.Unmarshal([]byte(output), &addonStatus)).To(Succeed())

		Expect(addonStatus.Name).To(Equal("ingress"))
		Expect(addonStatus.Implementation).To(Equal("nginx"))
		Expect(addonStatus.Enabled).NotTo(BeNil())
		Expect(*addonStatus.Enabled).To(BeTrue())
		Expect(addonStatus.Props).NotTo(BeNil())
		Expect(addonStatus.Props).To(ContainElements(
			SatisfyAll(
				HaveField("Name", "IsIngressNginxRunning"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue()))),
			SatisfyAll(
				HaveField("Name", "IsCertManagerAvailable"),
				HaveField("Value", false),
				HaveField("Okay", gstruct.PointTo(BeFalse()))),
			SatisfyAll(
				HaveField("Name", "IsCaRootCertificateAvailable"),
				HaveField("Value", false),
				HaveField("Okay", gstruct.PointTo(BeFalse()))),
		))
	})

	It("disables cleanly without cert-manager errors", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")

		k2s.VerifyAddonIsDisabled("ingress", "nginx")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
	})
})
