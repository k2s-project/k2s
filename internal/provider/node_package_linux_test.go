//go:build linux

// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package provider

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Guards the regex-based extraction against refactors of Get-DefaultK8sVersion.
func TestResolveDefaultK8sVersion_ReadsRepositoryConfigModule(t *testing.T) {
	installDir, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}

	version, err := resolveDefaultK8sVersion(installDir)
	if err != nil {
		t.Fatalf("could not resolve default K8s version: %v", err)
	}
	if len(version) < 2 || version[0] != 'v' {
		t.Fatalf("unexpected version '%s'", version)
	}
}

func TestLockAPTConfigurationSerializesBuilds(t *testing.T) {
	lockPath := filepath.Join(t.TempDir(), "apt.lock")
	first, err := lockAPTConfiguration(lockPath)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()

	acquired := make(chan *os.File, 1)
	errs := make(chan error, 1)
	go func() {
		lock, err := lockAPTConfiguration(lockPath)
		if err != nil {
			errs <- err
			return
		}
		acquired <- lock
	}()

	select {
	case lock := <-acquired:
		lock.Close()
		t.Fatal("second build acquired the APT lock before the first released it")
	case err := <-errs:
		t.Fatalf("second lock failed: %v", err)
	case <-time.After(50 * time.Millisecond):
	}

	if err := syscall.Flock(int(first.Fd()), syscall.LOCK_UN); err != nil {
		t.Fatal(err)
	}
	select {
	case second := <-acquired:
		if err := second.Close(); err != nil {
			t.Fatal(err)
		}
	case err := <-errs:
		t.Fatalf("second lock failed after release: %v", err)
	case <-time.After(time.Second):
		t.Fatal("second build did not acquire the APT lock after release")
	}
}

