// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/host"
	kJson "github.com/k2s-project/k2s/internal/json"
	"github.com/k2s-project/k2s/internal/output"
	"github.com/k2s-project/k2s/internal/providers/bash"
)

const (
	defaultLinuxRegistriesDir = "/etc/containers/registries.conf.d"
	defaultContainersAuthFile = "/root/.config/containers/auth.json"
)

type linuxImageProvider struct {
	installDir string
	configDir  string
	stdWriter  output.StreamWriter
	winWorker  *winWorkerClient

	// Optional hooks for unit testing; nil uses production defaults.
	localRunner     cmdRunner
	runScriptFn     func(script string, showOutput bool, args ...string) error
	linuxImagesFn   func(nodeName string) ([]ContainerImage, error)
	httpClient      *http.Client
	registriesDir   string
	authFilePath    string
	clusterActiveFn func(ctx context.Context) bool
}

func newLinuxImageProvider(cfg ProviderConfig) *linuxImageProvider {
	return &linuxImageProvider{
		installDir: cfg.InstallDir,
		configDir:  cfg.ConfigDir,
		stdWriter:  cfg.StdWriter,
		winWorker:  newWinWorkerClient(cfg.InstallDir, cfg.ConfigDir, cfg.StdWriter),
	}
}

func (p *linuxImageProvider) worker() *winWorkerClient {
	if p.winWorker == nil {
		p.winWorker = newWinWorkerClient(p.installDir, p.configDir, p.stdWriter)
	}
	return p.winWorker
}

func (p *linuxImageProvider) effectiveLocalRunner() cmdRunner {
	if p.localRunner != nil {
		return p.localRunner
	}
	return &execCmdRunner{}
}

func (p *linuxImageProvider) effectiveHTTPClient(timeout time.Duration) *http.Client {
	if p.httpClient != nil {
		return p.httpClient
	}
	return &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
		Timeout: timeout,
	}
}

func (p *linuxImageProvider) effectiveRegistriesDir() string {
	if p.registriesDir != "" {
		return p.registriesDir
	}
	return defaultLinuxRegistriesDir
}

func (p *linuxImageProvider) effectiveAuthFilePath() string {
	if p.authFilePath != "" {
		return p.authFilePath
	}
	return defaultContainersAuthFile
}

type capturingStreamWriter struct {
	delegate output.StreamWriter
	buf      bytes.Buffer
}

func (w *capturingStreamWriter) WriteStdOut(message string) {
	w.buf.WriteString(message)
	w.buf.WriteByte('\n')
	if w.delegate != nil {
		w.delegate.WriteStdOut(message)
	}
}

func (w *capturingStreamWriter) WriteStdErr(message string) {
	w.buf.WriteString(message)
	w.buf.WriteByte('\n')
	if w.delegate != nil {
		w.delegate.WriteStdErr(message)
	}
}

func (w *capturingStreamWriter) Flush() {
	if w.delegate != nil {
		w.delegate.Flush()
	}
}

func (p *linuxImageProvider) runScript(script string, showOutput bool, args ...string) error {
	if p.runScriptFn != nil {
		return p.runScriptFn(script, showOutput, args...)
	}
	capture := &capturingStreamWriter{delegate: p.stdWriter}
	err := bash.NewScript(script).
		WithArgs(args...).
		WithShowLogs(showOutput).
		WithStdWriter(capture).
		Exec()
	if err != nil {
		out := strings.TrimSpace(capture.buf.String())
		if out != "" {
			return fmt.Errorf("%w: %s", err, out)
		}
		return err
	}
	return nil
}

func (p *linuxImageProvider) runLocalCmd(ctx context.Context, showOutput bool, name string, args ...string) (string, error) {
	var stdoutBuf, stderrBuf bytes.Buffer
	var stdoutW io.Writer = &stdoutBuf
	var stderrW io.Writer = &stderrBuf
	if showOutput {
		stdoutW = io.MultiWriter(&stdoutBuf, os.Stdout)
		stderrW = io.MultiWriter(&stderrBuf, os.Stderr)
	}
	err := p.effectiveLocalRunner().Run(ctx, name, args, stdoutW, stderrW)
	out := strings.TrimSpace(stdoutBuf.String())
	if err != nil {
		errOut := strings.TrimSpace(stderrBuf.String())
		if errOut != "" {
			return out, fmt.Errorf("%s failed: %w: %s", name, err, errOut)
		}
		if out != "" {
			return out, fmt.Errorf("%s failed: %w: %s", name, err, out)
		}
		return out, fmt.Errorf("%s failed: %w", name, err)
	}
	return out, nil
}

func (p *linuxImageProvider) scriptPath(script string) string {
	return filepath.Join(p.installDir, "lib", "scripts", "linux", "debian", "host", "image", script)
}

func (p *linuxImageProvider) List(cfg ImageListConfig) (*ImageListResult, error) {
	ctx := context.Background()
	slog.Debug("[Image] Listing images (Linux)", "nodes", cfg.Nodes, "includeK8s", cfg.IncludeK8sImages)

	target, err := p.worker().resolveNodeTarget(ctx, splitNodeSelector(cfg.Nodes), false, true)
	if err != nil {
		return nil, err
	}

	explicitNodes := strings.TrimSpace(cfg.Nodes) != ""
	baseline := p.loadK8sBaselineImages()
	result := &ImageListResult{}

	var linuxErr, winErr error
	var succeededCount int

	if target.IncludeLinux {
		linuxImages, err := p.getLinuxImages(target.LinuxNodeName)
		if err != nil {
			linuxErr = fmt.Errorf("listing Linux node images: %w", err)
			if explicitNodes {
				return nil, linuxErr
			}
			slog.Warn("[Image] Could not list Linux node images", "error", err)
		} else {
			succeededCount++
			for _, img := range linuxImages {
				if img.Node == "" {
					img.Node = target.LinuxNodeName
				}
				if !cfg.IncludeK8sImages && isK8sBaselineImage(img.Repository, img.Tag, baseline) {
					continue
				}
				result.ContainerImages = append(result.ContainerImages, img)
			}
		}
	}

	if target.IncludeWindows {
		winImages, err := p.listWindowsImages(ctx, target.WindowsNodeName)
		if err != nil {
			winErr = fmt.Errorf("listing Windows worker images: %w", err)
			if explicitNodes {
				return nil, winErr
			}
			slog.Warn("[Image] Could not list Windows worker images", "error", err)
		} else {
			succeededCount++
			for _, img := range winImages {
				if img.Node == "" {
					img.Node = target.WindowsNodeName
				}
				if !cfg.IncludeK8sImages && (isK8sBaselineImage(img.Repository, img.Tag, baseline) || isWindowsPauseImage(img.Repository)) {
					continue
				}
				result.ContainerImages = append(result.ContainerImages, img)
			}
		}
	}

	if succeededCount == 0 && (linuxErr != nil || winErr != nil) {
		return nil, errors.Join(linuxErr, winErr)
	}

	registryName, pushed := p.queryLocalRegistry(ctx, target.LinuxNodeName)
	if registryName != "" {
		result.ContainerRegistry = registryName
		result.PushedImages = pushed
	}

	return result, nil
}

