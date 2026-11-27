// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/k2s-project/k2s/internal/definitions"
	kjson "github.com/k2s-project/k2s/internal/json"
)

const testKubectlNodesDualJSON = `{
	"items": [
		{
			"metadata": {
				"name": "debian-host",
				"labels": {"node-role.kubernetes.io/control-plane": ""}
			},
			"status": {"nodeInfo": {"operatingSystem": "linux"}}
		},
		{
			"metadata": {
				"name": "win-worker-01",
				"labels": {"kubernetes.io/os": "windows"}
			},
			"status": {"nodeInfo": {"operatingSystem": "windows"}}
		}
	]
}`

const testKubectlNodesLinuxOnlyJSON = `{
	"items": [
		{
			"metadata": {
				"name": "debian-host",
				"labels": {"node-role.kubernetes.io/control-plane": ""}
			},
			"status": {"nodeInfo": {"operatingSystem": "linux"}}
		}
	]
}`

func extractDecodedPSScript(t *testing.T, sshArgs []string) string {
	t.Helper()
	if len(sshArgs) == 0 {
		t.Fatal("empty ssh args")
	}
	remoteCmd := sshArgs[len(sshArgs)-1]
	const marker = "-EncodedCommand "
	idx := strings.Index(remoteCmd, marker)
	if idx == -1 {
		t.Fatalf("expected -EncodedCommand in remote cmd: %q", remoteCmd)
	}
	return decodeUTF16LEBase64(t, strings.TrimSpace(remoteCmd[idx+len(marker):]))
}

func setupTestProvider(t *testing.T, linuxOnly bool, runner *mockCmdRunner) (*linuxImageProvider, string, string) {
	t.Helper()
	installDir := t.TempDir()
	configDir := t.TempDir()

	setupCfg := map[string]any{
		"SetupType":  "k2s",
		"LinuxOnly":  linuxOnly,
		"Registries": []any{},
	}
	setupPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	if err := kjson.ToFile(setupPath, &setupCfg); err != nil {
		t.Fatalf("writing setup.json: %v", err)
	}
	if !linuxOnly {
		workerPath := filepath.Join(configDir, windowsWorkerStateFileName)
		if err := os.WriteFile(workerPath, []byte(`{"name":"k2s-win-worker","ip":"172.19.1.101"}`), 0600); err != nil {
			t.Fatalf("writing windows-worker.json: %v", err)
		}
	}

	w := newWinWorkerClient(installDir, configDir, nil)
	w.runner = runner
	w.hostnameFn = func() (string, error) { return "debian-host", nil }
	w.getenvFn = func(string) string { return "" }

	p := &linuxImageProvider{
		installDir: installDir,
		configDir:  configDir,
		winWorker:  w,
		localRunner: runner,
	}
	return p, installDir, configDir
}

func createDummyScript(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatalf("failed to create script dir: %v", err)
	}
	content := []byte("#!/usr/bin/env bash\nexit 0\n")
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

func TestLinuxImageProvider_BuildRejectsWindowsOnLinuxOnly(t *testing.T) {
	runner := &mockCmdRunner{}
	p, _, _ := setupTestProvider(t, true, runner)
	err := p.Build(ImageBuildConfig{Windows: true})
	if err == nil {
		t.Fatal("Build(Windows=true) expected error, got nil")
	}
	want := "building Windows container images is not supported on a Linux-only installation"
	if err.Error() != want {
		t.Fatalf("got error %q, want %q", err.Error(), want)
	}
}

func TestLinuxImageProvider_BuildExecutesScript(t *testing.T) {
	tmpDir := t.TempDir()
	var gotScript string
	var gotArgs []string
	p := &linuxImageProvider{
		installDir: tmpDir,
		runScriptFn: func(script string, showOutput bool, args ...string) error {
			gotScript = script
			gotArgs = args
			return nil
		},
	}
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
	if gotScript != script {
		t.Fatalf("script = %q, want %q", gotScript, script)
	}
	if !strings.Contains(strings.Join(gotArgs, " "), "--build-arg KEY=VAL") {
		t.Fatalf("expected build-arg in args, got %v", gotArgs)
	}
}

func TestLinuxImageProvider_BuildWindowsOnReverted(t *testing.T) {
	var psScripts []string
	var scpCalls []recordedCmd
	runner := &mockCmdRunner{
		fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
			switch name {
			case "ssh":
				psScripts = append(psScripts, extractDecodedPSScript(t, args))
			case "scp":
				scpCalls = append(scpCalls, recordedCmd{name: name, args: args})
			}
			return nil
		},
	}

	p, _, _ := setupTestProvider(t, false, runner)
	ctxDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(ctxDir, "Dockerfile"), []byte("FROM mcr.microsoft.com/windows/nanoserver:ltsc2022\n"), 0644); err != nil {
		t.Fatal(err)
	}

	err := p.Build(ImageBuildConfig{
		InputFolder: ctxDir,
		ImageName:   "k2s.registry.local/win-app",
		ImageTag:    "1.0",
		Windows:     true,
		Push:        true,
		BuildArgs:   map[string]string{"ENV": "prod"},
		ShowOutput:  true,
	})
	if err != nil {
		t.Fatalf("Build(Windows=true) failed: %v", err)
	}

	if len(scpCalls) != 1 {
		t.Fatalf("expected 1 scp call, got %d", len(scpCalls))
	}
	if !strings.Contains(strings.Join(scpCalls[0].args, " "), "C:/ProgramData/K2s/tmp/build-") {
		t.Fatalf("expected scp destination under C:/ProgramData/K2s/tmp/build-, got %v", scpCalls[0].args)
	}

	allPS := strings.Join(psScripts, "\n---\n")
	for _, want := range []string{
		"tar.exe -xf",
		"Install-WinDocker",
		`C:\k2s\bin\docker\docker.exe`,
		"--build-arg",
		"ENV=prod",
		"save -o",
		`C:\k2s\bin\containerd\ctr.exe`,
		"images import",
		"rmi -f",
		`C:\k2s\bin\nerdctl.exe`,
		"--allow-nondistributable-artifacts",
		"Remove-Item -Path 'C:\\ProgramData\\K2s\\tmp\\build-",
	} {
		if !strings.Contains(allPS, want) {
			t.Errorf("expected PowerShell script to contain %q", want)
		}
	}
}

