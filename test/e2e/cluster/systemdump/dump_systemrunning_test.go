// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package systemdump

import (
	"archive/zip"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestSystemDump(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Cluster System Dump Acceptance Tests", Label("core", "acceptance", "internet-required", "setup-required", "system-running", "system-dump"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(200*time.Millisecond),
		framework.ClusterTestStepTimeout(15*time.Minute),
	)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system dump", func() {
	const entryMissingPattern = "%s not found in dump zip"

	getNodes := func(ctx context.Context, osType string) []string {
		output := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", fmt.Sprintf("kubernetes.io/os=%s", osType), "-o", "jsonpath={range .items[*]}{.metadata.name}{'\\n'}{end}")
		output = strings.TrimSpace(output)

		if output == "" {
			return []string{}
		}

		return strings.Split(output, "\n")
	}

	latestDumpZip := func(logsDir string, after time.Time) string {
		files, err := os.ReadDir(logsDir)
		Expect(err).NotTo(HaveOccurred(), "failed to read logs directory")

		var dumpZip string
		var newest time.Time
		for _, f := range files {
			if !strings.HasPrefix(f.Name(), "k2s-dump-") || !strings.HasSuffix(f.Name(), ".zip") {
				continue
			}

			info, err := f.Info()
			Expect(err).NotTo(HaveOccurred())
			if info.ModTime().Before(after) {
				continue
			}

			if dumpZip == "" || info.ModTime().After(newest) {
				dumpZip = filepath.Join(logsDir, f.Name())
				newest = info.ModTime()
			}
		}

		Expect(dumpZip).NotTo(BeEmpty(), "dump zip file not found")
		return dumpZip
	}

	hasDumpEntry := func(files []*zip.File, suffix string) bool {
		for _, f := range files {
			if strings.HasSuffix(f.Name, suffix) || strings.HasSuffix(f.Name, strings.ReplaceAll(suffix, "/", "\\")) {
				return true
			}
		}
		return false
	}

	It("creates dump with --nodes node1,node2 and verifies node folder files", func(ctx context.Context) {
		linuxNodes := getNodes(ctx, "linux")
		if len(linuxNodes) < 2 {
			Skip("Need at least 2 linux nodes for --nodes node1,node2 test")
		}

		node1 := linuxNodes[0]
		node2 := linuxNodes[1]
		nodesSelector := strings.Join([]string{node1, node2}, ",")

		start := time.Now().Add(-2 * time.Second)
		output := suite.K2sCli().MustExec(ctx, "system", "dump", "--skip-open", "--nodes", nodesSelector)
		Expect(output).NotTo(BeEmpty(), "system dump output should not be empty")

		dumpZip := latestDumpZip(suite.LogsDir(), start)
		r, err := zip.OpenReader(dumpZip)
		Expect(err).NotTo(HaveOccurred(), "failed to open dump zip")
		defer r.Close()

		node1NodeFile := fmt.Sprintf("/node/%s-node.txt", node1)
		node1ProcFile := fmt.Sprintf("/node/%s-processes.txt", node1)
		node1ResourcesFile := fmt.Sprintf("/node/%s-resources.txt", node1)
		node1SystemdFile := fmt.Sprintf("/node/%s-systemd-units.txt", node1)

		node2NodeFile := fmt.Sprintf("/node/%s-node.txt", node2)
		node2ProcFile := fmt.Sprintf("/node/%s-processes.txt", node2)
		node2ResourcesFile := fmt.Sprintf("/node/%s-resources.txt", node2)
		node2SystemdFile := fmt.Sprintf("/node/%s-systemd-units.txt", node2)

		describeFile1 := fmt.Sprintf("/cluster/describe-%s.txt", node1)
		describeFile2 := fmt.Sprintf("/cluster/describe-%s.txt", node2)
		Expect(hasDumpEntry(r.File, describeFile1)).To(BeTrue(), entryMissingPattern, describeFile1)
		Expect(hasDumpEntry(r.File, describeFile2)).To(BeTrue(), entryMissingPattern, describeFile2)

		Expect(hasDumpEntry(r.File, node1NodeFile)).To(BeTrue(), entryMissingPattern, node1NodeFile)
		Expect(hasDumpEntry(r.File, node1ProcFile)).To(BeTrue(), entryMissingPattern, node1ProcFile)
		Expect(hasDumpEntry(r.File, node1ResourcesFile)).To(BeTrue(), entryMissingPattern, node1ResourcesFile)
		Expect(hasDumpEntry(r.File, node1SystemdFile)).To(BeTrue(), entryMissingPattern, node1SystemdFile)

		Expect(hasDumpEntry(r.File, node2NodeFile)).To(BeTrue(), entryMissingPattern, node2NodeFile)
		Expect(hasDumpEntry(r.File, node2ProcFile)).To(BeTrue(), entryMissingPattern, node2ProcFile)
		Expect(hasDumpEntry(r.File, node2ResourcesFile)).To(BeTrue(), entryMissingPattern, node2ResourcesFile)
		Expect(hasDumpEntry(r.File, node2SystemdFile)).To(BeTrue(), entryMissingPattern, node2SystemdFile)
	})
})
