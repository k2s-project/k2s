// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"archive/tar"
	"compress/gzip"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/k2s-project/k2s/internal/definitions"
)

// fakeAddonCommands replaces linuxAddonCommandOutput for a test. kubectl calls
// are answered by the handler; sudo calls run the wrapped command without sudo
// so that archives are really created and extracted in temporary directories.
type fakeAddonCommands struct {
	calls   []string
	kubectl func(args []string) ([]byte, error)
}

func stubAddonCommands(t *testing.T, kubectl func(args []string) ([]byte, error)) *fakeAddonCommands {
	t.Helper()
	fake := &fakeAddonCommands{kubectl: kubectl}
	original := linuxAddonCommandOutput
	linuxAddonCommandOutput = func(name string, args ...string) ([]byte, error) {
		fake.calls = append(fake.calls, strings.Join(append([]string{name}, args...), " "))
		switch name {
		case "kubectl":
			if fake.kubectl == nil {
				t.Fatalf("unexpected kubectl call: %v", args)
			}
			return fake.kubectl(args)
		case "sudo":
			out, err := exec.Command(args[0], args[1:]...).CombinedOutput()
			if err != nil {
				return out, errors.New(string(out))
			}
			return out, nil
		default:
			t.Fatalf("unexpected command: %s %v", name, args)
			return nil, nil
		}
	}
	t.Cleanup(func() { linuxAddonCommandOutput = original })
	return fake
}

func (f *fakeAddonCommands) kubectlCalls() []string {
	var calls []string
	for _, call := range f.calls {
		if strings.HasPrefix(call, "kubectl ") {
			calls = append(calls, strings.TrimPrefix(call, "kubectl "))
		}
	}
	return calls
}

func useRegistryDataDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	original := linuxRegistryDataDir
	linuxRegistryDataDir = dir
	t.Cleanup(func() { linuxRegistryDataDir = original })
	return dir
}

func newBackupTestProvider(t *testing.T, enabledAddons ...map[string]string) *linuxAddonProvider {
	t.Helper()
	configDir := t.TempDir()
	data, err := json.Marshal(map[string]any{"EnabledAddons": enabledAddons})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(configDir, definitions.K2sRuntimeConfigFileName), data, 0o600); err != nil {
		t.Fatal(err)
	}
	return &linuxAddonProvider{installDir: t.TempDir(), configDir: configDir}
}

func writeTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readBackupManifest(t *testing.T, backupDir string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(backupDir, addonBackupManifestFileName))
	if err != nil {
		t.Fatalf("backup.json not written: %v", err)
	}
	var manifest map[string]any
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatalf("backup.json is invalid: %v", err)
	}
	return manifest
}

func tarGzEntries(t *testing.T, path string) []string {
	t.Helper()
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	gz, err := gzip.NewReader(file)
	if err != nil {
		t.Fatal(err)
	}
	reader := tar.NewReader(gz)
	var names []string
	for {
		header, err := reader.Next()
		if err == io.EOF {
			return names
		}
		if err != nil {
			t.Fatal(err)
		}
		names = append(names, strings.TrimSuffix(header.Name, "/"))
	}
}

func notFound(kind, name string) error {
	return errors.New(`Error from server (NotFound): ` + kind + ` "` + name + `" not found`)
}

const registryConfigMapJSON = `{
  "apiVersion": "v1",
  "kind": "ConfigMap",
  "metadata": {"name": "registry-config", "namespace": "registry", "resourceVersion": "4711", "managedFields": [{"manager": "kubectl"}]},
  "data": {"config.yml": "version: 0.1\n"}
}`

func TestBackup_RejectsAddonsWithoutLinuxImplementation(t *testing.T) {
	fake := stubAddonCommands(t, nil)
	p := newBackupTestProvider(t, map[string]string{"Name": "monitoring"})
	backupDir := t.TempDir()

	err := p.Backup(AddonBackupConfig{AddonName: "monitoring", Implementation: "monitoring", BackupDir: backupDir})

	if !errors.Is(err, ErrNotSupported) || !strings.Contains(err.Error(), "'ingress nginx', 'ingress traefik', 'registry'") {
		t.Fatalf("expected NotSupportedError listing the supported addons, got: %v", err)
	}
	if len(fake.calls) != 0 {
		t.Fatalf("expected no commands, got: %v", fake.calls)
	}
	if _, err := os.Stat(filepath.Join(backupDir, addonBackupManifestFileName)); !os.IsNotExist(err) {
		t.Fatalf("expected no backup.json, got stat error: %v", err)
	}
}

