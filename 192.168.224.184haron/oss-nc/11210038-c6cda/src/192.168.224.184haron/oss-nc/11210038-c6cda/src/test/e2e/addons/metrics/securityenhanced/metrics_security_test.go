// SPDX-FileCopyrightText: © 2025 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package metricssecurity

import (
	"context"
	"testing"
	"time"

	"github.com/k2s-project/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 20

var suite *framework.K2sTestSuite
var testFailed = false

func TestMetricsSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Metrics and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-3", "acceptance", "setup-required", "invasive", "metrics", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up metrics security test")
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up metrics security test")

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	if suite.ShouldCleanup(testFailed) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "metrics", "-o")
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

var _ = Describe("'metrics and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then metrics addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("activates the metrics addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling metrics addon")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "metrics", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "metrics-server", "metrics")
			GinkgoWriter.Println(">>> TEST: Metrics addon enabled")
		})

		It("verifies that the metrics deployment is available and pods are ready", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying metrics deployment with linkerd")
			suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "metrics-server", "metrics")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "metrics")
			GinkgoWriter.Println(">>> TEST: Metrics deployment verified with linkerd injection")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "metrics", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})

	Describe("Metrics addon activated first then security addon", func() {
		It("activates the metrics addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling metrics addon first")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "metrics", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "metrics-server", "metrics")
			GinkgoWriter.Println(">>> TEST: Metrics addon enabled")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("verifies that the metrics deployment is available and pods are ready", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying metrics deployment with linkerd")
			suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "metrics-server", "metrics")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "metrics")
			GinkgoWriter.Println(">>> TEST: Metrics deployment verified with linkerd injection")
		})
	})
})
