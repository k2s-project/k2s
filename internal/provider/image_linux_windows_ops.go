// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"archive/tar"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	winCrictlExe     = `C:\k2s\bin\crictl.exe`
	winNerdctlExe    = `C:\k2s\bin\nerdctl.exe`
	winCtrExe        = `C:\k2s\bin\containerd\ctr.exe`
	winDockerExe     = `C:\k2s\bin\docker\docker.exe`
	winDockerdExe    = `C:\k2s\bin\docker\dockerd.exe`
	winZapExe        = `C:\k2s\bin\zap.exe`
	winDockerModule  = `C:\k2s\lib\modules\windows\node\k2s.node.module\windowsnode\downloader\artifacts\docker\docker.module.psm1`
	winContainerdCfg = `C:\k2s\cfg\containerd\config.toml`
	winCertsBaseDir  = `C:\etc\containerd\certs.d`
	winDefaultProxy  = `http://172.19.1.1:8181`
)

func (p *linuxImageProvider) cleanupWindowsTempDir(remoteDir string) {
	if remoteDir == "" {
		return
	}
	cleanupCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	script := fmt.Sprintf("Remove-Item -Path %s -Recurse -Force -ErrorAction SilentlyContinue", psSingleQuote(remoteDir))
	if _, err := p.worker().runWindowsPowerShell(cleanupCtx, script, false); err != nil {
		slog.Debug("[Image] Failed to clean up Windows temp directory", "dir", remoteDir, "error", err)
	}
}

func (p *linuxImageProvider) listWindowsImages(ctx context.Context, nodeName string) ([]ContainerImage, error) {
	script := fmt.Sprintf(`$ErrorActionPreference = 'Continue'
& %s images -o json
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
`, psSingleQuote(winCrictlExe))
	out, err := p.worker().runWindowsPowerShell(ctx, script, false)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(out) == "" {
		return nil, nil
	}
	return parseCrictlImagesJSON([]byte(out), nodeName)
}

func (p *linuxImageProvider) pullWindowsImage(ctx context.Context, imageName string, showOutput bool) error {
	script := fmt.Sprintf(`$ErrorActionPreference = 'Continue'
$img = %s
& %s pull $img
if ($LASTEXITCODE -ne 0) {
    & %s -n k8s.io pull --insecure-registry $img
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
`, psSingleQuote(imageName), psSingleQuote(winCrictlExe), psSingleQuote(winNerdctlExe))

	_, err := p.worker().runWindowsPowerShell(ctx, script, showOutput)
	return err
}

func (p *linuxImageProvider) buildWindowsImage(ctx context.Context, cfg ImageBuildConfig) error {
	inputFolder := strings.TrimSpace(cfg.InputFolder)
	if inputFolder == "" {
		inputFolder = "."
	}
	absInput, err := filepath.Abs(inputFolder)
	if err != nil {
		return fmt.Errorf("resolving input folder %q: %w", inputFolder, err)
	}
	info, err := os.Stat(absInput)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("input folder %q does not exist or is not a directory", inputFolder)
	}

	dockerfilePath, err := resolveDockerfilePath(absInput, cfg.Dockerfile)
	if err != nil {
		return err
	}

	fullImageName := cfg.ImageName
	if fullImageName != "" && cfg.ImageTag != "" {
		fullImageName = fullImageName + ":" + cfg.ImageTag
	} else if fullImageName == "" && cfg.ImageTag != "" {
		fullImageName = cfg.ImageTag
	}
	if fullImageName == "" {
		return errors.New("image name must be specified for Windows image build")
	}

	localTar, relDockerfile, err := createBuildContextTar(absInput, dockerfilePath)
	if err != nil {
		return fmt.Errorf("creating build context archive: %w", err)
	}
	defer os.Remove(localTar)

	remoteDir := winTempDir("build")
	defer p.cleanupWindowsTempDir(remoteDir)

	mkdirScript := fmt.Sprintf("New-Item -ItemType Directory -Force -Path %s | Out-Null", psSingleQuote(remoteDir))
	if _, err := p.worker().runWindowsPowerShell(ctx, mkdirScript, false); err != nil {
		return fmt.Errorf("creating remote build directory: %w", err)
	}

	remoteTar := remoteDir + `\context.tar`
	if err := p.worker().scpToWindows(ctx, localTar, remoteTar); err != nil {
		return fmt.Errorf("transferring build context to Windows worker: %w", err)
	}

	remoteCtxDir := remoteDir + `\ctx`
	remoteDockerfile := remoteCtxDir + `\` + strings.ReplaceAll(relDockerfile, "/", `\`)
	remoteImageTar := remoteDir + `\image.tar`

	var buildArgsLines strings.Builder
	if len(cfg.BuildArgs) > 0 {
		keys := make([]string, 0, len(cfg.BuildArgs))
		for k := range cfg.BuildArgs {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			buildArgsLines.WriteString(fmt.Sprintf("$buildArgs += '--build-arg'\n$buildArgs += %s\n", psSingleQuote(k+"="+cfg.BuildArgs[k])))
		}
	}

	pushSection := ""
	if cfg.Push {
		pushSection = fmt.Sprintf(`
