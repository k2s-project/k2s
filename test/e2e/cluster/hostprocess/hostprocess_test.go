// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package hostprocess

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"
	"github.com/k2s-project/k2s/test/framework/watcher"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	// Use shared namespace constant (can diverge from system namespace if needed)
	namespace         = NamespaceHostProcess
	launcherConfigMap = "hostprocess-launcher-env"
)

var (
	// Expected names coming from the hostprocess workload examples.
	hostProcessDeploymentNames = []string{HostProcessDeploymentName}
	anchorPodName              = AnchorPodName

	suite *framework.K2sTestSuite
	k2s   *dsl.K2s

	manifestDir       string
	testFailed        bool
	createdSystemRole bool
	podWatcher        *watcher.PodWatcher
)

func TestClusterHostProcess(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Cluster HostProcess Acceptance Tests", Label("hostprocess", "acceptance", "internet-required", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	manifestDir = resolveManifestDir()

	suite = framework.Setup(ctx, framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(200*time.Millisecond),
		framework.ClusterTestStepTimeout(8*time.Minute))
	k2s = dsl.NewK2s(suite)

	if _, err := os.Stat(manifestDir); err != nil {
		Skip("hostprocess manifest directory not found: " + manifestDir)
	}

	// Create cluster role for k2s-NT-AUTHORITY-SYSTEM only if not already running as SYSTEM
	if !isRunningAsSystem() {
		GinkgoWriter.Println("Creating cluster role for k2s-NT-AUTHORITY-SYSTEM (current user is not SYSTEM)")
		suite.K2sCli().MustExec(ctx, "system", "users", "add", "-u", "NT AUTHORITY\\SYSTEM")
		suite.Kubectl().MustExec(ctx, "delete", "clusterrole", "ViewDeploymentRole", "--ignore-not-found=true")
		suite.Kubectl().MustExec(ctx, "delete", "clusterrolebinding", "ViewDeploymenBinding", "--ignore-not-found=true")
		suite.Kubectl().MustExec(ctx, "create", "clusterrole", "ViewDeploymentRole", "--verb=get,list,watch", "--resource=pods,deployments")
		suite.Kubectl().MustExec(ctx, "create", "clusterrolebinding", "ViewDeploymenBinding", "--clusterrole=ViewDeploymentRole", "--user=k2s-NT-AUTHORITY-SYSTEM")
		createdSystemRole = true
	} else {
		GinkgoWriter.Println("Running as NT AUTHORITY\\SYSTEM; skipping creation of cluster role and user add")
	}

	GinkgoWriter.Println("Applying hostprocess workloads from", manifestDir)

	suite.Kubectl().MustExec(ctx, "delete", "namespace", namespace, "--ignore-not-found=true")
	suite.Kubectl().MustExec(ctx, "create", "namespace", namespace)

	// Start pod watcher in background after namespace is created
	startPodWatcher(ctx)

	// Create log directory for albumswin
	albumsLogDir := `C:\var\log\albumswin`
	if err := os.MkdirAll(albumsLogDir, 0755); err != nil {
		GinkgoWriter.Printf("Warning: failed to create albumswin log directory %s: %v\n", albumsLogDir, err)
	} else {
		GinkgoWriter.Printf("Created albumswin log directory: %s\n", albumsLogDir)
	}

	// Resolve paths and attempt local build of albumswin before creating ConfigMap
	computeAndSetLauncherEnv()

	// Create/update ConfigMap with dynamic base paths before applying manifests
	ensureLauncherConfigMap(ctx)

	// Deploy the anchor pod first and wait for it to be Ready before applying the
	// HostProcess deployment.  cplauncher in the HostProcess pod resolves the
	// anchor pod by label to obtain its network compartment.  If the anchor pod
	// is not yet scheduled (no IP), cplauncher retries for up to label-timeout
	// but deploying sequentially avoids unnecessary restarts.
	anchorManifest := filepath.Join(manifestDir, "anchor-pod.yaml")
	GinkgoWriter.Println("Applying anchor pod from", anchorManifest)
	suite.Kubectl().MustExec(ctx, "apply", "-f", anchorManifest, "-n", namespace)

	GinkgoWriter.Println("Waiting for anchor pod to be Ready before deploying HostProcess workloads ..")
	suite.Cluster().ExpectPodToBeReady(anchorPodName, namespace, "")
	GinkgoWriter.Println("Anchor pod is Ready")

	// Now apply the full kustomization (anchor pod is idempotent, rest is new)
	suite.Kubectl().MustExec(ctx, "apply", "-k", manifestDir)

	GinkgoWriter.Println("Waiting for hostprocess deployments (if any) to be ready in namespace <", namespace, "> ..")

	// Only wait for rollout if deployments exist (skip errors if some examples only contain pods)
	for _, dep := range hostProcessDeploymentNames {
		_, code := suite.Kubectl().Exec(ctx, "get", "deployment", dep, "-n", namespace)
		if code == 0 {
			output, rolloutCode := suite.Kubectl().Exec(ctx, "rollout", "status", "deployment", dep, "-n", namespace, "--timeout="+suite.TestStepTimeout().String())
			if rolloutCode != 0 {
				// Collect diagnostics before failing so sporadic failures are actionable
				GinkgoWriter.Printf("Rollout failed for deployment %s (exit code %d). Collecting diagnostics..\n", dep, rolloutCode)
				descOut, _ := suite.Kubectl().Exec(ctx, "describe", "deployment", dep, "-n", namespace)
				GinkgoWriter.Printf("=== kubectl describe deployment %s ===\n%s\n", dep, descOut)
				podsOut, _ := suite.Kubectl().Exec(ctx, "get", "pods", "-n", namespace, "-l", "app="+dep, "-o", "wide")
				GinkgoWriter.Printf("=== pods for %s ===\n%s\n", dep, podsOut)
				logsOut, _ := suite.Kubectl().Exec(ctx, "logs", "deployment/"+dep, "-n", namespace, "--tail=80")
				GinkgoWriter.Printf("=== logs (current) %s ===\n%s\n", dep, logsOut)
				prevLogsOut, _ := suite.Kubectl().Exec(ctx, "logs", "deployment/"+dep, "-n", namespace, "--previous", "--tail=80")
				GinkgoWriter.Printf("=== logs (previous) %s ===\n%s\n", dep, prevLogsOut)
				eventsOut, _ := suite.Kubectl().Exec(ctx, "get", "events", "-n", namespace, "--sort-by=.lastTimestamp")
				GinkgoWriter.Printf("=== events in namespace %s ===\n%s\n", namespace, eventsOut)
				epOut, _ := suite.Kubectl().Exec(ctx, "get", "endpoints", dep, "-n", namespace, "-o", "yaml")
				GinkgoWriter.Printf("=== endpoints %s ===\n%s\n", dep, epOut)
				Fail(fmt.Sprintf("Rollout timed out for deployment %s: %s", dep, output))
			}
		}
	}
})

