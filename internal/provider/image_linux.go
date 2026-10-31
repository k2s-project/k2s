// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build linux

package provider

import (
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/host"
	kjson "github.com/k2s-project/k2s/internal/json"
)

const (
	winVMIP = "172.19.1.101"
	sshUser = "remote"
)

type linuxImageProvider struct {
	installDir string
	configDir  string
}

func newLinuxImageProvider(cfg ProviderConfig) *linuxImageProvider {
	return &linuxImageProvider{
		installDir: cfg.InstallDir,
		configDir:  cfg.ConfigDir,
	}
}

func (p *linuxImageProvider) scriptPath(script string) string {
	return filepath.Join(p.installDir, "lib", "scripts", "linux", "debian", "host", "image", script)
}

// sshCmd executes a command on the Windows VM via SSH.
func sshCmd(command string) (string, error) {
	cmd := exec.Command("ssh",
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "ConnectTimeout=10",
		fmt.Sprintf("%s@%s", sshUser, winVMIP),
		command,
	)
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && len(exitErr.Stderr) > 0 {
			return string(out), fmt.Errorf("SSH command failed: %w: %s", err, string(exitErr.Stderr))
		}
		return string(out), fmt.Errorf("SSH command failed: %w: %s", err, string(out))
	}
	return string(out), nil
}

func (p *linuxImageProvider) List(cfg ImageListConfig) (*ImageListResult, error) {
	slog.Debug("[Image] Listing images (Linux)")
	result := &ImageListResult{}

	// List images on the local Linux node via buildah or crictl
	linuxImages, err := listLinuxImages()
	if err != nil {
		slog.Warn("[Image] Could not list Linux node images", "error", err)
	} else {
		for _, img := range linuxImages {
			if !cfg.IncludeK8sImages && isK8sImage(img.Repository) {
				continue
			}
			result.ContainerImages = append(result.ContainerImages, img)
		}
	}

	// List images on the Windows VM via SSH + crictl if not LinuxOnly
	if !p.isLinuxOnly() {
		winImages, err := listWindowsVMImages()
		if err != nil {
			slog.Debug("[Image] Could not list Windows VM images (VM may be offline)", "error", err)
		} else {
			for _, img := range winImages {
				if !cfg.IncludeK8sImages && isK8sImage(img.Repository) {
					continue
				}
				result.ContainerImages = append(result.ContainerImages, img)
			}
		}
	}

	return result, nil
}

