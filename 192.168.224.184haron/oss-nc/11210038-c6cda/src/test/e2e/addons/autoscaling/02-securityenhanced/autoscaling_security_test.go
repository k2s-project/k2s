// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package autoscalingsecurity

import (
	"context"
	"testing"
	"time"

	"github.com/k2s-project/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 30

var (
	suite      *framework.K2sTestSuite
	testFailed = false
)

func TestAutoscalingSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Autoscaling and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-1", "acceptance", "setup-required", "invasive", "autoscaling", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up autoscaling security test")
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up autoscaling security test")

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	if suite.ShouldCleanup(testFailed) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "autoscaling", "-o")
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

var _ = Describe("'autoscaling and security enhanced' addons", Ordered, func() {
	Describe("Security addon activated first then autoscaling addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("activates the autoscaling addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling autoscaling addon")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "autoscaling", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("keda-admission", "autoscaling")
			suite.Cluster().ExpectPodsInReadyState(ctx, "app=keda-admission-webhooks", "autoscaling")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "autoscaling")
			GinkgoWriter.Println(">>> TEST: Autoscaling addon enabled and verified")
		})

		It("verifies autoscaling deployment is available and pods are ready", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying autoscaling deployment")
			suite.Cluster().ExpectDeploymentToBeAvailable("keda-admission", "autoscaling")
			suite.Cluster().ExpectPodsInReadyState(ctx, "app=keda-admission-webhooks", "autoscaling")
			GinkgoWriter.Println(">>> TEST: Autoscaling deployment verified")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "autoscaling", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})

	Describe("Autoscaling addon activated first then security addon", func() {
		It("activates the autoscaling addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling autoscaling addon first")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "autoscaling", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("keda-admission", "autoscaling")
			suite.Cluster().ExpectPodsInReadyState(ctx, "app=keda-admission-webhooks", "autoscaling")
			GinkgoWriter.Println(">>> TEST: Autoscaling addon enabled")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("verifies autoscaling deployment is available and pods are ready", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying autoscaling deployment with linkerd")
			suite.Cluster().ExpectDeploymentToBeAvailable("keda-admission", "autoscaling")
			suite.Cluster().ExpectPodsInReadyState(ctx, "app=keda-admission-webhooks", "autoscaling")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "autoscaling")
			GinkgoWriter.Println(">>> TEST: Autoscaling deployment verified with linkerd injection")
		})
	})
})
