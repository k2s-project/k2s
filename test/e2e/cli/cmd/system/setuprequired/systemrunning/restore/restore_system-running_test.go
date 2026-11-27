// SPDX-FileCopyrightText: © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package restore

import (
	"archive/zip"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	successMessage  = "System restore completed"
	testDataContent = "test-data-for-integrity-check-12345"
)

var (
	suite           *framework.K2sTestSuite
	randomSeed      string
	validBackupFile string
	testTempDir     string
)

func TestRestoreSystemRunning(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "System Restore Acceptance Tests", Label("e2e", "system", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning)
	randomSeed = strconv.FormatInt(GinkgoRandomSeed(), 10)

	// Create test temp directory
	var err error
	testTempDir, err = os.MkdirTemp("", "k2s-restore-test-*")
	Expect(err).ToNot(HaveOccurred())

	// Cleanup orphaned resources from previous test runs (async, non-blocking)
	GinkgoWriter.Println("Cleaning up orphaned test resources from previous runs...")

	// Cleanup orphaned PVs (async)
	output, _ := suite.Kubectl().Exec(ctx, "get", "pv", "-o", "jsonpath={.items[*].metadata.name}")
	if output != "" {
		pvNames := strings.Fields(output)
		for _, pvName := range pvNames {
			if strings.Contains(pvName, "test-restore-pv-") || strings.Contains(pvName, "test-backup-pv-") {
				suite.Kubectl().Exec(ctx, "delete", "pv", pvName, "--ignore-not-found=true", "--wait=false")
			}
		}
	}

	// Cleanup orphaned test namespaces (async)
	nsOutput, _ := suite.Kubectl().Exec(ctx, "get", "ns", "-o", "jsonpath={.items[*].metadata.name}")
	if nsOutput != "" {
		namespaces := strings.Fields(nsOutput)
		for _, ns := range namespaces {
			if strings.Contains(ns, "test-pv-restore-") || strings.Contains(ns, "test-img-restore-") ||
				strings.Contains(ns, "test-restore-multi-") || strings.Contains(ns, "test-orphan-") {
				suite.Kubectl().Exec(ctx, "delete", "namespace", ns, "--ignore-not-found=true", "--timeout=30s", "--wait=false")
			}
		}
	}

	time.Sleep(500 * time.Millisecond) // Minimal wait for cleanup to start

	// Create valid backup file
	validBackupFile = createValidBackupForRestore(ctx)

	DeferCleanup(func(ctx context.Context) {
		cleanupBackupFile(ctx, validBackupFile)
	})
})

var _ = AfterSuite(func(ctx context.Context) {
	if testTempDir != "" {
		os.RemoveAll(testTempDir)
	}
	suite.TearDown(ctx)
})

var _ = Describe("'k2s system restore'", Ordered, func() {
	Describe("success scenarios", func() {
		Context("with valid backup file", func() {
			It("restores system from valid backup (CRD conflicts expected)", func(ctx context.Context) {
				GinkgoWriter.Println("Restoring system from:", validBackupFile)
				GinkgoWriter.Println("Note: CRD conflicts are expected when restoring to a running cluster")

				output, _ := suite.K2sCli().Exec(ctx, "system", "restore", "-f", validBackupFile)

				// When restoring to a running cluster, CRD conflicts are normal
				// The restore should proceed and log these as warnings
				Expect(output).To(Or(
					ContainSubstring(successMessage),
					ContainSubstring("Restoring cluster-scoped resources"),
					ContainSubstring("Restoring namespaced resources"),
				), "Should show restore progress")
			})

			It("backup file remains intact after restore", func(ctx context.Context) {
				Expect(validBackupFile).To(BeAnExistingFile(), "Backup file should still exist after restore")
			})
		})
	})

	Describe("with --error-on-failure flag", func() {
		Context("when backup file does not exist", func() {
			It("exits with failure code", func(ctx context.Context) {
				nonExistentFile := filepath.Join(testTempDir, "non-existent-backup.zip")

				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx,
					"system", "restore",
					"-f", nonExistentFile,
					"-e")

				Expect(output).To(Or(
					ContainSubstring("Backup file not found"),
					ContainSubstring("not found"),
				))
			})
		})

		Context("when backup file is invalid or corrupted", func() {
			var corruptedFile string

			BeforeAll(func() {
				corruptedFile = filepath.Join(testTempDir, "corrupted-backup.zip")
				err := os.WriteFile(corruptedFile, []byte("invalid zip content"), 0644)
				Expect(err).ToNot(HaveOccurred())
			})

			It("exits with failure code when restoration fails", func(ctx context.Context) {
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx,
					"system", "restore",
					"-f", corruptedFile,
					"-e")

				Expect(output).To(Or(
					ContainSubstring("failed"),
					ContainSubstring("error"),
					ContainSubstring("invalid"),
					ContainSubstring("corrupted"),
				))
			})
		})

		Context("with valid backup containing resources", func() {
			It("successfully restores the system with error flag enabled", func(ctx context.Context) {
				// This uses the suite-level validBackupFile created in BeforeSuite
				// which contains valid K8s resources
				suite.K2sCli().MustExec(ctx, "system", "restore", "-f", validBackupFile, "-e")
				// MustExec will fail the test if exit code is non-zero
			})
		})
	})
})