func TestBackup_RequiresEnabledAddon(t *testing.T) {
	fake := stubAddonCommands(t, nil)
	p := newBackupTestProvider(t, map[string]string{"Name": "ingress", "Implementation": "traefik"})

	err := p.Backup(AddonBackupConfig{AddonName: "ingress", Implementation: "nginx", BackupDir: t.TempDir()})

	if err == nil || !strings.Contains(err.Error(), "addon 'ingress nginx' is not enabled") {
		t.Fatalf("expected not-enabled error, got: %v", err)
	}
	if len(fake.calls) != 0 {
		t.Fatalf("expected no commands, got: %v", fake.calls)
	}
}

func TestBackup_RegistryArchivesRepositoryAndMinimalConfigMap(t *testing.T) {
	dataDir := useRegistryDataDir(t)
	writeTestFile(t, filepath.Join(dataDir, "repository", "docker", "registry", "v2", "blobs", "data"), "layer")
	writeTestFile(t, filepath.Join(dataDir, "auth", "htpasswd"), "secret")
	stubAddonCommands(t, func(args []string) ([]byte, error) {
		if strings.Join(args, " ") != "get configmap registry-config -n registry -o json" {
			t.Fatalf("unexpected kubectl call: %v", args)
		}
		return []byte(registryConfigMapJSON), nil
	})
	p := newBackupTestProvider(t, map[string]string{"Name": "registry"})
	backupDir := t.TempDir()

	if err := p.Backup(AddonBackupConfig{AddonName: "registry", Implementation: "registry", BackupDir: backupDir}); err != nil {
		t.Fatalf("Backup() failed: %v", err)
	}

	manifest := readBackupManifest(t, backupDir)
	if manifest["addon"] != "registry" || manifest["k2sVersion"] == "" || manifest["createdAt"] == "" {
		t.Fatalf("unexpected backup.json: %v", manifest)
	}
	if _, ok := manifest["implementation"]; ok {
		t.Fatalf("single-implementation addon must not record an implementation: %v", manifest)
	}
	if files, _ := json.Marshal(manifest["files"]); string(files) != `["registry-repository.tar.gz","registry-config.json"]` {
		t.Fatalf("unexpected files: %s", files)
	}

	entries := tarGzEntries(t, filepath.Join(backupDir, registryRepositoryArchive))
	if !slices.Contains(entries, "repository/docker/registry/v2/blobs/data") {
		t.Fatalf("archive must keep the 'repository/' prefix used by Windows backups, got: %v", entries)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry, "auth") {
			t.Fatalf("archive must only contain the repository, got: %v", entries)
		}
	}

	var configMap map[string]any
	data, err := os.ReadFile(filepath.Join(backupDir, registryConfigBackupFile))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &configMap); err != nil {
		t.Fatal(err)
	}
	metadata, _ := json.Marshal(configMap["metadata"])
	if string(metadata) != `{"name":"registry-config","namespace":"registry"}` {
		t.Fatalf("expected metadata without resourceVersion/managedFields, got: %s", metadata)
	}
	if dataField, _ := json.Marshal(configMap["data"]); string(dataField) != `{"config.yml":"version: 0.1\n"}` {
		t.Fatalf("unexpected ConfigMap data: %s", dataField)
	}
}

func TestBackup_RegistryWithoutConfigMapKeepsDataArchive(t *testing.T) {
	dataDir := useRegistryDataDir(t)
	writeTestFile(t, filepath.Join(dataDir, "repository", "blob"), "layer")
	stubAddonCommands(t, func(args []string) ([]byte, error) {
		return nil, notFound("configmaps", "registry-config")
	})
	p := newBackupTestProvider(t, map[string]string{"Name": "registry"})
	backupDir := t.TempDir()

	if err := p.Backup(AddonBackupConfig{AddonName: "registry", Implementation: "registry", BackupDir: backupDir}); err != nil {
		t.Fatalf("Backup() failed: %v", err)
	}

	if files, _ := json.Marshal(readBackupManifest(t, backupDir)["files"]); string(files) != `["registry-repository.tar.gz"]` {
		t.Fatalf("unexpected files: %s", files)
	}
}

