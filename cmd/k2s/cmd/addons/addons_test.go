// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package addons

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/backup"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/generic"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/restore"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	"github.com/k2s-project/k2s/internal/core/addonplacement"
	addoncore "github.com/k2s-project/k2s/internal/core/addons"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

func TestManualPlacementCLIContract(t *testing.T) {
	allAddons, err := addoncore.LoadAddons(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	commands, err := generic.NewCommands(allAddons)
	if err != nil {
		t.Fatal(err)
	}
	root := &cobra.Command{Use: "addons"}
	root.AddCommand(commands...)
	root.AddCommand(status.NewCommand(allAddons), backup.NewCommand(), restore.NewCommand())
	for _, path := range []string{
		"enable metrics", "enable dashboard", "enable monitoring", "enable logging", "enable registry",
		"enable ingress nginx", "enable ingress traefik", "enable ingress nginx-gw",
		"disable metrics", "status metrics", "status ingress nginx",
	} {
		t.Run(path, func(t *testing.T) {
			command, remaining, err := root.Find(strings.Fields(path))
			if err != nil || len(remaining) != 0 || command.RunE == nil {
				t.Fatalf("documented command unavailable: %s (%v, %v)", path, remaining, err)
			}
			if strings.HasPrefix(path, "enable ") && command.Flags().Lookup("infra-node-selector") == nil {
				t.Fatal("placement option missing")
			}
			if path == "enable monitoring" && (command.Flags().Lookup("omitGrafana") == nil || command.Flags().Lookup("omitgrafana") != nil) {
				t.Fatal("monitoring recovery requires the case-sensitive --omitGrafana option")
			}
			if strings.HasPrefix(path, "status ") && command.Flags().ShorthandLookup("o") == nil {
				t.Fatal("JSON status option missing")
			}
		})
	}
	for _, name := range []string{"backup", "restore"} {
		command, _, err := root.Find([]string{name})
		if err != nil || command.Flags().ShorthandLookup("f") == nil || command.Flags().ShorthandLookup("f").Name != "file" {
			t.Fatalf("%s must use -f/--file", name)
		}
		if err := command.Args(command, []string{"ingress", "nginx"}); err != nil {
			t.Fatal(err)
		}
	}
	for _, addon := range []string{"metrics", "dashboard", "monitoring", "logging", "registry"} {
		command, remaining, err := root.Find([]string{"update", addon})
		if err == nil && len(remaining) == 0 && command.RunE != nil {
			t.Fatalf("public update command must not be exposed: %s", addon)
		}
	}
}

type placementAddonManifest struct {
	Spec struct {
		Implementations []struct {
			Commands map[string]struct {
				CLI struct {
					Flags []struct {
						Name string `yaml:"name"`
					} `yaml:"flags"`
				} `yaml:"cli"`
				Script struct {
					ParameterMappings []struct {
						CLIFlagName         string `yaml:"cliFlagName"`
						ScriptParameterName string `yaml:"scriptParameterName"`
					} `yaml:"parameterMappings"`
				} `yaml:"script"`
			} `yaml:"commands"`
		} `yaml:"implementations"`
	} `yaml:"spec"`
}

func TestPlacementRenderCommand(t *testing.T) {
	manifestsDir := t.TempDir()
	manifest := `apiVersion: apps/v1
kind: Deployment
metadata:
  name: metrics-server
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      containers: []
`
	if err := os.WriteFile(filepath.Join(manifestsDir, "deployment.yaml"), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	outputPath := filepath.Join(t.TempDir(), "rendered.yaml")

	cmd := newPlacementRenderCommand()
	cmd.SetArgs([]string{
		"--addon-name", "metrics",
		"--manifest-directory", manifestsDir,
		"--selector", "kubernetes.io/hostname=infra-1",
		"--output", outputPath,
	})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("placement render command error = %v", err)
	}

	rendered, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(rendered), "kubernetes.io/os: linux") || !strings.Contains(string(rendered), "kubernetes.io/hostname: infra-1") {
		t.Fatalf("rendered output did not preserve and merge selectors:\n%s", rendered)
	}
}