func createValidBackupForRestore(ctx context.Context) string {
	backupFile := filepath.Join(testTempDir, fmt.Sprintf("valid-backup-%s.zip", randomSeed))

	GinkgoWriter.Println("Creating backup for restore tests at:", backupFile)
	GinkgoWriter.Println("Using --skip-images and --skip-pvs flags to speed up backup creation")

	// Use --skip-images and --skip-pvs flags to make backup faster for test setup
	// Individual tests that need images/PVs will create their own backups
	suite.K2sCli().MustExec(ctx, "system", "backup", "-f", backupFile, "--skip-images", "--skip-pvs")

	Expect(backupFile).To(BeAnExistingFile())
	GinkgoWriter.Println("Backup created successfully at:", backupFile)

	return backupFile
}

func cleanupBackupFile(ctx context.Context, backupFile string) {
	if backupFile == "" {
		return
	}

	GinkgoWriter.Println("Cleaning up backup file:", backupFile)

	// Wait a bit for file handles to be released
	time.Sleep(100 * time.Millisecond)

	// Retry deletion with backoff
	for i := 0; i < 3; i++ {
		err := os.Remove(backupFile)
		if err == nil {
			GinkgoWriter.Println("Successfully cleaned up backup file:", backupFile)
			return
		}
		if os.IsNotExist(err) {
			return // Already deleted
		}
		if i < 2 {
			time.Sleep(time.Duration(i+1) * 200 * time.Millisecond)
		}
	}
	GinkgoWriter.Printf("Warning: Could not clean up backup file (still locked): %s\n", backupFile)
}

