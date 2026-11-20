// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package kubevirt

import (
	"context"
	"fmt"

	"encoding/json"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

const (
	manualExecutionFilterTag = "manual"
	testWorkload             = "workloads/test.yaml"
	testStepTimeout          = time.Minute * 10
)

var (
	suite                         *framework.K2sTestSuite
	isManualExecution             = false
	automatedExecutionSkipMessage = fmt.Sprintf("can only be run using the filter value '%s'", manualExecutionFilterTag)
	testFailed                    = false
)

func TestAddon(t *testing.T) {
	executionLabels := []string{"addon", "addon-diverse", "acceptance", "setup-required", "invasive", "kubevirt", "system-running"}
	userAppliedLabels := GinkgoLabelFilter()
	if strings.Compare(userAppliedLabels, "") != 0 {
		if Label(manualExecutionFilterTag).MatchesLabelFilter(userAppliedLabels) {
			isManualExecution = true
			executionLabels = append(executionLabels, manualExecutionFilterTag)
		}
	}

	RegisterFailHandler(Fail)
	RunSpecs(t, "kubevirt Addon Acceptance Tests", Label(executionLabels...))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testStepTimeout))
	expectVirtctlNotInstalled()
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

var _ = Describe("'kubevirt' addon", Ordered, func() {
	When("addon is disabled", func() {
		Describe("disable", func() {
			It("prints already-disabled message and exits with non-zero", func(ctx context.Context) {
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", "kubevirt")

				Expect(output).To(ContainSubstring("already disabled"))
			})
		})

		Describe("status", func() {
			Context("default output", func() {
				It("displays disabled message", func(ctx context.Context) {
					output := suite.K2sCli().MustExec(ctx, "addons", "status", "kubevirt")

					Expect(output).To(SatisfyAll(
						MatchRegexp(`ADDON STATUS`),
						MatchRegexp(`Addon .+kubevirt.+ is .+disabled.+`),
					))
				})
			})

			Context("JSON output", func() {
				It("displays JSON", func(ctx context.Context) {
					output := suite.K2sCli().MustExec(ctx, "addons", "status", "kubevirt", "-o", "json")

					var status status.AddonPrintStatus

					Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

					Expect(status.Name).To(Equal("kubevirt"))
					Expect(status.Enabled).NotTo(BeNil())
					Expect(*status.Enabled).To(BeFalse())
					Expect(status.Props).To(BeNil())
					Expect(status.Error).To(BeNil())
				})
			})
		})

		Describe("enable", func() {
			BeforeAll(func(ctx context.Context) {
				if !isManualExecution {
					Skip(automatedExecutionSkipMessage)
				}
				suite.K2sCli().MustExec(ctx, "addons", "enable", "kubevirt", "-o")
			})

			It("enables the addon", func(ctx context.Context) {
				podNames := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "kubevirt", "-o", "jsonpath='{.items[*].metadata.name}'")

				Expect(podNames).To(ContainSubstring("virt-controller"))
			})

			It("installs 'virtctl.exe'", func() {
				_, err := runVirtctlCommand(make([]string, 0))

				Expect(err).To(BeNil())
			})
		})
	})
	When("addon is enabled", func() {
		BeforeAll(func(ctx context.Context) {
			if !isManualExecution {
				Skip(automatedExecutionSkipMessage)
			}
		})

		It("prints the status", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", "kubevirt")

			Expect(output).To(SatisfyAll(
				MatchRegexp("ADDON STATUS"),
				MatchRegexp(`Addon .+kubevirt.+ is .+enabled.+`),
				MatchRegexp("The virt-api is working"),
				MatchRegexp("The virt-controller is working"),
				MatchRegexp("The virt-operator is working"),
				MatchRegexp("The virt-handler is working"),
			))

			output = suite.K2sCli().MustExec(ctx, "addons", "status", "kubevirt", "-o", "json")

			var status status.AddonPrintStatus

			Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

			Expect(status.Name).To(Equal("kubevirt"))
			Expect(status.Error).To(BeNil())
			Expect(status.Enabled).NotTo(BeNil())
			Expect(*status.Enabled).To(BeTrue())
			Expect(status.Props).NotTo(BeNil())
			Expect(status.Props).To(ContainElements(
				SatisfyAll(
					HaveField("Name", "IsVirtApiRunning"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(ContainSubstring("The virt-api is working")))),
				SatisfyAll(
					HaveField("Name", "IsVirtControllerRunning"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(MatchRegexp("The virt-controller is working")))),
				SatisfyAll(
					HaveField("Name", "IsVirtOperatorRunning"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(ContainSubstring("The virt-operator is working")))),
				SatisfyAll(
					HaveField("Name", "IsVirtHandlerRunning"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(MatchRegexp("The virt-handler is working")))),
			))
		})

		Describe("resource 'VirtualMachine'", func() {
			AfterAll(func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "delete", "-f", testWorkload)
			})

			It("creates a VM", func(ctx context.Context) {
				suite.Kubectl().MustExec(ctx, "apply", "-f", testWorkload)
				vmStatusOutput := suite.Kubectl().MustExec(ctx, "get", "vms", "testvm")
				Expect(vmStatusOutput).To(ContainSubstring("Stopped"))

				output, err := runVirtctlCommand([]string{"start", "testvm"})

				Expect(err).To(BeNil())
				Expect(output).To(ContainSubstring("VM testvm was scheduled to start"))

				suite.Kubectl().MustExec(ctx, "wait", "--timeout=180s", "--for=condition=ContainersReady", "pod", "-l", "kubevirt.io/size=small,kubevirt.io/domain=testvm")

				Eventually(suite.Kubectl().MustExec).
					WithArguments("get", "vms", "testvm").
					WithTimeout(3 * time.Minute).
					WithPolling(30 * time.Second).
					WithContext(ctx).
					Should(ContainSubstring("Running"))

				podName := suite.Kubectl().MustExec(ctx, "get", "pod", "-l", "kubevirt.io/size=small,kubevirt.io/domain=testvm", "-o", "jsonpath={.items[0].metadata.name}")
				Expect(podName).To(ContainSubstring("testvm"))

				runningVMsOutput := suite.Kubectl().MustExec(ctx, "exec", podName, "--", "virsh", "list", "--all")
				Expect(runningVMsOutput).To(ContainSubstring("default_testvm   running"))
			})
		})

		Describe("disable", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "kubevirt", "-o")

				Eventually(isKubectlAvailable).WithTimeout(3 * time.Minute).WithPolling(30 * time.Second).Should(BeTrue())
			})

			It("disables the addon", func(ctx context.Context) {
				podNames := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "kubevirt", "-o", "jsonpath='{.items[*].metadata.name}'")

				Expect(podNames).To(BeComparableTo("''"))
			})

			It("uninstalls 'virtctl.exe'", func() {
				_, err := runVirtctlCommand(make([]string, 0))

				Expect(err).ShouldNot(BeNil())
			})
		})
	})
})

func runVirtctlCommand(args []string) (string, error) {
	cmd, b := exec.Command("virtctl.exe", args...), new(strings.Builder)
	cmd.Stdout = b
	cmd.Stderr = b
	err := cmd.Run()

	if err != nil {
		return "", err
	}

	output := b.String()
	return output, nil
}

func isKubectlAvailable() bool {
	var err error
	cmd, b := exec.Command("kubectl.exe", "get", "pods"), new(strings.Builder)
	cmd.Stdout = b
	cmd.Stderr = b
	err = cmd.Run()
	if err != nil || strings.Contains(b.String(), "Unable to connect to the server") {
		return false
	} else {
		return true
	}
}

func expectVirtctlNotInstalled() {
	_, err := runVirtctlCommand(make([]string, 0))

	Expect(err).ShouldNot(BeNil())
}
