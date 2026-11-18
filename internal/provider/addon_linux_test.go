// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/k2s-project/k2s/internal/definitions"
	sshprovider "github.com/k2s-project/k2s/internal/providers/ssh"
	"gopkg.in/yaml.v3"
)

func TestRunCommand_RejectsInfraNodeSelectorWithoutSideEffects(t *testing.T) {
	p := &linuxAddonProvider{installDir: t.TempDir()}
	for name, cfg := range map[string]AddonRunCommandConfig{
		"script param":    {AddonName: "metrics", CommandName: "enable", Params: []string{" -InfraNodeSelector 'kubernetes.io/hostname=infra-1'"}},
		"parameter value": {AddonName: "metrics", CommandName: "enable", ParameterValues: map[string]string{"InfraNodeSelector": "kubernetes.io/hostname=infra-1"}},
	} {
		t.Run(name, func(t *testing.T) {
			err := p.RunCommand(cfg)
			if !errors.Is(err, ErrNotSupported) || !strings.Contains(err.Error(), "Windows-hosted") {
				t.Fatalf("expected NotSupportedError mentioning Windows-hosted clusters, got: %v", err)
			}
		})
	}
}

func TestRunCommand_WithoutSelectorIsUnaffected(t *testing.T) {
	p := &linuxAddonProvider{installDir: t.TempDir()}
	err := p.RunCommand(AddonRunCommandConfig{AddonName: "metrics", CommandName: "update", Params: []string{"-OmitGrafana"}})
	if !errors.Is(err, ErrNotSupported) || strings.Contains(err.Error(), "infra-node-selector") {
		t.Fatalf("expected the regular unsupported-command error, got: %v", err)
	}
}

const (
	configMediaType        = "application/vnd.k2s.addon.configfiles.v1.tar+gzip"
	manifestsMediaType     = "application/vnd.k2s.addon.manifests.v1.tar+gzip"
	chartsMediaType        = "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
	scriptsMediaType       = "application/vnd.k2s.addon.scripts.v1.tar+gzip"
	linuxImagesMediaType   = "application/vnd.oci.image.layer.v1.tar"
	windowsImagesMediaType = "application/vnd.k2s.addon.images-windows.v1.tar"
	packagesMediaType      = "application/vnd.k2s.addon.packages.v1.tar+gzip"

	certManagerArchive = "quay.io_jetstack_cert-manager-controller_v1.20.2.tar"
	nginxArchive       = "registry.k8s.io_ingress-nginx_v1.tar"
)

type tarEntry struct {
	name    string
	content string
}

type testLayer struct {
	mediaType string
	content   []byte
	corrupt   bool
}

type testAddon struct {
	name           string
	implementation string
	layers         []testLayer
}

func tarOf(t *testing.T, entries ...tarEntry) []byte {
	t.Helper()
	var archive bytes.Buffer
	writer := tar.NewWriter(&archive)
	for _, entry := range entries {
		header := &tar.Header{Name: entry.name, Typeflag: tar.TypeReg, Mode: 0o644, Size: int64(len(entry.content))}
		if err := writer.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write([]byte(entry.content)); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return archive.Bytes()
}

func tarGzOf(t *testing.T, entries ...tarEntry) []byte {
	t.Helper()
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	if _, err := writer.Write(tarOf(t, entries...)); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return compressed.Bytes()
}

// writeArtifact creates an OCI artifact laid out like the one written by addons/Export.ps1.
func writeArtifact(t *testing.T, addons ...testAddon) string {
	t.Helper()
	entries := []tarEntry{{"./oci-layout", `{"imageLayoutVersion":"1.0.0"}`}}
	addBlob := func(content []byte, corrupt bool) string {
		digest := fmt.Sprintf("%x", sha256.Sum256(content))
		if corrupt {
			content = append(slices.Clone(content), "tampered"...)
		}
		entries = append(entries, tarEntry{"./blobs/sha256/" + digest, string(content)})
		return "sha256:" + digest
	}

	var indexManifests []map[string]any
	for _, addon := range addons {
		layers := []map[string]any{}
		for _, layer := range addon.layers {
			layers = append(layers, map[string]any{"mediaType": layer.mediaType, "digest": addBlob(layer.content, layer.corrupt)})
		}
		annotations := map[string]string{addonNameAnnotation: addon.name, addonImplAnnotation: addon.implementation}
		manifestJSON, err := json.Marshal(map[string]any{"schemaVersion": 2, "layers": layers, "annotations": annotations})
		if err != nil {
			t.Fatal(err)
		}
		indexManifests = append(indexManifests, map[string]any{"digest": addBlob(manifestJSON, false), "annotations": annotations})
	}

	indexJSON, err := json.Marshal(map[string]any{"schemaVersion": 2, "manifests": indexManifests})
	if err != nil {
		t.Fatal(err)
	}
	entries = append(entries, tarEntry{"./index.json", string(indexJSON)})

	artifact := filepath.Join(t.TempDir(), "addons.oci.tar")
	if err := os.WriteFile(artifact, tarOf(t, entries...), 0o600); err != nil {
		t.Fatal(err)
	}
	return artifact
}

// importFixture is a provider whose Import-Image.sh records the archives handed to it; an
// archive with the content 'broken' makes the script fail.
type importFixture struct {
	provider *linuxAddonProvider
	record   string
}

func newImportFixture(t *testing.T) *importFixture {
	t.Helper()
	installDir := t.TempDir()
	fixture := &importFixture{
		provider: &linuxAddonProvider{installDir: installDir, configDir: t.TempDir()},
		record:   filepath.Join(t.TempDir(), "imported-images"),
	}

	script := (&linuxImageProvider{installDir: installDir}).scriptPath("Import-Image.sh")
	if err := os.MkdirAll(filepath.Dir(script), 0o755); err != nil {
		t.Fatal(err)
	}
	body := "#!/bin/sh\ncontent=$(cat \"$2\")\nprintf '%s=%s\\n' \"$(basename \"$2\")\" \"$content\" >> \"" + fixture.record + "\"\n[ \"$content\" != broken ]\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return fixture
}

func (f *importFixture) addonsDir() string { return filepath.Join(f.provider.installDir, "addons") }

func (f *importFixture) importedImages(t *testing.T) []string {
	t.Helper()
	content, err := os.ReadFile(f.record)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(content)), "\n")
}

