// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package addons

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/test/framework"
)

const (
	artifactName = "test-addon.oci.tar"
	artifactTag  = "v1.0.0"
	clusterIp    = "172.19.1.100"
	registryPort = 30500
	testRepo     = "test-repo"
	orasFileName = "oras.exe"

	layerAnnotationTitle = "config.tar.gz"
)

var suite *framework.K2sTestSuite
var orasFilePath string
var testFailed = false

func TestOCIArtifact(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "OCI Artifact Functional Tests", Label("functional", "acceptance", "oci-artifact", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(time.Millisecond*200))
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

// digestOf computes SHA-256 of data and returns the full OCI digest string ("sha256:<hex>") and the hex string alone.
func digestOf(data []byte) (string, string) {
	sum := sha256.Sum256(data)
	h := hex.EncodeToString(sum[:])
	return "sha256:" + h, h
}

// newTarGzLayer creates an in-memory tar.gz archive containing a single file.
func newTarGzLayer(filename, content string) ([]byte, error) {
	var buf bytes.Buffer
	gw := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gw)

	body := []byte(content)
	hdr := &tar.Header{
		Name:     filename,
		Mode:     0o600,
		Size:     int64(len(body)),
		Typeflag: tar.TypeReg,
	}
	if err := tw.WriteHeader(hdr); err != nil {
		return nil, err
	}
	if _, err := tw.Write(body); err != nil {
		return nil, err
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if err := gw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// writeBlob writes data to <blobsDir>/<hexDigest> and returns the full OCI digest and the byte length.
func writeBlob(blobsDir string, data []byte) (string, int64, error) {
	digest, hexOnly := digestOf(data)
	dest := filepath.Join(blobsDir, hexOnly)
	if err := os.WriteFile(dest, data, 0o600); err != nil {
		return "", 0, err
	}
	return digest, int64(len(data)), nil
}

// tarDir creates a tar archive at destFile from all files inside srcDir (paths relative to srcDir).
func tarDir(srcDir, destFile string) error {
	f, err := os.Create(destFile)
	if err != nil {
		return err
	}
	defer f.Close()

	tw := tar.NewWriter(f)
	defer tw.Close()

	return filepath.Walk(srcDir, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(srcDir, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if info.IsDir() {
			if rel == "." {
				return nil
			}
			return tw.WriteHeader(&tar.Header{
				Name:     rel + "/",
				Typeflag: tar.TypeDir,
				Mode:     0o755,
			})
		}
		hdr := &tar.Header{
			Name:     rel,
			Mode:     int64(info.Mode()),
			Size:     info.Size(),
			Typeflag: tar.TypeReg,
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		src, err := os.Open(path)
		if err != nil {
			return err
		}
		defer src.Close()
		_, err = io.Copy(tw, src)
		return err
	})
}

// buildOciTar creates a minimal OCI Image Layout tar archive at destPath.
// The layout contains one manifest with a config blob and one compressed layer.
func buildOciTar(destPath string) error {
	layoutDir, err := os.MkdirTemp("", "k2s-oci-layout-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(layoutDir)

	blobsDir := filepath.Join(layoutDir, "blobs", "sha256")
	if err := os.MkdirAll(blobsDir, 0o755); err != nil {
		return err
	}

	if err := os.WriteFile(
		filepath.Join(layoutDir, "oci-layout"),
		[]byte(`{"imageLayoutVersion":"1.0.0"}`),
		0o600,
	); err != nil {
		return err
	}

	configJSON, err := json.Marshal(map[string]string{
		"name":           "test-addon",
		"version":        "1.0.0",
		"implementation": "test-addon",
		"k2sVersion":     "test",
	})
	if err != nil {
		return err
	}
	configDigest, configSize, err := writeBlob(blobsDir, configJSON)
	if err != nil {
		return err
	}

	layerData, err := newTarGzLayer("addon.manifest.yaml", "name: test-addon\nversion: 1.0.0\n")
	if err != nil {
		return err
	}
	layerDigest, layerSize, err := writeBlob(blobsDir, layerData)
	if err != nil {
		return err
	}

	type descriptor struct {
		MediaType    string            `json:"mediaType"`
		Size         int64             `json:"size"`
		Digest       string            `json:"digest"`
		ArtifactType string            `json:"artifactType,omitempty"`
		Annotations  map[string]string `json:"annotations,omitempty"`
	}
	type ociManifest struct {
		SchemaVersion int               `json:"schemaVersion"`
		MediaType     string            `json:"mediaType"`
		ArtifactType  string            `json:"artifactType"`
		Config        descriptor        `json:"config"`
		Layers        []descriptor      `json:"layers"`
		Annotations   map[string]string `json:"annotations"`
	}

	manifest := ociManifest{
		SchemaVersion: 2,
		MediaType:     "application/vnd.oci.image.manifest.v1+json",
		ArtifactType:  "application/vnd.k2s.addon.v1",
		Config: descriptor{
			MediaType: "application/vnd.k2s.addon.config.v1+json",
			Size:      configSize,
			Digest:    configDigest,
		},
		Layers: []descriptor{
			{
				MediaType: "application/vnd.k2s.addon.configfiles.v1.tar+gzip",
				Size:      layerSize,
				Digest:    layerDigest,
				Annotations: map[string]string{
					"org.opencontainers.image.title": layerAnnotationTitle,
				},
			},
		},
		Annotations: map[string]string{
			"org.opencontainers.image.title": "test-addon",
			"vnd.k2s.addon.name":             "test-addon",
		},
	}
	manifestJSON, err := json.Marshal(manifest)
	if err != nil {
		return err
	}
	manifestDigest, manifestSize, err := writeBlob(blobsDir, manifestJSON)
	if err != nil {
		return err
	}

	type indexEntry struct {
		MediaType    string            `json:"mediaType"`
		Size         int64             `json:"size"`
		Digest       string            `json:"digest"`
		ArtifactType string            `json:"artifactType"`
		Annotations  map[string]string `json:"annotations"`
	}
	type ociIndex struct {
		SchemaVersion int          `json:"schemaVersion"`
		MediaType     string       `json:"mediaType"`
		Manifests     []indexEntry `json:"manifests"`
	}

	index := ociIndex{
		SchemaVersion: 2,
		MediaType:     "application/vnd.oci.image.index.v1+json",
		Manifests: []indexEntry{
			{
				MediaType:    "application/vnd.oci.image.manifest.v1+json",
				Size:         manifestSize,
				Digest:       manifestDigest,
				ArtifactType: "application/vnd.k2s.addon.v1",
				Annotations: map[string]string{
					"org.opencontainers.image.ref.name": artifactTag,
				},
			},
		},
	}
	indexJSON, err := json.Marshal(index)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(layoutDir, "index.json"), indexJSON, 0o600); err != nil {
		return err
	}

	return tarDir(layoutDir, destPath)
}

var _ = Describe("OCI Artifact operations", Ordered, func() {
	When("registry addon is enabled", func() {
		BeforeAll(func(ctx context.Context) {
			orasFilePath = filepath.Join(suite.RootDir(), "bin", orasFileName)
			GinkgoWriter.Println("oras.exe path:", orasFilePath)

			Expect(buildOciTar(artifactName)).To(Succeed(), "failed to build OCI Image Layout tar")

			suite.K2sCli().MustExec(ctx, "addons", "enable", "registry", "-o")

			DeferCleanup(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "registry", "-o")

				os.RemoveAll("./downloaded")
				os.Remove(artifactName)
			})
		})

		It("local container registry is configured", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "image", "registry", "ls")

			Expect(output).Should(ContainSubstring("k2s.registry.local:30500"), "Local Registry was not enabled")
		})

		It("registry is reachable", func(ctx context.Context) {
			url := fmt.Sprintf("http://%s:%d", clusterIp, registryPort)

			_, err := suite.HttpClient().Get(ctx, url)

			Expect(err).To(BeNil())
		})

		It("pushes the OCI Image Layout tar as an OCI artifact", func(ctx context.Context) {
			Expect(os.Stat(artifactName)).ToNot(BeNil())

			ref := fmt.Sprintf("%s:%d/%s:%s", clusterIp, registryPort, testRepo, artifactTag)
			suite.Cli(orasFilePath).MustExec(ctx,
				"cp",
				"--from-oci-layout",
				fmt.Sprintf("%s:%s", artifactName, artifactTag),
				ref,
				"--to-plain-http",
				"--to-insecure",
			)
		})

		It("verifies the manifest after push", func(ctx context.Context) {
			output := suite.Cli(orasFilePath).MustExec(ctx,
				"manifest", "fetch",
				"--insecure", "--plain-http",
				fmt.Sprintf("%s:%d/%s:%s", clusterIp, registryPort, testRepo, artifactTag),
			)

			Expect(output).To(ContainSubstring("application/vnd.k2s.addon.v1"))
		})

		It("pulls the artifact to a specific directory", func(ctx context.Context) {
			suite.Cli(orasFilePath).MustExec(ctx,
				"pull",
				"--insecure", "--plain-http",
				fmt.Sprintf("%s:%d/%s:%s", clusterIp, registryPort, testRepo, artifactTag),
				"-o", "./downloaded",
			)

			Expect(os.Stat("./downloaded/" + layerAnnotationTitle)).ToNot(BeNil())
		})
	})
})
