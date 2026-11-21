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
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

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
	name                string
	implementation      string
	layers              []testLayer
	manifestAnnotations map[string]string
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
		manifestAnnotations := addon.manifestAnnotations
		if manifestAnnotations == nil {
			manifestAnnotations = annotations
		}
		manifestJSON, err := json.Marshal(map[string]any{"schemaVersion": 2, "layers": layers, "annotations": manifestAnnotations})
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

const (
	addonNameAnnotation = "vnd.k2s.addon.name"
	addonImplAnnotation = "vnd.k2s.addon.implementation"
)

// importFixture is an installation with the real Import-Addon.sh and stubs for everything outside of
// the host: Import-Image.sh records the archives handed to it (an archive with the content 'broken'
// makes it fail), kubectl reports the nodes of K2S_TEST_READY_NODES ('*' for all) as Ready, and ssh/scp
// record what is done on an additional node; commands matching K2S_TEST_SSH_FAIL and every copy with
// K2S_TEST_SCP_FAIL set fail.
type importFixture struct {
	provider  *linuxAddonProvider
	output    *recordingWriter
	recordDir string
}

func newImportFixture(t *testing.T) *importFixture {
	t.Helper()
	requireAddonScriptTools(t)

	installDir := t.TempDir()
	fixture := &importFixture{
		provider:  &linuxAddonProvider{installDir: installDir, configDir: t.TempDir()},
		output:    &recordingWriter{},
		recordDir: t.TempDir(),
	}
	fixture.provider.stdWriter = fixture.output

	installAddonScripts(t, installDir,
		"lib/scripts/linux/debian/host/addon/Import-Addon.sh",
		"lib/modules/linux/common/logging.sh",
		"lib/modules/linux/infra/ssh.sh",
		"lib/modules/linux/cluster/addon-oci.sh",
	)
	writeExecutable(t, filepath.Join(installDir, "lib/scripts/linux/debian/host/image/Import-Image.sh"),
		"#!/bin/sh\ncontent=$(cat \"$2\")\nprintf '%s=%s\\n' \"$(basename \"$2\")\" \"$content\" >> \"$K2S_TEST_RECORD_DIR/imported-images\"\n[ \"$content\" != broken ]\n")

	stubs := t.TempDir()
	writeExecutable(t, filepath.Join(stubs, "kubectl"), `#!/bin/sh
printf '%s\n' "$3" >> "$K2S_TEST_RECORD_DIR/readiness-checks"
case ",$K2S_TEST_READY_NODES," in
  *",*,"* | *",$3,"*) printf True ;;
  *) printf False ;;
esac
`)
	writeExecutable(t, filepath.Join(stubs, "scp"), `#!/bin/sh
printf '%s\n' "$*" >> "$K2S_TEST_RECORD_DIR/scp-arguments"
eval "source=\${$(($# - 1))}"
eval "target=\${$#}"
printf '%s=%s\n' "${target#*:}" "$(cat "$source")" >> "$K2S_TEST_RECORD_DIR/copied"
if [ -n "$K2S_TEST_SCP_FAIL" ]; then echo 'simulated upload failure' >&2; exit 1; fi
`)
	writeExecutable(t, filepath.Join(stubs, "ssh"), `#!/bin/sh
printf '%s\n' "$*" >> "$K2S_TEST_RECORD_DIR/ssh-arguments"
eval "command=\${$#}"
printf '%s\n' "$command" >> "$K2S_TEST_RECORD_DIR/commands"
case "$command" in "tar -C "*) tar -tf - >> "$K2S_TEST_RECORD_DIR/received-files" ;; esac
if [ -n "$K2S_TEST_SSH_FAIL" ] && printf '%s' "$command" | grep -Eq "$K2S_TEST_SSH_FAIL"; then echo 'simulated failure' >&2; exit 1; fi
`)

	t.Setenv("PATH", stubs+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("HOME", t.TempDir())
	t.Setenv("K2S_LOG_FILE", filepath.Join(t.TempDir(), "k2s.log"))
	t.Setenv("K2S_TEST_RECORD_DIR", fixture.recordDir)
	t.Setenv("K2S_TEST_READY_NODES", "*")
	t.Setenv("K2S_TEST_SSH_FAIL", "")
	t.Setenv("K2S_TEST_SCP_FAIL", "")
	return fixture
}

// repositoryRoot is the checkout that contains the scripts under test.
const repositoryRoot = "../.."

// requireAddonScriptTools skips the test unless the tools of the addon scripts are available.
func requireAddonScriptTools(t *testing.T) {
	t.Helper()
	for _, tool := range []string{"bash", "tar", "sha256sum", "jq", "yq"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s is not available", tool)
		}
	}
	if version, err := exec.Command("yq", "--version").CombinedOutput(); err != nil || !strings.Contains(string(version), "mikefarah") {
		t.Skip("yq from https://github.com/mikefarah/yq is not available")
	}
}

