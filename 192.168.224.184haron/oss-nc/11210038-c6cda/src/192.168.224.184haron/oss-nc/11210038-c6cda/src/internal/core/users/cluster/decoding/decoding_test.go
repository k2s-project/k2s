// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package decoding_test

import (
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/core/users/cluster/decoding"
	"github.com/k2s-project/k2s/internal/providers/kubeconfig"
)

func TestPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "decoding pkg Unit Tests", Label("unit", "ci", "decoding"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("CredentialsDecoder", func() {
	Describe("DecodeK8sApiCredentials", func() {
		When("decoding cluster cert fails", func() {
			It("returns error", func() {
				clusterConfig := &kubeconfig.Cluster{
					Details: kubeconfig.ClusterDetails{Cert: "invalid-base64"},
				}

				caCert, userCert, userKey, err := decoding.DecodeK8sApiCredentials(clusterConfig, nil)

				Expect(err).To(MatchError(ContainSubstring("failed to decode cluster certificate")))
				Expect(caCert).To(BeNil())
				Expect(userCert).To(BeNil())
				Expect(userKey).To(BeNil())
			})
		})

		When("decoding user cert fails", func() {
			It("returns error", func() {
				clusterConfig := &kubeconfig.Cluster{
					Details: kubeconfig.ClusterDetails{Cert: "AFFE"},
				}
				userConfig := &kubeconfig.User{
					Details: kubeconfig.UserDetails{Cert: "invalid-base64"},
				}

				caCert, userCert, userKey, err := decoding.DecodeK8sApiCredentials(clusterConfig, userConfig)

				Expect(err).To(MatchError(ContainSubstring("failed to decode user certificate")))
				Expect(caCert).To(BeNil())
				Expect(userCert).To(BeNil())
				Expect(userKey).To(BeNil())
			})
		})

		When("decoding user key fails", func() {
			It("returns error", func() {
				clusterConfig := &kubeconfig.Cluster{
					Details: kubeconfig.ClusterDetails{Cert: "AFFE"},
				}
				userConfig := &kubeconfig.User{
					Details: kubeconfig.UserDetails{Cert: "AFFE", Key: "invalid-base64"},
				}

				caCert, userCert, userKey, err := decoding.DecodeK8sApiCredentials(clusterConfig, userConfig)

				Expect(err).To(MatchError(ContainSubstring("failed to decode user key")))
				Expect(caCert).To(BeNil())
				Expect(userCert).To(BeNil())
				Expect(userKey).To(BeNil())
			})
		})

		When("decoding is successful", func() {
			It("returns decoded credentials", func() {
				clusterConfig := &kubeconfig.Cluster{
					Details: kubeconfig.ClusterDetails{Cert: "dGVzdC1jYQ=="},
				}
				userConfig := &kubeconfig.User{
					Details: kubeconfig.UserDetails{Cert: "dGVzdC1jZXJ0", Key: "dGVzdC1rZXk="},
				}

				caCert, userCert, userKey, err := decoding.DecodeK8sApiCredentials(clusterConfig, userConfig)

				Expect(err).ToNot(HaveOccurred())
				Expect(caCert).To(Equal([]byte("test-ca")))
				Expect(userCert).To(Equal([]byte("test-cert")))
				Expect(userKey).To(Equal([]byte("test-key")))
			})
		})
	})
})
