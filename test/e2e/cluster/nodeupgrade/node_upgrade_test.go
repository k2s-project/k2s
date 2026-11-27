// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package nodeupgrade

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/core/clusterconfig"
	"github.com/k2s-project/k2s/test/framework"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/util/retry"
)

const (
	envTargetNode      = "K2S_NODE_UPGRADE_NODE"
	envFullPackage     = "K2S_NODE_UPGRADE_FULL_PACKAGE"
	envBasePackage     = "K2S_NODE_UPGRADE_BASE_PACKAGE"
	envTargetPackage   = "K2S_NODE_UPGRADE_TARGET_PACKAGE"
	envPackageProxy    = "K2S_NODE_UPGRADE_PROXY"
	envWorkloadImage   = "K2S_NODE_UPGRADE_WORKLOAD_IMAGE"
	workloadWaitWindow = 10 * time.Minute
)

var (
	suite        *framework.K2sTestSuite
	client       kubernetes.Interface
	configDir    string
	workDir      string
	targetWorker clusterconfig.Node
)

func TestNodeUpgrade(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Linux Worker Node Upgrade Acceptance Tests",
		Label("cli", "acceptance", "setup-required", "system-running", "node-upgrade", "disruptive", "internet-required"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	if runtime.GOOS != "windows" {
		Skip("Node upgrade with system node package is supported only from the Windows K2s host")
	}
	suite = framework.Setup(ctx, framework.SystemMustBeRunning,
		framework.ClusterTestStepTimeout(40*time.Minute),
		framework.ClusterTestStepPollInterval(500*time.Millisecond))
	DeferCleanup(suite.TearDown)

	if installCfg := suite.SetupInfo().RuntimeConfig.InstallConfig(); installCfg != nil && installCfg.LinuxOnly() {
		Skip("Node upgrade via 'k2s system upgrade --node' is not available on Linux-only setups")
	}

	configDir = suite.SetupInfo().Config.Host().K2sSetupConfigDir()
	config, err := clusterconfig.Read(configDir)
	Expect(err).NotTo(HaveOccurred())
	overrideNode := strings.TrimSpace(os.Getenv(envTargetNode))
	if overrideNode == "" && (config == nil || !slices.ContainsFunc(config.Nodes, isManagedLinuxWorker)) {
		Skip("Skipping node upgrade tests: no managed Linux worker node found in cluster.json")
	}
	targetWorker, err = selectTargetLinuxWorker(config, overrideNode)
	Expect(err).NotTo(HaveOccurred())

	client, err = kubernetes.NewForConfig(suite.Cluster().Client().Resources().GetConfig())
	Expect(err).NotTo(HaveOccurred())

	workDir, err = os.MkdirTemp("", "k2s-node-upgrade-e2e-*")
	Expect(err).NotTo(HaveOccurred())
	DeferCleanup(func() {
		Expect(os.RemoveAll(workDir)).To(Succeed())
	})
})

var _ = Describe("node package and node delta package rejections", Serial, Label("node-package", "node-delta-package", "node-upgrade-rejections"), func() {
	It("rejects invalid k2s system package --node-package invocations", func(ctx SpecContext) {
		outDir := filepath.Join(workDir, "reject-node-pkg")
		Expect(os.MkdirAll(outDir, 0o755)).To(Succeed())

		output := rejectSystemPackage(ctx, "--node-package", "-d", outDir, "-n", "missing-os.zip")
		Expect(output).To(ContainSubstring("--os is required"))

		output = rejectSystemPackage(ctx, "--node-package", "--os", "alpine3", "-d", outDir, "-n", "bad-os.zip")
		Expect(output).To(ContainSubstring("not supported"))

		output = rejectSystemPackage(ctx, "--node-package", "--os", "debian13", "--arch", "riscv64", "-d", outDir, "-n", "bad-arch.zip")
		Expect(output).To(ContainSubstring("not supported"))

		output = rejectSystemPackage(ctx, "--node-package", "--os", "debian13", "--arch", "arm64", "-d", outDir, "-n", "arm64-on-win.zip")
		Expect(output).To(ContainSubstring("only support amd64"))

		output = rejectSystemPackage(ctx, "--node-package", "--os", "debian13", "-n", "missing-dir.zip")
		Expect(output).To(ContainSubstring("target-dir"))

		output = rejectSystemPackage(ctx, "--node-package", "--os", "debian13", "-d", outDir)
		Expect(output).To(ContainSubstring("name"))
	})

	It("rejects invalid k2s system package --node-package --delta-package invocations", func(ctx SpecContext) {
		fixtureDir := filepath.Join(workDir, "reject-node-delta")
		outDir := filepath.Join(fixtureDir, "out")
		Expect(os.MkdirAll(outDir, 0o755)).To(Succeed())

		validDeb12 := filepath.Join(fixtureDir, "deb12.zip")
		validDeb13 := filepath.Join(fixtureDir, "deb13.zip")
		noPackages := filepath.Join(fixtureDir, "no-packages.zip")
		multiOSOld := filepath.Join(fixtureDir, "multi-os-old.zip")
		multiOSNew := filepath.Join(fixtureDir, "multi-os-new.zip")

		Expect(writeZipFixture(validDeb12, map[string][]byte{
			"packages/debian12/kubernetes/kubelet_1.35.0_amd64.deb": []byte("deb12-v1"),
		})).To(Succeed())
		Expect(writeZipFixture(validDeb13, map[string][]byte{
			"packages/debian13/kubernetes/kubelet_1.35.0_amd64.deb": []byte("deb13-v1"),
		})).To(Succeed())
		Expect(writeZipFixture(noPackages, map[string][]byte{
			"images/pause.tar": []byte("img"),
		})).To(Succeed())
		Expect(writeZipFixture(multiOSOld, map[string][]byte{
			"packages/debian12/kubernetes/kubelet_1.35.0_amd64.deb": []byte("deb12-v1"),
			"packages/debian13/kubernetes/kubelet_1.35.0_amd64.deb": []byte("deb13-v1"),
		})).To(Succeed())
		Expect(writeZipFixture(multiOSNew, map[string][]byte{
			"packages/debian12/kubernetes/kubelet_1.35.0_amd64.deb": []byte("deb12-v2"),
			"packages/debian13/kubernetes/kubelet_1.35.0_amd64.deb": []byte("deb13-v2"),
		})).To(Succeed())

		missingZip := filepath.Join(fixtureDir, "does-not-exist.zip")

		output := rejectSystemPackage(ctx, "--node-package", "--delta-package",
			"--package-version-to", validDeb13, "-d", outDir, "-n", "delta.zip")
		Expect(output).To(ContainSubstring("--package-version-from is required"))

		output = rejectSystemPackage(ctx, "--node-package", "--delta-package",
			"--package-version-from", validDeb13, "-d", outDir, "-n", "delta.zip")
		Expect(output).To(ContainSubstring("--package-version-to is required"))

		output = rejectSystemPackage(ctx, "--node-package", "--delta-package",
			"--package-version-from", missingZip, "--package-version-to", validDeb13,
			"-d", outDir, "-n", "delta.zip")
		Expect(output).To(ContainSubstring("InputPackageOne not found"))

		output = rejectSystemPackage(ctx, "--node-package", "--delta-package",
			"--package-version-from", validDeb13, "--package-version-to", missingZip,
			"-d", outDir, "-n", "delta.zip")
		Expect(output).To(ContainSubstring("InputPackageTwo not found"))

		output = rejectSystemPackage(ctx, "--node-package", "--delta-package",
			"--package-version-from", validDeb13, "--package-version-to", validDeb13,
			"-d", outDir, "-n", "delta.tar")
		Expect(output).To(ContainSubstring(".zip"))

		output = rejectSystemPackage(ctx, "--node-package", "--delta-package",
			"--package-version-from", noPackages, "--package-version-to", validDeb13,
			"-d", outDir, "-n", "delta-nopkgs.zip")
		Expect(output).To(ContainSubstring("packages"))

		output = rejectSystemPackage(ctx, "--node-package", "--delta-package",
			"--package-version-from", validDeb12, "--package-version-to", validDeb13,
			"-d", outDir, "-n", "delta-disjoint.zip")
		Expect(output).To(ContainSubstring("No common OS folder"))

		output = rejectSystemPackage(ctx, "--node-package", "--delta-package",
			"--package-version-from", multiOSOld, "--package-version-to", multiOSNew,
			"-d", outDir, "-n", "delta-ambiguous.zip")
		Expect(output).To(ContainSubstring("Multiple common OS folders"))

		output = rejectSystemPackage(ctx, "--node-package", "--delta-package",
			"--package-version-from", validDeb13, "--package-version-to", validDeb13,
			"--os", "debian12", "-d", outDir, "-n", "delta-missing-os.zip")
		Expect(output).To(ContainSubstring("not found"))
	})
})

