// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package nodepackage

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/utils"
	"github.com/spf13/pflag"
)

// gpuDebPackages mirrors the list downloaded by Get-NvidiaGpuDebPackagesFromInternet
// in common-setup.module.psm1 (the Windows/Hyper-V build path).
var gpuDebPackages = []string{
	"libnvidia-container1",
	"libnvidia-container-tools",
	"nvidia-container-toolkit-base",
	"nvidia-container-runtime",
	"nvidia-container-toolkit",
}

func validateRequiredDebPackages(dir string, required []string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return fmt.Errorf("could not read package directory %s: %w", dir, err)
	}
	found := make(map[string]bool)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".deb") {
			continue
		}
		if packageName, _, ok := strings.Cut(entry.Name(), "_"); ok {
			found[packageName] = true
		}
	}
	var missing []string
	for _, packageName := range required {
		if !found[packageName] {
			missing = append(missing, packageName)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("required packages are missing from %s: %s", dir, strings.Join(missing, ", "))
	}
	return nil
}

func runLogged(name string, args ...string) error {
	fmt.Printf("[NodePkg] + %s %s\n", name, strings.Join(args, " "))
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func runLoggedWithEnv(ctx context.Context, env map[string]string, name string, args ...string) error {
	fmt.Printf("[NodePkg] + %s %s (env: %d extra var(s))\n", name, strings.Join(args, " "), len(env))
	cmd := buildCommand(ctx, name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = environmentWithOverrides(env)
	return cmd.Run()
}

func buildCommand(ctx context.Context, name string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); err != nil && !errors.Is(err, syscall.ESRCH) {
			return err
		}
		return os.ErrProcessDone
	}
	cmd.WaitDelay = 5 * time.Second
	return cmd
}

func environmentWithOverrides(overrides map[string]string) []string {
	env := os.Environ()
	for key, value := range overrides {
		found := false
		for i, entry := range env {
			entryKey, _, ok := strings.Cut(entry, "=")
			if ok && entryKey == key {
				env[i] = key + "=" + value
				found = true
			}
		}
		if !found {
			env = append(env, key+"="+value)
		}
	}
	return env
}

// runShellWithEnv runs script with the given extra environment variables appended to
// the current process's environment, referenced in script as "$NAME" rather than
// interpolated into the script text - the values (e.g. a user-supplied --proxy) are
// never passed through shell string formatting/quoting, so they can't be used to
// inject shell commands no matter what characters they contain.
func runShellWithEnv(ctx context.Context, script string, env map[string]string) error {
	cmd := buildCommand(ctx, "bash", "-c", script)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = environmentWithOverrides(env)
	fmt.Printf("[NodePkg] + bash -c %q (env: %d extra var(s))\n", script, len(env))
	return cmd.Run()
}

// resolveDefaultK8sVersion extracts the version Get-DefaultK8sVersion returns, without
// invoking PowerShell. Mirrors the sed-based extraction already used by the Linux Host
// control-plane bootstrap in lib/modules/linux/node/packages.sh, so the Kubernetes
// version is read from a single source instead of being duplicated as a Go constant.
func resolveDefaultK8sVersion(installDir string) (string, error) {
	configModulePath := filepath.Join(installDir, "lib", "modules", "windows", "infra", "k2s.infra.module", "config", "config.module.psm1")
	data, err := os.ReadFile(configModulePath)
	if err != nil {
		return "", fmt.Errorf("could not read %s: %w", configModulePath, err)
	}
	re := regexp.MustCompile(`(?s)function Get-DefaultK8sVersion\s*\{.*?return\s+['"](v[0-9.]+)['"]`)
	m := re.FindSubmatch(data)
	if m == nil {
		return "", fmt.Errorf("could not resolve default Kubernetes version from %s", configModulePath)
	}
	return string(m[1]), nil
}

func countDebFiles(dir string) int {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	count := 0
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".deb") {
			count++
		}
	}
	return count
}

