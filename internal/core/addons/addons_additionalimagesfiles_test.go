// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package addons

import (
	"os"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("additionalImagesFiles", func() {
	var tempDir string

	BeforeEach(func() {
		var err error
		tempDir, err = os.MkdirTemp("", "addon-test-*")
		Expect(err).ToNot(HaveOccurred())
	})

	AfterEach(func() {
		if tempDir != "" {
			os.RemoveAll(tempDir)
		}
	})

	Describe("ExtractImagesFromFiles", func() {
		Context("when YAML file contains image in image: field", func() {
			It("extracts the image with version", func() {
				yamlContent := `apiVersion: apps/v1
kind: Deployment
metadata:
  name: test
spec:
  containers:
    - name: test-container
      image: "quay.io/prometheus-operator/prometheus-operator:v0.66.0"
      imagePullPolicy: IfNotPresent`

				yamlFile := filepath.Join(tempDir, "deployment.yaml")
				err := os.WriteFile(yamlFile, []byte(yamlContent), 0644)
				Expect(err).ToNot(HaveOccurred())

				impl := Implementation{
					Directory: tempDir,
					OfflineUsage: OfflineUsage{
						LinuxResources: LinuxResources{
							AdditionalImagesFiles: []string{"deployment.yaml"},
						},
					},
				}

				images, err := impl.ExtractImagesFromFiles()

				Expect(err).ToNot(HaveOccurred())
				Expect(images).To(ConsistOf("quay.io/prometheus-operator/prometheus-operator:v0.66.0"))
			})
		})

		Context("when YAML file contains image in command argument", func() {
			It("extracts images from --param=image:tag format", func() {
				yamlContent := `apiVersion: apps/v1
kind: Deployment
spec:
  containers:
    - name: operator
      image: "quay.io/prometheus-operator/prometheus-operator:v0.66.0"
      args:
        - --kubelet-service=kube-system/service
        - --prometheus-config-reloader=quay.io/prometheus-operator/prometheus-config-reloader:v0.66.0
        - --config-reloader-cpu-request=200m`

				yamlFile := filepath.Join(tempDir, "deployment.yaml")
				err := os.WriteFile(yamlFile, []byte(yamlContent), 0644)
				Expect(err).ToNot(HaveOccurred())

				impl := Implementation{
					Directory: tempDir,
					OfflineUsage: OfflineUsage{
						LinuxResources: LinuxResources{
							AdditionalImagesFiles: []string{"deployment.yaml"},
						},
					},
				}

				images, err := impl.ExtractImagesFromFiles()

				Expect(err).ToNot(HaveOccurred())
				Expect(images).To(ContainElements(
					"quay.io/prometheus-operator/prometheus-operator:v0.66.0",
					"quay.io/prometheus-operator/prometheus-config-reloader:v0.66.0",
				))
			})
		})

		Context("when YAML file does not exist", func() {
			It("returns an error", func() {
				impl := Implementation{
					Directory: tempDir,
					OfflineUsage: OfflineUsage{
						LinuxResources: LinuxResources{
							AdditionalImagesFiles: []string{"nonexistent.yaml"},
						},
					},
				}

				images, err := impl.ExtractImagesFromFiles()

				Expect(err).To(HaveOccurred())
				Expect(images).To(BeNil())
			})
		})

		Context("when YAML file contains no images", func() {
			It("returns empty slice", func() {
				yamlContent := `apiVersion: v1
kind: Service
metadata:
  name: test-service
spec:
  ports:
    - port: 80`

				yamlFile := filepath.Join(tempDir, "service.yaml")
				err := os.WriteFile(yamlFile, []byte(yamlContent), 0644)
				Expect(err).ToNot(HaveOccurred())

				impl := Implementation{
					Directory: tempDir,
					OfflineUsage: OfflineUsage{
						LinuxResources: LinuxResources{
							AdditionalImagesFiles: []string{"service.yaml"},
						},
					},
				}

				images, err := impl.ExtractImagesFromFiles()

				Expect(err).ToNot(HaveOccurred())
				Expect(images).To(BeEmpty())
			})
		})

		Context("when additionalImagesFiles is empty", func() {
			It("returns empty slice", func() {
				impl := Implementation{
					Directory: tempDir,
					OfflineUsage: OfflineUsage{
						LinuxResources: LinuxResources{
							AdditionalImagesFiles: []string{},
						},
					},
				}

				images, err := impl.ExtractImagesFromFiles()

				Expect(err).ToNot(HaveOccurred())
				Expect(images).To(BeEmpty())
			})
		})

		Context("when relative paths are used", func() {
			It("resolves paths correctly from implementation directory", func() {
				// Create manifests subdirectory
				manifestsDir := filepath.Join(tempDir, "manifests")
				err := os.MkdirAll(manifestsDir, 0755)
				Expect(err).ToNot(HaveOccurred())

				yamlContent := `apiVersion: apps/v1
kind: Deployment
spec:
  containers:
    - image: "test.io/image:v1.0.0"`

				yamlFile := filepath.Join(manifestsDir, "deployment.yaml")
				err = os.WriteFile(yamlFile, []byte(yamlContent), 0644)
				Expect(err).ToNot(HaveOccurred())

				impl := Implementation{
					Directory: tempDir,
					OfflineUsage: OfflineUsage{
						LinuxResources: LinuxResources{
							AdditionalImagesFiles: []string{"manifests/deployment.yaml"},
						},
					},
				}

				images, err := impl.ExtractImagesFromFiles()

				Expect(err).ToNot(HaveOccurred())
				Expect(images).To(ConsistOf("test.io/image:v1.0.0"))
			})
		})

		Context("when shared resources with ../../ paths are used", func() {
			It("resolves parent directory paths correctly", func() {
				// Create directory structure: tempDir/addon/nginx and tempDir/common/manifests
				nginxDir := filepath.Join(tempDir, "addon", "nginx")
				commonDir := filepath.Join(tempDir, "common", "manifests")
				err := os.MkdirAll(nginxDir, 0755)
				Expect(err).ToNot(HaveOccurred())
				err = os.MkdirAll(commonDir, 0755)
				Expect(err).ToNot(HaveOccurred())

				yamlContent := `apiVersion: apps/v1
kind: Deployment
spec:
  containers:
    - image: "registry.k8s.io/external-dns/external-dns:v0.19.0"`

				yamlFile := filepath.Join(commonDir, "external-dns.yaml")
				err = os.WriteFile(yamlFile, []byte(yamlContent), 0644)
				Expect(err).ToNot(HaveOccurred())

				impl := Implementation{
					Directory: nginxDir,
					OfflineUsage: OfflineUsage{
						LinuxResources: LinuxResources{
							AdditionalImagesFiles: []string{"../../common/manifests/external-dns.yaml"},
						},
					},
				}

				images, err := impl.ExtractImagesFromFiles()

				Expect(err).ToNot(HaveOccurred())
				Expect(images).To(ConsistOf("registry.k8s.io/external-dns/external-dns:v0.19.0"))
			})
		})

		Context("when multiple files are specified", func() {
			It("extracts images from all files", func() {
				yamlContent1 := `apiVersion: apps/v1
kind: Deployment
spec:
  containers:
    - image: "image1.io/test:v1.0.0"`

				yamlContent2 := `apiVersion: apps/v1
kind: Deployment
spec:
  containers:
    - image: "image2.io/test:v2.0.0"`

				yamlFile1 := filepath.Join(tempDir, "deployment1.yaml")
				yamlFile2 := filepath.Join(tempDir, "deployment2.yaml")
				err := os.WriteFile(yamlFile1, []byte(yamlContent1), 0644)
				Expect(err).ToNot(HaveOccurred())
				err = os.WriteFile(yamlFile2, []byte(yamlContent2), 0644)
				Expect(err).ToNot(HaveOccurred())

				impl := Implementation{
					Directory: tempDir,
					OfflineUsage: OfflineUsage{
						LinuxResources: LinuxResources{
							AdditionalImagesFiles: []string{"deployment1.yaml", "deployment2.yaml"},
						},
					},
				}

				images, err := impl.ExtractImagesFromFiles()

				Expect(err).ToNot(HaveOccurred())
				Expect(images).To(ConsistOf(
					"image1.io/test:v1.0.0",
					"image2.io/test:v2.0.0",
				))
			})
		})

		Context("when a file contains multiple YAML documents", func() {
			It("extracts images from every document, not only the first one", func() {
				yamlContent := `apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
---
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - image: "quay.io/jetstack/cert-manager-controller:v1.21.1"
---
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - image: "quay.io/jetstack/cert-manager-webhook:v1.21.1"
`

				yamlFile := filepath.Join(tempDir, "multi-doc.yaml")
				err := os.WriteFile(yamlFile, []byte(yamlContent), 0644)
				Expect(err).ToNot(HaveOccurred())

				impl := Implementation{
					Directory: tempDir,
					OfflineUsage: OfflineUsage{
						LinuxResources: LinuxResources{
							AdditionalImagesFiles: []string{"multi-doc.yaml"},
						},
					},
				}

				images, err := impl.ExtractImagesFromFiles()

				Expect(err).ToNot(HaveOccurred())
				Expect(images).To(ConsistOf(
					"quay.io/jetstack/cert-manager-controller:v1.21.1",
					"quay.io/jetstack/cert-manager-webhook:v1.21.1",
				))
			})
		})

		Context("export monitoring addon", func() {
			It("extracts both operator and config-reloader images", func() {
				yamlContent := `apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-prometheus-stack-operator
  namespace: monitoring
spec:
  template:
    spec:
      containers:
        - name: kube-prometheus-stack
          image: "quay.io/prometheus-operator/prometheus-operator:v0.66.0"
          imagePullPolicy: "IfNotPresent"
          args:
            - --kubelet-service=kube-system/kube-prometheus-stack-kubelet
            - --prometheus-config-reloader=quay.io/prometheus-operator/prometheus-config-reloader:v0.66.0
            - --config-reloader-cpu-request=200m`

				yamlFile := filepath.Join(tempDir, "prometheus-operator-deployment.yaml")
				err := os.WriteFile(yamlFile, []byte(yamlContent), 0644)
				Expect(err).ToNot(HaveOccurred())

				impl := Implementation{
					Directory: tempDir,
					OfflineUsage: OfflineUsage{
						LinuxResources: LinuxResources{
							AdditionalImagesFiles: []string{"prometheus-operator-deployment.yaml"},
						},
					},
				}

				images, err := impl.ExtractImagesFromFiles()

				Expect(err).ToNot(HaveOccurred())
				Expect(images).To(ConsistOf(
					"quay.io/prometheus-operator/prometheus-operator:v0.66.0",
					"quay.io/prometheus-operator/prometheus-config-reloader:v0.66.0",
				))
			})
		})
	})
})
