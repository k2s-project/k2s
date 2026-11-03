// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package imageimport

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/providers/ssh"
	"github.com/k2s-project/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// These tests generate synthetic Docker archives (no Docker daemon needed) with unique random content per run.
// They prove the K2s import path for multi-image Docker archives, but not compatibility with a genuine 'docker save' archive.

var suite *framework.K2sTestSuite

func TestMultiImageImport(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Multi-Image Archive Import Acceptance Tests", Label("core", "acceptance", "setup-required", "system-running", "invasive", "image"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	if runtime.GOOS != "windows" {
		Skip("the Docker archive import path under test is implemented by the Windows host scripts")
	}

	suite = framework.Setup(ctx, framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(500*time.Millisecond),
		framework.ClusterTestStepTimeout(10*time.Minute),
	)
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite != nil {
		suite.TearDown(ctx)
	}
})

type archiveLayer struct {
	blob       []byte
	diffID     string
	compressed bool
}

type archiveImage struct {
	tag    string
	layers []archiveLayer
	config []byte
}

func (i *archiveImage) id() string { return sha256Hex(i.config) }

type buildahImage struct {
	ID    string   `json:"id"`
	Names []string `json:"names"`
}

type storageLayer struct {
	ID         string `json:"id"`
	Parent     string `json:"parent"`
	DiffDigest string `json:"diff-digest"`
}

type storageImage struct {
	ID    string `json:"id"`
	Layer string `json:"layer"`
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func randomBytes(size int) []byte {
	data := make([]byte, size)
	_, err := rand.Read(data)
	Expect(err).ToNot(HaveOccurred())
	return data
}

func newLayer(files map[string][]byte, compressed bool) archiveLayer {
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	sort.Strings(names)

	var tarBuffer bytes.Buffer
	tw := tar.NewWriter(&tarBuffer)
	for _, name := range names {
		Expect(tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(files[name])), ModTime: time.Unix(0, 0), Typeflag: tar.TypeReg})).To(Succeed())
		_, err := tw.Write(files[name])
		Expect(err).ToNot(HaveOccurred())
	}
	Expect(tw.Close()).To(Succeed())

	uncompressed := tarBuffer.Bytes()
	layer := archiveLayer{blob: uncompressed, diffID: "sha256:" + sha256Hex(uncompressed), compressed: compressed}
	if compressed {
		var gzBuffer bytes.Buffer
		gw := gzip.NewWriter(&gzBuffer)
		_, err := gw.Write(uncompressed)
		Expect(err).ToNot(HaveOccurred())
		Expect(gw.Close()).To(Succeed())
		layer.blob = gzBuffer.Bytes()
	}
	return layer
}

// newImage creates an image config; configDiffIDs overrides the layer diff IDs to create an entry Buildah must reject.
func newImage(tag, runID string, layers []archiveLayer, configDiffIDs []string) *archiveImage {
	diffIDs := configDiffIDs
	if diffIDs == nil {
		for _, layer := range layers {
			diffIDs = append(diffIDs, layer.diffID)
		}
	}
	config, err := json.Marshal(map[string]any{
		"architecture": "amd64",
		"os":           "linux",
		"created":      "2026-01-01T00:00:00Z",
		"config":       map[string]any{"Cmd": []string{"/bin/true"}, "Labels": map[string]string{"k2s.e2e.run": runID, "k2s.e2e.tag": tag}},
		"rootfs":       map[string]any{"type": "layers", "diff_ids": diffIDs},
	})
	Expect(err).ToNot(HaveOccurred())
	return &archiveImage{tag: tag, layers: layers, config: config}
}