func TestLinuxImageProvider_List(t *testing.T) {
	winCrictlJSON := `{
		"images": [
			{"id": "sha256:111111111111aaaa", "repoTags": ["mywinapp:v1"], "size": "50000000"},
			{"id": "sha256:222222222222bbbb", "repoTags": ["shsk2s.azurecr.io/pause-win:3.9"], "size": "10000000"}
		]
	}`

	linuxImgs := []ContainerImage{
		{ImageId: "aaaa11112222", Repository: "mylinuxapp", Tag: "v1", Node: "debian-host", Size: "1234"},
		{ImageId: "bbbb11112222", Repository: "registry.k8s.io/coredns/coredns", Tag: "v1.11.1", Node: "debian-host", Size: "5678"},
	}

	t.Run("linux-only filters k8s and sets node name", func(t *testing.T) {
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				if name == "kubectl" {
					_, _ = io.WriteString(stdout, testKubectlNodesLinuxOnlyJSON)
				}
				return nil
			},
		}
		p, _, _ := setupTestProvider(t, true, runner)
		p.linuxImagesFn = func(nodeName string) ([]ContainerImage, error) {
			out := make([]ContainerImage, len(linuxImgs))
			for i, img := range linuxImgs {
				img.Node = nodeName
				out[i] = img
			}
			return out, nil
		}

		res, err := p.List(ImageListConfig{})
		if err != nil {
			t.Fatalf("List() failed: %v", err)
		}
		if len(res.ContainerImages) != 1 {
			t.Fatalf("expected 1 non-k8s image, got %d: %+v", len(res.ContainerImages), res.ContainerImages)
		}
		if res.ContainerImages[0].Node != "debian-host" {
			t.Fatalf("expected node 'debian-host', got %q", res.ContainerImages[0].Node)
		}
	})

	t.Run("reverted lists both nodes with real names and queries local registry", func(t *testing.T) {
		regServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch r.URL.Path {
			case "/v2/_catalog":
				_, _ = io.WriteString(w, `{"repositories":["demo/app"]}`)
			case "/v2/demo/app/tags/list":
				_, _ = io.WriteString(w, `{"name":"demo/app","tags":["v1","v2"]}`)
			default:
				http.NotFound(w, r)
			}
		}))
		defer regServer.Close()

		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				switch name {
				case "kubectl":
					_, _ = io.WriteString(stdout, testKubectlNodesDualJSON)
				case "ssh":
					_, _ = io.WriteString(stdout, winCrictlJSON)
				}
				return nil
			},
		}

		p, _, configDir := setupTestProvider(t, false, runner)
		// Configure local registry in setup.json and redirect HTTP transport to test server.
		setupPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
		setupCfg := map[string]any{
			"SetupType":  "k2s",
			"LinuxOnly":  false,
			"Registries": []any{"k2s.registry.local"},
		}
		if err := kjson.ToFile(setupPath, &setupCfg); err != nil {
			t.Fatal(err)
		}
		p.httpClient = &http.Client{
			Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				reqCopy := req.Clone(req.Context())
				reqCopy.URL.Scheme = "http"
				reqCopy.URL.Host = strings.TrimPrefix(regServer.URL, "http://")
				return http.DefaultTransport.RoundTrip(reqCopy)
			}),
		}
		p.linuxImagesFn = func(nodeName string) ([]ContainerImage, error) {
			return linuxImgs, nil
		}

		res, err := p.List(ImageListConfig{})
		if err != nil {
			t.Fatalf("List() failed: %v", err)
		}
		if len(res.ContainerImages) != 2 {
			t.Fatalf("expected 2 non-k8s images (1 linux + 1 windows), got %d: %+v", len(res.ContainerImages), res.ContainerImages)
		}
		if res.ContainerImages[0].Node != "debian-host" || res.ContainerImages[1].Node != "win-worker-01" {
			t.Fatalf("unexpected node names: %+v", res.ContainerImages)
		}
		if res.ContainerRegistry != "k2s.registry.local" {
			t.Fatalf("expected ContainerRegistry 'k2s.registry.local', got %q", res.ContainerRegistry)
		}
		if len(res.PushedImages) != 2 {
			t.Fatalf("expected 2 pushed images, got %+v", res.PushedImages)
		}

		// --node Linux only
		resLinuxOnly, err := p.List(ImageListConfig{Nodes: "debian-host"})
		if err != nil {
			t.Fatalf("List(--node debian-host) failed: %v", err)
		}
		if len(resLinuxOnly.ContainerImages) != 1 || resLinuxOnly.ContainerImages[0].Node != "debian-host" {
			t.Fatalf("expected only Linux image, got %+v", resLinuxOnly.ContainerImages)
		}

		// --node Windows only (with IncludeK8sImages)
		resWinOnly, err := p.List(ImageListConfig{Nodes: "win-worker-01", IncludeK8sImages: true})
		if err != nil {
			t.Fatalf("List(--node win-worker-01) failed: %v", err)
		}
		if len(resWinOnly.ContainerImages) != 2 || resWinOnly.ContainerImages[0].Node != "win-worker-01" {
			t.Fatalf("expected 2 Windows images including pause, got %+v", resWinOnly.ContainerImages)
		}
	})
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestLinuxImageProvider_Pull(t *testing.T) {
	t.Run("windows flag pulls on Windows worker", func(t *testing.T) {
		var psScript string
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				switch name {
				case "kubectl":
					_, _ = io.WriteString(stdout, testKubectlNodesDualJSON)
				case "ssh":
					psScript = extractDecodedPSScript(t, args)
				}
				return nil
			},
		}
		p, _, _ := setupTestProvider(t, false, runner)
		if err := p.Pull(ImagePullConfig{ImageName: "mcr.microsoft.com/windows/nanoserver:ltsc2022", Windows: true}); err != nil {
			t.Fatalf("Pull(-w) failed: %v", err)
		}
		if !strings.Contains(psScript, `C:\k2s\bin\crictl.exe`) || !strings.Contains(psScript, `C:\k2s\bin\nerdctl.exe`) {
			t.Fatalf("unexpected Windows pull script: %s", psScript)
		}
	})

	t.Run("auto-fallback to Windows worker on platform mismatch", func(t *testing.T) {
		var winPulled bool
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				switch name {
				case "kubectl":
					_, _ = io.WriteString(stdout, testKubectlNodesDualJSON)
				case "ssh":
					script := extractDecodedPSScript(t, args)
					if strings.Contains(script, "pull") && strings.Contains(script, "win-image:latest") {
						winPulled = true
					}
				}
				return nil
			},
		}
		p, _, _ := setupTestProvider(t, false, runner)
		scriptPath := p.scriptPath("Pull-Image.sh")
		createDummyScript(t, scriptPath)
		p.runScriptFn = func(script string, showOutput bool, args ...string) error {
			return errors.New("no matching manifest for linux/amd64 in the manifest list entries")
		}

		if err := p.Pull(ImagePullConfig{ImageName: "win-image:latest"}); err != nil {
			t.Fatalf("Pull() with auto-fallback failed: %v", err)
		}
		if !winPulled {
			t.Fatal("expected fallback pull on Windows worker")
		}
	})
}