func TestBackup_RegistryFailsOnConfigMapExportErrors(t *testing.T) {
	dataDir := useRegistryDataDir(t)
	writeTestFile(t, filepath.Join(dataDir, "repository", "blob"), "layer")
	stubAddonCommands(t, func(args []string) ([]byte, error) {
		return nil, errors.New("Unable to connect to the server: dial tcp 172.19.1.100:6443: connect: connection refused")
	})
	p := newBackupTestProvider(t, map[string]string{"Name": "registry"})
	backupDir := t.TempDir()

	err := p.Backup(AddonBackupConfig{AddonName: "registry", Implementation: "registry", BackupDir: backupDir})

	if err == nil || !strings.Contains(err.Error(), "backup of addon 'registry' failed") {
		t.Fatalf("expected backup failure, got: %v", err)
	}
	if _, err := os.Stat(filepath.Join(backupDir, addonBackupManifestFileName)); !os.IsNotExist(err) {
		t.Fatalf("expected no backup.json after a failed backup, got stat error: %v", err)
	}
}

func TestBackup_RegistryFailsWithoutRepositoryDirectory(t *testing.T) {
	useRegistryDataDir(t)
	fake := stubAddonCommands(t, nil)
	p := newBackupTestProvider(t, map[string]string{"Name": "registry"})

	err := p.Backup(AddonBackupConfig{AddonName: "registry", Implementation: "registry", BackupDir: t.TempDir()})

	if err == nil || !strings.Contains(err.Error(), "repository") {
		t.Fatalf("expected missing repository error, got: %v", err)
	}
	if len(fake.calls) != 0 {
		t.Fatalf("expected no commands, got: %v", fake.calls)
	}
}

func TestBackup_IngressNginxExportsControllerConfigAndSkipsMissingIngress(t *testing.T) {
	const configMapYAML = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: ingress-nginx-controller\n"
	fake := stubAddonCommands(t, func(args []string) ([]byte, error) {
		switch strings.Join(args, " ") {
		case "get namespace ingress-nginx":
			return []byte("namespace/ingress-nginx"), nil
		case "get configmap ingress-nginx-controller -n ingress-nginx -o yaml":
			return []byte(configMapYAML), nil
		case "get ingress nginx-cluster-local -n ingress-nginx -o yaml":
			return nil, notFound("ingresses.networking.k8s.io", "nginx-cluster-local")
		}
		t.Fatalf("unexpected kubectl call: %v", args)
		return nil, nil
	})
	p := newBackupTestProvider(t, map[string]string{"Name": "ingress", "Implementation": "nginx"})
	backupDir := t.TempDir()

	if err := p.Backup(AddonBackupConfig{AddonName: "ingress", Implementation: "nginx", BackupDir: backupDir}); err != nil {
		t.Fatalf("Backup() failed: %v", err)
	}

	manifest := readBackupManifest(t, backupDir)
	if manifest["addon"] != "ingress" || manifest["implementation"] != "nginx" {
		t.Fatalf("unexpected backup.json: %v", manifest)
	}
	if files, _ := json.Marshal(manifest["files"]); string(files) != `["ingress-nginx-controller-configmap.yaml"]` {
		t.Fatalf("unexpected files: %s", files)
	}
	if data, _ := os.ReadFile(filepath.Join(backupDir, "ingress-nginx-controller-configmap.yaml")); string(data) != configMapYAML {
		t.Fatalf("unexpected exported ConfigMap: %q", data)
	}
	if len(fake.kubectlCalls()) != 3 {
		t.Fatalf("unexpected kubectl calls: %v", fake.kubectlCalls())
	}
}

func TestBackup_IngressTraefikRequiresClusterLocalIngress(t *testing.T) {
	stubAddonCommands(t, func(args []string) ([]byte, error) {
		if strings.Join(args, " ") == "get namespace ingress-traefik" {
			return []byte("namespace/ingress-traefik"), nil
		}
		return nil, notFound("ingresses.networking.k8s.io", "traefik-cluster-local")
	})
	p := newBackupTestProvider(t, map[string]string{"Name": "ingress", "Implementation": "traefik"})

	err := p.Backup(AddonBackupConfig{AddonName: "ingress", Implementation: "traefik", BackupDir: t.TempDir()})

	if err == nil || !strings.Contains(err.Error(), "exporting ingress 'traefik-cluster-local' failed") {
		t.Fatalf("expected export failure, got: %v", err)
	}
}

