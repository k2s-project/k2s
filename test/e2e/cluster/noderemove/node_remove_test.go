// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package noderemove

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/core/clusterconfig"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"
)

var removeSuite *framework.K2sTestSuite
var removeK2s *dsl.K2s

// NodeInfo holds the details of a node from cluster.json
type NodeInfo struct {
	Name      string
	IpAddress string
	Username  string
	NodeType  clusterconfig.NodeType
	Role      clusterconfig.Role
	OS        clusterconfig.OS
}

func TestNodeRemove(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Node Remove Acceptance Tests", Label("cli", "acceptance", "internet-required", "setup-required", "system-running", "node-remove"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	removeSuite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(500*time.Millisecond),
		framework.ClusterTestStepTimeout(10*time.Minute))
	removeK2s = dsl.NewK2s(removeSuite)

	DeferCleanup(removeSuite.TearDown)
})

// loadWorkerNodesFromClusterConfig reads cluster.json and returns all worker nodes.
// Returns nil if the file doesn't exist or has invalid format.
func loadWorkerNodesFromClusterConfig() []NodeInfo {
	configDir := removeSuite.SetupInfo().Config.Host().K2sSetupConfigDir()
	clusterCfg, err := clusterconfig.Read(configDir)
	if err != nil {
		GinkgoWriter.Printf("Warning: could not read cluster.json: %v\n", err)
		return nil
	}
	if clusterCfg == nil {
		return nil
	}

	var workerNodes []NodeInfo
	for _, node := range clusterCfg.Nodes {
		// Only include worker nodes (not control-plane)
		if node.Role == clusterconfig.RoleWorker {
			workerNodes = append(workerNodes, NodeInfo{
				Name:      node.Name,
				IpAddress: node.IpAddress,
				Username:  node.Username,
				NodeType:  node.NodeType,
				Role:      node.Role,
				OS:        node.OS,
			})
		}
	}
	return workerNodes
}

// reloadClusterConfig reloads cluster.json to get fresh state.
// Returns nil if the file doesn't exist or has invalid format.
func reloadClusterConfig() *clusterconfig.Cluster {
	configDir := removeSuite.SetupInfo().Config.Host().K2sSetupConfigDir()
	clusterCfg, err := clusterconfig.Read(configDir)
	if err != nil {
		GinkgoWriter.Printf("Warning: could not read cluster.json: %v\n", err)
		return nil
	}
	return clusterCfg
}

// nodeExistsInClusterConfig checks if a node with the given name exists in cluster.json.
func nodeExistsInClusterConfig(nodeName string) bool {
	clusterCfg := reloadClusterConfig()
	if clusterCfg == nil {
		return false
	}

	for _, node := range clusterCfg.Nodes {
		if node.Name == nodeName {
			return true
		}
	}
	return false
}

// getKubectlNodes runs kubectl get nodes and returns the output for logging/verification.
func getKubectlNodes(ctx context.Context) string {
	output := removeSuite.Kubectl().NoStdOut().MustExec(ctx, "get", "nodes", "-o", "wide")
	return output
}

// nodeExistsInKubernetes checks if a node with the given name exists in kubectl get nodes output.
func nodeExistsInKubernetes(ctx context.Context, nodeName string) bool {
	output := removeSuite.Kubectl().NoStdOut().MustExec(ctx, "get", "nodes", "-o", "jsonpath={.items[*].metadata.name}")
	nodes := strings.Fields(output)
	for _, name := range nodes {
		if name == nodeName {
			return true
		}
	}
	return false
}