var _ = Describe("node delta package creation and manifest contract", Serial, Label("node-delta-package"), func() {
	It("creates a valid node delta package with added, changed, and removed debs and images", func(ctx SpecContext) {
		contractDir := filepath.Join(workDir, "delta-contract")
		outDir := filepath.Join(contractDir, "out")
		Expect(os.MkdirAll(outDir, 0o755)).To(Succeed())

		baseZip := filepath.Join(contractDir, "debian13-node-v1.zip")
		targetZip := filepath.Join(contractDir, "debian13-node-v2.zip")
		deltaName := "debian13-node-delta-v1-to-v2.zip"
		deltaZip := filepath.Join(outDir, deltaName)

		Expect(writeZipFixture(baseZip, map[string][]byte{
			"packages/debian13/kubernetes/kubeadm_1.35.0_amd64.deb":   []byte("kubeadm-unchanged"),
			"packages/debian13/kubernetes/kubelet_1.35.0_amd64.deb":   []byte("kubelet-v1"),
			"packages/debian13/kubernetes/deprecated_1.0.0_amd64.deb": []byte("deprecated-v1"),
			"images/coredns.tar":        []byte("coredns-unchanged"),
			"images/pause.tar":          []byte("pause-v1"),
			"images/obsolete-image.tar": []byte("obsolete-v1"),
		})).To(Succeed())
		Expect(writeZipFixture(targetZip, map[string][]byte{
			"packages/debian13/kubernetes/kubeadm_1.35.0_amd64.deb": []byte("kubeadm-unchanged"),
			"packages/debian13/kubernetes/kubelet_1.35.0_amd64.deb": []byte("kubelet-v2-updated"),
			"packages/debian13/buildah/buildah_1.38.0_amd64.deb":    []byte("buildah-added"),
			"images/coredns.tar": []byte("coredns-unchanged"),
			"images/pause.tar":   []byte("pause-v2-updated"),
			"images/flannel.tar": []byte("flannel-added"),
		})).To(Succeed())

		suite.K2sCli().MustExec(ctx, "system", "package",
			"--node-package", "--delta-package",
			"--package-version-from", baseZip,
			"--package-version-to", targetZip,
			"-d", outDir,
			"-n", deltaName,
			"-o")

		archive, err := inspectNodePackageZip(deltaZip)
		Expect(err).NotTo(HaveOccurred())
		Expect(validateNodeDeltaPackage(archive, "debian13")).To(Succeed())

		m := archive.DeltaManifest
		Expect(m.BasePackage).To(Equal(filepath.Base(baseZip)))
		Expect(m.TargetPackage).To(Equal(filepath.Base(targetZip)))
		Expect(sortedCopy(m.DebianPackageDiff.Added)).To(Equal([]string{"buildah/buildah_1.38.0_amd64.deb"}))
		Expect(sortedCopy(m.DebianPackageDiff.Changed)).To(Equal([]string{"kubernetes/kubelet_1.35.0_amd64.deb"}))
		Expect(sortedCopy(m.DebianPackageDiff.Removed)).To(Equal([]string{"kubernetes/deprecated_1.0.0_amd64.deb"}))
		Expect(mapKeys(m.ContainerImageDiff.AddedImages)).To(Equal([]string{"flannel.tar"}))
		Expect(mapKeys(m.ContainerImageDiff.ChangedImages)).To(Equal([]string{"pause.tar"}))
		Expect(mapKeys(m.ContainerImageDiff.RemovedImages)).To(Equal([]string{"obsolete-image.tar"}))

		// Verify unchanged and removed payloads are excluded from the delta archive.
		Expect(archive.Entries).NotTo(HaveKey("packages/debian13/kubernetes/kubeadm_1.35.0_amd64.deb"))
		Expect(archive.Entries).NotTo(HaveKey("packages/debian13/kubernetes/deprecated_1.0.0_amd64.deb"))
		Expect(archive.Entries).NotTo(HaveKey("images/coredns.tar"))
		Expect(archive.Entries).NotTo(HaveKey("images/obsolete-image.tar"))
	})

	It("supports explicit --os selection for multi-OS node packages and handles identical packages with zero diff", func(ctx SpecContext) {
		contractDir := filepath.Join(workDir, "delta-multi-os")
		outDir := filepath.Join(contractDir, "out")
		Expect(os.MkdirAll(outDir, 0o755)).To(Succeed())

		baseZip := filepath.Join(contractDir, "multi-base.zip")
		targetZip := filepath.Join(contractDir, "multi-target.zip")
		Expect(writeZipFixture(baseZip, map[string][]byte{
			"packages/debian12/kubernetes/kubelet_1.35.0_amd64.deb": []byte("deb12-v1"),
			"packages/debian13/kubernetes/kubelet_1.35.0_amd64.deb": []byte("deb13-v1"),
			"images/pause.tar": []byte("pause-same"),
		})).To(Succeed())
		Expect(writeZipFixture(targetZip, map[string][]byte{
			"packages/debian12/kubernetes/kubelet_1.35.0_amd64.deb": []byte("deb12-v2"),
			"packages/debian13/kubernetes/kubelet_1.35.0_amd64.deb": []byte("deb13-v2"),
			"images/pause.tar": []byte("pause-same"),
		})).To(Succeed())

		multiDeltaName := "multi-explicit-debian13.zip"
		suite.K2sCli().MustExec(ctx, "system", "package",
			"--node-package", "--delta-package",
			"--package-version-from", baseZip,
			"--package-version-to", targetZip,
			"--os", "debian13",
			"-d", outDir,
			"-n", multiDeltaName,
			"-o")

		multiArchive, err := inspectNodePackageZip(filepath.Join(outDir, multiDeltaName))
		Expect(err).NotTo(HaveOccurred())
		Expect(validateNodeDeltaPackage(multiArchive, "debian13")).To(Succeed())
		Expect(multiArchive.OSDirs).To(Equal([]string{"debian13"}))
		Expect(sortedCopy(multiArchive.DeltaManifest.DebianPackageDiff.Changed)).To(Equal([]string{"kubernetes/kubelet_1.35.0_amd64.deb"}))
		Expect(multiArchive.DeltaManifest.ContainerImageDiff.AddedCount).To(Equal(0))
		Expect(multiArchive.DeltaManifest.ContainerImageDiff.ChangedCount).To(Equal(0))
		Expect(multiArchive.DeltaManifest.ContainerImageDiff.RemovedCount).To(Equal(0))

		noopDeltaName := "identical-noop-delta.zip"
		suite.K2sCli().MustExec(ctx, "system", "package",
			"--node-package", "--delta-package",
			"--package-version-from", targetZip,
			"--package-version-to", targetZip,
			"--os", "debian13",
			"-d", outDir,
			"-n", noopDeltaName,
			"-o")

		noopArchive, err := inspectNodePackageZip(filepath.Join(outDir, noopDeltaName))
		Expect(err).NotTo(HaveOccurred())
		Expect(validateNodeDeltaPackage(noopArchive, "debian13")).To(Succeed())
		Expect(noopArchive.DeltaManifest.AddedCount).To(Equal(0))
		Expect(noopArchive.DeltaManifest.ChangedCount).To(Equal(0))
		Expect(noopArchive.DeltaManifest.RemovedCount).To(Equal(0))
	})
})

