// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package zzaddonharness

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// exportFixture is an installation with the real Export-Addon.sh and stubs for everything outside of
// the host: buildah pulls succeed (unless K2S_TEST_PULL_FAIL is set) and report 'id-<image>',
// Export-Image.sh writes 'image <id>' as image archive, helm renders one manifest with an image, and
// apt-get, apt-config and curl simulate package downloads. Every stub records its calls.
type exportFixture struct {
	provider  *linuxAddonProvider
	output    *recordingWriter
	recordDir string
	outputDir string
}

const testK2sVersion = "2.1.0"

func newExportFixture(t *testing.T) *exportFixture {
	t.Helper()
	requireAddonScriptTools(t)

	installDir := t.TempDir()
	fixture := &exportFixture{
		provider:  &linuxAddonProvider{installDir: installDir, configDir: t.TempDir()},
		output:    &recordingWriter{},
		recordDir: t.TempDir(),
		outputDir: t.TempDir(),
	}
	fixture.provider.stdWriter = fixture.output

	installAddonScripts(t, installDir,
		"lib/scripts/linux/debian/host/addon/Export-Addon.sh",
		"lib/modules/linux/common/logging.sh",
		"lib/modules/linux/cluster/addon-oci.sh",
	)
	fixture.write(t, "VERSION", testK2sVersion+"\n")
	fixture.write(t, "cfg/config.json", `{"smallsetup":{"kubeSwitch":"172.19.1.1"}}`)
	fixture.write(t, "addons/common/manifests/addon-sync/gitops-sync/kustomization.yaml", "resources:\n  - sync-job.yaml\n")
	fixture.write(t, "addons/common/manifests/addon-sync/gitops-sync/sync-job.yaml", "name: sync-ADDON_NAME_PLACEHOLDER\nexported: EXPORT_TIMESTAMP_PLACEHOLDER\n")
	writeExecutable(t, filepath.Join(installDir, "lib/scripts/linux/debian/host/image/Export-Image.sh"), `#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in -i) id=$2; shift 2 ;; -t) archive=$2; shift 2 ;; *) shift ;; esac
done
printf '%s\n' "$id" >> "$K2S_TEST_RECORD_DIR/exported-images"
printf 'image %s' "$id" > "$archive"
`)

	stubs := t.TempDir()
	writeExecutable(t, filepath.Join(stubs, "buildah"), `#!/bin/sh
printf '%s\n' "$*" >> "$K2S_TEST_RECORD_DIR/buildah"
[ "$1" = pull ] || exit 0
eval "image=\${$#}"
if [ -n "$K2S_TEST_PULL_FAIL" ]; then echo "simulated pull failure for $image" >&2; exit 1; fi
echo "Getting image source signatures"
printf 'id-%s\n' "$(printf '%s' "$image" | tr '/:' '__')"
`)
	writeExecutable(t, filepath.Join(stubs, "helm"), `#!/bin/sh
printf '%s\n' "$*" >> "$K2S_TEST_RECORD_DIR/helm"
if [ -n "$K2S_TEST_HELM_FAIL" ]; then echo "Error: simulated render failure" >&2; exit 1; fi
release=$2
while [ $# -gt 0 ]; do
  case "$1" in --output-dir) out=$2; shift 2 ;; *) shift ;; esac
done
mkdir -p "$out/$release/templates"
printf 'spec:\n  containers:\n    - image: ghcr.io/example/chart-image:1.0\n' > "$out/$release/templates/deployment.yaml"
`)
	writeExecutable(t, filepath.Join(stubs, "apt-config"), `#!/bin/sh
printf "ARCHIVES='%s/'\n" "$K2S_TEST_RECORD_DIR/apt-archives"
`)
	writeExecutable(t, filepath.Join(stubs, "apt-get"), `#!/bin/sh
printf '%s\n' "$*" >> "$K2S_TEST_RECORD_DIR/apt-get"
case "$*" in
  *--download-only*) eval "package=\${$#}"
    if [ "$package" = "$K2S_TEST_APT_FAIL" ]; then echo "E: Unable to locate package $package" >&2; exit 100; fi
    if [ "$package" = "$K2S_TEST_APT_EMPTY" ]; then exit 0; fi
    mkdir -p "$K2S_TEST_RECORD_DIR/apt-archives"
    printf 'deb %s' "$package" > "$K2S_TEST_RECORD_DIR/apt-archives/${package}_1.0_amd64.deb" ;;
  clean) rm -f "$K2S_TEST_RECORD_DIR/apt-archives/"*.deb ;;
esac
`)
	writeExecutable(t, filepath.Join(stubs, "curl"), `#!/bin/sh
printf '%s\n' "$*" >> "$K2S_TEST_RECORD_DIR/curl"
while [ $# -gt 0 ]; do
  case "$1" in -Lo) destination=$2; url=$3; shift 3 ;; *) shift ;; esac
done
printf 'downloaded %s' "$url" > "$destination"
`)

	t.Setenv("PATH", stubs+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("HOME", t.TempDir())
	t.Setenv("K2S_LOG_FILE", filepath.Join(t.TempDir(), "k2s.log"))
	t.Setenv("K2S_TEST_RECORD_DIR", fixture.recordDir)
	t.Setenv("K2S_TEST_PULL_FAIL", "")
	t.Setenv("K2S_TEST_HELM_FAIL", "")
	t.Setenv("K2S_TEST_APT_FAIL", "")
	t.Setenv("K2S_TEST_APT_EMPTY", "")
	return fixture
}

func (f *exportFixture) write(t *testing.T, file, content string) {
	t.Helper()
	writeExecutable(t, filepath.Join(f.provider.installDir, file), content)
}

func (f *exportFixture) recorded(t *testing.T, name string) []string {
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

func (f *exportFixture) artifact(t *testing.T, names string) *exportedArtifact {
	t.Helper()
	return readExportedArtifact(t, filepath.Join(f.outputDir, "K2s-"+testK2sVersion+"-addons-"+names+".oci.tar"))
}

const dashboardManifest = `apiVersion: v1
kind: AddonManifest
metadata:
  name: dashboard
  description: Dashboard addon
spec:
  implementations:
    - name: dashboard
      version: 2.0.0
      offline_usage:
        linux:
          additionalImages:
            - docker.io/library/busybox:1.36
        windows:
          additionalImages:
            - mcr.microsoft.com/windows/nanoserver:ltsc2022
`

const ingressManifest = `apiVersion: v1
kind: AddonManifest
metadata:
  name: ingress
spec:
  implementations:
    - name: nginx
    - name: traefik
`

// withDashboard adds an addon with a single implementation that uses every kind of content.
func (f *exportFixture) withDashboard(t *testing.T) {
	t.Helper()
	f.write(t, "addons/dashboard/addon.manifest.yaml", dashboardManifest)
	f.write(t, "addons/dashboard/manifests/dashboard.yaml", `spec:
  containers:
    - image: docker.io/kubernetesui/dashboard:v2.7.0
    - image: mcr.microsoft.com/windows/servercore:ltsc2022 #windows_image
    # - image: docker.io/commented/out:1
    - image: noversion
`)
	f.write(t, "addons/dashboard/manifests/excluded.yaml", "## exclude-from-export\nimage: docker.io/excluded/image:1\n")
	f.write(t, "addons/dashboard/manifests/chart/headlamp-0.25.0.tgz", "chart")
	f.write(t, "addons/dashboard/manifests/chart/values.yaml", "replicas: 1\n")
	f.write(t, "addons/dashboard/values.yaml", "dashboard: values\n")
	f.write(t, "addons/dashboard/config/settings.conf", "setting=1\n")
	f.write(t, "addons/dashboard/Enable.ps1", "enable")
	f.write(t, "addons/dashboard/README.md", "readme")
	f.write(t, "addons/dashboard/docs/diagram.png", "png")
}

func (f *exportFixture) withIngress(t *testing.T) {
	t.Helper()
	f.write(t, "addons/ingress/addon.manifest.yaml", ingressManifest)
	f.write(t, "addons/ingress/nginx/manifests/nginx.yaml", "kind: Deployment\n")
	f.write(t, "addons/ingress/nginx/Enable.ps1", "enable nginx")
	f.write(t, "addons/ingress/traefik/manifests/traefik.yaml", "kind: Deployment\n")
}

func TestExport_WritesOciArtifactLikeExportPs1(t *testing.T) {
	fixture := newExportFixture(t)
	fixture.withDashboard(t)
	fixture.withIngress(t)

	if err := fixture.provider.Export(AddonExportConfig{OutputDir: fixture.outputDir}); err != nil {
		t.Fatal(err)
	}

	artifact := fixture.artifact(t, "all")
	if got := strings.TrimSpace(string(artifact.files["oci-layout"])); got != `{"imageLayoutVersion":"1.0.0"}` {
		t.Fatalf("oci-layout = %s", got)
	}
	index := artifact.index(t)
	if index.Annotations["vnd.k2s.export.type"] != "all" || index.Annotations["vnd.k2s.addon.count"] != "3" || index.Annotations["vnd.k2s.version"] != testK2sVersion {
		t.Fatalf("index annotations = %v", index.Annotations)
	}
	var titles []string
	for _, entry := range index.Manifests {
		titles = append(titles, entry.Annotations["org.opencontainers.image.title"])
		if entry.ArtifactType != "application/vnd.k2s.addon.v1" || entry.MediaType != "application/vnd.oci.image.manifest.v1+json" {
			t.Fatalf("index entry = %+v", entry)
		}
	}
	if want := []string{"dashboard", "ingress-nginx", "ingress-traefik"}; !slices.Equal(titles, want) {
		t.Fatalf("exported addons = %q, want %q", titles, want)
	}

	dashboard := artifact.manifest(t, "dashboard")
	if dashboard.Annotations["vnd.k2s.addon.name"] != "dashboard" || dashboard.Annotations["vnd.k2s.addon.implementation"] != "dashboard" ||
		dashboard.Annotations["org.opencontainers.image.version"] != "2.0.0" || dashboard.Annotations["org.opencontainers.image.description"] != "Dashboard addon" {
		t.Fatalf("dashboard annotations = %v", dashboard.Annotations)
	}
	var metadata map[string]string
	if err := json.Unmarshal(artifact.blob(t, dashboard.Config), &metadata); err != nil {
		t.Fatal(err)
	}
	if metadata["name"] != "dashboard" || metadata["version"] != "2.0.0" || metadata["k2sVersion"] != testK2sVersion || dashboard.Config.MediaType != "application/vnd.k2s.addon.config.v1+json" {
		t.Fatalf("metadata = %v (%s)", metadata, dashboard.Config.MediaType)
	}

	var mediaTypes []string
	for _, layer := range dashboard.Layers {
		mediaTypes = append(mediaTypes, layer.MediaType)
	}
	if want := []string{configMediaType, manifestsMediaType, chartsMediaType, scriptsMediaType, linuxImagesMediaType}; !slices.Equal(mediaTypes, want) {
		t.Fatalf("dashboard layers = %q, want %q", mediaTypes, want)
	}

	config := artifact.layerFiles(t, dashboard, configMediaType)
	if !strings.Contains(config["addon.manifest.yaml"], "name: dashboard") || config["values.yaml"] != "dashboard: values\n" || config["config/settings.conf"] != "setting=1\n" {
		t.Fatalf("config layer = %v", keysOf(config))
	}
	manifests := artifact.layerFiles(t, dashboard, manifestsMediaType)
	if !strings.Contains(manifests["dashboard.yaml"], "kubernetesui/dashboard") || manifests["chart/headlamp-0.25.0.tgz"] != "chart" ||
		manifests["gitops-sync/sync-job.yaml"] == "" || !strings.HasPrefix(manifests["gitops-sync/sync-job.yaml"], "name: sync-dashboard\nexported: 20") {
		t.Fatalf("manifests layer = %v\n%s", keysOf(manifests), manifests["gitops-sync/sync-job.yaml"])
	}
	if charts := artifact.layerFiles(t, dashboard, chartsMediaType); charts["headlamp-0.25.0.tgz"] != "chart" {
		t.Fatalf("charts layer = %v", keysOf(charts))
	}
	scripts := artifact.layerFiles(t, dashboard, scriptsMediaType)
	if scripts["Enable.ps1"] != "enable" || scripts["README.md"] != "readme" || scripts["docs/diagram.png"] != "png" {
		t.Fatalf("scripts layer = %v", keysOf(scripts))
	}

	images := artifact.layerFiles(t, dashboard, linuxImagesMediaType)
	wantImages := map[string]string{
		"docker.io_kubernetesui_dashboard_v2.7.0.tar": "image id-docker.io_kubernetesui_dashboard_v2.7.0",
		"ghcr.io_example_chart-image_1.0.tar":         "image id-ghcr.io_example_chart-image_1.0",
		"docker.io_library_busybox_1.36.tar":          "image id-docker.io_library_busybox_1.36",
	}
	if !mapsEqual(images, wantImages) {
		t.Fatalf("images layer = %v, want %v", images, wantImages)
	}
	for _, call := range fixture.recorded(t, "buildah") {
		if strings.Contains(call, "windows") || strings.Contains(call, "excluded") || strings.Contains(call, "commented") || strings.Contains(call, "noversion") {
			t.Fatalf("an image that must not be exported was pulled: %q", call)
		}
	}
	if helm := fixture.recorded(t, "helm"); len(helm) != 1 || !strings.HasPrefix(helm[0], "template headlamp ") || !strings.Contains(helm[0], "-f ") {
		t.Fatalf("helm calls = %q", helm)
	}
	if output := strings.Join(fixture.output.stdOut, "\n"); !strings.Contains(output, "Skipping 2 Windows image(s) of addon dashboard") {
		t.Fatalf("the skipped Windows images are not reported:\n%s", output)
	}

	nginx := artifact.manifest(t, "ingress-nginx")
	if files := artifact.layerFiles(t, nginx, scriptsMediaType); files["Enable.ps1"] != "enable nginx" {
		t.Fatalf("nginx scripts layer = %v", keysOf(files))
	}
	if config := artifact.layerFiles(t, nginx, configMediaType); !strings.Contains(config["addon.manifest.yaml"], "traefik") {
		t.Fatal("exporting all addons must keep every implementation in the addon manifest")
	}
	if _, err := os.Stat(filepath.Join(fixture.outputDir, "tmp-exported-addons")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the staging directory was not removed: %v", err)
	}
}

func TestExport_SelectsAddonsLikeExportPs1(t *testing.T) {
	for name, test := range map[string]struct {
		names        []string
		wantFile     string
		wantTitles   []string
		wantFiltered bool
	}{
		// Like Export.ps1, a single name reduces the manifest to the exported implementation, also for a base addon.
		"base addon exports every implementation": {names: []string{"ingress"}, wantFile: "ingress-nginx-ingress-traefik", wantTitles: []string{"ingress-nginx", "ingress-traefik"}, wantFiltered: true},
		"quoted implementation":                   {names: []string{"ingress nginx"}, wantFile: "ingress-nginx", wantTitles: []string{"ingress-nginx"}, wantFiltered: true},
		"implementation as next token":            {names: []string{"ingress", "traefik"}, wantFile: "ingress-traefik", wantTitles: []string{"ingress-traefik"}},
		"next token naming another addon":         {names: []string{"ingress", "dashboard"}, wantFile: "ingress-nginx-ingress-traefik-dashboard", wantTitles: []string{"ingress-nginx", "ingress-traefik", "dashboard"}},
		"names are matched case-insensitive":      {names: []string{"Dashboard"}, wantFile: "dashboard", wantTitles: []string{"dashboard"}},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newExportFixture(t)
			fixture.withDashboard(t)
			fixture.withIngress(t)

			if err := fixture.provider.Export(AddonExportConfig{OutputDir: fixture.outputDir, Names: test.names, OmitImages: true}); err != nil {
				t.Fatal(err)
			}

			artifact := fixture.artifact(t, test.wantFile)
			var titles []string
			for _, entry := range artifact.index(t).Manifests {
				titles = append(titles, entry.Annotations["org.opencontainers.image.title"])
			}
			if !slices.Equal(titles, test.wantTitles) {
				t.Fatalf("exported addons = %q, want %q", titles, test.wantTitles)
			}
			if artifact.index(t).Annotations["vnd.k2s.export.type"] != "specific" {
				t.Fatal("selected addons must be exported as type 'specific'")
			}
			if strings.HasPrefix(test.wantTitles[0], "ingress-") {
				config := artifact.layerFiles(t, artifact.manifest(t, test.wantTitles[0]), configMediaType)
				var parsed struct {
					Spec struct {
						Implementations []struct {
							Name string `yaml:"name"`
						} `yaml:"implementations"`
					} `yaml:"spec"`
				}
				if err := yaml.Unmarshal([]byte(config["addon.manifest.yaml"]), &parsed); err != nil {
					t.Fatal(err)
				}
				if filtered := len(parsed.Spec.Implementations) == 1; filtered != test.wantFiltered {
					t.Fatalf("manifest implementations = %+v, want filtered=%t", parsed.Spec.Implementations, test.wantFiltered)
				}
			}
		})
	}
}

