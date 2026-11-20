// SPDX-FileCopyrightText: © 2025 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

// Package securityenhanced provides shared helper functions for addon + security enhanced tests.
package securityenhanced

import (
	"context"
	"time"

	"github.com/k2s-project/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
)

// DefaultSecurityTestTimeout is the default timeout for security enhanced tests.
const DefaultSecurityTestTimeout = time.Minute * 20

// EnableSecurityEnhanced enables the security addon in enhanced mode and waits for it to stabilize.
func EnableSecurityEnhanced(ctx context.Context, suite *framework.K2sTestSuite) {
	GinkgoWriter.Println(">>> SECURITY: Enabling security addon in enhanced mode...")
	args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
	suite.K2sCli().MustExec(ctx, args...)
	GinkgoWriter.Println(">>> SECURITY: Waiting 30s for security addon to stabilize...")
	time.Sleep(30 * time.Second)
	GinkgoWriter.Println(">>> SECURITY: Security addon enabled and stabilized")
}

// DisableSecurityAddon disables the security addon.
func DisableSecurityAddon(ctx context.Context, suite *framework.K2sTestSuite) {
	GinkgoWriter.Println(">>> SECURITY: Disabling security addon...")
	suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
	GinkgoWriter.Println(">>> SECURITY: Security addon disabled")
}

// DisableIngressNginx disables the ingress nginx addon.
func DisableIngressNginx(ctx context.Context, suite *framework.K2sTestSuite) {
	GinkgoWriter.Println(">>> SECURITY: Disabling ingress nginx addon...")
	suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	GinkgoWriter.Println(">>> SECURITY: Ingress nginx addon disabled")
}

// VerifyLinkerdInjected verifies that linkerd sidecar is injected in the given namespace.
func VerifyLinkerdInjected(ctx context.Context, suite *framework.K2sTestSuite, namespace string) {
	GinkgoWriter.Printf(">>> SECURITY: Verifying linkerd injection in namespace '%s'...\n", namespace)
	suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", namespace)
	GinkgoWriter.Printf(">>> SECURITY: Linkerd injection verified in namespace '%s'\n", namespace)
}
