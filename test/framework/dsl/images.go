// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package dsl

import (
	"bytes"
	"context"
	"crypto/tls"
	"fmt"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"

	"github.com/k2s-project/k2s/internal/definitions"
	k2s_json "github.com/k2s-project/k2s/internal/json"
	"github.com/k2s-project/k2s/internal/providers/ssh"
	"github.com/k2s-project/k2s/test/framework/http"

	"encoding/json"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

type buildahImage struct {
	Names []string `json:"names"`
}

type crictlImagesResult struct {
	Images []crictlImage `json:"images"`
}

type crictlImage struct {
	RepoTags []string `json:"repoTags"`
}

type k8sImageConfig struct {
	Repository string `json:"Repository"`
	Tag        string `json:"Tag"`
}

const (
	localRegistryUrlPart    = "k2s.registry.local"
	k8sImagesConfigFileName = "kubernetes_images.json"
)

func (k2s *K2s) VerifyImageIsAvailableOnAnyNode(ctx context.Context, name string) {
	if k2s.isImageAvailableOnLinuxNode(name) {
		return
	}
	if k2s.isImageAvailableOnWindowsNode(ctx, name) {
		return
	}
	Fail(fmt.Sprintf("Image '%s' not available on any node", name))
}

func (k2s *K2s) VerifyImageIsNotAvailableOnAnyNode(ctx context.Context, name string) {
	if !k2s.isImageAvailableOnLinuxNode(name) && !k2s.isImageAvailableOnWindowsNode(ctx, name) {
		return
	}
	Fail(fmt.Sprintf("Image '%s' must not be available on any node", name))
}

func (k2s *K2s) IsImageNotAvailableOnAnyNode(ctx context.Context, name string) bool {
	return !k2s.isImageAvailableOnLinuxNode(name) && !k2s.isImageAvailableOnWindowsNode(ctx, name)
}

func (k2s *K2s) VerifyImageIsNotAvailableInLocalRegistry(ctx context.Context, name string) {
	if !k2s.isImageAvailableInLocalRegistry(ctx, name) {
		return
	}
	Fail(fmt.Sprintf("Image '%s' must not be available in local registry", name))
}

func (k2s *K2s) VerifyImageIsAvailableInLocalRegistry(ctx context.Context, name string) {
	if k2s.isImageAvailableInLocalRegistry(ctx, name) {
		return
	}
	Fail(fmt.Sprintf("Image '%s' not available in local registry", name))
}

func (k2s *K2s) GetNonK8sImagesFromNodes(ctx context.Context) (images []string) {
	imagesFromLinuxNode := k2s.getImagesFromLinuxNode()
	imagesFromWindowsNode := k2s.getImagesFromWindowsNode(ctx)
	k8sImageRepos := k2s.getK8sImageRepositories()

	for _, image := range append(imagesFromLinuxNode, imagesFromWindowsNode...) {
		imageRepo := extractImageRepository(image)
		if !slices.Contains(k8sImageRepos, imageRepo) {
			images = append(images, image)
		}
	}
	return
}

// extractImageRepository extracts the repository part from an image reference.
// It handles both tag format (repo:tag) and digest format (repo@sha256:...).
func extractImageRepository(image string) string {
	// First check for digest format (contains @)
	if idx := strings.Index(image, "@"); idx != -1 {
		return image[:idx]
	}
	// Then check for tag format (contains :)
	// But be careful with registry ports like "localhost:5000/image:tag"
	// Find the last colon after the last slash
	lastSlash := strings.LastIndex(image, "/")
	if lastSlash == -1 {
		lastSlash = 0
	}
	if idx := strings.LastIndex(image[lastSlash:], ":"); idx != -1 {
		return image[:lastSlash+idx]
	}
	return image
}

// FilterOutK8sImages filters out images whose repository matches a known
// Kubernetes base image recorded in kubernetes_images.json. This mirrors
// the filtering done by GetNonK8sImagesFromNodes so that expected and
// actual image lists are comparable (e.g. images already present in the
// base cluster setup are excluded from both sides).
func (k2s *K2s) FilterOutK8sImages(images []string) []string {
	k8sImageRepos := k2s.getK8sImageRepositories()

	var filtered []string
	for _, image := range images {
		imageRepo := extractImageRepository(image)
		if !slices.Contains(k8sImageRepos, imageRepo) {
			filtered = append(filtered, image)
		}
	}
	return filtered
}

func (k2s *K2s) getK8sImageRepositories() (repos []string) {
	configFilePath := filepath.Join(k2s.suite.SetupInfo().Config.Host().K2sSetupConfigDir(), k8sImagesConfigFileName)

	config, err := k2s_json.FromFile[[]k8sImageConfig](configFilePath)
	Expect(err).ToNot(HaveOccurred())

	for _, imageConfig := range *config {
		repos = append(repos, imageConfig.Repository)
	}
	return
}

func (k2s *K2s) getImagesFromWindowsNode(ctx context.Context) (images []string) {
	if k2s.isLinuxOnly() || runtime.GOOS == "linux" {
		return nil
	}

	crictl := k2s.suite.Cli(filepath.Join(k2s.suite.RootDir(), "bin", "crictl.exe"))
	crictlConfig := filepath.Join(k2s.suite.RootDir(), "bin", "crictl.yaml")
	output := crictl.NoStdOut().MustExec(ctx, "--config", crictlConfig, "images", "-o", "json")

	var imageResult crictlImagesResult
	err := json.Unmarshal([]byte(output), &imageResult)
	Expect(err).ToNot(HaveOccurred())

	for _, imageEntry := range imageResult.Images {
		images = append(images, imageEntry.RepoTags...)
	}
	return
}

func (k2s *K2s) getImagesFromLinuxNode() (images []string) {
	var output []byte
	var err error

	if k2s.isLinuxOnly() || runtime.GOOS == "linux" {
		output, err = exec.Command("sudo", "buildah", "images", "--json").Output()
		if err != nil {
			output, err = exec.Command("sudo", "crictl", "images", "-o", "json").Output()
			if err == nil {
				var crictlRes crictlImagesResult
				if json.Unmarshal(output, &crictlRes) == nil {
					for _, img := range crictlRes.Images {
						images = append(images, img.RepoTags...)
					}
					return images
				}
			}
		}
	} else {
		buf := new(bytes.Buffer)
		connectionOptions := ssh.ConnectionOptions{
			IpAddress:         k2s.suite.SetupInfo().Config.ControlPlane().IpAddress(),
			Port:              definitions.SSHDefaultPort,
			RemoteUser:        definitions.SSHRemoteUser,
			SshPrivateKeyPath: k2s.suite.SetupInfo().Config.Host().SshConfig().CurrentPrivateKeyPath(),
			Timeout:           time.Minute * 2,
			StdOutWriter:      buf,
		}

		err = ssh.NewSSH(connectionOptions).Exec("sudo buildah images --json")
		output = buf.Bytes()
	}
	Expect(err).ToNot(HaveOccurred())

	var imageList []buildahImage
	err = json.Unmarshal(output, &imageList)
	Expect(err).ToNot(HaveOccurred())

	for _, imageEntry := range imageList {
		images = append(images, imageEntry.Names...)
	}
	return
}

func (k2s *K2s) isImageAvailableOnWindowsNode(ctx context.Context, fullName string) bool {
	if k2s.isLinuxOnly() || runtime.GOOS == "linux" {
		return false
	}
	return slices.Contains(k2s.getImagesFromWindowsNode(ctx), fullName)
}

func (k2s *K2s) isImageAvailableOnLinuxNode(fullName string) bool {
	for _, img := range k2s.getImagesFromLinuxNode() {
		if img == fullName || strings.TrimPrefix(img, "localhost/") == fullName {
			return true
		}
	}
	return false
}

func (k2s *K2s) isLinuxOnly() bool {
	if installConfig := k2s.suite.SetupInfo().RuntimeConfig.InstallConfig(); installConfig != nil {
		return installConfig.LinuxOnly()
	}
	return false
}

func (k2s *K2s) isImageAvailableInLocalRegistry(ctx context.Context, name string) bool {
	k2s.suite.SetupInfo().ReloadRuntimeConfig()

	var registry string
	for _, r := range k2s.suite.SetupInfo().RuntimeConfig.ClusterConfig().Registries() {
		if strings.Contains(string(r), localRegistryUrlPart) {
			registry = string(r)
			break
		}
	}
	if registry == "" {
		Fail("Local registry not found in runtime config")
	}

	var protocol string
	var client *http.ResilientHttpClient

	if strings.Contains(registry, ":") {
		protocol = "http"
		client = k2s.suite.HttpClient()
	} else {
		protocol = "https"
		client = k2s.suite.HttpClient(&tls.Config{InsecureSkipVerify: true})
	}

	responseJson, err := client.GetJson(ctx, protocol+"://"+registry+"/v2/_catalog")
	Expect(err).ToNot(HaveOccurred())

	var catalog struct {
		Repositories []string `json:"repositories"`
	}
	err = json.Unmarshal(responseJson, &catalog)
	Expect(err).ToNot(HaveOccurred())

	for _, repository := range catalog.Repositories {
		responseJson, err = client.GetJson(ctx, protocol+"://"+registry+"/v2/"+repository+"/tags/list")
		Expect(err).ToNot(HaveOccurred())

		var image struct {
			Name string   `json:"name"`
			Tags []string `json:"tags"`
		}
		err = json.Unmarshal(responseJson, &image)
		Expect(err).ToNot(HaveOccurred())

		for _, tag := range image.Tags {
			if registry+"/"+image.Name+":"+tag == name {
				return true
			}
		}
	}
	return false
}