func (p *linuxImageProvider) Pull(cfg ImagePullConfig) error {
	ctx := context.Background()
	requestedNodes := splitNodeSelector(cfg.Nodes)
	target, err := p.worker().resolveNodeTarget(ctx, requestedNodes, cfg.Windows, false)
	if err != nil {
		return err
	}

	var linuxErr error
	if target.IncludeLinux {
		slog.Info("[Image] Pulling image on Linux node", "image", cfg.ImageName)
		linuxErr = p.pullLinuxImage(ctx, cfg)
		if linuxErr != nil {
			// Auto-fallback to Windows worker on OS/platform mismatch when no explicit node or --windows was requested.
			if len(requestedNodes) == 0 && !cfg.Windows && !p.worker().isLinuxOnly() && isPlatformMismatchError(linuxErr) {
				slog.Info("[Image] Linux pull failed with platform mismatch; falling back to Windows worker", "image", cfg.ImageName, "error", linuxErr)
				return p.pullWindowsImage(ctx, cfg.ImageName, cfg.ShowOutput)
			}
			return linuxErr
		}
	}

	if target.IncludeWindows {
		slog.Info("[Image] Pulling image on Windows worker", "image", cfg.ImageName)
		if err := p.pullWindowsImage(ctx, cfg.ImageName, cfg.ShowOutput); err != nil {
			return err
		}
	}

	return nil
}

func (p *linuxImageProvider) pullLinuxImage(ctx context.Context, cfg ImagePullConfig) error {
	script := p.scriptPath("Pull-Image.sh")
	if _, err := os.Stat(script); err == nil {
		return p.runScript(script, cfg.ShowOutput, "-n", cfg.ImageName)
	}
	_, err := p.runLocalCmd(ctx, cfg.ShowOutput, "crictl", "pull", cfg.ImageName)
	return err
}