var _ = Describe("node upgrade rejections", Serial, Label("node-upgrade-rejections"), func() {
	It("rejects unpaired flags, invalid paths, unknown or unmanaged nodes, and malformed node packages without mutating cluster state", func(ctx SpecContext) {
		rejectDir := filepath.Join(workDir, "reject-node-upgrade")
		Expect(os.MkdirAll(rejectDir, 0o755)).To(Succeed())

		nonZipFile := filepath.Join(rejectDir, "not-a-zip.txt")
		Expect(os.WriteFile(nonZipFile, []byte("plain text"), 0o600)).To(Succeed())

		missingPackagesZip := filepath.Join(rejectDir, "missing-packages.zip")
		Expect(writeZipFixture(missingPackagesZip, map[string][]byte{
			"images/pause.tar": []byte("img"),
		})).To(Succeed())

		wrongOSZip := filepath.Join(rejectDir, "wrong-os.zip")
		Expect(writeZipFixture(wrongOSZip, map[string][]byte{
			"packages/debian99/kubernetes/kubelet_1.35.0_amd64.deb": []byte("deb"),
		})).To(Succeed())

		clusterDeltaJSON, err := json.Marshal(map[string]any{
			"ManifestVersion": "2.0",
			"DeltaType":       "cluster",
		})
		Expect(err).NotTo(HaveOccurred())
		wrongDeltaTypeZip := filepath.Join(rejectDir, "cluster-delta.zip")
		Expect(writeZipFixture(wrongDeltaTypeZip, map[string][]byte{
			"delta-manifest.json": clusterDeltaJSON,
			"packages/debian13/kubernetes/kubelet_1.35.0_amd64.deb": []byte("deb"),
		})).To(Succeed())

		nodesBefore, err := client.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
		Expect(err).NotTo(HaveOccurred())
		descriptorBefore := readDescriptor()
		workerBefore := getNode(ctx, targetWorker.Name)
		Expect(isNodeReady(workerBefore)).To(BeTrue(), "target worker %s must be Ready before rejection checks", targetWorker.Name)
		kubeletBefore := readKubeletState(ctx, targetWorker)

		By("rejecting unpaired --node and --path flags")
		output := rejectNodeUpgrade(ctx, "--node", targetWorker.Name)
		Expect(output).To(ContainSubstring("--node and --path must be specified together"))

		output = rejectNodeUpgrade(ctx, "--path", wrongOSZip)
		Expect(output).To(ContainSubstring("--node and --path must be specified together"))

		By("rejecting missing and non-.zip package paths")
		output = rejectNodeUpgrade(ctx, "--node", targetWorker.Name, "--path", filepath.Join(rejectDir, "nonexistent.zip"), "-o")
		Expect(output).To(ContainSubstring("does not exist"))

		output = rejectNodeUpgrade(ctx, "--node", targetWorker.Name, "--path", nonZipFile, "-o")
		Expect(output).To(ContainSubstring("must be a .zip file"))

		By("rejecting an unknown node name")
		missingNode := uniqueName("missing-node")
		output = rejectNodeUpgrade(ctx, "--node", missingNode, "--path", wrongOSZip, "-o")
		Expect(output).To(ContainSubstring("not found in cluster"))

		By("rejecting an unready synthetic Node and a Ready unmanaged Node absent from cluster.json")
		syntheticName := uniqueName("unmanaged-node")
		syntheticNode, err := client.CoreV1().Nodes().Create(ctx, &corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name:   syntheticName,
				Labels: map[string]string{"kubernetes.io/os": "linux"},
			},
			Spec: corev1.NodeSpec{
				Taints: []corev1.Taint{{
					Key:    metadataKey,
					Value:  "synthetic",
					Effect: corev1.TaintEffectNoSchedule,
				}},
			},
		}, metav1.CreateOptions{})
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(func(ctx SpecContext) {
			deleteSyntheticNode(ctx, syntheticName, syntheticNode.UID)
		}, NodeTimeout(3*time.Minute))

		output = rejectNodeUpgrade(ctx, "--node", syntheticName, "--path", wrongOSZip, "-o")
		Expect(output).To(ContainSubstring("not in Ready state"))

		stopHeartbeat, err := startSyntheticNodeHeartbeat(ctx, client, syntheticNode, syntheticNodeHeartbeatPeriod)
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(stopHeartbeat)
		Eventually(func() bool {
			return isNodeReady(getNode(ctx, syntheticName))
		}, 30*time.Second, 500*time.Millisecond).Should(BeTrue())

		output = rejectNodeUpgrade(ctx, "--node", syntheticName, "--path", wrongOSZip, "-o")
		stopHeartbeat()
		Expect(output).To(ContainSubstring("not found in cluster.json"))

		By("rejecting malformed node packages against the real Ready Linux worker")
		output = rejectNodeUpgrade(ctx, "--node", targetWorker.Name, "--path", missingPackagesZip, "-o")
		Expect(output).To(ContainSubstring("No 'packages' directory found"))

		output = rejectNodeUpgrade(ctx, "--node", targetWorker.Name, "--path", wrongDeltaTypeZip, "-o")
		Expect(output).To(ContainSubstring("Unsupported delta manifest type"))

		output = rejectNodeUpgrade(ctx, "--node", targetWorker.Name, "--path", wrongOSZip, "-o")
		Expect(output).To(ContainSubstring("not found in zip"))

		By("verifying cluster state, cluster.json, and worker kubelet were not mutated")
		Expect(readDescriptor()).To(Equal(descriptorBefore))
		for _, before := range nodesBefore.Items {
			after := getNode(ctx, before.Name)
			Expect(after.UID).To(Equal(before.UID))
			Expect(after.Spec.Unschedulable).To(Equal(before.Spec.Unschedulable))
			Expect(isNodeReady(after)).To(Equal(isNodeReady(&before)))
		}
		kubeletAfter := readKubeletState(ctx, targetWorker)
		Expect(kubeletAfter.Active).To(Equal("active"))
		Expect(kubeletAfter.StartTimestampMonotonic).To(Equal(kubeletBefore.StartTimestampMonotonic))
	})
})