func TestExport_RejectsUnknownAddon(t *testing.T) {
	for name, test := range map[string]struct {
		names     []string
		wantError string
	}{
		"unknown addon":                              {names: []string{"ghost", "dashboard"}, wantError: "no addon with name 'ghost' found"},
		"unknown implementation":                     {names: []string{"ingress", "nonexistent"}, wantError: "addon 'ingress' has no implementation 'nonexistent'"},
		"unknown quoted implementation among others": {names: []string{"dashboard", "ingress nonexistent"}, wantError: "addon 'ingress' has no implementation 'nonexistent'"},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newExportFixture(t)
			fixture.withDashboard(t)
			fixture.withIngress(t)

			err := fixture.provider.Export(AddonExportConfig{OutputDir: fixture.outputDir, Names: test.names, OmitImages: true})

			if err == nil || !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("expected an error containing %q, got: %v", test.wantError, err)
			}
			if entries, _ := os.ReadDir(fixture.outputDir); len(entries) != 0 {
				t.Fatalf("a rejected export must not write anything: %v", entries)
			}
		})
	}
}

func TestExport_FailsWhenAChartCannotBeRendered(t *testing.T) {
	fixture := newExportFixture(t)
	fixture.withDashboard(t)
	t.Setenv("K2S_TEST_HELM_FAIL", "true")

	err := fixture.provider.Export(AddonExportConfig{OutputDir: fixture.outputDir, Names: []string{"dashboard"}})

	if err == nil || !strings.Contains(err.Error(), "rendering chart headlamp-0.25.0.tgz of addon dashboard failed") || !strings.Contains(err.Error(), "simulated render failure") {
		t.Fatalf("expected a render failure, got: %v", err)
	}
	if calls := fixture.recorded(t, "buildah"); len(calls) != 0 {
		t.Fatalf("no image must be pulled after a render failure: %q", calls)
	}
}

