// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package gpunode

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

const (
	namespace       = "gpu-node-test"
	workloadsPath   = "workloads/"
	podName         = "cuda-vector-add"
	cudaSampleImage = "nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1" // must match workloads/cuda-sample.yaml
)

var suite *framework.K2sTestSuite
var testFailed = false

func TestAddon(t *testing.T) {
	RegisterFailHandler(Fail)

	hiddenLabels := []string{"addon", "addon-diverse", "acceptance", "setup-required", "invasive", "gpu-node", "system-running", "nvidia"}

	RunSpecs(t, "gpu-node Addon Acceptance Tests", Label(hiddenLabels...))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled)
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	if suite.ShouldCleanup(testFailed) {
		GinkgoWriter.Println("Deleting workloads..")

		suite.Kubectl().MustExec(ctx, "delete", "-k", workloadsPath, "--ignore-not-found")

		_, exitCode := suite.K2sCli().Exec(ctx, "addons", "disable", "gpu-node", "-o")

		GinkgoWriter.Println("Disable addon result:", exitCode)
	}

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("'gpu-node' addon", Ordered, func() {
	Describe("status", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "gpu-node")

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Addon .+gpu-node.+ is .+disabled.+`),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "gpu-node", "-o", "json")

				var status status.AddonPrintStatus

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

				Expect(status.Name).To(Equal("gpu-node"))
				Expect(status.Enabled).NotTo(BeNil())
				Expect(*status.Enabled).To(BeFalse())
				Expect(status.Props).To(BeNil())
				Expect(status.Error).To(BeNil())
			})
		})
	})

	Describe("disable", func() {
		It("prints already-disabled message and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", "gpu-node")

			Expect(output).To(ContainSubstring("already disabled"))
		})
	})

	Describe("enable", func() {
		It("enables the addon", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "enable", "gpu-node", "-o")

			Expect(output).To(SatisfyAll(
				MatchRegexp("Running 'enable' for 'gpu-node' addon"),
				MatchRegexp("'k2s addons enable gpu-node' completed"),
			))
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "gpu-node")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", "gpu-node")

			Expect(output).To(SatisfyAll(
				MatchRegexp("ADDON STATUS"),
				MatchRegexp(`Addon .+gpu-node.+ is .+enabled.+`),
				MatchRegexp("The gpu node is working"),
			))

			output = suite.K2sCli().MustExec(ctx, "addons", "status", "gpu-node", "-o", "json")

			var status status.AddonPrintStatus

			Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

			Expect(status.Name).To(Equal("gpu-node"))
			Expect(status.Error).To(BeNil())
			Expect(status.Enabled).NotTo(BeNil())
			Expect(*status.Enabled).To(BeTrue())
			Expect(status.Props).NotTo(BeNil())
			Expect(status.Props).To(ContainElements(
				SatisfyAll(
					HaveField("Name", "IsDevicePluginRunning"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(ContainSubstring("The gpu node is working")))),
				SatisfyAll(
					HaveField("Name", "IsDCGMExporterRunning"),
					HaveField("Okay", gstruct.PointTo(BeTrue()))),
				// DCGM is no longer deployed (NVML unavailable via dxcore/GPU-PV), but status is still reported as Okay
				SatisfyAll(
					HaveField("Name", "NodeGpuLabels"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(ContainSubstring("gpu=true and accelerator=nvidia")))),
				SatisfyAll(
					HaveField("Name", "GpuAllocatable"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(MatchRegexp(`\d+ GPU slots? available`)))),
				SatisfyAll(
					HaveField("Name", "GpuInUse"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(MatchRegexp(`\d+ of \d+ GPU slots? in use`)))),
			))
		})

		It("runs CUDA workloads", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "image", "pull", cudaSampleImage, "-o")

			suite.Kubectl().MustExec(ctx, "delete", "pod", podName, "-n", namespace, "--ignore-not-found")
			suite.Kubectl().MustExec(ctx, "apply", "-k", workloadsPath)

			suite.Cluster().ExpectPodToBeCompleted(podName, namespace)
		})

		It("checks CUDA results", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "logs", podName, "-n", namespace)

			Expect(output).To(ContainSubstring("Test PASSED"))
		})

		It("labels the GPU node", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "gpu=true,accelerator=nvidia", "-o", "jsonpath={.items[0].metadata.name}")

			Expect(output).NotTo(BeEmpty())
		})

		It("device plugin has liveness probe configured", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "gpu-node", "-l", "k8s-app=nvidia-device-plugin", "-o", "jsonpath={.items[0].spec.containers[0].livenessProbe.exec.command[0]}")

			Expect(output).To(Equal("/usr/lib/wsl/lib/nvidia-smi"))
		})

		It("CDI spec contains directory mounts for full GPU library access", func(ctx context.Context) {
			// Get the device plugin pod name
			podName := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "gpu-node", "-l", "k8s-app=nvidia-device-plugin", "-o", "jsonpath={.items[0].metadata.name}")

			// Read the CDI spec
			output := suite.Kubectl().MustExec(ctx, "exec", "-n", "gpu-node", podName, "--", "cat", "/var/run/cdi/k8s.device-plugin.nvidia.com-gpu.json")

			// Verify directory mounts are present (required for OpenGL via D3D12 and CUDA)
			Expect(output).To(ContainSubstring(`"containerPath":"/usr/lib/wsl/lib"`), "CDI spec should mount /usr/lib/wsl/lib directory")
			Expect(output).To(ContainSubstring(`"containerPath":"/usr/lib/wsl/drivers"`), "CDI spec should mount /usr/lib/wsl/drivers directory")
		})

		It("CDI spec contains LD_LIBRARY_PATH environment variable", func(ctx context.Context) {
			podName := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "gpu-node", "-l", "k8s-app=nvidia-device-plugin", "-o", "jsonpath={.items[0].metadata.name}")

			output := suite.Kubectl().MustExec(ctx, "exec", "-n", "gpu-node", podName, "--", "cat", "/var/run/cdi/k8s.device-plugin.nvidia.com-gpu.json")

			Expect(output).To(ContainSubstring(`LD_LIBRARY_PATH=/usr/lib/wsl/lib`), "CDI spec should set LD_LIBRARY_PATH for workload pods")
		})

		It("workload pod has access to GPU libraries including OpenGL support", func(ctx context.Context) {
			// The cuda-vector-add pod completes and exits, so we use kubectl run to create a temporary pod
			// that checks library access. This verifies the CDI mounts are working for workload pods.
			gpuLibsTestPod := "gpu-libs-test"

			// Clean up any previous test pod
			suite.Kubectl().Exec(ctx, "delete", "pod", gpuLibsTestPod, "-n", namespace, "--ignore-not-found")

			// Run a pod that checks /usr/lib/wsl/lib and exits
			output := suite.Kubectl().MustExec(ctx, "run", gpuLibsTestPod, "-n", namespace,
				"--image=busybox:latest",
				"--restart=Never",
				"--overrides", `{"spec":{"containers":[{"name":"gpu-libs-test","image":"busybox:latest","command":["ls","-la","/usr/lib/wsl/lib/"],"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}`,
				"--timeout=60s")

			// Wait for pod to complete
			suite.Cluster().ExpectPodToBeCompleted(gpuLibsTestPod, namespace)

			// Get the logs which contain the ls output
			output = suite.Kubectl().MustExec(ctx, "logs", gpuLibsTestPod, "-n", namespace)

			Expect(output).To(ContainSubstring("libcuda.so"), "workload should have access to libcuda.so")
			Expect(output).To(ContainSubstring("libd3d12.so"), "workload should have access to libd3d12.so for D3D12 support")

			// Run another pod to check /usr/lib/wsl/drivers for libnvwgf2umx.so (OpenGL -> D3D12 translator)
			gpuDriversTestPod := "gpu-drivers-test"
			suite.Kubectl().Exec(ctx, "delete", "pod", gpuDriversTestPod, "-n", namespace, "--ignore-not-found")

			suite.Kubectl().MustExec(ctx, "run", gpuDriversTestPod, "-n", namespace,
				"--image=busybox:latest",
				"--restart=Never",
				"--overrides", `{"spec":{"containers":[{"name":"gpu-drivers-test","image":"busybox:latest","command":["find","/usr/lib/wsl/drivers","-name","libnvwgf2umx.so"],"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}`,
				"--timeout=60s")

			suite.Cluster().ExpectPodToBeCompleted(gpuDriversTestPod, namespace)

			output = suite.Kubectl().MustExec(ctx, "logs", gpuDriversTestPod, "-n", namespace)

			Expect(output).To(ContainSubstring("libnvwgf2umx.so"), "workload should have access to libnvwgf2umx.so for OpenGL support")

			// Cleanup test pods
			suite.Kubectl().Exec(ctx, "delete", "pod", gpuLibsTestPod, "-n", namespace, "--ignore-not-found")
			suite.Kubectl().Exec(ctx, "delete", "pod", gpuDriversTestPod, "-n", namespace, "--ignore-not-found")
		})

	})

	Describe("disables cleanly", func() {
		It("disables the addon", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "disable", "gpu-node", "-o")

			Expect(output).To(ContainSubstring("'k2s addons disable gpu-node' completed"))
		})

		It("removes the gpu-node namespace", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "namespace", "gpu-node", "--ignore-not-found")

			Expect(output).To(BeEmpty())
		})

		It("removes GPU node labels", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "gpu=true", "-o", "jsonpath={.items[*].metadata.name}")

			Expect(output).To(BeEmpty())
		})
	})
})