func validateBuildHostOS(targetOS, osReleasePath string) error {
	data, err := os.ReadFile(osReleasePath)
	if err != nil {
		return fmt.Errorf("could not determine this host's distribution from %s: %w", osReleasePath, err)
	}

	var id, versionID string
	for _, line := range strings.Split(string(data), "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		value = strings.Trim(value, `"'`)
		switch key {
		case "ID":
			id = value
		case "VERSION_ID":
			versionID = value
		}
	}

	hostOS := id + versionID
	if id == "" || versionID == "" || hostOS != targetOS {
		return fmt.Errorf("--%s '%s' does not match this host's distribution and release '%s'; run this command on a matching host instead", OSFlagName, targetOS, hostOS)
	}
	return nil
}

// downloadNvidiaGpuPackages mirrors Get-NvidiaGpuDebPackagesFromInternet, run locally
// instead of over SSH into a VM. targetPath and proxy are both ultimately attacker-
// controllable (--target-dir / --proxy, run as root) so neither is ever interpolated
// into shell source - both cross into bash only via $K2S_GPU_* environment variables.
func downloadNvidiaGpuPackages(ctx context.Context, targetPath, proxy, aptConfigPath string) error {
	if err := os.MkdirAll(targetPath, 0o755); err != nil {
		return err
	}
	env := map[string]string{
		"APT_CONFIG":          aptConfigPath,
		"K2S_GPU_TARGET_PATH": targetPath,
		"K2S_GPU_PROXY":       proxy,
	}

	if proxy != "" {
		proxyConf := fmt.Sprintf("Acquire::http::Proxy %q;\nAcquire::https::Proxy %q;\n", proxy, proxy)
		if err := os.WriteFile("/etc/apt/apt.conf.d/95k2s-proxy", []byte(proxyConf), 0o644); err != nil {
			return fmt.Errorf("could not write apt proxy config: %w", err)
		}
		defer os.Remove("/etc/apt/apt.conf.d/95k2s-proxy")
	}

	repoSetup := `
		curlProxy=""
		[ -n "$K2S_GPU_PROXY" ] && curlProxy="-x $K2S_GPU_PROXY"
		curl --retry 3 --retry-all-errors -fsSL https://nvidia.github.io/libnvidia-container/gpgkey $curlProxy \
			| gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg &&
		curl --retry 3 --retry-all-errors -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list $curlProxy \
			| sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
			| tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
	`
	if err := runShellWithEnv(ctx, repoSetup, env); err != nil {
		return fmt.Errorf("could not set up NVIDIA Container Toolkit apt repository: %w", err)
	}

	if err := runLoggedWithEnv(ctx, env, "apt-get", "update"); err != nil {
		return fmt.Errorf("apt-get update failed: %w", err)
	}

	for _, pkg := range gpuDebPackages {
		fmt.Printf("[NodePkg][GpuPkg] Downloading GPU package: %s\n", pkg)
		env["K2S_GPU_PKG"] = pkg
		if err := runShellWithEnv(ctx, `cd "$K2S_GPU_TARGET_PATH" && apt-get download "$K2S_GPU_PKG"`, env); err != nil {
			return fmt.Errorf("could not download %s: %w", pkg, err)
		}
		depsScript := `
			set -o pipefail
			cd "$K2S_GPU_TARGET_PATH" &&
			DEBIAN_FRONTEND=noninteractive apt-get --reinstall install -y --no-install-recommends --no-install-suggests \
				--simulate ./"$K2S_GPU_PKG"*.deb 2>/dev/null \
				| { grep 'Inst ' || true; } | cut -d ' ' -f 2 | sort -u | xargs -r apt-get download
		`
		if err := runShellWithEnv(ctx, depsScript, env); err != nil {
			return fmt.Errorf("could not download dependencies for %s: %w", pkg, err)
		}
	}

	count := countDebFiles(targetPath)
	fmt.Printf("[NodePkg][GpuPkg] GPU packages downloaded: %d\n", count)
	if count == 0 {
		return fmt.Errorf("no NVIDIA Container Toolkit packages were downloaded")
	}
	return nil
}