func TestExport_FailsWhenADebianPackageIsNotDownloaded(t *testing.T) {
	for name, test := range map[string]struct {
		env, wantError string
	}{
		"download fails":     {env: "K2S_TEST_APT_FAIL", wantError: "downloading debian package apache2-utils failed: E: Unable to locate package apache2-utils"},
		"nothing downloaded": {env: "K2S_TEST_APT_EMPTY", wantError: "no debian packages were downloaded for apache2-utils"},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newExportFixture(t)
			fixture.write(t, "addons/registry/addon.manifest.yaml", "metadata:\n  name: registry\nspec:\n  implementations:\n    - name: registry\n      offline_usage:\n        linux:\n          deb:\n            - apache2-utils\n")
			t.Setenv(test.env, "apache2-utils")

			err := fixture.provider.Export(AddonExportConfig{OutputDir: fixture.outputDir, Names: []string{"registry"}, OmitImages: true})

			if err == nil || !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("expected an error containing %q, got: %v", test.wantError, err)
			}
			if _, err := os.Stat(filepath.Join(os.Getenv("HOME"), ".registry", "apache2-utils")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("an incomplete cache entry must not be kept: %v", err)
			}
			if entries, _ := os.ReadDir(fixture.outputDir); len(entries) != 0 {
				t.Fatalf("a failed export must not write anything: %v", entries)
			}
		})
	}
}

