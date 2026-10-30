// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package backup

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestAddPlacementMetadata(t *testing.T) {
	for _, test := range []struct {
		name     string
		config   string
		selector string
	}{
		{"legacy omission", `{"EnabledAddons":[{"Name":"ingress","Implementation":"nginx"}]}`, ""},
		{"exact implementation", `{"EnabledAddons":[{"Name":"ingress","Implementation":"traefik","InfraNodeSelector":"pool=other"},{"Name":"ingress","Implementation":"nginx","InfraNodeSelector":"pool=infra"}]}`, "pool=infra"},
		{"legacy record cannot shadow implementation", `{"EnabledAddons":[{"Name":"ingress","InfraNodeSelector":"pool=legacy"},{"Name":"ingress","Implementation":"nginx","InfraNodeSelector":"pool=infra"}]}`, "pool=infra"},
	} {
		t.Run(test.name, func(t *testing.T) {
			directory := t.TempDir()
			configPath := filepath.Join(directory, "setup.json")
			manifestPath := filepath.Join(directory, "backup.json")
			original := []byte(`{"k2sVersion":"1.0","addon":"ingress","implementation":"nginx","files":[],"custom":{"preserved":true}}`)
			if err := os.WriteFile(configPath, append([]byte{0xef, 0xbb, 0xbf}, []byte(test.config)...), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(manifestPath, original, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := addPlacementMetadata(manifestPath, configPath, "ingress", "nginx"); err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(manifestPath)
			if err != nil {
				t.Fatal(err)
			}
			var manifest map[string]json.RawMessage
			if err := json.Unmarshal(data, &manifest); err != nil {
				t.Fatal(err)
			}
			if test.selector == "" {
				if string(data) != string(original) {
					t.Fatal("legacy backup changed despite omitted placement")
				}
			} else {
				var selector string
				if err := json.Unmarshal(manifest["infraNodeSelector"], &selector); err != nil {
					t.Fatal(err)
				}
				if selector != test.selector {
					t.Fatalf("selector = %q, want %q", selector, test.selector)
				}
			}
			if string(manifest["custom"]) != `{"preserved":true}` && string(manifest["custom"]) != "{\n    \"preserved\": true\n  }" {
				t.Fatalf("custom metadata lost: %s", manifest["custom"])
			}
		})
	}
}

func TestAddPlacementMetadataIsBestEffort(t *testing.T) {
	original := []byte(`{"k2sVersion":"1.0","addon":"metrics","files":[]}`)

	for _, test := range []struct {
		name   string
		config *string
	}{
		{"runtime config missing", nil},
		{"runtime config not json", ptr("not json")},
	} {
		t.Run(test.name, func(t *testing.T) {
			directory := t.TempDir()
			configPath := filepath.Join(directory, "setup.json")
			manifestPath := filepath.Join(directory, "backup.json")
			if test.config != nil {
				if err := os.WriteFile(configPath, []byte(*test.config), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(manifestPath, original, 0o600); err != nil {
				t.Fatal(err)
			}

			if err := addPlacementMetadata(manifestPath, configPath, "metrics", "metrics"); err != nil {
				t.Fatalf("backup must not fail on unusable runtime config: %v", err)
			}
			data, err := os.ReadFile(manifestPath)
			if err != nil {
				t.Fatal(err)
			}
			if string(data) != string(original) {
				t.Fatal("backup.json changed although no placement could be read")
			}
		})
	}
}

func TestAddPlacementMetadataRejectsCorruptBackupManifest(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "setup.json")
	manifestPath := filepath.Join(directory, "backup.json")
	if err := os.WriteFile(configPath, []byte(`{"EnabledAddons":[{"Name":"metrics","InfraNodeSelector":"pool=infra"}]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(manifestPath, []byte("not json"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := addPlacementMetadata(manifestPath, configPath, "metrics", "metrics"); err == nil {
		t.Fatal("expected an error for a corrupt backup.json")
	}
}

func ptr(value string) *string { return &value }
