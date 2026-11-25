// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package exportimport

import (
	"archive/tar"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestPrebuiltAddonOci(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Prebuilt addon OCI selection", Label("unit", "ci"))
}

var _ = Describe("prebuilt addon OCI selection", func() {
	It("uses the configured artifact when its contents include the requested implementation", func() {
		rootDir := GinkgoT().TempDir()
		source := filepath.Join(rootDir, "renamed-all-addons.oci.tar")
		writePrebuiltOciArchive(source,
			map[string]string{
				"vnd.k2s.addon.name":           "security",
				"vnd.k2s.addon.implementation": "security",
			},
			map[string]string{
				"vnd.k2s.addon.name":           "ingress",
				"vnd.k2s.addon.implementation": "nginx",
			})
		setPrebuiltOciEnvironment(source)

		selected, found := usePrebuiltAddonOci("ingress", "nginx", filepath.Join(rootDir, "out"))

		Expect(found).To(BeTrue())
		Expect(filepath.Base(selected)).To(Equal(filepath.Base(source)))
	})

	It("looks for a companion only when the configured artifact lacks the requested implementation", func() {
		rootDir := GinkgoT().TempDir()
		source := filepath.Join(rootDir, "K2s-2.0-addons-all.oci.tar")
		writePrebuiltOciArchive(source, map[string]string{
			"vnd.k2s.addon.name":           "security",
			"vnd.k2s.addon.implementation": "security",
		})
		companion := filepath.Join(rootDir, "K2s-2.0-addons-ingress-nginx.oci.tar")
		writePrebuiltOciArchive(companion, map[string]string{
			"vnd.k2s.addon.name":           "ingress",
			"vnd.k2s.addon.implementation": "nginx",
		})
		setPrebuiltOciEnvironment(source)

		selected, found := usePrebuiltAddonOci("ingress", "nginx", filepath.Join(rootDir, "out"))

		Expect(found).To(BeTrue())
		Expect(filepath.Base(selected)).To(Equal(filepath.Base(companion)))
	})
})

func writePrebuiltOciArchive(filePath string, annotations ...map[string]string) {
	manifests := make([]any, 0, len(annotations))
	for _, annotation := range annotations {
		manifests = append(manifests, map[string]any{"annotations": annotation})
	}
	content, err := json.Marshal(map[string]any{
		"schemaVersion": 2,
		"manifests":     manifests,
	})
	Expect(err).ToNot(HaveOccurred())

	file, err := os.Create(filePath)
	Expect(err).ToNot(HaveOccurred())
	writer := tar.NewWriter(file)
	Expect(writer.WriteHeader(&tar.Header{Name: "./index.json", Mode: 0o644, Size: int64(len(content))})).To(Succeed())
	_, err = writer.Write(content)
	Expect(err).ToNot(HaveOccurred())
	Expect(writer.Close()).To(Succeed())
	Expect(file.Close()).To(Succeed())
}

func setPrebuiltOciEnvironment(source string) {
	original, wasSet := os.LookupEnv(PrebuiltAddonOciFileEnv)
	Expect(os.Setenv(PrebuiltAddonOciFileEnv, source)).To(Succeed())
	DeferCleanup(func() {
		if wasSet {
			Expect(os.Setenv(PrebuiltAddonOciFileEnv, original)).To(Succeed())
		} else {
			Expect(os.Unsetenv(PrebuiltAddonOciFileEnv)).To(Succeed())
		}
	})
}
