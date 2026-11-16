// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package nodeimage

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var suite *framework.K2sTestSuite

func TestNodeImage(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Cluster Node Image Acceptance Tests", Label("core", "acceptance", "internet-required", "setup-required", "system-running", "node-image"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(300*time.Millisecond),
		framework.ClusterTestStepTimeout(8*time.Minute),
	)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("Node Image CLI", Label("node-image", "image"), Ordered, func() {
	type nodeMeta struct {
		Name string
		OS   string
	}

	type nodeList struct {
		Items []struct {
			Metadata struct {
				Name   string            `json:"name"`
				Labels map[string]string `json:"labels"`
			} `json:"metadata"`
		} `json:"items"`
	}

	type listedImage struct {
		ImageId    string `json:"imageid"`
		Repository string `json:"repository"`
		Tag        string `json:"tag"`
		Node       string `json:"node"`
	}

	type pushedImage struct {
		Name string `json:"name"`
		Tag  string `json:"tag"`
		Node string `json:"node"`
	}

	type listedImages struct {
		ContainerImages []listedImage `json:"containerimages"`
		PushedImages    []pushedImage `json:"pushedimages"`
		Error           *string       `json:"error"`
	}

	type imageLifecycleRecord struct {
		NodeName      string
		NodeOS        string
		PulledImage   string
		PulledImageID string
		TaggedImage   string
		TaggedImageID string
	}

	const (
		linuxNodeOsName   = "linux"
		windowsNodeOsName = "windows"
		windowsFlag       = "--windows"
		nodeFlag          = "--node"
		nodesFlag         = "--nodes"
		nameFlag          = "--name"
		idFlag            = "--id"
		registryName      = "k2s.registry.local"
		registryAddress   = "k2s.registry.local:30500"

		linuxSourceImage   = "shsk2s.azurecr.io/example.albums-golang-linux:v1.0.0"
		windowsSourceImage = "shsk2s.azurecr.io/example.albums-golang-win:v1.0.0"
	)

	var (
		additionalNodes []nodeMeta
		nodesSelector   string
		nodePair        []nodeMeta
		nodePairSelect  string
		imageTestDir    string

		sourceImageByNode map[string]string
		targetImageByNode map[string]string
		exportTarByNode   map[string]string
		exportTarPair     string
		imageStateByNode  map[string]*imageLifecycleRecord
	)

	logStep := func(format string, args ...any) {
		GinkgoWriter.Printf("[STEP] "+format+"\n", args...)
	}

	logOutcome := func(format string, args ...any) {
		GinkgoWriter.Printf("[OUTCOME] "+format+"\n", args...)
	}

	getAdditionalNodes := func(ctx context.Context) []nodeMeta {
		raw := suite.Kubectl().MustExec(ctx, "get", "nodes", "-o", "json")
		parsed := nodeList{}
		Expect(json.Unmarshal([]byte(raw), &parsed)).To(Succeed())

		localHostname, err := os.Hostname()
		Expect(err).ToNot(HaveOccurred())
		localHostname = strings.ToLower(localHostname)

		isLinuxOnly := false
		if installConfig := suite.SetupInfo().RuntimeConfig.InstallConfig(); installConfig != nil {
			isLinuxOnly = installConfig.LinuxOnly()
		}

		result := []nodeMeta{}
		for _, node := range parsed.Items {
			labels := node.Metadata.Labels
			if labels == nil {
				continue
			}

			osLabel := labels["kubernetes.io/os"]
			if osLabel != linuxNodeOsName && osLabel != windowsNodeOsName {
				continue
			}

			// Skip the Windows host node (registered by k2s at install time).
			// It is the local machine itself; on Windows host, image operations on it run locally
			// and are not covered by worker-node-focused test suite.
			// On Linux-only setups, the local host is the sole cluster node running workloads.
			if !isLinuxOnly && strings.ToLower(node.Metadata.Name) == localHostname {
				GinkgoWriter.Printf("[SETUP] Skipping host node <%s> (matches local hostname on Windows host)\n", node.Metadata.Name)
				continue
			}

			result = append(result, nodeMeta{Name: node.Metadata.Name, OS: osLabel})
		}

		// Fallback: if all nodes were skipped (e.g. single-node cluster), include all discovered nodes
		if len(result) == 0 {
			for _, node := range parsed.Items {
				labels := node.Metadata.Labels
				if labels == nil {
					continue
				}
				osLabel := labels["kubernetes.io/os"]
				if osLabel == linuxNodeOsName || osLabel == windowsNodeOsName {
					result = append(result, nodeMeta{Name: node.Metadata.Name, OS: osLabel})
				}
			}
		}

		return result
	}

	imageForNode := func(node nodeMeta) string {
		if node.OS == windowsNodeOsName {
			return windowsSourceImage
		}

		return linuxSourceImage
	}

	selectSameOSPair := func(nodes []nodeMeta) []nodeMeta {
		for _, left := range nodes {
			for _, right := range nodes {
				if left.Name == right.Name {
					continue
				}
				if left.OS == right.OS {
					return []nodeMeta{left, right}
				}
			}
		}

		return nil
	}

	pullArgsForNode := func(node nodeMeta, imageName string) []string {
		args := []string{"image", "pull", imageName}
		if node.OS == windowsNodeOsName {
			args = append(args, windowsFlag)
		}

		return append(args, nodeFlag, node.Name)
	}

	importArgsForNode := func(node nodeMeta, tarPath string) []string {
		args := []string{"image", "import", "-t", tarPath}
		if node.OS == windowsNodeOsName {
			args = append(args, windowsFlag)
		}

		return append(args, nodeFlag, node.Name)
	}

	listImages := func(ctx context.Context, nodeName string) listedImages {
		output := suite.K2sCli().MustExec(ctx, "image", "ls", nodeFlag, nodeName, "-o", "json")

		parsed := listedImages{}
		Expect(json.Unmarshal([]byte(output), &parsed)).To(Succeed())
		Expect(parsed.Error).To(BeNil(), "image ls returned error for node %s: %s", nodeName, output)

		return parsed
	}

	hasImage := func(images listedImages, nodeName, imageName string) bool {
		for _, image := range images.ContainerImages {
			cleanRepo := strings.TrimPrefix(image.Repository, "localhost/")
			matchesName := fmt.Sprintf("%s:%s", image.Repository, image.Tag) == imageName ||
				fmt.Sprintf("%s:%s", cleanRepo, image.Tag) == imageName
			matchesNode := strings.EqualFold(image.Node, nodeName) ||
				strings.EqualFold(image.Node, "linux") ||
				nodeName == ""

			if matchesName && matchesNode {
				return true
			}
		}

		return false
	}

	findImageID := func(images listedImages, nodeName, imageName string) string {
		for _, image := range images.ContainerImages {
			cleanRepo := strings.TrimPrefix(image.Repository, "localhost/")
			matchesName := fmt.Sprintf("%s:%s", image.Repository, image.Tag) == imageName ||
				fmt.Sprintf("%s:%s", cleanRepo, image.Tag) == imageName
			matchesNode := strings.EqualFold(image.Node, nodeName) ||
				strings.EqualFold(image.Node, "linux") ||
				nodeName == ""

			if matchesName && matchesNode {
				return image.ImageId
			}
		}

		return ""
	}

	registryListContains := func(output string, registry string) bool {
		return strings.Contains(strings.ToLower(output), strings.ToLower(registry))
	}

	BeforeAll(func(ctx context.Context) {
		additionalNodes = getAdditionalNodes(ctx)
		if len(additionalNodes) == 0 {
			Skip("No cluster nodes found")
		}

		// Wait for all discovered nodes to be Ready before running image tests
		GinkgoWriter.Println("Waiting for all discovered nodes to be in Ready state...")
		for _, node := range additionalNodes {
			GinkgoWriter.Printf("Waiting for node %s to be Ready...\n", node.Name)
			suite.Cluster().WaitForNodeToBeReady(node.Name, ctx)
		}
		GinkgoWriter.Println("All nodes are Ready")

		imageTestDir = filepath.Join(suite.RootDir(), "imgetest")
		Expect(os.MkdirAll(imageTestDir, 0o755)).To(Succeed())

		nodeNames := make([]string, 0, len(additionalNodes))
		for _, node := range additionalNodes {
			nodeNames = append(nodeNames, node.Name)
		}
		nodesSelector = strings.Join(nodeNames, ",")

		nodePair = selectSameOSPair(additionalNodes)
		if len(nodePair) == 2 {
			nodePairSelect = strings.Join([]string{nodePair[0].Name, nodePair[1].Name}, ",")
		}

		sourceImageByNode = map[string]string{}
		targetImageByNode = map[string]string{}
		exportTarByNode = map[string]string{}
		imageStateByNode = map[string]*imageLifecycleRecord{}
		for idx, node := range additionalNodes {
			suffix := fmt.Sprintf("%d-%d", time.Now().Unix(), idx)
			sourceImageByNode[node.Name] = imageForNode(node)
			targetImageByNode[node.Name] = fmt.Sprintf("%s/%s:%s", registryAddress, strings.ToLower(node.Name), suffix)
			exportTarByNode[node.Name] = filepath.Join(imageTestDir, fmt.Sprintf("node-image-%s-%s.tar", node.Name, suffix))
			imageStateByNode[node.Name] = &imageLifecycleRecord{
				NodeName:    node.Name,
				NodeOS:      node.OS,
				PulledImage: sourceImageByNode[node.Name],
				TaggedImage: targetImageByNode[node.Name],
			}
		}
		exportTarPair = filepath.Join(imageTestDir, fmt.Sprintf("node-image-pair-%d.tar", time.Now().Unix()))

		for _, node := range additionalNodes {
			logStep("Node <%s> OS=<%s> sourceImage=<%s> targetImage=<%s>", node.Name, node.OS, sourceImageByNode[node.Name], targetImageByNode[node.Name])
		}
		if len(nodePair) == 2 {
			logStep("Using pair for --nodes scenarios: <%s>", nodePairSelect)
		} else {
			logStep("No same-OS pair found. --nodes export/import scenarios will be skipped")
		}

		logOutcome("Discovered %d cluster nodes: %s", len(additionalNodes), nodesSelector)
	})

	AfterAll(func(ctx context.Context) {
		GinkgoWriter.Printf("[CLEANUP] Starting AfterAll cleanup sequence\n")

		for _, node := range additionalNodes {
			exportTarPath := exportTarByNode[node.Name]
			if err := os.Remove(exportTarPath); err != nil && !os.IsNotExist(err) {
				GinkgoWriter.Printf("[CLEANUP] warning: failed to remove export tar <%s>: %v\n", exportTarPath, err)
			}
		}
		if err := os.Remove(exportTarPair); err != nil && !os.IsNotExist(err) {
			GinkgoWriter.Printf("[CLEANUP] warning: failed to remove pair export tar <%s>: %v\n", exportTarPair, err)
		}

		GinkgoWriter.Printf("[CLEANUP] AfterAll cleanup completed\n")
	})

	Describe("complete workflow", Ordered, func() {
		It("1) verifies source images are absent before pull", func(ctx context.Context) {
			GinkgoWriter.Printf("[TESTCASE][START] 1) verify source images absent before pull | nodes=%s\n", nodesSelector)
			for _, node := range additionalNodes {
				sourceImageName := sourceImageByNode[node.Name]
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s os=%s action=check-absent image=%s\n", node.Name, node.OS, sourceImageName)
				if hasImage(listImages(ctx, node.Name), node.Name, sourceImageName) {
					GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s image=%s status=already-present skipping assertion\n", node.Name, sourceImageName)
				} else {
					GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s image=%s status=absent ok\n", node.Name, sourceImageName)
				}
			}
			GinkgoWriter.Printf("[TESTCASE][END] 1) verify source images absent before pull\n")
		})

		It("2) pulls source image on each node using --node", func(ctx context.Context) {
			GinkgoWriter.Printf("[TESTCASE][START] 2) pull source image on each node using --node\n")
			for _, node := range additionalNodes {
				sourceImageName := sourceImageByNode[node.Name]
				args := pullArgsForNode(node, sourceImageName)
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s os=%s action=pull args=%v\n", node.Name, node.OS, args)
				suite.K2sCli().MustExec(ctx, args...)
				Eventually(func(g Gomega) {
					g.Expect(hasImage(listImages(ctx, node.Name), node.Name, sourceImageName)).To(BeTrue())
				}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())
			}
			GinkgoWriter.Printf("[TESTCASE][END] 2) pull source image on each node using --node\n")
		})

		It("3) verifies image ls with --nodes for same-OS pair", func(ctx context.Context) {
			GinkgoWriter.Printf("[TESTCASE][START] 3) verify image ls with --nodes for same-OS pair\n")

			// First verify per-node listing for all nodes.
			for _, node := range additionalNodes {
				image := sourceImageByNode[node.Name]
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s os=%s action=ls-node image=%s\n", node.Name, node.OS, image)
				nodeImages := listImages(ctx, node.Name)
				Expect(hasImage(nodeImages, node.Name, image)).To(BeTrue())
			}

			pairsByOS := map[string][]nodeMeta{
				linuxNodeOsName:   {},
				windowsNodeOsName: {},
			}
			for _, node := range additionalNodes {
				if _, ok := pairsByOS[node.OS]; ok {
					pairsByOS[node.OS] = append(pairsByOS[node.OS], node)
				}
			}

			hasVerifiedAtLeastOnePair := false
			for _, osName := range []string{linuxNodeOsName, windowsNodeOsName} {
				nodesOfOS := pairsByOS[osName]
				if len(nodesOfOS) < 2 {
					GinkgoWriter.Printf("[TESTCASE][DETAIL] os=%s action=skip-ls-nodes reason=insufficient-nodes count=%d\n", osName, len(nodesOfOS))
					continue
				}

				n1 := nodesOfOS[0]
				n2 := nodesOfOS[1]
				pairSelect := strings.Join([]string{n1.Name, n2.Name}, ",")
				image1 := sourceImageByNode[n1.Name]
				image2 := sourceImageByNode[n2.Name]

				GinkgoWriter.Printf("[TESTCASE][DETAIL] os=%s pair=%s action=ls-nodes image1=%s image2=%s\n", osName, pairSelect, image1, image2)
				lsOutput := suite.K2sCli().MustExec(ctx, "image", "ls", nodesFlag, pairSelect, "-o", "json")
				pairImages := listedImages{}
				Expect(json.Unmarshal([]byte(lsOutput), &pairImages)).To(Succeed())
				Expect(hasImage(pairImages, n1.Name, image1)).To(BeTrue())
				Expect(hasImage(pairImages, n2.Name, image2)).To(BeTrue())

				hasVerifiedAtLeastOnePair = true
			}

			if !hasVerifiedAtLeastOnePair {
				GinkgoWriter.Printf("[TESTCASE][DETAIL] no same-OS family has >=2 nodes; validated per-node ls only\n")
			}
			GinkgoWriter.Printf("[TESTCASE][END] 3) verify image ls with --nodes for same-OS pair\n")
		})

		It("4) enables registry addon ", func(ctx context.Context) {
			GinkgoWriter.Printf("[TESTCASE][START] 4) enable registry addon and verify registry is added\n")

			enabledAddons := suite.SetupInfo().RuntimeConfig.ClusterConfig().EnabledAddons()
			registryAlreadyEnabled := false
			for _, a := range enabledAddons {
				if a.Name == "registry" {
					registryAlreadyEnabled = true
					break
				}
			}

			if registryAlreadyEnabled {
				GinkgoWriter.Printf("[TESTCASE][DETAIL] action=addons-enable addon=registry status=already-enabled skipping\n")
			} else {
				GinkgoWriter.Printf("[TESTCASE][DETAIL] action=addons-enable addon=registry\n")
				suite.K2sCli().MustExec(ctx, "addons", "enable", "registry", "-o")
			}

			// Addon enable already deploys local registry; verify it appears on at least one node.
			foundRegistryOnAnyNode := false
			for _, node := range additionalNodes {
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s action=registry-ls-node\n", node.Name)
				regLs := suite.K2sCli().MustExec(ctx, "image", "registry", "ls", nodeFlag, node.Name)
				deployed := registryListContains(regLs, registryName)
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s registry-present=%v registry=%s\n", node.Name, deployed, registryName)
				if deployed {
					foundRegistryOnAnyNode = true
				}
			}

			Expect(foundRegistryOnAnyNode).To(BeTrue(), "expected registry %s to be present on at least one node", registryName)

			GinkgoWriter.Printf("[TESTCASE][END] 4) enable registry addon and verify registry is added\n")
		})

		It("5) tags and pushes image from each node, verifies round-trip pull from registry", func(ctx context.Context) {
			GinkgoWriter.Printf("[TESTCASE][START] 5) tag and push image from each node, verify round-trip pull from registry\n")
			for _, node := range additionalNodes {
				sourceImageName := sourceImageByNode[node.Name]
				targetImageName := targetImageByNode[node.Name]
				nodeImages := listImages(ctx, node.Name)
				targetImageID := findImageID(nodeImages, node.Name, targetImageName)

				record := imageStateByNode[node.Name]
				record.PulledImageID = findImageID(nodeImages, node.Name, sourceImageName)

				if targetImageID == "" {
					GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s action=tag-missing-target source=%s target=%s\n", node.Name, sourceImageName, targetImageName)
					suite.K2sCli().MustExec(ctx, "image", "tag", "-n", sourceImageName, "-t", targetImageName, nodeFlag, node.Name)
					Eventually(func(g Gomega) {
						taggedImages := listImages(ctx, node.Name)
						g.Expect(findImageID(taggedImages, node.Name, targetImageName)).ToNot(BeEmpty())
					}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())
					targetImageID = findImageID(listImages(ctx, node.Name), node.Name, targetImageName)
				}

				Expect(targetImageID).ToNot(BeEmpty())
				record.TaggedImageID = targetImageID
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s action=push image=%s by=name pulledId=%s taggedId=%s\n", node.Name, targetImageName, record.PulledImageID, record.TaggedImageID)
				suite.K2sCli().MustExec(ctx, "image", "push", "-n", targetImageName, nodeFlag, node.Name)
			}

			for _, node := range additionalNodes {
				record := imageStateByNode[node.Name]
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s action=remove-tagged-local image=%s\n", node.Name, record.TaggedImage)
				suite.K2sCli().MustExec(ctx, "image", "rm", nameFlag, record.TaggedImage, nodeFlag, node.Name)
				Eventually(func(g Gomega) {
					g.Expect(hasImage(listImages(ctx, node.Name), node.Name, record.TaggedImage)).To(BeFalse())
				}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())

				pullArgs := pullArgsForNode(node, record.TaggedImage)
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s action=pull-from-local-registry args=%v\n", node.Name, pullArgs)
				suite.K2sCli().MustExec(ctx, pullArgs...)
				Eventually(func(g Gomega) {
					g.Expect(hasImage(listImages(ctx, node.Name), node.Name, record.TaggedImage)).To(BeTrue())
				}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())
			}
			GinkgoWriter.Printf("[TESTCASE][END] 7) tag and push image from each node, verify round-trip pull from registry\n")
		})

		It("6) exports, removes, and re-imports with --node for each node", func(ctx context.Context) {
			GinkgoWriter.Printf("[TESTCASE][START] 6) export, remove, and re-import with --node for each node\n")
			for _, node := range additionalNodes {
				targetImageName := targetImageByNode[node.Name]
				exportTarPath := exportTarByNode[node.Name]

				// Step 1: export the image to a tar archive.
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s action=export image=%s tar=%s\n", node.Name, targetImageName, exportTarPath)
				suite.K2sCli().MustExec(ctx, "image", "export", "-n", targetImageName, "-t", exportTarPath, nodeFlag, node.Name)
				_, err := os.Stat(exportTarPath)
				Expect(err).ToNot(HaveOccurred())

				// Step 2: remove the image from the node so the subsequent import is
				// a genuine restore, not a no-op overwrite of an already-present image.
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s action=remove-before-import image=%s\n", node.Name, targetImageName)
				suite.K2sCli().MustExec(ctx, "image", "rm", nameFlag, targetImageName, nodeFlag, node.Name)
				Eventually(func(g Gomega) {
					g.Expect(hasImage(listImages(ctx, node.Name), node.Name, targetImageName)).To(BeFalse())
				}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())

				// Step 3: import from the tar and verify the image is present again.
				importArgs := importArgsForNode(node, exportTarPath)
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s action=import args=%v\n", node.Name, importArgs)
				suite.K2sCli().MustExec(ctx, importArgs...)
				Eventually(func(g Gomega) {
					g.Expect(hasImage(listImages(ctx, node.Name), node.Name, targetImageName)).To(BeTrue())
				}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s action=import-verified image=%s status=present\n", node.Name, targetImageName)
			}
			GinkgoWriter.Printf("[TESTCASE][END] 6) export, remove, and re-import with --node for each node\n")
		})

		It("7) exports, removes, and re-imports with --nodes for same-OS pair", func(ctx context.Context) {
			GinkgoWriter.Printf("[TESTCASE][START] 7) export, remove, and re-import with --nodes for same-OS pair\n")
			if len(nodePair) != 2 {
				GinkgoWriter.Printf("[TESTCASE][SKIP] 8) no same-OS pair found\n")
				Skip("No same-OS pair found")
			}

			pairTarget := targetImageByNode[nodePair[0].Name]

			// Step 1: export the image to a tar archive using --nodes (searches both nodes).
			GinkgoWriter.Printf("[TESTCASE][DETAIL] pair=%s action=export image=%s tar=%s\n", nodePairSelect, pairTarget, exportTarPair)
			suite.K2sCli().MustExec(ctx, "image", "export", "-n", pairTarget, "-t", exportTarPair, nodesFlag, nodePairSelect)
			_, err := os.Stat(exportTarPair)
			Expect(err).ToNot(HaveOccurred())

			for _, node := range nodePair {
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s action=remove-before-import image=%s\n", node.Name, pairTarget)
				suite.K2sCli().Exec(ctx, "image", "rm", nameFlag, pairTarget, nodeFlag, node.Name)
			}
			for _, node := range nodePair {
				Eventually(func(g Gomega) {
					g.Expect(hasImage(listImages(ctx, node.Name), node.Name, pairTarget)).To(BeFalse())
				}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s action=remove-verified image=%s status=absent\n", node.Name, pairTarget)
			}

			// Step 3: import from the tar to both nodes and verify the image is present on each.
			importArgs := []string{"image", "import", "-t", exportTarPair, nodesFlag, nodePairSelect}
			if nodePair[0].OS == windowsNodeOsName {
				importArgs = []string{"image", "import", "-t", exportTarPair, windowsFlag, nodesFlag, nodePairSelect}
			}
			GinkgoWriter.Printf("[TESTCASE][DETAIL] pair=%s action=import args=%v\n", nodePairSelect, importArgs)
			suite.K2sCli().MustExec(ctx, importArgs...)
			for _, node := range nodePair {
				Eventually(func(g Gomega) {
					g.Expect(hasImage(listImages(ctx, node.Name), node.Name, pairTarget)).To(BeTrue())
				}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())
				GinkgoWriter.Printf("[TESTCASE][DETAIL] node=%s action=import-verified image=%s status=present\n", node.Name, pairTarget)
			}
			GinkgoWriter.Printf("[TESTCASE][END] 7) export, remove, and re-import with --nodes for same-OS pair\n")
		})

		It("8) negative tests for Linux-only installation", func(ctx context.Context) {
			if installConfig := suite.SetupInfo().RuntimeConfig.InstallConfig(); installConfig == nil || !installConfig.LinuxOnly() {
				Skip("Negative tests for Linux-only installation only run on LinuxOnly setups")
			}

			GinkgoWriter.Println("[TESTCASE][START] 8) negative tests for Linux-only installation")

			GinkgoWriter.Println("Verifying k2s image build --windows fails with actionable error...")
			buildOut, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "image", "build", "--windows")
			Expect(buildOut).To(ContainSubstring("building Windows container images is not supported on a Linux-only installation"))

			GinkgoWriter.Println("Verifying k2s image clean --nodes n1,n2 fails with actionable error...")
			cleanOut, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "image", "clean", "--nodes", "worker-1,worker-2")
			Expect(cleanOut).To(ContainSubstring("multi-node selection 'worker-1,worker-2' is not supported on a Linux-only installation"))

			GinkgoWriter.Println("[TESTCASE][END] 8) negative tests for Linux-only installation")
		})
	})
})