var _ = Describe("'k2s system restore' - persistent volumes", Ordered, Label("pv"), func() {
	var (
		testNamespace   string
		pvRestoreBackup string
		pvcName         string
		podName         string
	)

	BeforeAll(func(ctx context.Context) {
		testNamespace = fmt.Sprintf("test-pv-restore-%s", randomSeed)
		pvRestoreBackup = filepath.Join(testTempDir, fmt.Sprintf("backup-pv-restore-%s.zip", randomSeed))

		suite.Kubectl().MustExec(ctx, "create", "namespace", testNamespace)

		DeferCleanup(func(ctx context.Context) {
			cleanupBackupFile(ctx, pvRestoreBackup)
			// Delete namespace first, which will delete PVC and release PV
			suite.Kubectl().Exec(ctx, "delete", "namespace", testNamespace, "--ignore-not-found=true", "--timeout=60s")
			// Then clean up any orphaned PVs (use --wait=false to avoid hanging)
			pvName := fmt.Sprintf("test-restore-pv-%s", randomSeed)
			suite.Kubectl().Exec(ctx, "delete", "pv", pvName, "--ignore-not-found=true", "--wait=false")
		})
	})

	It("creates backup with PVC, restores it, and verifies data integrity", func(ctx context.Context) {
		pvcName = "test-restore-pvc"
		podName = "test-restore-writer"
		pvName := fmt.Sprintf("test-restore-pv-%s", randomSeed)

		// Create PV first so PVC can bind
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
    path: /tmp/k2s-test-pv-%s
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/os
          operator: In
          values:
          - linux
  claimRef:
    name: %s
    namespace: %s
`, pvName, randomSeed, pvcName, testNamespace)

		applyYaml(ctx, suite, pvYaml)

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

		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "pvc", pvcName, "-n", testNamespace, "-o", "jsonpath={.status.phase}")
			return output
		}).WithContext(ctx).WithTimeout(20 * time.Second).WithPolling(500 * time.Millisecond).Should(Equal("Bound"))

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
    command: ["sh", "-c", "echo '%s' > /data/restore-test.txt && sleep 600"]
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

		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "pod", podName, "-n", testNamespace, "-o", "jsonpath={.status.phase}")
			return output
		}).WithContext(ctx).WithTimeout(60 * time.Second).WithPolling(time.Second).Should(Or(Equal("Running"), Equal("Succeeded")))

		time.Sleep(1 * time.Second) // Allow the writer to finish the initial write.

		GinkgoWriter.Println("Creating backup for PV restore test at:", pvRestoreBackup)
		// Use --skip-images since we're testing PV restore, not image backup
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", pvRestoreBackup, "--skip-images")
		Expect(pvRestoreBackup).To(BeAnExistingFile())

		// Remove the marker after backup so the test only passes if restore
		// actually puts the backed-up volume data back.
		_, exitCode := suite.Kubectl().Exec(ctx, "exec", podName, "-n", testNamespace, "--",
			"sh", "-c", "rm -f /data/restore-test.txt && test ! -e /data/restore-test.txt")
		Expect(exitCode).To(Equal(0), "the marker must be absent from the source volume before restore")

		// Now test restore - delete PV, PVC, and pod so restore creates them fresh.
		// The PV must be deleted because the backup strips spec.claimRef (by design),
		// but kubectl apply --server-side won't remove an existing claimRef owned by
		// the PV controller. A stale claimRef.uid causes the restored PVC to show "Lost".
		suite.Kubectl().Exec(ctx, "delete", "pod", podName, "-n", testNamespace, "--ignore-not-found=true", "--wait=false")
		suite.Kubectl().Exec(ctx, "delete", "pvc", pvcName, "-n", testNamespace, "--ignore-not-found=true")
		suite.Kubectl().Exec(ctx, "delete", "pv", pvName, "--ignore-not-found=true", "--wait=false")

		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "pvc", pvcName, "-n", testNamespace, "--ignore-not-found=true")
			return output
		}).WithContext(ctx).WithTimeout(15 * time.Second).WithPolling(500 * time.Millisecond).Should(BeEmpty())

		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "pv", pvName, "--ignore-not-found=true")
			return output
		}).WithContext(ctx).WithTimeout(15 * time.Second).WithPolling(500 * time.Millisecond).Should(BeEmpty())

		GinkgoWriter.Println("Restoring PVC from backup:", pvRestoreBackup)
		output := suite.K2sCli().MustExec(ctx, "system", "restore", "-f", pvRestoreBackup)
		Expect(output).To(ContainSubstring(successMessage))

		// Diagnostic: print PV state after restore to aid debugging
		pvOut, _ := suite.Kubectl().Exec(ctx, "get", "pv", pvName, "-o", "jsonpath={.status.phase},{.spec.claimRef.uid}")
		GinkgoWriter.Printf("After restore: PV %s status=%s\n", pvName, pvOut)

		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "pvc", pvcName, "-n", testNamespace, "-o", "jsonpath={.status.phase}")
			return output
		}).WithContext(ctx).WithTimeout(30 * time.Second).WithPolling(500 * time.Millisecond).Should(Equal("Bound"))

		// Verify data integrity
		readerPod := "test-restore-reader"
		readerYaml := fmt.Sprintf(`
apiVersion: v1
kind: Pod
metadata:
  name: %s
  namespace: %s
spec:
  nodeSelector:
    kubernetes.io/os: linux
  containers:
  - name: reader
    image: busybox:1.36
    command: ["sh", "-c", "cat /data/restore-test.txt && sleep 5"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: %s
  restartPolicy: Never
`, readerPod, testNamespace, pvcName)

		applyYaml(ctx, suite, readerYaml)

		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "pod", readerPod, "-n", testNamespace, "-o", "jsonpath={.status.phase}")
			return output
		}).WithContext(ctx).WithTimeout(60 * time.Second).WithPolling(time.Second).Should(Or(Equal("Running"), Equal("Succeeded")))

		time.Sleep(500 * time.Millisecond) // Minimal wait for logs
		logs, exitCode := suite.Kubectl().Exec(ctx, "logs", readerPod, "-n", testNamespace)
		Expect(exitCode).To(Equal(0))
		Expect(logs).To(ContainSubstring(testDataContent))
	})
})

var _ = Describe("'k2s system restore' - container images", Ordered, Label("images"), func() {
	var (
		testNamespace    string
		imgRestoreBackup string
		deploymentName   string
	)

	BeforeAll(func(ctx context.Context) {
		testNamespace = fmt.Sprintf("test-img-restore-%s", randomSeed)
		imgRestoreBackup = filepath.Join(testTempDir, fmt.Sprintf("backup-img-restore-%s.zip", randomSeed))

		suite.Kubectl().MustExec(ctx, "create", "namespace", testNamespace)

		DeferCleanup(func(ctx context.Context) {
			cleanupBackupFile(ctx, imgRestoreBackup)
			suite.Kubectl().Exec(ctx, "delete", "namespace", testNamespace, "--ignore-not-found=true")
		})
	})

	It("creates backup with deployment, restores it, and verifies deployment recreates using cached images", func(ctx context.Context) {
		deploymentName = "test-img-deploy"

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
      app: test-img-restore
  template:
    metadata:
      labels:
        app: test-img-restore
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      containers:
      - name: test
        image: busybox:1.36
        command: ["sleep", "600"]
`, deploymentName, testNamespace)

		applyYaml(ctx, suite, deployYaml)

		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "deployment", deploymentName, "-n", testNamespace, "-o", "jsonpath={.status.conditions[?(@.type=='Available')].status}")
			return output
		}).WithContext(ctx).WithTimeout(30 * time.Second).WithPolling(500 * time.Millisecond).Should(Equal("True"))

		// Use --skip-images since busybox:1.36 is already in cluster cache
		// This test verifies deployment restore works correctly when images are in cache
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", imgRestoreBackup, "--skip-images")

		// Now test restore - delete deployment
		suite.Kubectl().Exec(ctx, "delete", "deployment", deploymentName, "-n", testNamespace, "--wait=false")

		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "deployment", deploymentName, "-n", testNamespace, "--ignore-not-found=true")
			return output
		}).WithContext(ctx).WithTimeout(15 * time.Second).WithPolling(500 * time.Millisecond).Should(BeEmpty())

		// Restore from backup
		output := suite.K2sCli().MustExec(ctx, "system", "restore", "-f", imgRestoreBackup)
		Expect(output).To(ContainSubstring(successMessage))

		// Verify deployment is restored and becomes available
		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "deployment", deploymentName, "-n", testNamespace, "-o", "jsonpath={.status.conditions[?(@.type=='Available')].status}")
			return output
		}).WithContext(ctx).WithTimeout(30 * time.Second).WithPolling(500 * time.Millisecond).Should(Equal("True"))

		// Verify pods start successfully using cached images (no ImagePullBackOff)
		Eventually(func(ctx context.Context) bool {
			output, _ := suite.Kubectl().Exec(ctx, "get", "pods", "-n", testNamespace, "-l", "app=test-img-restore", "-o", "jsonpath={.items[*].status.containerStatuses[*].state.waiting.reason}")
			return !strings.Contains(output, "ImagePullBackOff") && !strings.Contains(output, "ErrImagePull")
		}).WithContext(ctx).WithTimeout(15 * time.Second).WithPolling(500 * time.Millisecond).Should(BeTrue())
	})
})

