// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package keyauth_test

import (
	"errors"
	"strings"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/core/users/controlplane/keyauth"
	"github.com/k2s-project/k2s/internal/test/reflection"
	"github.com/stretchr/testify/mock"
)

type mockSshProvider struct {
	mock.Mock
}

func (m *mockSshProvider) Exec(command string) error {
	args := m.Called(command)
	return args.Error(0)
}

func (m *mockSshProvider) CopyToNode(source, target string) error {
	args := m.Called(source, target)
	return args.Error(0)
}

func TestPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "keyauth pkg Unit Tests", Label("unit", "ci", "keyauth"))
}

var _ = Describe("KeyAuthorizer", func() {
	Describe("AuthorizePubKeyOnRemote", func() {
		When("removing the existing remote key fails", func() {
			It("returns error", func() {
				sshMock := &mockSshProvider{}
				sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.MatchedBy(func(cmd string) bool {
					return cmd == "rm -f /tmp/my.key"
				})).Return(errors.New("oops")).Once()

				sut := keyauth.NewKeyAuthorizer(sshMock)

				err := sut.AuthorizePubKeyOnRemote("/my-dir/my.key", "my-comment")

				Expect(err).To(MatchError(ContainSubstring("failed to remove existing SSH public key")))
				sshMock.AssertExpectations(GinkgoT())
			})
		})

		When("copying the key fails", func() {
			It("returns error", func() {
				sshMock := &mockSshProvider{}
				sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil).Once()
				sshMock.On(reflection.GetFunctionName(sshMock.CopyToNode), "/my-dir/my.key", "/tmp/my.key").Return(errors.New("oops")).Once()

				sut := keyauth.NewKeyAuthorizer(sshMock)

				err := sut.AuthorizePubKeyOnRemote("/my-dir/my.key", "my-comment")

				Expect(err).To(MatchError(ContainSubstring("failed to copy public SSH key")))
				sshMock.AssertExpectations(GinkgoT())
			})
		})

		When("authorizing the key on the remote fails", func() {
			It("returns a wrapped error", func() {
				sshMock := &mockSshProvider{}
				sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil).Once()
				sshMock.On(reflection.GetFunctionName(sshMock.CopyToNode), mock.Anything, mock.Anything).Return(nil).Once()
				sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(errors.New("oops")).Once()

				sut := keyauth.NewKeyAuthorizer(sshMock)

				err := sut.AuthorizePubKeyOnRemote("/my-dir/my.key", "my-comment")

				Expect(err).To(MatchError(ContainSubstring("failed to add public SSH key to authorized keys file")))
				sshMock.AssertExpectations(GinkgoT())
			})
		})

		When("all succeeds", func() {
			It("successfully authorizes key on remote", func() {
				sshMock := &mockSshProvider{}
				sshMock.On(reflection.GetFunctionName(sshMock.Exec), "rm -f /tmp/my.key").Return(nil).Once()
				sshMock.On(reflection.GetFunctionName(sshMock.CopyToNode), mock.Anything, mock.Anything).Return(nil).Once()
				sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.MatchedBy(func(cmd string) bool {
					return strings.Contains(cmd, "sed") &&
						strings.Contains(cmd, "my-comment") &&
						strings.Contains(cmd, "/tmp/my.key") &&
						strings.Contains(cmd, "~/.ssh/authorized_keys")
				})).Return(nil)

				sut := keyauth.NewKeyAuthorizer(sshMock)

				err := sut.AuthorizePubKeyOnRemote("/my-dir/my.key", "my-comment")

				Expect(err).To(BeNil())
				sshMock.AssertExpectations(GinkgoT())
			})
		})
	})
})