func assertFile(t *testing.T, want string, pathElements ...string) {
	t.Helper()
	content, err := os.ReadFile(filepath.Join(pathElements...))
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != want {
		t.Fatalf("%s = %q, want %q", filepath.Join(pathElements...), content, want)
	}
}

func manifestsLayerOf(t *testing.T, fileName string) testLayer {
	return testLayer{mediaType: manifestsMediaType, content: tarGzOf(t, tarEntry{"./" + fileName, fileName})}
}

// omitManifest declares the enable flag omitCertMgr that covers the given images.
func omitManifest(addonName, implementation string, fromFiles []string, explicit ...string) string {
	var covered strings.Builder
	if len(fromFiles) > 0 {
		covered.WriteString("                  fromFiles:\n")
		for _, file := range fromFiles {
			covered.WriteString("                    - " + file + "\n")
		}
	}
	if len(explicit) > 0 {
		covered.WriteString("                  explicit:\n")
		for _, image := range explicit {
			covered.WriteString("                    - " + image + "\n")
		}
	}
	return fmt.Sprintf(`apiVersion: v1
kind: Addon
metadata:
  name: %s
spec:
  implementations:
    - name: %s
      commands:
        enable:
          cli:
            flags:
              - name: omitCertMgr
                omittedImages:
%s`, addonName, implementation, covered.String())
}

// certManagerAddon is an ingress implementation that carries a cert-manager and an ingress image.
func certManagerAddon(t *testing.T, name, implementation, configManifest string) testAddon {
	layers := []testLayer{{mediaType: linuxImagesMediaType, content: tarOf(t,
		tarEntry{"./" + certManagerArchive, "cert-manager"}, tarEntry{"./" + nginxArchive, "nginx"})}}
	if configManifest != "" {
		layers = append(layers, testLayer{mediaType: configMediaType, content: tarGzOf(t, tarEntry{"./addon.manifest.yaml", configManifest})})
	}
	return testAddon{name: name, implementation: implementation, layers: layers}
}

func TestImport_StagesAddonFilesAndImportsLinuxImages(t *testing.T) {
	fixture := newImportFixture(t)
	artifact := writeArtifact(t, testAddon{name: "dashboard", implementation: "dashboard", layers: []testLayer{
		{mediaType: configMediaType, content: tarGzOf(t,
			tarEntry{"./addon.manifest.yaml", "manifest"}, tarEntry{"./values.yaml", "values"}, tarEntry{"./config/settings.json", "settings"})},
		{mediaType: manifestsMediaType, content: tarGzOf(t,
			tarEntry{"./dashboard.yaml", "deployment"}, tarEntry{"./gitops-sync/sync-job.yaml", "job"})},
		{mediaType: chartsMediaType, content: tarGzOf(t, tarEntry{"./headlamp-1.0.0.tgz", "chart"})},
		{mediaType: scriptsMediaType, content: tarGzOf(t, tarEntry{"./Enable.ps1", "script"})},
		{mediaType: linuxImagesMediaType, content: tarOf(t,
			tarEntry{"./registry.k8s.io_one_v1.tar", "image-one"}, tarEntry{"./registry.k8s.io_two_v2.tar", "image-two"})},
		{mediaType: windowsImagesMediaType, content: tarOf(t, tarEntry{"./windows_one_v1.tar", "windows-image"})},
		{mediaType: packagesMediaType, content: tarGzOf(t, tarEntry{"./debianpackages/tool.deb", "package"})},
	}})

	if err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact}); err != nil {
		t.Fatal(err)
	}

	addonDir := filepath.Join(fixture.addonsDir(), "dashboard")
	assertFile(t, "manifest", addonDir, "addon.manifest.yaml")
	assertFile(t, "values", addonDir, "values.yaml")
	assertFile(t, "settings", addonDir, "config", "settings.json")
	assertFile(t, "deployment", addonDir, "manifests", "dashboard.yaml")
	assertFile(t, "job", addonDir, "manifests", "gitops-sync", "sync-job.yaml")
	assertFile(t, "chart", addonDir, "manifests", "chart", "headlamp-1.0.0.tgz")
	assertFile(t, "script", addonDir, "Enable.ps1")

	wantImages := []string{"registry.k8s.io_one_v1.tar=image-one", "registry.k8s.io_two_v2.tar=image-two"}
	if images := fixture.importedImages(t); !slices.Equal(images, wantImages) {
		t.Fatalf("imported images = %q, want %q", images, wantImages)
	}
	if _, err := os.Stat(filepath.Join(addonDir, "debianpackages")); err == nil {
		t.Fatal("offline packages were staged into the addon directory")
	}
}