// installAddonScripts copies scripts of the checkout into the installation under test.
func installAddonScripts(t *testing.T, installDir string, scripts ...string) {
	t.Helper()
	for _, script := range scripts {
		content, err := os.ReadFile(filepath.Join(repositoryRoot, script))
		if err != nil {
			t.Fatal(err)
		}
		writeExecutable(t, filepath.Join(installDir, script), string(content))
	}
}

func writeExecutable(t *testing.T, file, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
}

func (f *importFixture) addonsDir() string { return filepath.Join(f.provider.installDir, "addons") }

func (f *importFixture) importedImages(t *testing.T) []string {
	return f.recorded(t, "imported-images")
}

// recorded returns the lines a stub wrote to the record with the given name.
func (f *importFixture) recorded(t *testing.T, name string) []string {
	t.Helper()
	content, err := os.ReadFile(filepath.Join(f.recordDir, name))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(content)), "\n")
}

type recordingWriter struct {
	stdOut, stdErr []string
}

func (w *recordingWriter) WriteStdOut(message string) { w.stdOut = append(w.stdOut, message) }
func (w *recordingWriter) WriteStdErr(message string) { w.stdErr = append(w.stdErr, message) }
func (w *recordingWriter) Flush()                     {}

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

func TestImport_ResolvesIdentityAnnotationsIndependently(t *testing.T) {
	for name, test := range map[string]struct {
		annotations        map[string]string
		wantName           string
		wantImplementation string
	}{
		"index only": {
			annotations: map[string]string{}, wantName: "ingress", wantImplementation: "nginx",
		},
		"manifest name only": {
			annotations: map[string]string{addonNameAnnotation: "ingress"}, wantName: "ingress", wantImplementation: "nginx",
		},
		"manifest implementation only": {
			annotations: map[string]string{addonImplAnnotation: "traefik"}, wantName: "ingress", wantImplementation: "traefik",
		},
		"manifest overrides both": {
			annotations: map[string]string{addonNameAnnotation: "storage", addonImplAnnotation: "ceph"},
			wantName:    "storage", wantImplementation: "ceph",
		},
		"empty manifest values preserve index": {
			annotations: map[string]string{addonNameAnnotation: "", addonImplAnnotation: ""},
			wantName:    "ingress", wantImplementation: "nginx",
		},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newImportFixture(t)
			artifact := writeArtifact(t, testAddon{
				name: "ingress", implementation: "nginx", manifestAnnotations: test.annotations,
				layers: []testLayer{{mediaType: scriptsMediaType, content: tarGzOf(t, tarEntry{"./Enable.ps1", "enable"})}},
			})

			if err := fixture.provider.Import(AddonImportConfig{
				ArtifactFile: artifact, Names: []string{test.wantName, test.wantImplementation},
			}); err != nil {
				t.Fatal(err)
			}
			assertFile(t, "enable", fixture.addonsDir(), test.wantName, test.wantImplementation, "Enable.ps1")
			if _, err := os.Stat(filepath.Join(fixture.addonsDir(), test.wantName, "Enable.ps1")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("implementation script must not be staged at the addon root: %v", err)
			}
		})
	}
}