var _ = Describe("'k2s system restore' - negative scenarios", Ordered, Label("negative"), func() {

	It("handles idempotent restore (re-restore)", func(ctx context.Context) {
		idempotentBackup := filepath.Join(testTempDir, fmt.Sprintf("backup-idempotent-%s.zip", randomSeed))
		defer cleanupBackupFile(ctx, idempotentBackup)

		// Use skip flags since this test is about idempotent restore behavior, not images/PVs
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", idempotentBackup, "--skip-images", "--skip-pvs")

		output1 := suite.K2sCli().MustExec(ctx, "system", "restore", "-f", idempotentBackup)
		Expect(output1).To(ContainSubstring(successMessage))

		output2 := suite.K2sCli().MustExec(ctx, "system", "restore", "-f", idempotentBackup)
		Expect(output2).To(Or(
			ContainSubstring(successMessage),
			ContainSubstring("completed"),
		))
	})
})

var _ = Describe("'k2s system restore' - edge cases and system consistency", Ordered, Label("edge"), func() {
	It("restores multiple namespaces with resources", func(ctx context.Context) {
		multiNsBackup := filepath.Join(testTempDir, fmt.Sprintf("backup-multi-ns-%s.zip", randomSeed))
		testNsBase := fmt.Sprintf("test-restore-multi-%s", randomSeed)

		defer cleanupBackupFile(ctx, multiNsBackup)

		// Create multiple namespaces with resources - reduced from 3 to 2 for speed
		createdNs := []string{}
		for i := 0; i < 2; i++ {
			ns := fmt.Sprintf("%s-%d", testNsBase, i)
			createdNs = append(createdNs, ns)
			suite.Kubectl().MustExec(ctx, "create", "namespace", ns)

			cmYaml := fmt.Sprintf(`
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-cm
  namespace: %s
data:
  index: "%d"
`, ns, i)
			applyYaml(ctx, suite, cmYaml)
		}

		defer func() {
			for _, ns := range createdNs {
				suite.Kubectl().Exec(ctx, "delete", "namespace", ns, "--ignore-not-found=true")
			}
		}()

		// Backup (skip images/PVs since this test is about multiple namespace handling)
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", multiNsBackup, "--skip-images", "--skip-pvs")

		// Delete all test namespaces
		for _, ns := range createdNs {
			suite.Kubectl().Exec(ctx, "delete", "namespace", ns)
		}

		// Restore
		output := suite.K2sCli().MustExec(ctx, "system", "restore", "-f", multiNsBackup)
		Expect(output).To(ContainSubstring(successMessage))

		// Verify all namespaces and resources are restored
		for i, ns := range createdNs {
			Eventually(func(ctx context.Context) int {
				_, exitCode := suite.Kubectl().Exec(ctx, "get", "namespace", ns)
				return exitCode
			}).WithContext(ctx).WithTimeout(20 * time.Second).WithPolling(500 * time.Millisecond).Should(Equal(0))

			Eventually(func(ctx context.Context) string {
				output, _ := suite.Kubectl().Exec(ctx, "get", "configmap", "test-cm", "-n", ns, "-o", "jsonpath={.data.index}")
				return output
			}).WithContext(ctx).WithTimeout(20 * time.Second).WithPolling(500 * time.Millisecond).Should(Equal(fmt.Sprintf("%d", i)))
		}
	})
})