func TestImport_StagesSharedScriptsAtAddonRoot(t *testing.T) {
	for _, implementation := range []string{"smb", "ceph"} {
		t.Run(implementation, func(t *testing.T) {
			fixture := newImportFixture(t)
			artifact := writeArtifact(t, testAddon{name: "storage", implementation: implementation, layers: []testLayer{
				{mediaType: scriptsMediaType, content: tarGzOf(t,
					tarEntry{"./Enable.ps1", "enable"}, tarEntry{"./README.md", "implementation documentation"})},
				{mediaType: "application/vnd.k2s.addon.shared-scripts.v1.tar+gzip", content: tarGzOf(t,
					tarEntry{"./storage-validation.module.psm1", "shared validation"},
					tarEntry{"./README.md", "shared storage documentation"},
					tarEntry{"./README.md.license", "readme license"})},
			}})

			if err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact}); err != nil {
				t.Fatal(err)
			}

			addonDir := filepath.Join(fixture.addonsDir(), "storage")
			assertFile(t, "shared validation", addonDir, "storage-validation.module.psm1")
			assertFile(t, "shared storage documentation", addonDir, "README.md")
			assertFile(t, "readme license", addonDir, "README.md.license")
			assertFile(t, "enable", addonDir, implementation, "Enable.ps1")
			assertFile(t, "implementation documentation", addonDir, implementation, "README.md")
			if _, err := os.Stat(filepath.Join(addonDir, implementation, "storage-validation.module.psm1")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("shared module must not be placed in the implementation directory: %v", err)
			}
		})
	}
}

func TestImport_MergesNewImplementationIntoInstalledManifest(t *testing.T) {
	installedManifest := `# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

apiVersion: v1
kind: AddonManifest
metadata:
  name: ingress
spec:
  implementations:
    - name: nginx
      description: installed nginx
`
	exportedManifest := `metadata:
  name: ingress
spec:
  implementations:
    - name: nginx
      description: exported nginx
    - name: traefik
      description: exported traefik
`
	fixture := newImportFixture(t)
	artifact := writeArtifact(t, testAddon{name: "ingress", implementation: "traefik", layers: []testLayer{
		{mediaType: configMediaType, content: tarGzOf(t, tarEntry{"./addon.manifest.yaml", exportedManifest})},
		manifestsLayerOf(t, "traefik.yaml"),
	}})
	manifestPath := filepath.Join(fixture.addonsDir(), "ingress", "addon.manifest.yaml")
	if err := os.MkdirAll(filepath.Dir(manifestPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(manifestPath, []byte(installedManifest), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact}); err != nil {
		t.Fatal(err)
	}

	assertFile(t, "traefik.yaml", fixture.addonsDir(), "ingress", "traefik", "manifests", "traefik.yaml")
	if _, err := os.Stat(filepath.Join(fixture.addonsDir(), "ingress", "traefik", "addon.manifest.yaml")); err == nil {
		t.Fatal("addon manifest was staged into the implementation directory")
	}

	merged, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	var parsed struct {
		Spec struct {
			Implementations []struct {
				Name        string `yaml:"name"`
				Description string `yaml:"description"`
			} `yaml:"implementations"`
		} `yaml:"spec"`
	}
	if err := yaml.Unmarshal(merged, &parsed); err != nil {
		t.Fatalf("merged manifest is invalid: %v\n%s", err, merged)
	}
	implementations := parsed.Spec.Implementations
	if len(implementations) != 2 || implementations[0].Description != "installed nginx" || implementations[1].Name != "traefik" {
		t.Fatalf("unexpected implementations %+v\n%s", implementations, merged)
	}
	if !strings.HasPrefix(string(merged), "# SPDX-FileCopyrightText: © 2026 The K2s Authors\n# SPDX-License-Identifier: Apache-2.0\n") {
		t.Fatalf("license header was not preserved:\n%s", merged)
	}

	if err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact}); err != nil {
		t.Fatal(err)
	}
	assertFile(t, string(merged), manifestPath)
}

func TestImport_OnlySelectedAddons(t *testing.T) {
	fixture := newImportFixture(t)
	artifact := writeArtifact(t,
		testAddon{name: "registry", implementation: "registry", layers: []testLayer{manifestsLayerOf(t, "registry.yaml")}},
		testAddon{name: "ingress", implementation: "nginx", layers: []testLayer{manifestsLayerOf(t, "nginx.yaml")}},
		testAddon{name: "ingress", implementation: "traefik", layers: []testLayer{manifestsLayerOf(t, "traefik.yaml")}},
	)

	if err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Names: []string{"ingress", "nginx"}}); err != nil {
		t.Fatal(err)
	}

	assertFile(t, "nginx.yaml", fixture.addonsDir(), "ingress", "nginx", "manifests", "nginx.yaml")
	for _, notImported := range []string{"registry", filepath.Join("ingress", "traefik")} {
		if _, err := os.Stat(filepath.Join(fixture.addonsDir(), notImported)); err == nil {
			t.Fatalf("'%s' was imported although it was not selected", notImported)
		}
	}
}

