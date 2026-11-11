// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package kubeconfig_test

import (
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-logr/logr"
	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/contracts/users"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/providers/kubeconfig"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"gopkg.in/yaml.v2"
)

func TestKubeconfigPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "kubeconfig pkg Tests", Label("ci", "internal", "kubeconfig"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("kubeconfig pkg", func() {
	Describe("FromFile", Label("integration"), func() {
		When("file read failed", func() {
			It("returns error", func() {
				actual, err := kubeconfig.FromFile("non-existent")

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(os.ErrNotExist))
			})
		})

		When("file read successful", func() {
			var path string
			var writtenConfig map[string]any

			BeforeEach(func() {
				path = filepath.Join(GinkgoT().TempDir(), "test.yaml")

				writtenConfig = map[string]any{
					"current-context": "my-context",
				}

				bytes, err := yaml.Marshal(writtenConfig)
				Expect(err).ToNot(HaveOccurred())

				Expect(os.WriteFile(path, bytes, os.ModePerm)).To(Succeed())
			})

			It("reads kubeconfig file correctly", func() {
				actual, err := kubeconfig.FromFile(path)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.CurrentContext).To(Equal(writtenConfig["current-context"]))
			})
		})
	})

	Describe("FindCluster", func() {
		When("not found", func() {
			It("returns error", func() {
				const name = "non-existent"
				config := &kubeconfig.Kubeconfig{}

				actual, err := config.FindCluster(name)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("cluster 'non-existent' not found")))
			})
		})

		When("found", func() {
			It("returns finding", func() {
				const name = "existent"
				config := &kubeconfig.Kubeconfig{
					Clusters: []kubeconfig.Cluster{{Name: name}},
				}

				actual, err := config.FindCluster(name)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Name).To(Equal(name))
			})
		})
	})

	Describe("FindUser", func() {
		When("not found", func() {
			It("returns error", func() {
				const name = "non-existent"
				config := &kubeconfig.Kubeconfig{}

				actual, err := config.FindUser(name)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("user 'non-existent' not found")))
			})
		})

		When("found", func() {
			It("returns finding", func() {
				const name = "existent"
				config := &kubeconfig.Kubeconfig{
					Users: []kubeconfig.User{{Name: name}},
				}

				actual, err := config.FindUser(name)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Name).To(Equal(name))
			})
		})
	})

	Describe("FindContextByCluster", func() {
		When("not found", func() {
			It("returns error", func() {
				const clusterName = "non-existent"
				config := &kubeconfig.Kubeconfig{}

				actual, err := config.FindContextByCluster(clusterName)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("context for cluster 'non-existent' not found")))
			})
		})

		When("found", func() {
			It("returns finding", func() {
				const clusterName = "existent"
				const contextName = "my-ctx"

				config := &kubeconfig.Kubeconfig{
					Contexts: []kubeconfig.Context{
						{
							Name: contextName,
							Details: kubeconfig.ContextDetails{
								Cluster: clusterName,
							},
						},
					},
				}

				actual, err := config.FindContextByCluster(clusterName)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Name).To(Equal(contextName))
			})
		})
	})

	Describe("FindK8sApiCredentials", func() {
		When("context not found", func() {
			It("returns error", func() {
				const contextName = "non-existent"
				config := &kubeconfig.Kubeconfig{}

				cluster, user, err := config.FindK8sApiCredentials(contextName)

				Expect(cluster).To(BeNil())
				Expect(user).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("context 'non-existent' not found")))
			})
		})

		When("user not found", func() {
			It("returns error", func() {
				const contextName = "my-context"
				config := &kubeconfig.Kubeconfig{
					Contexts: []kubeconfig.Context{
						{
							Name: contextName,
							Details: kubeconfig.ContextDetails{
								User: "non-existent",
							},
						},
					},
				}

				cluster, user, err := config.FindK8sApiCredentials(contextName)

				Expect(cluster).To(BeNil())
				Expect(user).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("user 'non-existent' not found in kubeconfig")))
			})
		})

		When("cluster not found", func() {
			It("returns error", func() {
				const contextName = "my-context"
				const userName = "my-user"
				config := &kubeconfig.Kubeconfig{
					Contexts: []kubeconfig.Context{
						{
							Name: contextName,
							Details: kubeconfig.ContextDetails{
								User:    userName,
								Cluster: "non-existent",
							},
						},
					},
					Users: []kubeconfig.User{{Name: userName}},
				}

				cluster, user, err := config.FindK8sApiCredentials(contextName)

				Expect(cluster).To(BeNil())
				Expect(user).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("cluster 'non-existent' not found in kubeconfig")))
			})
		})

		When("API credentials found", func() {
			It("returns API credentials", func() {
				const contextName = "my-context"
				const userName = "my-user"
				const clusterName = "my-cluster"
				config := &kubeconfig.Kubeconfig{
					Contexts: []kubeconfig.Context{
						{
							Name: contextName,
							Details: kubeconfig.ContextDetails{
								User:    userName,
								Cluster: clusterName,
							},
						},
					},
					Users:    []kubeconfig.User{{Name: userName}},
					Clusters: []kubeconfig.Cluster{{Name: clusterName}},
				}

				cluster, user, err := config.FindK8sApiCredentials(contextName)

				Expect(err).ToNot(HaveOccurred())
				Expect(cluster.Name).To(Equal(clusterName))
				Expect(user.Name).To(Equal(userName))
			})
		})
	})

	Describe("KubeconfigResolver", func() {
		Describe("ResolveKubeconfigPath", func() {
			It("returns correct kubeconfig path", func() {
				config := config.NewKubeConfig("", "~/test-kube-dir", "")
				user := users.NewOSUser("", "", filepath.Join("c:\\", "users", "test-user"))

				sut := kubeconfig.NewKubeconfigResolver(config)

				actual := sut.ResolveKubeconfigPath(user)

				Expect(actual).To(Equal(filepath.Join("c:\\", "users", "test-user", "test-kube-dir", definitions.KubeconfigName)))
			})
		})
	})
})
