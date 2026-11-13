// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package host_test

import (
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/host"
)

func TestHostPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "host pkg Unit Tests", Label("ci", "internal", "host"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("host pkg", Ordered, func() {
	Describe("SystemDrive", Label("unit"), func() {
		It("returns Windows system drive with trailing backslash", func() {
			drive := host.SystemDrive()

			Expect(drive).To(Equal("C:\\"))
		})
	})

	Describe("ResolveTildePrefixForCurrentUser", Label("integration"), func() {
		When("path contains tilde as prefix", func() {
			DescribeTable("resolves tilde with current user's home dir", func(input string) {
				actual, err := host.ResolveTildePrefixForCurrentUser(input)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(MatchRegexp(`^C:\\Users\\[^\\]+\\dir\\test-file$`))
			},
				Entry("win path backslash", "~\\dir\\test-file"),
				Entry("win path slash", "~/dir/test-file"),
				Entry("weird mix", "~/dir\\test-file"),
			)
		})

		When("path contains tilde without prefix", Label("unit"), func() {
			DescribeTable("returns unmodified path", func(input string) {
				actual, err := host.ResolveTildePrefixForCurrentUser(input)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(input))
			},
				Entry("abs win path backslash", "c:\\dir\\~"),
				Entry("abs win path slash", "c:/~/test-file"),
				Entry("abs unix path", "/dir/test/~"),
				Entry("rel win path", "dir\\test-file\\~"),
				Entry("rel unix path", "dir/test-file/~"),
				Entry("weird mix", "oh\\my/~/gosh-file"),
			)
		})

		When("path does not contain tilde", Label("unit"), func() {
			DescribeTable("returns unmodified path", func(input string) {
				actual, err := host.ResolveTildePrefixForCurrentUser(input)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(input))
			},
				Entry("abs win path backslash", "c:\\dir\\test-file"),
				Entry("abs win path slash", "c:/dir/test-file"),
				Entry("abs unix path", "/dir/test-file"),
				Entry("rel win path", "dir\\test-file"),
				Entry("rel unix path", "dir/test-file"),
				Entry("weird mix", "oh\\my/gosh-file"),
			)
		})
	})

	Describe("ResolveTildePrefix", Label("unit"), func() {
		When("path contains tilde as prefix", func() {
			DescribeTable("resolves tilde with given path", func(input string) {
				actual := host.ResolveTildePrefix(input, "D:\\root")

				Expect(actual).To(MatchRegexp(`D:\\root\\dir\\test-file$`))
			},
				Entry("win path backslash", "~\\dir\\test-file"),
				Entry("win path slash", "~/dir/test-file"),
				Entry("weird mix", "~/dir\\test-file"),
			)
		})

		When("path contains tilde without prefix", Label("unit"), func() {
			DescribeTable("resolves tilde with given path", func(input, expected string) {
				actual := host.ResolveTildePrefix(input, "\\some-dir\\")

				Expect(actual).To(Equal(expected))
			},
				Entry("abs win path backslash", "c:\\dir\\~", "c:\\dir\\some-dir"),
				Entry("abs win path slash", "c:/~/test-file", "c:\\some-dir\\test-file"),
				Entry("abs unix path", "/dir/test/~", "\\dir\\test\\some-dir"),
				Entry("rel win path", "dir\\test-file\\~", "dir\\test-file\\some-dir"),
				Entry("rel unix path", "dir/test-file/~", "dir\\test-file\\some-dir"),
				Entry("weird mix", "oh\\my/~/gosh-file", "oh\\my\\some-dir\\gosh-file"),
			)
		})

		When("path does not contain tilde", Label("unit"), func() {
			DescribeTable("returns only cleaned path", func(input string, expected string) {
				actual := host.ResolveTildePrefix(input, "\\some-dir\\")

				Expect(actual).To(Equal(expected))
			},
				Entry("abs win path backslash", "c:\\dir\\test-file", "c:\\dir\\test-file"),
				Entry("abs win path slash", "c:/dir/test-file", "c:\\dir\\test-file"),
				Entry("abs unix path", "/dir/test-file", "\\dir\\test-file"),
				Entry("rel win path", "dir\\test-file", "dir\\test-file"),
				Entry("rel unix path", "dir/test-file", "dir\\test-file"),
				Entry("weird mix", "oh\\my/gosh-file", "oh\\my\\gosh-file"),
			)
		})
	})
})
