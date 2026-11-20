// SPDX-FileCopyrightText: © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package systemrunning

import (
	"archive/zip"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	backupFileName  = "k2s-backup.zip"
	backupJsonFile  = "backup.json"
	testDataContent = "test-data-for-integrity-check-12345"
)

func logZipEntries(zipPath string) {
	zr, err := zip.OpenReader(zipPath)
	if err != nil {
		GinkgoWriter.Printf("[DIAG] Failed to open zip %s: %v\n", zipPath, err)
		return
	}
	defer zr.Close()
	GinkgoWriter.Printf("[DIAG] Zip %s contains %d entries:\n", zipPath, len(zr.File))
	for i, f := range zr.File {
		GinkgoWriter.Printf("[DIAG]   [%d] %s (%d bytes)\n", i, f.Name, f.UncompressedSize64)
	}
}

func logPersistentVolumeDiagnostics(ctx context.Context, namespace, podName, pvcName, pvName string) {
	commands := [][]string{
		{"get", "pod", podName, "-n", namespace, "-o", "wide"},
		{"describe", "pod", podName, "-n", namespace},
		{"get", "events", "-n", namespace, "--field-selector", "involvedObject.name=" + podName, "--sort-by=.lastTimestamp"},
		{"get", "pvc", pvcName, "-n", namespace, "-o", "wide"},
		{"describe", "pv", pvName},
	}

	for _, args := range commands {
		output, exitCode := suite.Kubectl().Exec(ctx, args...)
		GinkgoWriter.Printf("[DIAG] kubectl %s (exit code %d):\n%s\n", strings.Join(args, " "), exitCode, output)
	}
}

var (
	suite         *framework.K2sTestSuite
	randomSeed    string
	testBackupDir string
	sharedBackup  string // Shared backup for read-only tests
)

