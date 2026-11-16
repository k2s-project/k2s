// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package common

import (
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/providers/kubeconfig"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v2"
)

func Test(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "cmd common Unit Tests", Label("ci", "cmd"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("common", func() {
	Describe("NodeSelector", Label("unit"), func() {
		It("prefers a non-empty nodes flag and trims surrounding whitespace", func() {
			cmd := &cobra.Command{}
			cmd.Flags().String("node", "worker-1", "")
			cmd.Flags().String("nodes", "  worker-2,worker-3  ", "")

			selector, err := ParseNodeSelector(cmd, "node", "nodes")

			Expect(err).ToNot(HaveOccurred())
			Expect(selector).To(Equal("worker-2,worker-3"))
		})

		It("treats comma-only selectors as empty and falls back to node", func() {
			cmd := &cobra.Command{}
			cmd.Flags().String("node", "worker-1", "")
			cmd.Flags().String("nodes", " , , ", "")

			selector, err := ParseNodeSelector(cmd, "node", "nodes")

			Expect(err).ToNot(HaveOccurred())
			Expect(selector).To(Equal("worker-1"))
		})

		It("does not append an empty node selector", func() {
			params := AppendNodesParam([]string{" -ImagePath 'image.tar'"}, " , , ")

			Expect(params).To(Equal([]string{" -ImagePath 'image.tar'"}))
		})
	})

	Describe("CmdFailure", Label("unit"), func() {
		Describe("Error", func() {
			It("implements the error interface", func() {
				sut := &CmdFailure{
					Code:    "my-code",
					Message: "my-msg",
				}

				result := sut.Error()

				Expect(result).To(Equal("my-code: my-msg"))
			})
		})
	})

	Describe("FailureSeverity", Label("unit"), func() {
		DescribeTable("String - implements the stringer interface", func(input FailureSeverity, expected string) {
			sut := FailureSeverity(input)

			result := sut.String()

			Expect(result).To(Equal(expected))
		},
			Entry("warning", FailureSeverity(3), "warning"),
			Entry("error", FailureSeverity(4), "error"),
			Entry("unknown", FailureSeverity(123), "unknown"))
	})

	Describe("CreateSystemNotInstalledCmdResult", Label("unit"), func() {
		It("works", func() {
			result := CreateSystemNotInstalledCmdResult()

			Expect(result.Failure.Code).To(Equal(config.ErrSystemNotInstalled.Error()))
		})
	})

	Describe("CreateSystemNotInstalledCmdFailure", Label("unit"), func() {
		It("works", func() {
			result := CreateSystemNotInstalledCmdFailure()

			Expect(result.Severity).To(Equal(SeverityWarning))
			Expect(result.Code).To(Equal(config.ErrSystemNotInstalled.Error()))
			Expect(result.Message).To(Equal(ErrSystemNotInstalledMsg))
		})
	})

	Describe("CmdContext", Label("integration"), func() {
		Describe("EnsureK2sK8sContext", func() {
			var kubeConfigDir string

			BeforeEach(func() {
				kubeConfigDir = GinkgoT().TempDir()
			})

			writeKubeConfig := func(currentContext, contextName, clusterName string) {
				content := map[string]any{
					"current-context": currentContext,
					"contexts": []map[string]any{
						{
							"name": contextName,
							"context": map[string]any{
								"cluster": clusterName,
								"user":    "test-user",
							},
						},
					},
				}

				bytes, err := yaml.Marshal(content)
				Expect(err).ToNot(HaveOccurred())

				kubeConfigPath := filepath.Join(kubeConfigDir, kubeconfig.DefaultFileName)
				Expect(os.WriteFile(kubeConfigPath, bytes, os.ModePerm)).To(Succeed())
			}

			newSut := func() *CmdContext {
				hostConfig := config.NewHostConfig(config.NewKubeConfig(kubeConfigDir, "", ""), nil, "", "", "")
				k2sConfig := config.NewK2sConfig(hostConfig, nil)

				return NewCmdContext(k2sConfig, nil, nil)
			}

			When("kubeconfig file cannot be read", func() {
				It("returns error", func() {
					sut := newSut()

					err := sut.EnsureK2sK8sContext("my-cluster")

					Expect(err).To(MatchError(ContainSubstring("could not read kubeconfig")))
				})
			})

			When("no context exists for the cluster", func() {
				It("returns error", func() {
					writeKubeConfig("other-context", "other-context", "other-cluster")

					sut := newSut()

					err := sut.EnsureK2sK8sContext("my-cluster")

					Expect(err).To(MatchError(ContainSubstring("could not find context for cluster 'my-cluster'")))
				})
			})

			When("cluster matches legacy cluster name (kubernetes)", func() {
				It("falls back to legacy cluster context and succeeds", func() {
					writeKubeConfig("kubernetes-admin@kubernetes", "kubernetes-admin@kubernetes", definitions.LegacyClusterName)

					sut := newSut()

					err := sut.EnsureK2sK8sContext("k2s-cluster")

					Expect(err).ToNot(HaveOccurred())
				})
			})

			When("the cluster context is already the current context", func() {
				It("returns nil", func() {
					writeKubeConfig("my-context", "my-context", "my-cluster")

					sut := newSut()

					err := sut.EnsureK2sK8sContext("my-cluster")

					Expect(err).ToNot(HaveOccurred())
				})
			})

			When("the cluster context is not the current context", func() {
				It("returns a CmdFailure hinting at the required context switch", func() {
					writeKubeConfig("other-context", "my-context", "my-cluster")

					sut := newSut()

					err := sut.EnsureK2sK8sContext("my-cluster")

					var cmdFailure *CmdFailure
					Expect(errors.As(err, &cmdFailure)).To(BeTrue())
					Expect(cmdFailure.Severity).To(Equal(SeverityWarning))
					Expect(cmdFailure.Code).To(Equal("not-k2s-context"))
					Expect(cmdFailure.Message).To(ContainSubstring("kubectl config use-context my-context"))
				})
			})
		})
	})
})