// writeDockerArchive writes a Docker archive in the layout of current 'docker save' versions: content-addressed blobs,
// 'manifest.json' (entry order = manifestOrder) and an OCI 'index.json' listing the images in the reverse order.
func writeDockerArchive(path string, manifestOrder []*archiveImage) {
	blobs := map[string][]byte{}
	addBlob := func(data []byte) string {
		digest := sha256Hex(data)
		blobs[digest] = data
		return "blobs/sha256/" + digest
	}

	type manifestEntry struct {
		Config   string
		RepoTags []string
		Layers   []string
	}
	manifest := []manifestEntry{}
	indexManifests := []map[string]any{}
	for _, image := range manifestOrder {
		entry := manifestEntry{Config: addBlob(image.config), RepoTags: []string{image.tag}}
		ociLayers := []map[string]any{}
		for _, layer := range image.layers {
			entry.Layers = append(entry.Layers, addBlob(layer.blob))
			mediaType := "application/vnd.oci.image.layer.v1.tar"
			if layer.compressed {
				mediaType += "+gzip"
			}
			ociLayers = append(ociLayers, map[string]any{"mediaType": mediaType, "digest": "sha256:" + sha256Hex(layer.blob), "size": len(layer.blob)})
		}
		manifest = append(manifest, entry)

		ociManifest, err := json.Marshal(map[string]any{
			"schemaVersion": 2,
			"mediaType":     "application/vnd.oci.image.manifest.v1+json",
			"config":        map[string]any{"mediaType": "application/vnd.oci.image.config.v1+json", "digest": "sha256:" + image.id(), "size": len(image.config)},
			"layers":        ociLayers,
		})
		Expect(err).ToNot(HaveOccurred())
		addBlob(ociManifest)
		indexManifests = append([]map[string]any{{
			"mediaType":   "application/vnd.oci.image.manifest.v1+json",
			"digest":      "sha256:" + sha256Hex(ociManifest),
			"size":        len(ociManifest),
			"annotations": map[string]string{"io.containerd.image.name": image.tag, "org.opencontainers.image.ref.name": image.tag[strings.LastIndex(image.tag, ":")+1:]},
		}}, indexManifests...)
	}

	manifestJSON, err := json.Marshal(manifest)
	Expect(err).ToNot(HaveOccurred())
	indexJSON, err := json.Marshal(map[string]any{"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": indexManifests})
	Expect(err).ToNot(HaveOccurred())

	file, err := os.Create(path)
	Expect(err).ToNot(HaveOccurred())
	defer func() { Expect(file.Close()).To(Succeed()) }()

	tw := tar.NewWriter(file)
	writeDir := func(name string) {
		Expect(tw.WriteHeader(&tar.Header{Name: name, Mode: 0o755, ModTime: time.Unix(0, 0), Typeflag: tar.TypeDir})).To(Succeed())
	}
	writeFile := func(name string, data []byte) {
		Expect(tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(data)), ModTime: time.Unix(0, 0), Typeflag: tar.TypeReg})).To(Succeed())
		_, err := tw.Write(data)
		Expect(err).ToNot(HaveOccurred())
	}

	writeDir("blobs/")
	writeDir("blobs/sha256/")
	digests := make([]string, 0, len(blobs))
	for digest := range blobs {
		digests = append(digests, digest)
	}
	sort.Strings(digests)
	for _, digest := range digests {
		writeFile("blobs/sha256/"+digest, blobs[digest])
	}
	writeFile("index.json", indexJSON)
	writeFile("manifest.json", manifestJSON)
	writeFile("oci-layout", []byte(`{"imageLayoutVersion":"1.0.0"}`))
	Expect(tw.Close()).To(Succeed())
}

func execOnControlPlane(command string) (string, error) {
	buffer := new(bytes.Buffer)
	err := ssh.NewSSH(ssh.ConnectionOptions{
		IpAddress:         suite.SetupInfo().Config.ControlPlane().IpAddress(),
		Port:              definitions.SSHDefaultPort,
		RemoteUser:        definitions.SSHRemoteUser,
		SshPrivateKeyPath: suite.SetupInfo().Config.Host().SshConfig().CurrentPrivateKeyPath(),
		Timeout:           2 * time.Minute,
		StdOutWriter:      buffer,
	}).Exec(command)
	return buffer.String(), err
}

func mustExecOnControlPlane(command string) string {
	output, err := execOnControlPlane(command)
	Expect(err).ToNot(HaveOccurred(), "command '%s' failed on the control-plane: %s", command, output)
	return output
}

// listControlPlaneImages returns the sorted image names per full image ID (without 'sha256:' prefix).
func listControlPlaneImages() map[string][]string {
	var images []buildahImage
	Expect(json.Unmarshal([]byte(mustExecOnControlPlane("sudo buildah images --json --no-trunc")), &images)).To(Succeed())

	result := map[string][]string{}
	for _, image := range images {
		names := append([]string{}, image.Names...)
		sort.Strings(names)
		result[strings.TrimPrefix(image.ID, "sha256:")] = names
	}
	return result
}

