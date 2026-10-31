// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/k2s-project/k2s/internal/definitions"
	kjson "github.com/k2s-project/k2s/internal/json"
)

func createDummyScript(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatalf("failed to create script dir: %v", err)
	}
	content := []byte("#!/bin/sh\nexit 0\n")
	if err := os.WriteFile(path, content, 0755); err != nil {
		t.Fatalf("failed to create dummy script: %v", err)
	}
}

func TestLinuxImageProvider_ScriptPath(t *testing.T) {
	p := &linuxImageProvider{installDir: "/test/k2s"}
	got := p.scriptPath("test.sh")
	want := filepath.Join("/test/k2s", "lib", "scripts", "linux", "debian", "host", "image", "test.sh")
	if got != want {
		t.Fatalf("scriptPath() = %q, want %q", got, want)
	}
}

func TestLinuxImageProvider_BuildRejectsWindows(t *testing.T) {
	p := &linuxImageProvider{installDir: "/test/k2s"}
	err := p.Build(ImageBuildConfig{Windows: true})
	if err == nil {
		t.Fatal("Build(Windows=true) expected error, got nil")
	}
	if !strings.Contains(err.Error(), "building Windows container images is not supported on Linux hosts") {
		t.Fatalf("unexpected error message: %v", err)
	}
}

func TestLinuxImageProvider_BuildExecutesScript(t *testing.T) {
	tmpDir := t.TempDir()
	p := &linuxImageProvider{installDir: tmpDir}
	script := p.scriptPath("Build-Image.sh")
	createDummyScript(t, script)

	err := p.Build(ImageBuildConfig{
		InputFolder: tmpDir,
		ImageName:   "myimage",
		ImageTag:    "v1",
		BuildArgs:   map[string]string{"KEY": "VAL"},
	})
	if err != nil {
		t.Fatalf("Build() failed: %v", err)
	}
}

func TestLinuxImageProvider_RegistryAddAndRemoveSyncsSetupJson(t *testing.T) {
	installDir := t.TempDir()
	configDir := t.TempDir()

	p := &linuxImageProvider{
		installDir: installDir,
		configDir:  configDir,
	}

	addScript := p.scriptPath(filepath.Join("registry", "Add-Registry.sh"))
	createDummyScript(t, addScript)

	rmScript := p.scriptPath(filepath.Join("registry", "Remove-Registry.sh"))
	createDummyScript(t, rmScript)

	// Create initial setup.json
	setupJsonPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	initialConfig := map[string]any{
		"SetupType":  "k2s",
		"LinuxOnly":  true,
		"Registries": []any{"existing.registry.io"},
	}
	if err := kjson.ToFile(setupJsonPath, &initialConfig); err != nil {
		t.Fatalf("failed to write initial setup.json: %v", err)
	}

	// RegistryAdd
	err := p.RegistryAdd(ImageRegistryAddConfig{
		RegistryName: "my.new.registry:5000",
		Username:     "user",
		Password:     "pass",
		SkipVerify:   true,
		PlainHttp:    true,
	})
	if err != nil {
		t.Fatalf("RegistryAdd() failed: %v", err)
	}

	// Verify setup.json contains both registries
	loadedConfig, err := kjson.FromFile[map[string]any](setupJsonPath)
	if err != nil {
		t.Fatalf("failed to read setup.json: %v", err)
	}
	regs := (*loadedConfig)["Registries"].([]any)
	if len(regs) != 2 {
		t.Fatalf("expected 2 registries, got %d: %v", len(regs), regs)
	}
	if regs[0] != "existing.registry.io" || regs[1] != "my.new.registry:5000" {
		t.Fatalf("unexpected registries list: %v", regs)
	}

	// RegistryAdd duplicate should not duplicate
	if err := p.RegistryAdd(ImageRegistryAddConfig{RegistryName: "my.new.registry:5000"}); err != nil {
		t.Fatalf("RegistryAdd() duplicate failed: %v", err)
	}
	loadedConfig, _ = kjson.FromFile[map[string]any](setupJsonPath)
	regs = (*loadedConfig)["Registries"].([]any)
	if len(regs) != 2 {
		t.Fatalf("expected 2 registries after adding duplicate, got %d", len(regs))
	}

	// RegistryRemove
	err = p.RegistryRemove(ImageRegistryRemoveConfig{
		RegistryName: "existing.registry.io",
	})
	if err != nil {
		t.Fatalf("RegistryRemove() failed: %v", err)
	}

	loadedConfig, err = kjson.FromFile[map[string]any](setupJsonPath)
	if err != nil {
		t.Fatalf("failed to read setup.json: %v", err)
	}
	regs = (*loadedConfig)["Registries"].([]any)
	if len(regs) != 1 || regs[0] != "my.new.registry:5000" {
		t.Fatalf("expected only 'my.new.registry:5000' remaining, got %v", regs)
	}
}