func TestImport_ReportsImageFailuresAfterTryingAllImages(t *testing.T) {
	fixture := newImportFixture(t)
	artifact := writeArtifact(t, testAddon{name: "metrics", implementation: "metrics", layers: []testLayer{
		manifestsLayerOf(t, "metrics.yaml"),
		{mediaType: linuxImagesMediaType, content: tarOf(t, tarEntry{"./one_v1.tar", "broken"}, tarEntry{"./two_v2.tar", "image-two"})},
	}})

	err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact})

	if err == nil || !strings.Contains(err.Error(), "one_v1.tar of 'metrics'") || strings.Contains(err.Error(), "two_v2.tar") {
		t.Fatalf("expected a failure naming only the broken image, got: %v", err)
	}
	if images := fixture.importedImages(t); len(images) != 2 {
		t.Fatalf("import stopped after the first failure: %q", images)
	}
	assertFile(t, "metrics.yaml", fixture.addonsDir(), "metrics", "manifests", "metrics.yaml")
}

func TestImport_RejectsInvalidArtifacts(t *testing.T) {
	manifests := manifestsLayerOf(t, "addon.yaml")
	corrupted := manifests
	corrupted.corrupt = true

	for name, test := range map[string]struct {
		addon     testAddon
		wantError string
	}{
		"entry outside of the destination": {
			addon: testAddon{name: "metrics", implementation: "metrics", layers: []testLayer{
				{mediaType: manifestsMediaType, content: tarGzOf(t, tarEntry{"../../../evil.yaml", "evil"})}}},
			wantError: "outside of the extraction directory",
		},
		"corrupted blob": {
			addon:     testAddon{name: "metrics", implementation: "metrics", layers: []testLayer{corrupted}},
			wantError: "integrity check failed",
		},
		"addon name leaving the addons directory": {
			addon:     testAddon{name: "../metrics", implementation: "../metrics", layers: []testLayer{manifests}},
			wantError: "not a valid directory name",
		},
		"implementation leaving the addon directory": {
			addon:     testAddon{name: "ingress", implementation: "../../nginx", layers: []testLayer{manifests}},
			wantError: "not a valid directory name",
		},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newImportFixture(t)

			err := fixture.provider.Import(AddonImportConfig{ArtifactFile: writeArtifact(t, test.addon)})

			if err == nil || !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("expected error containing %q, got: %v", test.wantError, err)
			}
			installDir := fixture.provider.installDir
			walkErr := filepath.WalkDir(installDir, func(file string, entry os.DirEntry, err error) error {
				if err == nil && !entry.IsDir() && !strings.HasPrefix(file, filepath.Join(installDir, "lib")) {
					t.Errorf("unexpected file %s", file)
				}
				return err
			})
			if walkErr != nil {
				t.Fatal(walkErr)
			}
		})
	}
}

func TestImport_RejectsUnknownArtifactFormat(t *testing.T) {
	fixture := newImportFixture(t)

	err := fixture.provider.Import(AddonImportConfig{ArtifactFile: filepath.Join(t.TempDir(), "addons.zip")})

	if err == nil || !strings.Contains(err.Error(), "unknown artifact format") {
		t.Fatalf("expected an unknown artifact format error, got: %v", err)
	}
}

func TestImport_Omit(t *testing.T) {
	certManagerImage := "quay.io/jetstack/cert-manager-controller:v1.20.2"
	declaring := omitManifest("ingress", "nginx", nil, certManagerImage)

	for name, test := range map[string]struct {
		addons []testAddon
		names  []string
		omit   []string
		want   []string
	}{
		"without omit everything is imported": {
			addons: []testAddon{certManagerAddon(t, "ingress", "nginx", declaring)},
			want:   []string{certManagerArchive + "=cert-manager", nginxArchive + "=nginx"},
		},
		"flag skips the images it covers": {
			addons: []testAddon{certManagerAddon(t, "ingress", "nginx", declaring)},
			omit:   []string{"omitCertMgr"},
			want:   []string{nginxArchive + "=nginx"},
		},
		"flag name is matched case-insensitive": {
			addons: []testAddon{certManagerAddon(t, "ingress", "nginx", declaring)},
			omit:   []string{"  OMITCERTMGR "},
			want:   []string{nginxArchive + "=nginx"},
		},
		"scope of the matching implementation": {
			addons: []testAddon{certManagerAddon(t, "ingress", "nginx", declaring)},
			omit:   []string{"ingress/nginx:omitCertMgr"},
			want:   []string{nginxArchive + "=nginx"},
		},
		"scope of another addon is ignored": {
			addons: []testAddon{certManagerAddon(t, "ingress", "nginx", declaring)},
			omit:   []string{"security:omitCertMgr"},
			want:   []string{certManagerArchive + "=cert-manager", nginxArchive + "=nginx"},
		},
		"unknown flag is ignored": {
			addons: []testAddon{certManagerAddon(t, "ingress", "nginx", declaring)},
			omit:   []string{"omitSomethingElse"},
			want:   []string{certManagerArchive + "=cert-manager", nginxArchive + "=nginx"},
		},
		"image another imported addon still requires is kept": {
			addons: []testAddon{
				certManagerAddon(t, "ingress", "nginx", declaring),
				{name: "security", implementation: "security", layers: []testLayer{
					{mediaType: linuxImagesMediaType, content: tarOf(t, tarEntry{"./" + certManagerArchive, "cert-manager"})}}},
			},
			omit: []string{"omitCertMgr"},
			want: []string{certManagerArchive + "=cert-manager", nginxArchive + "=nginx", certManagerArchive + "=cert-manager"},
		},
		"image is skipped once every addon omits it": {
			addons: []testAddon{
				certManagerAddon(t, "ingress", "nginx", declaring),
				certManagerAddon(t, "ingress", "traefik", omitManifest("ingress", "traefik", nil, certManagerImage)),
			},
			omit: []string{"omitCertMgr"},
			want: []string{nginxArchive + "=nginx", nginxArchive + "=nginx"},
		},
		"another version of the image in the artifact is matched": {
			addons: []testAddon{certManagerAddon(t, "ingress", "nginx", omitManifest("ingress", "nginx", nil, "quay.io/jetstack/cert-manager-controller:v1.21.1"))},
			omit:   []string{"omitCertMgr"},
			want:   []string{nginxArchive + "=nginx"},
		},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newImportFixture(t)
			cfg := AddonImportConfig{ArtifactFile: writeArtifact(t, test.addons...), Names: test.names, Omit: test.omit}

			if err := fixture.provider.Import(cfg); err != nil {
				t.Fatal(err)
			}

			if images := fixture.importedImages(t); !slices.Equal(images, test.want) {
				t.Fatalf("imported images = %q, want %q", images, test.want)
			}
		})
	}
}