var _ = Describe("end-to-end node system package, node delta package, and node upgrade lifecycle",
	Ordered, Serial, Label("node-package", "node-delta-package", "node-upgrade-full", "node-upgrade-delta"), func() {
		var (
			distKey             string
			controlPlaneName    string
			fullPackagePath     string
			fullArchive         *nodePackageArchive
			deltaPackagePath    string
			deltaArchive        *nodePackageArchive
			derivedPlan         *derivedDeltaPlan
			workloadNamespace   string
			workerPodUID        types.UID
			canaryPodUID        types.UID
			metadataMarkerValue string
		)

		AfterAll(func(ctx SpecContext) {
			if workloadNamespace != "" {
				deleteNamespace(ctx, workloadNamespace)
			}
			if metadataMarkerValue != "" {
				removeTestMetadata(ctx, targetWorker.Name)
			}
		}, NodeTimeout(10*time.Minute))

		It("builds or validates the full node system package for the target Linux worker distribution", Label("node-package"), func(ctx SpecContext) {
			workerNode := getNode(ctx, targetWorker.Name)
			Expect(isNodeReady(workerNode)).To(BeTrue(), "target worker %s must be Ready", targetWorker.Name)
			Expect(workerNode.Spec.Unschedulable).To(BeFalse(), "target worker %s must be schedulable before upgrade tests", targetWorker.Name)

			nodes, err := client.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
			Expect(err).NotTo(HaveOccurred())
			controlPlaneName, err = findLinuxControlPlane(nodes.Items)
			Expect(err).NotTo(HaveOccurred())
			cpNode := getNode(ctx, controlPlaneName)
			Expect(isNodeReady(cpNode)).To(BeTrue(), "control plane %s must be Ready", controlPlaneName)

			By(fmt.Sprintf("detecting Linux distribution on %s worker %s (%s)", targetWorker.NodeType, targetWorker.Name, targetWorker.IpAddress))
			distKey = detectWorkerDistro(ctx, targetWorker)
			GinkgoWriter.Printf("[NodeUpgradeE2E] Target worker=%s (%s) IP=%s user=%s distro=%s controlPlane=%s\n",
				targetWorker.Name, targetWorker.NodeType, targetWorker.IpAddress, targetWorker.Username, distKey, controlPlaneName)

			configuredFull := strings.TrimSpace(os.Getenv(envFullPackage))
			if configuredFull == "" {
				configuredFull = strings.TrimSpace(os.Getenv(envTargetPackage))
			}

			if configuredFull != "" {
				By(fmt.Sprintf("using prebuilt full node package from environment: %s", configuredFull))
				fullPackagePath = configuredFull
			} else {
				pkgDir := filepath.Join(workDir, "full-package")
				pkgName := fmt.Sprintf("%s-node-e2e.zip", distKey)
				fullPackagePath = filepath.Join(pkgDir, pkgName)

				args := []string{
					"system", "package",
					"--node-package",
					"--os", distKey,
					"--target-dir", pkgDir,
					"--name", pkgName,
					"-o",
				}
				if proxyOverride := strings.TrimSpace(os.Getenv(envPackageProxy)); proxyOverride != "" {
					args = append(args, "--proxy", proxyOverride)
				}

				By(fmt.Sprintf("building full node system package for %s via 'k2s system package --node-package'", distKey))
				suite.K2sCli().MustExec(ctx, args...)
			}

			By("inspecting and validating full node package archive structure")
			fullArchive, err = inspectNodePackageZip(fullPackagePath)
			Expect(err).NotTo(HaveOccurred())
			Expect(validateFullNodePackage(fullArchive, distKey)).To(Succeed())
			GinkgoWriter.Printf("[NodeUpgradeE2E] Full node package verified: path=%s size=%d bytes debs=%d images=%d\n",
				fullArchive.Path, fullArchive.SizeBytes, len(fullArchive.DebsByOS[distKey]), len(fullArchive.Images))
		})

		It("upgrades the Linux worker node using the full node system package while preserving metadata and recovering workloads", Label("node-upgrade-full"), func(ctx SpecContext) {
			Expect(fullPackagePath).NotTo(BeEmpty(), "full node package must be available from previous step")
			Expect(fullArchive).NotTo(BeNil())

			By("attaching custom label, annotation, and taint to verify metadata preservation across upgrades")
			metadataMarkerValue = uniqueName("marker")
			attachTestMetadata(ctx, targetWorker.Name, metadataMarkerValue)

			By("deploying a pinned worker workload and control-plane canary workload")
			workloadImage := strings.TrimSpace(os.Getenv(envWorkloadImage))
			if workloadImage == "" {
				workloadImage = defaultWorkloadImage
			}
			ns := uniqueName("node-upgrade-e2e")
			_, err := client.CoreV1().Namespaces().Create(ctx, &corev1.Namespace{
				ObjectMeta: metav1.ObjectMeta{Name: ns},
			}, metav1.CreateOptions{})
			Expect(err).NotTo(HaveOccurred())
			workloadNamespace = ns

			_, err = client.AppsV1().Deployments(workloadNamespace).Create(ctx,
				workerWorkloadDeployment(workloadNamespace, targetWorker.Name, workloadImage), metav1.CreateOptions{})
			Expect(err).NotTo(HaveOccurred())
			_, err = client.AppsV1().Deployments(workloadNamespace).Create(ctx,
				controlPlaneCanaryDeployment(workloadNamespace, controlPlaneName, workloadImage), metav1.CreateOptions{})
			Expect(err).NotTo(HaveOccurred())

			workerPod := waitForSinglePod(ctx, workloadNamespace, "app="+workerWorkloadName, targetWorker.Name, "")
			canaryPod := waitForSinglePod(ctx, workloadNamespace, "app="+canaryWorkloadName, controlPlaneName, "")
			workerPodUID = workerPod.UID
			canaryPodUID = canaryPod.UID

			workerPodUID = executeAndVerifyNodeUpgrade(ctx, nodeUpgradeRunParams{
				mode:              upgradeModeFull,
				packagePath:       fullPackagePath,
				distKey:           distKey,
				controlPlaneName:  controlPlaneName,
				workloadNamespace: workloadNamespace,
				prevWorkerPodUID:  workerPodUID,
				canaryPodUID:      canaryPodUID,
				metadataValue:     metadataMarkerValue,
				expectedDebs:      []string{"kubelet", "kubeadm", "kubectl"},
			})
		})

		It("creates a compact node delta package from base and target node packages and validates its manifest", Label("node-delta-package"), func(ctx SpecContext) {
			Expect(fullPackagePath).NotTo(BeEmpty(), "full node package must be available from step 1")
			Expect(fullArchive).NotTo(BeNil())

			deltaDir := filepath.Join(workDir, "delta-package")
			Expect(os.MkdirAll(deltaDir, 0o755)).To(Succeed())

			basePackagePath := strings.TrimSpace(os.Getenv(envBasePackage))
			if basePackagePath != "" {
				By(fmt.Sprintf("using prebuilt base node package from %s=%s", envBasePackage, basePackagePath))
				_, err := os.Stat(basePackagePath)
				Expect(err).NotTo(HaveOccurred())
			} else {
				basePackagePath = filepath.Join(deltaDir, fmt.Sprintf("%s-node-derived-base.zip", distKey))
				By("deriving a base node package from the full node package to exercise Added and Changed diffs")
				var err error
				derivedPlan, err = deriveBaseNodePackage(fullPackagePath, distKey, basePackagePath)
				Expect(err).NotTo(HaveOccurred())
				GinkgoWriter.Printf("[NodeUpgradeE2E] Derived base plan: addedDeb=%q changedDeb=%q addedImage=%q changedImage=%q\n",
					derivedPlan.AddedDeb, derivedPlan.ChangedDeb, derivedPlan.AddedImage, derivedPlan.ChangedImage)
			}

			deltaName := fmt.Sprintf("%s-node-delta-e2e.zip", distKey)
			deltaPackagePath = filepath.Join(deltaDir, deltaName)

			By("creating the node delta package via 'k2s system package --node-package --delta-package'")
			suite.K2sCli().MustExec(ctx, "system", "package",
				"--node-package", "--delta-package",
				"--package-version-from", basePackagePath,
				"--package-version-to", fullPackagePath,
				"-d", deltaDir,
				"-n", deltaName,
				"-o")

			By("validating the generated node delta package manifest, helper scripts, and entries")
			var err error
			deltaArchive, err = inspectNodePackageZip(deltaPackagePath)
			Expect(err).NotTo(HaveOccurred())
			Expect(validateNodeDeltaPackage(deltaArchive, distKey)).To(Succeed())

			if derivedPlan != nil {
				m := deltaArchive.DeltaManifest
				Expect(sortedCopy(m.DebianPackageDiff.Added)).To(Equal([]string{derivedPlan.AddedDeb}))
				if derivedPlan.ChangedDeb != "" {
					Expect(sortedCopy(m.DebianPackageDiff.Changed)).To(Equal([]string{derivedPlan.ChangedDeb}))
				}
				Expect(m.DebianPackageDiff.RemovedCount).To(Equal(0))

				if derivedPlan.AddedImage != "" {
					Expect(mapKeys(m.ContainerImageDiff.AddedImages)).To(Equal([]string{derivedPlan.AddedImage}))
				}
				if derivedPlan.ChangedImage != "" {
					Expect(mapKeys(m.ContainerImageDiff.ChangedImages)).To(Equal([]string{derivedPlan.ChangedImage}))
				}
				Expect(m.ContainerImageDiff.RemovedCount).To(Equal(0))

				if len(fullArchive.DebsByOS[distKey]) > 2 || len(fullArchive.Images) > 2 {
					Expect(deltaArchive.SizeBytes).To(BeNumerically("<", fullArchive.SizeBytes),
						"node delta package (%d bytes) should be smaller than full node package (%d bytes)",
						deltaArchive.SizeBytes, fullArchive.SizeBytes)
				}
			}

			GinkgoWriter.Printf("[NodeUpgradeE2E] Node delta package verified: path=%s size=%d bytes (full=%d bytes) debDiff=+%d/~%d/-%d imgDiff=+%d/~%d/-%d\n",
				deltaArchive.Path, deltaArchive.SizeBytes, fullArchive.SizeBytes,
				deltaArchive.DeltaManifest.DebianPackageDiff.AddedCount,
				deltaArchive.DeltaManifest.DebianPackageDiff.ChangedCount,
				deltaArchive.DeltaManifest.DebianPackageDiff.RemovedCount,
				deltaArchive.DeltaManifest.ContainerImageDiff.AddedCount,
				deltaArchive.DeltaManifest.ContainerImageDiff.ChangedCount,
				deltaArchive.DeltaManifest.ContainerImageDiff.RemovedCount)
		})

		It("upgrades the Linux worker node using the node delta package and verifies applied packages, images, and workload recovery", Label("node-upgrade-delta"), func(ctx SpecContext) {
			Expect(deltaPackagePath).NotTo(BeEmpty(), "node delta package must be available from previous step")
			Expect(deltaArchive).NotTo(BeNil())
			Expect(deltaArchive.DeltaManifest).NotTo(BeNil())

			var expectedInstalled []string
			for _, rel := range append(slices.Clone(deltaArchive.DeltaManifest.DebianPackageDiff.Added), deltaArchive.DeltaManifest.DebianPackageDiff.Changed...) {
				pkg := debFilenameToPackageName(rel)
				if !slices.Contains(expectedInstalled, pkg) {
					expectedInstalled = append(expectedInstalled, pkg)
				}
			}
			var expectedRemoved []string
			for _, rel := range deltaArchive.DeltaManifest.DebianPackageDiff.Removed {
				pkg := debFilenameToPackageName(rel)
				if !slices.Contains(expectedInstalled, pkg) && !slices.Contains(expectedRemoved, pkg) {
					expectedRemoved = append(expectedRemoved, pkg)
				}
			}

			workerPodUID = executeAndVerifyNodeUpgrade(ctx, nodeUpgradeRunParams{
				mode:              upgradeModeDelta,
				packagePath:       deltaPackagePath,
				distKey:           distKey,
				controlPlaneName:  controlPlaneName,
				workloadNamespace: workloadNamespace,
				prevWorkerPodUID:  workerPodUID,
				canaryPodUID:      canaryPodUID,
				metadataValue:     metadataMarkerValue,
				expectedDebs:      expectedInstalled,
				removedDebs:       expectedRemoved,
			})
		})
	})