& %s -n k8s.io --insecure-registry image push --allow-nondistributable-artifacts $imageName
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
`, psSingleQuote(winNerdctlExe))
	}

	proxy := winDefaultProxy
	if state, stateErr := readWindowsWorkerState(p.worker().effectiveConfigDir()); stateErr == nil && state != nil && strings.TrimSpace(state.Proxy) != "" {
		proxy = strings.TrimSpace(state.Proxy)
	}

	script := fmt.Sprintf(`$ErrorActionPreference = 'Stop'
$remoteCtx = %s
$remoteTar = %s
$remoteDockerfile = %s
$remoteImageTar = %s
$imageName = %s

New-Item -ItemType Directory -Force -Path $remoteCtx | Out-Null
tar.exe -xf $remoteTar -C $remoteCtx
if ($LASTEXITCODE -ne 0) { throw "Failed to extract build context archive" }

$svc = Get-Service -Name 'docker' -ErrorAction SilentlyContinue
if ($null -eq $svc) {
    if (Test-Path %s) {
        Import-Module %s -Force
        Install-WinDocker -Proxy %s
    } else {
        & %s --register-service
        Start-Service -Name 'docker'
    }
} elseif ($svc.Status -ne 'Running') {
    Start-Service -Name 'docker'
}

$dockerReady = $false
for ($i = 0; $i -lt 30; $i++) {
    $ErrorActionPreference = 'Continue'
    & %s info *> $null
    if ($LASTEXITCODE -eq 0) {
        $dockerReady = $true
        break
    }
    Start-Sleep -Seconds 2
}
$ErrorActionPreference = 'Stop'
if (-not $dockerReady) {
    throw "Docker daemon on Windows worker did not become ready within 60 seconds"
}

$buildArgs = @('build', '-f', $remoteDockerfile, '-t', $imageName)
%s$buildArgs += $remoteCtx

