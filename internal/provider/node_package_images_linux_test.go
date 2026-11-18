//go:build linux

// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package provider

import (
	"archive/zip"
	"context"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

func TestParseKubeadmImageList_KeepsOnlyImageReferences(t *testing.T) {
	output := "registry.k8s.io/kube-apiserver:v1.37.2\n" +
		"registry.k8s.io/pause:3.10.1\n" +
		"\n" +
		"  registry.k8s.io/coredns/coredns:v1.12.0  \n" +
		"W0101 00:00:00.000000 warning: something went wrong\n"

	got := parseKubeadmImageList(output)

	want := []string{
		"registry.k8s.io/kube-apiserver:v1.37.2",
		"registry.k8s.io/pause:3.10.1",
		"registry.k8s.io/coredns/coredns:v1.12.0",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parseKubeadmImageList() = %v, want %v", got, want)
	}
}

func TestNvidiaImagesFromManifest_ReturnsDistinctReferences(t *testing.T) {
	manifest := `
images:
  device-plugin: nvcr.io/nvidia/k8s-device-plugin:v0.18.0
  dcgm: nvcr.io/nvidia/k8s/dcgm-exporter:4.2.3-4.1.3-ubuntu22.04
  duplicate: nvcr.io/nvidia/k8s-device-plugin:v0.18.0
  unrelated: docker.io/library/busybox:1.36
`

	got := nvidiaImagesFromManifest(manifest)

	want := []string{
		"nvcr.io/nvidia/k8s-device-plugin:v0.18.0",
		"nvcr.io/nvidia/k8s/dcgm-exporter:4.2.3-4.1.3-ubuntu22.04",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("nvidiaImagesFromManifest() = %v, want %v", got, want)
	}
}

func TestImageArchiveName_MatchesWindowsPackageNaming(t *testing.T) {
	// Same escaping as New-K2sNodePackage.ps1: '/' -> '_', ':' -> '__'.
	got := imageArchiveName("registry.k8s.io/kube-apiserver:v1.37.2")

	if want := "registry.k8s.io_kube-apiserver__v1.37.2.tar"; got != want {
		t.Fatalf("imageArchiveName() = %q, want %q", got, want)
	}
}

func TestAppendUnique_KeepsOrderAndDropsDuplicates(t *testing.T) {
	got := appendUnique([]string{"a", "b"}, "b", "c", "a", "d")

	if want := []string{"a", "b", "c", "d"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("appendUnique() = %v, want %v", got, want)
	}
}

func TestProxyEnvironment_AddsSchemeAndSetsBothCases(t *testing.T) {
	if env := proxyEnvironment(""); env != nil {
		t.Fatalf("proxyEnvironment(\"\") = %v, want nil", env)
	}

	env := proxyEnvironment("10.0.0.1:3128")

	for _, key := range []string{"HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"} {
		if env[key] != "http://10.0.0.1:3128" {
			t.Fatalf("%s = %q, want %q", key, env[key], "http://10.0.0.1:3128")
		}
	}
}

func TestBuildZipSources_PlacesEachSourceUnderItsPrefix(t *testing.T) {
	packagesRoot := t.TempDir()
	imagesRoot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(packagesRoot, "debian13", "kubernetes"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packagesRoot, "debian13", "kubernetes", "kubeadm.deb"), []byte("deb"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(imagesRoot, "registry.k8s.io_pause__3.10.1.tar"), []byte("tar"), 0o644); err != nil {
		t.Fatal(err)
	}
	zipPath := filepath.Join(t.TempDir(), "node.zip")

	err := buildZipSources(context.Background(), zipPath,
		zipSource{prefix: "packages", root: packagesRoot},
		zipSource{prefix: "images", root: imagesRoot},
	)
	if err != nil {
		t.Fatalf("buildZipSources() error = %v", err)
	}

	reader, err := zip.OpenReader(zipPath)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	var names []string
	for _, f := range reader.File {
		names = append(names, f.Name)
	}
	sort.Strings(names)

	want := []string{
		"images/registry.k8s.io_pause__3.10.1.tar",
		"packages/debian13/kubernetes/kubeadm.deb",
	}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("zip entries = %v, want %v", names, want)
	}
}