type nodeUpgradeRunParams struct {
	mode              string
	packagePath       string
	distKey           string
	controlPlaneName  string
	workloadNamespace string
	prevWorkerPodUID  types.UID
	canaryPodUID      types.UID
	metadataValue     string
	expectedDebs      []string
	removedDebs       []string
}

func executeAndVerifyNodeUpgrade(ctx SpecContext, params nodeUpgradeRunParams) types.UID {
	nodeBefore := getNode(ctx, targetWorker.Name).DeepCopy()
	Expect(isNodeReady(nodeBefore)).To(BeTrue())
	Expect(nodeBefore.Spec.Unschedulable).To(BeFalse())

	allNodesBefore, err := client.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	Expect(err).NotTo(HaveOccurred())
	descriptorBefore := readDescriptor()
	kubeletBefore := readKubeletState(ctx, targetWorker)
	Expect(kubeletBefore.Active).To(Equal("active"))

	observer, err := observeNodeUpgrade(ctx, client, targetWorker.Name, nodeBefore.UID)
	Expect(err).NotTo(HaveOccurred())
	defer observer.stop()

	By(fmt.Sprintf("running 'k2s system upgrade --node %s --path %s -o' (%s mode)",
		targetWorker.Name, params.packagePath, params.mode))
	output := suite.K2sCli().MustExec(ctx, "system", "upgrade",
		"--node", targetWorker.Name,
		"--path", params.packagePath,
		"-o")

	By(fmt.Sprintf("verifying %s upgrade phase log ordering", params.mode))
	Expect(validateUpgradeLogOrdering(output, params.mode)).To(Succeed())

	By("verifying Node API lifecycle observed cordon -> uncordon -> Ready without deletion or UID change")
	nodeAfter := getNode(ctx, targetWorker.Name)
	Expect(observer.verify(nodeAfter)).To(Succeed())

	By("verifying worker Node identity, PodCIDR, and custom metadata were preserved")
	Expect(nodeAfter.UID).To(Equal(nodeBefore.UID))
	Expect(nodeAfter.Spec.PodCIDR).To(Equal(nodeBefore.Spec.PodCIDR))
	Expect(nodeAfter.Spec.PodCIDRs).To(Equal(nodeBefore.Spec.PodCIDRs))
	Expect(nodeAfter.Status.NodeInfo.OSImage).To(Equal(nodeBefore.Status.NodeInfo.OSImage))
	Expect(nodeAfter.Spec.Unschedulable).To(BeFalse())
	Expect(isNodeReady(nodeAfter)).To(BeTrue())
	Expect(nodeAfter.Labels).To(HaveKeyWithValue(metadataKey, params.metadataValue))
	Expect(nodeAfter.Annotations).To(HaveKeyWithValue(metadataKey, params.metadataValue))
	Expect(slices.ContainsFunc(nodeAfter.Spec.Taints, func(t corev1.Taint) bool {
		return t.Key == metadataKey && t.Value == params.metadataValue && t.Effect == corev1.TaintEffectNoSchedule
	})).To(BeTrue(), "custom NoSchedule taint should be preserved across node upgrade")

	By("verifying kubelet restarted and is active on the upgraded worker")
	kubeletAfter := readKubeletState(ctx, targetWorker)
	Expect(validateKubeletRestarted(kubeletBefore, kubeletAfter)).To(Succeed())

	By("verifying Debian packages, container images, and remote temp directory cleanup on the worker")
	for _, pkg := range params.expectedDebs {
		status := remote(ctx, targetWorker, fmt.Sprintf("dpkg-query -W -f='${Status}' '%s'", pkg))
		Expect(status).To(Equal("install ok installed"), "expected Debian package %q to be installed on %s", pkg, targetWorker.Name)
	}
	for _, pkg := range params.removedDebs {
		status := remote(ctx, targetWorker, fmt.Sprintf("dpkg-query -W -f='${Status}' '%s' 2>/dev/null || true", pkg))
		Expect(status).NotTo(ContainSubstring("install ok installed"), "expected removed Debian package %q to be purged on %s", pkg, targetWorker.Name)
	}
	imageIDs := remote(ctx, targetWorker, "sudo -n crictl images -q")
	Expect(imageIDs).NotTo(BeEmpty(), "upgraded worker %s should have container images loaded", targetWorker.Name)

	tempCleanup := remote(ctx, targetWorker, "test ! -e /tmp/k2s-node-upgrade-pkgs && test ! -e /tmp/k2s-node-upgrade-images && echo clean")
	Expect(tempCleanup).To(Equal("clean"), "temporary upgrade staging directories should be removed from worker")

	By("verifying cluster.json and unrelated Nodes remained intact")
	Expect(readDescriptor()).To(Equal(descriptorBefore))
	for _, otherBefore := range allNodesBefore.Items {
		if otherBefore.Name == targetWorker.Name {
			continue
		}
		otherAfter := getNode(ctx, otherBefore.Name)
		Expect(otherAfter.UID).To(Equal(otherBefore.UID))
		Expect(otherAfter.Spec.Unschedulable).To(Equal(otherBefore.Spec.Unschedulable))
		Expect(isNodeReady(otherAfter)).To(Equal(isNodeReady(&otherBefore)))
	}

	By("verifying worker workload was drained and rescheduled with a new Pod UID while control-plane canary stayed intact")
	newWorkerPod := waitForSinglePod(ctx, params.workloadNamespace, "app="+workerWorkloadName, targetWorker.Name, params.prevWorkerPodUID)
	canaryPods, err := client.CoreV1().Pods(params.workloadNamespace).List(ctx, metav1.ListOptions{LabelSelector: "app=" + canaryWorkloadName})
	Expect(err).NotTo(HaveOccurred())
	Expect(validateCanaryPodUnchanged(canaryPods.Items, params.controlPlaneName, params.canaryPodUID)).To(Succeed())

	return newWorkerPod.UID
}

