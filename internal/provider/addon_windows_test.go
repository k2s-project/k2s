// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package provider

import (
	"slices"
	"testing"
)

func TestBuildAddonImportParams(t *testing.T) {
	cfg := AddonImportConfig{ArtifactFile: `C:\tmp\it's.oci.tar`}

	params := buildAddonImportParams(cfg)
	want := []string{` -ArtifactFile 'C:\tmp\it''s.oci.tar'`}
	if !slices.Equal(params, want) {
		t.Fatalf("params = %q, want %q", params, want)
	}

	cfg.Names = []string{"registry", "ingress"}
	cfg.Nodes = "worker-1,worker-2"
	cfg.Omit = []string{"omitKeycloak", "ingress/nginx:omitCertMgr"}
	cfg.ShowOutput = true
	params = buildAddonImportParams(cfg)
	want = []string{
		" -Names 'registry','ingress'",
		` -ArtifactFile 'C:\tmp\it''s.oci.tar'`,
		" -ShowLogs",
		" -Nodes 'worker-1,worker-2'",
		" -Omit 'omitKeycloak','ingress/nginx:omitCertMgr'",
	}
	if !slices.Equal(params, want) {
		t.Fatalf("params = %q, want %q", params, want)
	}
}

func TestBuildAddonExportParams(t *testing.T) {
	cfg := AddonExportConfig{OutputDir: `C:\tmp\it's`}

	params := buildAddonExportParams(cfg)
	want := []string{` -ExportDir 'C:\tmp\it''s'`, " -All"}
	if !slices.Equal(params, want) {
		t.Fatalf("params = %q, want %q", params, want)
	}

	cfg.Names = []string{"registry", "ingress nginx"}
	cfg.ShowOutput, cfg.OmitImages, cfg.OmitPackages = true, true, true
	params = buildAddonExportParams(cfg)
	want = []string{` -ExportDir 'C:\tmp\it''s'`, " -Names 'registry','ingress nginx'", " -ShowLogs", " -OmitImages", " -OmitPackages"}
	if !slices.Equal(params, want) {
		t.Fatalf("params = %q, want %q", params, want)
	}
}