// buildZip writes srcRoot (recursively, under a "packages" prefix) into a new zip file
// at destZipPath. Callers are responsible for only exposing destZipPath to the rest of
// the system once this returns successfully - see its caller in BuildLinux.
func buildZip(ctx context.Context, destZipPath, srcRoot string) error {
	zf, err := os.CreateTemp(filepath.Dir(destZipPath), "."+filepath.Base(destZipPath)+".tmp-*")
	if err != nil {
		return fmt.Errorf("could not create temporary output for %s: %w", destZipPath, err)
	}
	tmpZipPath := zf.Name()
	defer os.Remove(tmpZipPath)

	zw := zip.NewWriter(zf)
	if err := zipDir(ctx, zw, srcRoot, "packages"); err != nil {
		zw.Close()
		zf.Close()
		return fmt.Errorf("could not zip packages: %w", err)
	}
	if err := zw.Close(); err != nil {
		zf.Close()
		return err
	}
	if err := zf.Sync(); err != nil {
		zf.Close()
		return err
	}
	if err := zf.Chmod(0o644); err != nil {
		zf.Close()
		return err
	}
	if err := zf.Close(); err != nil {
		return err
	}
	if err := os.Link(tmpZipPath, destZipPath); err != nil {
		return fmt.Errorf("could not finalize %s: %w", destZipPath, err)
	}
	return nil
}

func zipDir(ctx context.Context, zw *zip.Writer, srcRoot, destPrefix string) error {
	return filepath.Walk(srcRoot, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(srcRoot, path)
		if err != nil {
			return err
		}
		destPath := filepath.ToSlash(filepath.Join(destPrefix, rel))
		w, err := zw.Create(destPath)
		if err != nil {
			return err
		}
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()
		_, err = io.Copy(w, f)
		return err
	})
}

var hostAptFiles = []string{
	"/etc/apt/apt.conf.d/10sandbox-for-k2s",
	"/etc/apt/apt.conf.d/90k2s-proxy",
	"/etc/apt/apt.conf.d/95k2s-proxy",
	"/etc/apt/sources.list.d/kubernetes.list",
	"/etc/apt/sources.list.d/cri-o.list",
	"/etc/apt/sources.list.d/nvidia-container-toolkit.list",
	"/usr/share/keyrings/kubernetes-apt-keyring.gpg",
	"/usr/share/keyrings/cri-o-apt-keyring.gpg",
	"/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg",
}

type fileSnapshot struct {
	path              string
	content           []byte
	mode              os.FileMode
	uid               int
	gid               int
	linkTarget        string
	linkTargetPath    string
	linkTargetContent []byte
	linkTargetMode    os.FileMode
	linkTargetUID     int
	linkTargetGID     int
	linkTargetExists  bool
	exists            bool
}

func snapshotFiles(paths []string) ([]fileSnapshot, error) {
	snapshots := make([]fileSnapshot, 0, len(paths))
	for _, path := range paths {
		snapshot := fileSnapshot{path: path}
		info, err := os.Lstat(path)
		if err != nil {
			if os.IsNotExist(err) {
				snapshots = append(snapshots, snapshot)
				continue
			}
			return nil, fmt.Errorf("could not inspect %s: %w", path, err)
		}
		snapshot.exists = true
		snapshot.mode = info.Mode()
		if stat, ok := info.Sys().(*syscall.Stat_t); ok {
			snapshot.uid = int(stat.Uid)
			snapshot.gid = int(stat.Gid)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			snapshot.linkTarget, err = os.Readlink(path)
			if err == nil {
				targetPath := snapshot.linkTarget
				if !filepath.IsAbs(targetPath) {
					targetPath = filepath.Join(filepath.Dir(path), targetPath)
				}
				targetPath, err = filepath.Abs(targetPath)
				if err == nil {
					if resolvedPath, resolveErr := filepath.EvalSymlinks(path); resolveErr == nil {
						targetPath = resolvedPath
					}
					snapshot.linkTargetPath = targetPath
					targetInfo, targetErr := os.Stat(targetPath)
					if targetErr == nil {
						if !targetInfo.Mode().IsRegular() {
							return nil, fmt.Errorf("cannot snapshot non-regular APT symlink target %s", targetPath)
						}
						snapshot.linkTargetExists = true
						snapshot.linkTargetMode = targetInfo.Mode()
						if stat, ok := targetInfo.Sys().(*syscall.Stat_t); ok {
							snapshot.linkTargetUID = int(stat.Uid)
							snapshot.linkTargetGID = int(stat.Gid)
						}
						snapshot.linkTargetContent, err = os.ReadFile(targetPath)
					} else if !os.IsNotExist(targetErr) {
						return nil, fmt.Errorf("could not inspect APT symlink target %s: %w", targetPath, targetErr)
					}
				}
			}
		} else if info.Mode().IsRegular() {
			snapshot.content, err = os.ReadFile(path)
		} else {
			return nil, fmt.Errorf("cannot snapshot non-regular APT file %s", path)
		}
		if err != nil {
			return nil, fmt.Errorf("could not snapshot %s: %w", path, err)
		}
		snapshots = append(snapshots, snapshot)
	}
	return snapshots, nil
}