func rejectSystemPackage(ctx context.Context, args ...string) string {
	output, code := suite.K2sCli().Exec(ctx, append([]string{"system", "package"}, args...)...)
	Expect(code).NotTo(Equal(0), "expected 'k2s system package %s' to fail; output:\n%s", strings.Join(args, " "), output)
	return output
}

func rejectNodeUpgrade(ctx context.Context, args ...string) string {
	output, code := suite.K2sCli().Exec(ctx, append([]string{"system", "upgrade"}, args...)...)
	Expect(code).NotTo(Equal(0), "expected 'k2s system upgrade %s' to fail; output:\n%s", strings.Join(args, " "), output)
	return output
}

func remote(ctx context.Context, worker clusterconfig.Node, command string) string {
	return strings.TrimSpace(suite.K2sCli().MustExec(ctx, "node", "exec",
		"--ip-addr", worker.IpAddress,
		"--username", worker.Username,
		"--command", command,
		"--raw"))
}

func detectWorkerDistro(ctx context.Context, worker clusterconfig.Node) string {
	lsbID := remote(ctx, worker, "lsb_release -i | cut -d ':' -f 2 | tr -d '[:blank:]'")
	lsbRelease := remote(ctx, worker, "lsb_release -r | cut -d ':' -f 2 | tr -d '[:blank:]'")
	distKey, err := parseDistroKey(lsbID, lsbRelease)
	Expect(err).NotTo(HaveOccurred())
	return distKey
}