func TestExport_OmitsImagesAndPackages(t *testing.T) {
	fixture := newExportFixture(t)
	fixture.withDashboard(t)
	fixture.write(t, "addons/dashboard/addon.manifest.yaml", dashboardManifest+"          deb:\n            - tool\n")

	if err := fixture.provider.Export(AddonExportConfig{OutputDir: fixture.outputDir, Names: []string{"dashboard"}, OmitImages: true, OmitPackages: true}); err != nil {
		t.Fatal(err)
	}

	for _, layer := range fixture.artifact(t, "dashboard").manifest(t, "dashboard").Layers {
		if layer.MediaType == linuxImagesMediaType || layer.MediaType == packagesMediaType {
			t.Fatalf("omitted layer %s was exported", layer.MediaType)
		}
	}
	if calls := append(fixture.recorded(t, "buildah"), fixture.recorded(t, "apt-get")...); len(calls) != 0 {
		t.Fatalf("nothing must be pulled or downloaded: %q", calls)
	}
}

func TestExport_DownloadsPackagesLikeExportPs1(t *testing.T) {
	fixture := newExportFixture(t)
	fixture.write(t, "addons/registry/addon.manifest.yaml", `apiVersion: v1
kind: AddonManifest
metadata:
  name: registry
spec:
  implementations:
    - name: registry
      offline_usage:
        linux:
          repos:
            - echo "repo via __LOCAL_HTTP_PROXY__" >> "$K2S_TEST_RECORD_DIR/repos"
          deb:
            - apache2-utils
            - cached-tool
          curl:
            - url: https://example.com/linux/tool-linux-amd64?raw=true
              destination: bin/tool
        windows:
          curl:
            - url: https://example.com/windows/tool.exe
              destination: bin/tool.exe
`)
	cached := filepath.Join(os.Getenv("HOME"), ".registry", "cached-tool", "cached-tool_1.0_amd64.deb")
	writeExecutable(t, cached, "cached deb")

	if err := fixture.provider.Export(AddonExportConfig{OutputDir: fixture.outputDir, Names: []string{"registry"}, OmitImages: true}); err != nil {
		t.Fatal(err)
	}

	packages := fixture.artifact(t, "registry").layerFiles(t, fixture.artifact(t, "registry").manifest(t, "registry"), packagesMediaType)
	want := map[string]string{
		"debianpackages/apache2-utils/apache2-utils_1.0_amd64.deb": "deb apache2-utils",
		"debianpackages/cached-tool/cached-tool_1.0_amd64.deb":     "cached deb",
		"linuxpackages/tool-linux-amd64":                           "downloaded https://example.com/linux/tool-linux-amd64?raw=true",
	}
	if !mapsEqual(packages, want) {
		t.Fatalf("packages layer = %v, want %v; Windows packages must be skipped on a Linux host", packages, want)
	}
	if output := strings.Join(fixture.output.stdOut, "\n"); !strings.Contains(output, "Skipping 1 Windows package(s) of addon registry") {
		t.Fatalf("the skipped Windows package is not reported:\n%s", output)
	}
	if repos := fixture.recorded(t, "repos"); !slices.Equal(repos, []string{"repo via 172.19.1.1:8181"}) {
		t.Fatalf("repository commands = %q", repos)
	}
	if apt := fixture.recorded(t, "apt-get"); !slices.Contains(apt, "--download-only reinstall -y apache2-utils") || slices.Contains(apt, "--download-only reinstall -y cached-tool") {
		t.Fatalf("apt-get calls = %q; only packages that are not available offline must be downloaded", apt)
	}
	for _, call := range fixture.recorded(t, "curl") {
		if !strings.Contains(call, "--proxy http://172.19.1.1:8181") || strings.Contains(call, "windows") {
			t.Fatalf("downloads must use the K2s HTTP proxy and skip Windows packages: %q", call)
		}
	}

	// The exported packages end up where the addons expect them for an offline enable.
	importer := newImportFixture(t)
	if err := importer.provider.Import(AddonImportConfig{ArtifactFile: filepath.Join(fixture.outputDir, "K2s-"+testK2sVersion+"-addons-registry.oci.tar")}); err != nil {
		t.Fatal(err)
	}
	home := os.Getenv("HOME")
	assertFile(t, "deb apache2-utils", home, ".registry", "apache2-utils", "apache2-utils_1.0_amd64.deb")
	assertFile(t, "cached deb", home, ".registry", "cached-tool", "cached-tool_1.0_amd64.deb")
	assertFile(t, "downloaded https://example.com/linux/tool-linux-amd64?raw=true", home, ".registry", "bin", "tool")
}

