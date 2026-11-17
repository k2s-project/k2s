// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package provider

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// The container images bundled into a native Linux node package's images/ folder. This is
// the same set New-K2sNodePackage.ps1 exports from its Hyper-V guest, so an arm64 package
// can be joined the same way as an amd64 one (the join imports images/ as OCI archives):
//   - Kubernetes images as listed by `kubeadm config images list` for the resolved version
//     (kubeadm comes from the downloaded kubeadm .deb, so the list matches the packages);
//   - flannel images (mirrors Get-FlannelImages in common-setup.module.psm1);
//   - NVIDIA images from addons/gpu-node/addon.manifest.yaml when GPU support is included.
//
// Images are copied straight from the registries into OCI archives with skopeo, so the
// build needs neither a container runtime nor local image storage.

var flannelImages = []string{
	"docker.io/flannel/flannel-cni-plugin:v1.9.1-flannel3",
	"docker.io/flannel/flannel:v0.28.10",
}

var (
	nvidiaImagePattern = regexp.MustCompile(`nvcr\.io/nvidia/[A-Za-z0-9_./-]+:[A-Za-z0-9_.-]+`)
	// Same filter New-K2sNodePackage.ps1 applies to `kubeadm config images list` output.
	kubeadmImageRefPattern  = regexp.MustCompile(`^[^\s]+/[^\s]+:[^\s]+$`)
	imageArchiveNameEscaper = strings.NewReplacer("/", "_", ":", "__")
)

// parseKubeadmImageList keeps the image references from `kubeadm config images list` output.
func parseKubeadmImageList(output string) []string {
	var refs []string
	for _, line := range strings.Split(output, "\n") {
		ref := strings.TrimSpace(line)
		if kubeadmImageRefPattern.MatchString(ref) {
			refs = append(refs, ref)
		}
	}
	return refs
}

// nvidiaImagesFromManifest returns the distinct nvcr.io/nvidia image references in a GPU addon manifest.
func nvidiaImagesFromManifest(content string) []string {
	return appendUnique(nil, nvidiaImagePattern.FindAllString(content, -1)...)
}

// imageArchiveName matches the archive names the Windows-built package uses.
func imageArchiveName(ref string) string {
	return imageArchiveNameEscaper.Replace(ref) + ".tar"
}

func appendUnique(list []string, values ...string) []string {
	for _, value := range values {
		seen := false
		for _, existing := range list {
			if existing == value {
				seen = true
				break
			}
		}
		if !seen {
			list = append(list, value)
		}
	}
	return list
}

// kubeadmImageRefs asks the kubeadm binary from the downloaded .deb which images the
// given Kubernetes version needs. The binary is extracted rather than installed, so the
// build host's own package state is not changed.
func kubeadmImageRefs(ctx context.Context, kubeadmDeb, k8sVersion string) ([]string, error) {
	extractDir, err := os.MkdirTemp("", "k2s-kubeadm-")
	if err != nil {
		return nil, fmt.Errorf("could not create kubeadm extraction directory: %w", err)
	}
	defer os.RemoveAll(extractDir)

	if output, err := buildCommand(ctx, "dpkg-deb", "-x", kubeadmDeb, extractDir).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("could not extract %s: %w: %s", kubeadmDeb, err, strings.TrimSpace(string(output)))
	}

	kubeadm := filepath.Join(extractDir, "usr", "bin", "kubeadm")
	cmd := buildCommand(ctx, kubeadm, "config", "images", "list", "--kubernetes-version", k8sVersion)
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("kubeadm config images list failed for %s: %w", k8sVersion, err)
	}
	refs := parseKubeadmImageList(string(output))
	if len(refs) == 0 {
		return nil, fmt.Errorf("kubeadm config images list returned no images for %s", k8sVersion)
	}
	return refs, nil
}

// proxyEnvironment passes the build proxy on to skopeo, which reads the standard variables.
func proxyEnvironment(proxy string) map[string]string {
	if proxy == "" {
		return nil
	}
	if !strings.Contains(proxy, "://") {
		proxy = "http://" + proxy
	}
	return map[string]string{
		"HTTP_PROXY":  proxy,
		"HTTPS_PROXY": proxy,
		"http_proxy":  proxy,
		"https_proxy": proxy,
	}
}

// exportNodePackageImages writes one OCI archive per image into imagesDir for the given
// architecture. It fails if any image cannot be copied, because a package missing an image
// would only fail later, on the node that joins with it.
func exportNodePackageImages(ctx context.Context, imagesDir, kubeadmDeb, k8sVersion, arch, installDir, proxy string, includeGpu bool) error {
	if _, err := exec.LookPath("skopeo"); err != nil {
		return fmt.Errorf("skopeo is required to export container images into the node package (install it with 'apt-get install skopeo'): %w", err)
	}

	k8sRefs, err := kubeadmImageRefs(ctx, kubeadmDeb, k8sVersion)
	if err != nil {
		return err
	}
	refs := appendUnique(nil, k8sRefs...)
	refs = appendUnique(refs, flannelImages...)

	if includeGpu {
		manifestPath := filepath.Join(installDir, "addons", "gpu-node", "addon.manifest.yaml")
		content, err := os.ReadFile(manifestPath)
		if err != nil {
			return fmt.Errorf("could not read GPU addon manifest %s: %w", manifestPath, err)
		}
		gpuRefs := nvidiaImagesFromManifest(string(content))
		if len(gpuRefs) == 0 {
			return fmt.Errorf("no NVIDIA container images found in %s", manifestPath)
		}
		refs = appendUnique(refs, gpuRefs...)
	}

	if err := os.MkdirAll(imagesDir, 0o755); err != nil {
		return fmt.Errorf("could not create images directory %s: %w", imagesDir, err)
	}

	fmt.Printf("[NodePkg] Exporting %d container images for %s\n", len(refs), arch)
	env := proxyEnvironment(proxy)
	for _, ref := range refs {
		destination := filepath.Join(imagesDir, imageArchiveName(ref))
		if err := runLoggedWithEnv(ctx, env, "skopeo", "copy",
			"--retry-times", "3",
			"--override-os", "linux",
			"--override-arch", arch,
			"docker://"+ref,
			"oci-archive:"+destination+":"+ref,
		); err != nil {
			return fmt.Errorf("could not export image %s: %w", ref, err)
		}
	}

	archives, err := filepath.Glob(filepath.Join(imagesDir, "*.tar"))
	if err != nil {
		return err
	}
	if len(archives) != len(refs) {
		return fmt.Errorf("exported %d image archives, expected %d", len(archives), len(refs))
	}
	return nil
}