func TestImport_NormalizesLegacyIdentityBeforeSelectionAndOmission(t *testing.T) {
	for name, names := range map[string][]string{
		"all addons":      nil,
		"base addon":      {"storage"},
		"quoted":          {"storage ceph"},
		"separate tokens": {"storage", "ceph"},
		"flattened":       {"storage-ceph"},
	} {
		t.Run(name, func(t *testing.T) {
			for _, omit := range []string{"storage:omitCertMgr", "storage/ceph:omitCertMgr"} {
				t.Run(omit, func(t *testing.T) {
					fixture := newImportFixture(t)
					addon := certManagerAddon(t, "storage ceph", "ceph",
						omitManifest("storage", "ceph", nil, "quay.io/jetstack/cert-manager-controller:v1.20.2"))
					addon.layers = append(addon.layers, testLayer{
						mediaType: scriptsMediaType, content: tarGzOf(t, tarEntry{"./Enable.ps1", "enable"}),
					})
					artifact := writeArtifact(t, addon)

					if err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Names: names, Omit: []string{omit}}); err != nil {
						t.Fatal(err)
					}
					assertFile(t, "enable", fixture.addonsDir(), "storage", "ceph", "Enable.ps1")
					if images := fixture.importedImages(t); !slices.Equal(images, []string{nginxArchive + "=nginx"}) {
						t.Fatalf("imported images = %q; scoped omission must still match the normalized identity", images)
					}
				})
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

func TestImport_OmitAlsoWorksWhenLogsAreShown(t *testing.T) {
	fixture := newImportFixture(t)
	addon := certManagerAddon(t, "ingress", "nginx", omitManifest("ingress", "nginx", []string{"manifests/missing.yaml"}, "quay.io/jetstack/cert-manager-controller:v1.20.2"))

	err := fixture.provider.Import(AddonImportConfig{ArtifactFile: writeArtifact(t, addon), Omit: []string{"omitCertMgr"}, ShowOutput: true})
	if err != nil {
		t.Fatal(err)
	}

	if images := fixture.importedImages(t); !slices.Equal(images, []string{nginxArchive + "=nginx"}) {
		t.Fatalf("imported images = %q", images)
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
		"worker user as an option":  {nodes: "worker-1", descriptor: `{"Name":"worker-1","IpAddress":"172.19.1.50","Username":"-oProxyCommand=x","OS":"linux"}`, wantError: "invalid IpAddress or Username"},
		"worker not ready":          {nodes: "worker-1", descriptor: linuxWorkerDescriptor, notReady: true, wantError: "is not in Ready state"},
		"local alias not ready":     {nodes: "linux", notReady: true, wantError: "is not in Ready state"},
		"local hostname not ready":  {nodes: getNodeName(), notReady: true, wantError: "is not in Ready state"},
		"one bad node among others": {nodes: "worker-1,winworker-1", descriptor: linuxWorkerDescriptor + "," + windowsWorkerDescriptor, wantError: "Windows node", notSupp: true},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newImportFixture(t)
			if test.notReady {
				t.Setenv("K2S_TEST_READY_NODES", "")
			}
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
			if len(fixture.recorded(t, "commands")) != 0 || len(fixture.recorded(t, "copied")) != 0 || len(fixture.importedImages(t)) != 0 {
				t.Fatal("images were imported although the nodes were rejected")
			}
		})
	}
}

func TestImport_ImportsOntoAdditionalLinuxWorkerOverSSH(t *testing.T) {
	fixture := newImportFixture(t)
	writeClusterDescriptor(t, fixture, linuxWorkerDescriptor)
	artifact := writeArtifact(t, certManagerAddon(t, "ingress", "nginx", ""))

	err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Nodes: "WORKER-1", SshPrivateKeyPath: "/keys/id_rsa"})
	if err != nil {
		t.Fatal(err)
	}

	for record, want := range map[string]string{"ssh-arguments": "-p 22 worker@172.19.1.50 ", "scp-arguments": "-P 22 "} {
		for _, arguments := range fixture.recorded(t, record) {
			if !strings.HasPrefix(arguments, "-i /keys/id_rsa ") || !strings.Contains(arguments, want) {
				t.Fatalf("%s = %q, want the K2s key and %q", record, arguments, want)
			}
		}
	}
	copied, commands := fixture.recorded(t, "copied"), fixture.recorded(t, "commands")
	if len(copied) != 2 || len(commands) != 4 {
		t.Fatalf("copied = %q, commands = %q", copied, commands)
	}
	for i, wantContent := range []string{"cert-manager", "nginx"} {
		remote, content, _ := strings.Cut(copied[i], "=")
		if !strings.HasPrefix(remote, "/var/tmp/k2s-image-import-") || content != wantContent {
			t.Fatalf("copied[%d] = %q", i, copied[i])
		}
		if got, want := commands[i*2], "sudo buildah pull oci-archive:"+remote+" 2>&1"; got != want {
			t.Fatalf("commands[%d] = %q, want %q", i*2, got, want)
		}
		if got, want := commands[i*2+1], "sudo rm -f "+remote; got != want {
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
	writeClusterDescriptor(t, fixture, linuxWorkerDescriptor)
	artifact := writeArtifact(t, certManagerAddon(t, "ingress", "nginx", ""))

	err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Nodes: getNodeName() + ",worker-1,linux", SshPrivateKeyPath: "/keys/id_rsa"})
	if err != nil {
		t.Fatal(err)
	}

	if images := fixture.importedImages(t); len(images) != 2 {
		t.Fatalf("local images = %q", images)
	}
	if copied := fixture.recorded(t, "copied"); len(copied) != 2 {
		t.Fatalf("worker was not given both images: %q", copied)
	}
}