func TestImport_OmitFallsBackToInstalledManifest(t *testing.T) {
	fixture := newImportFixture(t)
	// The artifact predates the omit option: its manifest does not declare the flag.
	artifact := writeArtifact(t, certManagerAddon(t, "ingress", "nginx", "apiVersion: v1\nmetadata:\n  name: ingress\nspec:\n  implementations:\n    - name: nginx\n"))
	manifestPath := filepath.Join(fixture.addonsDir(), "ingress", "addon.manifest.yaml")
	if err := os.MkdirAll(filepath.Dir(manifestPath), 0o755); err != nil {
		t.Fatal(err)
	}
	installed := omitManifest("ingress", "nginx", nil, "quay.io/jetstack/cert-manager-controller:v1.20.2")
	if err := os.WriteFile(manifestPath, []byte(installed), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Omit: []string{"omitCertMgr"}}); err != nil {
		t.Fatal(err)
	}

	if images := fixture.importedImages(t); !slices.Equal(images, []string{nginxArchive + "=nginx"}) {
		t.Fatalf("imported images = %q", images)
	}
}

func TestImport_OmitResolvesFromFilesAgainstImportedManifests(t *testing.T) {
	fixture := newImportFixture(t)
	certManagerManifests := tarGzOf(t, tarEntry{"./certmanager/deployment.yaml", "containers:\n  - name: controller\n    image: \"quay.io/jetstack/cert-manager-controller:v1.20.2\" # pinned\n"})
	addon := certManagerAddon(t, "ingress", "nginx", omitManifest("ingress", "nginx", []string{"manifests/certmanager/deployment.yaml"}))
	addon.layers = append(addon.layers, testLayer{mediaType: manifestsMediaType, content: certManagerManifests})

	if err := fixture.provider.Import(AddonImportConfig{ArtifactFile: writeArtifact(t, addon), Omit: []string{"omitCertMgr"}}); err != nil {
		t.Fatal(err)
	}

	if images := fixture.importedImages(t); !slices.Equal(images, []string{nginxArchive + "=nginx"}) {
		t.Fatalf("imported images = %q", images)
	}
}

// fakeWorker records what is done on an additional node instead of using SSH.
type fakeWorker struct {
	options  sshprovider.ConnectionOptions
	copied   []string
	commands []string
	fail     func(command string) bool
}

func (w *fakeWorker) CopyToNode(source, target string) error {
	content, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	w.copied = append(w.copied, target+"="+string(content))
	return nil
}

func (w *fakeWorker) Exec(command string) error {
	w.commands = append(w.commands, command)
	if w.fail != nil && w.fail(command) {
		return errors.New("exit status 1")
	}
	return nil
}

// useFakeWorkers replaces the SSH access and the readiness check; workers are keyed by IP address.
func useFakeWorkers(t *testing.T, ready bool, fail func(command string) bool) map[string]*fakeWorker {
	t.Helper()
	workers := map[string]*fakeWorker{}
	originalConnect, originalReady := connectWorker, isNodeReady
	t.Cleanup(func() { connectWorker, isNodeReady = originalConnect, originalReady })

	connectWorker = func(options sshprovider.ConnectionOptions) workerShell {
		if workers[options.IpAddress] == nil {
			workers[options.IpAddress] = &fakeWorker{fail: fail}
		}
		workers[options.IpAddress].options = options
		return workers[options.IpAddress]
	}
	isNodeReady = func(string) bool { return ready }
	return workers
}