func TestValidateBuildHostOS(t *testing.T) {
	tests := []struct {
		name      string
		targetOS  string
		osRelease string
		wantErr   bool
	}{
		{
			name:      "matching Debian release",
			targetOS:  "debian13",
			osRelease: "ID=debian\nVERSION_ID=\"13\"\n",
		},
		{
			name:      "different Debian release",
			targetOS:  "debian12",
			osRelease: "ID=debian\nVERSION_ID=\"13\"\n",
			wantErr:   true,
		},
		{
			name:      "different distribution",
			targetOS:  "debian13",
			osRelease: "ID=ubuntu\nVERSION_ID=\"24.04\"\n",
			wantErr:   true,
		},
		{
			name:      "missing distribution metadata",
			targetOS:  "debian13",
			osRelease: "NAME=Debian\n",
			wantErr:   true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			osReleasePath := filepath.Join(t.TempDir(), "os-release")
			if err := os.WriteFile(osReleasePath, []byte(tt.osRelease), 0o600); err != nil {
				t.Fatal(err)
			}

			err := validateBuildHostOS(tt.targetOS, osReleasePath)
			if (err != nil) != tt.wantErr {
				t.Fatalf("validateBuildHostOS() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestRequireNodePackageToolsNamesMissingPackages(t *testing.T) {
	missing := map[string]bool{"skopeo": true, "dpkg-deb": true}
	lookPath := func(command string) (string, error) {
		if missing[command] {
			return "", exec.ErrNotFound
		}
		return "/usr/bin/" + command, nil
	}

	err := requireNodePackageTools(lookPath)

	if err == nil || !strings.Contains(err.Error(), "dpkg-deb, skopeo") || !strings.Contains(err.Error(), "sudo apt-get install dpkg skopeo") {
		t.Fatalf("got %v, want the missing commands and the sudo apt-get install hint", err)
	}
	if err := requireNodePackageTools(func(command string) (string, error) { return "/usr/bin/" + command, nil }); err != nil {
		t.Fatalf("all tools present: got %v", err)
	}
}

func TestDefaultNodePackageProxyUsesK2sProxyOnlyWhenInstalled(t *testing.T) {
	configDir := t.TempDir()

	proxy, err := defaultNodePackageProxy(repositoryRoot, configDir)
	if err != nil || proxy != "" {
		t.Fatalf("without K2s installation: got %q, %v, want no proxy", proxy, err)
	}

	if err := os.WriteFile(filepath.Join(configDir, "setup.json"), []byte(`{"SetupType":"k2s","LinuxOnly":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	proxy, err = defaultNodePackageProxy(repositoryRoot, configDir)
	if err != nil || proxy != "http://172.19.1.1:8181" {
		t.Fatalf("with K2s installation: got %q, %v, want http://172.19.1.1:8181", proxy, err)
	}
}

func TestValidateNodePackageProxy(t *testing.T) {
	tests := []struct {
		name    string
		proxy   string
		wantErr bool
	}{
		{name: "empty", proxy: ""},
		{name: "http proxy", proxy: "http://proxy.example:8080"},
		{name: "https proxy", proxy: "https://proxy.example:8443"},
		{name: "ipv6 proxy", proxy: "http://[2001:db8::1]:8080"},
		{name: "apt quote injection", proxy: `http://proxy"; DPkg::Pre-Invoke { "id"; }; "`, wantErr: true},
		{name: "curl option injection", proxy: "http://proxy.example:8080 --output=/tmp/file", wantErr: true},
		{name: "shell expansion", proxy: "http://proxy.example:8080$(id)", wantErr: true},
		{name: "unsupported scheme", proxy: "ftp://proxy.example:8080", wantErr: true},
		{name: "path", proxy: "http://proxy.example/path", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateNodePackageProxy(tt.proxy)
			if (err != nil) != tt.wantErr {
				t.Fatalf("validateNodePackageProxy(%q) error = %v, wantErr %v", tt.proxy, err, tt.wantErr)
			}
		})
	}
}

func TestEnvironmentWithOverridesReplacesExistingValues(t *testing.T) {
	const key = "K2S_TEST_APT_CONFIG"
	t.Setenv(key, "original")

	values := environmentWithOverrides(map[string]string{key: "isolated"})
	count := 0
	for _, entry := range values {
		if strings.HasPrefix(entry, key+"=") {
			count++
			if entry != key+"=isolated" {
				t.Fatalf("environment value = %q, want %q", entry, key+"=isolated")
			}
		}
	}
	if count != 1 {
		t.Fatalf("found %d entries for %s, want exactly one", count, key)
	}
}

func TestValidateRequiredDebPackages(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"cri-o", "cri-tools", "kubeadm", "kubectl", "kubelet"} {
		path := filepath.Join(dir, name+"_1.0_amd64.deb")
		if err := os.WriteFile(path, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	if err := validateRequiredDebPackages(dir, []string{"cri-o", "cri-tools", "kubeadm", "kubectl", "kubelet"}); err != nil {
		t.Fatalf("validateRequiredDebPackages() error = %v", err)
	}

	if err := os.Remove(filepath.Join(dir, "cri-o_1.0_amd64.deb")); err != nil {
		t.Fatal(err)
	}
	if err := validateRequiredDebPackages(dir, []string{"cri-o", "cri-tools", "kubeadm", "kubectl", "kubelet"}); err == nil || !strings.Contains(err.Error(), "cri-o") {
		t.Fatalf("validateRequiredDebPackages() error = %v, want missing cri-o package", err)
	}
}

func TestBuildZipDoesNotFollowExistingSymlink(t *testing.T) {
	dir := t.TempDir()
	sourceDir := filepath.Join(dir, "source")
	if err := os.Mkdir(sourceDir, 0o700); err != nil {
		t.Fatal(err)
	}
	victimPath := filepath.Join(dir, "victim")
	if err := os.WriteFile(victimPath, []byte("preserve"), 0o600); err != nil {
		t.Fatal(err)
	}
	zipPath := filepath.Join(dir, "package.zip")
	if err := os.Symlink(victimPath, zipPath); err != nil {
		t.Fatal(err)
	}

	if err := buildZip(context.Background(), zipPath, sourceDir); err == nil {
		t.Fatal("buildZip() succeeded with an existing symlink destination")
	}
	content, err := os.ReadFile(victimPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "preserve" {
		t.Fatalf("symlink target content = %q, want %q", content, "preserve")
	}
}

func TestBuildCommandCancellationStopsProcessGroup(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cmd := buildCommand(ctx, "sh", "-c", "sleep 30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	cancel()
	if err := cmd.Wait(); err == nil {
		t.Fatal("build command succeeded after cancellation")
	}
}

func TestRestoreFilesRestoresExistingFilesAndRemovesNewFiles(t *testing.T) {
	dir := t.TempDir()
	existingPath := filepath.Join(dir, "existing.list")
	newPath := filepath.Join(dir, "new.list")
	if err := os.WriteFile(existingPath, []byte("original"), 0o640); err != nil {
		t.Fatal(err)
	}

	snapshots, err := snapshotFiles([]string{existingPath, newPath})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(existingPath, []byte("modified"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(newPath, []byte("new"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := restoreFiles(snapshots); err != nil {
		t.Fatal(err)
	}

	content, err := os.ReadFile(existingPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "original" {
		t.Fatalf("restored content = %q, want %q", content, "original")
	}
	info, err := os.Stat(existingPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o640 {
		t.Fatalf("restored mode = %o, want %o", info.Mode().Perm(), 0o640)
	}
	if _, err := os.Stat(newPath); !os.IsNotExist(err) {
		t.Fatalf("new file still exists or could not be checked: %v", err)
	}
}

func TestRestoreFilesRestoresSymlinks(t *testing.T) {
	dir := t.TempDir()
	targetPath := filepath.Join(dir, "target")
	linkPath := filepath.Join(dir, "source.list")
	if err := os.WriteFile(targetPath, []byte("original target"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(targetPath, linkPath); err != nil {
		t.Fatal(err)
	}

	snapshots, err := snapshotFiles([]string{linkPath})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(targetPath, []byte("modified target"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(linkPath); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(linkPath, []byte("replacement"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := restoreFiles(snapshots); err != nil {
		t.Fatal(err)
	}
	linkTarget, err := os.Readlink(linkPath)
	if err != nil {
		t.Fatal(err)
	}
	if linkTarget != targetPath {
		t.Fatalf("restored symlink target = %q, want %q", linkTarget, targetPath)
	}
	content, err := os.ReadFile(targetPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "original target" {
		t.Fatalf("restored symlink target content = %q, want %q", content, "original target")
	}
	info, err := os.Stat(targetPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o640 {
		t.Fatalf("restored symlink target mode = %o, want %o", info.Mode().Perm(), 0o640)
	}
}