var _ = Describe("'k2s system restore' after Linux lifecycle restart", Ordered, Label("linux-only"), func() {
	It("restores a deleted workload after stop and start", func(ctx context.Context) {
		if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
			Skip("Linux-only")
		}

		testNamespace := fmt.Sprintf("test-restore-lifecycle-%s", randomSeed)
		backupFile := filepath.Join(testTempDir, fmt.Sprintf("backup-lifecycle-%s.zip", randomSeed))
		const (
			configMapName = "restore-lifecycle"
			configMapKey  = "marker"
			configMapData = "restored-after-lifecycle-restart"
		)

		suite.Kubectl().MustExec(ctx, "create", "namespace", testNamespace)
		DeferCleanup(func(ctx context.Context) {
			if !suite.StatusChecker().IsK2sRunning(ctx) {
				suite.K2sCli().MustExec(ctx, "start")
			}
			suite.Kubectl().Exec(ctx, "delete", "namespace", testNamespace, "--ignore-not-found=true", "--timeout=60s")
			cleanupBackupFile(ctx, backupFile)
		})

		configMap := fmt.Sprintf(`apiVersion: v1
kind: ConfigMap
metadata:
  name: %s
  namespace: %s
data:
  %s: %s
`, configMapName, testNamespace, configMapKey, configMapData)
		applyYaml(ctx, suite, configMap)

		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", backupFile, "--skip-images", "--skip-pvs")
		Expect(backupFile).To(BeAnExistingFile())
		suite.Kubectl().MustExec(ctx, "delete", "namespace", testNamespace, "--timeout=60s")

		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "namespace", testNamespace, "--ignore-not-found=true", "-o", "name")
			return output
		}).WithContext(ctx).WithTimeout(30 * time.Second).WithPolling(time.Second).Should(BeEmpty())

		suite.K2sCli().MustExec(ctx, "stop")
		Eventually(func(ctx context.Context) bool {
			return !suite.StatusChecker().IsK2sRunning(ctx)
		}).WithContext(ctx).WithTimeout(3 * time.Minute).WithPolling(5 * time.Second).Should(BeTrue())

		suite.K2sCli().MustExec(ctx, "start")
		Eventually(func(ctx context.Context) bool {
			return suite.StatusChecker().IsK2sRunning(ctx)
		}).WithContext(ctx).WithTimeout(5 * time.Minute).WithPolling(5 * time.Second).Should(BeTrue())

		output := suite.K2sCli().MustExec(ctx, "system", "restore", "-f", backupFile)
		Expect(output).To(ContainSubstring(successMessage))
		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "configmap", configMapName, "-n", testNamespace,
				"-o", fmt.Sprintf("jsonpath={.data.%s}", configMapKey))
			return output
		}).WithContext(ctx).WithTimeout(30 * time.Second).WithPolling(time.Second).Should(Equal(configMapData))
	})
})