func TestPlacementRenderCommandRejectsUnsupportedAddon(t *testing.T) {
	cmd := newPlacementRenderCommand()
	cmd.SetArgs([]string{"--addon-name", "gpu-node", "--manifest-directory", "unused", "--selector", "key=value", "--output", "unused"})
	if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), "does not support infrastructure placement") {
		t.Fatalf("placement render command error = %v, want unsupported-addon error", err)
	}
}

func TestPlacementRenderCommandOwnerInputs(t *testing.T) {
	input := "nodeSelector:\n  kubernetes.io/os: linux\n"
	inputPath := filepath.Join(t.TempDir(), "input.yaml")
	if err := os.WriteFile(inputPath, []byte(input), 0o600); err != nil {
		t.Fatal(err)
	}
	outputPath := filepath.Join(t.TempDir(), "output.yaml")
	cmd := newPlacementRenderCommand()
	cmd.SetArgs([]string{"--addon-name", "dashboard", "--input-file", inputPath, "--selector", "kubernetes.io/hostname=kubemaster", "--output", outputPath})
	if err := cmd.Execute(); err != nil {
		t.Fatal(err)
	}
	output, err := os.ReadFile(outputPath)
	if err != nil || !strings.Contains(string(output), "kubernetes.io/os: linux") || !strings.Contains(string(output), "kubernetes.io/hostname: kubemaster") {
		t.Fatalf("owner output = %s, error = %v", output, err)
	}
}

func TestUnintegratedAddonPlacementIsNotExposed(t *testing.T) {
	addonsNotExposingPlacement := []string{
		"gpu-node", "autoscaling", "viewer", "kubevirt", "dicom", "rollout", "security", "storage",
	}
	repositoryRoot := filepath.Join("..", "..", "..", "..")

	for _, addonName := range addonsNotExposingPlacement {
		t.Run(addonName, func(t *testing.T) {
			if addonplacement.SupportsAddon(addonName) {
				t.Fatalf("addon %q is marked placement-capable before full integration or despite its workload exception", addonName)
			}

			manifestPath := filepath.Join(repositoryRoot, "addons", addonName, "addon.manifest.yaml")
			manifestData, err := os.ReadFile(manifestPath)
			if err != nil {
				t.Fatal(err)
			}
			var manifest placementAddonManifest
			if err := yaml.Unmarshal(manifestData, &manifest); err != nil {
				t.Fatalf("parse addon manifest: %v", err)
			}
			for _, implementation := range manifest.Spec.Implementations {
				enable := implementation.Commands["enable"]
				for _, flag := range enable.CLI.Flags {
					if flag.Name == "infra-node-selector" {
						t.Fatalf("addon %q exposes infra-node-selector before provider coverage is complete", addonName)
					}
				}
				for _, mapping := range enable.Script.ParameterMappings {
					if mapping.CLIFlagName == "infra-node-selector" || mapping.ScriptParameterName == "InfraNodeSelector" {
						t.Fatalf("addon %q maps infra-node-selector before provider coverage is complete", addonName)
					}
				}
			}
		})
	}
}