var _ = Describe("node remove", Ordered, func() {
	// Store node info upfront before any removals
	var workerNodes []NodeInfo

	BeforeAll(func(ctx context.Context) {
		// Capture all worker nodes at the start - store name, IP, etc.
		workerNodes = loadWorkerNodesFromClusterConfig()
		if len(workerNodes) == 0 {
			Skip("Skipping node remove tests: no worker nodes found in cluster.json")
		}

		GinkgoWriter.Printf("Captured %d worker node(s) from cluster.json for removal testing:\n", len(workerNodes))
		for _, node := range workerNodes {
			GinkgoWriter.Printf("  - name=%s, ip=%s, type=%s, os=%s\n",
				node.Name, node.IpAddress, node.NodeType, node.OS)
		}

		// Show current kubectl get nodes output
		GinkgoWriter.Println("\n--- kubectl get nodes (before removal) ---")
		GinkgoWriter.Println(getKubectlNodes(ctx))
	})

	Describe("pre-removal validation", Label("validate"), func() {
		It("all worker nodes are present in cluster.json", func() {
			for _, node := range workerNodes {
				Expect(nodeExistsInClusterConfig(node.Name)).To(BeTrue(),
					"Expected node %s to exist in cluster.json", node.Name)
			}
		})

		It("all worker nodes are visible in kubectl get nodes", func(ctx context.Context) {
			for _, node := range workerNodes {
				exists := nodeExistsInKubernetes(ctx, node.Name)
				Expect(exists).To(BeTrue(),
					"Expected node %s to be visible in kubectl get nodes", node.Name)
			}
		})
	})

	Describe("remove each worker node", Label("remove"), func() {
		It("removes all worker nodes successfully", func(ctx context.Context) {
			// Use the stored workerNodes captured in BeforeAll
			Expect(workerNodes).NotTo(BeEmpty(), "No worker nodes captured for removal")

			for _, nodeToRemove := range workerNodes {
				By(fmt.Sprintf("Removing node: name=%s, ip=%s", nodeToRemove.Name, nodeToRemove.IpAddress))

				// Verify node exists in kubectl before removal
				By("Verifying node exists in kubectl get nodes before removal")
				Expect(nodeExistsInKubernetes(ctx, nodeToRemove.Name)).To(BeTrue(),
					"Expected node %s to exist in kubectl get nodes before removal", nodeToRemove.Name)

				// Verify node is Ready before removal
				removeSuite.Cluster().ExpectNodeToBeReady(nodeToRemove.Name, ctx)

				// Execute node remove command using stored name
				result := removeK2s.RemoveNode(ctx, nodeToRemove.Name)
				result.ExpectSuccess()

				// Verify node no longer exists in kubectl get nodes
				By("Verifying node is removed from kubectl get nodes")
				Expect(nodeExistsInKubernetes(ctx, nodeToRemove.Name)).To(BeFalse(),
					"Expected node %s to be removed from kubectl get nodes", nodeToRemove.Name)

				// Verify node no longer exists in kubernetes cluster (API check)
				removeSuite.Cluster().ExpectNodeNotToExist(nodeToRemove.Name, ctx)

				GinkgoWriter.Printf("Successfully removed node: %s (ip=%s)\n", nodeToRemove.Name, nodeToRemove.IpAddress)
			}

			// Show final kubectl get nodes output
			GinkgoWriter.Println("\n--- kubectl get nodes (after all removals) ---")
			GinkgoWriter.Println(getKubectlNodes(ctx))
		})
	})

	Describe("post-removal validation", Label("post-validate"), func() {
		It("all removed nodes are gone from kubectl get nodes", func(ctx context.Context) {
			for _, node := range workerNodes {
				exists := nodeExistsInKubernetes(ctx, node.Name)
				Expect(exists).To(BeFalse(),
					"Expected node %s (ip=%s) to not appear in kubectl get nodes", node.Name, node.IpAddress)
			}
		})

		It("all removed nodes are gone from cluster.json", func() {
			// Check using the stored workerNodes captured at the start
			for _, node := range workerNodes {
				exists := nodeExistsInClusterConfig(node.Name)
				Expect(exists).To(BeFalse(),
					"Expected node %s (ip=%s) to be removed from cluster.json", node.Name, node.IpAddress)
			}
		})

		It("control plane is still accessible", func(ctx context.Context) {
			result := removeK2s.ShowStatus(ctx)
			result.ExpectSuccess()
		})
	})
})