func TestLinuxImageProvider_ImportWindows(t *testing.T) {
	var psScripts []string
	var scpCount int
	runner := &mockCmdRunner{
		fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
			switch name {
			case "kubectl":
				_, _ = io.WriteString(stdout, testKubectlNodesDualJSON)
			case "ssh":
				psScripts = append(psScripts, extractDecodedPSScript(t, args))
			case "scp":
				scpCount++
			}
			return nil
		},
	}

	p, _, _ := setupTestProvider(t, false, runner)
	tarDir := t.TempDir()
	tar1 := filepath.Join(tarDir, "a.tar")
	tar2 := filepath.Join(tarDir, "b.tar")
	if err := os.WriteFile(tar1, []byte("tar1"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(tar2, []byte("tar2"), 0644); err != nil {
		t.Fatal(err)
	}

	if err := p.Import(ImageImportConfig{DirPath: tarDir, Windows: true}); err != nil {
		t.Fatalf("Import(DirPath, Windows=true) failed: %v", err)
	}
	if scpCount != 2 {
		t.Fatalf("expected 2 scp uploads for 2 tar files, got %d", scpCount)
	}
	allPS := strings.Join(psScripts, "\n")
	if !strings.Contains(allPS, "images import --all-platforms") || !strings.Contains(allPS, "Remove-Item -Path 'C:\\ProgramData\\K2s\\tmp\\import-") {
		t.Fatalf("expected ctr import and cleanup in PS scripts, got: %s", allPS)
	}
}

func TestLinuxImageProvider_Export(t *testing.T) {
	winCrictlJSON := `{"images":[{"id":"sha256:9999888877776666","repoTags":["shared/app:v1"],"size":"42"}]}`

	t.Run("dual-node export splits into _linux.tar and _windows.tar", func(t *testing.T) {
		var linuxExportPath string
		var scpFromDest string
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				switch name {
				case "kubectl":
					_, _ = io.WriteString(stdout, testKubectlNodesDualJSON)
				case "ssh":
					script := extractDecodedPSScript(t, args)
					if strings.Contains(script, "images -o json") {
						_, _ = io.WriteString(stdout, winCrictlJSON)
					} else if strings.Contains(script, "images ls -q") {
						_, _ = io.WriteString(stdout, "shared/app:v1\n")
					}
				case "scp":
					scpFromDest = args[len(args)-1]
				}
				return nil
			},
		}

		p, _, _ := setupTestProvider(t, false, runner)
		createDummyScript(t, p.scriptPath("Export-Image.sh"))
		p.linuxImagesFn = func(nodeName string) ([]ContainerImage, error) {
			return []ContainerImage{{ImageId: "1234567890ab", Repository: "shared/app", Tag: "v1", Node: nodeName}}, nil
		}
		p.runScriptFn = func(script string, showOutput bool, args ...string) error {
			for i := 0; i < len(args)-1; i++ {
				if args[i] == "-t" {
					linuxExportPath = args[i+1]
				}
			}
			return nil
		}

		outPath := filepath.Join(t.TempDir(), "myexport.tar")
		if err := p.Export(ImageExportConfig{ImageName: "shared/app:v1", OutputPath: outPath}); err != nil {
			t.Fatalf("Export() dual-node failed: %v", err)
		}

		wantLinux := strings.TrimSuffix(outPath, ".tar") + "_linux.tar"
		wantWin := strings.TrimSuffix(outPath, ".tar") + "_windows.tar"
		if linuxExportPath != wantLinux {
			t.Fatalf("linux export path = %q, want %q", linuxExportPath, wantLinux)
		}
		if scpFromDest != wantWin {
			t.Fatalf("windows export path = %q, want %q", scpFromDest, wantWin)
		}
	})

	t.Run("not found returns error", func(t *testing.T) {
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				if name == "kubectl" {
					_, _ = io.WriteString(stdout, testKubectlNodesLinuxOnlyJSON)
				}
				return nil
			},
		}
		p, _, _ := setupTestProvider(t, true, runner)
		p.linuxImagesFn = func(nodeName string) ([]ContainerImage, error) { return nil, nil }

		err := p.Export(ImageExportConfig{ImageName: "missing:v1", OutputPath: filepath.Join(t.TempDir(), "out.tar")})
		if err == nil || !strings.Contains(err.Error(), "image not found") {
			t.Fatalf("expected image not found error, got %v", err)
		}
	})
}