$ErrorActionPreference = 'Continue'
& %s @buildArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& %s save -o $remoteImageTar $imageName
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& %s -n k8s.io images import $remoteImageTar
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& %s rmi -f $imageName *> $null
%s`,
		psSingleQuote(remoteCtxDir),
		psSingleQuote(remoteTar),
		psSingleQuote(remoteDockerfile),
		psSingleQuote(remoteImageTar),
		psSingleQuote(fullImageName),
		psSingleQuote(winDockerModule),
		psSingleQuote(winDockerModule),
		psSingleQuote(proxy),
		psSingleQuote(winDockerdExe),
		psSingleQuote(winDockerExe),
		buildArgsLines.String(),
		psSingleQuote(winDockerExe),
		psSingleQuote(winDockerExe),
		psSingleQuote(winCtrExe),
		psSingleQuote(winDockerExe),
		pushSection,
	)

	_, err = p.worker().runWindowsPowerShell(ctx, script, cfg.ShowOutput)
	return err
}

func resolveDockerfilePath(absInput, dockerfile string) (string, error) {
	if strings.TrimSpace(dockerfile) == "" {
		preCompile := filepath.Join(absInput, "Dockerfile.PreCompile")
		if isReadableFile(preCompile) {
			return preCompile, nil
		}
		standard := filepath.Join(absInput, "Dockerfile")
		if isReadableFile(standard) {
			return standard, nil
		}
		return "", fmt.Errorf("no Dockerfile or Dockerfile.PreCompile found in %q", absInput)
	}

	if isReadableFile(dockerfile) {
		return filepath.Abs(dockerfile)
	}
	candidate := filepath.Join(absInput, dockerfile)
	if isReadableFile(candidate) {
		return filepath.Abs(candidate)
	}
	return "", fmt.Errorf("Dockerfile %q not found", dockerfile)
}

func createBuildContextTar(absInput, absDockerfile string) (tarPath string, relDockerfile string, err error) {
	tmpFile, err := os.CreateTemp("", "k2s-win-build-*.tar")
	if err != nil {
		return "", "", err
	}
	tarPath = tmpFile.Name()
	defer func() {
		if err != nil {
			_ = tmpFile.Close()
			_ = os.Remove(tarPath)
		}
	}()

	tw := tar.NewWriter(tmpFile)

	walkErr := filepath.Walk(absInput, func(path string, info os.FileInfo, wErr error) error {
		if wErr != nil {
			return wErr
		}
		if path == absInput {
			return nil
		}
		rel, err := filepath.Rel(absInput, path)
		if err != nil {
			return err
		}
		relSlash := filepath.ToSlash(rel)

		var linkTarget string
		if info.Mode()&os.ModeSymlink != 0 {
			linkTarget, err = os.Readlink(path)
			if err != nil {
				return err
			}
		}

		hdr, err := tar.FileInfoHeader(info, linkTarget)
		if err != nil {
			return err
		}
		hdr.Name = relSlash

		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		if info.Mode().IsRegular() {
			f, err := os.Open(path)
			if err != nil {
				return err
			}
			_, copyErr := io.Copy(tw, f)
			closeErr := f.Close()
			if copyErr != nil {
				return copyErr
			}
			if closeErr != nil {
				return closeErr
			}
		}
		return nil
	})
	if walkErr != nil {
		err = walkErr
		return "", "", err
	}

	rel, relErr := filepath.Rel(absInput, absDockerfile)
	if relErr == nil && !strings.HasPrefix(rel, "..") && !filepath.IsAbs(rel) {
		relDockerfile = filepath.ToSlash(rel)
	} else {
		// External Dockerfile outside InputFolder: embed at archive root.
		relDockerfile = ".k2s-dockerfile"
		dfInfo, statErr := os.Stat(absDockerfile)
		if statErr != nil {
			err = statErr
			return "", "", err
		}
		hdr, hdrErr := tar.FileInfoHeader(dfInfo, "")
		if hdrErr != nil {
			err = hdrErr
			return "", "", err
		}
		hdr.Name = relDockerfile
		if err = tw.WriteHeader(hdr); err != nil {
			return "", "", err
		}
		f, openErr := os.Open(absDockerfile)
		if openErr != nil {
			err = openErr
			return "", "", err
		}
		_, copyErr := io.Copy(tw, f)
		closeErr := f.Close()
		if copyErr != nil {
			err = copyErr
			return "", "", err
		}
		if closeErr != nil {
			err = closeErr
			return "", "", err
		}
	}

	if err = tw.Close(); err != nil {
		return "", "", err
	}
	if err = tmpFile.Close(); err != nil {
		return "", "", err
	}
	return tarPath, relDockerfile, nil
}

func (p *linuxImageProvider) importWindowsImages(ctx context.Context, cfg ImageImportConfig) error {
	var tarFiles []string
	if cfg.TarPath != "" {
		if !isReadableFile(cfg.TarPath) {
			return fmt.Errorf("image archive %q does not exist or is not readable", cfg.TarPath)
		}
		tarFiles = append(tarFiles, cfg.TarPath)
	}
	if cfg.DirPath != "" {
		info, err := os.Stat(cfg.DirPath)
		if err != nil || !info.IsDir() {
			return fmt.Errorf("image directory %q does not exist or is not a directory", cfg.DirPath)
		}
		matches, err := filepath.Glob(filepath.Join(cfg.DirPath, "*.tar"))
		if err != nil {
			return fmt.Errorf("listing tar files in %q: %w", cfg.DirPath, err)
		}
		sort.Strings(matches)
		tarFiles = append(tarFiles, matches...)
	}

	if len(tarFiles) == 0 {
		if cfg.TarPath == "" && cfg.DirPath == "" {
			return errors.New("either tar file path or directory path must be specified")
		}
		slog.Warn("[Image] No .tar files found to import on Windows worker", "dir", cfg.DirPath)
		return nil
	}

	for _, tarFile := range tarFiles {
		if err := p.importSingleWindowsTar(ctx, tarFile, cfg.ShowOutput); err != nil {
			return err
		}
	}
	return nil
}

func (p *linuxImageProvider) importSingleWindowsTar(ctx context.Context, tarFile string, showOutput bool) error {
	remoteDir := winTempDir("import")
	defer p.cleanupWindowsTempDir(remoteDir)

	mkdirScript := fmt.Sprintf("New-Item -ItemType Directory -Force -Path %s | Out-Null", psSingleQuote(remoteDir))
	if _, err := p.worker().runWindowsPowerShell(ctx, mkdirScript, false); err != nil {
		return fmt.Errorf("creating remote import directory: %w", err)
	}

	remoteTar := remoteDir + `\image.tar`
	if err := p.worker().scpToWindows(ctx, tarFile, remoteTar); err != nil {
		return fmt.Errorf("transferring %q to Windows worker: %w", tarFile, err)
	}

	script := fmt.Sprintf(`$ErrorActionPreference = 'Continue'
