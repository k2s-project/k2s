// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package addonplacement

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

const headlampTemplateProbeYAML = "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: headlamp\nspec:\n  template:\n    spec:\n      nodeSelector:\n        pool: infra\n"

func TestMain(main *testing.M) {
	if logPath := os.Getenv("K2S_HEADLAMP_TEMPLATE_PROBE"); logPath != "" {
		arguments := os.Args[1:]
		if len(arguments) != 7 {
			fmt.Fprintln(os.Stderr, "unexpected template argument count")
			os.Exit(2)
		}
		values, err := os.ReadFile(arguments[6])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		encoded, _ := json.Marshal(struct {
			Arguments []string
			Values    string
		}{arguments, string(values)})
		if err := os.WriteFile(logPath, encoded, 0o600); err != nil {
			os.Exit(2)
		}
		fmt.Print(headlampTemplateProbeYAML)
		fmt.Fprintln(os.Stderr, "warning: offline chart diagnostic")
		if os.Getenv("K2S_HEADLAMP_TEMPLATE_FAIL") == "true" {
			os.Exit(7)
		}
		os.Exit(0)
	}
	os.Exit(main.Run())
}

func TestResolveSelectorCanonicalSavedState(t *testing.T) {
	for _, test := range []struct {
		name, requested, saved, want string
		found, fail                  bool
	}{
		{name: "fresh omission"},
		{name: "fresh canonical", requested: "zone=A, pool=infra", want: "pool=infra,zone=A"},
		{name: "saved omission", saved: "zone=A, pool=infra", found: true, want: "pool=infra,zone=A"},
		{name: "equivalent", requested: "pool=infra,zone=A", saved: "zone=A, pool=infra", found: true, want: "pool=infra,zone=A"},
		{name: "value case", requested: "zone=a,pool=infra", saved: "zone=A,pool=infra", found: true, fail: true},
		{name: "key case", requested: "Zone=A,pool=infra", saved: "zone=A,pool=infra", found: true, fail: true},
		{name: "malformed saved omitted", saved: "broken", found: true, fail: true},
		{name: "malformed saved explicit", saved: "pool=infra,", requested: "pool=infra", found: true, fail: true},
		{name: "legacy unconstrained", requested: "pool=infra", found: true, fail: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := ResolveSelector(test.requested, test.saved, test.found)
			if (err != nil) != test.fail || got != test.want {
				t.Fatalf("ResolveSelector() = %q, %v; want %q, fail=%v", got, err, test.want, test.fail)
			}
		})
	}
}

func TestHeadlampTemplateArgumentsDiagnosticsAndCleanup(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, fail := range []bool{false, true} {
		t.Run(fmt.Sprint(fail), func(t *testing.T) {
			logPath := filepath.Join(t.TempDir(), "template.json")
			t.Setenv("K2S_HEADLAMP_TEMPLATE_PROBE", logPath)
			t.Setenv("K2S_HEADLAMP_TEMPLATE_FAIL", fmt.Sprint(fail))
			output, err := TemplateHeadlampChart(executable, "offline chart.tgz", []byte("nodeSelector: {}\n"))
			if fail {
				var exitError *exec.ExitError
				if !errors.As(err, &exitError) || exitError.ExitCode() != 7 || !strings.Contains(err.Error(), "warning: offline chart diagnostic") || !strings.Contains(err.Error(), "kind: Deployment") || len(output) != 0 {
					t.Fatalf("diagnostics or exit error lost: output=%q, err=%v", output, err)
				}
			} else {
				if err != nil || string(output) != headlampTemplateProbeYAML {
					t.Fatalf("template stdout contaminated: %q, %v", output, err)
				}
				selectors, err := WorkloadSelectors(output)
				if err != nil || !reflect.DeepEqual(selectors, []string{"pool=infra"}) {
					t.Fatalf("template selectors: %v, %v", selectors, err)
				}
			}
			data, err := os.ReadFile(logPath)
			if err != nil {
				t.Fatal(err)
			}
			var call struct {
				Arguments []string
				Values    string
			}
			if err := json.Unmarshal(data, &call); err != nil {
				t.Fatal(err)
			}
			want := []string{"template", "headlamp", "offline chart.tgz", "--namespace", "dashboard", "--values", call.Arguments[6]}
			if !reflect.DeepEqual(call.Arguments, want) || call.Values != "nodeSelector: {}\n" {
				t.Fatalf("unexpected template call: %#v", call)
			}
			if _, err := os.Stat(call.Arguments[6]); !os.IsNotExist(err) {
				t.Fatalf("values file retained: %v", err)
			}
		})
	}
	tempRoot := t.TempDir()
	t.Setenv("TMP", tempRoot)
	t.Setenv("TEMP", tempRoot)
	t.Setenv("TMPDIR", tempRoot)
	if _, err := TemplateHeadlampChart(filepath.Join(tempRoot, "missing-helm"), "chart.tgz", []byte("values")); err == nil {
		t.Fatal("missing executable accepted")
	}
	files, err := os.ReadDir(tempRoot)
	if err != nil || len(files) != 0 {
		t.Fatalf("values leaked on start error: %v, %v", files, err)
	}
}

