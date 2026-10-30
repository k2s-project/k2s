// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package windowsexporter

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

func TestValidateExporterScrapes(t *testing.T) {
	target := func(instance, value string) string {
		return `{"metric":{"job":"windows-exporter","namespace":"kube-system","service":"windows-exporter","instance":"` +
			instance + `"},"value":[123,` + value + `]}`
	}
	response := func(targets ...string) string {
		return `{"status":"success","data":{"resultType":"vector","result":[` + strings.Join(targets, ",") + `]}}`
	}
	up := target("node1:9100", `"1"`)
	for _, tc := range []struct {
		name     string
		output   string
		expected int
		wantErr  bool
	}{
		{"healthy node", response(up), 1, false},
		{"healthy multi-node", response(up, target("node2:9100", `"1"`)), 2, false},
		{"all down regression", response(target("node1:9100", `"0"`)), 1, true},
		{"one node down", response(up, target("node2:9100", `"0"`)), 2, true},
		{"missing node", response(up), 2, true},
		{"duplicate target", response(up, up), 2, true},
		{"no targets", response(), 1, true},
		{"no Windows nodes", response(), 0, true},
		{"static target", response(strings.ReplaceAll(up, `"namespace":"kube-system",`, "")), 1, true},
		{"wrong service", response(strings.ReplaceAll(up, `"service":"windows-exporter"`, `"service":"other"`)), 1, true},
		{"missing sample", response(strings.ReplaceAll(up, `[123,"1"]`, `[]`)), 1, true},
		{"invalid sample", response(target("node1:9100", `1`)), 1, true},
		{"malformed JSON", "not-json", 1, true},
		{"API error", `{"status":"error","error":"query failed"}`, 1, true},
		{"wrong result type", strings.ReplaceAll(response(up), `"vector"`, `"matrix"`), 1, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := validateExporterScrapes(tc.output, tc.expected); (err != nil) != tc.wantErr {
				t.Fatalf("error = %v, wantErr = %v", err, tc.wantErr)
			}
		})
	}
}

func TestExporterTargetDiagnostics(t *testing.T) {
	output := `{"status":"success","data":{"activeTargets":[
		{"labels":{"job":"windows-exporter","instance":"node1:9100"},"scrapeUrl":"http://node1:9100/metrics","health":"down","lastError":"connection refused"},
		{"labels":{"job":"other"},"scrapeUrl":"http://unrelated","lastError":"unrelated error"}
	]}}`
	text, err := exporterTargetDiagnostics(output)
	if err != nil || !strings.Contains(text, `lastError="connection refused"`) ||
		!strings.Contains(text, `health="down"`) || strings.Contains(text, "unrelated") {
		t.Fatalf("diagnostics = %q, error = %v", text, err)
	}
	for _, output := range []string{"not-json", `{"status":"error"}`} {
		if _, err := exporterTargetDiagnostics(output); err == nil {
			t.Fatalf("expected error for %q", output)
		}
	}
	text, err = exporterTargetDiagnostics(`{"status":"success","data":{"activeTargets":[]}}`)
	if err != nil || !strings.Contains(text, "No active") {
		t.Fatalf("empty diagnostics = %q, error = %v", text, err)
	}
}

func TestExporterDiagnosticOutputBound(t *testing.T) {
	buffer := &exporterDiagnosticBuffer{remaining: 5}
	for _, text := range []string{"abc", "def", "ghi"} {
		n, err := buffer.Write([]byte(text))
		if err != nil || n != len(text) {
			t.Fatalf("write = %d, %v", n, err)
		}
	}
	if buffer.String() != "abcde" || !buffer.truncated {
		t.Fatalf("buffer = %+v", buffer)
	}
}

func TestExporterDiagnosticCommand(t *testing.T) {
	for _, mode := range []string{"output", "failure", "sleep"} {
		t.Run(mode, func(t *testing.T) {
			timeout := 10 * time.Second
			if mode == "sleep" {
				timeout = 200 * time.Millisecond
			}
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()
			output, err := exporterDiagnosticCommand(ctx, os.Args[0],
				"-test.run=^TestExporterDiagnosticProcessHelper$", "--", mode)
			if mode == "output" {
				if err != nil || !strings.Contains(output, "fixture output") {
					t.Fatalf("output = %q, error = %v", output, err)
				}
			} else if err == nil {
				t.Fatal("expected diagnostic failure")
			}
		})
	}
}

func TestExporterDiagnosticProcessHelper(t *testing.T) {
	if len(os.Args) < 2 || os.Args[len(os.Args)-2] != "--" {
		return
	}
	switch os.Args[len(os.Args)-1] {
	case "output":
		_, _ = os.Stdout.WriteString("fixture output")
	case "failure":
		os.Exit(2)
	case "sleep":
		time.Sleep(30 * time.Second)
	}
}

func TestExporterCollectorConfiguration(t *testing.T) {
	path := filepath.Join("..", "..", "..", "..", "addons", "common", "manifests", "windows-exporter", "configmap.yaml")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	var configMap struct {
		Data map[string]string `yaml:"data"`
	}
	if err := yaml.Unmarshal(data, &configMap); err != nil {
		t.Fatal(err)
	}
	var config struct {
		Collectors struct {
			Enabled string `yaml:"enabled"`
		} `yaml:"collectors"`
	}
	if err := yaml.Unmarshal([]byte(configMap.Data["windows_exporter.yaml"]), &config); err != nil {
		t.Fatal(err)
	}
	collectors := strings.Split(config.Collectors.Enabled, ",")
	// thermalzone was removed in 0.32; unknown collectors prevent startup.
	if slices.Contains(collectors, "thermalzone") || slices.Contains(collectors, "filetime") {
		t.Fatalf("removed collector enabled: %v", collectors)
	}
	for _, required := range []string{"cpu", "memory", "logical_disk", "net", "os", "service", "system", "cpu_info", "container"} {
		if !slices.Contains(collectors, required) {
			t.Errorf("required collector %q missing", required)
		}
	}
}

func TestExporterDashboardMetricCompatibility(t *testing.T) {
	path := filepath.Join("..", "..", "..", "..", "addons", "monitoring", "manifests", "monitoring", "grafana", "dashboards.yaml")
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	decoder := yaml.NewDecoder(file)
	removedMetrics := regexp.MustCompile(`\bwindows_cpu_time_total\b|\bwindows_thermalzone_[a-zA-Z0-9_]*\b`)
	dashboards, cpuQueries := 0, 0
	for {
		var configMap struct {
			Data map[string]string `yaml:"data"`
		}
		if err := decoder.Decode(&configMap); err == io.EOF {
			break
		} else if err != nil {
			t.Fatal(err)
		}
		for name, dashboard := range configMap.Data {
			if !strings.HasSuffix(name, ".json") {
				continue
			}
			if !json.Valid([]byte(dashboard)) {
				t.Fatalf("invalid dashboard JSON in %s", name)
			}
			dashboards++
			if metric := removedMetrics.FindString(dashboard); metric != "" {
				t.Errorf("dashboard %s still references obsolete metric %s", name, metric)
			}
			cpuQueries += strings.Count(dashboard, "windows_cpu_time_seconds_total")
		}
	}
	if dashboards == 0 || cpuQueries == 0 {
		t.Fatalf("expected parsed dashboards and updated Windows CPU queries, got %d dashboards and %d queries", dashboards, cpuQueries)
	}
}
