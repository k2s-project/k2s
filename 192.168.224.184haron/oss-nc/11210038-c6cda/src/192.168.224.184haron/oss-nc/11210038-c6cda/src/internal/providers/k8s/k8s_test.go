// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package k8s_test

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/providers/k8s"
	"github.com/k2s-project/k2s/internal/test/reflection"
	"github.com/stretchr/testify/mock"
)

type mockRestClient struct {
	mock.Mock
}

func (m *mockRestClient) SetTLSConfig(caCert, userCert, userKey []byte) error {
	return m.Called(caCert, userCert, userKey).Error(0)
}

func (m *mockRestClient) Post(url string, payload any, result any) error {
	return m.Called(url, payload, result).Error(0)
}

func TestPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "k8s pkg Unit Tests", Label("unit", "ci", "k8s"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("UserInfoAPI", func() {
	var (
		sut        *k8s.UserInfoAPI
		mockClient *mockRestClient
		server     string
		caCert     []byte
		userCert   []byte
		userKey    []byte
	)

	BeforeEach(func() {
		mockClient = &mockRestClient{}
		sut = k8s.NewUserInfoAPI(mockClient)
		server = "https://k8s-api.example.com"
		caCert = []byte("ca-cert")
		userCert = []byte("user-cert")
		userKey = []byte("user-key")
	})

	Describe("FetchUserInfo", func() {
		When("TLS configuration fails", func() {
			It("returns an error", func() {
				mockClient.On(reflection.GetFunctionName(mockClient.SetTLSConfig), caCert, userCert, userKey).Return(errors.New("tls-config-error")).Once()

				actual, err := sut.FetchUserInfo(server, caCert, userCert, userKey)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("failed to set http client TLS config")))
				Expect(mockClient.AssertExpectations(GinkgoT())).To(BeTrue())
			})
		})

		When("REST client POST fails", func() {
			It("returns an error", func() {
				mockClient.On(reflection.GetFunctionName(mockClient.SetTLSConfig), caCert, userCert, userKey).Return(nil).Once()
				mockClient.On(reflection.GetFunctionName(mockClient.Post), mock.Anything, mock.Anything, mock.Anything).Return(errors.New("network-error")).Once()

				actual, err := sut.FetchUserInfo(server, caCert, userCert, userKey)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("failed to POST who-am-I request to K8s API")))
				Expect(mockClient.AssertExpectations(GinkgoT())).To(BeTrue())
			})
		})

		Context("when REST client POST succeeds", func() {
			It("returns user info", func() {
				response := k8s.SelfSubjectReview{
					Status: k8s.AuthStatus{
						UserInfo: k8s.UserInfo{
							Name:   "my-user",
							Groups: []string{"my-group-1", "my-group-2"},
						},
					},
				}

				mockClient.On(reflection.GetFunctionName(mockClient.SetTLSConfig), caCert, userCert, userKey).Return(nil).Once()
				mockClient.On(reflection.GetFunctionName(mockClient.Post), mock.Anything, mock.Anything, mock.Anything).Return(nil).Once().Run(func(args mock.Arguments) {
					arg := args.Get(2).(*k8s.SelfSubjectReview)
					*arg = response
				})

				actual, err := sut.FetchUserInfo(server, caCert, userCert, userKey)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).ToNot(BeNil())
				Expect(actual.Name).To(Equal("my-user"))
				Expect(actual.Groups).To(ConsistOf("my-group-1", "my-group-2"))
				Expect(mockClient.AssertExpectations(GinkgoT())).To(BeTrue())
			})
		})
	})
})