func TestExport_StagesTheSharedStorageScripts(t *testing.T) {
	fixture := newExportFixture(t)
	fixture.write(t, "addons/storage/addon.manifest.yaml", "metadata:\n  name: storage\nspec:\n  implementations:\n    - name: smb\n    - name: ceph\n")
	fixture.write(t, "addons/storage/smb/Enable.ps1", "enable smb")
	fixture.write(t, "addons/storage/README.md", "storage readme")

	err := fixture.provider.Export(AddonExportConfig{OutputDir: fixture.outputDir, Names: []string{"storage"}, OmitImages: true})
	if err == nil || !strings.Contains(err.Error(), "shared module") {
		t.Fatalf("expected the missing shared module to fail the export, got: %v", err)
	}

	fixture.write(t, "addons/storage/storage-validation.module.psm1", "validation")
	if err := fixture.provider.Export(AddonExportConfig{OutputDir: fixture.outputDir, Names: []string{"storage"}, OmitImages: true}); err != nil {
		t.Fatal(err)
	}

	// 'storage' alone means its default implementation smb.
	artifact := fixture.artifact(t, "storage-smb")
	shared := artifact.layerFiles(t, artifact.manifest(t, "storage-smb"), "application/vnd.k2s.addon.shared-scripts.v1.tar+gzip")
	if !mapsEqual(shared, map[string]string{"storage-validation.module.psm1": "validation", "README.md": "storage readme"}) {
		t.Fatalf("shared scripts layer = %v", shared)
	}
}