func writeClusterDescriptor(t *testing.T, fixture *importFixture, nodesJSON string) {
	t.Helper()
	content := `{"nodes":[` + nodesJSON + `]}`
	if err := os.WriteFile(filepath.Join(fixture.provider.configDir, "cluster.json"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

const (
	linuxWorkerDescriptor   = `{"Name":"Worker-1","IpAddress":"172.19.1.50","Username":"worker","OS":"linux","Role":"worker","NodeType":"VM-EXISTING"}`
	windowsWorkerDescriptor = `{"Name":"winworker-1","IpAddress":"172.19.1.60","Username":"remote","OS":"windows","Role":"worker","NodeType":"VM-EXISTING"}`
)

func TestImport_RejectsNodesThatCannotReceiveImagesBeforeAnyChange(t *testing.T) {
	for name, test := range map[string]struct {
		nodes      string
		descriptor string
		notReady   bool
		wantError  string
		notSupp    bool
	}{
		"windows worker":            {nodes: "winworker-1", descriptor: windowsWorkerDescriptor, wantError: "Windows node", notSupp: true},
		"node missing in cluster":   {nodes: "ghost", descriptor: linuxWorkerDescriptor, wantError: "was not found in the cluster"},
		"no cluster descriptor":     {nodes: "worker-1", wantError: "was not found in the cluster"},
		"invalid node name":         {nodes: "-rf", descriptor: linuxWorkerDescriptor, wantError: "not a valid node name"},
		"worker without SSH user":   {nodes: "worker-1", descriptor: `{"Name":"worker-1","IpAddress":"172.19.1.50","OS":"linux"}`, wantError: "IpAddress or Username is missing"},
		"worker not ready":          {nodes: "worker-1", descriptor: linuxWorkerDescriptor, notReady: true, wantError: "is not in Ready state"},
		"one bad node among others": {nodes: "worker-1,winworker-1", descriptor: linuxWorkerDescriptor + "," + windowsWorkerDescriptor, wantError: "Windows node", notSupp: true},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newImportFixture(t)
			workers := useFakeWorkers(t, !test.notReady, nil)
			if test.descriptor != "" {
				writeClusterDescriptor(t, fixture, test.descriptor)
			}
			artifact := writeArtifact(t, certManagerAddon(t, "ingress", "nginx", ""))

			err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Nodes: test.nodes})

			if err == nil || !strings.Contains(err.Error(), test.wantError) || errors.Is(err, ErrNotSupported) != test.notSupp {
				t.Fatalf("expected error containing %q (not supported: %t), got: %v", test.wantError, test.notSupp, err)
			}
			if _, statErr := os.Stat(fixture.addonsDir()); statErr == nil {
				t.Fatal("the addons directory was changed although the nodes were rejected")
			}
			if len(workers) != 0 || len(fixture.importedImages(t)) != 0 {
				t.Fatal("images were imported although the nodes were rejected")
			}
		})
	}
}

func TestImport_ImportsOntoAdditionalLinuxWorkerOverSSH(t *testing.T) {
	fixture := newImportFixture(t)
	workers := useFakeWorkers(t, true, nil)
	writeClusterDescriptor(t, fixture, linuxWorkerDescriptor)
	artifact := writeArtifact(t, certManagerAddon(t, "ingress", "nginx", ""))

	err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Nodes: "WORKER-1", SshPrivateKeyPath: "/keys/id_rsa"})
	if err != nil {
		t.Fatal(err)
	}

	worker := workers["172.19.1.50"]
	if worker == nil {
		t.Fatal("the worker was not contacted")
	}
	wantOptions := sshprovider.ConnectionOptions{IpAddress: "172.19.1.50", Port: 22, RemoteUser: "worker", SshPrivateKeyPath: "/keys/id_rsa", Timeout: definitions.SSHDefaultTimeout}
	worker.options.StdOutWriter = nil
	if worker.options != wantOptions {
		t.Fatalf("SSH options = %+v, want %+v", worker.options, wantOptions)
	}
	if len(worker.copied) != 2 || len(worker.commands) != 4 {
		t.Fatalf("copied = %q, commands = %q", worker.copied, worker.commands)
	}
	for i, wantContent := range []string{"cert-manager", "nginx"} {
		remote, content, _ := strings.Cut(worker.copied[i], "=")
		if !strings.HasPrefix(remote, "/tmp/k2s-image-import-") || content != wantContent {
			t.Fatalf("copied[%d] = %q", i, worker.copied[i])
		}
		if got, want := worker.commands[i*2], "sudo buildah pull oci-archive:"+remote+" 2>&1"; got != want {
			t.Fatalf("commands[%d] = %q, want %q", i*2, got, want)
		}
		if got, want := worker.commands[i*2+1], "sudo rm -f "+remote; got != want {
			t.Fatalf("commands[%d] = %q, want %q", i*2+1, got, want)
		}
	}
	// Only the selected node receives the images, not the local host.
	if images := fixture.importedImages(t); len(images) != 0 {
		t.Fatalf("images were imported on the local host: %q", images)
	}
}

func TestImport_ImportsOntoLocalHostAndWorkerWhenBothAreSelected(t *testing.T) {
	fixture := newImportFixture(t)
	workers := useFakeWorkers(t, true, nil)
	writeClusterDescriptor(t, fixture, linuxWorkerDescriptor)
	artifact := writeArtifact(t, certManagerAddon(t, "ingress", "nginx", ""))

	err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Nodes: getNodeName() + ",worker-1,linux"})
	if err != nil {
		t.Fatal(err)
	}

	if images := fixture.importedImages(t); len(images) != 2 {
		t.Fatalf("local images = %q", images)
	}
	if worker := workers["172.19.1.50"]; worker == nil || len(worker.copied) != 2 {
		t.Fatalf("worker was not given both images: %+v", worker)
	}
}