func TestPlacementRenderCommandStorageAndChartOwners(t *testing.T) {
	for _, test := range []struct {
		addon, input string
		options      []string
		want         string
	}{
		{"registry", "apiVersion: v1\nkind: PersistentVolume\nmetadata:\n  name: data\nspec:\n  nodeAffinity:\n    required:\n      nodeSelectorTerms:\n      - matchExpressions:\n        - key: kubernetes.io/hostname\n          operator: In\n          values: [__STORAGE_NODE__]\n---\napiVersion: apps/v1\nkind: StatefulSet\nmetadata:\n  name: registry\n", []string{"--storage-node", "kubemaster"}, "kubernetes.io/hostname: kubemaster"},
	} {
		t.Run(test.addon, func(t *testing.T) {
			input := filepath.Join(t.TempDir(), "input.yaml")
			output := filepath.Join(t.TempDir(), "output.yaml")
			if err := os.WriteFile(input, []byte(test.input), 0o600); err != nil {
				t.Fatal(err)
			}
			cmd := newPlacementRenderCommand()
			cmd.SetArgs(append([]string{"--addon-name", test.addon, "--input-file", input, "--selector", "kubernetes.io/hostname=kubemaster", "--output", output}, test.options...))
			if err := cmd.Execute(); err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(output)
			if err != nil || !strings.Contains(string(data), test.want) || strings.Contains(string(data), "__STORAGE_NODE__") {
				t.Fatalf("wrong owner output: %s (%v)", data, err)
			}
		})
	}
}

func TestPlacementOwnerAssetsAndFlagMappings(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..", "..", "..")
	for _, addon := range []string{"dashboard"} {
		t.Run(addon, func(t *testing.T) {
			addonDir := filepath.Join(repositoryRoot, "addons", addon)
			data, err := os.ReadFile(filepath.Join(addonDir, "addon.manifest.yaml"))
			if err != nil {
				t.Fatal(err)
			}
			var manifest placementAddonManifest
			if err := yaml.Unmarshal(data, &manifest); err != nil {
				t.Fatal(err)
			}
			for _, impl := range manifest.Spec.Implementations {
				foundFlag, foundMapping := false, false
				for _, flag := range impl.Commands["enable"].CLI.Flags {
					foundFlag = foundFlag || flag.Name == "infra-node-selector"
				}
				for _, mapping := range impl.Commands["enable"].Script.ParameterMappings {
					foundMapping = foundMapping || (mapping.CLIFlagName == "infra-node-selector" && mapping.ScriptParameterName == "InfraNodeSelector")
				}
				if !foundFlag || !foundMapping || !addonplacement.SupportsAddon(addon) {
					t.Fatal("owner integration is missing manifest flag, mapping or provider capability")
				}
				if _, exists := impl.Commands["update"]; exists {
					t.Fatal("public update command must not be exposed")
				}
			}
			if _, err := exec.LookPath("helm"); err != nil {
				t.Skip("local Helm required for offline chart asset check")
			}
			chartDir := filepath.Join(addonDir, "manifests", "chart")
			chart, values, err := addonplacement.PrepareHeadlampChart(chartDir, "kubernetes.io/hostname=kubemaster")
			if err != nil {
				t.Fatal(err)
			}
			rendered, err := addonplacement.TemplateHeadlampChart("helm", chart, values)
			if err != nil {
				t.Fatalf("render chart: %v: %s", err, rendered)
			}
			if !strings.Contains(string(rendered), "kubernetes.io/os: linux") || !strings.Contains(string(rendered), "kubernetes.io/hostname: kubemaster") || !strings.Contains(string(rendered), "kind: Deployment") {
				t.Fatalf("owner assets lost hard or mandatory placement: %s", rendered)
			}
			inputPath := filepath.Join(addonDir, "manifests", "chart", "values.yaml")
			selectorsPath := filepath.Join(t.TempDir(), "selectors.json")
			cmd := newPlacementRenderCommand()
			cmd.SetArgs([]string{"--addon-name", addon, "--input-file", inputPath, "--selector", "kubernetes.io/hostname=kubemaster", "--output", selectorsPath, "--selectors-only"})
			if err := cmd.Execute(); err != nil {
				t.Fatal(err)
			}
			selectors, err := os.ReadFile(selectorsPath)
			if err != nil || string(selectors) != `["kubernetes.io/hostname=kubemaster,kubernetes.io/os=linux"]` {
				t.Fatalf("owning rendered selectors = %s, error = %v", selectors, err)
			}
		})
	}
}