func TestRestore_RejectsUnsupportedInputsBeforeEnablingTheAddon(t *testing.T) {
	validBackup := t.TempDir()
	writeTestFile(t, filepath.Join(validBackup, addonBackupManifestFileName), `{"k2sVersion":"v1","addon":"registry","files":[]}`)

	traversalBackup := t.TempDir()
	writeTestFile(t, filepath.Join(traversalBackup, addonBackupManifestFileName), `{"k2sVersion":"v1","addon":"registry","files":["../registry-repository.tar.gz"]}`)

	missingFileBackup := t.TempDir()
	writeTestFile(t, filepath.Join(missingFileBackup, addonBackupManifestFileName), `{"k2sVersion":"v1","addon":"registry","files":["registry-repository.tar.gz"]}`)

	for name, tc := range map[string]struct {
		cfg     AddonRestoreConfig
		want    string
		notSupp bool
	}{
		"unsupported addon": {
			cfg:     AddonRestoreConfig{AddonName: "dashboard", Implementation: "dashboard", BackupDir: validBackup},
			want:    "cannot be backed up or restored on Linux hosts",
			notSupp: true,
		},
		"infrastructure placement": {
			cfg:     AddonRestoreConfig{AddonName: "registry", Implementation: "registry", BackupDir: validBackup, InfraNodeSelector: "kubernetes.io/hostname=infra-1"},
			want:    "Windows-hosted",
			notSupp: true,
		},
		"path traversal": {
			cfg:  AddonRestoreConfig{AddonName: "registry", Implementation: "registry", BackupDir: traversalBackup},
			want: "is not a plain file name",
		},
		"missing backup file": {
			cfg:  AddonRestoreConfig{AddonName: "registry", Implementation: "registry", BackupDir: missingFileBackup},
			want: "backup file 'registry-repository.tar.gz' not found",
		},
		"missing backup.json": {
			cfg:  AddonRestoreConfig{AddonName: "registry", Implementation: "registry", BackupDir: t.TempDir()},
			want: "reading backup.json failed",
		},
	} {
		t.Run(name, func(t *testing.T) {
			fake := stubAddonCommands(t, nil)
			p := newBackupTestProvider(t)

			err := p.Restore(tc.cfg)

			if err == nil || !strings.Contains(err.Error(), tc.want) || errors.Is(err, ErrNotSupported) != tc.notSupp {
				t.Fatalf("expected error containing %q (not supported: %v), got: %v", tc.want, tc.notSupp, err)
			}
			if len(fake.calls) != 0 {
				t.Fatalf("expected no commands, got: %v", fake.calls)
			}
		})
	}
}

func TestRestoreRegistry_ReplacesRepositoryWithBackupContent(t *testing.T) {
	// Create the backup from one data directory ...
	sourceDir := useRegistryDataDir(t)
	writeTestFile(t, filepath.Join(sourceDir, "repository", "docker", "registry", "v2", "blobs", "data"), "layer")
	stubAddonCommands(t, func(args []string) ([]byte, error) {
		return []byte(registryConfigMapJSON), nil
	})
	backupDir := t.TempDir()
	files, err := backupRegistry(backupDir)
	if err != nil {
		t.Fatalf("backupRegistry() failed: %v", err)
	}

	// ... and restore it into another one that holds stale data.
	targetDir := useRegistryDataDir(t)
	writeTestFile(t, filepath.Join(targetDir, "repository", "stale"), "old")
	writeTestFile(t, filepath.Join(targetDir, "auth", "htpasswd"), "secret")
	fake := stubAddonCommands(t, func(args []string) ([]byte, error) {
		return nil, nil
	})

	if err := restoreRegistry(backupDir, files); err != nil {
		t.Fatalf("restoreRegistry() failed: %v", err)
	}

	if data, err := os.ReadFile(filepath.Join(targetDir, "repository", "docker", "registry", "v2", "blobs", "data")); err != nil || string(data) != "layer" {
		t.Fatalf("expected restored blob, got %q (%v)", data, err)
	}
	if _, err := os.Stat(filepath.Join(targetDir, "repository", "stale")); !os.IsNotExist(err) {
		t.Fatalf("expected stale repository content to be removed, got stat error: %v", err)
	}
	if _, err := os.Stat(filepath.Join(targetDir, "auth", "htpasswd")); err != nil {
		t.Fatalf("expected data outside the repository to be kept: %v", err)
	}

	want := []string{
		"scale statefulset registry -n registry --replicas=0",
		"get pods -n registry -l app=registry -o name",
		"apply --server-side --force-conflicts --field-manager=k2s-addon-restore -f " + filepath.Join(backupDir, registryConfigBackupFile),
		"scale statefulset registry -n registry --replicas=1",
		"rollout status statefulset registry -n registry --timeout=300s",
	}
	if got := fake.kubectlCalls(); !slices.Equal(got, want) {
		t.Fatalf("unexpected kubectl calls:\n got: %v\nwant: %v", got, want)
	}
}

