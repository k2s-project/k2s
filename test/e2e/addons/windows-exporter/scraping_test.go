// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package windowsexporter

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os/exec"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func expectWindowsExporterScraping(ctx context.Context, prometheusPod string) {
	output := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "kubernetes.io/os=windows", "-o", "json")
	var nodes corev1.NodeList
	Expect(json.Unmarshal([]byte(output), &nodes)).To(Succeed())
	if len(nodes.Items) == 0 {
		Skip("No Windows nodes available")
	}
	query := `up{job="windows-exporter",namespace="kube-system",service="windows-exporter"}`
	address := "http://localhost:9090/api/v1/query?query=" + url.QueryEscape(query)
	Eventually(func() error {
		output, exitCode := suite.Kubectl().Exec(ctx, "exec", prometheusPod, "-n", "monitoring", "--",
			"wget", "-qO-", "-T", "10", address)
		if exitCode != 0 {
			return fmt.Errorf("Prometheus scrape query failed (exit %d): %s", exitCode, output)
		}
		return validateExporterScrapes(output, len(nodes.Items))
	}).WithTimeout(120*time.Second).WithPolling(10*time.Second).Should(Succeed(),
		"Every Windows node must have a successfully scraped ServiceMonitor exporter target")
}

func validateExporterScrapes(output string, expected int) error {
	var response struct {
		Status string `json:"status"`
		Error  string `json:"error"`
		Data   struct {
			ResultType string `json:"resultType"`
			Result     []struct {
				Metric map[string]string `json:"metric"`
				Value  []json.RawMessage `json:"value"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(output), &response); err != nil {
		return fmt.Errorf("invalid Prometheus scrape response: %w", err)
	}
	if response.Status != "success" || response.Data.ResultType != "vector" {
		return fmt.Errorf("Prometheus scrape query status %q, result type %q: %s",
			response.Status, response.Data.ResultType, response.Error)
	}
	if expected < 1 || len(response.Data.Result) != expected {
		return fmt.Errorf("expected %d Windows exporter targets, found %d", expected, len(response.Data.Result))
	}
	seen := make(map[string]bool)
	for _, result := range response.Data.Result {
		instance := result.Metric["instance"]
		if result.Metric["job"] != "windows-exporter" || result.Metric["namespace"] != "kube-system" ||
			result.Metric["service"] != "windows-exporter" || instance == "" || seen[instance] {
			return fmt.Errorf("invalid or duplicate Windows exporter target: %v", result.Metric)
		}
		seen[instance] = true
		var value string
		if len(result.Value) != 2 || json.Unmarshal(result.Value[1], &value) != nil || value != "1" {
			return fmt.Errorf("Windows exporter target %q is not successfully scraped: %s", instance, result.Value)
		}
	}
	return nil
}

// Keep diagnostics out of the assertion-based executor so collection cannot replace the original failure.
func collectExporterDiagnostics(ctx context.Context, kubectl string) {
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	for _, args := range [][]string{
		{"get", "daemonset", "windows-exporter", "-n", "kube-system", "-o", "yaml"},
		{"describe", "pods", "-n", "kube-system", "-l", "app=windows-exporter"},
		{"get", "configmap", "windows-exporter-config", "-n", "kube-system", "-o", "yaml"},
		{"get", "endpointslices", "-n", "kube-system", "-l", "kubernetes.io/service-name=windows-exporter", "-o", "yaml"},
		{"logs", "-n", "kube-system", "-l", "app=windows-exporter", "--tail=80", "--prefix=true"},
		{"logs", "-n", "kube-system", "-l", "app=windows-exporter", "--tail=80", "--prefix=true", "--previous"},
	} {
		output, err := exporterDiagnosticCommand(ctx, kubectl, args...)
		GinkgoWriter.Printf("[ExporterDiag] kubectl %s\n%s\n", strings.Join(args, " "), output)
		if err != nil {
			GinkgoWriter.Printf("[ExporterDiag] Collection failed: %v\n", err)
		}
	}
	output, err := exporterDiagnosticCommand(ctx, kubectl, "get", "pods", "-n", "monitoring",
		"-l", "app.kubernetes.io/name=prometheus", "-o", "jsonpath={.items[0].metadata.name}")
	if err != nil || strings.TrimSpace(output) == "" {
		GinkgoWriter.Printf("[ExporterDiag] Cannot locate Prometheus pod: %v; %.4096s\n", err, output)
		return
	}
	output, err = exporterDiagnosticCommand(ctx, kubectl, "exec", strings.TrimSpace(output), "-n", "monitoring", "--",
		"wget", "-qO-", "-T", "10", "http://localhost:9090/api/v1/targets?state=active")
	if err != nil {
		GinkgoWriter.Printf("[ExporterDiag] Cannot read Prometheus targets: %v; %.4096s\n", err, output)
		return
	}
	targets, err := exporterTargetDiagnostics(output)
	if err != nil {
		GinkgoWriter.Printf("[ExporterDiag] %v\n", err)
		return
	}
	GinkgoWriter.Printf("[ExporterDiag] Prometheus exporter targets:\n%s\n", targets)
}

func exporterTargetDiagnostics(output string) (string, error) {
	var response struct {
		Status string `json:"status"`
		Data   struct {
			ActiveTargets []struct {
				Labels    map[string]string `json:"labels"`
				ScrapeURL string            `json:"scrapeUrl"`
				Health    string            `json:"health"`
				LastError string            `json:"lastError"`
			} `json:"activeTargets"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(output), &response); err != nil {
		return "", fmt.Errorf("invalid Prometheus targets response: %w", err)
	}
	if response.Status != "success" {
		return "", fmt.Errorf("Prometheus targets query status %q", response.Status)
	}
	var lines []string
	for _, target := range response.Data.ActiveTargets {
		if target.Labels["job"] == "windows-exporter" {
			lines = append(lines, fmt.Sprintf("instance=%q url=%q health=%q lastError=%q",
				target.Labels["instance"], target.ScrapeURL, target.Health, target.LastError))
		}
	}
	if len(lines) == 0 {
		return "No active Windows exporter targets discovered.", nil
	}
	return strings.Join(lines, "\n"), nil
}

func exporterDiagnosticCommand(ctx context.Context, executable string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, executable, args...)
	command.WaitDelay = time.Second
	// Targets can be several MB. Bound retained output without stopping the pipe reader.
	output := &exporterDiagnosticBuffer{remaining: 4 * 1024 * 1024}
	command.Stdout = output
	command.Stderr = output
	err := command.Run()
	if output.truncated {
		err = fmt.Errorf("diagnostic output exceeded 4 MiB (command error: %v)", err)
	}
	return output.String(), err
}

type exporterDiagnosticBuffer struct {
	strings.Builder
	remaining int
	truncated bool
}

func (b *exporterDiagnosticBuffer) Write(p []byte) (int, error) {
	n := len(p)
	if n > b.remaining {
		p = p[:b.remaining]
		b.truncated = true
	}
	_, _ = b.Builder.Write(p)
	b.remaining -= len(p)
	return n, nil
}