func restoreFiles(snapshots []fileSnapshot) error {
	var restoreErr error
	for _, snapshot := range snapshots {
		if !snapshot.exists {
			if err := os.Remove(snapshot.path); err != nil && !os.IsNotExist(err) {
				restoreErr = errors.Join(restoreErr, fmt.Errorf("could not remove %s: %w", snapshot.path, err))
			}
			continue
		}

		if snapshot.mode&os.ModeSymlink != 0 {
			if snapshot.linkTargetPath != "" {
				if snapshot.linkTargetExists {
					if err := restoreRegularFile(snapshot.linkTargetPath, snapshot.linkTargetContent, snapshot.linkTargetMode, snapshot.linkTargetUID, snapshot.linkTargetGID); err != nil {
						restoreErr = errors.Join(restoreErr, fmt.Errorf("could not restore symlink target %s: %w", snapshot.linkTargetPath, err))
						continue
					}
				} else if err := os.Remove(snapshot.linkTargetPath); err != nil && !os.IsNotExist(err) {
					restoreErr = errors.Join(restoreErr, fmt.Errorf("could not remove new symlink target %s: %w", snapshot.linkTargetPath, err))
					continue
				}
			}
			if err := os.Remove(snapshot.path); err != nil && !os.IsNotExist(err) {
				restoreErr = errors.Join(restoreErr, fmt.Errorf("could not replace %s: %w", snapshot.path, err))
				continue
			}
			if err := os.Symlink(snapshot.linkTarget, snapshot.path); err != nil {
				restoreErr = errors.Join(restoreErr, fmt.Errorf("could not restore symlink %s: %w", snapshot.path, err))
			}
			continue
		}

		if err := restoreRegularFile(snapshot.path, snapshot.content, snapshot.mode, snapshot.uid, snapshot.gid); err != nil {
			restoreErr = errors.Join(restoreErr, fmt.Errorf("could not restore %s: %w", snapshot.path, err))
		}
	}
	return restoreErr
}

func restoreRegularFile(path string, content []byte, mode os.FileMode, uid, gid int) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".k2s-apt-restore-*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	if _, err = temp.Write(content); err == nil {
		err = temp.Chmod(mode.Perm())
	}
	if err == nil {
		if current, statErr := os.Stat(tempPath); statErr == nil {
			if currentUID, currentGID, ok := fileOwner(current); ok &&
				(currentUID != uid || currentGID != gid) {
				err = os.Chown(tempPath, uid, gid)
			}
		}
	}
	closeErr := temp.Close()
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(tempPath, path)
	}
	if err != nil {
		os.Remove(tempPath)
	}
	return err
}

func fileOwner(info os.FileInfo) (uid, gid int, ok bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, 0, false
	}
	return int(stat.Uid), int(stat.Gid), true
}