func TestImport_WorkerFallsBackToDockerArchiveAndCleansUp(t *testing.T) {
	fixture := newImportFixture(t)
	workers := useFakeWorkers(t, true, func(command string) bool { return strings.Contains(command, "oci-archive:") })
	writeClusterDescriptor(t, fixture, linuxWorkerDescriptor)
	artifact := writeArtifact(t, testAddon{name: "metrics", implementation: "metrics", layers: []testLayer{
		{mediaType: linuxImagesMediaType, content: tarOf(t, tarEntry{"./one_v1.tar", "image-one"})}}})

	if err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Nodes: "worker-1"}); err != nil {
		t.Fatal(err)
	}

	commands := workers["172.19.1.50"].commands
	if len(commands) != 3 || !strings.Contains(commands[0], "oci-archive:") || !strings.Contains(commands[1], "docker-archive:") || !strings.HasPrefix(commands[2], "sudo rm -f /tmp/k2s-image-import-") {
		t.Fatalf("commands = %q", commands)
	}
}

func TestImport_ReportsWorkerImageFailuresAndStillRemovesTheArchive(t *testing.T) {
	fixture := newImportFixture(t)
	workers := useFakeWorkers(t, true, func(command string) bool { return strings.Contains(command, "buildah pull") })
	writeClusterDescriptor(t, fixture, linuxWorkerDescriptor)
	artifact := writeArtifact(t, testAddon{name: "metrics", implementation: "metrics", layers: []testLayer{
		{mediaType: linuxImagesMediaType, content: tarOf(t, tarEntry{"./one_v1.tar", "image-one"})}}})

	err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Nodes: "worker-1"})

	if err == nil || !strings.Contains(err.Error(), "one_v1.tar of 'metrics'") {
		t.Fatalf("expected an image import failure, got: %v", err)
	}
	commands := workers["172.19.1.50"].commands
	if last := commands[len(commands)-1]; !strings.HasPrefix(last, "sudo rm -f /tmp/k2s-image-import-") {
		t.Fatalf("the temporary archive was not removed: %q", commands)
	}
}

func TestImport_AcceptsTheLocalHostNode(t *testing.T) {
	for name, nodes := range map[string]string{
		"node name":           getNodeName(),
		"node name uppercase": strings.ToUpper(getNodeName()),
		"linux alias":         "linux",
		"duplicates":          "linux, ," + getNodeName(),
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newImportFixture(t)
			artifact := writeArtifact(t, certManagerAddon(t, "ingress", "nginx", ""))

			if err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Nodes: nodes}); err != nil {
				t.Fatal(err)
			}

			if images := fixture.importedImages(t); len(images) != 2 {
				t.Fatalf("imported images = %q", images)
			}
		})
	}
}

func TestParseOmitTokens(t *testing.T) {
	tokens := parseOmitTokens([]string{"omitCertMgr", " security : omitKeycloak ", "ingress/nginx:omitCertMgr", "  ", "security:"})

	want := []omitToken{
		{raw: "omitCertMgr", flag: "omitCertMgr"},
		{raw: "security : omitKeycloak", addon: "security", flag: "omitKeycloak"},
		{raw: "ingress/nginx:omitCertMgr", addon: "ingress", implementation: "nginx", flag: "omitCertMgr"},
	}
	if !slices.Equal(tokens, want) {
		t.Fatalf("tokens = %+v, want %+v", tokens, want)
	}
}

func TestImageNameHelpers(t *testing.T) {
	if got := imageArchiveName("quay.io/keycloak/keycloak:26.7.2"); got != "quay.io_keycloak_keycloak_26.7.2.tar" {
		t.Errorf("imageArchiveName = %q", got)
	}
	for image, want := range map[string]string{
		"quay.io/jetstack/cert-manager-controller:v1.21.1": "quay.io_jetstack_cert-manager-controller",
		"localhost:5000/repo/image:1.0":                    "localhost_5000_repo_image",
		"repo/image@sha256:abc":                            "repo_image",
		"image:1":                                          "image",
		"":                                                 "",
	} {
		if got := comparableImageKey(image); got != want {
			t.Errorf("comparableImageKey(%q) = %q, want %q", image, got, want)
		}
	}
	for archive, want := range map[string]string{
		"quay.io_jetstack_cert-manager-controller_v1.20.2.tar":         "quay.io_jetstack_cert-manager-controller",
		"windows_quay.io_jetstack_cert-manager-controller_v1.20.2.tar": "quay.io_jetstack_cert-manager-controller",
		"noversion.tar": "",
		"image.zip":     "",
	} {
		if got := archiveIdentityKey(archive); got != want {
			t.Errorf("archiveIdentityKey(%q) = %q, want %q", archive, got, want)
		}
	}
}

func TestImagesFromYAMLAndVersionlessImages(t *testing.T) {
	content := "containers:\n  - name: a\n    image: 'repo/a:1' # comment\n    image: repo/b\n    image: repo/b:2\n    args:\n      - --solver=quay.io/x/solver:v3\n"

	images := imagesFromYAML(content)

	if want := []string{"repo/a:1", "repo/b", "repo/b:2", "quay.io/x/solver:v3"}; !slices.Equal(images, want) {
		t.Fatalf("images = %q, want %q", images, want)
	}
	if got, want := removeVersionlessImages(images), []string{"repo/a:1", "repo/b:2", "quay.io/x/solver:v3"}; !slices.Equal(got, want) {
		t.Fatalf("images without versionless duplicates = %q, want %q", got, want)
	}
}

