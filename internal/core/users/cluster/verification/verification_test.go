// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package verification_test

import (
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/core/users/cluster/verification"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/providers/k8s"
)

func TestPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "verification pkg Unit Tests", Label("unit", "ci", "verification"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("VerifyUser", func() {
	When("user is not in K2s users group", func() {
		It("returns an error", func() {
			user := "my-user"

			userInfo := &k8s.UserInfo{
				Name:   user,
				Groups: []string{"group-1", "group-2"},
			}

			err := verification.VerifyUser(user, userInfo)

			Expect(err).To(HaveOccurred())
			Expect(err).To(MatchError(ContainSubstring("not part of the group")))
		})
	})

	Context("when user names do not match", func() {
		It("returns an error", func() {
			userInfo := &k8s.UserInfo{
				Name:   "different-user",
				Groups: []string{definitions.K2sUserGroup},
			}

			err := verification.VerifyUser("my-user", userInfo)

			Expect(err).To(HaveOccurred())
			Expect(err).To(MatchError(ContainSubstring("does not match expected user name")))
		})
	})

	Context("when verification succeeds", func() {
		It("returns nil", func() {
			user := "my-user"
			userInfo := &k8s.UserInfo{
				Name:   user,
				Groups: []string{definitions.K2sUserGroup},
			}

			err := verification.VerifyUser(user, userInfo)

			Expect(err).ToNot(HaveOccurred())
		})
	})
})