// BuildLinux builds a Linux node package natively on the build host: no Hyper-V VM, no
// SSH. The host's own apt is used to download .deb packages for its own (running)
// architecture, which is what makes arm64 node packages possible at all --
// New-K2sNodePackage.ps1 can only ever build amd64 packages because it provisions an
// x86 Hyper-V guest, and Hyper-V cannot run an arm64 guest on an x86 host.
// Dependency resolution uses an isolated empty package database so installed build-host
// packages cannot be omitted from the resulting offline package.
//
// Unlike the Windows-built package, this does not pre-stage container images as OCI
// archives: 'k2s node add' with a package built here still needs network access to
// pull Kubernetes/flannel/GPU images at join time. Only the .deb packages are bundled
// for offline use. This is a deliberate, documented gap for the initial arm64 support
// (see docs/op-manual/creating-offline-package.md), not an oversight.
func BuildLinux(flags *pflag.FlagSet, targetDir, zipName, proxy string) (buildErr error) {
	if targetDir == "" {
		return fmt.Errorf("required flag(s) \"target-dir\" not set")
	}
	if zipName == "" {
		return fmt.Errorf("required flag(s) \"name\" not set")
	}

	osName := flags.Lookup(OSFlagName).Value.String()
	arch := flags.Lookup(ArchFlagName).Value.String()
	includeGpu, _ := flags.GetBool(IncludeGpuFlagName)

	if os.Geteuid() != 0 {
		return fmt.Errorf("building a node package natively requires root privileges (sudo)")
	}

	actualArchRaw, err := exec.Command("dpkg", "--print-architecture").Output()
	if err != nil {
		return fmt.Errorf("could not determine this host's architecture via dpkg: %w", err)
	}
	actualArch := strings.TrimSpace(string(actualArchRaw))
	if actualArch != arch {
		return fmt.Errorf("--%s '%s' does not match this host's architecture '%s'; there is no cross-build path for node packages, run this command on a %s host instead", ArchFlagName, arch, actualArch, arch)
	}

	if err := validateBuildHostOS(osName, "/etc/os-release"); err != nil {
		return err
	}

	installDir := utils.InstallDir()
	scriptsDir := filepath.Join(installDir, "cfg", "nodeextension", osName, "scripts")
	if _, err := os.Stat(scriptsDir); err != nil {
		return fmt.Errorf("no node-extension scripts found for --%s %s (%s): %w", OSFlagName, osName, scriptsDir, err)
	}

	k8sVersion, err := resolveDefaultK8sVersion(installDir)
	if err != nil {
		return err
	}

	zipTarget := filepath.Join(targetDir, zipName)
	if _, err := os.Stat(zipTarget); err == nil {
		fmt.Printf("[NodePkg] Package already exists: %s\n", zipTarget)
		return nil
	}

	stagingDir, err := os.MkdirTemp("", "k2s-node-pkg-")
	if err != nil {
		return fmt.Errorf("could not create staging directory: %w", err)
	}
	defer os.RemoveAll(stagingDir)

	packagesByOsDir := filepath.Join(stagingDir, "packages", osName)
	k8sPkgDir := filepath.Join(packagesByOsDir, "kubernetes")
	buildahPkgDir := filepath.Join(packagesByOsDir, "buildah")
	gpuPkgDir := filepath.Join(packagesByOsDir, "nvidia-gpu")
	for _, d := range []string{k8sPkgDir, buildahPkgDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return fmt.Errorf("could not create %s: %w", d, err)
		}
	}

	aptStateDir := filepath.Join(stagingDir, "apt-state")
	for _, d := range []string{
		filepath.Join(aptStateDir, "lists", "partial"),
		filepath.Join(aptStateDir, "cache", "archives", "partial"),
	} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return fmt.Errorf("could not create isolated APT state directory %s: %w", d, err)
		}
	}
	aptStatusPath := filepath.Join(aptStateDir, "status")
	if err := os.WriteFile(aptStatusPath, nil, 0o644); err != nil {
		return fmt.Errorf("could not create isolated APT package database: %w", err)
	}
	aptConfigPath := filepath.Join(aptStateDir, "apt.conf")
	aptConfig := fmt.Sprintf(
		"Dir::State::status %q;\nDir::State::extended_states %q;\nDir::State::lists %q;\nDir::Cache %q;\nDir::Cache::archives %q;\n",
		aptStatusPath,
		filepath.Join(aptStateDir, "extended_states"),
		filepath.Join(aptStateDir, "lists"),
		filepath.Join(aptStateDir, "cache"),
		filepath.Join(aptStateDir, "cache", "archives"),
	)
	if err := os.WriteFile(aptConfigPath, []byte(aptConfig), 0o600); err != nil {
		return fmt.Errorf("could not create isolated APT configuration: %w", err)
	}

	aptSnapshots, err := snapshotFiles(hostAptFiles)
	if err != nil {
		return fmt.Errorf("could not snapshot host APT files: %w", err)
	}
	defer func() {
		if err := restoreFiles(aptSnapshots); err != nil {
			buildErr = errors.Join(buildErr, fmt.Errorf("could not restore host APT files: %w", err))
		}
	}()

	buildCtx, stopOnSignal := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopOnSignal()

	downloadEnv := map[string]string{
		"APT_CONFIG":                      aptConfigPath,
		"K2S_APT_CONFIG":                  aptConfigPath,
		"K2S_PACKAGE_DOWNLOAD_ONLY":       "true",
		"K2S_DISABLE_ZSCALER_CERT_IMPORT": "true",
	}
	fmt.Printf("[NodePkg] === Downloading Kubernetes packages (k8sVersion=%s, arch=%s) ===\n", k8sVersion, arch)
	if err := runLoggedWithEnv(buildCtx, downloadEnv, "bash", filepath.Join(scriptsDir, "download-k8s-packages.sh"), k8sPkgDir, k8sVersion, proxy); err != nil {
		return fmt.Errorf("kubernetes package download failed: %w", err)
	}

	fmt.Println("[NodePkg] === Downloading buildah packages ===")
	if err := runLoggedWithEnv(buildCtx, downloadEnv, "bash", filepath.Join(scriptsDir, "download-buildah-packages.sh"), buildahPkgDir, proxy); err != nil {
		return fmt.Errorf("buildah package download failed: %w", err)
	}

	if includeGpu {
		if err := os.MkdirAll(gpuPkgDir, 0o755); err != nil {
			return err
		}
		fmt.Println("[NodePkg] === Downloading NVIDIA Container Toolkit packages (GPU support) ===")
		if err := downloadNvidiaGpuPackages(buildCtx, gpuPkgDir, proxy, aptConfigPath); err != nil {
			return fmt.Errorf("GPU package download failed: %w", err)
		}
	}

	if err := buildCtx.Err(); err != nil {
		return fmt.Errorf("node package build interrupted: %w", err)
	}

	k8sDebCount := countDebFiles(k8sPkgDir)
	buildahDebCount := countDebFiles(buildahPkgDir)
	fmt.Printf("[NodePkg] Local package counts: kubernetes=%d, buildah=%d\n", k8sDebCount, buildahDebCount)
	if err := validateRequiredDebPackages(k8sPkgDir, []string{"cri-o", "cri-tools", "kubeadm", "kubectl", "kubelet"}); err != nil {
		return err
	}
	if err := validateRequiredDebPackages(buildahPkgDir, []string{"buildah"}); err != nil {
		return err
	}

	fmt.Println("[NodePkg] === Creating output zip ===")
	if err := os.MkdirAll(targetDir, 0o755); err != nil {
		return fmt.Errorf("could not create target directory: %w", err)
	}
	// Build the zip under a temp name and rename into place only once it's fully
	// written: a partial zip left at zipTarget after a failed/interrupted run would
	// otherwise be mistaken for a finished package by the "already exists" check above
	// on the next invocation.
	if err := buildZip(buildCtx, zipTarget, filepath.Join(stagingDir, "packages")); err != nil {
		return err
	}

	gpuMsg := ""
	if includeGpu {
		gpuMsg = " (with GPU support)"
	}
	fmt.Printf("[NodePkg] Node package zip created%s: %s\n", gpuMsg, zipTarget)
	fmt.Printf("[NodePkg] Package creation for '%s'/'%s' completed successfully.\n", osName, arch)
	return nil
}