func TestSelectExportedAddons(t *testing.T) {
	exported := []exportedAddon{
		{name: "registry", implementation: "registry"},
		{name: "ingress", implementation: "nginx"},
		{name: "ingress", implementation: "traefik"},
		{name: "security", implementation: "security"},
	}

	for name, test := range map[string]struct {
		names []string
		want  []string
	}{
		"no names selects everything":        {nil, []string{"registry", "ingress/nginx", "ingress/traefik", "security"}},
		"base addon selects all its impls":   {[]string{"ingress"}, []string{"ingress/nginx", "ingress/traefik"}},
		"quoted implementation":              {[]string{"ingress traefik"}, []string{"ingress/traefik"}},
		"implementation as separate token":   {[]string{"ingress", "traefik", "registry"}, []string{"ingress/traefik", "registry"}},
		"flattened implementation":           {[]string{"ingress-nginx"}, []string{"ingress/nginx"}},
		"names are matched case-insensitive": {[]string{"Registry"}, []string{"registry"}},
		"duplicates are removed":             {[]string{"security", "ingress nginx", "security"}, []string{"ingress/nginx", "security"}},
	} {
		t.Run(name, func(t *testing.T) {
			selected, err := selectExportedAddons(exported, test.names)
			if err != nil {
				t.Fatal(err)
			}
			var keys []string
			for _, addon := range selected {
				keys = append(keys, addon.key())
			}
			if !slices.Equal(keys, test.want) {
				t.Fatalf("selected %q, want %q", keys, test.want)
			}
		})
	}

	if _, err := selectExportedAddons(exported, []string{"registry", "dashboard"}); err == nil || !strings.Contains(err.Error(), "addon 'dashboard' not found") {
		t.Fatalf("expected a not-found error for 'dashboard', got: %v", err)
	}
}

func TestResolveImportPath(t *testing.T) {
	for _, test := range []struct {
		name, implementation         string
		wantBase, wantImplementation string
		wantError                    bool
	}{
		{name: "dashboard", implementation: "dashboard", wantBase: "dashboard"},
		{name: "dashboard", wantBase: "dashboard"},
		{name: "ingress", implementation: "nginx-gw", wantBase: "ingress", wantImplementation: "nginx-gw"},
		{name: "storage ceph", implementation: "ceph", wantBase: "storage", wantImplementation: "ceph"},
		{name: "gpu node", wantError: true},
		{name: "ingress", implementation: "..", wantError: true},
		{name: "/etc", implementation: "cron.d", wantError: true},
	} {
		base, implementation, err := resolveImportPath(test.name, test.implementation)
		if (err != nil) != test.wantError || base != test.wantBase || implementation != test.wantImplementation {
			t.Errorf("resolveImportPath(%q, %q) = (%q, %q, %v), want (%q, %q, error=%t)",
				test.name, test.implementation, base, implementation, err, test.wantBase, test.wantImplementation, test.wantError)
		}
	}
}

func TestUpdateHostsContent_PreservesCoLocatedHostnames(t *testing.T) {
	initial := "127.0.0.1 localhost k2s.registry.local\n::1 localhost\n"
	updated := updateHostsContent(initial, "k2s.registry.local", "172.19.1.100")

	if !strings.Contains(updated, "127.0.0.1 localhost") {
		t.Fatalf("expected '127.0.0.1 localhost' to be preserved, got:\n%s", updated)
	}
	if !strings.Contains(updated, "172.19.1.100 k2s.registry.local") {
		t.Fatalf("expected '172.19.1.100 k2s.registry.local', got:\n%s", updated)
	}
	if strings.Contains(updated, "127.0.0.1 localhost k2s.registry.local") {
		t.Fatalf("did not expect old co-located entry to remain, got:\n%s", updated)
	}
}

func TestUpdateHostsContent_IdempotentWhenAlreadyPresent(t *testing.T) {
	initial := "127.0.0.1 localhost\n172.19.1.100 k2s.registry.local\n"
	updated := updateHostsContent(initial, "k2s.registry.local", "172.19.1.100")

	if updated != initial {
		t.Fatalf("expected content to be unchanged, got:\n%s", updated)
	}
}

func TestRemoveHostsContent_PreservesCoLocatedHostnames(t *testing.T) {
	initial := "127.0.0.1 localhost k2s.registry.local\n::1 localhost\n"
	updated := removeHostsContent(initial, "k2s.registry.local")

	if !strings.Contains(updated, "127.0.0.1 localhost") {
		t.Fatalf("expected '127.0.0.1 localhost' to be preserved, got:\n%s", updated)
	}
	if strings.Contains(updated, "k2s.registry.local") {
		t.Fatalf("expected 'k2s.registry.local' to be removed, got:\n%s", updated)
	}
}

func TestRemoveHostsContent_DropsLineWhenOnlyTargetHostname(t *testing.T) {
	initial := "127.0.0.1 localhost\n172.19.1.100 k2s.registry.local\n"
	updated := removeHostsContent(initial, "k2s.registry.local")

	if strings.Contains(updated, "172.19.1.100") || strings.Contains(updated, "k2s.registry.local") {
		t.Fatalf("expected standalone line to be dropped, got:\n%s", updated)
	}
	if !strings.Contains(updated, "127.0.0.1 localhost") {
		t.Fatalf("expected '127.0.0.1 localhost' to remain, got:\n%s", updated)
	}
}