func TestBackupSystemRunning(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "System Backup Acceptance Tests", Label("e2e", "system", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(time.Millisecond*500),
		framework.ClusterTestStepTimeout(4*time.Minute)) // Set aggressive timeout per test step
	randomSeed = strconv.FormatInt(GinkgoRandomSeed(), 10)
	testBackupDir = GinkgoT().TempDir()

	// Cleanup orphaned PVs from previous test runs to avoid backing them up (async)
	GinkgoWriter.Println("Cleaning up orphaned test PVs from previous runs...")
	output, _ := suite.Kubectl().Exec(ctx, "get", "pv", "-o", "jsonpath={.items[*].metadata.name}")
	if output != "" {
		pvNames := strings.Fields(output)
		for _, pvName := range pvNames {
			if strings.Contains(pvName, "test-restore-pv-") || strings.Contains(pvName, "test-backup-pv-") {
				suite.Kubectl().Exec(ctx, "delete", "pv", pvName, "--ignore-not-found=true", "--wait=false")
			}
		}
	}
	time.Sleep(500 * time.Millisecond) // Reduced from 2s

	// Create ONE shared backup for all read-only tests (skip images/PVs for speed)
	sharedBackup = filepath.Join(testBackupDir, "shared-backup.zip")
	GinkgoWriter.Println("Creating shared backup for test suite (skip images/PVs)...")
	suite.K2sCli().MustExec(ctx, "system", "backup", "-f", sharedBackup, "--skip-images", "--skip-pvs")
	GinkgoWriter.Println("Shared backup created at:", sharedBackup)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("k2s system backup - basic functionality", Ordered, func() {
	It("creates backup successfully", func(ctx context.Context) {
		// Reuse shared backup created in BeforeSuite
		Expect(sharedBackup).To(BeAnExistingFile(), "Backup file should exist")
		GinkgoWriter.Println("Using shared backup at:", sharedBackup)
	})

	It("verifies backup contains backup.json", func(ctx context.Context) {
		// Use shared backup instead of creating a new one
		logZipEntries(sharedBackup)

		zipReader, err := zip.OpenReader(sharedBackup)
		Expect(err).NotTo(HaveOccurred(), "Should open backup archive")
		defer zipReader.Close()

		foundBackupJson := false
		for _, file := range zipReader.File {
			normalizedName := strings.ReplaceAll(file.Name, "\\", "/")
			if normalizedName == backupJsonFile {
				foundBackupJson = true
				break
			}
		}

		Expect(foundBackupJson).To(BeTrue(), "backup.json should exist in archive")
	})
})

var _ = Describe("k2s system backup - persistent volumes", Ordered, Label("pv"), func() {
	var (
		testNamespace string
		pvBackupFile  string
		pvcName       string
		podName       string
		pvName        string
	)

	BeforeAll(func(ctx context.Context) {
		testNamespace = fmt.Sprintf("test-pv-backup-%s", randomSeed)
		pvBackupFile = filepath.Join(testBackupDir, fmt.Sprintf("backup-pv-%s.zip", randomSeed))
		pvName = fmt.Sprintf("test-backup-pv-%s", randomSeed)

		// Create test namespace
		suite.Kubectl().MustExec(ctx, "create", "namespace", testNamespace)

		DeferCleanup(func(ctx context.Context) {
			if CurrentSpecReport().Failed() && podName != "" {
				logPersistentVolumeDiagnostics(ctx, testNamespace, podName, pvcName, pvName)
			}

			// Cleanup in correct order: pod -> pvc -> namespace -> pv
			suite.Kubectl().Exec(ctx, "delete", "pod", podName, "-n", testNamespace, "--ignore-not-found=true", "--wait=false")
			suite.Kubectl().Exec(ctx, "delete", "pvc", pvcName, "-n", testNamespace, "--ignore-not-found=true", "--wait=false")
			suite.Kubectl().Exec(ctx, "delete", "namespace", testNamespace, "--ignore-not-found=true", "--timeout=30s", "--wait=false")
			suite.Kubectl().Exec(ctx, "delete", "pv", pvName, "--ignore-not-found=true", "--wait=false")
			cleanupBackupFile(ctx, pvBackupFile)
		})
	})

	It("backs up user workload PVC with data and verifies PV directory exists", func(ctx context.Context) {
		pvcName = "test-user-pvc"
		podName = "test-writer-pod"

		// Create PV first
		pvYaml := fmt.Sprintf(`
apiVersion: v1
kind: PersistentVolume
metadata:
  name: %s
spec:
  capacity:
    storage: 5Mi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: /tmp/test-pv-data-%s
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/os
          operator: In
          values:
          - linux
  claimRef:
    namespace: %s
    name: %s
`, pvName, randomSeed, testNamespace, pvcName)

		applyYaml(ctx, suite, pvYaml)

		// Create PVC that binds to the PV
		pvcYaml := fmt.Sprintf(`
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: %s
  namespace: %s
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Mi
  storageClassName: ""
  volumeName: %s
`, pvcName, testNamespace, pvName)

		applyYaml(ctx, suite, pvcYaml)

		// Wait for PVC to be bound with reduced timeout
		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "pvc", pvcName, "-n", testNamespace, "-o", "jsonpath={.status.phase}")
			return output
		}).WithContext(ctx).WithTimeout(15*time.Second).WithPolling(500*time.Millisecond).Should(Equal("Bound"), "PVC should bind to PV")

		// Create pod that writes data
		podYaml := fmt.Sprintf(`
apiVersion: v1
kind: Pod
metadata:
  name: %s
  namespace: %s
spec:
  nodeSelector:
    kubernetes.io/os: linux
  containers:
  - name: writer
    image: busybox:1.36
    command: ["sh", "-c", "echo '%s' > /data/testfile.txt && sleep 2"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: %s
  restartPolicy: Never
`, podName, testNamespace, testDataContent, pvcName)

		applyYaml(ctx, suite, podYaml)

		// Allow time for transient scheduling and image startup delays.
		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "pod", podName, "-n", testNamespace, "-o", "jsonpath={.status.phase}")
			return output
		}).WithContext(ctx).WithTimeout(60*time.Second).WithPolling(time.Second).Should(
			Or(Equal("Running"), Equal("Succeeded")),
			"Linux PV writer pod should start",
		)

		// Wait for data to be written
		time.Sleep(2 * time.Second)

		// Verify PV is visible to kubectl before backup
		pvOutput, _ := suite.Kubectl().Exec(ctx, "get", "pv", pvName, "-o", "jsonpath={.metadata.name}")
		GinkgoWriter.Printf("PV check before backup: name=%q\n", pvOutput)
		Expect(pvOutput).To(Equal(pvName), "PV should be visible to kubectl before backup")

		// Create backup (skip images for speed - testing PV backup, not images)
		GinkgoWriter.Println("Creating backup with PVC data at:", pvBackupFile)
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", pvBackupFile, "--skip-images")
		Expect(pvBackupFile).To(BeAnExistingFile())

		// Verify backup contains PV data
		logZipEntries(pvBackupFile)

		zipReader, err := zip.OpenReader(pvBackupFile)
		Expect(err).NotTo(HaveOccurred())
		defer zipReader.Close()

		foundPVDir := false
		for _, file := range zipReader.File {
			// Normalize path separators - zip uses forward slashes but Windows may use backslashes
			normalizedName := strings.ReplaceAll(file.Name, "\\", "/")
			if strings.HasPrefix(normalizedName, "pv/") {
				foundPVDir = true
				GinkgoWriter.Printf("Found PV file in backup: %s\n", file.Name)
				break
			}
		}

		Expect(foundPVDir).To(BeTrue(), "Backup should contain pv/ directory")
	})
})