func TestLinuxImageProvider_TagPushRemoveCleanWindows(t *testing.T) {
	winCrictlJSON := `{"images":[{"id":"sha256:abcdef1234567890","repoTags":["k2s.registry.local/winapp:v1"],"size":"100"},{"id":"sha256:0000111122223333","repoTags":["shsk2s.azurecr.io/pause-win:3.9"],"size":"50"}]}`
	winPsJSON := `{"containers":[{"id":"ctr-123","image":{"image":"k2s.registry.local/winapp:v1"},"imageRef":"sha256:abcdef1234567890"}]}`

	var psScripts []string
	runner := &mockCmdRunner{
		fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
			switch name {
			case "kubectl":
				_, _ = io.WriteString(stdout, testKubectlNodesDualJSON)
			case "ssh":
				script := extractDecodedPSScript(t, args)
				psScripts = append(psScripts, script)
				if strings.Contains(script, "images -o json") {
					_, _ = io.WriteString(stdout, winCrictlJSON)
				} else if strings.Contains(script, "images ls -q") {
					_, _ = io.WriteString(stdout, "k2s.registry.local/winapp:v1\n")
				} else if strings.Contains(script, "ps -a -o json") {
					_, _ = io.WriteString(stdout, winPsJSON)
				}
			}
			return nil
		},
	}

	p, _, _ := setupTestProvider(t, false, runner)
	p.linuxImagesFn = func(nodeName string) ([]ContainerImage, error) { return nil, nil }

	// Tag on Windows
	if err := p.Tag(ImageTagConfig{ImageName: "k2s.registry.local/winapp:v1", TargetImageName: "k2s.registry.local/winapp:v2"}); err != nil {
		t.Fatalf("Tag() failed: %v", err)
	}
	// Push on Windows
	if err := p.Push(ImagePushConfig{ImageName: "k2s.registry.local/winapp:v1"}); err != nil {
		t.Fatalf("Push() failed: %v", err)
	}
	// Remove with --force on Windows
	if err := p.Remove(ImageRemoveConfig{ImageName: "k2s.registry.local/winapp:v1", Force: true}); err != nil {
		t.Fatalf("Remove(--force) failed: %v", err)
	}
	// Clean on Windows only
	if err := p.Clean(ImageCleanConfig{Nodes: "win-worker-01"}); err != nil {
		t.Fatalf("Clean(win-worker-01) failed: %v", err)
	}

	allPS := strings.Join(psScripts, "\n---\n")
	for _, want := range []string{
		"-n k8s.io tag",
		"--allow-nondistributable-artifacts",
		"stop 'ctr-123'",
		"rm 'ctr-123'",
		"rmi 'k2s.registry.local/winapp:v1'",
		"rmi 'abcdef123456'",
	} {
		if !strings.Contains(allPS, want) {
			t.Errorf("expected Windows PS commands to contain %q", want)
		}
	}
	if strings.Contains(allPS, "rmi '000011112222'") {
		t.Error("Clean should not remove pause-win baseline image")
	}
}

func TestLinuxImageProvider_RemoveFromRegistryWithBasicAuth(t *testing.T) {
	var gotAuthHeader string
	var deletedPath string
	regServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuthHeader = r.Header.Get("Authorization")
		switch r.Method {
		case http.MethodGet:
			w.Header().Set("Docker-Content-Digest", "sha256:deadbeef")
			w.WriteHeader(http.StatusOK)
		case http.MethodDelete:
			deletedPath = r.URL.Path
			w.WriteHeader(http.StatusAccepted)
		}
	}))
	defer regServer.Close()

	runner := &mockCmdRunner{}
	p, _, _ := setupTestProvider(t, true, runner)

	authFile := filepath.Join(t.TempDir(), "auth.json")
	authB64 := base64.StdEncoding.EncodeToString([]byte("admin:secret"))
	if err := os.WriteFile(authFile, []byte(`{"auths":{"k2s.registry.local":{"auth":"`+authB64+`"}}}`), 0600); err != nil {
		t.Fatal(err)
	}
	p.authFilePath = authFile
	p.httpClient = &http.Client{
		Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			reqCopy := req.Clone(req.Context())
			reqCopy.URL.Scheme = "http"
			reqCopy.URL.Host = strings.TrimPrefix(regServer.URL, "http://")
			return http.DefaultTransport.RoundTrip(reqCopy)
		}),
	}

	err := p.Remove(ImageRemoveConfig{ImageName: "k2s.registry.local/demo/app:v1", FromRegistry: true})
	if err != nil {
		t.Fatalf("Remove(FromRegistry=true) failed: %v", err)
	}
	if gotAuthHeader != "Basic "+authB64 {
		t.Fatalf("auth header = %q, want %q", gotAuthHeader, "Basic "+authB64)
	}
	if deletedPath != "/v2/demo/app/manifests/sha256:deadbeef" {
		t.Fatalf("deletedPath = %q", deletedPath)
	}
}

