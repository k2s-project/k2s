// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package users

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestUsersPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "users cmd Unit Tests", Label("unit", "ci", "users"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("users pkg", func() {
	Describe("add cmd", func() {
		Describe("newUserNotFoundFailure", func() {
			It("returns cmd failure with warn level severity", func() {
				input := errors.New("oops")

				actual := newUserNotFoundFailure(input)

				Expect(actual.Severity).To(Equal(common.SeverityWarning))
				Expect(actual.Code).To(Equal("user-not-found"))
				Expect(actual.Message).To(Equal("oops"))
			})
		})
	})
})