func TestImport_WorkerFallsBackToDockerArchiveAndCleansUp(t *testing.T) {
	fixture := newImportFixture(t)
	t.Setenv("K2S_TEST_SSH_FAIL", "oci-archive:")
	writeClusterDescriptor(t, fixture, linuxWorkerDescriptor)
	artifact := writeArtifact(t, testAddon{name: "metrics", implementation: "metrics", layers: []testLayer{
		{mediaType: linuxImagesMediaType, content: tarOf(t, tarEntry{"./one_v1.tar", "image-one"})}}})

	if err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Nodes: "worker-1", SshPrivateKeyPath: "/keys/id_rsa"}); err != nil {
		t.Fatal(err)
	}

	commands := fixture.recorded(t, "commands")
	if len(commands) != 3 || !strings.Contains(commands[0], "oci-archive:") || !strings.Contains(commands[1], "docker-archive:") || !strings.HasPrefix(commands[2], "sudo rm -f /var/tmp/k2s-image-import-") {
		t.Fatalf("commands = %q", commands)
	}
}

func TestImport_ReportsWorkerImageFailuresAndStillRemovesTheArchive(t *testing.T) {
	fixture := newImportFixture(t)
	t.Setenv("K2S_TEST_SSH_FAIL", "buildah pull")
	writeClusterDescriptor(t, fixture, linuxWorkerDescriptor)
	artifact := writeArtifact(t, testAddon{name: "metrics", implementation: "metrics", layers: []testLayer{
		{mediaType: linuxImagesMediaType, content: tarOf(t, tarEntry{"./one_v1.tar", "image-one"})}}})

	err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Nodes: "worker-1", SshPrivateKeyPath: "/keys/id_rsa"})

	if err == nil || !strings.Contains(err.Error(), "one_v1.tar of 'metrics'") {
		t.Fatalf("expected an image import failure, got: %v", err)
	}
	commands := fixture.recorded(t, "commands")
	if last := commands[len(commands)-1]; !strings.HasPrefix(last, "sudo rm -f /var/tmp/k2s-image-import-") {
		t.Fatalf("the temporary archive was not removed: %q", commands)
	}
}