func listTemporaryArchives() []string {
	return strings.Fields(mustExecOnControlPlane("ls -1 /tmp/k2s-image-import-*.tar 2>/dev/null || true"))
}

var _ = Describe("k2s image import of multi-image Docker archives", Label("image", "image-import"), Ordered, func() {
	var (
		runID              string
		repository         string
		baseLayer          archiveLayer
		alpha, beta        *archiveImage
		broken, gamma      *archiveImage
		delta              *archiveImage
		imagesBefore       map[string][]string
		temporaryBefore    []string
		createdImageIDs    []string
		multiArchivePath   string
		failingArchivePath string
		singleArchivePath  string
	)

	expectImageTaggedOnce := func(images map[string][]string, image *archiveImage) {
		Expect(images).To(HaveKey(image.id()), "image %s with ID %s is missing on the control-plane", image.tag, image.id())
		Expect(images[image.id()]).To(ContainElement(image.tag))
		for id, names := range images {
			if id != image.id() {
				Expect(names).ToNot(ContainElement(image.tag), "tag %s must not be assigned to image %s", image.tag, id)
			}
		}
	}

	BeforeAll(func() {
		runID = hex.EncodeToString(randomBytes(4))
		repository = "k2s.local/e2e-multi-image-" + runID
		archiveDir := GinkgoT().TempDir()

		baseLayer = newLayer(map[string][]byte{"k2s-e2e/base.bin": randomBytes(1 << 20)}, false)
		alpha = newImage(repository+"/alpha:v1", runID, []archiveLayer{baseLayer, newLayer(map[string][]byte{"k2s-e2e/alpha.txt": []byte("alpha " + runID)}, true)}, nil)
		beta = newImage(repository+"/beta:v1", runID, []archiveLayer{baseLayer, newLayer(map[string][]byte{"k2s-e2e/beta.txt": []byte("beta " + runID)}, false)}, nil)

		gamma = newImage(repository+"/gamma:v1", runID, []archiveLayer{newLayer(map[string][]byte{"k2s-e2e/gamma.bin": randomBytes(1024)}, false)}, nil)
		brokenLayer := newLayer(map[string][]byte{"k2s-e2e/broken.bin": randomBytes(1024)}, false)
		// the config declares two layers while the manifest entry references one, so Buildah rejects this entry
		broken = newImage(repository+"/broken:v1", runID, []archiveLayer{brokenLayer}, []string{brokenLayer.diffID, "sha256:" + sha256Hex(randomBytes(32))})

		delta = newImage(repository+"/delta:v1", runID, []archiveLayer{newLayer(map[string][]byte{"k2s-e2e/delta.bin": randomBytes(1024)}, true)}, nil)

		multiArchivePath = filepath.Join(archiveDir, "multi-image.tar")
		failingArchivePath = filepath.Join(archiveDir, "partially-broken.tar")
		singleArchivePath = filepath.Join(archiveDir, "single-image.tar")
		writeDockerArchive(multiArchivePath, []*archiveImage{beta, alpha})
		writeDockerArchive(failingArchivePath, []*archiveImage{broken, gamma})
		writeDockerArchive(singleArchivePath, []*archiveImage{delta})

		imagesBefore = listControlPlaneImages()
		for _, image := range []*archiveImage{alpha, beta, broken, gamma, delta} {
			Expect(imagesBefore).ToNot(HaveKey(image.id()), "generated image IDs must be unique to this run")
		}
		temporaryBefore = listTemporaryArchives()
		GinkgoWriter.Printf("run %s: alpha=%s beta=%s gamma=%s broken=%s delta=%s\n", runID, alpha.id(), beta.id(), gamma.id(), broken.id(), delta.id())
	})

	AfterAll(func() {
		if len(createdImageIDs) == 0 {
			return
		}
		images := listControlPlaneImages()
		for _, id := range createdImageIDs {
			names, found := images[id]
			if !found {
				continue
			}
			// remove only images of this run, i.e. images whose names all belong to the run-specific repository
			ownedByRun := true
			for _, name := range names {
				ownedByRun = ownedByRun && strings.HasPrefix(name, repository+"/")
			}
			if !ownedByRun {
				GinkgoWriter.Printf("keeping image %s, it has names outside of %s: %v\n", id, repository, names)
				continue
			}
			output, err := execOnControlPlane("sudo buildah rmi " + id)
			GinkgoWriter.Printf("cleanup of image %s: err=%v output=%s\n", id, err, output)
		}
	})

	It("imports all images of a multi-image Docker archive without --docker-archive", func(ctx context.Context) {
		createdImageIDs = append(createdImageIDs, alpha.id(), beta.id())

		suite.K2sCli().MustExec(ctx, "image", "import", "-t", multiArchivePath, "-o")

		images := listControlPlaneImages()
		expectImageTaggedOnce(images, alpha)
		expectImageTaggedOnce(images, beta)

		for _, image := range []*archiveImage{alpha, beta} {
			Expect(mustExecOnControlPlane("sudo crictl inspecti -o json "+image.tag)).To(ContainSubstring(image.id()), "CRI-O must see %s", image.tag)
		}
	})

	It("stores the layer shared by both images only once", func() {
		storageInfo := strings.Fields(mustExecOnControlPlane("sudo buildah info --format '{{.store.GraphRoot}} {{.store.GraphDriverName}}'"))
		Expect(storageInfo).To(HaveLen(2))
		graphRoot, driver := storageInfo[0], storageInfo[1]

		var layers []storageLayer
		Expect(json.Unmarshal([]byte(mustExecOnControlPlane(fmt.Sprintf("sudo cat %s/%s-layers/layers.json", graphRoot, driver))), &layers)).To(Succeed())
		var storedImages []storageImage
		Expect(json.Unmarshal([]byte(mustExecOnControlPlane(fmt.Sprintf("sudo cat %s/%s-images/images.json", graphRoot, driver))), &storedImages)).To(Succeed())

		layersByID := map[string]storageLayer{}
		var baseLayerRecords []storageLayer
		for _, layer := range layers {
			layersByID[layer.ID] = layer
			if layer.DiffDigest == baseLayer.diffID {
				baseLayerRecords = append(baseLayerRecords, layer)
			}
		}
		Expect(baseLayerRecords).To(HaveLen(1), "the shared base layer must be stored exactly once")

		for _, image := range []*archiveImage{alpha, beta} {
			var topLayerID string
			for _, stored := range storedImages {
				if stored.ID == image.id() {
					topLayerID = stored.Layer
				}
			}
			Expect(topLayerID).ToNot(BeEmpty(), "image %s not found in the image store", image.tag)
			topLayer, found := layersByID[topLayerID]
			Expect(found).To(BeTrue())
			Expect(topLayer.DiffDigest).To(Equal(image.layers[1].diffID))
			Expect(topLayer.Parent).To(Equal(baseLayerRecords[0].ID), "the top layer of %s must be based on the shared layer", image.tag)
		}
	})

	It("fails when an archive entry cannot be imported but keeps the other entries", func(ctx context.Context) {
		createdImageIDs = append(createdImageIDs, gamma.id(), broken.id())

		suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "image", "import", "-t", failingArchivePath, "--docker-archive", "-o")

		images := listControlPlaneImages()
		expectImageTaggedOnce(images, gamma)
		Expect(images).ToNot(HaveKey(broken.id()))
		for _, names := range images {
			Expect(names).ToNot(ContainElement(broken.tag))
		}
	})

	It("still imports a single-image Docker archive", func(ctx context.Context) {
		createdImageIDs = append(createdImageIDs, delta.id())

		suite.K2sCli().MustExec(ctx, "image", "import", "-t", singleArchivePath, "--docker-archive", "-o")

		expectImageTaggedOnce(listControlPlaneImages(), delta)
	})

	It("removes the temporary archives from the control-plane", func() {
		Expect(listTemporaryArchives()).To(ConsistOf(temporaryBefore), "temporary import archives must be removed from the control-plane")
	})

	It("leaves pre-existing images untouched", func() {
		imagesAfter := listControlPlaneImages()
		for id, names := range imagesBefore {
			Expect(imagesAfter).To(HaveKeyWithValue(id, names), "pre-existing image %s must not be removed or retagged", id)
		}
	})
})
