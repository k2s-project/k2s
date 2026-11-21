// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package timeslicing

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	"github.com/k2s-project/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	testNamespace    = "default"
	sliceTestTimeout = time.Minute * 30
	timeSlices       = 4
	alpineImage      = "docker.io/library/alpine:3.21" // must match workloads/gpu-slice-test.yaml
)

var (
	suite             *framework.K2sTestSuite
	testFailed        = false
	sliceTestYamlPath string
)

func TestGpuNodeTimeSlicing(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "gpu-node Addon Time-Slicing Acceptance Tests", Label("addon", "addon-diverse", "acceptance", "setup-required", "invasive", "gpu-node-timeslicing", "system-running", "nvidia"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(sliceTestTimeout))

	sliceTestYamlPath = filepath.Join(suite.RootDir(), "k2s", "test", "e2e", "addons", "gpu-node", "workloads", "gpu-slice-test.yaml")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "gpu-node", "-o")

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("'gpu-node' addon time-slicing", Ordered, func() {
	It("enables the addon with time-slices", func(ctx context.Context) {
		output := suite.K2sCli().MustExec(ctx, "addons", "enable", "gpu-node", "--time-slices", fmt.Sprint(timeSlices), "-o")

		Expect(output).To(SatisfyAll(
			MatchRegexp("Running 'enable' for 'gpu-node' addon"),
			MatchRegexp("'k2s addons enable gpu-node' completed"),
		))
	})

	It("reports correct GPU slot count", func(ctx context.Context) {
		output := suite.K2sCli().MustExec(ctx, "addons", "status", "gpu-node", "-o", "json")

		var addonStatus status.AddonPrintStatus
		Expect(json.Unmarshal([]byte(output), &addonStatus)).To(Succeed())

		prop := findProp(addonStatus.Props, "GpuAllocatable")
		Expect(prop).NotTo(BeNil(), "GpuAllocatable prop not found in status output")
		Expect(prop.Value).To(BeTrue())
		Expect(prop.Message).NotTo(BeNil())
		Expect(*prop.Message).To(MatchRegexp(fmt.Sprintf(`%d GPU slots? available`, timeSlices)))
	})

	It("runs two GPU pods concurrently", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "image", "pull", alpineImage, "-o")

		suite.Kubectl().MustExec(ctx, "delete", "pod", "gpu-test-1", "gpu-test-2", "-n", testNamespace, "--ignore-not-found")
		suite.Kubectl().MustExec(ctx, "apply", "-f", sliceTestYamlPath)

		suite.Cluster().ExpectPodToBeCompleted("gpu-test-1", testNamespace)
		suite.Cluster().ExpectPodToBeCompleted("gpu-test-2", testNamespace)
	})

	It("both pods executed successfully", func(ctx context.Context) {
		log1 := suite.Kubectl().MustExec(ctx, "logs", "gpu-test-1", "-n", testNamespace)
		log2 := suite.Kubectl().MustExec(ctx, "logs", "gpu-test-2", "-n", testNamespace)

		Expect(log1).To(ContainSubstring("gpu-test-1 got GPU slot"))
		Expect(log2).To(ContainSubstring("gpu-test-2 got GPU slot"))
	})

	It("GpuInUse is zero after pods complete", func(ctx context.Context) {
		output := suite.K2sCli().MustExec(ctx, "addons", "status", "gpu-node", "-o", "json")

		var addonStatus status.AddonPrintStatus
		Expect(json.Unmarshal([]byte(output), &addonStatus)).To(Succeed())

		prop := findProp(addonStatus.Props, "GpuInUse")
		Expect(prop).NotTo(BeNil(), "GpuInUse prop not found in status output")
		Expect(prop.Message).NotTo(BeNil())
		Expect(*prop.Message).To(MatchRegexp(`0 of \d+ GPU slots? in use`))
	})

	It("cleans up test pods", func(ctx context.Context) {
		suite.Kubectl().MustExec(ctx, "delete", "pod", "gpu-test-1", "gpu-test-2", "-n", testNamespace, "--ignore-not-found")
	})
})

func findProp(props []status.AddonStatusProp, name string) *status.AddonStatusProp {
	for i := range props {
		if props[i].Name == name {
			return &props[i]
		}
	}
	return nil
}
