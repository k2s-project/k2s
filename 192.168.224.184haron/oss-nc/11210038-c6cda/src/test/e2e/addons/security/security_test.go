// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package security

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path"
	"testing"
	"time"

	"github.com/samber/lo"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"
	"github.com/k2s-project/k2s/test/framework/k2s/addons"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

const addonName = "security"
const (
	namespace = "k2s"
)

var linuxDeploymentNames = []string{"albums-linux1", "albums-linux2", "albums-linux3"}
var winDeploymentNames = []string{"albums-win1", "albums-win2", "albums-win3"}

var manifestDir string
var k2s *dsl.K2s

var proxy string
var testFailed = false
var workloadCreated = false
var suite *framework.K2sTestSuite
var testStepTimeout = time.Minute * 20

func TestSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "security Addon Acceptance Tests", Label("addon", "addon-security", "acceptance", "setup-required", "invasive", "security", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testStepTimeout))
	manifestDir = "workload/windows"
	proxy = "http://172.19.1.1:8181"

	k2s = dsl.NewK2s(suite)

	if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		GinkgoWriter.Println("Found Linux-only setup, skipping Windows-based workloads")
		manifestDir = "workload/base"
	}

	GinkgoWriter.Println("Using proxy <", proxy, "> for internet access")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	suite.StatusChecker().IsK2sRunning(ctx)

	GinkgoWriter.Println("Deleting workloads if necessary..")
	DeleteWorkloads(ctx)

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	isEnabled := func(name string, implementation ...string) bool {
		impl := ""
		if len(implementation) > 0 {
			impl = implementation[0]
		}
		return lo.ContainsBy(suite.SetupInfo().RuntimeConfig.ClusterConfig().EnabledAddons(), func(a config.Addon) bool {
			return a.Name == name && a.Implementation == impl
		})
	}

	if isEnabled(addonName) {
		suite.K2sCli().Exec(ctx, "addons", "disable", addonName, "-o")
	}

	if isEnabled("ingress", "nginx") {
		suite.K2sCli().Exec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	}

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

func DeployWorkloads(ctx context.Context) {
	GinkgoWriter.Println("Deploying workloads to cluster..")

	if manifestDir == "" {
		Fail("Manifest directory is not set, cannot deploy workloads")
	}
	suite.Kubectl().MustExec(ctx, "apply", "-k", manifestDir)

	GinkgoWriter.Println("Waiting for Deployments to be ready in namespace <", namespace, ">..")

	suite.Kubectl().MustExec(ctx, "rollout", "status", "deployment", "-n", namespace, "--timeout="+suite.TestStepTimeout().String())

	for _, deploymentName := range linuxDeploymentNames {
		suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, namespace)
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, namespace)
	}

	if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		for _, deploymentName := range winDeploymentNames {
			suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, namespace)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, namespace)
		}
	}
	workloadCreated = true
	GinkgoWriter.Println("Deployments ready for testing")
}

func DeleteWorkloads(ctx context.Context) {
	// for finding out the sporadically failed test runs
	if suite.ShouldCleanup(testFailed) && manifestDir != "" && workloadCreated {
		suite.Kubectl().MustExec(ctx, "delete", "-k", manifestDir)
		workloadCreated = false
		GinkgoWriter.Println("Workloads deleted")
	}
}