func TestLinuxImageProvider_RegistryAddRemoveListReverted(t *testing.T) {
	var psScripts []string
	runner := &mockCmdRunner{
		fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
			switch name {
			case "kubectl":
				_, _ = io.WriteString(stdout, testKubectlNodesDualJSON)
			case "ssh":
				script := extractDecodedPSScript(t, args)
				psScripts = append(psScripts, script)
				if strings.Contains(script, "Get-ChildItem") && strings.Contains(script, "hosts.toml") {
					_, _ = io.WriteString(stdout, "my.win.reg:5000\nshared.reg.io\n")
				}
			}
			return nil
		},
	}

	p, _, configDir := setupTestProvider(t, false, runner)
	p.runScriptFn = func(script string, showOutput bool, args ...string) error { return nil }

	// RegistryAdd on both nodes
	err := p.RegistryAdd(ImageRegistryAddConfig{
		RegistryName: "my.reg:5000",
		Username:     "user",
		Password:     "pass",
		SkipVerify:   true,
	})
	if err != nil {
		t.Fatalf("RegistryAdd() failed: %v", err)
	}

	// RegistryList with empty nodes reads setup.json
	regs, err := p.RegistryList(context.Background(), ImageRegistryListConfig{})
	if err != nil {
		t.Fatalf("RegistryList(empty) failed: %v", err)
	}
	if !reflect.DeepEqual(regs, []string{"my.reg:5000"}) {
		t.Fatalf("RegistryList(empty) = %v, want [my.reg:5000]", regs)
	}

	// RegistryList with --nodes queries Linux conf.d and Windows certs.d, deduplicated & sorted
	regDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(regDir, "shared.conf"), []byte("[[registry]]\nlocation = \"shared.reg.io\"\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(regDir, "linux.conf"), []byte("[[registry]]\nlocation = \"my.linux.reg\"\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(regDir, "00-default.conf"), []byte("location = \"ignored\"\n"), 0644); err != nil {
		t.Fatal(err)
	}
	p.registriesDir = regDir

	byNode, err := p.RegistryList(context.Background(), ImageRegistryListConfig{Nodes: []string{"debian-host", "win-worker-01"}})
	if err != nil {
		t.Fatalf("RegistryList(both nodes) failed: %v", err)
	}
	wantCombined := []string{"my.linux.reg", "my.win.reg:5000", "shared.reg.io"}
	if !reflect.DeepEqual(byNode, wantCombined) {
		t.Fatalf("RegistryList(both nodes) = %v, want %v", byNode, wantCombined)
	}

	// RegistryRemove on both nodes
	if err := p.RegistryRemove(ImageRegistryRemoveConfig{RegistryName: "my.reg:5000"}); err != nil {
		t.Fatalf("RegistryRemove() failed: %v", err)
	}

	setupPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	loadedConfig, err := kjson.FromFile[map[string]any](setupPath)
	if err != nil {
		t.Fatal(err)
	}
	if raw, ok := (*loadedConfig)["Registries"].([]any); ok && len(raw) != 0 {
		t.Fatalf("expected empty Registries after removal, got %v", raw)
	}

	allPS := strings.Join(psScripts, "\n---\n")
	for _, want := range []string{
		`C:\etc\containerd\certs.d\my.reg5000\hosts.toml`,
		"#add_new_registry_auth",
		"Restart-Service -Name 'containerd' -Force",
		"logout 'my.reg:5000'",
	} {
		if !strings.Contains(allPS, want) {
			t.Errorf("expected Windows registry PS script to contain %q", want)
		}
	}
}

