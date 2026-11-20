// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package validation_test

import (
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/contracts/users"
	"github.com/k2s-project/k2s/internal/core/users/validation"
	"github.com/stretchr/testify/mock"
)

type mockUserProvider struct {
	mock.Mock
}

func (m *mockUserProvider) CurrentUser() (*users.OSUser, error) {
	args := m.Called()

	return args.Get(0).(*users.OSUser), args.Error(1)
}

func TestPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "validation pkg Unit Tests", Label("unit", "ci", "validation"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("validation", func() {
	Describe("ValidateUser", func() {
		When("current user is the same as the target user", func() {
			It("returns error", func() {
				currentUser := users.NewOSUser("my-id", "my-name", "")
				targetUser := users.NewOSUser("my-id", "my-name", "")

				err := validation.ValidateUser(currentUser, targetUser)

				Expect(err).To(MatchError(ContainSubstring("cannot overwrite access of current user")))
			})
		})

		When("user is valid", func() {
			It("returns nil", func() {
				currentUser := users.NewOSUser("my-id", "my-name", "")
				targetUser := users.NewOSUser("different-id", "different-name", "")

				err := validation.ValidateUser(currentUser, targetUser)

				Expect(err).To(BeNil())
			})
		})
	})
})