func TestExport_ReportsPullFailures(t *testing.T) {
	fixture := newExportFixture(t)
	fixture.withDashboard(t)
	t.Setenv("K2S_TEST_PULL_FAIL", "true")

	err := fixture.provider.Export(AddonExportConfig{OutputDir: fixture.outputDir, Names: []string{"dashboard"}})

	if err == nil || !strings.Contains(err.Error(), "Pulling linux image") || !strings.Contains(err.Error(), "simulated pull failure") {
		t.Fatalf("expected a pull failure, got: %v", err)
	}
	if entries, _ := os.ReadDir(fixture.outputDir); len(entries) != 0 {
		t.Fatalf("a failed export must not leave files behind: %v", entries)
	}
}

func TestExport_ArtifactCanBeImported(t *testing.T) {
	exporter := newExportFixture(t)
	exporter.withDashboard(t)
	exporter.withIngress(t)
	if err := exporter.provider.Export(AddonExportConfig{OutputDir: exporter.outputDir}); err != nil {
		t.Fatal(err)
	}

	importer := newImportFixture(t)
	if err := importer.provider.Import(AddonImportConfig{ArtifactFile: filepath.Join(exporter.outputDir, "K2s-"+testK2sVersion+"-addons-all.oci.tar")}); err != nil {
		t.Fatal(err)
	}

	assertFile(t, "readme", importer.addonsDir(), "dashboard", "README.md")
	assertFile(t, "enable nginx", importer.addonsDir(), "ingress", "nginx", "Enable.ps1")
	assertFile(t, "kind: Deployment\n", importer.addonsDir(), "ingress", "traefik", "manifests", "traefik.yaml")
	assertFile(t, "dashboard: values\n", importer.addonsDir(), "dashboard", "values.yaml")
	images := importer.importedImages(t)
	slices.Sort(images)
	want := []string{
		"docker.io_kubernetesui_dashboard_v2.7.0.tar=image id-docker.io_kubernetesui_dashboard_v2.7.0",
		"docker.io_library_busybox_1.36.tar=image id-docker.io_library_busybox_1.36",
		"ghcr.io_example_chart-image_1.0.tar=image id-ghcr.io_example_chart-image_1.0",
	}
	if !slices.Equal(images, want) {
		t.Fatalf("imported images = %q, want %q", images, want)
	}
}