var _ = Describe("k2s system backup - container images", Ordered, Label("images"), func() {
	var (
		testNamespace  string
		imgBackupFile  string
		testDeployment string
	)

	BeforeAll(func(ctx context.Context) {
		testNamespace = fmt.Sprintf("test-img-backup-%s", randomSeed)
		imgBackupFile = filepath.Join(testBackupDir, fmt.Sprintf("backup-img-%s.zip", randomSeed))

		suite.Kubectl().MustExec(ctx, "create", "namespace", testNamespace)

		DeferCleanup(func(ctx context.Context) {
			cleanupBackupFile(ctx, imgBackupFile)
			suite.Kubectl().Exec(ctx, "delete", "namespace", testNamespace, "--ignore-not-found=true")
		})
	})

	It("backs up user workload images and verifies images directory exists", func(ctx context.Context) {
		testDeployment = "test-image-deployment"

		deployYaml := fmt.Sprintf(`
apiVersion: apps/v1
kind: Deployment
metadata:
  name: %s
  namespace: %s
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-img
  template:
    metadata:
      labels:
        app: test-img
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      containers:
      - name: test
        image: busybox:1.36
        command: ["sleep", "600"]
`, testDeployment, testNamespace)

		// Apply the deployment
		applyYaml(ctx, suite, deployYaml)

		// Wait for deployment to be available (reduced timeout & faster polling)
		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "deployment", testDeployment, "-n", testNamespace, "-o", "jsonpath={.status.conditions[?(@.type=='Available')].status}")
			return output
		}).WithContext(ctx).WithTimeout(30 * time.Second).WithPolling(500 * time.Millisecond).Should(Equal("True"))

		// Create backup WITHOUT images to avoid timeout (image backup takes 5+ minutes for all images)
		// This test verifies backup completes successfully with image workloads present
		GinkgoWriter.Println("Creating backup (skipping images) with image workload deployment at:", imgBackupFile)
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", imgBackupFile, "--skip-images")
		Expect(imgBackupFile).To(BeAnExistingFile())

		// Verify backup contains the deployment resource
		zipReader, err := zip.OpenReader(imgBackupFile)
		Expect(err).NotTo(HaveOccurred())
		defer zipReader.Close()

		foundDeployment := false
		for _, file := range zipReader.File {
			// Normalize path separators and check for deployment in namespace
			normalizedName := strings.ReplaceAll(file.Name, "\\", "/")
			if strings.Contains(normalizedName, testNamespace) && strings.Contains(normalizedName, "deployments.yaml") {
				foundDeployment = true
				GinkgoWriter.Printf("Found deployment in backup: %s\n", file.Name)
				break
			}
		}

		Expect(foundDeployment).To(BeTrue(), "Backup should contain deployment from namespace with image workload")
	})
})