func TestImport_RemovesPartialUploadFromWorker(t *testing.T) {
	for _, cleanupFails := range []bool{false, true} {
		t.Run(fmt.Sprintf("cleanup failure=%t", cleanupFails), func(t *testing.T) {
			fixture := newImportFixture(t)
			t.Setenv("K2S_TEST_SCP_FAIL", "true")
			if cleanupFails {
				t.Setenv("K2S_TEST_SSH_FAIL", "^sudo rm -f ")
			}
			writeClusterDescriptor(t, fixture, linuxWorkerDescriptor)
			artifact := writeArtifact(t, testAddon{name: "metrics", implementation: "metrics", layers: []testLayer{
				{mediaType: linuxImagesMediaType, content: tarOf(t, tarEntry{"./one_v1.tar", "partial image"})}}})

			err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Nodes: "worker-1", SshPrivateKeyPath: "/keys/id_rsa"})

			if err == nil || !strings.Contains(err.Error(), "one_v1.tar of 'metrics'") {
				t.Fatalf("expected an image import failure, got: %v", err)
			}
			output := strings.Join(fixture.output.stdOut, "\n")
			if !strings.Contains(output, "copying the image archive failed: simulated upload failure") {
				t.Fatalf("the upload error must be reported, got output:\n%s", output)
			}
			if strings.Contains(output, "removing the temporary image archive") != cleanupFails {
				t.Fatalf("cleanup failure reported incorrectly, got output:\n%s", output)
			}
			copied, commands := fixture.recorded(t, "copied"), fixture.recorded(t, "commands")
			if len(copied) != 1 || len(commands) != 1 {
				t.Fatalf("a failed copy must run only cleanup: copied=%q, commands=%q", copied, commands)
			}
			remote, _, _ := strings.Cut(copied[0], "=")
			if !strings.HasPrefix(remote, "/var/tmp/k2s-image-import-") || commands[0] != "sudo rm -f "+remote {
				t.Fatalf("the partial upload must be removed from disk-backed staging: %q", commands)
			}
		})
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
			t.Setenv("K2S_TEST_READY_NODES", getNodeName())
			artifact := writeArtifact(t, certManagerAddon(t, "ingress", "nginx", ""))

			if err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact, Nodes: nodes}); err != nil {
				t.Fatal(err)
			}

			if images := fixture.importedImages(t); len(images) != 2 {
				t.Fatalf("imported images = %q", images)
			}
			checks := fixture.recorded(t, "readiness-checks")
			if len(checks) == 0 || slices.Contains(checks, "linux") && getNodeName() != "linux" {
				t.Fatalf("readiness must be checked using the actual local node name, got %q", checks)
			}
		})
	}
}

// packagesAddon carries the offline packages of a registry addon: a debian package, linux packages with
// a relative, an absolute and an escaping destination, and a Windows package.
func packagesAddon(t *testing.T, systemDestination string) testAddon {
	manifest := fmt.Sprintf(`apiVersion: v1
kind: AddonManifest
metadata:
  name: registry
spec:
  implementations:
    - name: registry
      offline_usage:
        linux:
          deb:
            - apache2-utils
          curl:
            - url: https://example.com/tool-linux-amd64?raw=true
              destination: bin/tool
            - url: https://example.com/system-tool
              destination: %s
            - url: https://example.com/evil
              destination: ../../evil
        windows:
          curl:
            - url: https://example.com/tool.exe
              destination: bin/tool.exe
`, systemDestination)
	return testAddon{name: "registry", implementation: "registry", layers: []testLayer{
		{mediaType: configMediaType, content: tarGzOf(t, tarEntry{"./addon.manifest.yaml", manifest})},
		manifestsLayerOf(t, "registry.yaml"),
		{mediaType: packagesMediaType, content: tarGzOf(t,
			tarEntry{"./debianpackages/apache2-utils/apache2-utils_1.0_amd64.deb", "deb"},
			tarEntry{"./linuxpackages/tool-linux-amd64", "tool"},
			tarEntry{"./linuxpackages/system-tool", "system tool"},
			tarEntry{"./linuxpackages/evil", "evil"},
			tarEntry{"./windowspackages/tool.exe", "windows tool"})},
	}}
}