func (p *linuxImageProvider) Remove(cfg ImageRemoveConfig) error {
	if cfg.FromRegistry {
		return p.removeFromRegistry(cfg)
	}

	ctx := context.Background()
	target, err := p.worker().resolveNodeTarget(ctx, splitNodeSelector(cfg.Nodes), false, true)
	if err != nil {
		return err
	}

	runLinux := target.IncludeLinux
	runWindows := target.IncludeWindows

	if target.IncludeLinux && target.IncludeWindows {
		onLinux, onWin, err := p.locateImageOnNodes(ctx, target, strings.TrimSpace(cfg.Nodes) != "", cfg.ImageId, cfg.ImageName)
		if err != nil {
			return err
		}
		if onLinux || onWin {
			runLinux = onLinux
			runWindows = onWin
		} else {
			return fmt.Errorf("image not found on cluster nodes (id=%q, name=%q)", cfg.ImageId, cfg.ImageName)
		}
	}

	var errs []error
	if runLinux {
		if err := p.removeLinuxImage(ctx, cfg); err != nil {
			errs = append(errs, err)
		}
	}
	if runWindows {
		if err := p.removeWindowsImage(ctx, cfg); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

func (p *linuxImageProvider) removeLinuxImage(ctx context.Context, cfg ImageRemoveConfig) error {
	ref := cfg.ImageId
	if ref == "" {
		ref = cfg.ImageName
	}
	slog.Info("[Image] Removing image on Linux node", "ref", ref)

	script := p.scriptPath("Remove-Image.sh")
	if _, err := os.Stat(script); err == nil {
		var args []string
		if cfg.ImageId != "" {
			args = append(args, "-i", cfg.ImageId)
		}
		if cfg.ImageName != "" {
			args = append(args, "-n", cfg.ImageName)
		}
		if cfg.Force {
			args = append(args, "--force")
		}
		return p.runScript(script, cfg.ShowOutput, args...)
	}

	if _, err := exec.LookPath("buildah"); err == nil {
		args := []string{"rmi"}
		if cfg.Force {
			args = append(args, "--force")
		}
		args = append(args, ref)
		if _, err := p.runLocalCmd(ctx, cfg.ShowOutput, "buildah", args...); err == nil {
			return nil
		}
		if !strings.HasPrefix(ref, "localhost/") {
			retryArgs := []string{"rmi"}
			if cfg.Force {
				retryArgs = append(retryArgs, "--force")
			}
			retryArgs = append(retryArgs, "localhost/"+ref)
			if _, err := p.runLocalCmd(ctx, cfg.ShowOutput, "buildah", retryArgs...); err == nil {
				return nil
			}
		}
	}

	if cfg.Force {
		selectors := []string{ref}
		if !strings.HasPrefix(ref, "localhost/") {
			selectors = append(selectors, "localhost/"+ref)
		}
		for _, sel := range selectors {
			out, err := p.runLocalCmd(ctx, false, "crictl", "ps", "-a", "-q", "--image", sel)
			if err == nil {
				for _, cid := range strings.Fields(out) {
					_, _ = p.runLocalCmd(ctx, false, "crictl", "stop", cid)
					_, _ = p.runLocalCmd(ctx, false, "crictl", "rm", cid)
				}
			}
		}
	}

	if _, err := p.runLocalCmd(ctx, cfg.ShowOutput, "crictl", "rmi", ref); err == nil {
		return nil
	} else if !strings.HasPrefix(ref, "localhost/") {
		if _, retryErr := p.runLocalCmd(ctx, cfg.ShowOutput, "crictl", "rmi", "localhost/"+ref); retryErr == nil {
			return nil
		}
		return err
	} else {
		return err
	}
}

func (p *linuxImageProvider) Build(cfg ImageBuildConfig) error {
	ctx := context.Background()
	if cfg.Windows {
		if p.worker().isLinuxOnly() {
			return errors.New("building Windows container images is not supported on a Linux-only installation")
		}
		slog.Info("[Image] Building Windows image on Windows worker", "name", cfg.ImageName, "input", cfg.InputFolder)
		return p.buildWindowsImage(ctx, cfg)
	}

	slog.Info("[Image] Building Linux image", "name", cfg.ImageName, "input", cfg.InputFolder)

	script := p.scriptPath("Build-Image.sh")
	if _, err := os.Stat(script); err == nil {
		args := []string{"-d", cfg.InputFolder}
		if cfg.Dockerfile != "" {
			args = append(args, "-f", cfg.Dockerfile)
		}
		if cfg.ImageName != "" {
			args = append(args, "-n", cfg.ImageName)
		}
		if cfg.ImageTag != "" {
			args = append(args, "-t", cfg.ImageTag)
		}
		if cfg.Push {
			args = append(args, "--push")
		}
		if len(cfg.BuildArgs) > 0 {
			keys := make([]string, 0, len(cfg.BuildArgs))
			for k := range cfg.BuildArgs {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				args = append(args, "--build-arg", k+"="+cfg.BuildArgs[k])
			}
		}
		return p.runScript(script, cfg.ShowOutput, args...)
	}

	args := []string{"bud", "--layers"}
	if cfg.Dockerfile != "" {
		args = append(args, "-f", cfg.Dockerfile)
	}
	name := cfg.ImageName
	if name != "" && cfg.ImageTag != "" {
		name = name + ":" + cfg.ImageTag
	}
	if name != "" {
		args = append(args, "-t", name)
	}
	for k, v := range cfg.BuildArgs {
		args = append(args, "--build-arg", k+"="+v)
	}
	args = append(args, cfg.InputFolder)

	if _, err := p.runLocalCmd(ctx, cfg.ShowOutput, "buildah", args...); err != nil {
		return fmt.Errorf("buildah build failed: %w", err)
	}

	if cfg.Push && name != "" {
		_, err := p.runLocalCmd(ctx, cfg.ShowOutput, "buildah", "push", name)
		return err
	}

	return nil
}

func (p *linuxImageProvider) Import(cfg ImageImportConfig) error {
	ctx := context.Background()
	target, err := p.worker().resolveNodeTarget(ctx, splitNodeSelector(cfg.Nodes), cfg.Windows, false)
	if err != nil {
		return err
	}

	if target.IncludeLinux {
		slog.Info("[Image] Importing image on Linux node", "tar", cfg.TarPath, "dir", cfg.DirPath)
		if err := p.importLinuxImage(ctx, cfg); err != nil {
			return err
		}
	}

	if target.IncludeWindows {
		slog.Info("[Image] Importing image on Windows worker", "tar", cfg.TarPath, "dir", cfg.DirPath)
		if err := p.importWindowsImages(ctx, cfg); err != nil {
			return err
		}
	}

	return nil
}

func (p *linuxImageProvider) importLinuxImage(ctx context.Context, cfg ImageImportConfig) error {
	script := p.scriptPath("Import-Image.sh")
	if _, err := os.Stat(script); err == nil {
		var args []string
		if cfg.TarPath != "" {
			args = append(args, "-t", cfg.TarPath)
		}
		if cfg.DirPath != "" {
			args = append(args, "-d", cfg.DirPath)
		}
		return p.runScript(script, cfg.ShowOutput, args...)
	}

	path := cfg.TarPath
	if path == "" {
		return errors.New("tar file path must be specified when Import-Image.sh is unavailable")
	}
	transport := "oci-archive:"
	if cfg.DockerArchive {
		transport = "docker-archive:"
	}
	_, err := p.runLocalCmd(ctx, cfg.ShowOutput, "buildah", "pull", transport+path)
	return err
}

func (p *linuxImageProvider) Export(cfg ImageExportConfig) error {
	ctx := context.Background()
	target, err := p.worker().resolveNodeTarget(ctx, splitNodeSelector(cfg.Nodes), false, true)
	if err != nil {
		return err
	}

	onLinux, onWindows, err := p.locateImageOnNodes(ctx, target, strings.TrimSpace(cfg.Nodes) != "", cfg.ImageId, cfg.ImageName)
	if err != nil {
		return err
	}
	if !onLinux && !onWindows {
		return fmt.Errorf("image not found (id=%q, name=%q)", cfg.ImageId, cfg.ImageName)
	}

	linuxOut := cfg.OutputPath
	winOut := cfg.OutputPath
	if onLinux && onWindows {
		linuxOut = formatDualExportPath(cfg.OutputPath, "linux")
		winOut = formatDualExportPath(cfg.OutputPath, "windows")
	}

	if onLinux {
		slog.Info("[Image] Exporting image from Linux node", "id", cfg.ImageId, "name", cfg.ImageName, "output", linuxOut)
		if err := p.exportLinuxImage(ctx, cfg, linuxOut); err != nil {
			return err
		}
	}
	if onWindows {
		slog.Info("[Image] Exporting image from Windows worker", "id", cfg.ImageId, "name", cfg.ImageName, "output", winOut)
		if err := p.exportWindowsImage(ctx, cfg, winOut); err != nil {
			return err
		}
	}

	return nil
}

func (p *linuxImageProvider) exportLinuxImage(ctx context.Context, cfg ImageExportConfig, outputPath string) error {
	script := p.scriptPath("Export-Image.sh")
	if _, err := os.Stat(script); err == nil {
		var args []string
		if cfg.ImageId != "" {
			args = append(args, "-i", cfg.ImageId)
		}
		if cfg.ImageName != "" {
			args = append(args, "-n", cfg.ImageName)
		}
		if outputPath != "" {
			args = append(args, "-t", outputPath)
		}
		if cfg.DockerArchive {
			args = append(args, "--docker-archive")
		}
		return p.runScript(script, cfg.ShowOutput, args...)
	}

	ref := cfg.ImageId
	if ref == "" {
		ref = cfg.ImageName
	}
	format := "oci-archive"
	if cfg.DockerArchive {
		format = "docker-archive"
	}
	_, err := p.runLocalCmd(ctx, cfg.ShowOutput, "buildah", "push", ref, fmt.Sprintf("%s:%s", format, outputPath))
	return err
}

func (p *linuxImageProvider) Tag(cfg ImageTagConfig) error {
	ctx := context.Background()
	target, err := p.worker().resolveNodeTarget(ctx, splitNodeSelector(cfg.Nodes), false, true)
	if err != nil {
		return err
	}

	runLinux := target.IncludeLinux
	runWindows := target.IncludeWindows

	if target.IncludeLinux && target.IncludeWindows {
		onLinux, onWin, err := p.locateImageOnNodes(ctx, target, strings.TrimSpace(cfg.Nodes) != "", cfg.ImageId, cfg.ImageName)
		if err != nil {
			return err
		}
		if !onLinux && !onWin {
			return fmt.Errorf("image not found on cluster nodes (id=%q, name=%q)", cfg.ImageId, cfg.ImageName)
		}
		runLinux = onLinux
		runWindows = onWin
	}

	if runLinux {
		if err := p.tagLinuxImage(ctx, cfg); err != nil {
			return err
		}
	}
	if runWindows {
		if err := p.tagWindowsImage(ctx, cfg); err != nil {
			return err
		}
	}
	return nil
}

func (p *linuxImageProvider) tagLinuxImage(ctx context.Context, cfg ImageTagConfig) error {
	ref := cfg.ImageId
	if ref == "" {
		ref = cfg.ImageName
	}
	target := cfg.TargetImageName
	if target == "" {
		target = cfg.ImageName
	}
	slog.Info("[Image] Tagging image on Linux node", "ref", ref, "target", target)

	script := p.scriptPath("Tag-Image.sh")
	if _, err := os.Stat(script); err == nil {
		var args []string
		if cfg.ImageId != "" {
			args = append(args, "-i", cfg.ImageId)
		}
		if cfg.ImageName != "" {
			args = append(args, "-n", cfg.ImageName)
		}
		if target != "" {
			args = append(args, "-t", target)
		}
		return p.runScript(script, cfg.ShowOutput, args...)
	}

	_, err := p.runLocalCmd(ctx, cfg.ShowOutput, "buildah", "tag", ref, target)
	return err
}

func (p *linuxImageProvider) Push(cfg ImagePushConfig) error {
	ctx := context.Background()
	target, err := p.worker().resolveNodeTarget(ctx, splitNodeSelector(cfg.Nodes), false, true)
	if err != nil {
		return err
	}

	runLinux := target.IncludeLinux
	runWindows := target.IncludeWindows

	if target.IncludeLinux && target.IncludeWindows {
		onLinux, onWin, err := p.locateImageOnNodes(ctx, target, strings.TrimSpace(cfg.Nodes) != "", cfg.ImageId, cfg.ImageName)
		if err != nil {
			return err
		}
		if !onLinux && !onWin {
			return fmt.Errorf("image not found on cluster nodes (id=%q, name=%q)", cfg.ImageId, cfg.ImageName)
		}
		runLinux = onLinux
		runWindows = onWin
	}

	if runLinux {
		if err := p.pushLinuxImage(ctx, cfg); err != nil {
			return err
		}
	}
	if runWindows {
		if err := p.pushWindowsImage(ctx, cfg); err != nil {
			return err
		}
	}
	return nil
}

func (p *linuxImageProvider) pushLinuxImage(ctx context.Context, cfg ImagePushConfig) error {
	ref := cfg.ImageId
	if ref == "" {
		ref = cfg.ImageName
	}
	slog.Info("[Image] Pushing image from Linux node", "ref", ref)

	script := p.scriptPath("Push-Image.sh")
	if _, err := os.Stat(script); err == nil {
		var args []string
		if cfg.ImageId != "" {
			args = append(args, "-i", cfg.ImageId)
		}
		if cfg.ImageName != "" {
			args = append(args, "-n", cfg.ImageName)
		}
		return p.runScript(script, cfg.ShowOutput, args...)
	}

	_, err := p.runLocalCmd(ctx, cfg.ShowOutput, "buildah", "push", ref)
	return err
}

func (p *linuxImageProvider) Repair(cfg ImageRepairConfig) error {
	ctx := context.Background()
	var issues []string

	if _, err := p.runLocalCmd(ctx, false, "systemctl", "is-active", "--quiet", "crio"); err != nil {
		issues = append(issues, fmt.Sprintf("Linux CRI-O service is not active: %v", err))
	}
	if _, err := p.runLocalCmd(ctx, false, "crictl", "images"); err != nil {
		issues = append(issues, fmt.Sprintf("Linux crictl images check failed: %v", err))
	}

	if !p.worker().isLinuxOnly() {
		if err := p.checkWindowsContainerdHealth(ctx); err != nil {
			issues = append(issues, fmt.Sprintf("Windows worker containerd check failed: %v", err))
		}
	}

	if len(issues) > 0 {
		return fmt.Errorf("container runtime health check failed:\n - %s", strings.Join(issues, "\n - "))
	}
	slog.Info("[Image] Container runtime health checks passed")
	return nil
}

func (p *linuxImageProvider) Clean(cfg ImageCleanConfig) error {
	ctx := context.Background()
	target, err := p.worker().resolveNodeTarget(ctx, splitNodeSelector(cfg.Nodes), false, true)
	if err != nil {
		return err
	}

	var errs []error
	if target.IncludeLinux {
		slog.Info("[Image] Cleaning non-K8s images on Linux node")
		if err := p.cleanLinuxImages(ctx, cfg); err != nil {
			errs = append(errs, err)
		}
	}
	if target.IncludeWindows {
		slog.Info("[Image] Cleaning non-K8s images on Windows worker")
		if err := p.cleanWindowsImages(ctx, cfg); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

func (p *linuxImageProvider) cleanLinuxImages(ctx context.Context, cfg ImageCleanConfig) error {
	script := p.scriptPath("Clean-Images.sh")
	if _, err := os.Stat(script); err == nil {
		return p.runScript(script, cfg.ShowOutput)
	}

	baseline := p.loadK8sBaselineImages()
	if _, err := exec.LookPath("buildah"); err == nil {
		buildahImages, err := listBuildahImages(getNodeName())
		if err == nil {
			cleaned := make(map[string]bool)
			for _, img := range buildahImages {
				if isK8sBaselineImage(img.Repository, img.Tag, baseline) || cleaned[img.ImageId] {
					continue
				}
				cleaned[img.ImageId] = true
				if _, err := p.runLocalCmd(ctx, cfg.ShowOutput, "buildah", "rmi", "-f", img.ImageId); err != nil {
					slog.Warn("[Image] Could not remove buildah image", "id", img.ImageId, "error", err)
				}
			}
		}
	}

	images, err := listCrictlImages(getNodeName())
	if err != nil {
		return err
	}

	for _, img := range images {
		if isK8sBaselineImage(img.Repository, img.Tag, baseline) {
			continue
		}
		if _, err := p.runLocalCmd(ctx, cfg.ShowOutput, "crictl", "rmi", img.ImageId); err != nil {
			slog.Warn("[Image] Could not remove crictl image", "id", img.ImageId, "error", err)
		}
	}

	return nil
}

func (p *linuxImageProvider) RegistryAdd(cfg ImageRegistryAddConfig) error {
	ctx := context.Background()
	target, err := p.worker().resolveNodeTarget(ctx, splitNodeSelector(cfg.Nodes), false, true)
	if err != nil {
		return err
	}

	if target.IncludeLinux {
		script := p.scriptPath(filepath.Join("registry", "Add-Registry.sh"))
		args := []string{"--registry", cfg.RegistryName}
		if cfg.Username != "" {
			args = append(args, "--username", cfg.Username)
		}
		if cfg.Password != "" {
			args = append(args, "--password", cfg.Password)
		}
		if cfg.SkipVerify {
			args = append(args, "--skip-verify")
		}
		if cfg.PlainHttp {
			args = append(args, "--plain-http")
		}

		if err := p.runScript(script, cfg.ShowOutput, args...); err != nil {
			return fmt.Errorf("failed to add registry '%s' on Linux node: %w", cfg.RegistryName, err)
		}
	}

	if target.IncludeWindows {
		if err := p.addWindowsRegistry(ctx, cfg); err != nil {
			return fmt.Errorf("failed to add registry '%s' on Windows worker: %w", cfg.RegistryName, err)
		}
	}

	if strings.TrimSpace(cfg.Nodes) == "" {
		return p.addRegistryToConfig(cfg.RegistryName)
	}
	return nil
}

func (p *linuxImageProvider) RegistryRemove(cfg ImageRegistryRemoveConfig) error {
	ctx := context.Background()
	target, err := p.worker().resolveNodeTarget(ctx, splitNodeSelector(cfg.Nodes), false, true)
	if err != nil {
		return err
	}

	if target.IncludeLinux {
		script := p.scriptPath(filepath.Join("registry", "Remove-Registry.sh"))
		if err := p.runScript(script, cfg.ShowOutput, "--registry", cfg.RegistryName); err != nil {
			return fmt.Errorf("failed to remove registry '%s' on Linux node: %w", cfg.RegistryName, err)
		}
	}

	if target.IncludeWindows {
		if err := p.removeWindowsRegistry(ctx, cfg); err != nil {
			return fmt.Errorf("failed to remove registry '%s' on Windows worker: %w", cfg.RegistryName, err)
		}
	}

	if strings.TrimSpace(cfg.Nodes) == "" {
		return p.removeRegistryFromConfig(cfg.RegistryName)
	}
	return nil
}

func (p *linuxImageProvider) RegistryList(ctx context.Context, cfg ImageRegistryListConfig) ([]string, error) {
	if len(cfg.Nodes) == 0 {
		regs := p.getRegistriesFromConfig()
		if regs == nil {
			return []string{}, nil
		}
		return regs, nil
	}

	target, err := p.worker().resolveNodeTarget(ctx, cfg.Nodes, false, true)
	if err != nil {
		return nil, err
	}

	seen := make(map[string]bool)
	var combined []string
	addUnique := func(items []string) {
		for _, item := range items {
			trimmed := strings.TrimSpace(item)
			if trimmed != "" && !seen[trimmed] {
				seen[trimmed] = true
				combined = append(combined, trimmed)
			}
		}
	}

	if target.IncludeLinux {
		linuxRegs, err := p.listLinuxRegistries()
		if err != nil {
			return nil, fmt.Errorf("listing registries on Linux node: %w", err)
		}
		addUnique(linuxRegs)
	}

	if target.IncludeWindows {
		winRegs, err := p.listWindowsRegistries(ctx)
		if err != nil {
			return nil, fmt.Errorf("listing registries on Windows worker: %w", err)
		}
		addUnique(winRegs)
	}

	sort.Strings(combined)
	if combined == nil {
		return []string{}, nil
	}
	return combined, nil
}

func (p *linuxImageProvider) ResetWinStorage(ctx context.Context, cfg ImageResetWinStorageConfig) error {
	if p.worker().isLinuxOnly() {
		return errors.New("Resetting WinContainerStorage for Linux-only setup is not supported.")
	}

	if p.isClusterRunning(ctx) {
		return errors.New("cluster is still running; please stop the cluster before resetting Windows container storage")
	}

	return p.resetWindowsStorage(ctx, cfg)
}

func (p *linuxImageProvider) isClusterRunning(ctx context.Context) bool {
	if p.clusterActiveFn != nil {
		return p.clusterActiveFn(ctx)
	}
	if _, err := p.runLocalCmd(ctx, false, "systemctl", "is-active", "--quiet", "kubelet"); err == nil {
		return true
	}
	if _, err := p.runLocalCmd(ctx, false, "kubectl", "cluster-info"); err == nil {
		return true
	}
	return false
}

func (p *linuxImageProvider) addRegistryToConfig(registry string) error {
	if p.configDir == "" {
		return nil
	}
	configPath := filepath.Join(p.configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := kJson.FromFile[map[string]any](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("loading setup config: %w", err)
	}

	var registries []any
	if rawRegs, ok := (*cfgMap)["Registries"]; ok && rawRegs != nil {
		if list, ok := rawRegs.([]any); ok {
			registries = append(registries, list...)
		}
	}

	exists := false
	for _, r := range registries {
		if s, ok := r.(string); ok && s == registry {
			exists = true
			break
		}
	}
	if !exists {
		registries = append(registries, registry)
	}

	(*cfgMap)["Registries"] = registries
	return kJson.ToFile(configPath, cfgMap)
}

func (p *linuxImageProvider) removeRegistryFromConfig(registry string) error {
	if p.configDir == "" {
		return nil
	}
	configPath := filepath.Join(p.configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := kJson.FromFile[map[string]any](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("loading setup config: %w", err)
	}

	var registries []any
	if rawRegs, ok := (*cfgMap)["Registries"]; ok && rawRegs != nil {
		if list, ok := rawRegs.([]any); ok {
			for _, r := range list {
				if s, ok := r.(string); ok && s == registry {
					continue
				}
				registries = append(registries, r)
			}
		}
	}

	(*cfgMap)["Registries"] = registries
	return kJson.ToFile(configPath, cfgMap)
}

// ---------- helpers ----------

func splitNodeSelector(nodes string) []string {
	if strings.TrimSpace(nodes) == "" {
		return nil
	}
	parts := strings.Split(nodes, ",")
	var out []string
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

func isPlatformMismatchError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	patterns := []string{
		"no image found in manifest list",
		"no matching manifest",
		"platform",
		"not match",
		"unsupported",
		"os/arch",
		"image os",
	}
	for _, pat := range patterns {
		if strings.Contains(msg, pat) {
			return true
		}
	}
	return strings.Contains(msg, " os ")
}

func formatDualExportPath(outputPath, suffix string) string {
	ext := filepath.Ext(outputPath)
	if ext == "" {
		return outputPath + "_" + suffix + ".tar"
	}
	base := strings.TrimSuffix(outputPath, ext)
	return base + "_" + suffix + ext
}

func (p *linuxImageProvider) getLinuxImages(nodeName string) ([]ContainerImage, error) {
	if p.linuxImagesFn != nil {
		return p.linuxImagesFn(nodeName)
	}
	return listLinuxImages(nodeName)
}

func (p *linuxImageProvider) locateImageOnNodes(ctx context.Context, target *nodeTarget, explicitNodes bool, imageID, imageName string) (onLinux bool, onWindows bool, err error) {
	var linuxErr, winErr error
	var succeededCount int

	if target.IncludeLinux {
		imgs, lErr := p.getLinuxImages(target.LinuxNodeName)
		if lErr != nil {
			linuxErr = fmt.Errorf("querying Linux node images: %w", lErr)
			if explicitNodes {
				return false, false, linuxErr
			}
			slog.Warn("[Image] Could not query Linux node images", "error", lErr)
		} else {
			succeededCount++
			for _, img := range imgs {
				if imageMatchesFilter(img, imageID, imageName) {
					onLinux = true
					break
				}
			}
		}
	}
	if target.IncludeWindows {
		imgs, wErr := p.listWindowsImages(ctx, target.WindowsNodeName)
		if wErr != nil {
			winErr = fmt.Errorf("querying Windows worker images: %w", wErr)
			if explicitNodes {
				return false, false, winErr
			}
			slog.Warn("[Image] Could not query Windows worker images", "error", wErr)
		} else {
			succeededCount++
			for _, img := range imgs {
				if imageMatchesFilter(img, imageID, imageName) {
					onWindows = true
					break
				}
			}
		}
	}
	if succeededCount == 0 && (linuxErr != nil || winErr != nil) {
		return false, false, errors.Join(linuxErr, winErr)
	}
	return onLinux, onWindows, nil
}

func imageMatchesFilter(img ContainerImage, imageID, imageName string) bool {
	if imageID != "" {
		cleanID := strings.TrimPrefix(strings.ToLower(strings.TrimSpace(imageID)), "sha256:")
		imgID := strings.TrimPrefix(strings.ToLower(strings.TrimSpace(img.ImageId)), "sha256:")
		if cleanID != "" && imgID != "" && (strings.HasPrefix(imgID, cleanID) || strings.HasPrefix(cleanID, imgID)) {
			return true
		}
	}
	if imageName != "" {
		want := strings.ToLower(strings.TrimSpace(imageName))
		repo := strings.ToLower(img.Repository)
		tag := strings.ToLower(img.Tag)
		full := repo + ":" + tag
		if full == want || repo == want {
			return true
		}
		if strings.TrimPrefix(full, "localhost/") == want || strings.TrimPrefix(repo, "localhost/") == want {
			return true
		}
		if strings.TrimPrefix(full, "docker.io/library/") == want || strings.TrimPrefix(repo, "docker.io/library/") == want {
			return true
		}
		if strings.TrimPrefix(full, "docker.io/") == want || strings.TrimPrefix(repo, "docker.io/") == want {
			return true
		}
		if !strings.Contains(lastPathSegment(want), ":") {
			wantLatest := want + ":latest"
			if full == wantLatest ||
				strings.TrimPrefix(full, "localhost/") == wantLatest ||
				strings.TrimPrefix(full, "docker.io/library/") == wantLatest ||
				strings.TrimPrefix(full, "docker.io/") == wantLatest {
				return true
			}
		}
	}
	return false
}

func listLinuxImages(nodeName string) ([]ContainerImage, error) {
	if nodeName == "" {
		nodeName = getNodeName()
	}
	var combined []ContainerImage
	seen := make(map[string]bool)

	addImages := func(images []ContainerImage) {
		for _, img := range images {
			key := fmt.Sprintf("%s:%s", img.Repository, img.Tag)
			if key != "<none>:<none>" {
				if seen[key] {
					continue
				}
				seen[key] = true
			} else {
				idKey := fmt.Sprintf("id:%s", img.ImageId)
				if seen[idKey] {
					continue
				}
				seen[idKey] = true
			}
			combined = append(combined, img)
		}
	}

	var buildahErr, crictlErr error
	if _, err := exec.LookPath("buildah"); err == nil {
		bImages, err := listBuildahImages(nodeName)
		if err == nil {
			addImages(bImages)
		} else {
			buildahErr = err
			slog.Debug("[Image] listBuildahImages failed", "error", err)
		}
	}

	if _, err := exec.LookPath("crictl"); err == nil {
		cImages, err := listCrictlImages(nodeName)
		if err == nil {
			addImages(cImages)
		} else {
			crictlErr = err
			slog.Debug("[Image] listCrictlImages failed", "error", err)
		}
	}

	if len(combined) == 0 && buildahErr != nil && crictlErr != nil {
		return nil, fmt.Errorf("listing images failed (buildah: %v, crictl: %v)", buildahErr, crictlErr)
	}

	// Filter out <none> entries for image IDs that have real tags
	hasRealTag := make(map[string]bool)
	for _, img := range combined {
		if img.Repository != "<none>" && img.Tag != "<none>" {
			hasRealTag[img.ImageId] = true
		}
	}

	var deduplicated []ContainerImage
	for _, img := range combined {
		if (img.Repository == "<none>" || img.Tag == "<none>") && hasRealTag[img.ImageId] {
			continue
		}
		deduplicated = append(deduplicated, img)
	}

	return deduplicated, nil
}

type flexibleSize string

func (f *flexibleSize) UnmarshalJSON(data []byte) error {
	if len(data) == 0 || string(data) == "null" {
		*f = ""
		return nil
	}

	var str string
	if err := json.Unmarshal(data, &str); err == nil {
		*f = flexibleSize(str)
		return nil
	}

	var i int64
	if err := json.Unmarshal(data, &i); err == nil {
		*f = flexibleSize(strconv.FormatInt(i, 10))
		return nil
	}

	var u uint64
	if err := json.Unmarshal(data, &u); err == nil {
		*f = flexibleSize(strconv.FormatUint(u, 10))
		return nil
	}

	var fl float64
	if err := json.Unmarshal(data, &fl); err == nil {
		if fl >= math.MinInt64 && fl <= math.MaxInt64 && math.Trunc(fl) == fl {
			*f = flexibleSize(strconv.FormatInt(int64(fl), 10))
		} else {
			*f = flexibleSize(strconv.FormatFloat(fl, 'f', -1, 64))
		}
		return nil
	}

	return fmt.Errorf("flexibleSize: cannot unmarshal %s", string(data))
}

func (f flexibleSize) String() string {
	return string(f)
}

func listBuildahImages(nodeName string) ([]ContainerImage, error) {
	if nodeName == "" {
		nodeName = getNodeName()
	}
	output, err := exec.Command("buildah", "images", "--json").Output()
	if err != nil {
		return nil, fmt.Errorf("buildah images: %w", err)
	}

	var rawImages []struct {
		Id    string       `json:"id"`
		Names []string     `json:"names"`
		Size  flexibleSize `json:"size"`
	}

	if err := json.Unmarshal(output, &rawImages); err != nil {
		return nil, fmt.Errorf("parsing buildah output: %w", err)
	}

	var images []ContainerImage
	for _, img := range rawImages {
		shortId := img.Id
		if len(shortId) > 12 {
			shortId = shortId[:12]
		}

		names := img.Names
		if len(names) == 0 {
			names = []string{"<none>:<none>"}
		}

		for _, repoTag := range names {
			repo, tag := splitRepoTag(repoTag)
			images = append(images, ContainerImage{
				ImageId:    shortId,
				Repository: repo,
				Tag:        tag,
				Node:       nodeName,
				Size:       string(img.Size),
			})
		}
	}

	return images, nil
}

func listCrictlImages(nodeName string) ([]ContainerImage, error) {
	if nodeName == "" {
		nodeName = getNodeName()
	}
	output, err := exec.Command("crictl", "images", "-o", "json").Output()
	if err != nil {
		return nil, fmt.Errorf("crictl images: %w", err)
	}
	return parseCrictlImagesJSON(output, nodeName)
}

func parseCrictlImagesJSON(data []byte, nodeName string) ([]ContainerImage, error) {
	var result struct {
		Images []struct {
			Id          string       `json:"id"`
			RepoTags    []string     `json:"repoTags"`
			RepoDigests []string     `json:"repoDigests"`
			Size        flexibleSize `json:"size"`
		} `json:"images"`
	}

	if err := json.Unmarshal(data, &result); err != nil {
		return nil, fmt.Errorf("parsing crictl output: %w", err)
	}

	var images []ContainerImage
	for _, img := range result.Images {
		shortId := strings.TrimPrefix(img.Id, "sha256:")
		if len(shortId) > 12 {
			shortId = shortId[:12]
		}

		tags := img.RepoTags
		if len(tags) == 0 {
			tags = []string{"<none>:<none>"}
		}

		for _, repoTag := range tags {
			repo, tag := splitRepoTag(repoTag)
			images = append(images, ContainerImage{
				ImageId:    shortId,
				Repository: repo,
				Tag:        tag,
				Node:       nodeName,
				Size:       string(img.Size),
			})
		}
	}

	return images, nil
}

func splitRepoTag(repoTag string) (repo string, tag string) {
	repo = "<none>"
	tag = "<none>"
	if repoTag != "" && repoTag != "<none>:<none>" {
		lastColon := strings.LastIndex(repoTag, ":")
		lastSlash := strings.LastIndex(repoTag, "/")
		if lastColon != -1 && lastColon > lastSlash {
			repo = repoTag[:lastColon]
			tag = repoTag[lastColon+1:]
		} else {
			repo = repoTag
		}
	}
	return repo, tag
}

func getNodeName() string {
	h, err := os.Hostname()
	if err == nil && h != "" {
		return strings.ToLower(h)
	}
	return "linux"
}

func (p *linuxImageProvider) loadK8sBaselineImages() map[string]bool {
	baseline := make(map[string]bool)
	if p.installDir == "" {
		return baseline
	}
	jsonPath := filepath.Join(p.installDir, "cfg", "kubernetes-images.json")
	data, err := os.ReadFile(jsonPath)
	if err != nil {
		return baseline
	}

	var strList []string
	if err := json.Unmarshal(data, &strList); err == nil {
		for _, item := range strList {
			if trimmed := strings.ToLower(strings.TrimSpace(item)); trimmed != "" {
				baseline[trimmed] = true
			}
		}
		return baseline
	}

	var objMap map[string]any
	if err := json.Unmarshal(data, &objMap); err == nil {
		for _, v := range objMap {
			if list, ok := v.([]any); ok {
				for _, elem := range list {
					if s, ok := elem.(string); ok {
						if trimmed := strings.ToLower(strings.TrimSpace(s)); trimmed != "" {
							baseline[trimmed] = true
						}
					}
				}
			}
		}
	}
	return baseline
}

func isK8sBaselineImage(repo, tag string, baseline map[string]bool) bool {
	if isK8sImage(repo) {
		return true
	}
	if len(baseline) == 0 {
		return false
	}
	lowerRepo := strings.ToLower(repo)
	if baseline[lowerRepo] {
		return true
	}
	if tag != "" && tag != "<none>" {
		if baseline[lowerRepo+":"+strings.ToLower(tag)] {
			return true
		}
	}
	return false
}

func isWindowsPauseImage(repo string) bool {
	lower := strings.ToLower(repo)
	return strings.Contains(lower, "pause-win") || strings.Contains(lower, "/pause")
}

func isK8sImage(repo string) bool {
	k8sPrefixes := []string{
		"registry.k8s.io/",
		"k8s.gcr.io/",
		"docker.io/flannel",
		"docker.io/calico",
		"quay.io/coreos",
		"shsk2s.azurecr.io/clusterip-webhook",
		"shsk2s.azurecr.io/pause",
	}
	for _, prefix := range k8sPrefixes {
		if strings.HasPrefix(repo, prefix) {
			return true
		}
	}
	return false
}

func (p *linuxImageProvider) listLinuxRegistries() ([]string, error) {
	regDir := p.effectiveRegistriesDir()
	entries, err := os.ReadDir(regDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}

	locRegex := regexp.MustCompile(`(?m)^\s*location\s*=\s*["']?([^"'\s]+)["']?`)
	var registries []string
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".conf") {
			continue
		}
		fname := entry.Name()
		if fname == "crio.conf" || fname == "shortnames.conf" || strings.HasPrefix(fname, "00-") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(regDir, fname))
		if err != nil {
			continue
		}
		if m := locRegex.FindSubmatch(data); len(m) > 1 {
			registries = append(registries, string(m[1]))
		} else {
			registries = append(registries, strings.TrimSuffix(fname, ".conf"))
		}
	}
	return registries, nil
}

func (p *linuxImageProvider) queryLocalRegistry(ctx context.Context, nodeName string) (string, []PushedImage) {
	var registryHost string
	for _, r := range p.getRegistriesFromConfig() {
		if r == "k2s.registry.local" || r == "k2s.registry.local:30500" || strings.HasPrefix(r, "k2s.registry.local:") {
			registryHost = r
			break
		}
	}
	if registryHost == "" {
		return "", nil
	}

	client := p.effectiveHTTPClient(3 * time.Second)
	authHeader := p.lookupRegistryBasicAuth(registryHost)

	var baseURLs []string
	if strings.Contains(registryHost, ":") {
		baseURLs = append(baseURLs, "http://"+registryHost)
	} else {
		baseURLs = append(baseURLs, "https://"+registryHost, "http://"+registryHost)
	}
	baseURLs = append(baseURLs, "http://127.0.0.1:30500")

	for _, baseURL := range baseURLs {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/v2/_catalog", nil)
		if err != nil {
			continue
		}
		if authHeader != "" {
			req.Header.Set("Authorization", authHeader)
		}
		resp, err := client.Do(req)
		if err != nil {
			continue
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			continue
		}
		var catalog struct {
			Repositories []string `json:"repositories"`
		}
		decErr := json.NewDecoder(resp.Body).Decode(&catalog)
		resp.Body.Close()
		if decErr != nil {
			continue
		}

		var pushed []PushedImage
		for _, repo := range catalog.Repositories {
			tagReq, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s/v2/%s/tags/list", baseURL, repo), nil)
			if err != nil {
				continue
			}
			if authHeader != "" {
				tagReq.Header.Set("Authorization", authHeader)
			}
			tagResp, err := client.Do(tagReq)
			if err != nil {
				continue
			}
			if tagResp.StatusCode != http.StatusOK {
				tagResp.Body.Close()
				continue
			}
			var tagList struct {
				Tags []string `json:"tags"`
			}
			tErr := json.NewDecoder(tagResp.Body).Decode(&tagList)
			tagResp.Body.Close()
			if tErr != nil {
				continue
			}
			for _, tag := range tagList.Tags {
				pushed = append(pushed, PushedImage{
					Name: fmt.Sprintf("%s/%s", registryHost, repo),
					Tag:  tag,
					Node: nodeName,
				})
			}
		}
		return registryHost, pushed
	}

	return registryHost, nil
}

func (p *linuxImageProvider) lookupRegistryBasicAuth(registryHost string) string {
	data, err := os.ReadFile(p.effectiveAuthFilePath())
	if err != nil {
		return ""
	}
	var authCfg struct {
		Auths map[string]struct {
			Auth     string `json:"auth"`
			Username string `json:"username"`
			Password string `json:"password"`
		} `json:"auths"`
	}
	if err := json.Unmarshal(data, &authCfg); err != nil {
		return ""
	}
	candidates := []string{
		registryHost,
		"https://" + registryHost,
		"http://" + registryHost,
	}
	for _, key := range candidates {
		if entry, ok := authCfg.Auths[key]; ok {
			if entry.Auth != "" {
				return "Basic " + entry.Auth
			}
			if entry.Username != "" {
				return "Basic " + base64.StdEncoding.EncodeToString([]byte(entry.Username+":"+entry.Password))
			}
		}
	}
	return ""
}

func (p *linuxImageProvider) getRegistriesFromConfig() []string {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := kJson.FromFile[map[string]any](configPath)
	if err != nil {
		return nil
	}
	var res []string
	if raw, ok := (*cfgMap)["Registries"]; ok && raw != nil {
		if list, ok := raw.([]any); ok {
			for _, item := range list {
				if s, ok := item.(string); ok {
					res = append(res, s)
				}
			}
		}
	}
	return res
}

func (p *linuxImageProvider) removeFromRegistry(cfg ImageRemoveConfig) error {
	imageName := cfg.ImageName
	if imageName == "" {
		return fmt.Errorf("image name is required to remove image from registry")
	}

	registryHost := "k2s.registry.local"
	registries := p.getRegistriesFromConfig()
	for _, r := range registries {
		if strings.Contains(r, "k2s.registry") {
			registryHost = r
			break
		}
	}

	trimmed := imageName
	if strings.HasPrefix(trimmed, registryHost+"/") {
		trimmed = strings.TrimPrefix(trimmed, registryHost+"/")
	} else if idx := strings.Index(trimmed, "/"); idx != -1 && strings.Contains(trimmed[:idx], ".") {
		registryHost = trimmed[:idx]
		trimmed = trimmed[idx+1:]
	}

	colonIdx := strings.LastIndex(trimmed, ":")
	if colonIdx == -1 {
		return fmt.Errorf("tag is required in image name to remove from registry: %s", imageName)
	}
	repo := trimmed[:colonIdx]
	tag := trimmed[colonIdx+1:]

	var urls []string
	if strings.Contains(registryHost, ":") {
		urls = append(urls, "http://"+registryHost)
	} else {
		urls = append(urls, "https://"+registryHost, "http://"+registryHost)
	}
	urls = append(urls, "http://127.0.0.1:30500", "http://k2s.registry.local:30500")

	client := p.effectiveHTTPClient(10 * time.Second)
	authHeader := p.lookupRegistryBasicAuth(registryHost)

	var lastErr error
	for _, baseURL := range urls {
		manifestURL := fmt.Sprintf("%s/v2/%s/manifests/%s", baseURL, repo, tag)
		req, err := http.NewRequest(http.MethodGet, manifestURL, nil)
		if err != nil {
			lastErr = err
			continue
		}
		req.Header.Set("Accept", "application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json")
		if authHeader != "" {
			req.Header.Set("Authorization", authHeader)
		}
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("registry %s returned status %d for manifest", baseURL, resp.StatusCode)
			continue
		}

		digest := resp.Header.Get("Docker-Content-Digest")
		deleteRef := digest
		if deleteRef == "" {
			deleteRef = tag
		}

		delURL := fmt.Sprintf("%s/v2/%s/manifests/%s", baseURL, repo, deleteRef)
		delReq, err := http.NewRequest(http.MethodDelete, delURL, nil)
		if err != nil {
			lastErr = err
			continue
		}
		if authHeader != "" {
			delReq.Header.Set("Authorization", authHeader)
		}
		delResp, err := client.Do(delReq)
		if err != nil {
			lastErr = err
			continue
		}
		delResp.Body.Close()
		if delResp.StatusCode == http.StatusOK || delResp.StatusCode == http.StatusAccepted || delResp.StatusCode == http.StatusNoContent {
			slog.Info("[Image] Successfully removed image from registry", "image", imageName, "url", delURL)
			return nil
		}
		lastErr = fmt.Errorf("registry returned status %d when deleting manifest", delResp.StatusCode)
	}

	return fmt.Errorf("failed to remove image '%s' from registry: %w", imageName, lastErr)
}