$tarPath = %s
& %s -n k8s.io images import --all-platforms $tarPath
if ($LASTEXITCODE -ne 0) {
    & %s -n k8s.io images import $tarPath
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
`, psSingleQuote(remoteTar), psSingleQuote(winCtrExe), psSingleQuote(winCtrExe))

	_, err := p.worker().runWindowsPowerShell(ctx, script, showOutput)
	return err
}

func (p *linuxImageProvider) resolveWindowsImageRef(ctx context.Context, imageID, imageName string) (string, error) {
	// First check ctr images ls -q for exact refs in k8s.io namespace.
	ctrScript := fmt.Sprintf(`$ErrorActionPreference = 'Continue'
& %s -n k8s.io images ls -q
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
`, psSingleQuote(winCtrExe))
	ctrOut, ctrErr := p.worker().runWindowsPowerShell(ctx, ctrScript, false)
	var ctrRefs []string
	if ctrErr == nil {
		for _, line := range strings.Split(ctrOut, "\n") {
			if trimmed := strings.TrimSpace(line); trimmed != "" {
				ctrRefs = append(ctrRefs, trimmed)
			}
		}
	}

	if imageName != "" {
		if matched := matchWindowsRefByName(ctrRefs, imageName); matched != "" {
			return matched, nil
		}
	}

	// Query crictl images -o json to match by ID or RepoTags.
	images, err := p.listWindowsImages(ctx, "")
	if err != nil {
		if imageName != "" {
			return imageName, nil
		}
		return "", fmt.Errorf("resolving Windows image reference: %w", err)
	}

	for _, img := range images {
		if imageMatchesFilter(img, imageID, imageName) {
			if img.Repository != "<none>" && img.Tag != "<none>" {
				candidate := img.Repository + ":" + img.Tag
				if matched := matchWindowsRefByName(ctrRefs, candidate); matched != "" {
					return matched, nil
				}
				return candidate, nil
			}
			return img.ImageId, nil
		}
	}

	return "", fmt.Errorf("image not found on Windows worker (id=%q, name=%q)", imageID, imageName)
}

func matchWindowsRefByName(refs []string, name string) string {
	candidates := []string{name}
	if !strings.Contains(lastPathSegment(name), ":") {
		candidates = append(candidates, name+":latest")
	}
	if !strings.Contains(name, "/") {
		candidates = append(candidates, "docker.io/library/"+name)
		if !strings.Contains(name, ":") {
			candidates = append(candidates, "docker.io/library/"+name+":latest")
		}
	} else if !strings.Contains(strings.SplitN(name, "/", 2)[0], ".") && !strings.Contains(strings.SplitN(name, "/", 2)[0], ":") {
		candidates = append(candidates, "docker.io/"+name)
		if !strings.Contains(lastPathSegment(name), ":") {
			candidates = append(candidates, "docker.io/"+name+":latest")
		}
	}

	for _, cand := range candidates {
		for _, ref := range refs {
			if strings.EqualFold(ref, cand) {
				return ref
			}
		}
	}
	return ""
}

func lastPathSegment(ref string) string {
	if idx := strings.LastIndex(ref, "/"); idx != -1 {
		return ref[idx+1:]
	}
	return ref
}

func (p *linuxImageProvider) exportWindowsImage(ctx context.Context, cfg ImageExportConfig, outputPath string) error {
	resolvedRef, err := p.resolveWindowsImageRef(ctx, cfg.ImageId, cfg.ImageName)
	if err != nil {
		return err
	}

	remoteDir := winTempDir("export")
	defer p.cleanupWindowsTempDir(remoteDir)

	remoteTar := remoteDir + `\export.tar`
	script := fmt.Sprintf(`$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path %s | Out-Null
$ErrorActionPreference = 'Continue'
& %s -n k8s.io images export --all-platforms %s %s
if ($LASTEXITCODE -ne 0) {
    & %s -n k8s.io images export %s %s
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
`, psSingleQuote(remoteDir),
		psSingleQuote(winCtrExe), psSingleQuote(remoteTar), psSingleQuote(resolvedRef),
		psSingleQuote(winCtrExe), psSingleQuote(remoteTar), psSingleQuote(resolvedRef))

	if _, err := p.worker().runWindowsPowerShell(ctx, script, cfg.ShowOutput); err != nil {
		return fmt.Errorf("exporting image %q on Windows worker: %w", resolvedRef, err)
	}

	if parent := filepath.Dir(outputPath); parent != "" && parent != "." {
		if err := os.MkdirAll(parent, 0755); err != nil {
			return fmt.Errorf("creating output directory %q: %w", parent, err)
		}
	}

	if err := p.worker().scpFromWindows(ctx, remoteTar, outputPath); err != nil {
		return fmt.Errorf("copying exported archive from Windows worker: %w", err)
	}
	return nil
}

func (p *linuxImageProvider) tagWindowsImage(ctx context.Context, cfg ImageTagConfig) error {
	sourceRef, err := p.resolveWindowsImageRef(ctx, cfg.ImageId, cfg.ImageName)
	if err != nil {
		return err
	}
	target := cfg.TargetImageName
	if target == "" {
		target = cfg.ImageName
	}
	if target == "" {
		return errors.New("target image name must be specified")
	}

	script := fmt.Sprintf(`$ErrorActionPreference = 'Continue'
& %s -n k8s.io tag %s %s
if ($LASTEXITCODE -ne 0) {
    & %s -n k8s.io images tag --force %s %s
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
`, psSingleQuote(winNerdctlExe), psSingleQuote(sourceRef), psSingleQuote(target),
		psSingleQuote(winCtrExe), psSingleQuote(sourceRef), psSingleQuote(target))

	_, err = p.worker().runWindowsPowerShell(ctx, script, cfg.ShowOutput)
	return err
}

func (p *linuxImageProvider) pushWindowsImage(ctx context.Context, cfg ImagePushConfig) error {
	resolvedRef, err := p.resolveWindowsImageRef(ctx, cfg.ImageId, cfg.ImageName)
	if err != nil {
		return err
	}

	script := fmt.Sprintf(`$ErrorActionPreference = 'Continue'
& %s -n k8s.io --insecure-registry image push --allow-nondistributable-artifacts %s
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
`, psSingleQuote(winNerdctlExe), psSingleQuote(resolvedRef))

	_, err = p.worker().runWindowsPowerShell(ctx, script, cfg.ShowOutput)
	return err
}

func (p *linuxImageProvider) removeWindowsImage(ctx context.Context, cfg ImageRemoveConfig) error {
	images, err := p.listWindowsImages(ctx, "")
	if err != nil {
		return fmt.Errorf("listing Windows images for removal: %w", err)
	}

	var matched []ContainerImage
	for _, img := range images {
		if imageMatchesFilter(img, cfg.ImageId, cfg.ImageName) {
			matched = append(matched, img)
		}
	}
	if len(matched) == 0 {
		return fmt.Errorf("image not found on Windows worker (id=%q, name=%q)", cfg.ImageId, cfg.ImageName)
	}

	if cfg.Force {
		if err := p.stopAndRemoveWindowsContainersForImages(ctx, matched); err != nil {
			slog.Warn("[Image] Best-effort container cleanup on Windows failed", "error", err)
		}
	}

	var refsToRemove []string
	seen := make(map[string]bool)
	for _, img := range matched {
		if cfg.ImageName != "" && img.Repository != "<none>" && img.Tag != "<none>" {
			ref := img.Repository + ":" + img.Tag
			if !seen[ref] {
				seen[ref] = true
				refsToRemove = append(refsToRemove, ref)
			}
		} else if img.ImageId != "" && !seen[img.ImageId] {
			seen[img.ImageId] = true
			refsToRemove = append(refsToRemove, img.ImageId)
		}
	}

	var sb strings.Builder
	sb.WriteString("$ErrorActionPreference = 'Continue'\n$failed = $false\n")
	for _, ref := range refsToRemove {
		qRef := psSingleQuote(ref)
		sb.WriteString(fmt.Sprintf(`& %s rmi %s
if ($LASTEXITCODE -ne 0) {
    & %s -n k8s.io images rm %s
    if ($LASTEXITCODE -ne 0) {
        $failed = $true
    }
} else {
    & %s -n k8s.io images rm %s *> $null
}
`, psSingleQuote(winCrictlExe), qRef, psSingleQuote(winCtrExe), qRef, psSingleQuote(winCtrExe), qRef))
	}
	sb.WriteString("if ($failed) { exit 1 }\n")

	_, err = p.worker().runWindowsPowerShell(ctx, sb.String(), cfg.ShowOutput)
	return err
}

func (p *linuxImageProvider) stopAndRemoveWindowsContainersForImages(ctx context.Context, matched []ContainerImage) error {
	psListScript := fmt.Sprintf(`$ErrorActionPreference = 'Continue'
& %s ps -a -o json
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
`, psSingleQuote(winCrictlExe))
	out, err := p.worker().runWindowsPowerShell(ctx, psListScript, false)
	if err != nil || strings.TrimSpace(out) == "" {
		return err
	}

	var psResult struct {
		Containers []struct {
			ID    string `json:"id"`
			Image struct {
				Image string `json:"image"`
			} `json:"image"`
			ImageRef string `json:"imageRef"`
		} `json:"containers"`
	}
	if err := json.Unmarshal([]byte(out), &psResult); err != nil {
		return fmt.Errorf("parsing Windows crictl ps output: %w", err)
	}

	var containerIDs []string
	for _, c := range psResult.Containers {
		for _, img := range matched {
			fullRef := img.Repository + ":" + img.Tag
			if (img.ImageId != "" && (strings.Contains(c.ImageRef, img.ImageId) || strings.Contains(c.Image.Image, img.ImageId))) ||
				(img.Repository != "<none>" && (strings.EqualFold(c.Image.Image, fullRef) || strings.EqualFold(c.Image.Image, img.Repository))) {
				containerIDs = append(containerIDs, c.ID)
				break
			}
		}
	}

	if len(containerIDs) == 0 {
		return nil
	}

	var sb strings.Builder
	sb.WriteString("$ErrorActionPreference = 'Continue'\n")
	for _, cid := range containerIDs {
		sb.WriteString(fmt.Sprintf("& %s stop %s *> $null\nif ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }\n", psSingleQuote(winCrictlExe), psSingleQuote(cid)))
		sb.WriteString(fmt.Sprintf("& %s rm %s *> $null\nif ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }\n", psSingleQuote(winCrictlExe), psSingleQuote(cid)))
	}
	_, err = p.worker().runWindowsPowerShell(ctx, sb.String(), false)
	return err
}

func (p *linuxImageProvider) cleanWindowsImages(ctx context.Context, cfg ImageCleanConfig) error {
	images, err := p.listWindowsImages(ctx, "")
	if err != nil {
		return fmt.Errorf("listing Windows images for clean: %w", err)
	}

	baseline := p.loadK8sBaselineImages()
	seen := make(map[string]bool)
	var toRemove []string
	for _, img := range images {
		if isK8sBaselineImage(img.Repository, img.Tag, baseline) || isWindowsPauseImage(img.Repository) {
			continue
		}
		if img.ImageId != "" && !seen[img.ImageId] {
			seen[img.ImageId] = true
			toRemove = append(toRemove, img.ImageId)
		}
	}

	if len(toRemove) == 0 {
		return nil
	}

	var sb strings.Builder
	sb.WriteString("$ErrorActionPreference = 'Continue'\n$failed = $false\n")
	for _, id := range toRemove {
		sb.WriteString(fmt.Sprintf("& %s rmi %s\nif ($LASTEXITCODE -ne 0) { $failed = $true }\n", psSingleQuote(winCrictlExe), psSingleQuote(id)))
	}
	sb.WriteString("if ($failed) { exit 1 }\n")
	_, err = p.worker().runWindowsPowerShell(ctx, sb.String(), cfg.ShowOutput)
	return err
}

func (p *linuxImageProvider) addWindowsRegistry(ctx context.Context, cfg ImageRegistryAddConfig) error {
	folderName := strings.ReplaceAll(cfg.RegistryName, ":", "")
	protocol := "https"
	if cfg.PlainHttp {
		protocol = "http"
	}
	skipVerify := cfg.SkipVerify || cfg.PlainHttp || strings.Contains(cfg.RegistryName, "k2s.registry.local")

	hostsToml := fmt.Sprintf("server = \"%s://%s\"\n\n[host.\"%s://%s\"]\n  capabilities = [\"pull\", \"resolve\", \"push\"]\n  skip_verify = %t\n  plain_http = %t\n",
		protocol, cfg.RegistryName, protocol, cfg.RegistryName, skipVerify, cfg.PlainHttp)

	targetDir := winCertsBaseDir + `\` + folderName
	hostsPath := targetDir + `\hosts.toml`

	var authSection string
	if cfg.Username != "" {
		authB64 := base64.StdEncoding.EncodeToString([]byte(cfg.Username + ":" + cfg.Password))
		insecureFlag := ""
		if skipVerify {
			insecureFlag = " --insecure-registry"
		}
		header := fmt.Sprintf(`[plugins."io.containerd.grpc.v1.cri".registry.configs."%s".auth]`, cfg.RegistryName)
		authBlock := fmt.Sprintf("        %s\r\n          auth = %q\r\n\r\n        #add_new_registry_auth", header, authB64)
		authSection = fmt.Sprintf(`
$regPassword = %s
$ErrorActionPreference = 'Continue'
$regPassword | & %s -n k8s.io login%s -u %s --password-stdin %s
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$ErrorActionPreference = 'Stop'

$cfgPath = %s
if (Test-Path $cfgPath) {
    $content = Get-Content -Path $cfgPath -Raw
    $header = %s
    if (-not $content.Contains($header)) {
        $block = %s
        $content = $content.Replace('#add_new_registry_auth', $block)
        Set-Content -Path $cfgPath -Value $content -NoNewline
    }
}
`, psSingleQuote(cfg.Password), psSingleQuote(winNerdctlExe), insecureFlag, psSingleQuote(cfg.Username), psSingleQuote(cfg.RegistryName),
			psSingleQuote(winContainerdCfg), psSingleQuote(header), psSingleQuote(authBlock))
	}

	script := fmt.Sprintf(`$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path %s | Out-Null
$hostsContent = %s
Set-Content -Path %s -Value $hostsContent -Encoding ASCII
%s
Restart-Service -Name 'containerd' -Force
`, psSingleQuote(targetDir), psSingleQuote(hostsToml), psSingleQuote(hostsPath), authSection)

	_, err := p.worker().runWindowsPowerShell(ctx, script, cfg.ShowOutput)
	return err
}

func (p *linuxImageProvider) removeWindowsRegistry(ctx context.Context, cfg ImageRegistryRemoveConfig) error {
	folderName := strings.ReplaceAll(cfg.RegistryName, ":", "")
	targetDir := winCertsBaseDir + `\` + folderName

	script := fmt.Sprintf(`$ErrorActionPreference = 'Continue'
Remove-Item -Path %s -Recurse -Force -ErrorAction SilentlyContinue
& %s -n k8s.io logout %s *> $null

$cfgPath = %s
if (Test-Path $cfgPath) {
    $lines = Get-Content -Path $cfgPath
    $headerPattern = [regex]::Escape('[plugins."io.containerd.grpc.v1.cri".registry.configs."' + %s + '".auth]')
    $out = New-Object System.Collections.Generic.List[string]
    $skipNextAuth = $false
    foreach ($line in $lines) {
        if ($line -match $headerPattern) {
            $skipNextAuth = $true
            continue
        }
        if ($skipNextAuth -and $line -match '^\s*auth\s*=') {
            $skipNextAuth = $false
            continue
        }
        $skipNextAuth = $false
        $out.Add($line)
    }
    Set-Content -Path $cfgPath -Value $out
}

$ErrorActionPreference = 'Stop'
Restart-Service -Name 'containerd' -Force
`, psSingleQuote(targetDir), psSingleQuote(winNerdctlExe), psSingleQuote(cfg.RegistryName),
		psSingleQuote(winContainerdCfg), psSingleQuote(cfg.RegistryName))

	_, err := p.worker().runWindowsPowerShell(ctx, script, cfg.ShowOutput)
	return err
}

func (p *linuxImageProvider) listWindowsRegistries(ctx context.Context) ([]string, error) {
	script := fmt.Sprintf(`$base = %s
if (-not (Test-Path $base)) { return }
Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $folder = $_.Name
    $hostsFile = Join-Path $_.FullName 'hosts.toml'
    $found = ''
    if (Test-Path $hostsFile) {
        $raw = Get-Content -Path $hostsFile -Raw -ErrorAction SilentlyContinue
        if ($raw -match '\[host\."https?://([^"]+)"\]') {
            $found = $Matches[1]
        } elseif ($raw -match 'server\s*=\s*"https?://([^"]+)"') {
            $found = $Matches[1]
        }
    }
    if (-not $found) { $found = $folder }
    Write-Output $found
}
`, psSingleQuote(winCertsBaseDir))

	out, err := p.worker().runWindowsPowerShell(ctx, script, false)
	if err != nil {
		return nil, err
	}
	var registries []string
	for _, line := range strings.Split(out, "\n") {
		if trimmed := strings.TrimSpace(line); trimmed != "" {
			registries = append(registries, trimmed)
		}
	}
	return registries, nil
}

func (p *linuxImageProvider) resetWindowsStorage(ctx context.Context, cfg ImageResetWinStorageConfig) error {
	dockerDir := cfg.Docker
	if strings.TrimSpace(dockerDir) == "" {
		dockerDir = `C:\docker`
	}
	maxRetry := cfg.MaxRetry
	if maxRetry <= 0 {
		maxRetry = 1
	}

	script := fmt.Sprintf(`$ErrorActionPreference = 'Continue'
$containerdDir = %s
$dockerDir = %s
$maxRetry = %d
$forceZap = $%t

if (-not $containerdDir) {
    $containerdDir = 'C:\var\lib\containerd'
    if (Test-Path %s) {
        $cfgRaw = Get-Content -Path %s -Raw -ErrorAction SilentlyContinue
        if ($cfgRaw -match '(?m)^\s*root\s*=\s*"([^"]+)"') {
            $containerdDir = $Matches[1] -replace '\\\\', '\'
        }
    }
}

foreach ($svcName in @('containerd', 'docker')) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($null -ne $svc -and $svc.Status -eq 'Running') {
        Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
    }
}

function Remove-StorageDir([string]$dir) {
    if (-not $dir -or -not (Test-Path $dir)) { return }
    for ($attempt = 1; $attempt -le $maxRetry; $attempt++) {
        Get-ChildItem -Path $dir -Force -Recurse -Attributes Reparsepoint -ErrorAction SilentlyContinue | ForEach-Object {
            $n = $_.FullName.Trim('\')
            fsutil reparsepoint delete "$n" *> $null
        }
        Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $dir)) { return }
        Start-Sleep -Seconds 2
    }
    if ((Test-Path $dir) -and $forceZap -and (Test-Path %s)) {
        & %s -folder $dir
    }
    if (Test-Path $dir) {
        throw "Failed to clean storage directory: $dir"
    }
}