func TestRestoreRegistry_RequiresRepositoryArchive(t *testing.T) {
	useRegistryDataDir(t)
	fake := stubAddonCommands(t, nil)

	err := restoreRegistry(t.TempDir(), []string{registryConfigBackupFile})

	if err == nil || !strings.Contains(err.Error(), "required archive 'registry-repository.tar.gz'") {
		t.Fatalf("expected missing archive error, got: %v", err)
	}
	if len(fake.calls) != 0 {
		t.Fatalf("expected no commands, got: %v", fake.calls)
	}
}

func TestApplyBackupFiles_ReplacesObjectsOnConflict(t *testing.T) {
	backupDir := t.TempDir()
	fake := stubAddonCommands(t, func(args []string) ([]byte, error) {
		if args[0] == "apply" {
			return nil, errors.New(`Error from server (Conflict): Operation cannot be fulfilled on configmaps "ingress-nginx-controller": the object has been modified`)
		}
		return nil, nil
	})

	if err := applyBackupFiles(backupDir, []string{"ingress-nginx-controller-configmap.yaml"}); err != nil {
		t.Fatalf("applyBackupFiles() failed: %v", err)
	}

	path := filepath.Join(backupDir, "ingress-nginx-controller-configmap.yaml")
	want := []string{"apply -f " + path, "replace --force -f " + path}
	if got := fake.kubectlCalls(); !slices.Equal(got, want) {
		t.Fatalf("unexpected kubectl calls:\n got: %v\nwant: %v", got, want)
	}
}

func TestRestoreRegistry_AbortsWhenPodsDoNotTerminate(t *testing.T) {
	dataDir := useRegistryDataDir(t)
	writeTestFile(t, filepath.Join(dataDir, "repository", "keep"), "data")
	backupDir := t.TempDir()
	writeTestFile(t, filepath.Join(backupDir, registryRepositoryArchive), "unused")

	previous := registryPodsTerminationTimeout
	registryPodsTerminationTimeout = 0
	t.Cleanup(func() { registryPodsTerminationTimeout = previous })

	fake := stubAddonCommands(t, func(args []string) ([]byte, error) {
		if args[0] == "get" {
			return []byte("pod/registry-0\n"), nil
		}
		return nil, nil
	})

	err := restoreRegistry(backupDir, []string{registryRepositoryArchive})

	if err == nil || !strings.Contains(err.Error(), "did not terminate") {
		t.Fatalf("expected termination timeout error, got: %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(dataDir, "repository", "keep")); statErr != nil {
		t.Fatalf("expected repository data to be untouched: %v", statErr)
	}
	want := []string{
		"scale statefulset registry -n registry --replicas=0",
		"get pods -n registry -l app=registry -o name",
		"scale statefulset registry -n registry --replicas=1",
	}
	if got := fake.kubectlCalls(); !slices.Equal(got, want) {
		t.Fatalf("unexpected kubectl calls:\n got: %v\nwant: %v", got, want)
	}
}

func TestApplyBackupFiles_DoesNotReplaceOnUnrelatedConflictText(t *testing.T) {
	fake := stubAddonCommands(t, func(args []string) ([]byte, error) {
		return nil, errors.New(`admission webhook denied the request: host conflicts with another ingress`)
	})

	err := applyBackupFiles(t.TempDir(), []string{"x.yaml"})

	if err == nil {
		t.Fatal("expected apply failure")
	}
	if len(fake.calls) != 1 {
		t.Fatalf("expected no replace attempt, got: %v", fake.calls)
	}
}

func TestApplyBackupFiles_FailsOnOtherErrors(t *testing.T) {
	fake := stubAddonCommands(t, func(args []string) ([]byte, error) {
		return nil, errors.New(`error: error validating "x.yaml": unknown field "foo"`)
	})

	err := applyBackupFiles(t.TempDir(), []string{"traefik-cluster-local-ingress.yaml", "other.yaml"})

	if err == nil || !strings.Contains(err.Error(), "applying 'traefik-cluster-local-ingress.yaml' failed") {
		t.Fatalf("expected apply failure, got: %v", err)
	}
	if len(fake.calls) != 1 {
		t.Fatalf("expected the restore to stop after the first failure, got: %v", fake.calls)
	}
}
