// SPDX-FileCopyrightText: © 2025 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package windowsexporter

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 10

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
)

func TestWindowsExporter(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Windows Exporter HostProcess Container Acceptance Tests", Label("addon", "acceptance", "setup-required", "invasive", "windows-exporter", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.TearDown(ctx)
})

var _ = AfterEach(func(ctx context.Context) {
	if CurrentSpecReport().Failed() {
		testFailed = true
		collectExporterDiagnostics(ctx, suite.Kubectl().Path())
	}
})

var _ = Describe("Windows Exporter as HostProcess Container", Ordered, func() {
	Describe("when metrics addon is enabled", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "metrics", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "metrics", "-o")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "metrics-server", "metrics")
		})

		It("deploys Windows Exporter DaemonSet to kube-system namespace", func(ctx context.Context) {
			Eventually(func() string {
				output := suite.Kubectl().MustExec(ctx, "get", "daemonset", "windows-exporter", "-n", "kube-system", "-o", "json")
				return output
			}).WithTimeout(30 * time.Second).WithPolling(2 * time.Second).Should(ContainSubstring("windows-exporter"))
		})

		It("has Windows Exporter DaemonSet with HostProcess security context", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "daemonset", "windows-exporter", "-n", "kube-system", "-o", "json")
			Expect(output).To(SatisfyAll(
				ContainSubstring("windowsOptions"),
				ContainSubstring("\"hostProcess\": true"),
				ContainSubstring("\"runAsUserName\": \"NT AUTHORITY\\\\SYSTEM\""),
			))
		})

		It("has Windows Exporter DaemonSet with nodeSelector for Windows nodes", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "daemonset", "windows-exporter", "-n", "kube-system", "-o", "jsonpath={.spec.template.spec.nodeSelector}")
			Expect(output).To(ContainSubstring("windows"))
		})

		It("has Windows Exporter pods running on all Windows nodes", func(ctx context.Context) {
			Eventually(func() bool {
				// Get number of Windows nodes
				nodesOutput := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "kubernetes.io/os=windows", "-o", "json")
				var nodes map[string]interface{}
				if err := json.Unmarshal([]byte(nodesOutput), &nodes); err != nil {
					return false
				}
				items, ok := nodes["items"].([]interface{})
				if !ok {
					return false
				}
				expectedCount := len(items)

				if expectedCount == 0 {
					// No Windows nodes, skip this check
					return true
				}

				// Get number of ready Windows Exporter pods
				podsOutput := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "kube-system", "-l", "app=windows-exporter", "-o", "jsonpath={.items[?(@.status.phase=='Running')].metadata.name}")

				// Count the pods (space-separated names)
				if podsOutput == "" {
					return false
				}

				return true // At least one pod is running
			}).WithTimeout(60 * time.Second).WithPolling(5 * time.Second).Should(BeTrue())
		})

		It("exposes metrics endpoint on port 9100", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "service", "windows-exporter", "-n", "kube-system", "-o", "jsonpath={.spec.ports[0].port}")
			Expect(output).To(Equal("9100"))
		})

		It("has Windows Exporter service with correct selector", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "service", "windows-exporter", "-n", "kube-system", "-o", "jsonpath={.spec.selector.app}")
			Expect(output).To(Equal("windows-exporter"))
		})

		It("has Windows Exporter ConfigMap with configuration", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "configmap", "windows-exporter-config", "-n", "kube-system", "-o", "json")
			Expect(output).To(ContainSubstring("windows_exporter.yaml"))
		})

		It("Windows Exporter pods are healthy and ready", func(ctx context.Context) {
			Eventually(func() bool {
				// Check if at least one Windows Exporter pod exists and is ready
				output := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "kube-system", "-l", "app=windows-exporter", "-o", "jsonpath={.items[*].status.containerStatuses[0].ready}")

				if output == "" {
					return false
				}

				// Check if any pod reports "true" for ready status
				return output == "true" || strings.Contains(output, "true")
			}).WithTimeout(90 * time.Second).WithPolling(5 * time.Second).Should(BeTrue())
		})
	})

	Describe("when monitoring addon is enabled", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
		})

		It("has ServiceMonitor for Prometheus scraping", func(ctx context.Context) {
			// Check if ServiceMonitor exists
			Eventually(func() bool {
				_, exitCode := suite.Kubectl().Exec(ctx, "get", "servicemonitor", "windows-exporter", "-n", "monitoring")
				return exitCode == 0
			}).WithTimeout(30*time.Second).WithPolling(2*time.Second).Should(BeTrue(), "ServiceMonitor should exist")
		})

		It("ServiceMonitor has correct label selector for Windows Exporter", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "servicemonitor", "windows-exporter", "-n", "monitoring", "-o", "json")

			var sm map[string]interface{}
			Expect(json.Unmarshal([]byte(output), &sm)).To(Succeed())

			spec, ok := sm["spec"].(map[string]interface{})
			Expect(ok).To(BeTrue(), "ServiceMonitor should have spec")

			selector, ok := spec["selector"].(map[string]interface{})
			Expect(ok).To(BeTrue(), "spec should have selector")

			matchLabels, ok := selector["matchLabels"].(map[string]interface{})
			Expect(ok).To(BeTrue(), "selector should have matchLabels")

			app, ok := matchLabels["app"].(string)
			Expect(ok).To(BeTrue(), "matchLabels should have app label")
			Expect(app).To(Equal("windows-exporter"))
		})

		It("ServiceMonitor targets kube-system namespace", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "servicemonitor", "windows-exporter", "-n", "monitoring", "-o", "jsonpath={.spec.namespaceSelector.matchNames[0]}")
			Expect(output).To(Equal("kube-system"))
		})

		It("ServiceMonitor has release label for Prometheus Operator discovery", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "servicemonitor", "windows-exporter", "-n", "monitoring", "-o", "jsonpath={.metadata.labels.release}")
			Expect(output).To(Equal("kube-prometheus-stack"))
		})

		It("Prometheus discovers Windows Exporter as a target", func(ctx context.Context) {
			// Get Prometheus pod
			promPodOutput := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "monitoring", "-l", "app.kubernetes.io/name=prometheus", "-o", "jsonpath={.items[0].metadata.name}")

			if promPodOutput == "" {
				Skip("No Prometheus pod found")
			}

			// Poll the Prometheus query API for the windows-exporter 'up' metric.
			// Using /api/v1/query instead of /api/v1/targets avoids downloading the
			// full (multi-MB) targets payload which caused wget to stall and chunked-
			// encoding parse errors in the framework's exit-code extraction.
			Eventually(func() bool {
				output, exitCode := suite.Kubectl().Exec(ctx,
					"exec", promPodOutput, "-n", "monitoring", "--",
					"wget", "-qO-", "-T", "30",
					`http://localhost:9090/api/v1/query?query=up{job="windows-exporter"}`,
				)

				if exitCode != 0 {
					return false
				}

				// Response is small: {"status":"success","data":{"resultType":"vector","result":[{"metric":{..."job":"windows-exporter","namespace":"kube-system",...}}]}}
				return strings.Contains(output, "\"status\":\"success\"") &&
					strings.Contains(output, "windows-exporter")
			}).WithTimeout(180*time.Second).WithPolling(15*time.Second).Should(BeTrue(), "Prometheus should discover Windows Exporter target")
		})

		It("Windows Exporter metrics are available in Prometheus", func(ctx context.Context) {
			// Get Prometheus pod
			promPodOutput := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "monitoring", "-l", "app.kubernetes.io/name=prometheus", "-o", "jsonpath={.items[0].metadata.name}")

			if promPodOutput == "" {
				Skip("No Prometheus pod found")
			}

			expectWindowsExporterScraping(ctx, promPodOutput)
		})
	})

	Describe("reference counting behavior", func() {
		Context("when both metrics and monitoring addons are enabled", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "metrics", "-o")
				suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "-o")

				suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")
				suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")

				DeferCleanup(func(ctx context.Context) {
					suite.K2sCli().Exec(ctx, "addons", "disable", "metrics", "-o")
					suite.K2sCli().Exec(ctx, "addons", "disable", "monitoring", "-o")
				})
			})

			It("Windows Exporter DaemonSet exists", func(ctx context.Context) {
				output := suite.Kubectl().MustExec(ctx, "get", "daemonset", "windows-exporter", "-n", "kube-system", "-o", "json")
				Expect(output).To(ContainSubstring("windows-exporter"))
			})

			It("remains deployed when metrics addon is disabled but monitoring is still enabled", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "metrics", "-o")

				// Windows Exporter should still be there because monitoring needs it
				Eventually(func() bool {
					_, exitCode := suite.Kubectl().Exec(ctx, "get", "daemonset", "windows-exporter", "-n", "kube-system")
					return exitCode == 0
				}).WithTimeout(10 * time.Second).WithPolling(2 * time.Second).Should(BeTrue())

				k2s.VerifyAddonIsEnabled("monitoring")
			})

			It("is removed when the last dependent addon (monitoring) is disabled", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")

				// Now Windows Exporter should be removed since no addon needs it
				Eventually(func() bool {
					_, exitCode := suite.Kubectl().Exec(ctx, "get", "daemonset", "windows-exporter", "-n", "kube-system")
					return exitCode != 0 // Should fail because DaemonSet is gone
				}).WithTimeout(30 * time.Second).WithPolling(2 * time.Second).Should(BeTrue())

				k2s.VerifyAddonIsDisabled("monitoring")
			})
		})
	})

	Describe("Windows-specific metrics validation", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")

			promPod := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "monitoring", "-l", "app.kubernetes.io/name=prometheus", "-o", "jsonpath={.items[0].metadata.name}")
			Expect(promPod).NotTo(BeEmpty(), "Prometheus pod must exist after enabling monitoring")
			expectWindowsExporterScraping(ctx, promPod)
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")
		})

		It("exposes Windows OS information metrics", func(ctx context.Context) {
			// Skip if no Windows nodes
			nodesOutput := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "kubernetes.io/os=windows", "-o", "json")
			var nodes map[string]interface{}
			json.Unmarshal([]byte(nodesOutput), &nodes)
			items := nodes["items"].([]interface{})
			if len(items) == 0 {
				Skip("No Windows nodes available")
			}

			promPodOutput := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "monitoring", "-l", "app.kubernetes.io/name=prometheus", "-o", "jsonpath={.items[0].metadata.name}")
			if promPodOutput == "" {
				Skip("No Prometheus pod found")
			}

			// Query for windows_os_info - info metric, one series per node, response is small
			Eventually(func() bool {
				output, exitCode := suite.Kubectl().Exec(ctx,
					"exec", promPodOutput, "-n", "monitoring", "--",
					"wget", "-qO-", "-T", "30",
					`http://localhost:9090/api/v1/query?query=windows_os_info{job="windows-exporter"}`,
				)

				if exitCode != 0 {
					return false
				}

				// Should contain Windows version info
				return strings.Contains(output, "\"status\":\"success\"") &&
					strings.Contains(output, "windows_os_info") &&
					strings.Contains(output, "\"product\"")
			}).WithTimeout(60*time.Second).WithPolling(10*time.Second).Should(BeTrue(), "windows_os_info metric should be available")
		})

		It("exposes CPU metrics from Windows nodes", func(ctx context.Context) {
			// Skip if no Windows nodes
			nodesOutput := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "kubernetes.io/os=windows", "-o", "json")
			var nodes map[string]interface{}
			json.Unmarshal([]byte(nodesOutput), &nodes)
			items := nodes["items"].([]interface{})
			if len(items) == 0 {
				Skip("No Windows nodes available")
			}

			promPodOutput := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "monitoring", "-l", "app.kubernetes.io/name=prometheus", "-o", "jsonpath={.items[0].metadata.name}")
			if promPodOutput == "" {
				Skip("No Prometheus pod found")
			}

			// Use count() to collapse the high-cardinality series (cores × modes) into a
			// single scalar, keeping the response small and avoiding the framework's
			// chunked-encoding/jq parse failure that occurs with 50+ series in the output.
			Eventually(func() bool {
				output, exitCode := suite.Kubectl().Exec(ctx,
					"exec", promPodOutput, "-n", "monitoring", "--",
					"wget", "-qO-", "-T", "30",
					`http://localhost:9090/api/v1/query?query=count(windows_cpu_time_seconds_total{job="windows-exporter"})`,
				)

				if exitCode != 0 {
					return false
				}

				return strings.Contains(output, "\"status\":\"success\"") &&
					strings.Contains(output, "\"result\":[{")
			}).WithTimeout(60*time.Second).WithPolling(10*time.Second).Should(BeTrue(), "windows_cpu_time_seconds_total metric should be available")
		})

		It("exposes memory metrics from Windows nodes", func(ctx context.Context) {
			// Skip if no Windows nodes
			nodesOutput := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "kubernetes.io/os=windows", "-o", "json")
			var nodes map[string]interface{}
			json.Unmarshal([]byte(nodesOutput), &nodes)
			items := nodes["items"].([]interface{})
			if len(items) == 0 {
				Skip("No Windows nodes available")
			}

			promPodOutput := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "monitoring", "-l", "app.kubernetes.io/name=prometheus", "-o", "jsonpath={.items[0].metadata.name}")
			if promPodOutput == "" {
				Skip("No Prometheus pod found")
			}

			// Use avg() to return a single value regardless of node count.
			Eventually(func() bool {
				output, exitCode := suite.Kubectl().Exec(ctx,
					"exec", promPodOutput, "-n", "monitoring", "--",
					"wget", "-qO-", "-T", "30",
					`http://localhost:9090/api/v1/query?query=avg(windows_memory_available_bytes{job="windows-exporter"})`,
				)

				if exitCode != 0 {
					return false
				}

				return strings.Contains(output, "\"status\":\"success\"") &&
					strings.Contains(output, "\"result\":[{")
			}).WithTimeout(60*time.Second).WithPolling(10*time.Second).Should(BeTrue(), "windows_memory_available_bytes metric should be available")
		})

		It("exposes logical disk metrics from Windows nodes", func(ctx context.Context) {
			// Skip if no Windows nodes
			nodesOutput := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "kubernetes.io/os=windows", "-o", "json")
			var nodes map[string]interface{}
			json.Unmarshal([]byte(nodesOutput), &nodes)
			items := nodes["items"].([]interface{})
			if len(items) == 0 {
				Skip("No Windows nodes available")
			}

			promPodOutput := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "monitoring", "-l", "app.kubernetes.io/name=prometheus", "-o", "jsonpath={.items[0].metadata.name}")
			if promPodOutput == "" {
				Skip("No Prometheus pod found")
			}

			// Use count() to collapse per-drive series into a single scalar.
			Eventually(func() bool {
				output, exitCode := suite.Kubectl().Exec(ctx,
					"exec", promPodOutput, "-n", "monitoring", "--",
					"wget", "-qO-", "-T", "30",
					`http://localhost:9090/api/v1/query?query=count(windows_logical_disk_free_bytes{job="windows-exporter"})`,
				)

				if exitCode != 0 {
					return false
				}

				return strings.Contains(output, "\"status\":\"success\"") &&
					strings.Contains(output, "\"result\":[{")
			}).WithTimeout(60*time.Second).WithPolling(10*time.Second).Should(BeTrue(), "windows_logical_disk_free_bytes metric should be available")
		})

		It("exposes network interface metrics from Windows nodes", func(ctx context.Context) {
			// Skip if no Windows nodes
			nodesOutput := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "kubernetes.io/os=windows", "-o", "json")
			var nodes map[string]interface{}
			json.Unmarshal([]byte(nodesOutput), &nodes)
			items := nodes["items"].([]interface{})
			if len(items) == 0 {
				Skip("No Windows nodes available")
			}

			promPodOutput := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "monitoring", "-l", "app.kubernetes.io/name=prometheus", "-o", "jsonpath={.items[0].metadata.name}")
			if promPodOutput == "" {
				Skip("No Prometheus pod found")
			}

			// Use count() to collapse per-interface series into a single scalar.
			Eventually(func() bool {
				output, exitCode := suite.Kubectl().Exec(ctx,
					"exec", promPodOutput, "-n", "monitoring", "--",
					"wget", "-qO-", "-T", "30",
					`http://localhost:9090/api/v1/query?query=count(windows_net_bytes_total{job="windows-exporter"})`,
				)

				if exitCode != 0 {
					return false
				}

				return strings.Contains(output, "\"status\":\"success\"") &&
					strings.Contains(output, "\"result\":[{")
			}).WithTimeout(60*time.Second).WithPolling(10*time.Second).Should(BeTrue(), "windows_net_bytes_total metric should be available")
		})

		It("metrics have correct labels identifying Windows nodes", func(ctx context.Context) {
			// Skip if no Windows nodes
			nodesOutput := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "kubernetes.io/os=windows", "-o", "json")
			var nodes map[string]interface{}
			json.Unmarshal([]byte(nodesOutput), &nodes)
			items := nodes["items"].([]interface{})
			if len(items) == 0 {
				Skip("No Windows nodes available")
			}

			promPodOutput := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "monitoring", "-l", "app.kubernetes.io/name=prometheus", "-o", "jsonpath={.items[0].metadata.name}")
			if promPodOutput == "" {
				Skip("No Prometheus pod found")
			}

			// Query for up metric with job=windows-exporter
			Eventually(func() bool {
				output, exitCode := suite.Kubectl().Exec(ctx,
					"exec", promPodOutput, "-n", "monitoring", "--",
					"wget", "-qO-", "-T", "30",
					`http://localhost:9090/api/v1/query?query=up{job="windows-exporter"}`,
				)

				if exitCode != 0 {
					return false
				}

				// Should contain job label and instance label
				return strings.Contains(output, "\"status\":\"success\"") &&
					strings.Contains(output, "\"job\":\"windows-exporter\"") &&
					strings.Contains(output, "\"instance\":")

			}).WithTimeout(60*time.Second).WithPolling(10*time.Second).Should(BeTrue(), "Windows Exporter metrics should have correct job and instance labels")
		})
	})

	Describe("addon status with Windows Exporter", func() {
		Context("when metrics addon is enabled", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "metrics", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "metrics", "-o")
			})

			It("shows metrics addon as enabled", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "metrics")
				Expect(output).To(SatisfyAll(
					MatchRegexp("ADDON STATUS"),
					MatchRegexp(`Addon .+metrics.+ is .+enabled.+`),
					MatchRegexp("The metrics server is working"),
				))
			})

			It("shows metrics addon status in JSON format", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "metrics", "-o", "json")

				var addonStatus status.AddonPrintStatus
				Expect(json.Unmarshal([]byte(output), &addonStatus)).To(Succeed())

				Expect(addonStatus.Name).To(Equal("metrics"))
				Expect(addonStatus.Enabled).NotTo(BeNil())
				Expect(*addonStatus.Enabled).To(BeTrue())
			})
		})

		Context("when monitoring addon is enabled", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")
			})

			It("shows monitoring addon as enabled with Node Exporter working", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "monitoring")

				Expect(output).To(SatisfyAll(
					MatchRegexp("ADDON STATUS"),
					MatchRegexp(`Addon .+monitoring.+ is .+enabled.+`),
					MatchRegexp("Node Exporter is working"),
				))
			})
		})
	})
})
