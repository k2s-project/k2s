// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier:   MIT
package systemrunning

import (
	"context"
	"encoding/json"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/status"

	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/types"

	"k8s.io/apimachinery/pkg/api/resource"

	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/regex"
)

const (
	ageRegex     = `\d+[dhms](\d+[dhms])*`
	readyRegex   = `\d+/\d+`
	osRegex      = "((w)|(W)indows)|((l)|(L)inux)"
	runtimeRegex = "(cri-o|containerd)"
	bytesRegex   = `[0-9]+\w{0,2}B`
)

var suite *framework.K2sTestSuite

func isPositiveStorageCapacity(value string) (bool, error) {
	quantity, err := resource.ParseQuantity(value)
	if err != nil {
		return false, err
	}
	return quantity.Sign() > 0, nil
}

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "status CLI Command Acceptance Tests", Label("cli", "status", "acceptance", "setup-required", "invasive", "setup=k2s", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("status", Ordered, func() {
	Context("default output", func() {
		var output string

		BeforeAll(func(ctx context.Context) {
			output = regex.StripAnsi(suite.K2sCli().MustExec(ctx, "status"))
		})

		It("prints a header", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("K2s SYSTEM STATUS"))
		})

		It("prints setup", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("Setup: .+%s.+,", suite.SetupInfo().RuntimeConfig.InstallConfig().SetupName()))
		})

		It("prints version", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("Version: .+%s.+", regex.VersionRegex))
		})

		It("prints info that the system is running", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("The system is running"))
		})

		It("prints K8s server version", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("K8s server version: .+%s.+", regex.VersionRegex))
		})

		It("prints K8s client version", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("K8s client version: .+%s.+", regex.VersionRegex))
		})

		It("prints short node info", func(ctx context.Context) {
			matchers := []types.GomegaMatcher{
				MatchRegexp(`STATUS.+\|.+NAME.+\|.+ROLE.+\|.+AGE.+\|.+VERSION|.+CPUs|.+RAM|.+DISK`),
				MatchRegexp("Ready.+\\|.+%s.+\\|.+control-plane.+\\|.+%s.+\\|.+%s.+\\|.+[0-9]+.+\\|.+%s.+\\|.+%s", suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname(), ageRegex, regex.VersionRegex, bytesRegex, bytesRegex),
			}

			if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
				matchers = append(matchers, MatchRegexp("Ready.+\\|.+%s.+\\|.+worker.+\\|.+%s.+\\|.+%s", suite.SetupInfo().WinNodeName, ageRegex, regex.VersionRegex))
			}

			Expect(output).To(SatisfyAll(matchers...))
		})

		It("states that nodes are ready", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("All nodes are ready"))
		})

		It("prints short system Pods info", func(ctx context.Context) {
			Expect(output).To(SatisfyAll(
				MatchRegexp(`STATUS.+\|.+NAME.+\|.+READY.+\|.+RESTARTS.+\|.+AGE`),
				MatchRegexp("Running.+\\|.+kube-flannel-.+\\|.+%s.+\\|.+\\d+.+\\|.+%s", readyRegex, ageRegex),
				MatchRegexp("Running.+\\|.+coredns-.+\\|.+%s.+\\|.+\\d+.+\\|.+%s", readyRegex, ageRegex),
				MatchRegexp("Running.+\\|.+etcd-%s.+\\|.+%s.+\\|.+\\d+.+\\|.+%s", suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname(), readyRegex, ageRegex),
				MatchRegexp("Running.+\\|.+kube-apiserver-%s.+\\|.+%s.+\\|.+\\d+.+\\|.+%s", suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname(), readyRegex, ageRegex),
				MatchRegexp("Running.+\\|.+kube-controller-manager-%s.+\\|.+%s.+\\|.+\\d+.+\\|.+%s", suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname(), readyRegex, ageRegex),
				MatchRegexp("Running.+\\|.+kube-proxy-.+\\|.+%s.+\\|.+\\d+.+\\|.+%s", readyRegex, ageRegex),
				MatchRegexp("Running.+\\|.+kube-scheduler-%s.+\\|.+%s.+\\|.+\\d+.+\\|.+%s", suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname(), readyRegex, ageRegex),
			))
		})

		It("states that system Pods are running", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("All essential Pods are running"))
		})
	})

	Context("extended output", func() {
		var output string

		BeforeAll(func(ctx context.Context) {
			output = regex.StripAnsi(suite.K2sCli().MustExec(ctx, "status", "-o", "wide"))
		})

		It("prints a header", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("K2s SYSTEM STATUS"))
		})

		It("prints setup", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("Setup: .+%s.+,", suite.SetupInfo().RuntimeConfig.InstallConfig().SetupName()))
		})

		It("prints the version", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("Version: .+%s.+", regex.VersionRegex))
		})

		It("prints info that the system is running", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("The system is running"))
		})

		It("prints K8s server version", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("K8s server version: .+%s.+", regex.VersionRegex))
		})

		It("prints K8s client version", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("K8s client version: .+%s.+", regex.VersionRegex))
		})

		It("prints extended node info", func(ctx context.Context) {
			matchers := []types.GomegaMatcher{
				MatchRegexp(`STATUS.+\\|.+NAME.+\|.+ROLE.+\|.+AGE.+\|.+VERSION.+\|.+CPUs.+\|.+RAM.+\|.+DISK.+\|.+INTERNAL-IP.+\|.+OS-IMAGE.+\|.+KERNEL-VERSION.+\|.+CONTAINER-RUNTIME`),
				MatchRegexp("Ready.+\\|.+%s.+\\|.+control-plane.+\\|.+%s.+\\|.+%s.+\\|.+[0-9]+,+\\|.+%s.+\\|.+%s.+\\|.+%s.+\\|.+%s.+\\|.+.+\\|.+%s",
					suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname(), ageRegex, regex.VersionRegex, bytesRegex, bytesRegex, regex.IpAddressRegex, osRegex, runtimeRegex),
			}

			if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
				matchers = append(matchers, MatchRegexp("Ready.+\\|.+%s.+\\|.+worker.+\\|.+%s.+\\|.+%s.+\\|.+[0-9]+,+\\|.+%s.+\\|.+%s.+\\|.+%s.+\\|.+%s.+\\|.+.+\\|.+%s",
					suite.SetupInfo().WinNodeName, ageRegex, regex.VersionRegex, bytesRegex, bytesRegex, regex.IpAddressRegex, osRegex, runtimeRegex))
			}

			Expect(output).To(SatisfyAll(matchers...))
		})

		It("states that nodes are ready", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("All nodes are ready"))
		})

		It("prints extended system Pods info", func(ctx context.Context) {
			Expect(output).To(SatisfyAll(
				MatchRegexp(`STATUS.+\|.+NAMESPACE.+\|.+NAME.+\|.+READY.+\|.+RESTARTS.+\|.+AGE.+\|.+IP.+\|.+NODE`),
				MatchRegexp("Running.+\\|.+kube-flannel.+\\|.+kube-flannel-.+\\|.+%s.+\\|.+\\d+.+\\|.+%s.+\\|.+%s.+\\|.+%s", readyRegex, ageRegex, regex.IpAddressRegex, suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname()),
				MatchRegexp("Running.+\\|.+kube-system.+\\|.+coredns-.+\\|.+%s.+\\|.+\\d+.+\\|.+%s.+\\|.+%s.+\\|.+%s", readyRegex, ageRegex, regex.IpAddressRegex, suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname()),
				MatchRegexp("Running.+\\|.+kube-system.+\\|.+etcd-%s.+\\|.+%s.+\\|.+\\d+.+\\|.+%s.+\\|.+%s.+\\|.+%s", suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname(), readyRegex, ageRegex, regex.IpAddressRegex, suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname()),
				MatchRegexp("Running.+\\|.+kube-system.+\\|.+kube-apiserver-%s.+\\|.+%s.+\\|.+\\d+.+\\|.+%s.+\\|.+%s.+\\|.+%s", suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname(), readyRegex, ageRegex, regex.IpAddressRegex, suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname()),
				MatchRegexp("Running.+\\|.+kube-system.+\\|.+kube-controller-manager-%s.+\\|.+%s.+\\|.+\\d+.+\\|.+%s.+\\|.+%s.+\\|.+%s", suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname(), readyRegex, ageRegex, regex.IpAddressRegex, suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname()),
				MatchRegexp("Running.+\\|.+kube-system.+\\|.+kube-proxy-.+\\|.+%s.+\\|.+\\d+.+\\|.+%s.+\\|.+%s.+\\|.+%s", readyRegex, ageRegex, regex.IpAddressRegex, suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname()),
				MatchRegexp("Running.+\\|.+kube-system.+\\|.+kube-scheduler-%s.+\\|.+%s.+\\|.+\\d+.+\\|.+%s.+\\|.+%s.+\\|.+%s", suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname(), readyRegex, ageRegex, regex.IpAddressRegex, suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname()),
			))
		})

		It("states that system Pods are running", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("All essential Pods are running"))
		})
	})

	Context("JSON output", func() {
		var status status.PrintStatus

		BeforeAll(func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "status", "-o", "json")

			Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())
		})

		It("contains no error", func() {
			Expect(status.Error).To(BeNil())
		})

		It("contains setup info", func() {
			Expect(status.SetupInfo.Name).To(Equal(suite.SetupInfo().RuntimeConfig.InstallConfig().SetupName()))
			Expect(status.SetupInfo.Version).To(MatchRegexp(regex.VersionRegex))
			Expect(status.SetupInfo.LinuxOnly).To(Equal(suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly()))
		})

		It("contains K8s version info", func() {
			Expect(status.K8sVersionInfo.K8sClientVersion).To(MatchRegexp(regex.VersionRegex))
			Expect(status.K8sVersionInfo.K8sServerVersion).To(MatchRegexp(regex.VersionRegex))
		})

		It("contains info that the system is running", func() {
			Expect(status.RunningState.IsRunning).To(BeTrue())
			Expect(status.RunningState.Issues).To(BeEmpty())
		})

		It("contains nodes info", func() {
			expectedNodesLength := 1
			nodesMatchers := []types.GomegaMatcher{
				SatisfyAll(HaveField("Role", "control-plane"), HaveField("Name", suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname())),
			}

			if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
				expectedNodesLength = 2
				nodesMatchers = append(nodesMatchers, SatisfyAll(HaveField("Role", "worker"), HaveField("Name", suite.SetupInfo().WinNodeName)))
			}

			Expect(status.Nodes).To(HaveLen(expectedNodesLength))
			Expect(status.Nodes).To(ConsistOf(nodesMatchers))
			Expect(status.Nodes).To(HaveEach(SatisfyAll(
				HaveField("Status", "Ready"),
				HaveField("Age", MatchRegexp(ageRegex)),
				HaveField("KubeletVersion", MatchRegexp(regex.VersionRegex)),
				HaveField("KernelVersion", MatchRegexp(".+")),
				HaveField("OsImage", MatchRegexp(osRegex)),
				HaveField("ContainerRuntime", MatchRegexp(runtimeRegex)),
				HaveField("InternalIp", MatchRegexp(regex.IpAddressRegex)),
				HaveField("IsReady", BeTrue()),
				HaveField("Capacity", SatisfyAll(
					HaveField("Cpu", MatchRegexp("[0-9]+")),
					HaveField("Memory", MatchRegexp("[0-9]+Ki")),
					HaveField("Storage", WithTransform(isPositiveStorageCapacity, BeTrue())),
				)),
			)))
		})

		It("contains Pods info", func() {
			Expect(len(status.Pods)).To(BeNumerically(">=", 7))
			Expect(status.Pods).To(ContainElements(
				SatisfyAll(HaveField("Namespace", "kube-flannel"), HaveField("Name", MatchRegexp("kube-flannel-"))),
				SatisfyAll(HaveField("Namespace", "kube-system"), HaveField("Name", MatchRegexp("coredns-"))),
				SatisfyAll(HaveField("Namespace", "kube-system"), HaveField("Name", "etcd-"+suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname())),
				SatisfyAll(HaveField("Namespace", "kube-system"), HaveField("Name", "kube-apiserver-"+suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname())),
				SatisfyAll(HaveField("Namespace", "kube-system"), HaveField("Name", "kube-controller-manager-"+suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname())),
				SatisfyAll(HaveField("Namespace", "kube-system"), HaveField("Name", MatchRegexp("kube-proxy-"))),
				SatisfyAll(HaveField("Namespace", "kube-system"), HaveField("Name", "kube-scheduler-"+suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname())),
			))
			Expect(status.Pods).To(HaveEach(SatisfyAll(
				HaveField("Status", "Running"),
				HaveField("Ready", MatchRegexp(`\d+/\d+`)),
				HaveField("Restarts", MatchRegexp(`\d+`)),
				HaveField("Age", MatchRegexp(ageRegex)),
				HaveField("Ip", MatchRegexp(regex.IpAddressRegex)),
				HaveField("Node", MatchRegexp("(%s)|(%s)", suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname(), suite.SetupInfo().WinNodeName)),
				HaveField("IsRunning", true),
			)))
		})
	})
})