func TestImport_InstallsPackagesLikeImportPs1(t *testing.T) {
	fixture := newImportFixture(t)
	home := os.Getenv("HOME")
	writeExecutable(t, filepath.Join(home, ".registry", "stale", "stale.deb"), "stale")
	systemDestination := filepath.Join(t.TempDir(), "system-tool")

	if err := fixture.provider.Import(AddonImportConfig{ArtifactFile: writeArtifact(t, packagesAddon(t, systemDestination))}); err != nil {
		t.Fatal(err)
	}

	assertFile(t, "deb", home, ".registry", "apache2-utils", "apache2-utils_1.0_amd64.deb")
	assertFile(t, "tool", home, ".registry", "bin", "tool")
	assertFile(t, "system tool", systemDestination)
	if _, err := os.Stat(filepath.Join(home, ".registry", "stale")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the debian packages must replace ~/.registry: %v", err)
	}
	if _, err := os.Stat(filepath.Clean(filepath.Join(home, ".registry", "..", "..", "evil"))); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a package must not be written outside of ~/.registry: %v", err)
	}
	if _, err := os.Stat(filepath.Join(home, ".registry", "bin", "tool.exe")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Windows packages must not be installed on a Linux host: %v", err)
	}
	output := strings.Join(fixture.output.stdOut, "\n")
	for _, want := range []string{"Installing packages for addon registry", "destination '../../evil'", "Skipping 1 Windows package(s) of addon registry"} {
		if !strings.Contains(output, want) {
			t.Fatalf("output does not contain %q:\n%s", want, output)
		}
	}
}

func TestImport_InstallsPackagesOnTheLastSelectedWorker(t *testing.T) {
	fixture := newImportFixture(t)
	writeClusterDescriptor(t, fixture, linuxWorkerDescriptor)
	systemDestination := filepath.Join(t.TempDir(), "system-tool")

	err := fixture.provider.Import(AddonImportConfig{ArtifactFile: writeArtifact(t, packagesAddon(t, systemDestination)),
		Nodes: getNodeName() + ",worker-1", SshPrivateKeyPath: "/keys/id_rsa"})
	if err != nil {
		t.Fatal(err)
	}

	commands := fixture.recorded(t, "commands")
	for _, want := range []string{"sudo rm -rf .registry && mkdir -p .registry", "tar -C .registry -xf -", "mkdir -p .registry/bin"} {
		if !slices.Contains(commands, want) {
			t.Fatalf("commands = %q, missing %q", commands, want)
		}
	}
	if received := fixture.recorded(t, "received-files"); !slices.Contains(received, "./apache2-utils/apache2-utils_1.0_amd64.deb") {
		t.Fatalf("debian packages received by the worker = %q", received)
	}
	if copied := fixture.recorded(t, "copied"); !slices.Equal(copied, []string{".registry/bin/tool=tool"}) {
		t.Fatalf("copied = %q", copied)
	}
	// Like Import.ps1, an absolute destination is installed on the control plane.
	assertFile(t, "system tool", systemDestination)
	if _, err := os.Stat(filepath.Join(os.Getenv("HOME"), ".registry")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the packages of a worker must not be put on this host: %v", err)
	}
}

func TestImport_KeepsPackagesOfAllImplementationsInTheSharedAddonDirectory(t *testing.T) {
	fixture := newImportFixture(t)
	writeExecutable(t, filepath.Join(os.Getenv("HOME"), ".storage", "stale", "stale.deb"), "stale")
	manifest := `metadata:
  name: storage
spec:
  implementations:
    - name: smb
      offline_usage:
        linux:
          deb:
            - cifs-utils
    - name: ceph
      offline_usage:
        linux:
          deb:
            - lvm2
          curl:
            - url: https://example.com/cephadm
              destination: cephadm
`
	storageAddon := func(implementation, deb string, extra ...tarEntry) testAddon {
		packages := append([]tarEntry{{"./debianpackages/" + deb + "/" + deb + "_1.0_amd64.deb", deb}}, extra...)
		return testAddon{name: "storage", implementation: implementation, layers: []testLayer{
			{mediaType: configMediaType, content: tarGzOf(t, tarEntry{"./addon.manifest.yaml", manifest})},
			{mediaType: packagesMediaType, content: tarGzOf(t, packages...)},
		}}
	}
	artifact := writeArtifact(t,
		storageAddon("smb", "cifs-utils"),
		storageAddon("ceph", "lvm2", tarEntry{"./linuxpackages/cephadm", "cephadm"}))

	if err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact}); err != nil {
		t.Fatal(err)
	}

	home := os.Getenv("HOME")
	assertFile(t, "cifs-utils", home, ".storage", "cifs-utils", "cifs-utils_1.0_amd64.deb")
	assertFile(t, "lvm2", home, ".storage", "lvm2", "lvm2_1.0_amd64.deb")
	assertFile(t, "cephadm", home, ".storage", "cephadm")
	if _, err := os.Stat(filepath.Join(home, ".storage", "stale")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("~/.storage must still be replaced once per import: %v", err)
	}
}

