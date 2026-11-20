// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package dicom

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

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

func TestDicom(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "dicom Addon Acceptance Tests", Label("addon", "addon-medical", "acceptance", "setup-required", "invasive", "dicom", "system-running"))
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

var _ = Describe("'dicom' addon", Ordered, func() {
	Describe("status command", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "dicom")

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Addon .+dicom.+ is .+disabled.+`),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "dicom", "-o", "json")

				var status status.AddonPrintStatus

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

				Expect(status.Name).To(Equal("dicom"))
				Expect(status.Enabled).NotTo(BeNil())
				Expect(*status.Enabled).To(BeFalse())
				Expect(status.Props).To(BeNil())
				Expect(status.Error).To(BeNil())
			})
		})
	})

	Describe("disable command", func() {
		When("addon is already disabled", func() {
			It("prints already-disabled message and exits with non-zero", func(ctx context.Context) {
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", "dicom", "-f")

				Expect(output).To(ContainSubstring("already disabled"))
			})
		})
	})

	Describe("enable command", func() {
		When("no ingress controller is configured", func() {
			AfterAll(func(ctx context.Context) {
				if suite.ShouldCleanup(testFailed) {
					suite.K2sCli().MustExec(ctx, "addons", "disable", "dicom", "-o", "-f")
					k2s.VerifyAddonIsDisabled("dicom")

					suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "dicom", "dicom")
					suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "postgres", "dicom")
				}
			})

			It("is in enabled state and pods are in running state", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "dicom", "-o")
				k2s.VerifyAddonIsEnabled("dicom")

				suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
				suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")

				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})

		When("traefik as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
			})

			AfterAll(func(ctx context.Context) {
				if suite.ShouldCleanup(testFailed) {
					suite.K2sCli().MustExec(ctx, "addons", "disable", "dicom", "-o", "-f")
					suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")
					k2s.VerifyAddonIsDisabled("dicom")

					suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "orthanc", "dicom")
					suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "postgres", "dicom")

					suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
				}
			})

			It("is in enabled state and pods are in running state", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "dicom", "-o")
				k2s.VerifyAddonIsEnabled("dicom")

				suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
				suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")

				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")
			})

			It("is reachable through k2s.cluster.local for the ui app", func(ctx context.Context) {
				url := "https://k2s.cluster.local/dicom/ui/app"
				suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-o", "NUL", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
			})

			It("is reachable through k2s.cluster.local for DICOM Web", func(ctx context.Context) {
				url := "https://k2s.cluster.local/dicom/studies"
				suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-o", "NUL", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})

		When("nginx as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
			})

			AfterAll(func(ctx context.Context) {
				if suite.ShouldCleanup(testFailed) {
					suite.K2sCli().MustExec(ctx, "addons", "disable", "dicom", "-o", "-f")
					suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
					k2s.VerifyAddonIsDisabled("dicom")

					suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "orthanc", "dicom")
					suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "postgres", "dicom")

					suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
				}
			})

			It("is in enabled state and pods are in running state", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "dicom", "-o")
				k2s.VerifyAddonIsEnabled("dicom")

				suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
				suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")

				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")
			})

			It("is reachable through k2s.cluster.local for the ui app", func(ctx context.Context) {
				url := "https://k2s.cluster.local/dicom/ui/app"
				suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-o", "NUL", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
			})

			It("is reachable through k2s.cluster.local for DICOM Web", func(ctx context.Context) {
				url := "https://k2s.cluster.local/dicom/studies"
				suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-o", "NUL", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})

		When("nginx-gw as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx-gw", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("nginx-gw-controller", "nginx-gw")
			})

			AfterAll(func(ctx context.Context) {
				if suite.ShouldCleanup(testFailed) {
					suite.K2sCli().MustExec(ctx, "addons", "disable", "dicom", "-o", "-f")
					suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
					k2s.VerifyAddonIsDisabled("dicom")

					suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "orthanc", "dicom")
					suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "postgres", "dicom")

					suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "nginx-gw", "nginx-gw")
				}
			})

			It("is in enabled state and pods are in running state", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "dicom", "-o")
				k2s.VerifyAddonIsEnabled("dicom")

				suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
				suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")

				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")
			})

			It("is reachable through k2s.cluster.local for the ui app", func(ctx context.Context) {
				url := "https://k2s.cluster.local/dicom/ui/app"
				suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-o", "NUL", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
			})

			It("is reachable through k2s.cluster.local for DICOM Web", func(ctx context.Context) {
				url := "https://k2s.cluster.local/dicom/studies"
				suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-o", "NUL", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})
	})
})

func expectAddonToBeAlreadyEnabled(ctx context.Context) {
	output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "dicom")

	Expect(output).To(ContainSubstring("already enabled"))
}

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().MustExec(ctx, "addons", "status", "dicom")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Addon .+dicom.+ is .+enabled.+`),
		MatchRegexp("The dicom Deployment is working"),
		MatchRegexp("The postgres Deployment is working"),
	))

	output = suite.K2sCli().MustExec(ctx, "addons", "status", "dicom", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("dicom"))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
	Expect(status.Props).NotTo(BeNil())
	Expect(status.Props).To(ContainElements(
		SatisfyAll(
			HaveField("Name", "dicom"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("The dicom Deployment is working"))),
		),
		SatisfyAll(
			HaveField("Name", "postgres"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("The postgres Deployment is working"))),
		),
	))
}