var _ = Describe("'security' addon tests", Ordered, Serial, func() {
	Describe("'security' addon", Ordered, func() {
		It("completes successfully when addon is already disabled", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, "-o")
		})

		It("enables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, "-o")
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", addonName)

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status user-friendly", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName)

			Expect(output).To(SatisfyAll(
				MatchRegexp("ADDON STATUS"),
				MatchRegexp(`Addon .+%s.+ is .+enabled.+`, addonName),
				MatchRegexp("The cert-manager API is ready"),
				MatchRegexp("The CA root certificate is available"),
			))
		})

		It("prints the status as JSON", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, "-o", "json")

			var status status.AddonPrintStatus

			Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

			Expect(status.Name).To(Equal(addonName))
			Expect(status.Error).To(BeNil())
			Expect(status.Enabled).NotTo(BeNil())
			Expect(*status.Enabled).To(BeTrue())
			Expect(status.Props).NotTo(BeNil())
			Expect(status.Props).To(ContainElements(
				SatisfyAll(
					HaveField("Name", "IsCertManagerAvailable"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(ContainSubstring("The cert-manager API is ready")))),
				SatisfyAll(
					HaveField("Name", "IsCaRootCertificateAvailable"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(MatchRegexp("The CA root certificate is available"))),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
				),
				SatisfyAll(
					HaveField("Name", "IsKyvernoAvailable"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(ContainSubstring("The Kyverno policy engine is ready"))),
				)))
		})

		It("installs cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(err).To(BeNil())
		})

		It("creates the ca-issuer-root-secret", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
			Expect(output).To(ContainSubstring("ca-issuer-root-secret"))
		})

		It("Deploy the workloads after enabling the security addon", func(ctx context.Context) {
			DeployWorkloads(ctx)
		})

		headers := make(map[string]string)
		It("gets bearer token from keycloak", func(ctx context.Context) {
			// Get the access token
			accessToken, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred())

			// Make the request with the access token
			headers = map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", accessToken),
			}
		})

		DescribeTable("Deployment is reachable from host using bearer token ", func(ctx context.Context, name string, skipOnLinuxOnly bool) {
			if skipOnLinuxOnly && suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
				Skip("Linux-only")
			}

			if len(headers) == 0 {
				Fail("Headers for authentication are not set")
			}
			{
				url := fmt.Sprintf("https://k2s.cluster.local/%s", name)
				addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			}
		},
			Entry("albums-linux1 is reachable from host", "albums-linux1", false),
			Entry("albums-win1 is reachable from host", "albums-win1", true),
			Entry("albums-linux2 is reachable from host", "albums-linux2", false),
			Entry("albums-win2 is reachable from host", "albums-win2", true))

		It("Delete the workloads", func(ctx context.Context) {
			DeleteWorkloads(ctx)
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, "-o")
		})

		It("disables default ingress addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
		})

		It("preserves cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(err).To(BeNil())
		})

		It("preserves kyverno.exe, the Kyverno CLI", func(ctx context.Context) {
			kyvernoPath := path.Join(suite.RootDir(), "bin", "kyverno.exe")
			_, err := os.Stat(kyvernoPath)
			Expect(err).To(BeNil())
		})

		It("removed the ca-issuer-root-secret", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-A")
			Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"))
		})
	})

	Describe("'security' addon with enhanced mode", Ordered, func() {
		It("enables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, "-t", "enhanced", "-o")
		})

		It("prints the status user-friendly", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName)

			Expect(output).To(SatisfyAll(
				MatchRegexp("ADDON STATUS"),
				MatchRegexp(`Addon .+%s.+ is .+enabled.+`, addonName),
				MatchRegexp("The cert-manager API is ready"),
				MatchRegexp("The CA root certificate is available"),
			))
		})

		It("prints the status as JSON", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, "-o", "json")

			var status status.AddonPrintStatus

			Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

			Expect(status.Name).To(Equal(addonName))
			Expect(status.Error).To(BeNil())
			Expect(status.Enabled).NotTo(BeNil())
			Expect(*status.Enabled).To(BeTrue())
			Expect(status.Props).NotTo(BeNil())
			Expect(status.Props).To(ContainElements(
				SatisfyAll(
					HaveField("Name", "Type of security"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(ContainSubstring("enhanced")))),
				SatisfyAll(
					HaveField("Name", "IsCertManagerAvailable"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(ContainSubstring("The cert-manager API is ready")))),
				SatisfyAll(
					HaveField("Name", "IsCaRootCertificateAvailable"),
					HaveField("Value", true),
					HaveField("Message", gstruct.PointTo(MatchRegexp("The CA root certificate is available"))),
					HaveField("Okay", gstruct.PointTo(BeTrue()))),
				SatisfyAll(
					HaveField("Name", "IsTrustManagerAvailable"),
					HaveField("Value", true),
					HaveField("Message", gstruct.PointTo(MatchRegexp("The trust-manager API is ready"))),
					HaveField("Okay", gstruct.PointTo(BeTrue()))),
				SatisfyAll(
					HaveField("Name", "Type of security"),
					HaveField("Value", true),
					HaveField("Message", gstruct.PointTo(MatchRegexp("The linkerd API is ready"))),
					HaveField("Okay", gstruct.PointTo(BeTrue()))),
				SatisfyAll(
					HaveField("Name", "IsKeycloakAvailable"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(ContainSubstring("The keycloak API is ready")))),
				SatisfyAll(
					HaveField("Name", "IsHydraAvailable"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(ContainSubstring("The hydra API is ready")))),
			))
		})

		It("installs cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(err).To(BeNil())
		})

		It("installs linkerd", func(ctx context.Context) {
			linkerdPath := path.Join(suite.RootDir(), "bin", "linkerd.exe")
			_, err := os.Stat(linkerdPath)
			Expect(err).To(BeNil())
		})

		It("creates the ca-issuer-root-secret", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
			Expect(output).To(ContainSubstring("ca-issuer-root-secret"))
		})

		It("meshes the kyverno namespace into Linkerd (enhanced security mode)", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "namespace", "kyverno", "-o", "jsonpath={.metadata.annotations.linkerd\\.io/inject}")
			Expect(output).To(ContainSubstring("enabled"))
		})

		It("Deploy the workloads after enabling the security addon", func(ctx context.Context) {
			DeployWorkloads(ctx)
		})

		Describe("Communication", func() {
			DescribeTable("Deployments Availability", func(name string, skipOnLinuxOnly bool) {
				if skipOnLinuxOnly && suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeAvailable(name, namespace)
			},
				Entry("albums-linux1 is available", "albums-linux1", false),
				Entry("albums-win1 is available", "albums-win1", true),
				Entry("albums-linux2 is available", "albums-linux2", false),
				Entry("albums-win2 is available", "albums-win2", true),
				Entry("curl is available", "curl", false),
				Entry("albums-linux3 is available", "albums-linux3", false),
				Entry("albums-win3 is available", "albums-win3", true),
				Entry("curl1 is available", "curl1", false))

			// On Windows the redirection is programmed by the K2s CNI, so linkerd-init only
			// verifies the contract. Asserting the exit code pins the failure to the init
			// container instead of surfacing it later as an unrelated connectivity timeout.
			DescribeTable("Linkerd init container completes successfully", func(ctx context.Context, name string, skipOnLinuxOnly bool) {
				if skipOnLinuxOnly && suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				exitCode := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", namespace, "-l", "app="+name,
					"-o", `jsonpath={.items[*].status.initContainerStatuses[?(@.name=="linkerd-init")].state.terminated.exitCode}`)

				Expect(exitCode).To(MatchRegexp(`^0(\s+0)*$`), "linkerd-init did not complete successfully for "+name)
			},
				Entry("albums-linux1", "albums-linux1", false),
				Entry("albums-win1", "albums-win1", true),
				Entry("albums-linux2", "albums-linux2", false),
				Entry("albums-win2", "albums-win2", true))

			DescribeTable("Deployment is not reachable from Host due to StatusForbidden for pods with linkerd.io/inject: enabled", func(ctx context.Context, name string, skipOnLinuxOnly bool) {
				if skipOnLinuxOnly && suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}
				url := fmt.Sprintf("http://%s.%s.svc.cluster.local/%s", name, namespace, name)
				addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusForbidden, url)
			},
				Entry("albums-linux1 is NOT reachable from host", "albums-linux1", false),
				Entry("albums-win1 is NOT reachable from host", "albums-win1", true),
				Entry("albums-linux2 is NOT reachable from host", "albums-linux2", false),
				Entry("albums-win2 is NOT reachable from host", "albums-win2", true))

			DescribeTable("Deployment is reachable from Host due to StatusOK for pods without linkerd.io/inject: enabled", func(ctx context.Context, name string, skipOnLinuxOnly bool) {
				if skipOnLinuxOnly && suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}
				url := fmt.Sprintf("http://%s.%s.svc.cluster.local/%s", name, namespace, name)
				addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url)
			},
				Entry("albums-linux3 is reachable from host", "albums-linux3", false),
				Entry("albums-win3 is reachable from host", "albums-win3", true))

			Describe("Linux/Windows Deployments with linkerd.io/inject: enabled are reachable from Linux Pods with linkerd.io/inject: enabled", func() {
				It("Deployment albums-linux1 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
					suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "curl", namespace, ctx)
				})

				It("Deployment albums-win1 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
					if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
						Skip("Linux-only")
					}

					suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win1", namespace, "curl", namespace, ctx)
				})

				It("Deployment albums-linux2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
					suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "curl", namespace, ctx)
				})

				It("Deployment albums-win2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
					if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
						Skip("Linux-only")
					}

					suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "curl", namespace, ctx)
				})
			})

			Describe("Linux/Windows Deployments without linkerd.io/inject: enabled are reachable from Linux Pods with linkerd.io/inject: enabled", func() {
				It("Deployment albums-linux3 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
					suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux3", namespace, "curl", namespace, ctx)
				})

				It("Deployment albums-win3 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
					if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
						Skip("Linux-only")
					}
					suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win3", namespace, "curl", namespace, ctx)
				})
			})

			Describe("Linux/Windows Deployments with linkerd.io/inject: enabled are NOT reachable from Linux Pods without linkerd.io/inject: enabled", func() {
				It("Deployment albums-linux1 is NOT reachable from Pod of Deployment curl1", func(ctx SpecContext) {
					suite.Cluster().ExpectDeploymentNotToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "curl1", namespace, ctx)
				})

				It("Deployment albums-win1 is NOT reachable from Pod of Deployment curl", func(ctx SpecContext) {
					if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
						Skip("Linux-only")
					}

					suite.Cluster().ExpectDeploymentNotToBeReachableFromPodOfOtherDeployment("albums-win1", namespace, "curl1", namespace, ctx)
				})

				It("Deployment albums-linux2 is NOT reachable from Pod of Deployment curl", func(ctx SpecContext) {
					suite.Cluster().ExpectDeploymentNotToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "curl1", namespace, ctx)
				})

				It("Deployment albums-win2 is NOT reachable from Pod of Deployment curl1", func(ctx SpecContext) {
					if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
						Skip("Linux-only")
					}

					suite.Cluster().ExpectDeploymentNotToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "curl1", namespace, ctx)
				})
			})

			Describe("Linux/Windows Deployments without linkerd.io/inject: enabled are reachable from Linux Pods without linkerd.io/inject: enabled", func() {
				It("Deployment albums-linux3 is reachable from Pod of Deployment curl1", func(ctx SpecContext) {
					suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux3", namespace, "curl1", namespace, ctx)
				})

				It("Deployment albums-win3 is reachable from Pod of Deployment curl1", func(ctx SpecContext) {
					if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
						Skip("Linux-only")
					}
					suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win3", namespace, "curl1", namespace, ctx)
				})
			})
		})

		It("Delete the workloads", func(ctx context.Context) {
			DeleteWorkloads(ctx)
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, "-o")
		})

		It("disables default ingress addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
		})

		It("preserves cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(err).To(BeNil())
		})

		It("uninstalls linkerd", func(ctx context.Context) {
			linkerdPath := path.Join(suite.RootDir(), "bin", "linkerd.exe")
			_, err := os.Stat(linkerdPath)
			Expect(os.IsNotExist(err)).To(BeTrue())
		})

		It("removed the ca-issuer-root-secret", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-A")
			Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"))
		})
	})

	// omitFlagTestCase defines a test case for basic mode omit flag variations
	type omitFlagTestCase struct {
		description     string
		flags           []string
		expectedOmitted map[string]string // component name -> expected message substring
	}

	Describe("'security' addon with omit flags (basic mode)", Ordered, func() {
		// Test only "all omit flags" case - covers all omit functionality in one enable/disable cycle
		It("enables the addon with all omit flags", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, "--omitHydra", "--omitKeycloak", "--omitOAuth2Proxy", "--omitPolicyEnf", "-o")
		})

		It("prints the status showing all omitted components", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, "-o", "json")
			var addonStatus status.AddonPrintStatus
			Expect(json.Unmarshal([]byte(output), &addonStatus)).To(Succeed())

			// Verify all omitted components
			Expect(addonStatus.Props).To(ContainElement(SatisfyAll(
				HaveField("Name", "IsHydraAvailable"),
				HaveField("Value", false),
				HaveField("Message", gstruct.PointTo(ContainSubstring("not deployed"))),
			)))
			Expect(addonStatus.Props).To(ContainElement(SatisfyAll(
				HaveField("Name", "IsKeycloakAvailable"),
				HaveField("Value", false),
				HaveField("Message", gstruct.PointTo(ContainSubstring("not ready or was omitted"))),
			)))
			Expect(addonStatus.Props).To(ContainElement(SatisfyAll(
				HaveField("Name", "IsOAuth2ProxyAvailable"),
				HaveField("Value", false),
				HaveField("Message", gstruct.PointTo(ContainSubstring("not deployed"))),
			)))
			Expect(addonStatus.Props).To(ContainElement(SatisfyAll(
				HaveField("Name", "IsKyvernoAvailable"),
				HaveField("Value", false),
				HaveField("Message", gstruct.PointTo(ContainSubstring("not deployed"))),
			)))
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, "-o")
		})
	})

	Describe("'security' addon with omit flags (enhanced mode)", Ordered, func() {
		// Test only "all omit flags" case - covers all omit functionality in one enable/disable cycle
		It("enables the addon with all omit flags in enhanced mode", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, "-t", "enhanced", "--omitHydra", "--omitKeycloak", "--omitOAuth2Proxy", "--omitPolicyEnf", "-o")
		})

		It("prints the status showing correct component states", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, "-o", "json")
			var addonStatus status.AddonPrintStatus
			Expect(json.Unmarshal([]byte(output), &addonStatus)).To(Succeed())

			// Verify enhanced mode is active
			Expect(addonStatus.Props).To(ContainElement(SatisfyAll(
				HaveField("Name", "Type of security"),
				HaveField("Value", true),
				HaveField("Message", gstruct.PointTo(ContainSubstring("enhanced"))),
			)))

			// Verify omitted components
			Expect(addonStatus.Props).To(ContainElement(SatisfyAll(
				HaveField("Name", "IsHydraAvailable"),
				HaveField("Value", false),
				HaveField("Message", gstruct.PointTo(ContainSubstring("not deployed"))),
			)))
			Expect(addonStatus.Props).To(ContainElement(SatisfyAll(
				HaveField("Name", "IsKeycloakAvailable"),
				HaveField("Value", false),
				HaveField("Message", gstruct.PointTo(ContainSubstring("not ready or was omitted"))),
			)))
			Expect(addonStatus.Props).To(ContainElement(SatisfyAll(
				HaveField("Name", "IsOAuth2ProxyAvailable"),
				HaveField("Value", false),
				HaveField("Message", gstruct.PointTo(ContainSubstring("not deployed"))),
			)))

			// Verify non-omitted components ARE still available
			Expect(addonStatus.Props).To(ContainElement(SatisfyAll(
				HaveField("Name", "IsCertManagerAvailable"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(ContainSubstring("The cert-manager API is ready"))),
			)))
			Expect(addonStatus.Props).To(ContainElement(SatisfyAll(
				HaveField("Name", "IsCaRootCertificateAvailable"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(ContainSubstring("The CA root certificate is available"))),
			)))
			Expect(addonStatus.Props).To(ContainElement(SatisfyAll(
				HaveField("Name", "IsTrustManagerAvailable"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(ContainSubstring("The trust-manager API is ready"))),
			)))
		})
	})
})