func TestPlacementRenderCommandRetainsHelmDiagnosticAndCleansValues(t *testing.T) {
	helm, err := exec.LookPath("helm")
	if err != nil {
		t.Skip("local Helm required for offline template failure test")
	}
	chartDir := t.TempDir()
	inputPath := filepath.Join(chartDir, "values.yaml")
	if err := os.WriteFile(inputPath, []byte("nodeSelector: {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(chartDir, "headlamp-invalid.tgz"), []byte("invalid local chart"), 0o600); err != nil {
		t.Fatal(err)
	}
	temporaryFiles := t.TempDir()
	t.Setenv("TMP", temporaryFiles)
	t.Setenv("TEMP", temporaryFiles)
	t.Setenv("TMPDIR", temporaryFiles)
	outputPath := filepath.Join(t.TempDir(), "selectors.json")
	command := newPlacementRenderCommand()
	command.SetArgs([]string{"--addon-name", "dashboard", "--input-file", inputPath, "--selector", "pool=infra", "--output", outputPath, "--selectors-only", "--helm-path", helm})
	err = command.Execute()
	if err == nil || !strings.Contains(err.Error(), "render offline Headlamp chart") || !strings.Contains(err.Error(), "Error:") {
		t.Fatalf("Helm diagnostic lost: %v", err)
	}
	if _, err := os.Stat(outputPath); !os.IsNotExist(err) {
		t.Fatal("failed chart wrote selector output")
	}
	files, err := os.ReadDir(temporaryFiles)
	if err != nil || len(files) != 0 {
		t.Fatalf("template leaked temporary files: %v, %v", files, err)
	}
}

func TestSupportedAddonPlacementManifestCoverage(t *testing.T) {
	tests := []struct {
		addonName         string
		workloadCount     int
		preservedSelector string
	}{
		{addonName: "metrics", workloadCount: 1, preservedSelector: "kubernetes.io/os: linux"},
	}
	repositoryRoot := filepath.Join("..", "..", "..", "..")

	for _, test := range tests {
		t.Run(test.addonName, func(t *testing.T) {
			manifestPath := filepath.Join(repositoryRoot, "addons", test.addonName, "addon.manifest.yaml")
			manifestData, err := os.ReadFile(manifestPath)
			if err != nil {
				t.Fatal(err)
			}
			var manifest placementAddonManifest
			if err := yaml.Unmarshal(manifestData, &manifest); err != nil {
				t.Fatal(err)
			}
			for _, implementation := range manifest.Spec.Implementations {
				enable, exists := implementation.Commands["enable"]
				if !exists {
					t.Fatal("enable command is missing")
				}
				flagFound := false
				for _, flag := range enable.CLI.Flags {
					flagFound = flagFound || flag.Name == "infra-node-selector"
				}
				mappingFound := false
				for _, mapping := range enable.Script.ParameterMappings {
					mappingFound = mappingFound || (mapping.CLIFlagName == "infra-node-selector" && mapping.ScriptParameterName == "InfraNodeSelector")
				}
				if !flagFound || !mappingFound {
					t.Fatalf("enable manifest flag/mapping missing: flag=%t mapping=%t", flagFound, mappingFound)
				}
			}

			manifestsDir := filepath.Join(repositoryRoot, "addons", test.addonName, "manifests")
			rendered, changed, err := addonplacement.RenderManifestDirectory(manifestsDir, "kubernetes.io/hostname=infra-1")
			if err != nil {
				t.Fatalf("render addon manifests: %v", err)
			}
			if changed != test.workloadCount {
				t.Fatalf("rendered workload count = %d, want %d", changed, test.workloadCount)
			}
			if test.preservedSelector != "" && !strings.Contains(string(rendered), test.preservedSelector) {
				t.Fatalf("rendered output does not preserve %q", test.preservedSelector)
			}
		})
	}
}