var _ = Describe("'k2s system restore' - Linux host capabilities", Ordered, Label("linux-only"), func() {
	BeforeEach(func() {
		if runtime.GOOS != "linux" || !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
			Skip("Linux host only")
		}
	})

	It("backs up and restores user workload container images without --skip-images", func(ctx context.Context) {
		testNamespace := fmt.Sprintf("test-linux-img-%s", randomSeed)
		deploymentName := "test-linux-img-deploy"
		backupFile := filepath.Join(testTempDir, fmt.Sprintf("backup-linux-img-%s.zip", randomSeed))
		testImageRepo := "localhost/k2s-restore-e2e"
		testImage := fmt.Sprintf("%s:%s", testImageRepo, randomSeed)

		suite.Kubectl().MustExec(ctx, "create", "namespace", testNamespace)
		DeferCleanup(func(ctx context.Context) {
			cleanupBackupFile(ctx, backupFile)
			suite.Kubectl().Exec(ctx, "delete", "namespace", testNamespace, "--ignore-not-found=true", "--timeout=60s")
			suite.K2sCli().Exec(ctx, "image", "rm", "-n", testImage, "-f")
		})

		suite.K2sCli().MustExec(ctx, "image", "pull", "docker.io/library/busybox:1.36")
		suite.K2sCli().MustExec(ctx, "image", "tag", "-n", "docker.io/library/busybox:1.36", "-t", testImage)

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
      app: test-linux-img
  template:
    metadata:
      labels:
        app: test-linux-img
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      containers:
      - name: test
        image: %s
        imagePullPolicy: Never
        command: ["sleep", "600"]
`, deploymentName, testNamespace, testImage)
		applyYaml(ctx, suite, deployYaml)

		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "deployment", deploymentName, "-n", testNamespace,
				"-o", "jsonpath={.status.conditions[?(@.type=='Available')].status}")
			return output
		}).WithContext(ctx).WithTimeout(60 * time.Second).WithPolling(time.Second).Should(Equal("True"))

		// Do NOT pass --skip-images so image export and import are exercised end-to-end.
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", backupFile, "--skip-pvs")
		Expect(backupFile).To(BeAnExistingFile())

		zr, err := zip.OpenReader(backupFile)
		Expect(err).NotTo(HaveOccurred())
		hasManifest := false
		hasTar := false
		for _, f := range zr.File {
			name := strings.ReplaceAll(f.Name, "\\", "/")
			if name == "images/manifest.json" {
				hasManifest = true
			}
			if strings.HasPrefix(name, "images/") && strings.HasSuffix(name, ".tar") {
				hasTar = true
			}
		}
		_ = zr.Close()
		Expect(hasManifest).To(BeTrue(), "backup should contain images/manifest.json")
		Expect(hasTar).To(BeTrue(), "backup should contain at least one exported image .tar archive")

		suite.Kubectl().MustExec(ctx, "delete", "deployment", deploymentName, "-n", testNamespace, "--timeout=60s")
		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "pods", "-n", testNamespace, "-l", "app=test-linux-img", "--ignore-not-found=true")
			return output
		}).WithContext(ctx).WithTimeout(30 * time.Second).WithPolling(time.Second).Should(BeEmpty())

		// Remove the dedicated local tag and prove it is absent before restore so recovery must come from the archive.
		suite.K2sCli().MustExec(ctx, "image", "rm", "-n", testImage, "-f")
		Eventually(func(ctx context.Context) string {
			output, _ := suite.K2sCli().Exec(ctx, "image", "ls")
			return output
		}).WithContext(ctx).WithTimeout(15 * time.Second).WithPolling(time.Second).ShouldNot(ContainSubstring(testImageRepo))

		output := suite.K2sCli().MustExec(ctx, "system", "restore", "-f", backupFile, "-e")
		Expect(output).To(ContainSubstring(successMessage))

		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "deployment", deploymentName, "-n", testNamespace,
				"-o", "jsonpath={.status.conditions[?(@.type=='Available')].status}")
			return output
		}).WithContext(ctx).WithTimeout(60 * time.Second).WithPolling(time.Second).Should(Equal("True"))

		Eventually(func(ctx context.Context) bool {
			output, _ := suite.Kubectl().Exec(ctx, "get", "pods", "-n", testNamespace, "-l", "app=test-linux-img",
				"-o", "jsonpath={.items[*].status.containerStatuses[*].state.waiting.reason}")
			return !strings.Contains(output, "ImagePullBackOff") && !strings.Contains(output, "ErrImagePull")
		}).WithContext(ctx).WithTimeout(15 * time.Second).WithPolling(500 * time.Millisecond).Should(BeTrue())
	})

	It("executes additional backup and restore hooks via --additional-hooks-dir", func(ctx context.Context) {
		backupHooksDir := filepath.Join(testTempDir, fmt.Sprintf("backup-hooks-%s", randomSeed))
		restoreHooksDir := filepath.Join(testTempDir, fmt.Sprintf("restore-hooks-%s", randomSeed))
		Expect(os.MkdirAll(backupHooksDir, 0755)).To(Succeed())
		Expect(os.MkdirAll(restoreHooksDir, 0755)).To(Succeed())
		backupFile := filepath.Join(testTempDir, fmt.Sprintf("backup-hooks-%s.zip", randomSeed))
		restoreMarkerOut := filepath.Join(testTempDir, fmt.Sprintf("restore-hook-out-%s.txt", randomSeed))
		expectedMarker := fmt.Sprintf("hook-roundtrip-%s", randomSeed)

		DeferCleanup(func(ctx context.Context) {
			cleanupBackupFile(ctx, backupFile)
			_ = os.RemoveAll(backupHooksDir)
			_ = os.RemoveAll(restoreHooksDir)
			_ = os.Remove(restoreMarkerOut)
		})

		backupHook := fmt.Sprintf(`#!/usr/bin/env bash
set -euo pipefail
backup_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-dir) backup_dir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%%s' %q > "$backup_dir/e2e-hook.txt"
`, expectedMarker)
		Expect(os.WriteFile(filepath.Join(backupHooksDir, "e2e.Backup.sh"), []byte(backupHook), 0755)).To(Succeed())

		restoreHook := fmt.Sprintf(`#!/usr/bin/env bash
set -euo pipefail
backup_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-dir) backup_dir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$backup_dir/e2e-hook.txt" %q
`, restoreMarkerOut)
		Expect(os.WriteFile(filepath.Join(restoreHooksDir, "e2e.Restore.sh"), []byte(restoreHook), 0755)).To(Succeed())

		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", backupFile, "--skip-images", "--skip-pvs", "--additional-hooks-dir", backupHooksDir)
		Expect(backupFile).To(BeAnExistingFile())
		Expect(restoreMarkerOut).NotTo(BeAnExistingFile(), "backup must not execute restore hooks")

		zr, err := zip.OpenReader(backupFile)
		Expect(err).NotTo(HaveOccurred())
		foundHookFile := false
		for _, f := range zr.File {
			if strings.ReplaceAll(f.Name, "\\", "/") == "hooks/e2e-hook.txt" {
				foundHookFile = true
				break
			}
		}
		_ = zr.Close()
		Expect(foundHookFile).To(BeTrue(), "backup archive should include hooks/e2e-hook.txt written by backup hook")

		output := suite.K2sCli().MustExec(ctx, "system", "restore", "-f", backupFile, "--additional-hooks-dir", restoreHooksDir, "-e")
		Expect(output).To(ContainSubstring(successMessage))

		restoredBytes, err := os.ReadFile(restoreMarkerOut)
		Expect(err).NotTo(HaveOccurred(), "restore hook should have written output file")
		Expect(strings.TrimSpace(string(restoredBytes))).To(Equal(expectedMarker))
	})

	It("quiesces an active Deployment consumer and restores PV data in place", func(ctx context.Context) {
		testNamespace := fmt.Sprintf("test-pv-quiesce-%s", randomSeed)
		pvName := fmt.Sprintf("test-quiesce-pv-%s", randomSeed)
		pvcName := "test-quiesce-pvc"
		deploymentName := "test-quiesce-deploy"
		backupFile := filepath.Join(testTempDir, fmt.Sprintf("backup-pv-quiesce-%s.zip", randomSeed))
		expectedMarker := fmt.Sprintf("quiesce-marker-%s", randomSeed)

		suite.Kubectl().MustExec(ctx, "create", "namespace", testNamespace)
		DeferCleanup(func(ctx context.Context) {
			cleanupBackupFile(ctx, backupFile)
			suite.Kubectl().Exec(ctx, "delete", "namespace", testNamespace, "--ignore-not-found=true", "--timeout=60s")
			suite.Kubectl().Exec(ctx, "delete", "pv", pvName, "--ignore-not-found=true", "--wait=false")
		})

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
    path: /tmp/k2s-test-quiesce-pv-%s
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/os
          operator: In
          values:
          - linux
  claimRef:
    name: %s
    namespace: %s
`, pvName, randomSeed, pvcName, testNamespace)
		applyYaml(ctx, suite, pvYaml)

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

		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "pvc", pvcName, "-n", testNamespace, "-o", "jsonpath={.status.phase}")
			return output
		}).WithContext(ctx).WithTimeout(20 * time.Second).WithPolling(500 * time.Millisecond).Should(Equal("Bound"))

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
      app: test-pv-quiesce
  template:
    metadata:
      labels:
        app: test-pv-quiesce
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      containers:
      - name: app
        image: busybox:1.36
        command: ["sh", "-c", "sleep 600"]
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: %s
`, deploymentName, testNamespace, pvcName)
		applyYaml(ctx, suite, deployYaml)

		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "deployment", deploymentName, "-n", testNamespace,
				"-o", "jsonpath={.status.conditions[?(@.type=='Available')].status}")
			return output
		}).WithContext(ctx).WithTimeout(60 * time.Second).WithPolling(time.Second).Should(Equal("True"))

		// Write the marker into the mounted volume before backup.
		_, exitCode := suite.Kubectl().Exec(ctx, "exec", "deployment/"+deploymentName, "-n", testNamespace, "--",
			"sh", "-c", fmt.Sprintf("printf '%%s' %q > /data/quiesce.txt", expectedMarker))
		Expect(exitCode).To(Equal(0))

		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", backupFile, "--skip-images")
		Expect(backupFile).To(BeAnExistingFile())

		// Overwrite the marker while the Deployment is still running.
		_, exitCode = suite.Kubectl().Exec(ctx, "exec", "deployment/"+deploymentName, "-n", testNamespace, "--",
			"sh", "-c", "printf 'corrupted-after-backup' > /data/quiesce.txt")
		Expect(exitCode).To(Equal(0))

		// Restore in place: Linux restore must scale down the Deployment, restore the PV, and scale it back up.
		output := suite.K2sCli().MustExec(ctx, "system", "restore", "-f", backupFile, "-e")
		Expect(output).To(ContainSubstring(successMessage))

		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "deployment", deploymentName, "-n", testNamespace,
				"-o", "jsonpath={.status.conditions[?(@.type=='Available')].status}")
			return output
		}).WithContext(ctx).WithTimeout(60 * time.Second).WithPolling(time.Second).Should(Equal("True"))

		Eventually(func(ctx context.Context) string {
			out, code := suite.Kubectl().Exec(ctx, "exec", "deployment/"+deploymentName, "-n", testNamespace, "--",
				"cat", "/data/quiesce.txt")
			if code != 0 {
				return ""
			}
			return strings.TrimSpace(out)
		}).WithContext(ctx).WithTimeout(30 * time.Second).WithPolling(time.Second).Should(Equal(expectedMarker))
	})
})

func applyYaml(ctx context.Context, suite *framework.K2sTestSuite, yaml string) {
	tmpFile, err := os.CreateTemp("", "k2s-test-*.yaml")
	Expect(err).NotTo(HaveOccurred())
	defer os.Remove(tmpFile.Name())

	_, err = tmpFile.WriteString(yaml)
	Expect(err).NotTo(HaveOccurred())
	tmpFile.Close()

	suite.Kubectl().MustExec(ctx, "apply", "-f", tmpFile.Name())
}