func readKubeletState(ctx context.Context, worker clusterconfig.Node) kubeletState {
	raw := remote(ctx, worker, "sudo -n systemctl show kubelet -p ActiveState -p MainPID -p ExecMainStartTimestampMonotonic")
	state, err := parseKubeletState(raw)
	Expect(err).NotTo(HaveOccurred())
	return state
}

func readDescriptor() []byte {
	data, err := os.ReadFile(clusterconfig.ConfigPath(configDir))
	Expect(err).NotTo(HaveOccurred())
	return data
}

func getNode(ctx context.Context, name string) *corev1.Node {
	node, err := client.CoreV1().Nodes().Get(ctx, name, metav1.GetOptions{})
	Expect(err).NotTo(HaveOccurred())
	return node
}

func attachTestMetadata(ctx context.Context, nodeName, value string) {
	Expect(retry.RetryOnConflict(retry.DefaultRetry, func() error {
		node, err := client.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{})
		if err != nil {
			return err
		}
		if node.Labels == nil {
			node.Labels = map[string]string{}
		}
		if node.Annotations == nil {
			node.Annotations = map[string]string{}
		}
		node.Labels[metadataKey] = value
		node.Annotations[metadataKey] = value
		node.Spec.Taints = slices.DeleteFunc(node.Spec.Taints, func(t corev1.Taint) bool {
			return t.Key == metadataKey
		})
		node.Spec.Taints = append(node.Spec.Taints, corev1.Taint{
			Key:    metadataKey,
			Value:  value,
			Effect: corev1.TaintEffectNoSchedule,
		})
		_, err = client.CoreV1().Nodes().Update(ctx, node, metav1.UpdateOptions{})
		return err
	})).To(Succeed())
}