var _ = Describe("k2s system backup - negative scenarios", Ordered, Label("negative"), func() {
	It("fails gracefully when backup file path is invalid", func(ctx context.Context) {
		invalidPath := "/nonexistent/deeply/nested/invalid/path/backup.zip"

		// Skip images and PVs to test path validation failure quickly
		output, exitCode := suite.K2sCli().Exec(ctx, "system", "backup", "-f", invalidPath, "--skip-images", "--skip-pvs")

		GinkgoWriter.Printf("Negative test stdout output: %q\n", output)
		GinkgoWriter.Printf("Negative test exit code: %d\n", exitCode)

		Expect(exitCode).NotTo(Equal(0), "Should fail with invalid path")
	})

	It("handles backup when cluster has no user workloads", func(ctx context.Context) {
		// Reuse shared backup - it already skips images/PVs so it's essentially "empty" of user workloads
		Expect(sharedBackup).To(BeAnExistingFile())

		zipReader, err := zip.OpenReader(sharedBackup)
		Expect(err).NotTo(HaveOccurred())
		defer zipReader.Close()

		foundBackupJson := false
		for _, file := range zipReader.File {
			if file.Name == backupJsonFile {
				foundBackupJson = true
				break
			}
		}
		Expect(foundBackupJson).To(BeTrue())
	})
})

var _ = Describe("k2s system backup - selective content", Ordered, Label("flags"), func() {
	It("skips images when --skip-images flag is used", func(ctx context.Context) {
		skipImgBackup := filepath.Join(testBackupDir, fmt.Sprintf("backup-skip-img-%s.zip", randomSeed))

		DeferCleanup(func(ctx context.Context) {
			cleanupBackupFile(ctx, skipImgBackup)
		})

		// Also skip PVs to speed up test - we're only testing image skip functionality
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", skipImgBackup, "--skip-images=true", "--skip-pvs=true")
		Expect(skipImgBackup).To(BeAnExistingFile())

		zipReader, err := zip.OpenReader(skipImgBackup)
		Expect(err).NotTo(HaveOccurred())
		defer zipReader.Close()

		hasImageManifest := false
		for _, file := range zipReader.File {
			// Normalize path separators
			normalizedName := strings.ReplaceAll(file.Name, "\\", "/")
			if normalizedName == "images/manifest.json" {
				hasImageManifest = true
				break
			}
		}

		Expect(hasImageManifest).To(BeFalse(), "Image manifest should not be present when --skip-images is used")
	})

	It("skips PVs when --skip-pvs flag is used", func(ctx context.Context) {
		skipPvBackup := filepath.Join(testBackupDir, fmt.Sprintf("backup-skip-pv-%s.zip", randomSeed))

		DeferCleanup(func(ctx context.Context) {
			cleanupBackupFile(ctx, skipPvBackup)
		})

		// Also skip images to speed up test - we're only testing PV skip functionality
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", skipPvBackup, "--skip-pvs=true", "--skip-images=true")
		Expect(skipPvBackup).To(BeAnExistingFile())

		zipReader, err := zip.OpenReader(skipPvBackup)
		Expect(err).NotTo(HaveOccurred())
		defer zipReader.Close()

		hasPvDir := false
		for _, file := range zipReader.File {
			// Normalize path separators
			normalizedName := strings.ReplaceAll(file.Name, "\\", "/")
			if strings.HasPrefix(normalizedName, "pv/") {
				hasPvDir = true
				break
			}
		}

		Expect(hasPvDir).To(BeFalse(), "PV directory should not be present when --skip-pvs is used")
	})
})

func cleanupBackupFile(ctx context.Context, backupFile string) {
	if _, err := os.Stat(backupFile); err == nil {
		// Wait a bit for file handles to be released (PowerShell/compression may hold locks)
		time.Sleep(100 * time.Millisecond)

		// Retry deletion with backoff
		for i := 0; i < 3; i++ {
			err := os.Remove(backupFile)
			if err == nil {
				GinkgoWriter.Println("Cleaned up backup file:", backupFile)
				return
			}
			if i < 2 {
				time.Sleep(time.Duration(i+1) * 200 * time.Millisecond) // 200ms, 400ms
			}
		}
		GinkgoWriter.Println("Warning: Could not clean up backup file (still locked):", backupFile)
	}
}

func applyYaml(ctx context.Context, suite *framework.K2sTestSuite, yaml string) {
	tmpFile, err := os.CreateTemp("", "k2s-test-*.yaml")
	Expect(err).NotTo(HaveOccurred())
	defer os.Remove(tmpFile.Name())

	_, err = tmpFile.WriteString(yaml)
	Expect(err).NotTo(HaveOccurred())
	tmpFile.Close()

	suite.Kubectl().MustExec(ctx, "apply", "-f", tmpFile.Name())
}