func TestLinuxImageProvider_ResetWinStorage(t *testing.T) {
	t.Run("rejects Linux-only setup", func(t *testing.T) {
		p, _, _ := setupTestProvider(t, true, &mockCmdRunner{})
		err := p.ResetWinStorage(context.Background(), ImageResetWinStorageConfig{})
		want := "Resetting WinContainerStorage for Linux-only setup is not supported."
		if err == nil || err.Error() != want {
			t.Fatalf("got %v, want %q", err, want)
		}
	})

	t.Run("rejects when cluster is still running", func(t *testing.T) {
		p, _, _ := setupTestProvider(t, false, &mockCmdRunner{})
		p.clusterActiveFn = func(ctx context.Context) bool { return true }
		err := p.ResetWinStorage(context.Background(), ImageResetWinStorageConfig{})
		if err == nil || !strings.Contains(err.Error(), "still running") {
			t.Fatalf("expected 'still running' error, got %v", err)
		}
	})

	t.Run("cleans storage on Windows worker when stopped", func(t *testing.T) {
		var psScript string
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				if name == "ssh" {
					psScript = extractDecodedPSScript(t, args)
				}
				return nil
			},
		}
		p, _, _ := setupTestProvider(t, false, runner)
		p.clusterActiveFn = func(ctx context.Context) bool { return false }

		err := p.ResetWinStorage(context.Background(), ImageResetWinStorageConfig{
			Containerd: `C:\containerd`,
			Docker:     `C:\docker`,
			MaxRetry:   3,
			ForceZap:   true,
			Force:      true,
		})
		if err != nil {
			t.Fatalf("ResetWinStorage() failed: %v", err)
		}
		for _, want := range []string{`C:\containerd`, `C:\docker`, `$maxRetry = 3`, `$forceZap = $true`, `C:\k2s\bin\zap.exe`} {
			if !strings.Contains(psScript, want) {
				t.Errorf("expected ResetWinStorage PS script to contain %q", want)
			}
		}
	})
}