func TestLinuxImageProvider_DelegatesToScripts(t *testing.T) {
	installDir := t.TempDir()
	p := &linuxImageProvider{installDir: installDir}

	for _, script := range []string{
		"Clean-Images.sh",
		"Remove-Image.sh",
		"Export-Image.sh",
		"Import-Image.sh",
		"Pull-Image.sh",
		"Push-Image.sh",
		"Tag-Image.sh",
	} {
		createDummyScript(t, p.scriptPath(script))
	}

	if err := p.Clean(ImageCleanConfig{}); err != nil {
		t.Fatalf("Clean() failed: %v", err)
	}
	if err := p.Remove(ImageRemoveConfig{ImageName: "test"}); err != nil {
		t.Fatalf("Remove() failed: %v", err)
	}
	if err := p.Export(ImageExportConfig{ImageName: "test", OutputPath: "/tmp/out.tar"}); err != nil {
		t.Fatalf("Export() failed: %v", err)
	}
	if err := p.Import(ImageImportConfig{TarPath: "/tmp/in.tar"}); err != nil {
		t.Fatalf("Import() failed: %v", err)
	}
	if err := p.Pull(ImagePullConfig{ImageName: "test"}); err != nil {
		t.Fatalf("Pull() failed: %v", err)
	}
	if err := p.Push(ImagePushConfig{ImageName: "test"}); err != nil {
		t.Fatalf("Push() failed: %v", err)
	}
	if err := p.Tag(ImageTagConfig{ImageName: "test", TargetImageName: "test2"}); err != nil {
		t.Fatalf("Tag() failed: %v", err)
	}
}

func TestFlexibleSize(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "string with unit",
			input:    `"97.1 MB"`,
			expected: "97.1 MB",
		},
		{
			name:     "string numeric",
			input:    `"97114485"`,
			expected: "97114485",
		},
		{
			name:     "numeric int64",
			input:    `97114485`,
			expected: "97114485",
		},
		{
			name:     "numeric float64 whole",
			input:    `97114485.0`,
			expected: "97114485",
		},
		{
			name:     "numeric float64 fractional",
			input:    `12345.5`,
			expected: "12345.5",
		},
		{
			name:     "null",
			input:    `null`,
			expected: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var sz flexibleSize
			if err := json.Unmarshal([]byte(tt.input), &sz); err != nil {
				t.Fatalf("UnmarshalJSON failed: %v", err)
			}
			if string(sz) != tt.expected {
				t.Fatalf("expected %q, got %q", tt.expected, string(sz))
			}
			if sz.String() != tt.expected {
				t.Fatalf("String() expected %q, got %q", tt.expected, sz.String())
			}
		})
	}
}

func TestCrictlImageParsing_FlexibleSizeAndSha256Stripping(t *testing.T) {
	jsonData := `{
		"images": [
			{
				"id": "sha256:7c7f3b8908f972b22bb89a244431e67bb93406f36ebc24f6530a6c22cb8bbdf7",
				"repoTags": ["docker.io/library/nginx:latest"],
				"repoDigests": ["docker.io/library/nginx@sha256:..."],
				"size": 97114485
			},
			{
				"id": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
				"repoTags": ["docker.io/library/alpine:latest"],
				"repoDigests": [],
				"size": "97.1 MB"
			}
		]
	}`

	var result struct {
		Images []struct {
			Id          string       `json:"id"`
			RepoTags    []string     `json:"repoTags"`
			RepoDigests []string     `json:"repoDigests"`
			Size        flexibleSize `json:"size"`
		} `json:"images"`
	}

	if err := json.Unmarshal([]byte(jsonData), &result); err != nil {
		t.Fatalf("failed to unmarshal crictl JSON: %v", err)
	}

	if len(result.Images) != 2 {
		t.Fatalf("expected 2 images, got %d", len(result.Images))
	}

	img1 := result.Images[0]
	shortId1 := strings.TrimPrefix(img1.Id, "sha256:")
	if len(shortId1) > 12 {
		shortId1 = shortId1[:12]
	}
	if shortId1 != "7c7f3b8908f9" {
		t.Fatalf("expected shortId '7c7f3b8908f9', got %q", shortId1)
	}
	if string(img1.Size) != "97114485" {
		t.Fatalf("expected size '97114485', got %q", string(img1.Size))
	}

	img2 := result.Images[1]
	shortId2 := strings.TrimPrefix(img2.Id, "sha256:")
	if len(shortId2) > 12 {
		shortId2 = shortId2[:12]
	}
	if shortId2 != "e3b0c44298fc" {
		t.Fatalf("expected shortId 'e3b0c44298fc', got %q", shortId2)
	}
	if string(img2.Size) != "97.1 MB" {
		t.Fatalf("expected size '97.1 MB', got %q", string(img2.Size))
	}
}