func TestImport_ReportsImageArchivesThatCannotBeExtracted(t *testing.T) {
	fixture := newImportFixture(t)
	layer := tarOf(t, tarEntry{"./one_v1.tar", "image-one"}, tarEntry{"./two_v2.tar", strings.Repeat("x", 1000)})
	// Cut into the data of the second archive: its header is intact, its content is not.
	truncated := layer[:3*512+100]
	artifact := writeArtifact(t, testAddon{name: "metrics", implementation: "metrics", layers: []testLayer{
		{mediaType: linuxImagesMediaType, content: truncated}}})

	err := fixture.provider.Import(AddonImportConfig{ArtifactFile: artifact})

	if err == nil || !strings.Contains(err.Error(), "two_v2.tar of 'metrics' (extraction failed)") {
		t.Fatalf("expected the failed extraction to be reported, got: %v", err)
	}
	if images := fixture.importedImages(t); !slices.Equal(images, []string{"one_v1.tar=image-one"}) {
		t.Fatalf("imported images = %q", images)
	}
}

func TestImport_ReportsMissingScript(t *testing.T) {
	p := &linuxAddonProvider{installDir: t.TempDir(), configDir: t.TempDir()}

	err := p.Import(AddonImportConfig{ArtifactFile: filepath.Join(t.TempDir(), "addons.oci.tar")})

	if err == nil || errors.Is(err, ErrNotSupported) {
		t.Fatalf("expected the failure of the missing script, got: %v", err)
	}
}

// runImportFunction sources Import-Addon.sh of the checkout and runs the bash snippet with the arguments.
func runImportFunction(t *testing.T, snippet string, args ...string) (string, error) {
	t.Helper()
	for _, tool := range []string{"bash", "jq"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s is not available", tool)
		}
	}
	script := filepath.Join(repositoryRoot, "lib/scripts/linux/debian/host/addon/Import-Addon.sh")
	cmd := exec.Command("bash", append([]string{"-c", "source \"$0\"\n" + snippet, script}, args...)...)
	cmd.Env = append(os.Environ(), "K2S_INSTALL_DIR="+repositoryRoot, "K2S_LOG_FILE="+filepath.Join(t.TempDir(), "k2s.log"))
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	if err != nil {
		err = fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return strings.TrimSpace(stdout.String()), err
}

func TestImportScript_ParsesOmitTokens(t *testing.T) {
	got, err := runImportFunction(t, `addon_import_jq '$ARGS.positional | parse_tokens | map([.raw, .addon, .implementation, .flag] | join("|"))[]' -nr --args "$@"`,
		"omitCertMgr", " security : omitKeycloak ", "ingress/nginx:omitCertMgr", "  ", "security:")
	if err != nil {
		t.Fatal(err)
	}

	want := "omitCertMgr|||omitCertMgr\nsecurity : omitKeycloak|security||omitKeycloak\ningress/nginx:omitCertMgr|ingress|nginx|omitCertMgr"
	if got != want {
		t.Fatalf("tokens =\n%s\nwant\n%s", got, want)
	}
}

