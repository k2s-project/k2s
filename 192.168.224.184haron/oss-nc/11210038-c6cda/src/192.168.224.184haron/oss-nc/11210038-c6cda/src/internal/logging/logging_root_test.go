// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package logging_test

import (
	"path/filepath"

	"github.com/k2s-project/k2s/internal/logging"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("RootLogDir fallback chain", Label("integration"), func() {
	BeforeEach(func() {
		logging.ResetRootLogDirCache()
	})
	AfterEach(func() {
		logging.ResetRootLogDirCache()
	})

	It("returns the env var value when K2S_LOG_ROOT is set", func() {
		tempDir := GinkgoT().TempDir()
		GinkgoT().Setenv(logging.LogRootEnvVar, tempDir)

		Expect(logging.RootLogDir()).To(Equal(filepath.Clean(tempDir)))
	})

	It("expands environment variables embedded in the env var value", func() {
		tempDir := GinkgoT().TempDir()
		GinkgoT().Setenv("K2S_TEST_BASE", tempDir)
		GinkgoT().Setenv(logging.LogRootEnvVar, "${K2S_TEST_BASE}")

		Expect(logging.RootLogDir()).To(Equal(filepath.Clean(tempDir)))
	})

	It("memoizes the resolved path across calls", func() {
		first := GinkgoT().TempDir()
		GinkgoT().Setenv(logging.LogRootEnvVar, first)

		Expect(logging.RootLogDir()).To(Equal(filepath.Clean(first)))

		// Changing the env var without resetting the cache must not affect the result.
		second := GinkgoT().TempDir()
		GinkgoT().Setenv(logging.LogRootEnvVar, second)

		Expect(logging.RootLogDir()).To(Equal(filepath.Clean(first)))
	})
})