func removeTestMetadata(ctx context.Context, nodeName string) {
	Expect(retry.RetryOnConflict(retry.DefaultRetry, func() error {
		node, err := client.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{})
		if apierrors.IsNotFound(err) {
			return nil
		}
		if err != nil {
			return err
		}
		delete(node.Labels, metadataKey)
		delete(node.Annotations, metadataKey)
		node.Spec.Taints = slices.DeleteFunc(node.Spec.Taints, func(t corev1.Taint) bool {
			return t.Key == metadataKey
		})
		_, err = client.CoreV1().Nodes().Update(ctx, node, metav1.UpdateOptions{})
		return err
	})).To(Succeed())
}

func waitForSinglePod(ctx SpecContext, namespace, selector, expectedNode string, forbiddenUID types.UID) corev1.Pod {
	var pod corev1.Pod
	Eventually(func() error {
		pods, err := client.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{LabelSelector: selector})
		if err != nil {
			return err
		}
		matched, err := validateSinglePodOnNode(pods.Items, expectedNode, forbiddenUID)
		if err != nil {
			return err
		}
		pod = matched
		return nil
	}, workloadWaitWindow, 2*time.Second).Should(Succeed())
	return pod
}

func deleteNamespace(ctx SpecContext, namespace string) {
	err := client.CoreV1().Namespaces().Delete(ctx, namespace, metav1.DeleteOptions{})
	Expect(err == nil || apierrors.IsNotFound(err)).To(BeTrue(), "delete namespace %s: %v", namespace, err)
	Eventually(func() error {
		_, err := client.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
		if !apierrors.IsNotFound(err) {
			return fmt.Errorf("waiting for namespace %s deletion: %v", namespace, err)
		}
		return nil
	}, workloadWaitWindow, 2*time.Second).Should(Succeed())
}

func deleteSyntheticNode(ctx SpecContext, name string, uid types.UID) {
	leaseErr := client.CoordinationV1().Leases(nodeLeaseNamespace).Delete(ctx, name, metav1.DeleteOptions{})
	Expect(leaseErr == nil || apierrors.IsNotFound(leaseErr)).To(BeTrue(), "delete synthetic Node Lease %s: %v", name, leaseErr)

	err := client.CoreV1().Nodes().Delete(ctx, name, metav1.DeleteOptions{
		Preconditions: &metav1.Preconditions{UID: &uid},
	})
	Expect(err == nil || apierrors.IsNotFound(err)).To(BeTrue(), "delete synthetic Node %s: %v", name, err)
	Eventually(func() error {
		_, err := client.CoreV1().Nodes().Get(ctx, name, metav1.GetOptions{})
		if !apierrors.IsNotFound(err) {
			return fmt.Errorf("waiting for synthetic Node %s deletion: %v", name, err)
		}
		pods, err := client.CoreV1().Pods("").List(ctx, metav1.ListOptions{})
		if err != nil {
			return err
		}
		pending := 0
		for _, pod := range pods.Items {
			if !daemonPodTargetsNode(&pod, name) {
				continue
			}
			pending++
			if pod.DeletionTimestamp != nil {
				continue
			}
			delErr := client.CoreV1().Pods(pod.Namespace).Delete(ctx, pod.Name, metav1.DeleteOptions{
				Preconditions: &metav1.Preconditions{UID: &pod.UID},
			})
			if delErr != nil && !apierrors.IsNotFound(delErr) {
				return delErr
			}
		}
		if pending != 0 {
			return fmt.Errorf("waiting for %d DaemonSet Pods targeting synthetic Node %s to disappear", pending, name)
		}
		return nil
	}, 2*time.Minute, 2*time.Second).Should(Succeed())
}

func uniqueName(prefix string) string {
	return fmt.Sprintf("%s-%d", prefix, time.Now().UnixNano())
}