func TestPrepareHeadlampChartOfflineInputs(t *testing.T) {
	directory := t.TempDir()
	if _, _, err := PrepareHeadlampChart(directory, "pool=infra"); err == nil {
		t.Fatal("missing chart accepted")
	}
	chart := filepath.Join(directory, "headlamp-test.tgz")
	if err := os.WriteFile(chart, []byte("offline"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := PrepareHeadlampChart(directory, "pool=infra"); err == nil {
		t.Fatal("missing values accepted")
	}
	if err := os.WriteFile(filepath.Join(directory, "values.yaml"), []byte("nodeSelector:\n  kubernetes.io/os: linux\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	gotChart, values, err := PrepareHeadlampChart(directory, "pool=infra")
	if err != nil || gotChart != chart || !strings.Contains(string(values), "pool: infra") {
		t.Fatalf("prepare = %q, %s, %v", gotChart, values, err)
	}
	if err := os.WriteFile(filepath.Join(directory, "headlamp-duplicate.tgz"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := PrepareHeadlampChart(directory, "pool=infra"); err == nil {
		t.Fatal("ambiguous chart accepted")
	}
}

func TestOperatorPlacementUsesBundledSchemas(t *testing.T) {
	tests := []struct {
		file, kind, version string
		path                []string
	}{
		{"monitoring/manifests/monitoring/crds/crd-prometheuses.yaml", "Prometheus", "monitoring.coreos.com/v1", []string{"spec"}},
		{"monitoring/manifests/monitoring/crds/crd-alertmanagers.yaml", "Alertmanager", "monitoring.coreos.com/v1", []string{"spec"}},
		{"ingress/nginx-gw/manifests/crds/gateway-fabric-api-v2.8.0.yaml", "NginxProxy", "gateway.nginx.org/v1alpha2", []string{"spec", "kubernetes", "deployment", "pod"}},
	}
	for _, test := range tests {
		t.Run(test.kind, func(t *testing.T) {
			data, err := os.ReadFile(filepath.Join("..", "..", "..", "addons", filepath.FromSlash(test.file)))
			if err != nil {
				t.Fatal(err)
			}
			decoder := yaml.NewDecoder(bytes.NewReader(data))
			found := false
			for {
				var document map[string]any
				if err := decoder.Decode(&document); err == io.EOF {
					break
				} else if err != nil {
					t.Fatal(err)
				}
				if document["kind"] != "CustomResourceDefinition" {
					continue
				}
				spec := nestedMap(document, "spec")
				if nestedMap(spec, "names")["kind"] != test.kind {
					continue
				}
				for _, entry := range spec["versions"].([]any) {
					version := entry.(map[string]any)
					if !strings.HasSuffix(test.version, "/"+version["name"].(string)) {
						continue
					}
					schema := nestedMap(version, "schema", "openAPIV3Schema")
					for _, field := range append(test.path, "nodeSelector") {
						schema = nestedMap(schema, "properties", field)
					}
					if schema["type"] != "object" || nestedMap(schema, "additionalProperties")["type"] != "string" {
						t.Fatalf("bundled CRD has no string-map selector at %v", test.path)
					}
					found = true
				}
			}
			if !found {
				t.Fatal("owning schema not found")
			}
			input := []byte("apiVersion: " + test.version + "\nkind: " + test.kind + "\nmetadata:\n  name: central\n")
			output, changed, err := RenderManifestStream(input, "kubernetes.io/hostname=kubemaster")
			if err != nil || changed != 1 {
				t.Fatalf("render owner: changed=%d, err=%v", changed, err)
			}
			var owner map[string]any
			if err := yaml.Unmarshal(output, &owner); err != nil {
				t.Fatal(err)
			}
			selector, err := nodeSelector(nestedMap(owner, test.path...))
			if err != nil || selector["kubernetes.io/hostname"] != "kubemaster" {
				t.Fatalf("wrong owning placement: %s (%v)", output, err)
			}
		})
	}
}

func TestParseSelector(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    map[string]string
		wantErr string
	}{
		{
			name:  "valid requirements",
			input: "kubernetes.io/hostname=worker-1, topology.kubernetes.io/zone=zone-a",
			want:  map[string]string{"kubernetes.io/hostname": "worker-1", "topology.kubernetes.io/zone": "zone-a"},
		},
		{name: "omitted selector", input: "", want: map[string]string{}},
		{name: "whitespace-only selector", input: "  ", wantErr: "must not contain only whitespace"},
		{name: "empty label value", input: "node-role.kubernetes.io/control-plane=", want: map[string]string{"node-role.kubernetes.io/control-plane": ""}},
		{name: "normalized whitespace", input: " pool = Infra , role = ", want: map[string]string{"pool": "Infra", "role": ""}},
		{name: "case-sensitive keys", input: "pool=infra,Pool=Infra", want: map[string]string{"pool": "infra", "Pool": "Infra"}},
		{name: "equals in value", input: "key=bad=value", wantErr: "expected key=value"},
		{name: "missing equals", input: "key", wantErr: "expected key=value"},
		{name: "invalid key", input: "bad key=value", wantErr: "invalid infrastructure node selector key"},
		{name: "invalid value", input: "key=bad/value", wantErr: "invalid infrastructure node selector value"},
		{name: "duplicate key", input: "key=one,key=two", wantErr: "duplicate key"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseSelector(test.input)
			if test.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), test.wantErr) {
					t.Fatalf("ParseSelector() error = %v, want containing %q", err, test.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("ParseSelector() error = %v", err)
			}
			if len(got) != len(test.want) {
				t.Fatalf("ParseSelector() = %#v, want %#v", got, test.want)
			}
			for key, value := range test.want {
				if got[key] != value {
					t.Errorf("ParseSelector()[%q] = %q, want %q", key, got[key], value)
				}
			}
		})
	}
}

func TestValidatePersistentVolumeHost(t *testing.T) {
	node := append([]byte{0xef, 0xbb, 0xbf}, []byte(`{"metadata":{"name":"kubemaster","labels":{"kubernetes.io/hostname":"kubemaster","kubernetes.io/os":"linux","zone":"a"}}}`)...)
	for _, test := range []struct {
		name, affinity string
		fails          bool
	}{
		{"compatible", `{"nodeSelectorTerms":[{"matchExpressions":[{"key":"zone","operator":"In","values":["a"]}]}]}`, false},
		{"actual PV conflicts", `{"nodeSelectorTerms":[{"matchExpressions":[{"key":"zone","operator":"In","values":["b"]}]}]}`, true},
		{"missing label", `{"nodeSelectorTerms":[{"matchExpressions":[{"key":"disk","operator":"Exists"}]}]}`, true},
		{"OR alternative", `{"nodeSelectorTerms":[{"matchExpressions":[{"key":"zone","operator":"In","values":["b"]}]},{"matchFields":[{"key":"metadata.name","operator":"In","values":["kubemaster"]}]}]}`, false},
		{"empty affinity", `{"nodeSelectorTerms":[]}`, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			volume := []byte(`{"metadata":{"name":"data"},"spec":{"local":{"path":"/data"},"nodeAffinity":{"required":` + test.affinity + `}}}`)
			if err := ValidatePersistentVolumeHost(volume, node); (err != nil) != test.fails {
				t.Fatalf("storage validation error = %v, want failure %v", err, test.fails)
			}
		})
	}
}

func TestMergeSelectorPreservesMandatoryRequirements(t *testing.T) {
	existing := map[string]string{"kubernetes.io/os": "linux", "kubernetes.io/arch": "amd64"}
	merged, err := MergeSelector(existing, "kubernetes.io/hostname=worker-1,kubernetes.io/os=linux")
	if err != nil {
		t.Fatalf("MergeSelector() error = %v", err)
	}
	want := map[string]string{
		"kubernetes.io/os":       "linux",
		"kubernetes.io/arch":     "amd64",
		"kubernetes.io/hostname": "worker-1",
	}
	if len(merged) != len(want) {
		t.Fatalf("MergeSelector() = %#v, want %#v", merged, want)
	}
	for key, value := range want {
		if merged[key] != value {
			t.Errorf("MergeSelector()[%q] = %q, want %q", key, merged[key], value)
		}
	}
}

func TestMergeSelectorRejectsMandatoryConflict(t *testing.T) {
	_, err := MergeSelector(map[string]string{"kubernetes.io/os": "linux"}, "kubernetes.io/os=windows")
	if err == nil || !strings.Contains(err.Error(), "conflicts with the addon's required node selector") {
		t.Fatalf("MergeSelector() error = %v, want actionable mandatory-selector conflict", err)
	}
}

func TestFormatSelectorIsStable(t *testing.T) {
	got := FormatSelector(map[string]string{"z": "last", "a": "first"})
	if got != "a=first,z=last" {
		t.Fatalf("FormatSelector() = %q, want %q", got, "a=first,z=last")
	}
}

func TestRenderHelmValuesPreservesPlacementAndOtherValues(t *testing.T) {
	input := []byte("nodeSelector:\n  kubernetes.io/os: linux\n  kubernetes.io/arch: amd64\naffinity: {}\nreplicaCount: 1\n")
	output, err := RenderHelmValues(input, "kubernetes.io/hostname=kubemaster")
	if err != nil {
		t.Fatal(err)
	}
	var values map[string]any
	if err := yaml.Unmarshal(output, &values); err != nil {
		t.Fatal(err)
	}
	selector, err := nodeSelector(values)
	if err != nil || selector["kubernetes.io/os"] != "linux" || selector["kubernetes.io/arch"] != "amd64" || selector["kubernetes.io/hostname"] != "kubemaster" || values["replicaCount"] != 1 {
		t.Fatalf("chart values were not merged safely: %s (%v)", output, err)
	}
	if _, err := RenderHelmValues(input, "kubernetes.io/os=windows"); err == nil {
		t.Fatal("chart accepted conflicting mandatory selector")
	}
	unchanged, err := RenderHelmValues(input, "")
	if err != nil || !bytes.Equal(unchanged, input) {
		t.Fatal("omission changed chart values")
	}
}

func TestRenderManifestStreamLeavesInputUnchangedWhenSelectorIsOmitted(t *testing.T) {
	input := []byte("apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: controller\n")
	rendered, changed, err := RenderManifestStream(input, "")
	if err != nil {
		t.Fatalf("RenderManifestStream() error = %v", err)
	}
	if changed != 0 || !bytes.Equal(rendered, input) {
		t.Fatalf("omitted selector changed manifest: changed=%d, rendered=%q", changed, rendered)
	}
}

func TestRenderManifestStreamAppliesOnlyToCentralPodTemplates(t *testing.T) {
	input := []byte(`apiVersion: apps/v1
kind: Deployment
metadata:
  name: controller
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      containers: []
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-agent
spec:
  template:
    spec:
      containers: []
`)

	output, changed, err := RenderManifestStream(input, "kubernetes.io/hostname=infra-1")
	if err != nil {
		t.Fatalf("RenderManifestStream() error = %v", err)
	}
	if changed != 1 {
		t.Fatalf("RenderManifestStream() changed = %d, want 1", changed)
	}
	var deployment map[string]any
	if err := yaml.Unmarshal(output, &deployment); err != nil {
		t.Fatalf("unmarshal rendered deployment: %v", err)
	}
	podSpec := nestedMap(deployment, "spec", "template", "spec")
	selector, err := nodeSelector(podSpec)
	if err != nil {
		t.Fatalf("nodeSelector() error = %v", err)
	}
	if selector["kubernetes.io/os"] != "linux" || selector["kubernetes.io/hostname"] != "infra-1" {
		t.Fatalf("rendered selector = %#v, mandatory and requested requirements should both remain", selector)
	}
	if !strings.Contains(string(output), "kind: DaemonSet") {
		t.Fatalf("rendered stream omitted the node-local DaemonSet")
	}
}

func TestRenderManifestStreamRejectsConflictsAndCustomResources(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		wantErr string
	}{
		{
			name: "mandatory node selector conflict",
			input: `apiVersion: apps/v1
kind: Deployment
metadata:
  name: controller
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      containers: []
`,
			wantErr: "conflicts with the addon's required node selector",
		},
		{
			name: "unsupported custom resource",
			input: `apiVersion: example.com/v1
kind: Widget
metadata:
  name: main
`,
			wantErr: "custom resource API group",
		},
		{
			name: "non-resource yaml",
			input: `name: headlamp
service:
  type: ClusterIP
`,
			wantErr: "must include apiVersion and kind",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, _, err := RenderManifestStream([]byte(test.input), "kubernetes.io/os=windows")
			if err == nil || !strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf("RenderManifestStream() error = %v, want containing %q", err, test.wantErr)
			}
		})
	}
}

