// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package naming_test

import (
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/contracts/users"
	"github.com/k2s-project/k2s/internal/core/users/naming"
)

func TestPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "naming pkg Unit Tests", Label("unit", "ci", "naming"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("K2sUserNameProvider", func() {
	Describe("DetermineK2sUserName", func() {
		It("creates K2s user name from OS user", func() {
			user := users.NewOSUser("", "AD123\\test user", "")

			actual := naming.DetermineK2sUserName(user)

			Expect(actual).To(Equal("k2s-AD123-test-user"))
		})
	})
})