type ociTestDescriptor struct {
	MediaType    string            `json:"mediaType"`
	Digest       string            `json:"digest"`
	Size         int64             `json:"size"`
	ArtifactType string            `json:"artifactType"`
	Annotations  map[string]string `json:"annotations"`
}

type ociTestManifest struct {
	Config      ociTestDescriptor   `json:"config"`
	Layers      []ociTestDescriptor `json:"layers"`
	Annotations map[string]string   `json:"annotations"`
}

type ociTestIndex struct {
	Manifests   []ociTestDescriptor `json:"manifests"`
	Annotations map[string]string   `json:"annotations"`
}

// exportedArtifact holds the files of an exported OCI artifact by their path without './'.
type exportedArtifact struct {
	files map[string][]byte
}

func readExportedArtifact(t *testing.T, file string) *exportedArtifact {
	t.Helper()
	content, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	return &exportedArtifact{files: untar(t, bytes.NewReader(content))}
}

func untar(t *testing.T, content io.Reader) map[string][]byte {
	t.Helper()
	files := map[string][]byte{}
	reader := tar.NewReader(content)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			return files
		}
		if err != nil {
			t.Fatal(err)
		}
		if header.Typeflag != tar.TypeReg {
			continue
		}
		data, err := io.ReadAll(reader)
		if err != nil {
			t.Fatal(err)
		}
		files[path.Clean(strings.TrimPrefix(header.Name, "./"))] = data
	}
}