func TestImportScript_ImageNameHelpers(t *testing.T) {
	for function, cases := range map[string]map[string]string{
		"archive_name": {
			"quay.io/keycloak/keycloak:26.7.2":       "quay.io_keycloak_keycloak_26.7.2.tar",
			"registry.k8s.io/kube-apiserver:v1.37.2": "registry.k8s.io_kube-apiserver_v1.37.2.tar",
		},
		"comparable_key": {
			"quay.io/jetstack/cert-manager-controller:v1.21.1": "quay.io_jetstack_cert-manager-controller",
			"localhost:5000/repo/image:1.0":                    "localhost_5000_repo_image",
			"repo/image@sha256:abc":                            "repo_image",
			"image:1":                                          "image",
			"":                                                 "",
		},
		"identity_key": {
			"quay.io_jetstack_cert-manager-controller_v1.20.2.tar":         "quay.io_jetstack_cert-manager-controller",
			"windows_quay.io_jetstack_cert-manager-controller_v1.20.2.tar": "quay.io_jetstack_cert-manager-controller",
			"noversion.tar": "",
			"image.zip":     "",
		},
	} {
		for input, want := range cases {
			got, err := runImportFunction(t, `addon_import_jq "\$value | $1" -nr --arg value "$2"`, function, input)
			if err != nil || got != want {
				t.Errorf("%s(%q) = %q, %v; want %q", function, input, got, err, want)
			}
		}
	}
}

func TestImportScript_ImagesFromYAMLAndVersionlessImages(t *testing.T) {
	content := "containers:\n  - name: a\n    image: 'repo/a:1' # comment\n    image: repo/b\n    image: repo/b:2\n    args:\n      - --solver=quay.io/x/solver:v3\n"

	images, err := runImportFunction(t, `addon_import_jq 'images_from_yaml | join(",")' -rRs <<<"$1"`, content)
	if err != nil || images != "repo/a:1,repo/b,repo/b:2,quay.io/x/solver:v3" {
		t.Fatalf("images = %q, %v", images, err)
	}
	cleaned, err := runImportFunction(t, `addon_import_jq '$ARGS.positional | clean_images | join(",")' -nr --args "$@"`,
		"repo/a:1", "repo/b", ` "repo/b:2" `, "quay.io/x/solver:v3", "repo/a:1", "")
	if err != nil || cleaned != "repo/a:1,repo/b:2,quay.io/x/solver:v3" {
		t.Fatalf("images without versionless duplicates = %q, %v", cleaned, err)
	}
}

func TestImportScript_SelectsExportedAddons(t *testing.T) {
	selectAddons := `exported_names=(registry ingress ingress security)
exported_implementations=(registry nginx traefik security)
addon_import_select "$@"
for i in "${selected_indices[@]}"; do addon_import_key "${exported_names[i]}" "${exported_implementations[i]}"; done | paste -sd, -`

	for name, test := range map[string]struct {
		names []string
		want  string
	}{
		"no names selects everything":        {nil, "registry,ingress/nginx,ingress/traefik,security"},
		"base addon selects all its impls":   {[]string{"ingress"}, "ingress/nginx,ingress/traefik"},
		"quoted implementation":              {[]string{"ingress traefik"}, "ingress/traefik"},
		"implementation as separate token":   {[]string{"ingress", "traefik", "registry"}, "ingress/traefik,registry"},
		"flattened implementation":           {[]string{"ingress-nginx"}, "ingress/nginx"},
		"names are matched case-insensitive": {[]string{"Registry"}, "registry"},
		"duplicates are removed":             {[]string{"security", "ingress nginx", "security"}, "ingress/nginx,security"},
	} {
		t.Run(name, func(t *testing.T) {
			selected, err := runImportFunction(t, selectAddons, test.names...)
			if err != nil || selected != test.want {
				t.Fatalf("selected %q, %v; want %q", selected, err, test.want)
			}
		})
	}

	if _, err := runImportFunction(t, selectAddons, "registry", "dashboard"); err == nil || !strings.Contains(err.Error(), "addon 'dashboard' not found") {
		t.Fatalf("expected a not-found error for 'dashboard', got: %v", err)
	}
}

func TestImportScript_ResolvesImportPath(t *testing.T) {
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
		resolved, err := runImportFunction(t, `addon_import_resolve_path "$1" "$2" | tr '\t' '|'`, test.name, test.implementation)
		base, implementation, _ := strings.Cut(resolved, "|")
		if (err != nil) != test.wantError || (err == nil && (base != test.wantBase || implementation != test.wantImplementation)) {
			t.Errorf("resolve(%q, %q) = (%q, %q, %v), want (%q, %q, error=%t)",
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