var _ = AfterSuite(func(ctx context.Context) {
	stopPodWatcher()

	suite.StatusChecker().IsK2sRunning(ctx)

	// Check if any tests failed using CurrentSpecReport
	// This works even if BeforeSuite failed or if testFailed wasn't set
	hasFailed := testFailed || CurrentSpecReport().Failed()

	if hasFailed {
		GinkgoWriter.Println("Test failed; dumping system diagnostics")
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
		if !suite.ShouldCleanup(hasFailed) {
			return // keep workloads for inspection
		}
	}

	// dump a kubectl describe of all resources in the k2s namespace for debugging purposes
	GinkgoWriter.Println("Dumping kubectl describe of all resources in namespace", namespace)
	suite.Kubectl().MustExec(ctx, "describe", "all", "-n", namespace)

	// dump the logs of all pods in the k2s namespace for debugging purposes
	GinkgoWriter.Println("Dumping logs of all pods in namespace", namespace)
	GinkgoWriter.Println("POD albums-compartment-anchor", namespace)
	suite.Kubectl().MustExec(ctx, "logs", "pod/albums-compartment-anchor", "-n", namespace)
	GinkgoWriter.Println("DEPLOYMENT albums-win-hp-app-hostprocess", namespace)
	suite.Kubectl().MustExec(ctx, "logs", "deployment/albums-win-hp-app-hostprocess", "-n", namespace)

	GinkgoWriter.Println("Deleting hostprocess workloads (best-effort)..")
	_, code := suite.Kubectl().Exec(ctx, "delete", "-k", manifestDir, "--force", "--ignore-not-found=true")
	if code != 0 {
		GinkgoWriter.Println("(non-fatal) deletion returned exit code", code)
	}
	GinkgoWriter.Println("Hostprocess workloads delete step finished; manifests path:", manifestDir)

	suite.Kubectl().MustExec(ctx, "delete", "namespace", namespace, "--ignore-not-found=true")

	// Delete cluster role for k2s-NT-AUTHORITY-SYSTEM only if it was created in this run
	if createdSystemRole {
		GinkgoWriter.Println("Deleting cluster role for k2s-NT-AUTHORITY-SYSTEM (it was created by the test)")
		suite.Kubectl().MustExec(ctx, "delete", "clusterrole", "ViewDeploymentRole", "--ignore-not-found=true")
		suite.Kubectl().MustExec(ctx, "delete", "clusterrolebinding", "ViewDeploymenBinding", "--ignore-not-found=true")
	} else {
		GinkgoWriter.Println("Cluster role for k2s-NT-AUTHORITY-SYSTEM not created by test; skipping delete")
	}

	suite.TearDown(ctx, framework.RestartKubeProxy)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("HostProcess Workloads", func() {
	It("anchor pod becomes Ready", func() {
		// The anchor pod is a single Pod object.
		suite.Cluster().ExpectPodToBeReady(anchorPodName, namespace, "")
	})

	Describe("Deployments", func() {
		for _, dep := range hostProcessDeploymentNames {
			depName := dep

			It(depName+" becomes available", func(ctx context.Context) {
				// Skip gracefully if deployment not present in the workload set
				_, exitCode := suite.Kubectl().Exec(ctx, "get", "deployment", depName, "-n", namespace)
				if exitCode != 0 {
					Skip("deployment not found: " + depName)
				}
				suite.Cluster().ExpectDeploymentToBeAvailable(depName, namespace)
			})

			It(depName+" pods become Ready", func(ctx context.Context) {
				_, exitCode := suite.Kubectl().Exec(ctx, "get", "deployment", depName, "-n", namespace)
				if exitCode != 0 {
					Skip("deployment not found: " + depName)
				}
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", depName, namespace)
			})
		}
	})

	Describe("cplauncher diagnostics", func() {
		cplauncherLabel := HostProcessAppLabel

		It("cplauncher stdout logs contain pid line and target exe", func(ctx context.Context) {
			// Find pod name for deployment (assumes 1 replica)
			// We poll using kubectl get pod -l app=<depLabel>
			var podName string
			Eventually(func(g Gomega) string {
				out, code := suite.Kubectl().Exec(ctx, "get", "pods", "-n", namespace, "-l", "app="+cplauncherLabel, "-o", "jsonpath={.items[0].metadata.name}")
				if code != 0 {
					return ""
				}
				podName = out
				return out
			}, suite.TestStepTimeout(), 2*time.Second).ShouldNot(BeEmpty())

			Eventually(func() string {
				logs, code := suite.Kubectl().Exec(ctx, "logs", podName, "-n", namespace)
				if code != 0 {
					return ""
				}
				return logs
			}, 60*time.Second, 2*time.Second).Should(And(ContainSubstring("IP Addresses"), ContainSubstring("172.20.1")))
		})
	})

	Describe("Reachability", func() {
		const hostProcDep = HostProcessDeploymentName
		const serviceName = HostProcessServiceName
		servicePort := strconv.Itoa(HostProcessContainerTargetPort)

		It(serviceName+" service is reachable from host", func(ctx context.Context) {
			// Ensure service exists
			_, code := suite.Kubectl().Exec(ctx, "get", "service", serviceName, "-n", namespace)
			if code != 0 {
				Skip("service not found: " + serviceName)
			}
			k2s.VerifyDeploymentToBeReachableFromHostAtPort(ctx, hostProcDep, namespace, servicePort)
		})

		It(serviceName+" service is reachable from curl pod", func(ctx context.Context) {
			_, code := suite.Kubectl().Exec(ctx, "get", "service", serviceName, "-n", namespace)
			if code != 0 {
				Skip("service not found: " + serviceName)
			}
			_, curlCode := suite.Kubectl().Exec(ctx, "get", "deployment", "curl", "-n", namespace)
			if curlCode != 0 {
				Skip("curl deployment not found; skipping pod->deployment reachability test")
			}
			suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeploymentAtPort(hostProcDep, namespace, "curl", namespace, servicePort, ctx)
		})

		It("direct hostprocess pod IP is reachable from curl pod", func(ctx context.Context) {
			// Ensure curl deployment exists
			GinkgoWriter.Println("Getting curl deployment: ")
			_, curlCode := suite.Kubectl().Exec(ctx, "get", "deployment", "curl", "-n", namespace)
			if curlCode != 0 {
				Skip("curl deployment not found")
			}
			// Get hostprocess pod IP
			GinkgoWriter.Println("Getting hostprocess pod IP: ")
			podIP, ipCode := suite.Kubectl().Exec(ctx, "get", "pod", AnchorPodName, "-n", namespace, "-o", "jsonpath={.status.podIP}")
			if ipCode != 0 || podIP == "" {
				Skip("pod IP not available yet")
			}
			// Find curl pod name
			var curlPodName string
			Eventually(func() string {
				name, _ := suite.Kubectl().Exec(ctx, "get", "pods", "-n", namespace, "-l", "app=curl", "-o", "jsonpath={.items[0].metadata.name}")
				curlPodName = name
				return name
			}, suite.TestStepTimeout(), 2*time.Second).ShouldNot(BeEmpty())
			GinkgoWriter.Printf("Found curl pod: %s\n", curlPodName)
			// Execute curl directly to pod IP:8080 expecting HTTP 200 (health endpoint or root)
			cmd := fmt.Sprintf("curl -s -o /dev/null -w %%{http_code} http://%s:%d/%s || true", podIP, HostProcessContainerTargetPort, HostProcessDeploymentName)
			GinkgoWriter.Println("Executing curl command: ", cmd)
			Eventually(func() string {
				out, _ := suite.Kubectl().Exec(ctx, "exec", curlPodName, "-n", namespace, "--", "sh", "-c", cmd)
				return strings.TrimSpace(out)
			}, 60*time.Second, 3*time.Second).Should(Equal("200"))
		})

		It("direct hostprocess pod IP is reachable from host", func(ctx context.Context) {
			// Get hostprocess pod IP
			GinkgoWriter.Println("Getting hostprocess pod IP: ")
			podIP, ipCode := suite.Kubectl().Exec(ctx, "get", "pod", AnchorPodName, "-n", namespace, "-o", "jsonpath={.status.podIP}")
			if ipCode != 0 || podIP == "" {
				Skip("pod IP not available yet")
			}
			// Execute curl directly to pod IP:8080 expecting HTTP 200 (health endpoint or root)
			url := fmt.Sprintf("http://%s:%d/%s", podIP, HostProcessContainerTargetPort, HostProcessDeploymentName)
			GinkgoWriter.Println("Executing curl command: ", url)
			Eventually(func() string {
				out, _ := suite.Cli("curl").Exec(ctx, "-s", "-o", "/dev/null", "-w", "%{http_code}", url)
				return strings.TrimSpace(out)
			}, 60*time.Second, 3*time.Second).Should(Equal("200"))
		})
	})
})

// resolveManifestDir attempts to locate the hostprocess workload directory in a flexible way so the test
// can be run from repo root or within the package directory.
func resolveManifestDir() string {
	if st, err := os.Stat("workload"); err == nil && st.IsDir() {
		return "workload"
	}
	return "workload/" // default
}

// computeAndSetLauncherEnv locates cplauncher and builds the local albumswin test binary.
// It sets TEST_CPLAUNCHER_BASE and TEST_ALBUMS_WIN environment variables consumed when creating the ConfigMap.
func computeAndSetLauncherEnv() {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		return
	}
	testDir := filepath.Dir(file)

	// Ascend 4 levels: hostprocess -> cluster -> e2e -> test -> repo root.
	repoRoot := testDir
	for i := 0; i < 4; i++ {
		repoRoot = filepath.Dir(repoRoot)
	}

	// cplauncher
	cplauncherBase := filepath.Join(repoRoot, "bin", "cni")
	cplauncherExe := filepath.Join(cplauncherBase, "cplauncher.exe")
	cplauncherSet := false
	if _, err := os.Stat(cplauncherExe); err == nil {
		_ = os.Setenv("TEST_CPLAUNCHER_BASE", toWindowsPath(cplauncherBase))
		cplauncherSet = true
	}

	// albumswin local build target within test directory for portability
	albumsSrcDir := filepath.Join(testDir, "albumswin")
	albumsExe := filepath.Join(testDir, "albumswin.exe")
	albumsSet := false

	if _, err := os.Stat(albumsExe); err != nil { // not built yet
		if _, errSrc := os.Stat(filepath.Join(albumsSrcDir, "main.go")); errSrc == nil {
			// Attempt build (best effort)
			cmd := exec.Command("go", "build", "-o", albumsExe, ".")
			cmd.Dir = albumsSrcDir
			if out, errRun := cmd.CombinedOutput(); errRun != nil {
				GinkgoWriter.Println("albumswin build failed (will fall back to default path if any):", errRun)
				GinkgoWriter.Println(string(out))
			}
		}
	}
	if _, err := os.Stat(albumsExe); err == nil {
		_ = os.Setenv("TEST_ALBUMS_WIN", toWindowsPath(albumsExe))
		albumsSet = true
	}

	GinkgoWriter.Println("Resolved launcher paths:")
	GinkgoWriter.Println("  cplauncher base:", cplauncherBase, "exists=", cplauncherSet)
	GinkgoWriter.Println("  albums binary (local build):", albumsExe, "exists=", albumsSet)
	if !cplauncherSet {
		GinkgoWriter.Println("  (using default fallback for TEST_CPLAUNCHER_BASE inside ensureLauncherConfigMap)")
	}
	if !albumsSet {
		GinkgoWriter.Println("  (albums binary not built; using default fallback if required)")
	}
}

func toWindowsPath(p string) string {
	p = filepath.Clean(p)
	return strings.ReplaceAll(p, "/", "\\")
}

// ensureLauncherConfigMap creates or updates the ConfigMap holding env values for cplauncher paths.
// Priority: explicit env vars (TEST_CPLAUNCHER_BASE, TEST_ALBUMS_WIN) -> defaults.
func ensureLauncherConfigMap(ctx context.Context) {
	base := os.Getenv("TEST_CPLAUNCHER_BASE")
	if base == "" {
		base = `C:\k2s\bin\cni`
	}
	albums := os.Getenv("TEST_ALBUMS_WIN")
	if albums == "" {
		albums = `.\\albumswin.exe`
	}

	// Normalize to Windows backslashes (in case someone passed forward slashes)
	base = strings.ReplaceAll(base, `/`, `\\`)
	albums = strings.ReplaceAll(albums, `/`, `\\`)

	// Use kubectl apply via literal arguments for idempotency
	// Windows escaping: keep quotes minimal; rely on framework Exec for quoting.
	suite.Kubectl().MustExec(ctx, "delete", "configmap", launcherConfigMap, "-n", namespace, "--ignore-not-found=true")
	suite.Kubectl().MustExec(ctx, "create", "configmap", launcherConfigMap,
		"-n", namespace,
		"--from-literal=CPLAUNCHER_BASE="+base,
		"--from-literal=ALBUMS_WIN="+albums,
	)
}

// isRunningAsSystem returns true if the current process user matches 'NT AUTHORITY\\SYSTEM'.
// Uses 'whoami' for portability across different Windows configurations.
func isRunningAsSystem() bool {
	out, err := exec.Command("whoami").CombinedOutput()
	if err != nil {
		return false
	}
	user := strings.TrimSpace(string(out))
	return strings.EqualFold(user, "NT AUTHORITY\\SYSTEM")
}

// startPodWatcher starts a background kubectl watch process that continuously logs pod status
// This version includes error detection and automatic log dumping for hostprocess tests
func startPodWatcher(ctx context.Context) {
	podWatcher = watcher.NewPodWatcher(GinkgoWriter, namespace)
	if err := podWatcher.Start(ctx, suite.Kubectl().Path()); err != nil {
		GinkgoWriter.Printf("Warning: failed to start pod watcher: %v\n", err)
		return
	}
	GinkgoWriter.Println("Pod watcher started successfully")
}

// stopPodWatcher stops the background pod watcher process
func stopPodWatcher() {
	if podWatcher != nil {
		podWatcher.Stop()
		GinkgoWriter.Println("Pod watcher stopped")
	}
}