func (p *linuxImageProvider) Pull(cfg ImagePullConfig) error {
	if cfg.Windows {
		if p.isLinuxOnly() {
			return fmt.Errorf("pulling Windows container images is not supported on Linux hosts (Windows container images can only be used on Windows worker nodes)")
		}
		slog.Info("[Image] Pulling image on Windows VM", "image", cfg.ImageName)
		_, err := sshCmd(fmt.Sprintf("crictl pull %s", cfg.ImageName))
		return err
	}
	slog.Info("[Image] Pulling image on Linux node", "image", cfg.ImageName)

	script := p.scriptPath("Pull-Image.sh")
	if _, err := os.Stat(script); err == nil {
		cmd := exec.Command(script, "-n", cfg.ImageName)
		if cfg.ShowOutput {
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
		}
		return cmd.Run()
	}

	cmd := exec.Command("crictl", "pull", cfg.ImageName)
	if cfg.ShowOutput {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	return cmd.Run()
}

func (p *linuxImageProvider) Remove(cfg ImageRemoveConfig) error {
	if cfg.FromRegistry {
		return p.removeFromRegistry(cfg)
	}

	ref := cfg.ImageId
	if ref == "" {
		ref = cfg.ImageName
	}
	slog.Info("[Image] Removing image", "ref", ref)

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
		cmd := exec.Command(script, args...)
		if cfg.ShowOutput {
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
		}
		return cmd.Run()
	}

	if _, err := exec.LookPath("buildah"); err == nil {
		args := []string{"rmi"}
		if cfg.Force {
			args = append(args, "--force")
		}
		args = append(args, ref)
		cmd := exec.Command("buildah", args...)
		if cfg.ShowOutput {
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
		}
		if err := cmd.Run(); err == nil {
			return nil
		}
		if !strings.HasPrefix(ref, "localhost/") {
			retryArgs := []string{"rmi"}
			if cfg.Force {
				retryArgs = append(retryArgs, "--force")
			}
			retryArgs = append(retryArgs, "localhost/"+ref)
			retryCmd := exec.Command("buildah", retryArgs...)
			if cfg.ShowOutput {
				retryCmd.Stdout = os.Stdout
				retryCmd.Stderr = os.Stderr
			}
			if err := retryCmd.Run(); err == nil {
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
			out, err := exec.Command("crictl", "ps", "-a", "-q", "--image", sel).Output()
			if err == nil {
				for _, cid := range strings.Fields(string(out)) {
					_ = exec.Command("crictl", "stop", cid).Run()
					_ = exec.Command("crictl", "rm", cid).Run()
				}
			}
		}
	}

	cmd := exec.Command("crictl", "rmi", ref)
	if cfg.ShowOutput {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Run(); err == nil {
		return nil
	}
	if !strings.HasPrefix(ref, "localhost/") {
		retryCmd := exec.Command("crictl", "rmi", "localhost/"+ref)
		if cfg.ShowOutput {
			retryCmd.Stdout = os.Stdout
			retryCmd.Stderr = os.Stderr
		}
		if err := retryCmd.Run(); err == nil {
			return nil
		}
	}
	return cmd.Run()
}

func (p *linuxImageProvider) Build(cfg ImageBuildConfig) error {
	if cfg.Windows {
		return fmt.Errorf("building Windows container images is not supported on Linux hosts (Windows container images can only be built on Windows worker nodes)")
	}
	slog.Info("[Image] Building image", "name", cfg.ImageName, "input", cfg.InputFolder)

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
		for k, v := range cfg.BuildArgs {
			args = append(args, "--build-arg", k+"="+v)
		}
		cmd := exec.Command(script, args...)
		if cfg.ShowOutput {
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
		}
		return cmd.Run()
	}

	args := []string{"build"}
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

	cmd := exec.Command("nerdctl", args...)
	if cfg.ShowOutput {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("nerdctl build failed: %w", err)
	}

	if cfg.Push && name != "" {
		pushCmd := exec.Command("nerdctl", "push", name)
		if cfg.ShowOutput {
			pushCmd.Stdout = os.Stdout
			pushCmd.Stderr = os.Stderr
		}
		return pushCmd.Run()
	}

	return nil
}

func (p *linuxImageProvider) Import(cfg ImageImportConfig) error {
	path := cfg.TarPath
	if path == "" {
		path = cfg.DirPath
	}
	slog.Info("[Image] Importing image", "path", path, "windows", cfg.Windows)

	if cfg.Windows {
		if p.isLinuxOnly() {
			return fmt.Errorf("importing Windows container images is not supported on Linux hosts (Windows container images can only be used on Windows worker nodes)")
		}
		// Import on Windows VM via SSH
		_, err := sshCmd(fmt.Sprintf(`ctr -n k8s.io images import "%s"`, path))
		return err
	}

	script := p.scriptPath("Import-Image.sh")
	if _, err := os.Stat(script); err == nil {
		var args []string
		if cfg.TarPath != "" {
			args = append(args, "-t", cfg.TarPath)
		}
		if cfg.DirPath != "" {
			args = append(args, "-d", cfg.DirPath)
		}
		cmd := exec.Command(script, args...)
		if cfg.ShowOutput {
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			return cmd.Run()
		}
		out, err := cmd.CombinedOutput()
		if err != nil {
			return fmt.Errorf("%s: %w", strings.TrimSpace(string(out)), err)
		}
		return nil
	}

	cmd := exec.Command("ctr", "-n", "k8s.io", "images", "import", path)
	if cfg.ShowOutput {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		return cmd.Run()
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %w", strings.TrimSpace(string(out)), err)
	}
	return nil
}

func (p *linuxImageProvider) Export(cfg ImageExportConfig) error {
	ref := cfg.ImageId
	if ref == "" {
		ref = cfg.ImageName
	}
	slog.Info("[Image] Exporting image", "ref", ref, "output", cfg.OutputPath)

	script := p.scriptPath("Export-Image.sh")
	if _, err := os.Stat(script); err == nil {
		var args []string
		if cfg.ImageId != "" {
			args = append(args, "-i", cfg.ImageId)
		}
		if cfg.ImageName != "" {
			args = append(args, "-n", cfg.ImageName)
		}
		if cfg.OutputPath != "" {
			args = append(args, "-t", cfg.OutputPath)
		}
		if cfg.DockerArchive {
			args = append(args, "--docker-archive")
		}
		cmd := exec.Command(script, args...)
		if cfg.ShowOutput {
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			return cmd.Run()
		}
		out, err := cmd.CombinedOutput()
		if err != nil {
			return fmt.Errorf("%s: %w", strings.TrimSpace(string(out)), err)
		}
		return nil
	}

	if cfg.DockerArchive {
		cmd := exec.Command("nerdctl", "-n", "k8s.io", "save", "-o", cfg.OutputPath, ref)
		if cfg.ShowOutput {
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			return cmd.Run()
		}
		out, err := cmd.CombinedOutput()
		if err != nil {
			return fmt.Errorf("%s: %w", strings.TrimSpace(string(out)), err)
		}
		return nil
	}

	cmd := exec.Command("ctr", "-n", "k8s.io", "images", "export", cfg.OutputPath, ref)
	if cfg.ShowOutput {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		return cmd.Run()
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %w", strings.TrimSpace(string(out)), err)
	}
	return nil
}

func (p *linuxImageProvider) Tag(cfg ImageTagConfig) error {
	ref := cfg.ImageId
	if ref == "" {
		ref = cfg.ImageName
	}
	target := cfg.TargetImageName
	if target == "" {
		target = cfg.ImageName
	}
	slog.Info("[Image] Tagging image", "ref", ref, "target", target)

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
		cmd := exec.Command(script, args...)
		if cfg.ShowOutput {
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
		}
		return cmd.Run()
	}

	cmd := exec.Command("ctr", "-n", "k8s.io", "images", "tag", ref, target)
	if cfg.ShowOutput {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	return cmd.Run()
}

func (p *linuxImageProvider) Push(cfg ImagePushConfig) error {
	ref := cfg.ImageId
	if ref == "" {
		ref = cfg.ImageName
	}
	slog.Info("[Image] Pushing image", "name", ref)

	script := p.scriptPath("Push-Image.sh")
	if _, err := os.Stat(script); err == nil {
		var args []string
		if cfg.ImageId != "" {
			args = append(args, "-i", cfg.ImageId)
		}
		if cfg.ImageName != "" {
			args = append(args, "-n", cfg.ImageName)
		}
		cmd := exec.Command(script, args...)
		if cfg.ShowOutput {
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
		}
		return cmd.Run()
	}

	cmd := exec.Command("nerdctl", "push", ref)
	if cfg.ShowOutput {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	return cmd.Run()
}

func (p *linuxImageProvider) Clean(cfg ImageCleanConfig) error {
	slog.Info("[Image] Cleaning non-K8s images")

	script := p.scriptPath("Clean-Images.sh")
	if _, err := os.Stat(script); err == nil {
		cmd := exec.Command(script)
		if cfg.ShowOutput {
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
		}
		return cmd.Run()
	}

	if _, err := exec.LookPath("buildah"); err == nil {
		buildahImages, err := listBuildahImages()
		if err == nil {
			cleaned := make(map[string]bool)
			for _, img := range buildahImages {
				if isK8sImage(img.Repository) || cleaned[img.ImageId] {
					continue
				}
				cleaned[img.ImageId] = true
				cmd := exec.Command("buildah", "rmi", "-f", img.ImageId)
				if cfg.ShowOutput {
					cmd.Stdout = os.Stdout
					cmd.Stderr = os.Stderr
				}
				if err := cmd.Run(); err != nil {
					slog.Warn("[Image] Could not remove buildah image", "id", img.ImageId, "error", err)
				}
			}
		}
	}

	images, err := listCrictlImages()
	if err != nil {
		return err
	}

	for _, img := range images {
		if isK8sImage(img.Repository) {
			continue
		}
		cmd := exec.Command("crictl", "rmi", img.ImageId)
		if cfg.ShowOutput {
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
		}
		if err := cmd.Run(); err != nil {
			slog.Warn("[Image] Could not remove image", "id", img.ImageId, "error", err)
		}
	}

	return nil
}

func (p *linuxImageProvider) RegistryAdd(cfg ImageRegistryAddConfig) error {
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

	cmd := exec.Command(script, args...)
	if cfg.ShowOutput {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to add registry '%s': %w", cfg.RegistryName, err)
	}

	// Persist registry in setup.json
	return p.addRegistryToConfig(cfg.RegistryName)
}

func (p *linuxImageProvider) RegistryRemove(cfg ImageRegistryRemoveConfig) error {
	script := p.scriptPath(filepath.Join("registry", "Remove-Registry.sh"))
	cmd := exec.Command(script, "--registry", cfg.RegistryName)
	if cfg.ShowOutput {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to remove registry '%s': %w", cfg.RegistryName, err)
	}

	// Remove registry from setup.json
	return p.removeRegistryFromConfig(cfg.RegistryName)
}

func (p *linuxImageProvider) addRegistryToConfig(registry string) error {
	if p.configDir == "" {
		return nil
	}
	configPath := filepath.Join(p.configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := kjson.FromFile[map[string]any](configPath)
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
	return kjson.ToFile(configPath, cfgMap)
}

func (p *linuxImageProvider) removeRegistryFromConfig(registry string) error {
	if p.configDir == "" {
		return nil
	}
	configPath := filepath.Join(p.configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := kjson.FromFile[map[string]any](configPath)
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
	return kjson.ToFile(configPath, cfgMap)
}

func (p *linuxImageProvider) isLinuxOnly() bool {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	if configDir != "" {
		configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
		cfgMap, err := kjson.FromFile[map[string]any](configPath)
		if err == nil {
			if val, ok := (*cfgMap)["LinuxOnly"]; ok {
				if b, ok := val.(bool); ok {
					return b
				}
			}
		}
	}
	return true
}

// ---------- helpers ----------

func listLinuxImages() ([]ContainerImage, error) {
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
		bImages, err := listBuildahImages()
		if err == nil {
			addImages(bImages)
		} else {
			buildahErr = err
			slog.Debug("[Image] listBuildahImages failed", "error", err)
		}
	}

	if _, err := exec.LookPath("crictl"); err == nil {
		cImages, err := listCrictlImages()
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
		if float64(int64(fl)) == fl {
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

func listBuildahImages() ([]ContainerImage, error) {
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
			repo := "<none>"
			tag := "<none>"
			if repoTag != "" && repoTag != "<none>:<none>" {
				lastColon := strings.LastIndex(repoTag, ":")
				if lastColon != -1 {
					repo = repoTag[:lastColon]
					tag = repoTag[lastColon+1:]
				} else {
					repo = repoTag
				}
			}
			images = append(images, ContainerImage{
				ImageId:    shortId,
				Repository: repo,
				Tag:        tag,
				Node:       getNodeName(),
				Size:       string(img.Size),
			})
		}
	}

	return images, nil
}

func listCrictlImages() ([]ContainerImage, error) {
	output, err := exec.Command("crictl", "images", "-o", "json").Output()
	if err != nil {
		return nil, fmt.Errorf("crictl images: %w", err)
	}

	var result struct {
		Images []struct {
			Id          string       `json:"id"`
			RepoTags    []string     `json:"repoTags"`
			RepoDigests []string     `json:"repoDigests"`
			Size        flexibleSize `json:"size"`
		} `json:"images"`
	}

	if err := json.Unmarshal(output, &result); err != nil {
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
			repo := "<none>"
			tag := "<none>"
			if repoTag != "" && repoTag != "<none>:<none>" {
				lastColon := strings.LastIndex(repoTag, ":")
				if lastColon != -1 {
					repo = repoTag[:lastColon]
					tag = repoTag[lastColon+1:]
				} else {
					repo = repoTag
				}
			}
			images = append(images, ContainerImage{
				ImageId:    shortId,
				Repository: repo,
				Tag:        tag,
				Node:       getNodeName(),
				Size:       string(img.Size),
			})
		}
	}

	return images, nil
}

func listWindowsVMImages() ([]ContainerImage, error) {
	output, err := sshCmd("crictl images -o json")
	if err != nil {
		return nil, err
	}

	var result struct {
		Images []struct {
			Id       string       `json:"id"`
			RepoTags []string     `json:"repoTags"`
			Size     flexibleSize `json:"size"`
		} `json:"images"`
	}

	if err := json.Unmarshal([]byte(output), &result); err != nil {
		return nil, fmt.Errorf("parsing Windows VM crictl output: %w", err)
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
			repo := "<none>"
			tag := "<none>"
			if repoTag != "" && repoTag != "<none>:<none>" {
				lastColon := strings.LastIndex(repoTag, ":")
				if lastColon != -1 {
					repo = repoTag[:lastColon]
					tag = repoTag[lastColon+1:]
				} else {
					repo = repoTag
				}
			}
			images = append(images, ContainerImage{
				ImageId:    shortId,
				Repository: repo,
				Tag:        tag,
				Node:       "windows",
				Size:       string(img.Size),
			})
		}
	}

	return images, nil
}

func getNodeName() string {
	h, err := os.Hostname()
	if err == nil && h != "" {
		return strings.ToLower(h)
	}
	return "linux"
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

func (p *linuxImageProvider) getRegistriesFromConfig() []string {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := kjson.FromFile[map[string]any](configPath)
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

	tr := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}
	client := &http.Client{Transport: tr, Timeout: 10 * time.Second}

	var lastErr error
	for _, baseURL := range urls {
		manifestURL := fmt.Sprintf("%s/v2/%s/manifests/%s", baseURL, repo, tag)
		req, err := http.NewRequest("GET", manifestURL, nil)
		if err != nil {
			lastErr = err
			continue
		}
		req.Header.Set("Accept", "application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json")
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
		delReq, err := http.NewRequest("DELETE", delURL, nil)
		if err != nil {
			lastErr = err
			continue
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