func TestRenderManifestStreamRejectsRequiredNodeAffinityConflict(t *testing.T) {
	input := []byte(`apiVersion: apps/v1
kind: Deployment
metadata:
  name: controller
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/os
                    operator: In
                    values: [linux]
      containers: []
`)
	_, _, err := RenderManifestStream(input, "kubernetes.io/os=windows")
	if err == nil || !strings.Contains(err.Error(), "conflicts with required node affinity") {
		t.Fatalf("RenderManifestStream() error = %v, want required node affinity conflict", err)
	}
}

func TestRenderManifestStreamDoesNotConstrainDistributedAgents(t *testing.T) {
	for _, agent := range []string{"fluent-bit", "windows-exporter", "prometheus-node-exporter"} {
		t.Run(agent, func(t *testing.T) {
			input := []byte("apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: central\nspec:\n  template:\n    spec:\n      containers: []\n---\napiVersion: apps/v1\nkind: DaemonSet\nmetadata:\n  name: " + agent + "\nspec:\n  template:\n    spec:\n      nodeSelector:\n        kubernetes.io/os: linux\n      containers: []\n")
			rendered, changed, err := RenderManifestStream(input, "kubernetes.io/hostname=kubemaster")
			if err != nil || changed != 1 {
				t.Fatalf("render: %v, changed: %d", err, changed)
			}
			decoder := yaml.NewDecoder(bytes.NewReader(rendered))
			for index := 0; index < 2; index++ {
				var document map[string]any
				if err := decoder.Decode(&document); err != nil {
					t.Fatal(err)
				}
				if document["kind"] == "DaemonSet" {
					selector, err := nodeSelector(nestedMap(document, "spec", "template", "spec"))
					if err != nil || len(selector) != 1 || selector["kubernetes.io/os"] != "linux" {
						t.Fatalf("distributed agent inherited placement: %#v (%v)", selector, err)
					}
				}
			}
		})
	}
}