$ErrorActionPreference = 'Stop'
Remove-StorageDir $containerdDir
if ($dockerDir) {
    Remove-StorageDir $dockerDir
}

$cSvc = Get-Service -Name 'containerd' -ErrorAction SilentlyContinue
if ($null -ne $cSvc) {
    Start-Service -Name 'containerd' -ErrorAction SilentlyContinue
}
`, psSingleQuote(cfg.Containerd), psSingleQuote(dockerDir), maxRetry, cfg.ForceZap,
		psSingleQuote(winContainerdCfg), psSingleQuote(winContainerdCfg),
		psSingleQuote(winZapExe), psSingleQuote(winZapExe))

	_, err := p.worker().runWindowsPowerShell(ctx, script, cfg.ShowOutput)
	return err
}

func (p *linuxImageProvider) checkWindowsContainerdHealth(ctx context.Context) error {
	script := fmt.Sprintf(`$svc = Get-Service -Name 'containerd' -ErrorAction SilentlyContinue
if ($null -eq $svc -or $svc.Status -ne 'Running') {
    throw "containerd service is not running on Windows worker"
}
$ErrorActionPreference = 'Continue'
& %s images *> $null
if ($LASTEXITCODE -ne 0) {
    throw "crictl images failed on Windows worker (exit code $LASTEXITCODE)"
}
`, psSingleQuote(winCrictlExe))

	_, err := p.worker().runWindowsPowerShell(ctx, script, false)
	return err
}