func (a *exportedArtifact) index(t *testing.T) ociTestIndex {
	t.Helper()
	var index ociTestIndex
	if err := json.Unmarshal(a.files["index.json"], &index); err != nil {
		t.Fatalf("index.json: %v", err)
	}
	return index
}

// blob returns the content of a descriptor after checking digest and size.
func (a *exportedArtifact) blob(t *testing.T, descriptor ociTestDescriptor) []byte {
	t.Helper()
	content, ok := a.files["blobs/sha256/"+strings.TrimPrefix(descriptor.Digest, "sha256:")]
	if !ok {
		t.Fatalf("blob %s is missing", descriptor.Digest)
	}
	if digest := fmt.Sprintf("sha256:%x", sha256.Sum256(content)); digest != descriptor.Digest || int64(len(content)) != descriptor.Size {
		t.Fatalf("blob %s has digest %s and size %d, descriptor size %d", descriptor.Digest, digest, len(content), descriptor.Size)
	}
	return content
}

func (a *exportedArtifact) manifest(t *testing.T, title string) ociTestManifest {
	t.Helper()
	for _, entry := range a.index(t).Manifests {
		if entry.Annotations["org.opencontainers.image.title"] == title {
			var manifest ociTestManifest
			if err := json.Unmarshal(a.blob(t, entry), &manifest); err != nil {
				t.Fatal(err)
			}
			return manifest
		}
	}
	t.Fatalf("no manifest for %s", title)
	return ociTestManifest{}
}

// layerFiles returns the files of the layer with the media type; gzipped layers are decompressed.
func (a *exportedArtifact) layerFiles(t *testing.T, manifest ociTestManifest, mediaType string) map[string]string {
	t.Helper()
	for _, layer := range manifest.Layers {
		if layer.MediaType != mediaType {
			continue
		}
		var content io.Reader = bytes.NewReader(a.blob(t, layer))
		if strings.HasSuffix(mediaType, "+gzip") {
			gzipped, err := gzip.NewReader(content)
			if err != nil {
				t.Fatal(err)
			}
			content = gzipped
		}
		files := map[string]string{}
		for name, data := range untar(t, content) {
			files[name] = string(data)
		}
		return files
	}
	t.Fatalf("no %s layer in %v", mediaType, manifest.Layers)
	return nil
}

func keysOf(files map[string]string) []string {
	var keys []string
	for key := range files {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	return keys
}

func mapsEqual(got, want map[string]string) bool {
	if len(got) != len(want) {
		return false
	}
	for key, value := range want {
		if got[key] != value {
			return false
		}
	}
	return true
}