func TestLinuxImageProvider_RegistryAddAndRemoveSyncsSetupJson(t *testing.T) {
	runner := &mockCmdRunner{
		fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
			if name == "kubectl" {
				_, _ = io.WriteString(stdout, testKubectlNodesLinuxOnlyJSON)
			}
			return nil
		},
	}
	p, _, configDir := setupTestProvider(t, true, runner)
	p.runScriptFn = func(script string, showOutput bool, args ...string) error { return nil }

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
	runner := &mockCmdRunner{
		fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
			if name == "kubectl" {
				_, _ = io.WriteString(stdout, testKubectlNodesLinuxOnlyJSON)
			}
			return nil
		},
	}
	p, _, _ := setupTestProvider(t, true, runner)
	p.runScriptFn = func(script string, showOutput bool, args ...string) error { return nil }
	p.linuxImagesFn = func(nodeName string) ([]ContainerImage, error) {
		return []ContainerImage{{ImageId: "abc123456789", Repository: "test", Tag: "latest", Node: nodeName}}, nil
	}

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

	outTar := filepath.Join(t.TempDir(), "out.tar")
	inTar := filepath.Join(t.TempDir(), "in.tar")

	if err := p.Clean(ImageCleanConfig{}); err != nil {
		t.Fatalf("Clean() failed: %v", err)
	}
	if err := p.Remove(ImageRemoveConfig{ImageName: "test"}); err != nil {
		t.Fatalf("Remove() failed: %v", err)
	}
	if err := p.Export(ImageExportConfig{ImageName: "test", OutputPath: outTar}); err != nil {
		t.Fatalf("Export() failed: %v", err)
	}
	if err := p.Import(ImageImportConfig{TarPath: inTar}); err != nil {
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
			name:     "large float exceeding int64",
			input:    `1e20`,
			expected: "100000000000000000000",
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

func TestLinuxImageProvider_ReviewFixes(t *testing.T) {
	t.Run("1. addWindowsRegistry uses --password-stdin and checks LASTEXITCODE before config.toml", func(t *testing.T) {
		var psScript string
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				switch name {
				case "kubectl":
					_, _ = io.WriteString(stdout, testKubectlNodesDualJSON)
				case "ssh":
					psScript = extractDecodedPSScript(t, args)
				}
				return nil
			},
		}
		p, _, _ := setupTestProvider(t, false, runner)
		p.runScriptFn = func(script string, showOutput bool, args ...string) error { return nil }

		err := p.RegistryAdd(ImageRegistryAddConfig{
			RegistryName: "my.reg:5000",
			Username:     "alice",
			Password:     "s3cr3t",
			SkipVerify:   true,
		})
		if err != nil {
			t.Fatalf("RegistryAdd failed: %v", err)
		}
		if !strings.Contains(psScript, "--password-stdin") {
			t.Fatalf("expected --password-stdin in PS script, got:\n%s", psScript)
		}
		if strings.Contains(psScript, " -p ") {
			t.Fatalf("expected no -p flag in PS script, got:\n%s", psScript)
		}
		loginIdx := strings.Index(psScript, "login")
		exitIdx := strings.Index(psScript, "if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }")
		cfgIdx := strings.Index(psScript, "config.toml")
		if loginIdx == -1 || exitIdx == -1 || cfgIdx == -1 || !(loginIdx < exitIdx && exitIdx < cfgIdx) {
			t.Fatalf("expected LASTEXITCODE check between login and config.toml modification, got:\n%s", psScript)
		}
	})

	t.Run("2. Windows PS scripts check LASTEXITCODE and cleanWindowsImages tracks per-image failure", func(t *testing.T) {
		winCrictlJSON := `{"images":[{"id":"sha256:abcdef1234567890","repoTags":["mywin:v1"],"size":"100"}]}`
		winPsJSON := `{"containers":[{"id":"ctr-1","image":{"image":"mywin:v1"},"imageRef":"sha256:abcdef1234567890"}]}`
		var psScripts []string
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				if name == "ssh" {
					script := extractDecodedPSScript(t, args)
					psScripts = append(psScripts, script)
					switch {
					case strings.Contains(script, "images -o json"):
						_, _ = io.WriteString(stdout, winCrictlJSON)
					case strings.Contains(script, "images ls -q"):
						_, _ = io.WriteString(stdout, "mywin:v1\n")
					case strings.Contains(script, "ps -a -o json"):
						_, _ = io.WriteString(stdout, winPsJSON)
					}
				}
				return nil
			},
		}
		p, _, _ := setupTestProvider(t, false, runner)

		if _, err := p.listWindowsImages(context.Background(), "win-worker-01"); err != nil {
			t.Fatalf("listWindowsImages failed: %v", err)
		}
		if _, err := p.resolveWindowsImageRef(context.Background(), "", "mywin:v1"); err != nil {
			t.Fatalf("resolveWindowsImageRef failed: %v", err)
		}
		if err := p.stopAndRemoveWindowsContainersForImages(context.Background(), []ContainerImage{{ImageId: "abcdef123456", Repository: "mywin", Tag: "v1"}}); err != nil {
			t.Fatalf("stopAndRemoveWindowsContainersForImages failed: %v", err)
		}
		if err := p.cleanWindowsImages(context.Background(), ImageCleanConfig{}); err != nil {
			t.Fatalf("cleanWindowsImages failed: %v", err)
		}

		if len(psScripts) < 6 {
			t.Fatalf("expected at least 6 PS scripts, got %d", len(psScripts))
		}
		// listWindowsImages
		if !strings.Contains(psScripts[0], "if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }") {
			t.Errorf("listWindowsImages missing LASTEXITCODE check: %s", psScripts[0])
		}
		// resolveWindowsImageRef (ctr images ls -q)
		if !strings.Contains(psScripts[1], "if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }") {
			t.Errorf("resolveWindowsImageRef missing LASTEXITCODE check: %s", psScripts[1])
		}
		// stopAndRemoveWindowsContainersForImages (ps -a -o json and stop/rm)
		if !strings.Contains(psScripts[2], "if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }") {
			t.Errorf("stopAndRemoveWindowsContainersForImages ps missing LASTEXITCODE check: %s", psScripts[2])
		}
		if !strings.Contains(psScripts[3], "if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }") {
			t.Errorf("stopAndRemoveWindowsContainersForImages stop/rm missing LASTEXITCODE check: %s", psScripts[3])
		}
		// cleanWindowsImages (list + rmi loop)
		cleanRmiScript := psScripts[len(psScripts)-1]
		if !strings.Contains(cleanRmiScript, "$failed = $true") || !strings.Contains(cleanRmiScript, "if ($failed) { exit 1 }") {
			t.Errorf("cleanWindowsImages missing $failed tracking: %s", cleanRmiScript)
		}
	})

	t.Run("3. importSingleWindowsTar uses fixed safe remote filename image.tar", func(t *testing.T) {
		var scpDest string
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				if name == "scp" {
					scpDest = args[len(args)-1]
				}
				return nil
			},
		}
		p, _, _ := setupTestProvider(t, false, runner)
		tarPath := filepath.Join(t.TempDir(), "my:weird image.tar")
		if err := os.WriteFile(tarPath, []byte("tar"), 0644); err != nil {
			t.Fatal(err)
		}

		if err := p.importSingleWindowsTar(context.Background(), tarPath, false); err != nil {
			t.Fatalf("importSingleWindowsTar failed: %v", err)
		}
		if !strings.HasSuffix(scpDest, `/image.tar`) && !strings.HasSuffix(scpDest, `\image.tar`) {
			t.Fatalf("expected fixed remote filename image.tar, got %q", scpDest)
		}
		if strings.Contains(scpDest, "my:weird") {
			t.Fatalf("remote filename should not contain unsafe local filename, got %q", scpDest)
		}
	})

	t.Run("4. isPlatformMismatchError rejects unrelated errors on windows-named images", func(t *testing.T) {
		if isPlatformMismatchError(errors.New("401 unauthorized pulling my-windows-app:latest")) {
			t.Error("401 error on windows-named image should not trigger platform fallback")
		}
		if isPlatformMismatchError(errors.New("404 not found: no image found for windows-exporter")) {
			t.Error("404 'no image found' error should not trigger platform fallback")
		}
		if !isPlatformMismatchError(errors.New("no image found in manifest list for linux/amd64")) {
			t.Error("'no image found in manifest list' should trigger platform fallback")
		}
		if !isPlatformMismatchError(errors.New("no matching manifest for linux/amd64 in the manifest list entries")) {
			t.Error("'no matching manifest' should trigger platform fallback")
		}
	})

	t.Run("5. List and locateImageOnNodes surface errors for explicit or all-failing nodes", func(t *testing.T) {
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				switch name {
				case "kubectl":
					_, _ = io.WriteString(stdout, testKubectlNodesDualJSON)
				case "ssh":
					return errors.New("ssh connection refused")
				}
				return nil
			},
		}
		p, _, _ := setupTestProvider(t, false, runner)
		p.linuxImagesFn = func(nodeName string) ([]ContainerImage, error) {
			return []ContainerImage{{ImageId: "abc", Repository: "app", Tag: "v1", Node: nodeName}}, nil
		}

		// Explicit node selector failing must return error
		if _, err := p.List(ImageListConfig{Nodes: "win-worker-01"}); err == nil {
			t.Fatal("expected error when explicit node win-worker-01 fails in List")
		}

		// Default multi-node scope with one healthy node succeeds partially
		res, err := p.List(ImageListConfig{})
		if err != nil {
			t.Fatalf("expected partial success in default List, got error: %v", err)
		}
		if len(res.ContainerImages) != 1 {
			t.Fatalf("expected 1 linux image in partial List, got %d", len(res.ContainerImages))
		}

		// Explicit node failing in Export (locateImageOnNodes) returns error instead of "image not found"
		err = p.Export(ImageExportConfig{ImageName: "app:v1", Nodes: "win-worker-01", OutputPath: filepath.Join(t.TempDir(), "out.tar")})
		if err == nil || strings.Contains(err.Error(), "image not found") {
			t.Fatalf("expected query error instead of 'image not found', got: %v", err)
		}

		// All targeted nodes failing in List and Export returns error
		p.linuxImagesFn = func(nodeName string) ([]ContainerImage, error) {
			return nil, errors.New("linux runtime down")
		}
		if _, err := p.List(ImageListConfig{}); err == nil {
			t.Fatal("expected error when all targeted nodes fail in List")
		}
		err = p.Export(ImageExportConfig{ImageName: "app:v1", OutputPath: filepath.Join(t.TempDir(), "out.tar")})
		if err == nil || strings.Contains(err.Error(), "image not found") {
			t.Fatalf("expected query error when all nodes fail in Export, got: %v", err)
		}
	})

	t.Run("6. RegistryAdd and RegistryRemove only update setup.json when Nodes is empty", func(t *testing.T) {
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				if name == "kubectl" {
					_, _ = io.WriteString(stdout, testKubectlNodesDualJSON)
				}
				return nil
			},
		}
		p, _, configDir := setupTestProvider(t, false, runner)
		p.runScriptFn = func(script string, showOutput bool, args ...string) error { return nil }

		setupPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
		initialCfg := map[string]any{
			"SetupType":  "k2s",
			"LinuxOnly":  false,
			"Registries": []any{"keep.reg.io"},
		}
		if err := kjson.ToFile(setupPath, &initialCfg); err != nil {
			t.Fatal(err)
		}

		if err := p.RegistryAdd(ImageRegistryAddConfig{RegistryName: "scoped.reg.io", Nodes: "win-worker-01"}); err != nil {
			t.Fatalf("RegistryAdd(Nodes) failed: %v", err)
		}
		if err := p.RegistryRemove(ImageRegistryRemoveConfig{RegistryName: "keep.reg.io", Nodes: "debian-host"}); err != nil {
			t.Fatalf("RegistryRemove(Nodes) failed: %v", err)
		}

		loaded, err := kjson.FromFile[map[string]any](setupPath)
		if err != nil {
			t.Fatal(err)
		}
		regs := (*loaded)["Registries"].([]any)
		if len(regs) != 1 || regs[0] != "keep.reg.io" {
			t.Fatalf("expected setup.json Registries unchanged when Nodes is set, got %v", regs)
		}
	})

	t.Run("7. resetWindowsStorage defaults empty Docker dir to C:\\docker", func(t *testing.T) {
		var psScript string
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				if name == "ssh" {
					psScript = extractDecodedPSScript(t, args)
				}
				return nil
			},
		}
		p, _, _ := setupTestProvider(t, false, runner)
		p.clusterActiveFn = func(ctx context.Context) bool { return false }

		if err := p.ResetWinStorage(context.Background(), ImageResetWinStorageConfig{}); err != nil {
			t.Fatalf("ResetWinStorage failed: %v", err)
		}
		if !strings.Contains(psScript, `$dockerDir = 'C:\docker'`) {
			t.Fatalf("expected default docker dir C:\\docker in PS script, got:\n%s", psScript)
		}
	})

	t.Run("8. buildWindowsImage uses state.Proxy when set and falls back to winDefaultProxy", func(t *testing.T) {
		var psScripts []string
		runner := &mockCmdRunner{
			fn: func(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
				if name == "ssh" {
					psScripts = append(psScripts, extractDecodedPSScript(t, args))
				}
				return nil
			},
		}
		p, _, configDir := setupTestProvider(t, false, runner)
		ctxDir := t.TempDir()
		if err := os.WriteFile(filepath.Join(ctxDir, "Dockerfile"), []byte("FROM mcr.microsoft.com/windows/nanoserver:ltsc2022\n"), 0644); err != nil {
			t.Fatal(err)
		}

		// With custom proxy in windows-worker.json
		workerPath := filepath.Join(configDir, windowsWorkerStateFileName)
		if err := os.WriteFile(workerPath, []byte(`{"name":"k2s-win-worker","ip":"172.19.1.101","proxy":"http://10.0.0.1:3128"}`), 0600); err != nil {
			t.Fatal(err)
		}
		if err := p.Build(ImageBuildConfig{InputFolder: ctxDir, ImageName: "winapp", Windows: true}); err != nil {
			t.Fatalf("Build with custom proxy failed: %v", err)
		}
		if !strings.Contains(strings.Join(psScripts, "\n"), "Install-WinDocker -Proxy 'http://10.0.0.1:3128'") {
			t.Errorf("expected custom proxy in Install-WinDocker call")
		}

		// Without proxy in windows-worker.json -> fallback to winDefaultProxy
		psScripts = nil
		if err := os.WriteFile(workerPath, []byte(`{"name":"k2s-win-worker","ip":"172.19.1.101"}`), 0600); err != nil {
			t.Fatal(err)
		}
		if err := p.Build(ImageBuildConfig{InputFolder: ctxDir, ImageName: "winapp", Windows: true}); err != nil {
			t.Fatalf("Build with default proxy failed: %v", err)
		}
		if !strings.Contains(strings.Join(psScripts, "\n"), "Install-WinDocker -Proxy '"+winDefaultProxy+"'") {
			t.Errorf("expected default proxy %q in Install-WinDocker call", winDefaultProxy)
		}
	})
}
